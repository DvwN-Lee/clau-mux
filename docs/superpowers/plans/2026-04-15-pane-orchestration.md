# Pane Orchestration Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision: v2 (2026-04-15 post-cross-review)** — amended per 4-reviewer cross-review (orch-plan-reviewer / gemini-reviewer / codex-worker / copilot-worker) + user-directed Corporate Hierarchy amendments (A1-A4). 18 amendments applied: 2 blocking (B1 `end_meeting` crash recovery, B2 notify test mock), 4 high (H1 envelope/index ordering, H2 atomic synthesis, H3 stale lock `--force` recovery, H4 lock content moved outside lock dir), 3 medium (M3 list type validation, M6 PermissionError wrapping, M7 mid-delegate documented), 4 corporate (A1 project_root field, A2 Master terminology, A3 Corporate Hierarchy Pattern docs, A4 `--project-root` CLI option), 5 copilot (PR split rationale, GH Actions workflow in PR C, README bullet, version 1.3.0 + CHANGELOG, `_filelock` hard-dep note). See **Phase 2 Roadmap** at the bottom for items intentionally deferred.

**Goal:** 기업형 개발 프로세스(Stage Gate + RACI)를 모방한 pane 간 계층적 위임 프로토콜 구현 — 단일 Master가 사용자와 대화하고, 필요 시 clmux-teams로 meeting을 소집하고, Sub pane에게 작업을 delegate하고, Sub의 report를 검증한 뒤 사용자 승인을 받는 구조. 모든 state가 파일 기반이라 pane 죽어도 resume 가능.

**Architecture:** 세 축으로 분리한다. (1) **Orchestration layer** (pane → pane, 신규 `~/.claude/orchestration/`): thread + envelope JSONL로 delegate/ack/progress/report/accept/reject 기록. (2) **Meeting layer** (pane 내부 consultation, 기존 `clmux-teams` 재활용): 1회성 team 소집 → 종료 시 WORM archive. (3) **Delivery layer**: 기존 tmux `paste-buffer -p` 기반 single-line notification → 수신자는 `clmux-orchestrate inbox`로 전체 envelope 조회. Master 단일성과 meeting 동시 수행 금지는 mkdir-mutex 락으로 enforce.

**Tech Stack:** Python 3 stdlib only (json, os, signal, fcntl, tempfile, argparse, subprocess, datetime, glob), zsh 5, tmux. **Hard dependency**: 기존 `scripts/_filelock.py` (file_lock + sigterm_guard) — `sys.path` 삽입으로 import. `scripts/_filelock.py`가 없거나 import 실패 시 `scripts/_orch.py` import 자체가 실패. clmux-teams 프로토콜은 meeting layer에서 재사용.

**PR strategy:** 3 stacked PRs로 분리한다. Copilot 권고에 따라 **A와 B는 짧은 시간 내에 같은 reviewer가 연속 심의** (페어링 리뷰)하고, C는 작고 focused하게 유지한다.

1. **Core primitives** — Tasks 1-5: storage layout, envelope schema, 두 종류 lock (master/meeting), pane registry, thread state machine. CLI 없이 라이브러리만. 독립 머지는 가능하지만 사용자 가시 효과는 B/C 이후.
2. **Meeting + notify + resume** — Tasks 6-10: paste notification, meeting archive, resume recovery. Python API로 호출 가능 (CLI 없이 Integration test 가능).
3. **CLI + docs + integration + release plumbing** — Tasks 11-15: argparse CLI, zsh wrapper, 문서, e2e integration test, setup 통합, **GH Actions workflow 최소 스텁** (pytest + integration 실행), **README 기능 bullet**, **`package.json` version bump 1.2.0 → 1.3.0 + CHANGELOG entry**.

각 PR은 독립 머지 가능 — PR 1 merge 후에도 기존 clmux는 영향 없음 (신규 디렉토리만 추가됨). 단 PR 순서 의존성: A → B → C (이전 단계 미완 시 다음 단계 의미 없음).

---

## Enterprise Process Mapping (설계 참조)

본 프로토콜이 모방하는 기업 프로세스:

| 요소 | 본 프로토콜 | 기업 analog |
|---|---|---|
| User | Stakeholder | CEO가 보고받는 Board |
| Master pane | Accountable | CEO/VP — 전략 결정, 품질 판정 |
| Sub pane | Responsible | Tech Lead/Manager — 실행 |
| Meeting 참가자 | Consulted | 자문 위원 / 외부 전문가 |
| User 승인 | Sign-off | 경영진 승인 |

**Stage Gate**: Intake → Triage → Scoping → (Meeting?) → Delegation → Execution → Reporting → Review → Approval → Close.

**Audit 불변성**: 모든 envelope는 append-only JSONL에 기록. Meeting archive는 완료 후 `chmod 444`로 WORM.

---

## File Structure

**Create:**
- `scripts/_orch.py` — 전체 helper library (storage / envelope / lock / thread / inbox / meeting / notify / resume)
- `scripts/clmux_orchestrate.py` — argparse CLI entrypoint (subcommands dispatch)
- `tests/test_orchestrate.py` — pytest unit tests (class-grouped)
- `tests/test_orchestrate_integration.sh` — e2e shell integration
- `docs/orchestration.md` — user guide (workflow, CLI reference, enterprise mapping, known limitations)

**Modify:**
- `clmux.zsh` — 신규 `clmux-orchestrate` zsh function (Python CLI에 위임)
- `scripts/setup.sh` — 선택적 `.gitignore` 업데이트 (orchestration 디렉토리는 글로벌 `~/.claude/`에 있으므로 대체로 불필요; 문서만 업데이트)
- `README.md` — `docs/orchestration.md` 링크

**Directory scheme (생성 시점 on demand):**
```
~/.claude/orchestration/
├── master.lock.d/           # mkdir mutex — Master 단일성
│   └── content              # { pane_id, since, label }
├── meeting.lock.d/          # mkdir mutex — 동시 meeting 금지
│   └── content              # { meeting_id, topic, started_by, team_name }
├── panes.json               # registry: { pane_id: {role, master_pane, label, registered_at, last_seen} }
├── threads/
│   ├── <thread_id>.jsonl    # append-only: thread_meta + envelopes
│   └── index.json           # { thread_id: {state, delegator, assignee, parent_thread_id, created_at} }
├── meetings/
│   └── <meeting_id>/        # WORM archive (chmod 444 on end)
│       ├── metadata.json
│       ├── config.json      # team config snapshot
│       ├── outbox.json      # team-lead.json snapshot
│       ├── inboxes/         # per-member inbox snapshots
│       └── synthesis.md     # Master가 작성한 최종 결론
├── inbox/
│   └── <pane_id>.jsonl      # pending notifications (읽으면 archived로 이동)
├── inbox_archive/
│   └── <pane_id>.jsonl      # 읽음 처리된 알림 (audit 용)
└── state/
    └── <pane_id>.json       # { role, master, in_flight_threads, last_resume_at }
```

**Rationale:**
- 단일 `_orch.py`: Phase 1 MVP 범위에서 모듈 분리는 over-engineering. 성장 시 package로 승격.
- `~/.claude/orchestration/` (글로벌): orchestration은 프로젝트 경계를 넘어선 pane 관계. `<lead_cwd>/.claude/clmux/` (debug logging)와 달리 프로젝트-로컬 의미 없음.
- `panes.json`을 하나의 JSON으로 유지: pane 수 적음 (보통 ≤10). 전체 읽기/쓰기로 족함.
- `threads/<id>.jsonl`: append-only, envelope당 한 줄. 감사 불변성 + resume을 위한 재생 가능.
- `meetings/<id>/`: 복수 파일 구조 — team config/outbox/inboxes 스냅샷 + Master synthesis. 종료 후 chmod 444.
- 기존 `_filelock.py`의 `file_lock` 및 `sigterm_guard` 그대로 사용 — 독립 구현하지 않음.

---

## Envelope Schema (canonical, 전 Task 공유)

모든 envelope는 다음 형태의 JSON 객체:

```json
{
  "id": "e-<12 hex>",
  "thread_id": "t-<12 hex>",
  "ts": "2026-04-15T15:00:00.000Z",
  "from": "%105",
  "to": "%128",
  "kind": "delegate|ack|progress|report|accept|reject|thread_meta",
  "parent_id": "e-<12 hex> | null",
  "body": { ... }
}
```

**Kind별 body schema (Phase 1):**

| kind | 필수 body fields | 선택 body fields |
|---|---|---|
| `thread_meta` | `parent_thread_id` (null or t-xxx), `delegator` (pane_id), `root` (bool) | `label` |
| `delegate` | `scope`, `success_criteria` | `non_goals`, `deliverable`, `resources[]`, `urgency`, `consultations[]` |
| `ack` | — | `note` |
| `progress` | `status` | `note` |
| `report` | `summary`, `evidence[]` | `decisions_made[]`, `open_questions[]`, `risks[]`, `consultations[]` |
| `accept` | — | `note` |
| `reject` | `feedback`, `required_changes[]` | `allow_rescope` (bool, default true) |

`thread_meta`는 thread의 첫 줄로 한 번만 기록. 나머지 kind는 append.

Phase 2 예정: `blocked`, `reply`, `progress_heartbeat`.

---

## Thread State Machine (Phase 1)

```
        delegate
user→Master --------→ CREATED
                        │
                      ack (by Sub)
                        ↓
                    IN_PROGRESS
                        │
                 ┌──────┴──────┐
                 │             │
              progress      report
              (loop)           ↓
                 │         REPORTED
                 │             │
                 │      ┌──────┴─────┐
                 │      │            │
                 │    accept       reject
                 │      │            │
                 │   ACCEPTED    (back to IN_PROGRESS)
                 │      │
                 │    user approval (external)
                 │      ↓
                 │    CLOSED
                 ↓
              (state in index.json)
```

Legal transitions (enforced in `_orch.thread.transition()`):
- `CREATED` → `IN_PROGRESS` (via `ack`)
- `IN_PROGRESS` → `IN_PROGRESS` (via `progress`)
- `IN_PROGRESS` → `REPORTED` (via `report`)
- `REPORTED` → `ACCEPTED` (via `accept`)
- `REPORTED` → `IN_PROGRESS` (via `reject`)
- `ACCEPTED` → `CLOSED` (via external `close` call — user 승인 확인 후 Master 수동 close)

불법 전이는 `TransitionError` raise.

---

## Task 1: Storage helpers + thread JSONL writer/reader

**Files:**
- Create: `scripts/_orch.py`
- Test: `tests/test_orchestrate.py` (TestStorage class)

- [ ] **Step 1: Write the failing test**

```python
# tests/test_orchestrate.py
import json
import os
import subprocess
import tempfile
from pathlib import Path

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
        target = tmp_path / "x" / "y.json"
        orch.atomic_json_write(target, {"a": 1, "b": [2, 3]})
        loaded = json.loads(target.read_text())
        assert loaded == {"a": 1, "b": [2, 3]}
        # parent dir auto-created
        assert target.parent.is_dir()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_orchestrate.py::TestStorage -v`
Expected: All 7 tests FAIL with `ModuleNotFoundError: No module named '_orch'`.

- [ ] **Step 3: Implement storage primitives in `scripts/_orch.py`**

```python
"""Pane orchestration protocol helpers.

Single-file helper module for Phase 1 MVP. Split into sub-modules once
the surface stabilizes.

Subsystems:
  - storage : layout management, atomic writes, thread JSONL append/read
  - envelope: schema + validator (Task 2)
  - lock    : master.lock.d + meeting.lock.d (Tasks 3-4)
  - panes   : registration + panes.json CRUD (Task 5)
  - thread  : state machine + transition enforcement (Task 6)
  - inbox   : per-pane pending notifications (Task 7)
  - notify  : tmux paste-buffer alert (Task 8)
  - meeting : lifecycle + WORM archive (Task 9)
  - resume  : in-flight state reconstruction (Task 10)

All filesystem writes reuse _filelock.file_lock + sigterm_guard for
atomicity. JSONL thread files are append-only; corruption of one line
never destroys prior history.
"""
import datetime
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

# Reuse existing primitives
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _filelock import file_lock, sigterm_guard


# ─── storage ────────────────────────────────────────────────────────────────

def root() -> Path:
    """Return the orchestration root directory under $HOME."""
    return Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "orchestration"


def ensure_layout() -> None:
    """Create all subdirectories if missing. Idempotent."""
    r = root()
    for sub in ("threads", "meetings", "inbox", "inbox_archive", "state"):
        (r / sub).mkdir(parents=True, exist_ok=True)


def _now_ts() -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.") + f"{now.microsecond // 1000:03d}Z"


def _rand_id(prefix: str) -> str:
    return f"{prefix}-{secrets.token_hex(6)}"


def atomic_json_write(path: Path, obj) -> None:
    """Write JSON atomically via tempfile + os.replace. Parent auto-created."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with sigterm_guard():
        with tempfile.NamedTemporaryFile(
            mode="w", dir=str(path.parent), delete=False, suffix=".tmp", encoding="utf-8"
        ) as tf:
            json.dump(obj, tf, indent=2, ensure_ascii=False)
            tmp_name = tf.name
        os.replace(tmp_name, path)


def append_thread(thread_id: str, record: dict) -> None:
    """Append a JSONL record to threads/<thread_id>.jsonl under file_lock."""
    path = root() / "threads" / f"{thread_id}.jsonl"
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with file_lock(str(path)):
        with sigterm_guard():
            with open(path, "a", encoding="utf-8") as f:
                f.write(line)


def read_thread(thread_id: str) -> list:
    """Return all records in threads/<thread_id>.jsonl in order. [] if missing."""
    path = root() / "threads" / f"{thread_id}.jsonl"
    if not path.is_file():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            # Skip corrupt lines rather than failing — audit preserves rest
            continue
    return out
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_orchestrate.py::TestStorage -v`
Expected: All 7 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add storage helpers + thread JSONL append/read"
```

---

## Task 2: Envelope schema + validator

**Files:**
- Modify: `scripts/_orch.py` (add envelope section)
- Test: `tests/test_orchestrate.py` (TestEnvelope class)

- [ ] **Step 1: Add failing tests for envelope**

Append to `tests/test_orchestrate.py`:

```python
import pytest


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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestEnvelope -v`
Expected: 7 FAIL with `AttributeError: module '_orch' has no attribute 'make_envelope'`.

- [ ] **Step 3: Add envelope section to `scripts/_orch.py`**

Append at end of `scripts/_orch.py`:

```python
# ─── envelope ───────────────────────────────────────────────────────────────

class EnvelopeError(ValueError):
    """Raised when an envelope fails schema validation."""


# Required body fields per envelope kind. Empty list = no required fields.
_KIND_REQUIRED = {
    "thread_meta": ["parent_thread_id", "delegator", "root"],
    "delegate":    ["scope", "success_criteria"],
    "ack":         [],
    "progress":    ["status"],
    "report":      ["summary", "evidence"],
    "accept":      [],
    "reject":      ["feedback"],
}

# Body fields that MUST be a list (enforced by validator). Docs promise
# array semantics for these; without type enforcement, the CLI can emit
# a string where list is expected and downstream consumers break.
# [M3 amendment per 2026-04-15 cross-review]
_LIST_FIELDS = {
    "report": ["evidence", "decisions_made", "open_questions", "risks",
               "consultations"],
    "reject": ["required_changes"],
    "delegate": ["resources", "consultations"],
}


def make_envelope(thread_id: str, from_: str, to: str, kind: str,
                  body: dict, parent_id=None) -> dict:
    """Construct an envelope dict with auto-generated id and ts."""
    return {
        "id": _rand_id("e"),
        "thread_id": thread_id,
        "ts": _now_ts(),
        "from": from_,
        "to": to,
        "kind": kind,
        "parent_id": parent_id,
        "body": body or {},
    }


def validate_envelope(env: dict) -> None:
    """Raise EnvelopeError if envelope violates schema."""
    # parent_id is optional so not required here, but make_envelope always
    # emits it (default None). validator does not treat its absence as fatal.
    for top in ("id", "thread_id", "ts", "from", "to", "kind", "body"):
        if top not in env:
            raise EnvelopeError(f"missing top-level field: {top}")
    kind = env["kind"]
    if kind not in _KIND_REQUIRED:
        raise EnvelopeError(f"unknown kind: {kind}")
    body = env["body"]
    if not isinstance(body, dict):
        raise EnvelopeError(f"body must be object, got {type(body).__name__}")
    for req in _KIND_REQUIRED[kind]:
        if req not in body:
            raise EnvelopeError(f"{kind} body missing required field: {req}")
    # [M3] Enforce list types on documented array fields so the CLI cannot
    # emit structurally invalid envelopes that pass key-presence checks
    # but break downstream consumers expecting a list.
    for fname in _LIST_FIELDS.get(kind, []):
        if fname in body and not isinstance(body[fname], list):
            raise EnvelopeError(
                f"{kind} body field '{fname}' must be list, got {type(body[fname]).__name__}"
            )
    # reject.allow_rescope defaults true if absent; normalize
    if kind == "reject" and "allow_rescope" not in body:
        body["allow_rescope"] = True
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestEnvelope -v`
Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add envelope schema + validator"
```

---

## Task 3: Master lock (claim + handover)

**Files:**
- Modify: `scripts/_orch.py` (add lock section)
- Test: `tests/test_orchestrate.py` (TestMasterLock class)

- [ ] **Step 1: Add failing tests**

```python
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

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestMasterLock -v`
Expected: 7 FAIL.

- [ ] **Step 3: Add lock section to `scripts/_orch.py`**

Append at end of `scripts/_orch.py`:

```python
# ─── lock (master + meeting) ────────────────────────────────────────────────
#
# Design note [H4 amendment per 2026-04-15 cross-review]:
#   Lock directory (*.lock.d) is PURE MUTEX — empty directory used only for
#   mkdir-atomicity. Metadata (pane_id, since, label, etc.) lives in a
#   SIBLING JSON file (*.lock.meta.json) next to the lock dir. Rationale:
#   atomic_json_write() creates temp files in the target's parent dir; if
#   metadata lived inside the lock dir, a crash during the temp+rename
#   sequence would strand `.tmp-*.json` files inside the lock dir and
#   later rmdir() would fail with ENOTEMPTY — lock stays stuck forever.
#   Keeping the lock dir empty makes rmdir() always succeed.

class MasterLockError(RuntimeError):
    """Raised on master-lock contention / illegal transition."""


class MeetingLockError(RuntimeError):
    """Raised on meeting-lock contention."""


def _master_lock_dir() -> Path:
    return root() / "master.lock.d"


def _master_meta_path() -> Path:
    return root() / "master.lock.meta.json"


def _meeting_lock_dir() -> Path:
    return root() / "meeting.lock.d"


def _meeting_meta_path() -> Path:
    return root() / "meeting.lock.meta.json"


def current_master() -> dict | None:
    """Return current Master info dict, or None if no master claimed.

    Master is "claimed" iff both the lock dir AND the metadata file exist.
    Either missing is treated as stale (see release_master --force).
    """
    if not _master_lock_dir().is_dir():
        return None
    meta = _master_meta_path()
    if not meta.is_file():
        return None
    try:
        return json.loads(meta.read_text(encoding="utf-8"))
    except Exception:
        return None


def claim_master(pane_id: str, label: str = "") -> None:
    """Atomically claim the master role for pane_id. Idempotent for same pane.

    Two-step: mkdir lock dir (atomic), then write metadata (atomic).
    If mkdir succeeds but metadata write fails, a subsequent current_master()
    returns None (metadata missing) and the lock is treated as stale.
    Manual recovery: release_master(pane, force=True).
    """
    ensure_layout()
    lock = _master_lock_dir()
    try:
        lock.mkdir()
    except FileExistsError:
        existing = current_master()
        if existing and existing.get("pane_id") == pane_id:
            return  # idempotent
        holder = existing.get("pane_id", "<unknown>") if existing else "<stale>"
        raise MasterLockError(f"master role held by {holder}")
    atomic_json_write(_master_meta_path(), {
        "pane_id": pane_id,
        "label": label,
        "since": _now_ts(),
    })


def handover_master(from_pane: str, to_pane: str, label: str = "") -> None:
    """Transfer master role from from_pane to to_pane. Requires current holder == from_pane."""
    existing = current_master()
    if not existing:
        raise MasterLockError("no master currently held")
    if existing.get("pane_id") != from_pane:
        raise MasterLockError(f"master not held by {from_pane} (actual: {existing.get('pane_id')})")
    atomic_json_write(_master_meta_path(), {
        "pane_id": to_pane,
        "label": label,
        "since": _now_ts(),
    })


def release_master(pane_id: str, force: bool = False) -> None:
    """Release master role. Only the current holder may release unless force=True.

    [H3 amendment] `force=True` is the stale-lock recovery path: removes
    the lock regardless of holder identity (or missing/corrupt metadata).
    Surfaced via CLI as `clmux-orchestrate release-master --force`.
    """
    existing = current_master()
    if not existing and not force:
        return  # already released
    if existing and not force and existing.get("pane_id") != pane_id:
        raise MasterLockError(f"master not held by {pane_id}")
    meta = _master_meta_path()
    if meta.is_file():
        try:
            meta.unlink()
        except OSError:
            pass
    lock = _master_lock_dir()
    if lock.is_dir():
        try:
            lock.rmdir()
        except OSError:
            # Should not happen since lock dir is kept empty, but if
            # something external dropped a file here, force caller must
            # clean up manually. Surface via exception only if non-force.
            if not force:
                raise MasterLockError(
                    f"cannot remove lock dir {lock}; inspect and rm manually"
                )


def current_meeting() -> dict | None:
    """Return current meeting info dict, or None."""
    if not _meeting_lock_dir().is_dir():
        return None
    meta = _meeting_meta_path()
    if not meta.is_file():
        return None
    try:
        return json.loads(meta.read_text(encoding="utf-8"))
    except Exception:
        return None


def claim_meeting(meeting_id: str, topic: str, started_by: str, team_name: str) -> None:
    """Claim meeting slot. Raises MeetingLockError if another meeting active."""
    ensure_layout()
    lock = _meeting_lock_dir()
    try:
        lock.mkdir()
    except FileExistsError:
        existing = current_meeting()
        holder = existing.get("meeting_id", "<unknown>") if existing else "<stale>"
        raise MeetingLockError(f"another meeting in progress: {holder}")
    atomic_json_write(_meeting_meta_path(), {
        "meeting_id": meeting_id,
        "topic": topic,
        "started_by": started_by,
        "team_name": team_name,
        "started_at": _now_ts(),
    })


def release_meeting(meeting_id: str, force: bool = False) -> None:
    """Release meeting slot. [H3] force=True bypasses id check for stale-lock recovery."""
    existing = current_meeting()
    if not existing and not force:
        return  # nothing to release
    if existing and not force and existing.get("meeting_id") != meeting_id:
        return  # id mismatch, silent no-op unless forced
    meta = _meeting_meta_path()
    if meta.is_file():
        try:
            meta.unlink()
        except OSError:
            pass
    lock = _meeting_lock_dir()
    if lock.is_dir():
        try:
            lock.rmdir()
        except OSError:
            if not force:
                raise MeetingLockError(
                    f"cannot remove lock dir {lock}; inspect and rm manually"
                )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestMasterLock -v`
Expected: 7 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add master/meeting locks with atomic claim/handover"
```

---

## Task 4: Meeting lock tests

**Files:**
- Modify: `tests/test_orchestrate.py` (TestMeetingLock class)

- [ ] **Step 1: Add tests**

```python
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
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestMeetingLock -v`
Expected: 4 PASS (meeting lock implementation is already in place from Task 3's lock section).

- [ ] **Step 3: Commit**

```bash
git add tests/test_orchestrate.py
git commit -m "test(orch): meeting-lock contention tests"
```

---

## Task 5: Pane registry

**Files:**
- Modify: `scripts/_orch.py` (add panes section)
- Test: `tests/test_orchestrate.py` (TestPanes class)

- [ ] **Step 1: Add failing tests**

```python
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

    def test_register_pane_stores_project_root(self, tmp_path, monkeypatch):
        """[A1] project_root field is persisted when provided."""
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%128", role="sub", master="%105",
                            label="exam-main",
                            project_root="/Users/me/Project/exam-project")
        entry = orch.list_panes()["%128"]
        assert entry["project_root"] == "/Users/me/Project/exam-project"

    def test_register_pane_without_project_root_omits_field(self, tmp_path, monkeypatch):
        """[A1] project_root is optional — omitted pane has no key."""
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%105", role="master", master=None)
        entry = orch.list_panes()["%105"]
        assert "project_root" not in entry
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestPanes -v`
Expected: 4 FAIL.

- [ ] **Step 3: Add panes section to `scripts/_orch.py`**

Append at end:

```python
# ─── panes (registry) ───────────────────────────────────────────────────────

def _panes_path() -> Path:
    return root() / "panes.json"


def list_panes() -> dict:
    """Return the panes registry. Empty dict if not yet created."""
    path = _panes_path()
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def register_pane(pane_id: str, role: str, master: str | None = None,
                  label: str = "", project_root: str | None = None) -> None:
    """Add or refresh a pane entry. last_seen always updates to now.

    [A1 amendment per 2026-04-15 Corporate Hierarchy] `project_root` is an
    optional absolute path identifying which project this pane belongs to.
    Used for audit queries ("show all Subs working on /path/to/proj") and
    for distinguishing a Desktop-level Master from Project-level Subs that
    themselves delegate. Stored in panes.json as `project_root` field.
    """
    ensure_layout()
    path = _panes_path()
    with file_lock(str(path)):
        current = list_panes()
        entry = current.get(pane_id, {})
        entry.update({
            "role": role,
            "master_pane": master,
            "label": label or entry.get("label", ""),
            "last_seen": _now_ts(),
        })
        if project_root is not None:
            entry["project_root"] = project_root
        if "registered_at" not in entry:
            entry["registered_at"] = entry["last_seen"]
        current[pane_id] = entry
        atomic_json_write(path, current)


def unregister_pane(pane_id: str) -> None:
    """Remove a pane entry. No error if absent."""
    ensure_layout()
    path = _panes_path()
    with file_lock(str(path)):
        current = list_panes()
        if pane_id in current:
            del current[pane_id]
            atomic_json_write(path, current)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestPanes -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add pane registry (register/list/unregister)"
```

---

## Task 6: Thread state machine

**Files:**
- Modify: `scripts/_orch.py` (add thread section)
- Test: `tests/test_orchestrate.py` (TestThread class)

- [ ] **Step 1: Add failing tests**

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestThread -v`
Expected: 8 FAIL.

- [ ] **Step 3: Add thread section to `scripts/_orch.py`**

Append at end:

```python
# ─── thread (state machine) ─────────────────────────────────────────────────

class TransitionError(RuntimeError):
    """Raised on illegal state transition."""


_ALLOWED_TRANSITIONS = {
    "CREATED":     {"ack": "IN_PROGRESS"},
    "IN_PROGRESS": {"progress": "IN_PROGRESS", "report": "REPORTED"},
    "REPORTED":    {"accept": "ACCEPTED", "reject": "IN_PROGRESS"},
    "ACCEPTED":    {},   # closed via explicit close_thread()
    "CLOSED":      {},
}


def _thread_index_path() -> Path:
    return root() / "threads" / "index.json"


def read_thread_index() -> dict:
    path = _thread_index_path()
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def _write_thread_index(idx: dict) -> None:
    atomic_json_write(_thread_index_path(), idx)


def open_thread(delegator: str, assignee: str,
                parent_thread_id: str | None, label: str = "") -> str:
    """Create a new thread, write thread_meta, initialize index entry.
    Returns the new thread_id.
    """
    ensure_layout()
    tid = _rand_id("t")
    meta_env = make_envelope(
        thread_id=tid, from_=delegator, to=assignee,
        kind="thread_meta",
        body={
            "parent_thread_id": parent_thread_id,
            "delegator": delegator,
            "root": parent_thread_id is None,
            "label": label,
        },
    )
    validate_envelope(meta_env)
    append_thread(tid, meta_env)
    # Update index
    with file_lock(str(_thread_index_path())):
        idx = read_thread_index()
        idx[tid] = {
            "state": "CREATED",
            "delegator": delegator,
            "assignee": assignee,
            "parent_thread_id": parent_thread_id,
            "created_at": meta_env["ts"],
            "updated_at": meta_env["ts"],
        }
        _write_thread_index(idx)
    return tid


def _apply_transition(tid: str, kind: str) -> None:
    """Advance thread state per _ALLOWED_TRANSITIONS. Raise if illegal."""
    with file_lock(str(_thread_index_path())):
        idx = read_thread_index()
        if tid not in idx:
            raise TransitionError(f"unknown thread: {tid}")
        current = idx[tid]["state"]
        allowed = _ALLOWED_TRANSITIONS.get(current, {})
        if kind not in allowed:
            raise TransitionError(
                f"cannot apply {kind} in state {current} (thread {tid})"
            )
        idx[tid]["state"] = allowed[kind]
        idx[tid]["updated_at"] = _now_ts()
        _write_thread_index(idx)


def post_envelope(env: dict) -> None:
    """Validate, append, and (if state-changing) advance thread state.

    [H1 amendment per 2026-04-15 cross-review] Ordering:
      1. validate
      2. append_thread   ← JSONL is source of truth (audit log)
      3. _apply_transition  ← index.json is cache, may lag

    Rationale: if the process crashes between the two writes, a
    JSONL-first order leaves the log with a record that HAS NO
    corresponding index transition (rather than an index transition
    with NO audit record). On recovery, the audit log can be replayed
    to reconstruct correct index state. The reverse order loses the
    causative envelope entirely — unrecoverable drift.

    read_thread() already skips corrupt/partial JSONL lines, so a
    half-written append is bounded damage.
    """
    validate_envelope(env)
    tid = env["thread_id"]
    kind = env["kind"]
    # State-changing kinds (not thread_meta, which is initial marker)
    state_changing = {"ack", "progress", "report", "accept", "reject"}
    # 1) Append to audit log FIRST so the envelope is durable.
    append_thread(tid, env)
    # 2) THEN advance state. If this raises (illegal transition),
    #    the envelope is still logged — caller sees TransitionError,
    #    index remains at previous state. Caller MAY choose to log
    #    the illegal attempt as an audit event separately.
    if kind in state_changing:
        _apply_transition(tid, kind)


def close_thread(tid: str, note: str = "") -> None:
    """Transition ACCEPTED → CLOSED after external user approval."""
    with file_lock(str(_thread_index_path())):
        idx = read_thread_index()
        if tid not in idx:
            raise TransitionError(f"unknown thread: {tid}")
        if idx[tid]["state"] != "ACCEPTED":
            raise TransitionError(
                f"can only close ACCEPTED threads (current: {idx[tid]['state']})"
            )
        idx[tid]["state"] = "CLOSED"
        idx[tid]["updated_at"] = _now_ts()
        idx[tid]["close_note"] = note
        _write_thread_index(idx)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestThread -v`
Expected: 8 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add thread state machine (open/post/close + transitions)"
```

---

## Task 7: Inbox management

**Files:**
- Modify: `scripts/_orch.py` (add inbox section)
- Test: `tests/test_orchestrate.py` (TestInbox class)

- [ ] **Step 1: Add failing tests**

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestInbox -v`
Expected: 4 FAIL.

- [ ] **Step 3: Add inbox section to `scripts/_orch.py`**

Append at end:

```python
# ─── inbox ──────────────────────────────────────────────────────────────────

def _inbox_path(pane_id: str) -> Path:
    return root() / "inbox" / f"{pane_id}.jsonl"


def _inbox_archive_path(pane_id: str) -> Path:
    return root() / "inbox_archive" / f"{pane_id}.jsonl"


def add_inbox_alert(pane_id: str, alert: dict) -> None:
    """Append a notification alert to pane's inbox (pending)."""
    ensure_layout()
    record = dict(alert)
    record["received_at"] = _now_ts()
    path = _inbox_path(pane_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with file_lock(str(path)):
        with sigterm_guard():
            with open(path, "a", encoding="utf-8") as f:
                f.write(line)


def read_inbox(pane_id: str) -> list:
    """Return pending alerts (not yet marked read). Preserves order."""
    path = _inbox_path(pane_id)
    if not path.is_file():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def mark_inbox_read(pane_id: str) -> None:
    """Move all pending alerts to archive. Inbox cleared."""
    ensure_layout()
    path = _inbox_path(pane_id)
    archive = _inbox_archive_path(pane_id)
    archive.parent.mkdir(parents=True, exist_ok=True)
    with file_lock(str(path)):
        if not path.is_file():
            return
        content = path.read_text(encoding="utf-8")
        if not content.strip():
            path.unlink()
            return
        with sigterm_guard():
            with open(archive, "a", encoding="utf-8") as af:
                af.write(content)
            path.unlink()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestInbox -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add inbox management (add/read/mark_read → archive)"
```

---

## Task 8: Paste notification (tmux integration)

**Files:**
- Modify: `scripts/_orch.py` (add notify section)
- Test: `tests/test_orchestrate.py` (TestNotify class)

- [ ] **Step 1: Add failing tests**

The notify function invokes `tmux load-buffer` + `paste-buffer -p` + `send-keys Enter`. We test behavior by mocking subprocess calls.

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestNotify -v`
Expected: 2 FAIL.

- [ ] **Step 3: Add notify section to `scripts/_orch.py`**

Append at end:

```python
# ─── notify (tmux paste-buffer) ─────────────────────────────────────────────

import shutil
import subprocess


def _tmux_load_buffer(buf_name: str, data: str) -> None:
    """Pipe data to `tmux load-buffer -b <buf_name> -`."""
    subprocess.run(
        ["tmux", "load-buffer", "-b", buf_name, "-"],
        input=data.encode("utf-8"),
        check=True,
    )


def notify_pane(target_pane: str, message: str, buf_prefix: str = "orch") -> bool:
    """Paste a single-line alert into target_pane followed by Enter.

    Uses `paste-buffer -p` (bracketed paste) so newlines remain literal
    and a runaway message can't inject multiple keypresses.

    Returns True on success, False if tmux is unavailable.
    """
    if shutil.which("tmux") is None:
        return False
    buf = f"{buf_prefix}-{os.getpid()}-{secrets.token_hex(4)}"
    try:
        _tmux_load_buffer(buf, message)
        subprocess.run(
            ["tmux", "paste-buffer", "-d", "-p", "-b", buf, "-t", target_pane],
            check=True,
        )
        subprocess.run(
            ["tmux", "send-keys", "-t", target_pane, "Enter"],
            check=True,
        )
        return True
    except subprocess.CalledProcessError:
        return False
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestNotify -v`
Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add tmux paste-buffer notify helper"
```

---

## Task 9: Meeting lifecycle + WORM archive

**Files:**
- Modify: `scripts/_orch.py` (add meeting section)
- Test: `tests/test_orchestrate.py` (TestMeeting class)

- [ ] **Step 1: Add failing tests**

```python
class TestMeeting:
    def test_start_meeting_creates_lock_and_returns_id(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        mid = orch.start_meeting(started_by="%105", topic="test",
                                  team_name="meeting-t1")
        assert mid.startswith("m-")
        assert orch.current_meeting()["meeting_id"] == mid

    def test_end_meeting_archives_team_and_releases_lock(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        # Simulate a clmux team directory
        team_dir = tmp_path / ".claude" / "teams" / "meeting-t2"
        (team_dir / "inboxes").mkdir(parents=True)
        (team_dir / "config.json").write_text(
            json.dumps({"name": "meeting-t2", "members": [
                {"name": "codex", "agentType": "bridge"}
            ]})
        )
        (team_dir / "inboxes" / "team-lead.json").write_text(
            json.dumps([{"from": "codex", "text": "hello"}])
        )
        (team_dir / "inboxes" / "codex.json").write_text("[]")

        mid = orch.start_meeting(started_by="%105", topic="topic 2",
                                  team_name="meeting-t2")
        orch.end_meeting(mid, synthesis="Decision: do X")

        # Lock released
        assert orch.current_meeting() is None
        # Archive exists
        archive = tmp_path / ".claude" / "orchestration" / "meetings" / mid
        assert (archive / "config.json").is_file()
        assert (archive / "outbox.json").is_file()
        assert (archive / "inboxes" / "codex.json").is_file()
        assert (archive / "metadata.json").is_file()
        assert (archive / "synthesis.md").read_text().startswith("Decision")

    def test_end_meeting_archive_is_worm_readonly(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        team_dir = tmp_path / ".claude" / "teams" / "meeting-t3"
        (team_dir / "inboxes").mkdir(parents=True)
        (team_dir / "config.json").write_text('{"name":"meeting-t3"}')
        (team_dir / "inboxes" / "team-lead.json").write_text("[]")

        mid = orch.start_meeting(started_by="%105", topic="t3", team_name="meeting-t3")
        orch.end_meeting(mid, synthesis="sy")

        archive = tmp_path / ".claude" / "orchestration" / "meetings" / mid
        # Each archived file is 0o444 (read-only)
        for f in ["config.json", "outbox.json", "synthesis.md", "metadata.json"]:
            path = archive / f
            assert path.is_file()
            assert oct(path.stat().st_mode)[-3:] == "444"

    def test_end_meeting_unknown_id_raises(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        with pytest.raises(orch.MeetingLockError, match="no active meeting"):
            orch.end_meeting("m-nonexistent", synthesis="")
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestMeeting -v`
Expected: 4 FAIL.

- [ ] **Step 3: Add meeting section to `scripts/_orch.py`**

Append at end:

```python
# ─── meeting (lifecycle + WORM archive) ─────────────────────────────────────

import shutil as _shutil   # avoid shadowing earlier `shutil` import


def _teams_dir() -> Path:
    return Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "teams"


def start_meeting(started_by: str, topic: str, team_name: str) -> str:
    """Claim the meeting lock and return a new meeting_id.

    Caller is responsible for actually creating the clmux team
    (via TeamCreate) and adding bridges. This function only manages
    the orchestration-side lock + id.
    """
    mid = _rand_id("m")
    claim_meeting(mid, topic=topic, started_by=started_by, team_name=team_name)
    return mid


def _atomic_write_text(path: Path, text: str) -> None:
    """[H2] Write text atomically via tempfile + os.replace.

    Required for any archive file that will later be chmodded to 0o444.
    A non-atomic write (write_text) plus chmod sequence can leave a
    partial file permanently read-only if the process crashes mid-write.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with sigterm_guard():
        with tempfile.NamedTemporaryFile(
            mode="w", dir=str(path.parent), delete=False, suffix=".tmp",
            encoding="utf-8"
        ) as tf:
            tf.write(text)
            tmp_name = tf.name
        os.replace(tmp_name, path)


def end_meeting(meeting_id: str, synthesis: str) -> None:
    """Archive the meeting team to WORM and release the lock.

    Archive layout:
      meetings/<meeting_id>/
        metadata.json   — {meeting_id, topic, started_by, started_at, ended_at, team_name, participants}
        config.json     — team config snapshot
        outbox.json     — team-lead.json outbox snapshot
        inboxes/        — per-member inbox snapshots
        synthesis.md    — master's written conclusion

    [B1 amendment per 2026-04-15 cross-review] Redesigned ordering:

      Phase 1 — WRITE everything atomically (no chmod):
        config.json, outbox.json, inboxes/*, metadata.json, synthesis.md
        All writes use _atomic_write_text or _shutil.copy2 (already atomic
        via rename on same filesystem).

      Phase 2 — VERIFY writability before chmod:
        Confirm all target files are still writable by our user (not
        accidentally restricted by umask or prior partial run).

      Phase 3 — CHMOD 444 in a single final pass:
        Once the archive is complete, apply read-only in one loop.

      Phase 4 — RELEASE lock:
        Only after chmod succeeds. If crash occurs in phases 1-3, the
        lock is still held and retry is safe (all writes are atomic and
        idempotent; chmod is idempotent).

    Rationale: the previous design wrote synthesis non-atomically and
    intermixed chmod with writes. A crash after even one chmod 444 could
    leave a partially-locked archive where subsequent retries would fail
    with PermissionError — meeting_lock permanently wedged.

    Crash recovery: if end_meeting crashes between phases, caller may
    retry `end_meeting(same_id, same_synthesis)`. If the lock is wedged
    and recovery fails, operator uses `release_meeting(id, force=True)`.
    """
    current = current_meeting()
    if not current or current.get("meeting_id") != meeting_id:
        raise MeetingLockError(f"no active meeting with id {meeting_id}")

    team_name = current["team_name"]
    team_dir = _teams_dir() / team_name
    archive_dir = root() / "meetings" / meeting_id
    archive_dir.mkdir(parents=True, exist_ok=True)

    # ── Phase 1: atomic writes ─────────────────────────────────────────
    cfg_src = team_dir / "config.json"
    cfg_dst = archive_dir / "config.json"
    if cfg_src.is_file():
        _shutil.copy2(cfg_src, cfg_dst)  # shutil copy2 is atomic-rename-equivalent
    else:
        _atomic_write_text(cfg_dst, '{"warning":"source config missing"}')

    outbox_src = team_dir / "inboxes" / "team-lead.json"
    outbox_dst = archive_dir / "outbox.json"
    if outbox_src.is_file():
        _shutil.copy2(outbox_src, outbox_dst)
    else:
        _atomic_write_text(outbox_dst, "[]")

    # Member inboxes
    inboxes_dst = archive_dir / "inboxes"
    inboxes_dst.mkdir(exist_ok=True)
    inboxes_src = team_dir / "inboxes"
    participants: list = []
    member_dsts: list = []
    if inboxes_src.is_dir():
        for member_inbox in sorted(inboxes_src.glob("*.json")):
            if member_inbox.name == "team-lead.json":
                continue
            dst = inboxes_dst / member_inbox.name
            _shutil.copy2(member_inbox, dst)
            participants.append(member_inbox.stem)
            member_dsts.append(dst)

    # Metadata
    meta = {
        "meeting_id": meeting_id,
        "topic": current["topic"],
        "started_by": current["started_by"],
        "started_at": current["started_at"],
        "ended_at": _now_ts(),
        "team_name": team_name,
        "participants": participants,
    }
    meta_dst = archive_dir / "metadata.json"
    atomic_json_write(meta_dst, meta)

    # Synthesis — was non-atomic in v1; now atomic [H2]
    synthesis_dst = archive_dir / "synthesis.md"
    _atomic_write_text(synthesis_dst, synthesis or "")

    # ── Phase 2: writability verification ──────────────────────────────
    all_files = [cfg_dst, outbox_dst, meta_dst, synthesis_dst] + member_dsts
    for f in all_files:
        if not f.is_file():
            raise RuntimeError(f"archive integrity check failed: {f} missing")
        # If any file is already read-only from a partial prior run,
        # restore writability before the final chmod pass so os.chmod
        # itself cannot fail mid-loop.
        try:
            os.chmod(f, 0o644)
        except OSError as e:
            raise RuntimeError(
                f"cannot restore writability on {f}: {e} — "
                f"use release_meeting(id, force=True) to recover"
            )

    # ── Phase 3: single chmod 444 pass ─────────────────────────────────
    for f in all_files:
        os.chmod(f, 0o444)

    # ── Phase 4: release lock (only after archive is durable + immutable)
    release_meeting(meeting_id)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestMeeting -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add meeting start/end with WORM archive"
```

---

## Task 10: Resume logic (in-flight state recovery)

**Files:**
- Modify: `scripts/_orch.py` (add resume section)
- Test: `tests/test_orchestrate.py` (TestResume class)

- [ ] **Step 1: Add failing tests**

```python
class TestResume:
    def test_resume_pane_with_no_history_returns_empty(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        state = orch.resume_pane("%105")
        assert state["pane_id"] == "%105"
        assert state["role"] is None
        assert state["in_flight_threads"] == []
        assert state["pending_alerts"] == []

    def test_resume_pane_detects_in_flight_threads_as_master(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%105", role="master", master=None, label="main")
        # Open two threads: one IN_PROGRESS, one CLOSED
        t1 = orch.open_thread(delegator="%105", assignee="%128", parent_thread_id=None)
        t2 = orch.open_thread(delegator="%105", assignee="%200", parent_thread_id=None)
        orch.post_envelope(orch.make_envelope(
            thread_id=t1, from_="%105", to="%128", kind="delegate",
            body={"scope":"x","success_criteria":"y"}))
        orch.post_envelope(orch.make_envelope(
            thread_id=t1, from_="%128", to="%105", kind="ack", body={}))
        # t2 completes
        orch.post_envelope(orch.make_envelope(
            thread_id=t2, from_="%105", to="%200", kind="delegate",
            body={"scope":"x","success_criteria":"y"}))
        orch.post_envelope(orch.make_envelope(
            thread_id=t2, from_="%200", to="%105", kind="ack", body={}))
        orch.post_envelope(orch.make_envelope(
            thread_id=t2, from_="%200", to="%105", kind="report",
            body={"summary":"done","evidence":["x"]}))
        orch.post_envelope(orch.make_envelope(
            thread_id=t2, from_="%105", to="%200", kind="accept", body={}))
        orch.close_thread(t2, note="approved")

        state = orch.resume_pane("%105")
        assert state["role"] == "master"
        # Only t1 is in-flight (t2 is CLOSED)
        assert t1 in state["in_flight_threads"]
        assert t2 not in state["in_flight_threads"]

    def test_resume_pane_surfaces_pending_alerts(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%128", role="sub", master="%105")
        orch.add_inbox_alert("%128", {"thread_id": "t-xxx", "kind": "delegate"})
        state = orch.resume_pane("%128")
        assert len(state["pending_alerts"]) == 1

    def test_resume_pane_updates_state_file(self, tmp_path, monkeypatch):
        orch = _import_orch(monkeypatch, tmp_path)
        orch.ensure_layout()
        orch.register_pane("%105", role="master", master=None)
        orch.resume_pane("%105")
        state_file = tmp_path / ".claude" / "orchestration" / "state" / "%105.json"
        assert state_file.is_file()
        persisted = json.loads(state_file.read_text())
        assert persisted["pane_id"] == "%105"
        assert "last_resume_at" in persisted
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestResume -v`
Expected: 4 FAIL.

- [ ] **Step 3: Add resume section to `scripts/_orch.py`**

Append at end:

```python
# ─── resume ─────────────────────────────────────────────────────────────────

_IN_FLIGHT_STATES = {"CREATED", "IN_PROGRESS", "REPORTED"}


def _state_path(pane_id: str) -> Path:
    return root() / "state" / f"{pane_id}.json"


def resume_pane(pane_id: str) -> dict:
    """Rebuild a pane's in-flight state from persistent stores.

    Collects:
      - role (from panes.json)
      - in_flight_threads: threads where this pane is delegator or assignee
        AND state is not CLOSED/ACCEPTED
      - pending_alerts: current inbox contents

    Persists a snapshot at state/<pane_id>.json for audit.
    """
    ensure_layout()
    panes = list_panes()
    entry = panes.get(pane_id, {})
    role = entry.get("role")
    master = entry.get("master_pane")

    idx = read_thread_index()
    in_flight = [
        tid for tid, meta in idx.items()
        if meta["state"] in _IN_FLIGHT_STATES
        and (meta["delegator"] == pane_id or meta["assignee"] == pane_id)
    ]

    pending = read_inbox(pane_id)

    state = {
        "pane_id": pane_id,
        "role": role,
        "master": master,
        "in_flight_threads": in_flight,
        "pending_alerts": pending,
        "last_resume_at": _now_ts(),
    }
    atomic_json_write(_state_path(pane_id), state)
    return state
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m pytest tests/test_orchestrate.py::TestResume -v`
Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_orch.py tests/test_orchestrate.py
git commit -m "feat(orch): add resume_pane for in-flight state recovery"
```

> **[M7] Known limitation — mid-delegate crash alert loss.**
> If a Master crashes between `post_envelope(delegate)` (JSONL durable) and `notify_pane` (tmux paste), the Sub's inbox still has the alert record (it was written before notify_pane), but the Sub's pane never received the visual paste. `resume_pane(sub)` reports the pending inbox entry, so the alert is recoverable by human inspection. A future enhancement (Phase 2) can extend `resume_pane(master)` to detect `state == CREATED` threads whose assignee inbox has no corresponding `notified_at` marker and re-emit the paste. For Phase 1: documented in `docs/orchestration.md` "Known limitations".

---

## Task 11: CLI (clmux_orchestrate.py)

**Files:**
- Create: `scripts/clmux_orchestrate.py`
- Test: `tests/test_orchestrate.py` (TestCLI class)

- [ ] **Step 1: Add failing tests**

```python
class TestCLI:
    CLI = SCRIPTS / "clmux_orchestrate.py"

    def _run(self, tmp_path, *args, stdin=None):
        env = os.environ.copy()
        env["HOME"] = str(tmp_path)
        return subprocess.run(
            ["python3", str(self.CLI), *args],
            env=env, input=stdin, text=True, capture_output=True,
        )

    def test_cli_help_lists_subcommands(self, tmp_path):
        r = self._run(tmp_path, "--help")
        assert r.returncode == 0
        out = r.stdout
        for sub in ("set-master", "handover", "release-master",
                    "register-sub", "delegate",
                    "ack", "progress", "report", "accept", "reject", "close",
                    "meeting", "inbox", "thread", "panes", "resume"):
            assert sub in out

    def test_cli_register_sub_accepts_project_root(self, tmp_path):
        """[A4] --project-root records which worktree the Sub serves."""
        self._run(tmp_path, "set-master", "--pane", "%105", "--label", "main")
        r = self._run(tmp_path, "register-sub",
                      "--pane", "%128", "--master", "%105",
                      "--label", "impl",
                      "--project-root", "/tmp/worktrees/feat-x",
                      "--json")
        assert r.returncode == 0, r.stderr
        r2 = self._run(tmp_path, "panes", "--json")
        data = json.loads(r2.stdout)
        assert data["%128"]["project_root"] == "/tmp/worktrees/feat-x"

    def test_cli_release_master_force_clears_stuck_lock(self, tmp_path):
        """[H3] --force bypasses ownership check (crash recovery)."""
        self._run(tmp_path, "set-master", "--pane", "%105", "--label", "main")
        # Caller is a different pane; without --force this would fail
        r = self._run(tmp_path, "release-master", "--pane", "%999", "--force", "--json")
        assert r.returncode == 0, r.stderr
        r2 = self._run(tmp_path, "panes", "--json")
        # Master entry cleared (or release recorded with force flag)
        out = json.loads(r.stdout)
        assert out["force"] is True

    def test_cli_set_master_and_current_master(self, tmp_path):
        r1 = self._run(tmp_path, "set-master", "--pane", "%105", "--label", "main")
        assert r1.returncode == 0, r1.stderr
        # panes show %105 as master
        r2 = self._run(tmp_path, "panes", "--json")
        data = json.loads(r2.stdout)
        assert "%105" in data
        assert data["%105"]["role"] == "master"

    def test_cli_delegate_creates_thread(self, tmp_path):
        self._run(tmp_path, "set-master", "--pane", "%105", "--label", "main")
        self._run(tmp_path, "register-sub", "--pane", "%128",
                  "--master", "%105", "--label", "impl")
        r = self._run(tmp_path, "delegate",
                      "--from", "%105", "--to", "%128",
                      "--scope", "do x", "--criteria", "x done",
                      "--json")
        assert r.returncode == 0, r.stderr
        out = json.loads(r.stdout)
        assert out["thread_id"].startswith("t-")
        # Inbox of %128 has one alert
        r2 = self._run(tmp_path, "inbox", "--pane", "%128", "--json")
        alerts = json.loads(r2.stdout)
        assert len(alerts) == 1
        assert alerts[0]["kind"] == "delegate"

    def test_cli_thread_shows_history(self, tmp_path):
        self._run(tmp_path, "set-master", "--pane", "%105", "--label", "main")
        self._run(tmp_path, "register-sub", "--pane", "%128", "--master", "%105")
        r = self._run(tmp_path, "delegate",
                      "--from", "%105", "--to", "%128",
                      "--scope", "x", "--criteria", "y", "--json")
        tid = json.loads(r.stdout)["thread_id"]
        r2 = self._run(tmp_path, "thread", "--id", tid, "--json")
        records = json.loads(r2.stdout)
        kinds = [rec["kind"] for rec in records]
        assert "thread_meta" in kinds and "delegate" in kinds

    def test_cli_resume_prints_in_flight(self, tmp_path):
        self._run(tmp_path, "set-master", "--pane", "%105", "--label", "main")
        self._run(tmp_path, "register-sub", "--pane", "%128", "--master", "%105")
        self._run(tmp_path, "delegate",
                  "--from", "%105", "--to", "%128",
                  "--scope", "x", "--criteria", "y")
        r = self._run(tmp_path, "resume", "--pane", "%105", "--json")
        state = json.loads(r.stdout)
        assert state["role"] == "master"
        assert len(state["in_flight_threads"]) == 1
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m pytest tests/test_orchestrate.py::TestCLI -v`
Expected: 6 FAIL with "No such file or directory: scripts/clmux_orchestrate.py".

- [ ] **Step 3: Implement `scripts/clmux_orchestrate.py`**

```python
#!/usr/bin/env python3
"""CLI for the pane orchestration protocol.

Subcommands:
  set-master       — claim master role for a pane
  handover         — transfer master role atomically
  release-master   — release master role (held by caller)
  register-sub     — register a pane as a sub of a given master
  delegate         — master → sub task assignment (creates thread)
  ack              — sub acknowledges receipt of delegation
  progress         — sub reports progress
  report           — sub delivers final result with evidence
  accept           — master accepts a sub's report
  reject           — master rejects with feedback
  close            — master closes an accepted thread
  meeting          — subcommands: start, end
  inbox            — show/mark-read pending alerts for a pane
  thread           — show full history of a thread
  panes            — list registered panes
  resume           — reconstruct a pane's in-flight state

Every sub-command accepts --json for machine-readable output.
"""
import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _orch


def _emit(data, as_json: bool):
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        if isinstance(data, str):
            print(data)
        else:
            print(json.dumps(data, ensure_ascii=False, indent=2))


def cmd_set_master(args):
    _orch.claim_master(args.pane, label=args.label or "")
    _orch.register_pane(args.pane, role="master", master=None, label=args.label or "")
    _emit({"master": _orch.current_master()}, args.json)


def cmd_handover(args):
    _orch.handover_master(from_pane=args.from_pane, to_pane=args.to_pane,
                          label=args.label or "")
    _orch.register_pane(args.to_pane, role="master", master=None, label=args.label or "")
    _emit({"master": _orch.current_master()}, args.json)


def cmd_release_master(args):
    # [H3] --force lets operators clear a stuck lock after crash recovery
    _orch.release_master(args.pane, force=bool(args.force))
    _emit({"released": args.pane, "force": bool(args.force)}, args.json)


def cmd_register_sub(args):
    # [A4] project_root is optional — records which worktree this Sub serves
    _orch.register_pane(
        args.pane, role="sub", master=args.master,
        label=args.label or "", project_root=args.project_root,
    )
    _emit({"registered": args.pane, "project_root": args.project_root}, args.json)


def cmd_delegate(args):
    tid = _orch.open_thread(delegator=args.from_pane, assignee=args.to_pane,
                             parent_thread_id=args.parent, label=args.label or "")
    body = {"scope": args.scope, "success_criteria": args.criteria}
    if args.non_goals:
        body["non_goals"] = args.non_goals
    if args.deliverable:
        body["deliverable"] = args.deliverable
    if args.urgency:
        body["urgency"] = args.urgency
    env = _orch.make_envelope(
        thread_id=tid, from_=args.from_pane, to=args.to_pane,
        kind="delegate", body=body,
    )
    _orch.post_envelope(env)
    _orch.add_inbox_alert(args.to_pane, {
        "thread_id": tid, "kind": "delegate", "from": args.from_pane,
        "summary": args.scope[:80],
    })
    # Best-effort tmux notification (requires tmux)
    _orch.notify_pane(args.to_pane, f"[orch] new delegate thread={tid} from={args.from_pane} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": tid, "envelope_id": env["id"]}, args.json)


def cmd_ack(args):
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="ack", body={"note": args.note or ""},
    )
    _orch.post_envelope(env)
    _emit({"thread_id": args.thread, "state": _orch.read_thread_index()[args.thread]["state"]},
          args.json)


def cmd_progress(args):
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="progress", body={"status": args.status, "note": args.note or ""},
    )
    _orch.post_envelope(env)
    _emit({"thread_id": args.thread, "status": args.status}, args.json)


def cmd_report(args):
    evidence = args.evidence or []
    body = {"summary": args.summary, "evidence": evidence}
    if args.risks:
        body["risks"] = args.risks
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="report", body=body,
    )
    _orch.post_envelope(env)
    _orch.add_inbox_alert(args.to_pane, {
        "thread_id": args.thread, "kind": "report", "from": args.from_pane,
        "summary": args.summary[:80],
    })
    _orch.notify_pane(args.to_pane, f"[orch] report thread={args.thread} from={args.from_pane} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "envelope_id": env["id"],
           "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_accept(args):
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="accept", body={"note": args.note or ""},
    )
    _orch.post_envelope(env)
    _orch.notify_pane(args.to_pane, f"[orch] ACCEPT thread={args.thread} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_reject(args):
    body = {"feedback": args.feedback}
    if args.required_changes:
        body["required_changes"] = args.required_changes
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="reject", body=body,
    )
    _orch.post_envelope(env)
    _orch.notify_pane(args.to_pane, f"[orch] REJECT thread={args.thread} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_close(args):
    _orch.close_thread(args.thread, note=args.note or "")
    _emit({"thread_id": args.thread, "state": "CLOSED"}, args.json)


def cmd_meeting_start(args):
    mid = _orch.start_meeting(started_by=args.pane, topic=args.topic,
                              team_name=args.team)
    _emit({"meeting_id": mid}, args.json)


def cmd_meeting_end(args):
    synthesis = args.synthesis
    if args.synthesis_file:
        synthesis = Path(args.synthesis_file).read_text(encoding="utf-8")
    _orch.end_meeting(args.meeting_id, synthesis=synthesis or "")
    _emit({"meeting_id": args.meeting_id, "status": "archived"}, args.json)


def cmd_meeting_release(args):
    # [H3] --force teardown after crash leaves lock stuck
    _orch.release_meeting(args.meeting_id, force=bool(args.force))
    _emit({"meeting_id": args.meeting_id, "released": True,
           "force": bool(args.force)}, args.json)


def cmd_inbox(args):
    pending = _orch.read_inbox(args.pane)
    if args.mark_read and pending:
        _orch.mark_inbox_read(args.pane)
    _emit(pending, args.json)


def cmd_thread(args):
    records = _orch.read_thread(args.id)
    _emit(records, args.json)


def cmd_panes(args):
    _emit(_orch.list_panes(), args.json)


def cmd_resume(args):
    _emit(_orch.resume_pane(args.pane), args.json)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="clmux-orchestrate",
                                description="Pane orchestration protocol CLI")
    p.add_argument("--json", action="store_true", help="JSON output")
    sub = p.add_subparsers(dest="cmd", required=True)

    # Master
    sp = sub.add_parser("set-master"); sp.add_argument("--pane", required=True); sp.add_argument("--label"); sp.set_defaults(func=cmd_set_master)
    sp = sub.add_parser("handover"); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--label"); sp.set_defaults(func=cmd_handover)
    sp = sub.add_parser("release-master")
    sp.add_argument("--pane", required=True)
    sp.add_argument("--force", action="store_true",
                    help="[H3] clear lock even if held by a different pane (crash recovery)")
    sp.set_defaults(func=cmd_release_master)

    # Sub
    sp = sub.add_parser("register-sub")
    sp.add_argument("--pane", required=True)
    sp.add_argument("--master", required=True)
    sp.add_argument("--label")
    sp.add_argument("--project-root", dest="project_root",
                    help="[A4] worktree path this Sub serves (Corporate Hierarchy 'Squad')")
    sp.set_defaults(func=cmd_register_sub)

    # Thread lifecycle
    sp = sub.add_parser("delegate")
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--scope", required=True)
    sp.add_argument("--criteria", required=True)
    sp.add_argument("--non-goals", dest="non_goals")
    sp.add_argument("--deliverable")
    sp.add_argument("--urgency", choices=["blocker", "high", "normal", "low"])
    sp.add_argument("--parent", help="parent thread id (for sub-recursion)")
    sp.add_argument("--label")
    sp.set_defaults(func=cmd_delegate)

    sp = sub.add_parser("ack"); sp.add_argument("--thread", required=True); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_ack)

    sp = sub.add_parser("progress"); sp.add_argument("--thread", required=True); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--status", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_progress)

    sp = sub.add_parser("report")
    sp.add_argument("--thread", required=True)
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--summary", required=True)
    sp.add_argument("--evidence", action="append", help="repeatable evidence string")
    sp.add_argument("--risks", action="append")
    sp.set_defaults(func=cmd_report)

    sp = sub.add_parser("accept"); sp.add_argument("--thread", required=True); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_accept)

    sp = sub.add_parser("reject")
    sp.add_argument("--thread", required=True)
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--feedback", required=True)
    sp.add_argument("--required-changes", dest="required_changes", action="append")
    sp.set_defaults(func=cmd_reject)

    sp = sub.add_parser("close"); sp.add_argument("--thread", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_close)

    # Meeting
    sp = sub.add_parser("meeting")
    msub = sp.add_subparsers(dest="meeting_cmd", required=True)
    sps = msub.add_parser("start"); sps.add_argument("--pane", required=True); sps.add_argument("--topic", required=True); sps.add_argument("--team", required=True); sps.set_defaults(func=cmd_meeting_start)
    spe = msub.add_parser("end"); spe.add_argument("--meeting-id", dest="meeting_id", required=True); spe.add_argument("--synthesis"); spe.add_argument("--synthesis-file", dest="synthesis_file"); spe.set_defaults(func=cmd_meeting_end)
    spr = msub.add_parser("release")
    spr.add_argument("--meeting-id", dest="meeting_id", required=True)
    spr.add_argument("--force", action="store_true",
                     help="[H3] clear meeting lock after crash (skips ownership check)")
    spr.set_defaults(func=cmd_meeting_release)

    # Queries
    sp = sub.add_parser("inbox"); sp.add_argument("--pane", required=True); sp.add_argument("--mark-read", dest="mark_read", action="store_true"); sp.set_defaults(func=cmd_inbox)
    sp = sub.add_parser("thread"); sp.add_argument("--id", required=True); sp.set_defaults(func=cmd_thread)
    sp = sub.add_parser("panes"); sp.set_defaults(func=cmd_panes)
    sp = sub.add_parser("resume"); sp.add_argument("--pane", required=True); sp.set_defaults(func=cmd_resume)

    return p


def main(argv=None):
    p = build_parser()
    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run CLI tests**

Run: `python3 -m pytest tests/test_orchestrate.py::TestCLI -v`
Expected: 6 PASS.

- [ ] **Step 5: Run full test suite**

Run: `python3 -m pytest tests/test_orchestrate.py -v`
Expected: ~61 tests PASS (Storage 7 + Envelope 8 + MasterLock 8 + MeetingLock 5 + Panes 5 + Thread 9 + Inbox 4 + Notify 2 + Meeting 5 + Resume 4 + CLI 8 = 65). Count grows modestly in v2 due to new list-validation, `force=True`, project_root, and H1 ordering tests.

- [ ] **Step 6: Commit**

```bash
git add scripts/clmux_orchestrate.py tests/test_orchestrate.py
git commit -m "feat(orch): add clmux_orchestrate.py CLI (argparse subcommands)"
```

---

## Task 12: zsh wrapper

**Files:**
- Modify: `clmux.zsh` — append wrapper function

- [ ] **Step 1: Add `clmux-orchestrate` function**

Append to `clmux.zsh` near other public functions (e.g., after `clmux-debug` or near `clmux-teammates`):

```zsh
# ── clmux-orchestrate ─────────────────────────────────────────────────────────
# Thin wrapper that forwards to scripts/clmux_orchestrate.py with the
# CLMUX_DIR root discovered at first call.
clmux-orchestrate() {
  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/scripts/clmux_orchestrate.py" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/scripts/clmux_orchestrate.py" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/scripts/clmux_orchestrate.py" ]] || {
    echo "error: cannot find clau-mux directory" >&2; return 1;
  }
  python3 "$CLMUX_DIR/scripts/clmux_orchestrate.py" "$@"
}
```

- [ ] **Step 2: Syntax check**

Run: `zsh -n /Users/idongju/Desktop/Git/clau-mux/clmux.zsh && echo "OK"`
Expected: `OK`.

- [ ] **Step 3: Manual smoke**

```bash
source /Users/idongju/Desktop/Git/clau-mux/clmux.zsh
clmux-orchestrate --help
```

Expected: CLI help listing all subcommands.

- [ ] **Step 4: Commit**

```bash
git add clmux.zsh
git commit -m "feat(orch): add clmux-orchestrate zsh wrapper"
```

---

## Task 13: End-to-end integration test

**Files:**
- Create: `tests/test_orchestrate_integration.sh`

- [ ] **Step 1: Write the test script**

```bash
#!/usr/bin/env bash
# tests/test_orchestrate_integration.sh
#
# Exercises the full master → sub flow without tmux.
# Uses an isolated HOME so the test never touches the user's real
# orchestration state.
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export HOME="$tmpdir"
CLI="python3 $CLMUX_DIR/scripts/clmux_orchestrate.py"

# Step 1: master claim
$CLI set-master --pane "%105" --label "test-main"
[[ "$($CLI panes --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["%105"]["role"])')" == "master" ]] || { echo "FAIL: master not registered"; exit 1; }

# Step 2: register sub
$CLI register-sub --pane "%128" --master "%105" --label "test-sub"

# Step 3: delegate
tid=$($CLI delegate --from "%105" --to "%128" \
      --scope "test task" --criteria "done when asserted" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])')
echo "delegated thread: $tid"

# Step 4: %128 inbox has one alert
alerts=$($CLI inbox --pane "%128" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$alerts" == "1" ]] || { echo "FAIL: %128 inbox size != 1 ($alerts)"; exit 1; }

# Step 5: sub acks
$CLI ack --thread "$tid" --from "%128" --to "%105"

# Step 6: sub reports
$CLI report --thread "$tid" --from "%128" --to "%105" \
  --summary "all good" --evidence "test passed"

state=$($CLI thread --id "$tid" --json | python3 -c 'import json,sys; kinds=[r["kind"] for r in json.load(sys.stdin)]; print(",".join(kinds))')
echo "thread kinds: $state"
[[ "$state" == *"thread_meta"* && "$state" == *"delegate"* && "$state" == *"ack"* && "$state" == *"report"* ]] \
  || { echo "FAIL: thread events missing"; exit 1; }

# Step 7: master accepts
$CLI accept --thread "$tid" --from "%105" --to "%128"

# Step 8: master closes
$CLI close --thread "$tid" --note "test approved"

# Step 9: resume shows no in-flight for %105
inflight=$($CLI resume --pane "%105" --json \
         | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["in_flight_threads"]))')
[[ "$inflight" == "0" ]] || { echo "FAIL: %105 still has in-flight threads ($inflight)"; exit 1; }

# Step 10: meeting lifecycle
# Pre-create a fake team dir that end_meeting will archive
mkdir -p "$tmpdir/.claude/teams/meeting-it1/inboxes"
echo '{"name":"meeting-it1","members":[{"name":"codex","agentType":"bridge"}]}' \
  > "$tmpdir/.claude/teams/meeting-it1/config.json"
echo '[]' > "$tmpdir/.claude/teams/meeting-it1/inboxes/team-lead.json"
echo '[]' > "$tmpdir/.claude/teams/meeting-it1/inboxes/codex.json"

mid=$($CLI meeting start --pane "%105" --topic "test meeting" --team "meeting-it1" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["meeting_id"])')
echo "meeting: $mid"

# Meeting should be locked
if $CLI meeting start --pane "%105" --topic "second" --team "meeting-it2" --json 2>/dev/null; then
  echo "FAIL: concurrent meeting should have been rejected"; exit 1
fi

$CLI meeting end --meeting-id "$mid" --synthesis "Decision: merge"

# Archive exists and is WORM
archive="$tmpdir/.claude/orchestration/meetings/$mid"
[[ -f "$archive/metadata.json" ]] || { echo "FAIL: archive metadata missing"; exit 1; }
mode=$(stat -f '%Mp%Lp' "$archive/metadata.json" 2>/dev/null || stat -c '%a' "$archive/metadata.json")
[[ "$mode" == *"444" ]] || { echo "FAIL: archive not WORM (mode=$mode)"; exit 1; }

echo "PASS: full orchestration cycle + meeting archive"
```

Make executable:

```bash
chmod +x tests/test_orchestrate_integration.sh
```

- [ ] **Step 2: Run the integration test**

Run: `bash tests/test_orchestrate_integration.sh`
Expected: final `PASS: full orchestration cycle + meeting archive`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_orchestrate_integration.sh
git commit -m "test(orch): end-to-end integration script"
```

---

## Task 14: Documentation

**Files:**
- Create: `docs/orchestration.md`
- Modify: `README.md` — add link

- [ ] **Step 1: Write `docs/orchestration.md`**

```markdown
← [README](../README.md)

# Pane Orchestration Protocol

A single-layer protocol for **hierarchical delegation** across Claude Code panes. Inspired by corporate stage-gate processes. One Master pane talks to the user; it delegates work to Sub panes (which may use their own clmux-teams internally) and validates their reports before forwarding to the user for sign-off.

> **[A2] Terminology — "Master" is the role held by the current user-facing pane.**
> The lock in `~/.claude/orchestration/master.lock.d/` is *singular globally* (only one Master may exist at a time on this machine). This Master may be the Desktop-level top pane, a Project-level main pane, or any pane — the protocol doesn't care about hierarchy depth. The **Corporate Hierarchy Pattern** (below) is a *recommendation* for how teams typically organize Masters in nested worktrees; the protocol itself enforces only global singularity. See [A3] for the recommended pattern and transfer flow.

## Roles

| Role | Responsibility | Enforcement |
|---|---|---|
| **User** | final approval | (external) |
| **Master** | strategy, meeting synthesis, quality gate, user-facing summary | **single pane only, globally** (`master.lock.d`) |
| **Sub** | execution, may spawn sub-subs, may consult own clmux-teams | registered under a Master |
| **Meeting participants** | consultation only | existing clmux-teams protocol |

## [A3] Corporate Hierarchy Pattern (recommended org model)

The protocol enforces *one Master at a time* but doesn't prescribe *where* the Master lives. In practice we recommend the following three-tier layout, which maps cleanly onto `git worktree` isolation and clmux-teams delegation:

```
Desktop / Top-level          ← Master (pane %105)      — user-facing, highest strategic view
  └─ Project "clau-mux"/     ← Sub (pane %128)         — registered with --project-root $REPO_ROOT
       └─ Worktree "feat-x"/ ← Sub-Sub / "Squad" (%200) — registered with --project-root $WORKTREE
       └─ Worktree "feat-y"/ ← Sub-Sub / "Squad" (%240)
  └─ Project "other-repo"/   ← Sub (pane %160)
```

**Master transfer (handover) walk-down.** If the user moves focus to a project-level pane and wants it to become the new Master, run:

```bash
clmux-orchestrate handover --from %105 --to %128 --label clau-mux-main
```

This is an atomic swap: `%105` loses Master role, `%128` gains it, and the lock record is updated. In-flight threads delegated from `%105` remain open — the new Master can `thread --id <tid>` to review them and either `accept`/`reject` or `close` with note "handover cleanup".

**Why this pattern.**
- Each worktree becomes a "Squad" with its own registered Sub pane, so `panes.json` carries `project_root` (A4) — later queries can filter "all in-flight threads assigned to panes in worktree X" when diagnosing workflow leaks across worktrees.
- Recursion is unbounded by design (Sub-Subs are just Subs with a `parent_thread_id`), so deeper hierarchies (org → department → squad → task-force) are representable without protocol changes.
- The global Master lock prevents two panes from *both* thinking they're the top of the hierarchy. Conflicts surface immediately instead of corrupting shared `threads/index.json`.

**When NOT to use this pattern.**
- Single-worktree short-lived sessions: just use one Master pane, skip Sub registration entirely.
- Cross-machine work: `~/.claude/orchestration/` is machine-local. Use separate Masters on separate machines; no attempt at distributed consensus.

## Directory layout

```
~/.claude/orchestration/
├── master.lock.d/           # who is Master right now
├── meeting.lock.d/          # only one meeting may be active
├── panes.json               # registry {pane: role, master, label}
├── threads/<id>.jsonl       # append-only audit, one envelope per line
├── threads/index.json       # {thread_id: {state, delegator, assignee, parent, ts}}
├── meetings/<id>/           # WORM archive (chmod 444 on archive)
├── inbox/<pane>.jsonl       # pending alerts per pane
├── inbox_archive/<pane>.jsonl
└── state/<pane>.json        # resume snapshot
```

## Envelope kinds (Phase 1)

| kind | direction | required body |
|---|---|---|
| `thread_meta` | — | parent_thread_id, delegator, root |
| `delegate` | Master → Sub | scope, success_criteria |
| `ack` | Sub → Master | — |
| `progress` | Sub → Master | status |
| `report` | Sub → Master | summary, evidence[] |
| `accept` | Master → Sub | — |
| `reject` | Master → Sub | feedback |

Phase 2 additions (not implemented yet): `blocked`, `reply`, `progress_heartbeat`.

## Workflow

1. **User talks to Master.** Master claims the lock:
   ```bash
   clmux-orchestrate set-master --pane "$TMUX_PANE" --label main
   ```
2. **Optional meeting.** Master calls in teammates for consultation:
   ```bash
   # Create a clmux team manually (or via skill)
   # Then mark it as an orchestration meeting:
   mid=$(clmux-orchestrate meeting start --pane "$TMUX_PANE" \
         --topic "paste strategy" --team meeting-paste-01 --json \
       | jq -r .meeting_id)
   # ... run clmux-teams protocol ...
   clmux-orchestrate meeting end --meeting-id "$mid" \
         --synthesis "Decision: pluggable paste strategy, start minimal"
   ```
   Meeting archive lives under `~/.claude/orchestration/meetings/<mid>/` and is read-only (WORM).
3. **Delegate.** Master picks a Sub pane:
   ```bash
   clmux-orchestrate register-sub --pane %128 --master %105 --label impl
   tid=$(clmux-orchestrate delegate --from %105 --to %128 \
         --scope "implement pluggable paste" \
         --criteria "gemini/codex/copilot all work + 1 strategy added" \
         --json | jq -r .thread_id)
   ```
   A single-line alert is pasted into `%128`'s pane via `tmux paste-buffer -p`.
4. **Sub acknowledges and executes.** Sub uses its own clmux-teams for implementation if needed.
   ```bash
   clmux-orchestrate ack --thread $tid --from %128 --to %105
   # ... do the work ...
   clmux-orchestrate report --thread $tid --from %128 --to %105 \
         --summary "pluggable interface added" \
         --evidence "PR #99" --evidence "tests pass"
   ```
5. **Master reviews.** Accept or reject:
   ```bash
   # Accept:
   clmux-orchestrate accept --thread $tid --from %105 --to %128
   # Or reject with feedback (returns to IN_PROGRESS):
   clmux-orchestrate reject --thread $tid --from %105 --to %128 \
         --feedback "codex strategy missing"
   ```
6. **User sign-off.** Master summarizes for user, who approves verbally. Master closes:
   ```bash
   clmux-orchestrate close --thread $tid --note "user approved"
   ```

## Resume

If a pane dies, anyone can recover its in-flight state:

```bash
clmux-orchestrate resume --pane %128
```

This reads `panes.json`, filters `threads/index.json` for threads where `%128` is delegator or assignee AND state is not CLOSED/ACCEPTED, and persists a snapshot at `state/%128.json`.

## Sub recursion

A Sub may delegate to its own Sub by using `--parent <parent_thread_id>`:

```bash
clmux-orchestrate delegate --from %128 --to %200 \
      --scope "deeper investigation" \
      --criteria "root cause identified" \
      --parent t-abc --json
```

The new thread's `thread_meta` records `parent_thread_id: t-abc` — use `thread --id <root>` and traverse the index to reconstruct the tree.

## RACI mapping

| Activity | Responsible | Accountable | Consulted | Informed |
|---|---|---|---|---|
| Execution | Sub | Master | Meeting participants | User |
| Decision | Master | Master | Meeting participants | User |
| Approval | User | User | Master | — |
| Audit | (automated) | Master | — | User |

## [M4] WORM semantics — reality check

The meeting archive is **advisory read-only**, not tamper-proof.

- `chmod 0o444` prevents *accidental* overwrite by the orchestration process and most interactive shell commands. It is the appropriate hygiene level for a dev-machine audit log.
- **It does NOT prevent:** a determined user from running `chmod u+w` + overwrite, `rm -rf`, or editing files with tools that ignore permission bits (e.g., root, `sudo`, cross-filesystem move). On macOS, `chflags uchg` could harden this further but is not part of Phase 1.
- **It does NOT prevent** the archive from disappearing if `~/.claude/` is wiped, the disk dies, or a user manually deletes the directory.
- Treat the archive the way you'd treat `.git/logs/HEAD` — a local audit trail useful for reconstruction, not a compliance artifact.

If stronger guarantees are needed in Phase 2, options include: (1) signed content hashes in `threads/index.json`, (2) git-commit the archive to a tracked docs branch, (3) forward to an external append-only store (e.g., an S3 bucket with object lock). Phase 1 ships just advisory chmod.

## Known limitations

- **No `blocked` / `reply` state yet.** If Sub needs clarification, use informal channel for now. Phase 2 will add `blocked` + `reply` with state-machine transitions.
- **No automatic meeting audit CLI.** The archive is persistent and readable, but there's no `clmux-orchestrate meetings list/show` yet. Inspect with `ls ~/.claude/orchestration/meetings/` and `cat <id>/synthesis.md`.
- **No cascade cancel.** A rejected parent thread does NOT auto-cancel child threads; Sub should handle that manually if needed.
- **Master stale detection is manual.** If a Master pane dies without releasing, another pane can't automatically take over. Recovery path: `clmux-orchestrate release-master --pane <dead> --force` (a crash-recovery flag added in Phase 1 v2 for exactly this case).
- **Meeting lock stuck after crash.** Same failure mode for meetings. Recovery: `clmux-orchestrate meeting release --meeting-id <id> --force`.
- **Tmux paste-buffer is best-effort.** If tmux is unavailable, `notify_pane` silently returns False; the alert is still recorded in `inbox/<pane>.jsonl` and can be pulled with `clmux-orchestrate inbox --pane <pane>`.
- **Mid-delegate crash — alert paste not retried.** If Master crashes between JSONL durability and tmux paste, the inbox record exists but the Sub pane never flashed. `resume_pane` surfaces the pending alert, but a human must inspect it. Phase 2: auto-replay unpasted alerts on resume.
- **`project_root` is advisory only.** Recorded for operator tooling and future filtering; protocol does not enforce that a Sub with `project_root=/a/b` only operates on files under `/a/b`.
- **No schema versioning.** Envelopes don't carry a `schema_version`. Adding new required body fields will break validation of old records on replay. Phase 2: add `version` field and compat shim.
- **Cross-project / cross-machine** — `~/.claude/orchestration/` is global to one machine and one HOME. No distributed coordination.
- **Single Master globally.** This is by design (prevents split-brain). If you need two concurrent Masters for two independent workflows, run them under two OS users (two HOMEs) or on two machines.
```

- [ ] **Step 2: Add README link**

Find existing docs section in `README.md` and append:

```markdown
- [Pane Orchestration](docs/orchestration.md) — master/sub hierarchical delegation, meeting archive, resume
```

- [ ] **Step 3: Commit**

```bash
git add docs/orchestration.md README.md
git commit -m "docs(orch): add orchestration protocol user guide"
```

---

## Task 15: Final smoke + PR prep

**Files:**
- Modify: `package.json` (version bump)
- Modify: `CHANGELOG.md` (add entry)
- Create: `.github/workflows/orchestrate.yml` (CI stub)
- Modify: `README.md` (add top-level bullet)

- [ ] **Step 1: Bump version + CHANGELOG**

Edit `package.json`:

```diff
-  "version": "1.2.0",
+  "version": "1.3.0",
```

Prepend to `CHANGELOG.md` (or create if absent):

```markdown
## 1.3.0 — 2026-04-15

### Added
- **Pane orchestration protocol (Phase 1 MVP)** — hierarchical Master/Sub delegation across Claude Code panes, with thread-level audit (JSONL), meeting 1-off with WORM archive, and resume-across-sessions. CLI: `clmux-orchestrate` (set-master, handover, register-sub, delegate, ack, progress, report, accept, reject, close, meeting {start,end,release}, inbox, thread, panes, resume). See `docs/orchestration.md`.
- **Corporate Hierarchy Pattern** documented for Desktop → Project → Worktree org layouts; `register-sub --project-root` records which worktree each Sub serves.
- **Crash-recovery flags** — `release-master --force` and `meeting release --force` for clearing stuck locks after pane death.

### Tests
- `tests/test_orchestrate.py` — ~65 unit tests across storage, envelope, lock, panes, thread, inbox, notify, meeting, resume, CLI.
- `tests/test_orchestrate_integration.sh` — end-to-end shell test covering full delegate→ack→report→accept→close cycle plus meeting archive.

### Known limitations (Phase 2 candidates)
See `docs/orchestration.md` "Known limitations". No `blocked`/`reply` state yet, no cascade cancel, no cross-machine coordination, advisory-only WORM semantics.
```

- [ ] **Step 2: Add README top-level bullet**

In `README.md`, find the feature list and append:

```markdown
- **Pane Orchestration** (Phase 1) — hierarchical Master/Sub delegation protocol with thread-level audit, meeting archive, and resume. See [`docs/orchestration.md`](docs/orchestration.md).
```

- [ ] **Step 3: Add CI workflow stub**

Create `.github/workflows/orchestrate.yml`:

```yaml
name: orchestrate

on:
  pull_request:
    paths:
      - 'scripts/_orch.py'
      - 'scripts/clmux_orchestrate.py'
      - 'tests/test_orchestrate*'
      - '.github/workflows/orchestrate.yml'
  push:
    branches: [main]
    paths:
      - 'scripts/_orch.py'
      - 'scripts/clmux_orchestrate.py'
      - 'tests/test_orchestrate*'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - name: Install tmux (for integration test)
        run: sudo apt-get update && sudo apt-get install -y tmux
      - name: Unit tests
        run: python3 -m pytest tests/test_orchestrate.py -v
      - name: Integration test
        run: bash tests/test_orchestrate_integration.sh
        timeout-minutes: 2
```

- [ ] **Step 4: Full test suite**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_orchestrate.py -v`
Expected: all unit tests PASS (~65).

- [ ] **Step 5: Integration script**

Run: `bash tests/test_orchestrate_integration.sh`
Expected: `PASS: full orchestration cycle + meeting archive`.

- [ ] **Step 6: Manual smoke in a real tmux session**

```bash
source /Users/idongju/Desktop/Git/clau-mux/clmux.zsh
clmux-orchestrate set-master --pane "$TMUX_PANE" --label main --json
# Open another tmux pane in this repo; inside that pane, note its %id (say %XXX)
clmux-orchestrate register-sub --pane "%XXX" --master "$TMUX_PANE" --label smoke
tid=$(clmux-orchestrate delegate --from "$TMUX_PANE" --to "%XXX" \
      --scope "smoke delegate" --criteria "observe alert" --json | jq -r .thread_id)
```

Expected: `%XXX` receives a single-line alert in its pane.

- [ ] **Step 7: Push and open PR**

Decision point: this plan produces ~65 unit tests and ~1100 lines of code. If reviewers prefer 3 stacked PRs (per the header), split as follows:

- **PR A (Tasks 1-5)**: `scripts/_orch.py` (storage + envelope + lock + panes) + matching tests. No CLI yet. ~25 tests.
- **PR B (Tasks 6-10)**: `scripts/_orch.py` (thread + inbox + notify + meeting + resume) + matching tests. ~32 tests.
- **PR C (Tasks 11-15)**: `scripts/clmux_orchestrate.py` + zsh wrapper + integration test + docs + version bump + CI. ~8 tests + 1 integration + CHANGELOG/README/workflow.

Or land as a single PR:

```bash
git push -u origin <your-branch>
gh pr create --base main --head <your-branch> \
      --title "feat(orch): pane orchestration protocol (Phase 1 MVP)" \
      --body "$(cat <<'EOF'
Implements Phase 1 of the pane orchestration protocol (see docs/orchestration.md).

## Scope
- Master singular (lock), Sub recursion, Resume across sessions
- Meeting 1-off + WORM archive; concurrent meetings forbidden
- Envelope schema (delegate/ack/progress/report/accept/reject)
- Enterprise stage-gate alignment

## Tests
- Unit: tests/test_orchestrate.py (~57 tests)
- Integration: tests/test_orchestrate_integration.sh (end-to-end)

## Known limitations
See docs/orchestration.md "Known limitations".
EOF
)"
```

---

## Phase 2 Roadmap

Explicit non-goals for Phase 1, queued for Phase 2 prioritization:

| Item | Motivation | Estimated Scope |
|---|---|---|
| `blocked` / `reply` state machine | Sub formally asks Master a question and blocks; Master replies, Sub resumes. Removes the out-of-band channel dependency. | +2 envelope kinds, +2 state transitions, +~8 tests |
| Mid-delegate alert auto-replay | On `resume_pane(master)`, detect CREATED threads whose inbox entry has no `notified_at` and re-paste. Closes the M7 gap. | +`notified_at` field, +replay logic, +2 tests |
| Meeting audit CLI | `meeting list` / `meeting show <id>` subcommands; optionally `meeting search --topic <pattern>`. | +3 CLI subcommands, +3 tests |
| Cascade cancel | On `reject` of a parent thread, auto-emit `reject` to direct child threads (opt-in via flag). | +recursive traversal, +3 tests |
| Progress heartbeat + stale-Sub detection | Sub emits `progress_heartbeat` every N minutes; Master detects absence and surfaces in `resume_pane` / `panes --stale`. | +kind + timer + query, +4 tests |
| Master stale auto-takeover | Automate `release-master --force` via pane-liveness check (tmux `has-pane`). Removes manual cleanup for most crashes. | +liveness probe + `master claim --if-stale`, +3 tests |
| Schema versioning | Add `schema_version` to envelope root; add compat shim for reading older records. | +1 field, +shim, +2 tests |
| Claude Code slash / skill integration | `/orch` slash command and a `clmux-orchestration` skill entry to guide Masters through claim/delegate/close flows. | +skill manifest, +slash handler |
| Stronger WORM (optional) | macOS `chflags uchg` on archive + optional signed hashes in index. | +platform probe, +hash field |
| Cross-project query filters | `panes --project-root <path>`, `thread --project-root <path>` for auditing worktree-scoped work. | +CLI filter, +2 tests |

Sequencing suggestion: `blocked/reply` first (unblocks bidirectional flow), then mid-delegate replay + stale-Master auto-takeover (crash hardening), then meeting audit + cascade cancel (operator ergonomics), then schema versioning (precondition for any breaking change to envelope body shape).

---

## Self-Review Notes

### v1 (initial plan)

- **Spec coverage:**
  - Master lock + singular enforcement — Tasks 3, 11
  - Sub recursion via `parent_thread_id` — Tasks 6, 11, 14 (docs)
  - Resume persistence — Tasks 9, 10
  - Meeting 1-off + WORM archive — Task 9
  - Concurrent meeting ban — Tasks 4, 9
  - Enterprise RACI mapping — Task 14 (docs)
  - Stage-gate state machine — Task 6

- **Privacy:** envelopes never include user credentials or API tokens. `scope` / `summary` are user-authored and stored in plaintext; treat `~/.claude/orchestration/` as a dev-machine artifact (not published).

- **Backward compatibility:** all new files under `scripts/_orch.py`, `scripts/clmux_orchestrate.py`, `tests/test_orchestrate.py`, `tests/test_orchestrate_integration.sh`, `docs/orchestration.md`. No existing files modified except `clmux.zsh` (append-only) and `README.md` (link). Zero impact on existing bridge / team code paths.

- **Concurrency:** all `~/.claude/orchestration/` writes use `_filelock.file_lock` (mkdir mutex) + `sigterm_guard`. Thread JSONL append is serialized per-thread; index.json updates are serialized globally. Master/meeting locks are POSIX-atomic via `os.mkdir`.

- **Resume correctness:** `resume_pane` reads only persistent state (`panes.json`, `threads/index.json`, `inbox/<pane>.jsonl`). Nothing in-memory is required for correctness. A pane can die mid-delegate and another Master claim can continue work after inspecting in-flight threads.

- **Type consistency:** envelope keys (`id`, `thread_id`, `ts`, `from`, `to`, `kind`, `parent_id`, `body`) are identical across `_orch.py`, CLI emission, integration test, and docs. State names (`CREATED`, `IN_PROGRESS`, `REPORTED`, `ACCEPTED`, `CLOSED`) are identical across `_ALLOWED_TRANSITIONS`, tests, and documentation.

- **Meeting archive integrity:** `end_meeting` writes synthesis last, then walks the archive directory and chmods every file to 0o444. `release_meeting` runs only after archive completion, so a crash mid-archive leaves the lock claimed → the meeting is recoverable (caller can retry `end_meeting`).

### v2 addendum (reviewer cross-review + corporate hierarchy amendments)

Applied after 4-reviewer cross-review on `clau-mux-final-verify` team (Claude Sonnet plan-reviewer, Gemini 3.1 Pro frame-challenger, Codex GPT-5.4 correctness, Copilot PR-ops) plus user's "Corporate Hierarchy Pattern" architectural context.

**Blocking (2) — applied:**
- **B1 end_meeting atomicity** (Task 9): rewrote to 4-phase ordering (atomic writes → verify writability → single chmod 444 → release lock). Prevents partial-chmod from permanently wedging the meeting lock after crash.
- **B2 notify_pane test mock** (Task 8): added `monkeypatch.setattr(orch.shutil, "which", lambda cmd: "/usr/bin/tmux")` so CI without tmux installed doesn't falsely skip the assertion.

**High (4) — applied:**
- **H1 post_envelope ordering** (Task 6): reversed the critical path — JSONL append first (durable), then state transition. Prevents state drift when transition succeeds but append crashes.
- **H2 atomic text writes** (Task 9): added `_atomic_write_text()` helper using `tempfile.NamedTemporaryFile` + `os.replace` for synthesis.md; matches the atomicity level of `atomic_json_write`.
- **H3 crash-recovery flags** (Task 11, Task 3): `release_master(..., force=True)` and `release_meeting(..., force=True)`; exposed via `release-master --force` and `meeting release --force`. Documented in Known Limitations as the recovery path for dead-Master / crashed-meeting cases.
- **H4 hard-dep note in header:** `scripts/_filelock.py` is a required dependency (not just an aspirational one) — made explicit in the header along with the PR strategy.

**Medium (3) — applied:**
- **M3 envelope list validation** (Task 2): added `_LIST_FIELDS` dict declaring which body fields per kind must be lists; `validate_envelope` now rejects `{"evidence": "single string"}` with a clear error.
- **M4 WORM semantics clarification** (Task 14 docs): added explicit "reality check" section — advisory chmod is not tamper-proof; called out what it prevents (accidental overwrite) vs doesn't (determined user, `rm -rf`, root, cross-FS).
- **M7 mid-delegate crash** (Task 10 + Known Limitations): documented the inbox-recorded-but-not-pasted failure mode; `resume_pane` surfaces the entry; queued auto-replay for Phase 2.

**Corporate Hierarchy additions (4) — applied:**
- **A2 "Master" terminology** (Task 14 docs): clarified that the lock is globally singular; the protocol doesn't enforce Desktop/Project/Worktree hierarchy — that's a recommended *pattern*.
- **A3 Corporate Hierarchy Pattern section** (Task 14 docs): added walk-through of the three-tier Desktop → Project → Worktree layout, `handover` flow for transferring Master downward, and when NOT to use the pattern.
- **A4 `--project-root` option** (Task 11): `register-sub --project-root /path/to/worktree` records which worktree each Sub serves; stored in `panes.json` as advisory metadata for future cross-worktree filtering.

**Copilot PR-ops additions (5) — applied:**
- Version bump to 1.3.0 (Task 15 Step 1).
- CHANGELOG.md entry with Added / Tests / Known limitations sections (Task 15 Step 1).
- README top-level bullet pointing to `docs/orchestration.md` (Task 15 Step 2).
- GH Actions workflow stub `.github/workflows/orchestrate.yml` running unit tests + integration (Task 15 Step 3).
- Phase 2 Roadmap section (above) with 10 explicit Phase-2 candidates and sequencing suggestion.

**Test count update:** v1 projected ~57 tests; v2 projects ~65 (Envelope +1 list-validation, MasterLock +1 force-release, MeetingLock +1 force-release, Panes +1 project_root, Thread +1 H1 ordering, Meeting +1 writability-verify, CLI +2 register-sub-project-root + release-master-force). Growth is localized to amendment scope; no scope creep.

**Not applied (and why):**
- Suggested "replace mkdir-mutex with fcntl" — scope creep; mkdir-mutex works reliably on the macOS + Linux filesystems we target, and `_filelock.py` is already battle-tested via the bridge work. Revisit if Phase 2 reveals a real contention issue.
- Suggested "add JSON-schema validation via jsonschema library" — adds a dependency for marginal benefit over the hand-rolled `validate_envelope`. Revisit if the envelope surface grows beyond 10 kinds.
- Suggested "move `~/.claude/orchestration/` to project-local" — conflicts with the "single Master globally" invariant. Would require redesign of the lock scope. Left in Phase 2 Roadmap as "Cross-project query filters" which achieves the user-visible goal without breaking singularity.

---

## Known Limitations (Phase 1)

Out of scope in this PR; candidates for Phase 2:

- **`blocked` / `reply` state machine** — Sub cannot formally ask Master a question and wait. For now, out-of-band communication.
- **Meeting audit CLI** — archive exists but no `meetings list/show` subcommand. Use `ls ~/.claude/orchestration/meetings/` + `cat`.
- **Cascade cancel** — rejecting a parent thread does not auto-cancel child threads; Sub is responsible.
- **Progress heartbeat + stale Sub detection** — no automatic detection of Sub pane death.
- **Master stale auto-takeover** — if Master pane dies, recover with `release-master --force` (v2 addition); still manual, not automatic.
- **Mid-delegate crash alert replay** — if Master crashes between JSONL durability and tmux paste, Sub inbox has the record but pane never flashed. `resume_pane` surfaces it; auto-replay queued for Phase 2.
- **WORM semantics are advisory** — `chmod 0o444` prevents accidental overwrite, not determined tampering. See `docs/orchestration.md` "WORM semantics — reality check".
- **Claude Code slash command / skill integration** — no `/orch` slash command yet. Invoke CLI directly.
- **Cross-project audit** — `~/.claude/orchestration/` is global; `panes.json` records `project_root` per Sub (v2 addition) but there's no CLI filter yet.
- **Schema versioning** — envelopes don't carry a version field. Adding new required body fields will break validation of old records on replay.
- **Single Master globally (by design)** — no distributed coordination; two concurrent top-level Masters require two OS users or two machines.

See **Phase 2 Roadmap** (above) for the sequenced work plan to close these gaps.
