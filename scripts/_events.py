"""Append-only JSONL event log for teammate lifecycle observability.

Schema: one JSON object per line. See
docs/superpowers/plans/2026-04-16-teammate-parity-monitoring.md
"Event Schema" section.
"""
import os
from pathlib import Path


def log_dir() -> Path:
    return Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "clmux"


def log_path() -> Path:
    return log_dir() / "events.jsonl"


def ensure_log_dir() -> None:
    log_dir().mkdir(parents=True, exist_ok=True)
