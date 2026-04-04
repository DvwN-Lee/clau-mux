import json, sys, datetime, tempfile, os
inbox_path, agent_name = sys.argv[1], sys.argv[2]
outbox_path = os.path.join(os.path.dirname(inbox_path), 'team-lead.json')
try:
    with open(outbox_path) as f:
        msgs = json.load(f)
except Exception:
    msgs = []
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'
msgs.append({"from": agent_name, "text": f"{agent_name} has shut down.", "timestamp": ts, "read": False, "summary": f"{agent_name} terminated"})
if len(msgs) > 50:
    msgs = msgs[-50:]
dir_ = os.path.dirname(os.path.abspath(outbox_path))
with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(msgs, tf, indent=2, ensure_ascii=False)
    tmp_name = tf.name
os.replace(tmp_name, outbox_path)
