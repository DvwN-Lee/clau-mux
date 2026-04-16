import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"


def _seed(tmp_path, lines):
    d = tmp_path / ".claude" / "clmux"
    d.mkdir(parents=True, exist_ok=True)
    (d / "events.jsonl").write_text("\n".join(json.dumps(l) for l in lines) + "\n")


def _run_analyzer(tmp_path):
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run(
        ["python3", str(SCRIPTS / "analyze_events.py"),
         "--output", str(tmp_path / "matrix.md")],
        text=True, env=env, capture_output=True,
    )
    return r


def test_analyzer_produces_matrix_file(tmp_path):
    _seed(tmp_path, [
        {"ts": "2026-04-16T00:00:00.000Z", "event": "team.created",
         "source": "claude_code", "team_name": "demo"},
    ])
    r = _run_analyzer(tmp_path)
    assert r.returncode == 0, r.stderr
    out = (tmp_path / "matrix.md").read_text()
    assert "# Teammate Parity Matrix" in out
    assert "demo" in out


def test_analyzer_lists_native_and_bridge_teammates_separately(tmp_path):
    _seed(tmp_path, [
        {"ts": "2026-04-16T00:00:01.000Z", "event": "team.created",
         "source": "claude_code", "team_name": "t1"},
        {"ts": "2026-04-16T00:00:02.000Z", "event": "teammate.registered",
         "source": "claude_code", "team_name": "t1",
         "teammate": "native-1", "agent_type": "general-purpose",
         "backend": "in-process"},
        {"ts": "2026-04-16T00:00:03.000Z", "event": "teammate.spawned",
         "source": "claude_code", "team_name": "t1",
         "teammate": "native-1", "agent_type": "general-purpose",
         "backend": "in-process"},
        {"ts": "2026-04-16T00:00:04.000Z", "event": "teammate.spawned",
         "source": "update_pane", "team_name": "t1",
         "teammate": "bridge-1", "agent_type": "bridge",
         "backend": "external-cli"},
    ])
    r = _run_analyzer(tmp_path)
    assert r.returncode == 0, r.stderr
    out = (tmp_path / "matrix.md").read_text()
    assert "native-1" in out
    assert "bridge-1" in out
    for col in ("registered", "spawned", "message_sent", "message_delivered",
                "state_changed", "terminated"):
        assert col in out
    assert "—" in out or "-" in out


def test_analyzer_counts_message_drops(tmp_path):
    """A message_sent without a matching message_delivered is a drop."""
    _seed(tmp_path, [
        {"ts": "2026-04-16T00:00:10.000Z", "event": "teammate.message_sent",
         "source": "claude_code", "team_name": "t1",
         "teammate": "bridge-1",
         "args": {"from": "team-lead", "to": "bridge-1"}},
        {"ts": "2026-04-16T00:00:11.000Z", "event": "teammate.message_sent",
         "source": "claude_code", "team_name": "t1",
         "teammate": "native-1",
         "args": {"from": "team-lead", "to": "native-1"}},
        {"ts": "2026-04-16T00:00:11.500Z", "event": "teammate.message_delivered",
         "source": "bridge_daemon", "team_name": "t1",
         "teammate": "native-1"},
    ])
    r = _run_analyzer(tmp_path)
    assert r.returncode == 0, r.stderr
    out = (tmp_path / "matrix.md").read_text()
    assert "Message drop" in out or "drops" in out.lower()
