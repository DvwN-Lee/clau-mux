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
