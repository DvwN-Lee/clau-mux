import json, sys

inbox_path = sys.argv[1]
try:
    with open(inbox_path) as f:
        msgs = json.load(f)
except FileNotFoundError:
    print(f"read_unread: inbox not found: {inbox_path}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as e:
    print(f"read_unread: JSON parse error in {inbox_path}: {e}", file=sys.stderr)
    sys.exit(1)

unread = [m for m in msgs if not m.get('read', False)]
print(json.dumps(unread[0]) if unread else '', end='')
