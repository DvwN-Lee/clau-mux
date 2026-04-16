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


HOOKS = Path(__file__).resolve().parent.parent / "hooks"


def test_hook_team_create_emits_team_created(tmp_path, monkeypatch):
    import subprocess
    payload = json.dumps({
        "hook_event_name": "PostToolUse",
        "session_id": "s-1",
        "tool_name": "TeamCreate",
        "tool_input": {"team_name": "demo"},
        "tool_response": {"team_name": "demo", "team_file_path": "/tmp/demo/config.json"},
    })
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run(
        ["python3", str(HOOKS / "emit_tool_event.py")],
        input=payload, text=True, env=env, capture_output=True,
    )
    assert r.returncode == 0, r.stderr
    lines = (tmp_path / ".claude" / "clmux" / "events.jsonl").read_text().splitlines()
    recs = [json.loads(l) for l in lines]
    team_events = [r for r in recs if r["event"] == "team.created"]
    assert len(team_events) == 1
    assert team_events[0]["team_name"] == "demo"
    assert team_events[0]["session_id"] == "s-1"
    assert team_events[0]["source"] == "claude_code"


def test_hook_agent_spawn_emits_registered_and_spawned(tmp_path, monkeypatch):
    import subprocess
    payload = json.dumps({
        "hook_event_name": "PostToolUse",
        "session_id": "s-2",
        "tool_name": "Agent",
        "tool_input": {"subagent_type": "general-purpose", "description": "x",
                       "prompt": "...", "name": "helper-1", "model": "sonnet"},
        "tool_response": {"agent_id": "helper-1@demo"},
    })
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run(
        ["python3", str(HOOKS / "emit_tool_event.py")],
        input=payload, text=True, env=env, capture_output=True,
    )
    assert r.returncode == 0, r.stderr
    recs = [json.loads(l) for l in (tmp_path / ".claude" / "clmux" / "events.jsonl")
            .read_text().splitlines()]
    events = {r["event"] for r in recs}
    assert "teammate.registered" in events
    assert "teammate.spawned" in events


def test_hook_sendmessage_emits_message_sent(tmp_path, monkeypatch):
    import subprocess
    payload = json.dumps({
        "hook_event_name": "PostToolUse",
        "session_id": "s-3",
        "tool_name": "SendMessage",
        "tool_input": {"to": "codex-worker", "message": "hi", "summary": "ping"},
        "tool_response": {"success": True,
                          "routing": {"sender": "team-lead", "target": "@codex-worker"}},
    })
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run(
        ["python3", str(HOOKS / "emit_tool_event.py")],
        input=payload, text=True, env=env, capture_output=True,
    )
    assert r.returncode == 0, r.stderr
    recs = [json.loads(l) for l in (tmp_path / ".claude" / "clmux" / "events.jsonl")
            .read_text().splitlines()]
    send = [r for r in recs if r["event"] == "teammate.message_sent"]
    assert len(send) == 1
    assert send[0]["teammate"] == "codex-worker"
    assert send[0]["args"]["from"] == "team-lead"


def test_hook_tolerates_unknown_tool_name(tmp_path, monkeypatch):
    import subprocess
    payload = json.dumps({
        "hook_event_name": "PostToolUse",
        "session_id": "s-4",
        "tool_name": "SomeFutureTool",
        "tool_input": {},
        "tool_response": {},
    })
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run(
        ["python3", str(HOOKS / "emit_tool_event.py")],
        input=payload, text=True, env=env, capture_output=True,
    )
    assert r.returncode == 0, r.stderr
    assert not (tmp_path / ".claude" / "clmux" / "events.jsonl").exists(), \
        "hook should not emit for tools outside the watchlist"


def test_hook_tolerates_malformed_json(tmp_path, monkeypatch):
    import subprocess
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run(
        ["python3", str(HOOKS / "emit_tool_event.py")],
        input="{not json", text=True, env=env, capture_output=True,
    )
    assert r.returncode == 0, r.stderr


def test_update_pane_emits_teammate_spawned(tmp_path, monkeypatch):
    import subprocess
    team_dir = tmp_path / ".claude" / "teams" / "probe"
    team_dir.mkdir(parents=True)
    env = os.environ.copy()
    env["HOME"] = str(tmp_path)
    r = subprocess.run([
        "python3", str(SCRIPTS / "update_pane.py"),
        str(team_dir), "codex-probe", "%999", "codex-cli", "0",
    ], text=True, env=env, capture_output=True)
    assert r.returncode == 0, r.stderr

    lines = (tmp_path / ".claude" / "clmux" / "events.jsonl").read_text().splitlines()
    recs = [json.loads(l) for l in lines]
    spawned = [r for r in recs if r["event"] == "teammate.spawned" and r["source"] == "update_pane"]
    assert len(spawned) == 1
    s = spawned[0]
    assert s["teammate"] == "codex-probe"
    assert s["backend"] == "external-cli"
    assert s["agent_type"] == "bridge"
    assert s["team_name"] == "probe"
    assert s["args"]["pane_id"] == "%999"
