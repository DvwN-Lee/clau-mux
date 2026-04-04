import json, sys, time
team_dir, agent_name, pane_id, model_name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
cfg_path = f"{team_dir}/config.json"
with open(cfg_path) as f:
    cfg = json.load(f)
team_name = cfg.get('name', team_dir.split('/')[-1])
updated = False
for m in cfg['members']:
    if m.get('name') == agent_name or m.get('agentId', '').startswith(f'{agent_name}@'):
        m['tmuxPaneId'] = pane_id
        m['isActive'] = True
        updated = True
        break
if not updated:
    cfg['members'].append({
        "agentId": f"{agent_name}@{team_name}",
        "name": agent_name,
        "model": model_name,
        "joinedAt": int(time.time() * 1000),
        "tmuxPaneId": pane_id,
        "cwd": ".",
        "backendType": "tmux",
        "isActive": True
    })
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
