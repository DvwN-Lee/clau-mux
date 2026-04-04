import json, sys, tempfile, os
team_dir, agent_name = sys.argv[1], sys.argv[2]
cfg_path = f"{team_dir}/config.json"
try:
    with open(cfg_path) as f:
        cfg = json.load(f)
    for m in cfg.get('members', []):
        if m.get('name') == agent_name or m.get('agentId', '').startswith(f'{agent_name}@'):
            m['isActive'] = False
            break
    dir_ = os.path.dirname(os.path.abspath(cfg_path))
    with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(cfg, tf, indent=2)
        tmp_name = tf.name
    os.replace(tmp_name, cfg_path)
except Exception as e:
    print(f"warning: could not update config.json: {e}", file=sys.stderr)
