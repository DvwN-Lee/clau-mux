import json, sys, tempfile, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _filelock import sigterm_guard

path, ts = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        msgs = json.load(f)
except FileNotFoundError:
    print(f"mark_read: inbox not found: {path}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as e:
    print(f"mark_read: JSON parse error in {path}: {e}", file=sys.stderr)
    sys.exit(1)

for m in msgs:
    if not m.get('read', False) and m.get('timestamp') == ts:
        m['read'] = True
        break
dir_ = os.path.dirname(os.path.abspath(path))
with sigterm_guard():
    with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(msgs, tf, indent=2)
        tmp_name = tf.name
    os.replace(tmp_name, path)
