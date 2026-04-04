import json, sys
team_dir, agent_name = sys.argv[1], sys.argv[2]
cfg_path = f"{team_dir}/config.json"
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
    for m in cfg.get('members', []):
        if m.get('name') == agent_name or m.get('agentId', '').startswith(f'{agent_name}@'):
            m['isActive'] = False
            break
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
except Exception as e:
    print(f"warning: could not update config.json: {e}", file=sys.stderr)
