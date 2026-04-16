#!/usr/bin/env python3
"""PostToolUse hook — emit a canonical teammate-lifecycle event.

Claude Code invokes this with a JSON payload on stdin:
  { hook_event_name, session_id, tool_name, tool_input, tool_response }

We only care about five tools. Everything else is a no-op. The hook
MUST NOT fail the agent turn — unknown payloads and write failures
are caught, logged to stderr, and swallowed so exit code stays 0.
"""
import json
import sys
import traceback
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_SCRIPTS = _HERE.parent / "scripts"
sys.path.insert(0, str(_SCRIPTS))


def _safe():
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except Exception:
        print(f"[emit_tool_event] malformed JSON input; bytes={len(raw)}", file=sys.stderr)
        return

    tool = payload.get("tool_name")
    if tool not in ("TeamCreate", "TeamDelete", "Agent", "SendMessage", "TaskCreate"):
        return

    try:
        import _events
    except Exception as e:
        print(f"[emit_tool_event] _events import failed: {e}", file=sys.stderr)
        return

    session_id = payload.get("session_id")
    tool_input = payload.get("tool_input", {}) or {}
    tool_response = payload.get("tool_response", {}) or {}

    if tool == "TeamCreate":
        team_name = tool_input.get("team_name") or tool_response.get("team_name")
        _events.emit(
            event="team.created", source="claude_code",
            teammate=None, agent_type=None, backend=None, tool=tool,
            args=tool_input, result=tool_response, notes="",
            session_id=session_id, team_name=team_name,
        )

    elif tool == "TeamDelete":
        team_name = tool_input.get("team_name")
        _events.emit(
            event="team.deleted", source="claude_code",
            teammate=None, agent_type=None, backend=None, tool=tool,
            args=tool_input, result=tool_response, notes="",
            session_id=session_id, team_name=team_name,
        )

    elif tool == "Agent":
        name = tool_input.get("name") or tool_input.get("subagent_type")
        subagent_type = tool_input.get("subagent_type")
        agent_id = tool_response.get("agent_id")
        _events.emit(
            event="teammate.registered", source="claude_code",
            teammate=name, agent_type=subagent_type, backend="in-process",
            tool=tool, args=tool_input, result=tool_response,
            notes="", session_id=session_id, agent_id=agent_id,
        )
        _events.emit(
            event="teammate.spawned", source="claude_code",
            teammate=name, agent_type=subagent_type, backend="in-process",
            tool=tool, args=tool_input, result=tool_response,
            notes="", session_id=session_id, agent_id=agent_id,
        )

    elif tool == "SendMessage":
        to = tool_input.get("to")
        routing = (tool_response.get("routing") or {})
        # [Safeguard] PostToolUse fires after the tool returns; it records the
        # attempt, not whether the write succeeded. Flag tool-level errors so
        # the analyzer can separate them from silently-dropped messages.
        is_error = bool(tool_response.get("is_error"))
        message = tool_input.get("message")
        args = {
            "from": routing.get("sender"),
            "to": to,
            "summary": tool_input.get("summary"),
            "message_chars": len(message) if isinstance(message, str) else None,
            "routing_path": "unknown",
        }
        _events.emit(
            event="teammate.message_sent", source="claude_code",
            teammate=to, agent_type=None, backend=None,
            tool=tool, args=args, result=tool_response,
            notes="send_error" if is_error else "", session_id=session_id,
        )

    elif tool == "TaskCreate":
        _events.emit(
            event="teammate.state_changed", source="claude_code",
            teammate=tool_input.get("assignee"), agent_type=None, backend=None,
            tool=tool, args=tool_input, result=tool_response,
            notes="TaskCreate", session_id=session_id,
        )


try:
    _safe()
except Exception as e:
    print(f"[emit_tool_event] unexpected error: {e}\n{traceback.format_exc()}", file=sys.stderr)

sys.exit(0)
