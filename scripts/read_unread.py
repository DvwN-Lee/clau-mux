import json, sys
with open(sys.argv[1]) as f:
    msgs = json.load(f)
unread = [m for m in msgs if not m.get('read', False)]
print(json.dumps(unread[0]) if unread else '', end='')
