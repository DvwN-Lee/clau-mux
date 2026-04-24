"""Append-only JSONL event log for teammate lifecycle observability.

Schema: one JSON object per line. See
.claude/plans/2026-04-16-teammate-parity-monitoring.md
"Event Schema" section.
"""
import datetime
import json
import os
import sys
from pathlib import Path


def log_dir() -> Path:
    return Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "clmux"


def log_path() -> Path:
    return log_dir() / "events.jsonl"


def ensure_log_dir() -> None:
    log_dir().mkdir(parents=True, exist_ok=True)


_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))
from _filelock import file_lock, sigterm_guard  # noqa: E402

ALLOWED_EVENTS = {
    "teammate.registered", "teammate.spawned",
    "teammate.message_sent", "teammate.message_delivered",
    "teammate.state_changed", "teammate.terminated",
    "team.created", "team.deleted",
}

ALLOWED_SOURCES = {"claude_code", "bridge_daemon", "update_pane"}


class EventSchemaError(ValueError):
    """Raised when emit() receives an event or source not in the allowed set."""


def _now_ts() -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def emit(
    event: str,
    source: str,
    teammate,
    agent_type,
    backend,
    tool,
    args: dict,
    result: dict,
    notes: str,
    *,
    session_id=None,
    team_name=None,
    agent_id=None,
) -> None:
    """Append one canonical event to ~/.claude/clmux/events.jsonl.

    Unknown event/source raise EventSchemaError. All other fields
    accept None (null in JSON). See plan "Event Schema" for semantics.
    """
    if event not in ALLOWED_EVENTS:
        raise EventSchemaError(f"unknown event: {event!r}")
    if source not in ALLOWED_SOURCES:
        raise EventSchemaError(f"unknown source: {source!r}")

    ensure_log_dir()
    path = log_path()

    record = {
        "ts": _now_ts(),
        "event": event,
        "source": source,
        "session_id": session_id,
        "team_name": team_name,
        "teammate": teammate,
        "agent_id": agent_id,
        "agent_type": agent_type,
        "backend": backend,
        "tool": tool,
        "args": args,
        "result": result,
        "notes": notes,
    }
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with file_lock(str(path)):
        with sigterm_guard():
            with open(path, "a", encoding="utf-8") as f:
                f.write(line)
