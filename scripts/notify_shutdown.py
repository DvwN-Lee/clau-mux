import json, sys, datetime, tempfile, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _filelock import file_lock

inbox_path, agent_name = sys.argv[1], sys.argv[2]
request_id = sys.argv[3] if len(sys.argv) > 3 else None

outbox_path = os.path.join(os.path.dirname(inbox_path), 'team-lead.json')

# Hold the lock across read-modify-write to prevent lost updates when
# bridge-mcp-server.js writeToLeadImpl runs concurrently for another
# teammate (both write the same team-lead.json outbox).
with file_lock(outbox_path):
    try:
        with open(outbox_path) as f:
            msgs = json.load(f)
    except FileNotFoundError:
        msgs = []
    except json.JSONDecodeError as e:
        print(f"notify_shutdown: JSON parse error in {outbox_path}: {e}", file=sys.stderr)
        msgs = []

    now = datetime.datetime.now(datetime.timezone.utc)
    ts = now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'

    if request_id:
        payload = json.dumps({
            "type": "shutdown_approved",
            "requestId": request_id,
            "from": agent_name,
            "timestamp": ts,
            "backendType": "tmux"
        })
        msgs.append({"from": agent_name, "text": payload, "timestamp": ts, "read": False, "summary": f"{agent_name} terminated"})
    else:
        msgs.append({"from": agent_name, "text": f"{agent_name} has shut down.", "timestamp": ts, "read": False, "summary": f"{agent_name} terminated"})

    # Prefer dropping read messages over unread when over cap
    while len(msgs) > 50:
        idx = next((i for i, m in enumerate(msgs) if m.get('read')), None)
        if idx is not None:
            msgs.pop(idx)
        else:
            msgs.pop(0)
    dir_ = os.path.dirname(os.path.abspath(outbox_path))
    with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(msgs, tf, indent=2, ensure_ascii=False)
        tmp_name = tf.name
    os.replace(tmp_name, outbox_path)
