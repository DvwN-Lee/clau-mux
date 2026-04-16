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
