"""Cross-process advisory file lock using mkdir mutex.

mkdir is atomic on POSIX. Both Python (this module) and Node.js
(equivalent helper inside bridge-mcp-server.js) use the same
`<target>.lock.d` directory name to coordinate writes to a
shared file (e.g., team-lead.json outbox).

Wait budget: 200 attempts × 25ms = 5s max contention. If lock
cannot be acquired in that window, raises TimeoutError so the
caller can decide whether to skip or retry at a higher level.
"""
import os
import time
from contextlib import contextmanager


@contextmanager
def file_lock(path: str, attempts: int = 200, sleep_s: float = 0.025):
    lock_dir = path + '.lock.d'
    acquired = False
    for _ in range(attempts):
        try:
            os.mkdir(lock_dir)
            acquired = True
            break
        except FileExistsError:
            time.sleep(sleep_s)
    if not acquired:
        raise TimeoutError(f'could not acquire lock on {path}')
    try:
        yield
    finally:
        try:
            os.rmdir(lock_dir)
        except FileNotFoundError:
            pass
