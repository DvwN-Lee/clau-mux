"""Tests for cleanup hook coverage: Issue #24 (subagent cleanup) + Issue #3
(copilot spawn isActive).

reconcile_active.py is the universal cleanup path. For every team member with
isActive=true and a non-empty tmuxPaneId, it checks tmux for liveness; if the
pane is gone, isActive is flipped to false. Covers BOTH bridge teammates and
native Agent-tool subagents (agentType="general-purpose"), closing the
pre-existing gap where native subagents had no cleanup path at all.

update_pane.py is covered here as a regression test for Issue #3: the spawn
path must set isActive=true for copilot-worker, same as gemini/codex.
"""
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parent.parent / "scripts"


def _write_config(team_dir: Path, members):
    team_dir.mkdir(parents=True, exist_ok=True)
    cfg = {
        "name": team_dir.name,
        "leadSessionId": "test-session",
        "members": members,
    }
    (team_dir / "config.json").write_text(json.dumps(cfg, indent=2))
    return team_dir / "config.json"


def _read_config(cfg_path: Path):
    return json.loads(cfg_path.read_text())


def _run(script: str, *args) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPTS / script), *args],
        capture_output=True,
        text=True,
    )


@pytest.fixture
def tmux_session():
    """Spawn a dedicated tmux session so tests don't pollute user state."""
    name = f"clmux-test-{uuid.uuid4().hex[:8]}"
    # -d detached; dummy command keeps session alive briefly
    res = subprocess.run(
        ["tmux", "new-session", "-d", "-s", name, "sleep", "30"],
        capture_output=True, text=True,
    )
    if res.returncode != 0:
        pytest.skip(f"tmux unavailable: {res.stderr}")
    try:
        pane_id = subprocess.check_output(
            ["tmux", "list-panes", "-t", f"={name}", "-F", "#{pane_id}"],
            text=True,
        ).strip()
        yield name, pane_id
    finally:
        subprocess.run(["tmux", "kill-session", "-t", f"={name}"],
                       capture_output=True)


class TestReconcileActive:
    def test_dead_pane_flips_isactive_false(self, tmp_path):
        """Issue #24: general-purpose subagent with dead pane → isActive=false."""
        cfg_path = _write_config(tmp_path, [
            {
                "agentId": "plan-reviewer@test",
                "name": "plan-reviewer",
                "agentType": "general-purpose",
                "tmuxPaneId": "%999999",  # guaranteed non-existent
                "isActive": True,
            },
        ])
        result = _run("reconcile_active.py", str(tmp_path))
        assert result.returncode == 0, result.stderr
        cfg = _read_config(cfg_path)
        assert cfg["members"][0]["isActive"] is False

    def test_live_pane_preserves_isactive_true(self, tmp_path, tmux_session):
        """Live tmux pane → isActive=true preserved."""
        _, live_pane = tmux_session
        cfg_path = _write_config(tmp_path, [
            {
                "agentId": "gemini-worker@test",
                "name": "gemini-worker",
                "agentType": "bridge",
                "tmuxPaneId": live_pane,
                "isActive": True,
            },
        ])
        result = _run("reconcile_active.py", str(tmp_path))
        assert result.returncode == 0, result.stderr
        cfg = _read_config(cfg_path)
        assert cfg["members"][0]["isActive"] is True

    def test_bridge_and_subagent_handled_uniformly(self, tmp_path):
        """Both agentTypes reconcile when pane is dead (Issue #24 + symmetry)."""
        cfg_path = _write_config(tmp_path, [
            {
                "name": "plan-reviewer",
                "agentType": "general-purpose",
                "tmuxPaneId": "%999997",
                "isActive": True,
            },
            {
                "name": "gemini-worker",
                "agentType": "bridge",
                "tmuxPaneId": "%999998",
                "isActive": True,
            },
        ])
        result = _run("reconcile_active.py", str(tmp_path))
        assert result.returncode == 0, result.stderr
        cfg = _read_config(cfg_path)
        assert all(m["isActive"] is False for m in cfg["members"])

    def test_empty_tmux_pane_id_is_skipped(self, tmp_path):
        """team-lead has tmuxPaneId='' — never touch its isActive-less entry."""
        cfg_path = _write_config(tmp_path, [
            {
                "name": "team-lead",
                "agentType": "team-lead",
                "tmuxPaneId": "",
                # note: no isActive field on team-lead
            },
            {
                "name": "plan-reviewer",
                "agentType": "general-purpose",
                "tmuxPaneId": "%999996",
                "isActive": True,
            },
        ])
        result = _run("reconcile_active.py", str(tmp_path))
        assert result.returncode == 0, result.stderr
        cfg = _read_config(cfg_path)
        # team-lead untouched
        assert "isActive" not in cfg["members"][0]
        # plan-reviewer flipped
        assert cfg["members"][1]["isActive"] is False

    def test_already_inactive_is_noop(self, tmp_path):
        """Members already isActive=false are left alone (idempotent)."""
        cfg_path = _write_config(tmp_path, [
            {
                "name": "gemini-worker",
                "agentType": "bridge",
                "tmuxPaneId": "%999995",
                "isActive": False,
            },
        ])
        before = cfg_path.read_text()
        result = _run("reconcile_active.py", str(tmp_path))
        assert result.returncode == 0, result.stderr
        # content identical (no unnecessary rewrite)
        assert cfg_path.read_text() == before

    def test_missing_config_exits_cleanly(self, tmp_path):
        """No config.json → exit 0, no traceback (safe for SessionStart hook)."""
        result = _run("reconcile_active.py", str(tmp_path))
        assert result.returncode == 0
        assert "Traceback" not in result.stderr


class TestReconcileHook:
    """SessionStart hook wrapper: scoped to leadSessionId, degrades safely."""

    HOOK = Path(__file__).parent.parent / "hooks" / "reconcile-active.py"

    def _invoke(self, session_id: str, home: Path):
        env = dict(os.environ)
        env["HOME"] = str(home)
        # Force hook to discover the in-repo scripts/ via CLMUX_DIR
        env["CLMUX_DIR"] = str(Path(__file__).parent.parent)
        return subprocess.run(
            [sys.executable, str(self.HOOK)],
            input=json.dumps({"session_id": session_id}),
            capture_output=True, text=True, env=env,
        )

    def test_scoped_to_matching_leadsessionid(self, tmp_path):
        """Hook must only touch teams whose leadSessionId matches session_id."""
        teams_root = tmp_path / ".claude" / "teams"
        match_team = teams_root / "match"
        other_team = teams_root / "other"
        for td, sid in [(match_team, "S-ME"), (other_team, "S-THEM")]:
            td.mkdir(parents=True)
            (td / "config.json").write_text(json.dumps({
                "name": td.name,
                "leadSessionId": sid,
                "members": [{
                    "name": "plan-reviewer",
                    "agentType": "general-purpose",
                    "tmuxPaneId": "%999994",
                    "isActive": True,
                }],
            }))

        result = self._invoke("S-ME", tmp_path)
        assert result.returncode == 0, result.stderr

        match_cfg = json.loads((match_team / "config.json").read_text())
        other_cfg = json.loads((other_team / "config.json").read_text())
        assert match_cfg["members"][0]["isActive"] is False  # reconciled
        assert other_cfg["members"][0]["isActive"] is True   # untouched

    def test_missing_session_id_is_noop(self, tmp_path):
        """No session_id → hook silently exits 0 without touching anything."""
        result = self._invoke("", tmp_path)
        assert result.returncode == 0


class TestUpdatePaneCopilotRegression:
    """Issue #3 regression: update_pane.py must set isActive=true for copilot.

    docs/hooks-troubleshooting.md §5 speculated a copilot-specific branch
    might skip the isActive write. This test locks in that there is NO such
    branch — copilot-worker is treated identically to gemini/codex.
    """

    def test_copilot_spawn_sets_isactive_true_new_member(self, tmp_path):
        # No existing member — update_pane.py must APPEND with isActive=true
        (tmp_path / "config.json").write_text(json.dumps({
            "name": tmp_path.name,
            "members": [],
        }))
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "update_pane.py"),
             str(tmp_path), "copilot-worker", "%42", "copilot", "0"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stderr
        cfg = json.loads((tmp_path / "config.json").read_text())
        copilot = next(m for m in cfg["members"] if m["name"] == "copilot-worker")
        assert copilot["isActive"] is True
        assert copilot["agentType"] == "bridge"
        assert copilot["tmuxPaneId"] == "%42"

    def test_copilot_respawn_flips_isactive_back_to_true(self, tmp_path):
        # Existing entry with isActive=false (post-shutdown state) — respawn
        # must flip it back to true
        (tmp_path / "config.json").write_text(json.dumps({
            "name": tmp_path.name,
            "members": [{
                "agentId": f"copilot-worker@{tmp_path.name}",
                "name": "copilot-worker",
                "agentType": "bridge",
                "tmuxPaneId": "%10",
                "isActive": False,
            }],
        }))
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "update_pane.py"),
             str(tmp_path), "copilot-worker", "%99", "copilot", "0"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stderr
        cfg = json.loads((tmp_path / "config.json").read_text())
        copilot = next(m for m in cfg["members"] if m["name"] == "copilot-worker")
        assert copilot["isActive"] is True
        assert copilot["tmuxPaneId"] == "%99"
