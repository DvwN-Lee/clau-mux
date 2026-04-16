import json
import os
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"
sys.path.insert(0, str(SCRIPTS))


def _import_events(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    if "_events" in sys.modules:
        del sys.modules["_events"]
    import _events
    return _events


def test_log_dir_created_under_home(tmp_path, monkeypatch):
    events = _import_events(monkeypatch, tmp_path)
    events.ensure_log_dir()
    assert (tmp_path / ".claude" / "clmux").is_dir()
    assert (tmp_path / ".claude" / "clmux" / "events.jsonl").exists() is False


ALLOWED = {
    "teammate.registered", "teammate.spawned",
    "teammate.message_sent", "teammate.message_delivered",
    "teammate.state_changed", "teammate.terminated",
    "team.created", "team.deleted",
}


def test_emit_writes_one_jsonl_line(tmp_path, monkeypatch):
    events = _import_events(monkeypatch, tmp_path)
    events.emit(event="teammate.spawned", source="bridge_daemon",
                teammate="codex-worker", agent_type="bridge",
                backend="external-cli", tool=None,
                args={"pane_id": "%42"}, result={}, notes="")
    lines = (tmp_path / ".claude" / "clmux" / "events.jsonl").read_text().splitlines()
    assert len(lines) == 1
    rec = json.loads(lines[0])
    assert rec["event"] == "teammate.spawned"
    assert rec["source"] == "bridge_daemon"
    assert rec["teammate"] == "codex-worker"
    assert "ts" in rec


def test_emit_rejects_unknown_event(tmp_path, monkeypatch):
    events = _import_events(monkeypatch, tmp_path)
    try:
        events.emit(event="teammate.badname", source="bridge_daemon",
                    teammate="x", agent_type=None, backend=None, tool=None,
                    args={}, result={}, notes="")
    except events.EventSchemaError as e:
        assert "teammate.badname" in str(e)
        return
    raise AssertionError("expected EventSchemaError")


def test_emit_rejects_unknown_source(tmp_path, monkeypatch):
    events = _import_events(monkeypatch, tmp_path)
    try:
        events.emit(event="teammate.spawned", source="random_source",
                    teammate="x", agent_type=None, backend=None, tool=None,
                    args={}, result={}, notes="")
    except events.EventSchemaError as e:
        assert "random_source" in str(e)
        return
    raise AssertionError("expected EventSchemaError")


def test_emit_concurrent_writes_preserve_all(tmp_path, monkeypatch):
    import subprocess
    events = _import_events(monkeypatch, tmp_path)
    procs = []
    for i in range(10):
        p = subprocess.Popen([
            "python3", "-c",
            f"import sys; sys.path.insert(0, '{SCRIPTS}'); "
            f"import os; os.environ['HOME']='{tmp_path}'; "
            f"import _events; _events.emit('teammate.spawned', 'bridge_daemon', "
            f"'c{i}', 'bridge', 'external-cli', None, {{}}, {{}}, '')"
        ])
        procs.append(p)
    for p in procs:
        p.wait()
    lines = (tmp_path / ".claude" / "clmux" / "events.jsonl").read_text().splitlines()
    assert len(lines) == 10
    teammates = {json.loads(l)["teammate"] for l in lines}
    assert teammates == {f"c{i}" for i in range(10)}


def test_emit_null_session_id_and_team_ok(tmp_path, monkeypatch):
    events = _import_events(monkeypatch, tmp_path)
    events.emit(event="team.created", source="claude_code",
                teammate=None, agent_type=None, backend=None,
                tool="TeamCreate", args={"team_name": "x"}, result={},
                notes="", session_id=None, team_name=None)
    lines = (tmp_path / ".claude" / "clmux" / "events.jsonl").read_text().splitlines()
    rec = json.loads(lines[0])
    assert rec["session_id"] is None
    assert rec["team_name"] is None
