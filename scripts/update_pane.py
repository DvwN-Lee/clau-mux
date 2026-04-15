import json, sys, time, tempfile, os
team_dir, agent_name, pane_id, cli_cmd = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
task_capable = len(sys.argv) > 5 and sys.argv[5] == "1"
cfg_path = f"{team_dir}/config.json"
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
except FileNotFoundError:
    cfg = {"name": team_dir.split('/')[-1], "members": []}
team_name = cfg.get('name', team_dir.split('/')[-1])
updated = False
for m in cfg['members']:
    if m.get('name') == agent_name or m.get('agentId', '').startswith(f'{agent_name}@'):
        m['tmuxPaneId'] = pane_id
        m['isActive'] = True
        m['taskCapable'] = task_capable
        updated = True
        break
if not updated:
    cfg['members'].append({
        "agentId": f"{agent_name}@{team_name}",
        "name": agent_name,
        "model": cli_cmd,
        "joinedAt": int(time.time() * 1000),
        "tmuxPaneId": pane_id,
        "cwd": ".",
        "backendType": "tmux",
        "agentType": "bridge",
        "taskCapable": task_capable,
        "isActive": True
    })
dir_ = os.path.dirname(os.path.abspath(cfg_path))
with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(cfg, tf, indent=2)
    tmp_name = tf.name
os.replace(tmp_name, cfg_path)
