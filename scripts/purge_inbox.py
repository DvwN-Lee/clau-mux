"""Reset an inbox file to an empty list.

Used by clmux-bridge.zsh cleanup() to enforce the invariant
"queue lifecycle = agent session lifecycle": when an agent exits
(via shutdown_request, pane death, or bridge cleanup), all
remaining messages — read or unread — are discarded so that a
future spawn starts from a clean queue.
"""
import json, sys, tempfile, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _filelock import sigterm_guard

if len(sys.argv) < 2:
    print("usage: purge_inbox.py <inbox_path>", file=sys.stderr)
    sys.exit(1)

path = sys.argv[1]
dir_ = os.path.dirname(os.path.abspath(path))

try:
    with sigterm_guard():
        with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
            json.dump([], tf, indent=2)
            tmp_name = tf.name
        os.replace(tmp_name, path)
except Exception as e:
    print(f"purge_inbox: error: {e}", file=sys.stderr)
    sys.exit(1)
