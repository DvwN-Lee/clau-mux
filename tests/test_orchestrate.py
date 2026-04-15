import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parent.parent / "scripts"


def _import_orch(monkeypatch, home):
    """Helper to import _orch with HOME pointed at a tmp dir."""
    monkeypatch.setenv("HOME", str(home))
    import importlib, sys
    sys.path.insert(0, str(SCRIPTS))
    if "_orch" in sys.modules:
        del sys.modules["_orch"]
    import _orch
    importlib.reload(_orch)
    return _orch


class TestStorage:
    def test_root_path_uses_home(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        assert orch.root() == tmp_path / ".claude" / "orchestration"

    def test_ensure_layout_creates_all_dirs(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        for sub in ("threads", "meetings", "inbox", "inbox_archive", "state"):
            assert (tmp_path / ".claude" / "orchestration" / sub).is_dir()

    def test_append_thread_writes_one_line(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        record = {"id": "e-abc", "kind": "thread_meta", "thread_id": "t-001"}
        orch.append_thread("t-001", record)
        path = tmp_path / ".claude" / "orchestration" / "threads" / "t-001.jsonl"
        assert path.is_file()
        lines = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        assert len(lines) == 1 and lines[0]["id"] == "e-abc"

    def test_append_thread_is_concurrent_safe(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        # Serialize 10 concurrent writers via file_lock
        procs = [
            subprocess.Popen([
                "python3", "-c",
                f"import sys; sys.path.insert(0, '{SCRIPTS}'); "
                f"import os; os.environ['HOME']='{tmp_path}'; "
                f"import _orch; _orch.ensure_layout(); "
                f"_orch.append_thread('t-conc', {{'id':'e-{i}','kind':'progress','seq':{i}}})"
            ])
            for i in range(10)
        ]
        for p in procs:
            p.wait()
        path = tmp_path / ".claude" / "orchestration" / "threads" / "t-conc.jsonl"
        lines = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
        assert len(lines) == 10
        assert {l["seq"] for l in lines} == set(range(10))

    def test_read_thread_returns_all_records_in_order(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        for i in range(5):
            orch.append_thread("t-read", {"id": f"e-{i}", "seq": i})
        records = orch.read_thread("t-read")
        assert [r["seq"] for r in records] == [0, 1, 2, 3, 4]

    def test_read_thread_missing_returns_empty_list(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        assert orch.read_thread("t-nonexistent") == []

    def test_atomic_json_write_roundtrip(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        # [B2] target must be under orchestration root
        target = orch.root() / "state" / "y.json"
        orch.atomic_json_write(target, {"a": 1, "b": [2, 3]})
        loaded = json.loads(target.read_text())
        assert loaded == {"a": 1, "b": [2, 3]}
        # parent dir auto-created
        assert target.parent.is_dir()

    def test_safe_within_root_rejects_symlink_target(self, tmp_path, monkeypatch):
        """[B2] writes through a symlink are refused with SymlinkEscape."""
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        victim = tmp_path / "victim.json"
        victim.write_text("{}")
        link = orch.root() / "state" / "attack.json"
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(str(victim), str(link))
        with pytest.raises(orch.SymlinkEscape):
            orch.atomic_json_write(link, {"evil": True})
        # victim unchanged
        assert victim.read_text() == "{}"

    def test_safe_within_root_rejects_path_outside_root(self, tmp_path, monkeypatch):
        """[B2] writes to a path escaping root() are refused."""
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        outside = tmp_path / "outside" / "escape.json"
        with pytest.raises(orch.SymlinkEscape):
            orch.atomic_json_write(outside, {"escaped": True})
