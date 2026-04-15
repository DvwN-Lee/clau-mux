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


class TestEnvelope:
    def test_make_envelope_assigns_id_and_ts(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-001", from_="%105", to="%128",
            kind="delegate", body={"scope": "x", "success_criteria": "y"},
        )
        assert env["id"].startswith("e-")
        assert env["thread_id"] == "t-001"
        assert env["from"] == "%105"
        assert env["to"] == "%128"
        assert env["kind"] == "delegate"
        assert env["parent_id"] is None
        assert env["body"] == {"scope": "x", "success_criteria": "y"}
        assert env["ts"].endswith("Z")

    def test_validate_delegate_requires_scope_and_criteria(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-002", from_="%105", to="%128",
            kind="delegate", body={"scope": "x"},  # missing success_criteria
        )
        with pytest.raises(orch.EnvelopeError, match="success_criteria"):
            orch.validate_envelope(env)

    def test_validate_report_requires_summary_and_evidence(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-003", from_="%128", to="%105",
            kind="report", body={"summary": "ok"},  # missing evidence
        )
        with pytest.raises(orch.EnvelopeError, match="evidence"):
            orch.validate_envelope(env)

    def test_validate_reject_requires_feedback(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-004", from_="%105", to="%128",
            kind="reject", body={},
        )
        with pytest.raises(orch.EnvelopeError, match="feedback"):
            orch.validate_envelope(env)

    def test_validate_unknown_kind_rejected(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-005", from_="%105", to="%128",
            kind="not_a_real_kind", body={},
        )
        with pytest.raises(orch.EnvelopeError, match="unknown kind"):
            orch.validate_envelope(env)

    def test_validate_happy_path_passes(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-006", from_="%105", to="%128",
            kind="delegate",
            body={"scope": "do x", "success_criteria": "x done"},
        )
        orch.validate_envelope(env)  # no exception

    def test_ack_body_is_optional(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-007", from_="%128", to="%105",
            kind="ack", body={},
        )
        orch.validate_envelope(env)  # no exception

    def test_validate_report_evidence_must_be_list(self, tmp_path, monkeypatch):
        """[M3] evidence declared as evidence[] — must be list, not string."""
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-008", from_="%128", to="%105",
            kind="report",
            body={"summary": "ok", "evidence": "one item as string"},
        )
        with pytest.raises(orch.EnvelopeError, match="evidence.*must be list"):
            orch.validate_envelope(env)

    def test_validate_reject_required_changes_must_be_list(self, tmp_path, monkeypatch):
        """[M3] required_changes[] type enforced."""
        orch = _import_orch(monkeypatch, tmp_path)
        env = orch.make_envelope(
            thread_id="t-009", from_="%105", to="%128",
            kind="reject",
            body={"feedback": "redo", "required_changes": "not a list"},
        )
        with pytest.raises(orch.EnvelopeError, match="required_changes.*must be list"):
            orch.validate_envelope(env)


class TestMasterLock:
    def test_claim_master_when_none(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="main")
        info = orch.current_master()
        assert info["pane_id"] == "%105"
        assert info["label"] == "main"

    def test_claim_master_when_already_held_by_same_pane(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="main")
        # Re-claim by same pane is idempotent
        orch.claim_master("%105", label="main")
        assert orch.current_master()["pane_id"] == "%105"

    def test_claim_master_when_held_by_other_raises(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="a")
        with pytest.raises(orch.MasterLockError, match="held by %105"):
            orch.claim_master("%200", label="b")

    def test_handover_master_transfers(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="a")
        orch.handover_master(from_pane="%105", to_pane="%200", label="b")
        assert orch.current_master()["pane_id"] == "%200"
        assert orch.current_master()["label"] == "b"

    def test_handover_from_wrong_pane_raises(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="a")
        with pytest.raises(orch.MasterLockError, match="not held by %999"):
            orch.handover_master(from_pane="%999", to_pane="%200", label="b")

    def test_release_master(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="a")
        orch.release_master("%105")
        assert orch.current_master() is None

    def test_current_master_none_initially(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        assert orch.current_master() is None

    def test_release_master_force_clears_stale_lock(self, tmp_path, monkeypatch):
        """[H3] force=True recovers a stale lock where metadata is missing."""
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        # Simulate crash after mkdir but before metadata write
        orch._master_lock_dir().mkdir()
        # current_master() treats this as stale (returns None)
        assert orch.current_master() is None
        # Non-force release from a claimant: no-op because current_master is None
        orch.release_master("%105")
        # Lock dir still exists — stale
        assert orch._master_lock_dir().is_dir()
        # Force release clears it
        orch.release_master("%999", force=True)
        assert not orch._master_lock_dir().exists()
        # Now a new pane can claim
        orch.claim_master("%200", label="recovered")
        assert orch.current_master()["pane_id"] == "%200"

    def test_release_master_non_holder_without_force_raises(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_master("%105", label="a")
        with pytest.raises(orch.MasterLockError, match="not held by %999"):
            orch.release_master("%999")


class TestMeetingLock:
    def test_claim_meeting_when_none(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_meeting("m-001", topic="test topic", started_by="%105",
                            team_name="meeting-m-001")
        info = orch.current_meeting()
        assert info["meeting_id"] == "m-001"
        assert info["topic"] == "test topic"
        assert info["team_name"] == "meeting-m-001"

    def test_claim_meeting_while_active_raises(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_meeting("m-001", topic="a", started_by="%105", team_name="t1")
        with pytest.raises(orch.MeetingLockError, match="in progress"):
            orch.claim_meeting("m-002", topic="b", started_by="%105", team_name="t2")

    def test_release_meeting_allows_next(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_meeting("m-001", topic="a", started_by="%105", team_name="t1")
        orch.release_meeting("m-001")
        assert orch.current_meeting() is None
        # Next claim OK
        orch.claim_meeting("m-002", topic="b", started_by="%105", team_name="t2")
        assert orch.current_meeting()["meeting_id"] == "m-002"

    def test_release_meeting_mismatch_is_noop(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.claim_meeting("m-001", topic="a", started_by="%105", team_name="t1")
        orch.release_meeting("m-999")  # wrong id — should be silent no-op
        assert orch.current_meeting()["meeting_id"] == "m-001"


class TestPanes:
    def test_register_pane_stores_entry(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%128", role="sub", master="%105", label="issue-17")
        panes = orch.list_panes()
        assert "%128" in panes
        assert panes["%128"]["role"] == "sub"
        assert panes["%128"]["master_pane"] == "%105"
        assert panes["%128"]["label"] == "issue-17"

    def test_register_pane_updates_last_seen(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%105", role="master", master=None)
        first_seen = orch.list_panes()["%105"]["last_seen"]
        import time; time.sleep(0.01)
        orch.register_pane("%105", role="master", master=None)
        second_seen = orch.list_panes()["%105"]["last_seen"]
        assert second_seen > first_seen

    def test_unregister_pane_removes_entry(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%128", role="sub", master="%105")
        orch.unregister_pane("%128")
        assert "%128" not in orch.list_panes()

    def test_list_panes_empty_initially(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        assert orch.list_panes() == {}


class TestThread:
    def test_open_thread_writes_meta_and_index(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128",
                                parent_thread_id=None, label="root-task")
        assert tid.startswith("t-")
        # thread_meta is first line
        records = orch.read_thread(tid)
        assert records[0]["kind"] == "thread_meta"
        assert records[0]["body"]["delegator"] == "%105"
        assert records[0]["body"]["parent_thread_id"] is None
        assert records[0]["body"]["root"] is True
        # index updated
        idx = orch.read_thread_index()
        assert idx[tid]["state"] == "CREATED"
        assert idx[tid]["delegator"] == "%105"
        assert idx[tid]["assignee"] == "%128"

    def test_child_thread_records_parent(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        parent = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        child = orch.open_thread(delegator="%128", assignee="%200",
                                  parent_thread_id=parent)
        records = orch.read_thread(child)
        assert records[0]["body"]["parent_thread_id"] == parent
        assert records[0]["body"]["root"] is False

    def test_transition_delegate_sets_in_progress_requires_ack(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        # delegate (content of task)
        env = orch.make_envelope(
            thread_id=tid, from_="%105", to="%128",
            kind="delegate", body={"scope": "x", "success_criteria": "y"},
        )
        orch.post_envelope(env)
        assert orch.read_thread_index()[tid]["state"] == "CREATED"
        # ack transitions to IN_PROGRESS
        ack = orch.make_envelope(
            thread_id=tid, from_="%128", to="%105", kind="ack", body={},
        )
        orch.post_envelope(ack)
        assert orch.read_thread_index()[tid]["state"] == "IN_PROGRESS"

    def test_transition_report_then_accept(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        for env_kwargs in [
            {"from_": "%105", "to": "%128", "kind": "delegate",
             "body": {"scope": "x", "success_criteria": "y"}},
            {"from_": "%128", "to": "%105", "kind": "ack", "body": {}},
            {"from_": "%128", "to": "%105", "kind": "report",
             "body": {"summary": "done", "evidence": ["ok"]}},
        ]:
            orch.post_envelope(orch.make_envelope(thread_id=tid, **env_kwargs))
        assert orch.read_thread_index()[tid]["state"] == "REPORTED"
        orch.post_envelope(orch.make_envelope(
            thread_id=tid, from_="%105", to="%128", kind="accept", body={},
        ))
        assert orch.read_thread_index()[tid]["state"] == "ACCEPTED"

    def test_transition_reject_returns_to_in_progress(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        for env_kwargs in [
            {"from_": "%105", "to": "%128", "kind": "delegate",
             "body": {"scope": "x", "success_criteria": "y"}},
            {"from_": "%128", "to": "%105", "kind": "ack", "body": {}},
            {"from_": "%128", "to": "%105", "kind": "report",
             "body": {"summary": "done", "evidence": ["ok"]}},
            {"from_": "%105", "to": "%128", "kind": "reject",
             "body": {"feedback": "not enough tests"}},
        ]:
            orch.post_envelope(orch.make_envelope(thread_id=tid, **env_kwargs))
        assert orch.read_thread_index()[tid]["state"] == "IN_PROGRESS"

    def test_illegal_transition_accept_before_report_raises(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        orch.post_envelope(orch.make_envelope(
            thread_id=tid, from_="%105", to="%128", kind="delegate",
            body={"scope": "x", "success_criteria": "y"},
        ))
        orch.post_envelope(orch.make_envelope(
            thread_id=tid, from_="%128", to="%105", kind="ack", body={},
        ))
        # accept without report should fail
        with pytest.raises(orch.TransitionError, match="IN_PROGRESS"):
            orch.post_envelope(orch.make_envelope(
                thread_id=tid, from_="%105", to="%128", kind="accept", body={},
            ))

    def test_close_thread_sets_closed(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        for env_kwargs in [
            {"from_": "%105", "to": "%128", "kind": "delegate",
             "body": {"scope": "x", "success_criteria": "y"}},
            {"from_": "%128", "to": "%105", "kind": "ack", "body": {}},
            {"from_": "%128", "to": "%105", "kind": "report",
             "body": {"summary": "done", "evidence": ["ok"]}},
            {"from_": "%105", "to": "%128", "kind": "accept", "body": {}},
        ]:
            orch.post_envelope(orch.make_envelope(thread_id=tid, **env_kwargs))
        orch.close_thread(tid, note="user approved")
        assert orch.read_thread_index()[tid]["state"] == "CLOSED"

    def test_close_thread_requires_accepted_state(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        with pytest.raises(orch.TransitionError, match="ACCEPTED"):
            orch.close_thread(tid, note="premature")

    def test_h1_envelope_logged_even_when_transition_fails(self, tmp_path, monkeypatch):
        """[H1] Envelope is appended to JSONL BEFORE transition.
        An illegal transition raises but the envelope stays in the audit
        log — enabling forensics on rejected attempts.
        """
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        tid = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        # Attempt illegal transition: accept in CREATED state
        with pytest.raises(orch.TransitionError):
            orch.post_envelope(orch.make_envelope(
                thread_id=tid, from_="%105", to="%128", kind="accept", body={},
            ))
        # Envelope is still in the audit log
        records = orch.read_thread(tid)
        kinds = [r["kind"] for r in records]
        assert kinds.count("accept") == 1, \
            "H1: illegal envelope must still be logged for audit"
        # Index state unchanged (still CREATED)
        assert orch.read_thread_index()[tid]["state"] == "CREATED"


class TestInbox:
    def test_add_inbox_alert_creates_jsonl(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.add_inbox_alert("%128", {
            "thread_id": "t-001",
            "kind": "delegate",
            "from": "%105",
            "summary": "do x",
        })
        alerts = orch.read_inbox("%128")
        assert len(alerts) == 1
        assert alerts[0]["thread_id"] == "t-001"
        assert "received_at" in alerts[0]

    def test_mark_inbox_read_moves_to_archive(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.add_inbox_alert("%128", {"thread_id": "t-001", "kind": "delegate"})
        orch.add_inbox_alert("%128", {"thread_id": "t-002", "kind": "progress"})
        orch.mark_inbox_read("%128")
        assert orch.read_inbox("%128") == []
        # Archive contains both
        archive_path = tmp_path / ".claude" / "orchestration" / "inbox_archive" / "%128.jsonl"
        archived = [json.loads(l) for l in archive_path.read_text().splitlines() if l.strip()]
        assert len(archived) == 2

    def test_read_inbox_empty_when_none(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        assert orch.read_inbox("%128") == []

    def test_mark_inbox_read_when_empty_is_noop(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.mark_inbox_read("%128")  # no error
        assert orch.read_inbox("%128") == []


class TestNotify:
    def test_notify_pane_invokes_expected_tmux_calls(self, tmp_path, monkeypatch):
        """[B2 amendment per 2026-04-15 cross-review] Must mock shutil.which
        so the test does not depend on tmux being installed on the CI runner.
        Without this mock, CI without tmux returns None → notify_pane exits
        early → no subprocess calls → assertions fail.
        """
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        recorded = []

        # [B2] Fake tmux availability
        monkeypatch.setattr(orch.shutil, "which", lambda cmd: "/usr/bin/tmux")

        def fake_run(args, **kwargs):
            recorded.append(tuple(args))
            class R:
                returncode = 0
                stdout = ""
                stderr = ""
            return R()

        monkeypatch.setattr(orch.subprocess, "run", fake_run)
        # Avoid actually running tmux load-buffer via stdin
        def fake_load(buf, data):
            recorded.append(("load-buffer", buf, len(data)))
        monkeypatch.setattr(orch, "_tmux_load_buffer", fake_load)

        orch.notify_pane("%128", "[orch] thread=t-001 kind=delegate from=%105")

        kinds = [r[0] if isinstance(r, tuple) else r for r in recorded]
        # Expect load-buffer → paste-buffer → send-keys Enter
        assert any("load-buffer" in str(r) for r in recorded)
        assert any("paste-buffer" in str(r) for r in recorded)
        assert any(r for r in recorded if "send-keys" in str(r) and "Enter" in str(r))

    def test_notify_pane_skipped_when_tmux_unavailable(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()

        def fake_which(cmd):
            return None  # tmux not found

        monkeypatch.setattr(orch.shutil, "which", fake_which)
        # Should not raise, just return False
        ok = orch.notify_pane("%128", "hello")
        assert ok is False
