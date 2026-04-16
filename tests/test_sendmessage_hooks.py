"""Tests for SendMessage workaround hooks (Issue #25 defence-in-depth).

guard-sendmessage.py  — PreToolUse hook that blocks SendMessage when the
                        target name is not present in any active team's members.
rescue-default-inbox.py — Stop hook that moves misdelivered messages from
                          ~/.claude/teams/default/inboxes/ to the real team inbox.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

HOOKS = Path(__file__).parent.parent / "hooks"


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

def _write_team(teams_root: Path, team_name: str, session_id: str, members: list):
    """Create a minimal team config under teams_root/<team_name>/config.json."""
    team_dir = teams_root / team_name
    team_dir.mkdir(parents=True, exist_ok=True)
    cfg = {
        "name": team_name,
        "leadSessionId": session_id,
        "createdAt": "2026-04-16T00:00:00Z",
        "members": members,
    }
    (team_dir / "config.json").write_text(json.dumps(cfg, indent=2))
    return team_dir


def _write_inbox_message(teams_root: Path, team_name: str, inbox_owner: str,
                         messages: list):
    """Write a JSON message file into teams/<team>/inboxes/<owner>/<file>.json."""
    inbox_dir = teams_root / team_name / "inboxes" / inbox_owner
    inbox_dir.mkdir(parents=True, exist_ok=True)
    fp = inbox_dir / "msg_001.json"
    fp.write_text(json.dumps(messages, indent=2))
    return fp


def _run_hook(hook_name: str, stdin_data: dict, home: str) -> subprocess.CompletedProcess:
    """Run a hook script with given stdin and HOME override."""
    env = dict(os.environ)
    env["HOME"] = home
    return subprocess.run(
        [sys.executable, str(HOOKS / hook_name)],
        input=json.dumps(stdin_data),
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )


# ===========================================================================
# guard-sendmessage.py
# ===========================================================================

class TestGuardSendMessage:
    HOOK = "guard-sendmessage.py"
    SESSION = "sess-abc-123"

    def _setup_team(self, tmp_path):
        teams = tmp_path / ".claude" / "teams"
        _write_team(teams, "my-team", self.SESSION, [
            {"name": "gemini-worker", "agentId": "gemini-worker@my-team",
             "agentType": "bridge", "isActive": True},
            {"name": "plan-reviewer", "agentId": "plan-reviewer@my-team",
             "agentType": "general-purpose", "isActive": True},
        ])
        return teams

    def test_blocks_when_target_not_in_team(self, tmp_path):
        """SendMessage to unknown name → deny."""
        self._setup_team(tmp_path)
        result = _run_hook(self.HOOK, {
            "hook_event_name": "PreToolUse",
            "tool_name": "SendMessage",
            "tool_input": {"to": "nonexistent-agent", "message": "hello"},
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        out = json.loads(result.stdout)
        decision = out["hookSpecificOutput"]["permissionDecision"]
        assert decision == "deny"

    def test_allows_when_target_in_team(self, tmp_path):
        """SendMessage to a known member name → allow (no stdout)."""
        self._setup_team(tmp_path)
        result = _run_hook(self.HOOK, {
            "hook_event_name": "PreToolUse",
            "tool_name": "SendMessage",
            "tool_input": {"to": "gemini-worker", "message": "hello"},
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        # allow = no output (or empty)
        assert result.stdout.strip() == ""

    def test_allows_broadcast(self, tmp_path):
        """SendMessage to '*' (broadcast) → always allow."""
        self._setup_team(tmp_path)
        result = _run_hook(self.HOOK, {
            "hook_event_name": "PreToolUse",
            "tool_name": "SendMessage",
            "tool_input": {"to": "*", "message": "broadcast msg"},
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    def test_allows_when_no_teams_exist(self, tmp_path):
        """No teams directory at all → allow (fail-open for non-team usage)."""
        result = _run_hook(self.HOOK, {
            "hook_event_name": "PreToolUse",
            "tool_name": "SendMessage",
            "tool_input": {"to": "someone", "message": "hi"},
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        assert result.stdout.strip() == ""

    def test_matches_by_agent_id(self, tmp_path):
        """Target matches agentId (not just name) → allow."""
        self._setup_team(tmp_path)
        result = _run_hook(self.HOOK, {
            "hook_event_name": "PreToolUse",
            "tool_name": "SendMessage",
            "tool_input": {"to": "plan-reviewer@my-team", "message": "hi"},
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        assert result.stdout.strip() == ""


# ===========================================================================
# rescue-default-inbox.py
# ===========================================================================

class TestRescueDefaultInbox:
    HOOK = "rescue-default-inbox.py"
    SESSION = "sess-xyz-789"

    def _setup_active_team(self, tmp_path, team_name="real-team"):
        teams = tmp_path / ".claude" / "teams"
        _write_team(teams, team_name, self.SESSION, [
            {"name": "gemini-worker", "agentId": "gemini-worker@real-team",
             "agentType": "bridge", "isActive": True},
        ])
        return teams

    def test_moves_messages_from_default(self, tmp_path):
        """Messages in teams/default/inboxes/ are moved to the active team."""
        teams = self._setup_active_team(tmp_path)
        # Create misdelivered message in default inbox
        msg_data = [{"id": "msg1", "content": "hello from lead"}]
        _write_inbox_message(teams, "default", "gemini-worker", msg_data)
        assert (teams / "default" / "inboxes" / "gemini-worker" / "msg_001.json").exists()

        result = _run_hook(self.HOOK, {
            "hook_event_name": "Stop",
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0

        # Message should be moved to real team inbox
        rescued_dir = teams / "real-team" / "inboxes" / "gemini-worker"
        assert rescued_dir.exists()
        rescued_files = list(rescued_dir.glob("*.json"))
        assert len(rescued_files) >= 1
        rescued_data = json.loads(rescued_files[0].read_text())
        assert rescued_data == msg_data

        # Default inbox file should be gone
        assert not (teams / "default" / "inboxes" / "gemini-worker" / "msg_001.json").exists()

    def test_noop_when_default_empty(self, tmp_path):
        """No default/inboxes/ directory → clean exit, nothing to rescue."""
        self._setup_active_team(tmp_path)
        result = _run_hook(self.HOOK, {
            "hook_event_name": "Stop",
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        assert "rescued" not in result.stderr.lower()

    def test_merges_with_existing_inbox(self, tmp_path):
        """If the target inbox already has a message file, contents are merged."""
        teams = self._setup_active_team(tmp_path)

        # Existing message in the real team inbox
        existing_msg = [{"id": "existing", "content": "already here"}]
        _write_inbox_message(teams, "real-team", "gemini-worker", existing_msg)

        # Misdelivered message in default
        new_msg = [{"id": "rescued", "content": "was in default"}]
        default_inbox = teams / "default" / "inboxes" / "gemini-worker"
        default_inbox.mkdir(parents=True, exist_ok=True)
        (default_inbox / "msg_002.json").write_text(json.dumps(new_msg))

        result = _run_hook(self.HOOK, {
            "hook_event_name": "Stop",
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0

        # Real team inbox should now have BOTH files
        target_dir = teams / "real-team" / "inboxes" / "gemini-worker"
        all_files = list(target_dir.glob("*.json"))
        all_contents = []
        for f in all_files:
            all_contents.extend(json.loads(f.read_text()))
        ids = {m["id"] for m in all_contents}
        assert "existing" in ids
        assert "rescued" in ids

        # Default inbox file should be gone
        assert not (default_inbox / "msg_002.json").exists()

    def test_noop_when_no_active_team(self, tmp_path):
        """Default has messages but no active team → leave orphans, warn only."""
        teams = tmp_path / ".claude" / "teams"
        msg_data = [{"id": "orphan", "content": "no team to rescue to"}]
        _write_inbox_message(teams, "default", "someone", msg_data)

        result = _run_hook(self.HOOK, {
            "hook_event_name": "Stop",
            "session_id": self.SESSION,
        }, str(tmp_path))
        assert result.returncode == 0
        # Orphan message still in place
        assert (teams / "default" / "inboxes" / "someone" / "msg_001.json").exists()
