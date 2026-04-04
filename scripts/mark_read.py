import json, sys, tempfile, os
path, ts = sys.argv[1], sys.argv[2]
with open(path) as f:
    msgs = json.load(f)
for m in msgs:
    if m.get('timestamp') == ts:
        m['read'] = True
dir_ = os.path.dirname(os.path.abspath(path))
with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(msgs, tf, indent=2)
    tmp_name = tf.name
os.replace(tmp_name, path)
