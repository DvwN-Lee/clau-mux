"""Cross-process advisory file lock + SIGTERM guard.

`file_lock`: mkdir-based mutex. Coordinates with bridge-mcp-server.js
withLock() via the same `<target>.lock.d` directory name so Python
and Node writers don't lose updates to the shared team-lead.json.

`sigterm_guard`: ignore SIGTERM during a critical section so an
in-flight tempfile + os.replace cycle cannot be killed mid-way,
leaving an orphan `.tmp-*.json` and a half-written destination.

Wait budget: 200 attempts × 25ms = 5s max contention. If lock
cannot be acquired, raises TimeoutError so the caller can decide
whether to skip or retry at a higher level.
"""
import os
import signal
import time
from contextlib import contextmanager


@contextmanager
def file_lock(path: str, attempts: int = 200, sleep_s: float = 0.025):
    lock_dir = path + '.lock.d'
    # Ensure the parent directory exists. Without this, os.mkdir can raise
    # FileNotFoundError (not FileExistsError) when the team's inboxes/ dir
    # was removed/recreated concurrently — crashing notify_shutdown.py mid
    # pane-gone cleanup. makedirs with exist_ok=True is idempotent.
    parent = os.path.dirname(lock_dir) or '.'
    try:
        os.makedirs(parent, exist_ok=True)
    except OSError:
        # Parent creation failed (permission, etc.). Fall through and let
        # the mkdir attempt surface the real error.
        pass
    acquired = False
    for _ in range(attempts):
        try:
            os.mkdir(lock_dir)
            acquired = True
            break
        except FileExistsError:
            time.sleep(sleep_s)
        except FileNotFoundError:
            # Parent disappeared between makedirs and mkdir (race during
            # team deletion). Nothing useful to lock; abandon.
            break
    if not acquired:
        raise TimeoutError(f'could not acquire lock on {path}')
    try:
        yield
    finally:
        try:
            os.rmdir(lock_dir)
        except FileNotFoundError:
            pass


@contextmanager
def sigterm_guard():
    """Defer SIGTERM until the critical section completes."""
    try:
        old = signal.signal(signal.SIGTERM, signal.SIG_IGN)
    except (ValueError, OSError):
        # Not in main thread or platform restriction — fall through
        old = None
    try:
        yield
    finally:
        if old is not None:
            signal.signal(signal.SIGTERM, old)
