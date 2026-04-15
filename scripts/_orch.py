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


class SymlinkEscape(RuntimeError):
    """[B2] path escapes ~/.claude/orchestration/ via symlink or traversal."""


def _safe_within_root(path: Path) -> Path:
    """[B2] Validate that `path` (and every ancestor under root) stays under root().

    Returns the resolved absolute path. Raises SymlinkEscape if:
      - path itself is a symlink
      - any ancestor under root() is a symlink that escapes
      - resolved path is not under resolved root()

    Call this BEFORE every open/write/replace under ~/.claude/orchestration/.
    """
    path = Path(path)
    if path.is_symlink():
        raise SymlinkEscape(f"symlink not allowed: {path}")
    root_resolved = root().resolve()
    # Resolve parent (which must exist by the time we write); if path doesn't
    # exist yet, resolve its longest existing ancestor instead.
    probe = path
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    resolved = probe.resolve() if probe.exists() else path.parent.resolve()
    try:
        resolved.relative_to(root_resolved)
    except ValueError:
        raise SymlinkEscape(f"path escapes root: {path} -> {resolved}")
    return path


def atomic_json_write(path: Path, obj) -> None:
    """Write JSON atomically via tempfile + os.replace. Parent auto-created.

    [B2] Applies symlink defense: refuses to write through a symlink or to a
    path that escapes root().
    """
    path = _safe_within_root(Path(path))
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
    path = _safe_within_root(root() / "threads" / f"{thread_id}.jsonl")
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
                  label: str = "") -> None:
    """Add or refresh a pane entry. last_seen always updates to now.

    [v3 per 2026-04-15 cross-review] `project_root` field removed from Phase 1
    (YAGNI — no query filter uses it yet). Deferred to Phase 2 Roadmap as part
    of "Cross-project query filters".
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
      2. append_thread   <- JSONL is source of truth (audit log)
      3. _apply_transition  <- index.json is a derived summary

    Rationale: if the process crashes between the two writes, a
    JSONL-first order leaves the log with a record that HAS NO
    corresponding index transition (rather than an index transition
    with NO audit record). On recovery, an operator can inspect the
    JSONL audit log directly and reason about the correct index state.

    [v3 per codex-reviewer] The phrase "index.json can be replayed to
    reconstruct" was softened in this docstring because Phase 1 does
    NOT ship an automated `rebuild_thread_index()` function. Recovery
    is manual or via retry of the next valid transition. A programmatic
    rebuild/repair path is queued in Phase 2 Roadmap (#5).

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
    #    the envelope is still logged -- caller sees TransitionError,
    #    index remains at previous state. Caller MAY choose to log
    #    the illegal attempt as an audit event separately.
    if kind in state_changing:
        _apply_transition(tid, kind)


def close_thread(tid: str, note: str = "") -> None:
    """Transition ACCEPTED -> CLOSED after external user approval."""
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
