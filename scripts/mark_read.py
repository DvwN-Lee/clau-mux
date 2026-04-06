import json, sys, tempfile, os

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
    if m.get('timestamp') == ts:
        m['read'] = True
dir_ = os.path.dirname(os.path.abspath(path))
with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(msgs, tf, indent=2)
    tmp_name = tf.name
os.replace(tmp_name, path)
