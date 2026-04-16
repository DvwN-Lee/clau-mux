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
try:
    with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(cfg, tf, indent=2)
        tmp_name = tf.name
    os.replace(tmp_name, cfg_path)
except FileNotFoundError as e:
    # Team dir disappeared (TeamDelete race, manual rm). Nothing to
    # update. Spawner will see this as a non-fatal warning.
    print(f"update_pane: team dir gone, skipping: {e}", file=sys.stderr)
    sys.exit(0)

try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import _events
    _events.emit(
        event="teammate.spawned",
        source="update_pane",
        teammate=agent_name,
        agent_type="bridge",
        backend="external-cli",
        tool=None,
        args={"pane_id": pane_id, "cli_cmd": cli_cmd, "task_capable": task_capable},
        result={},
        notes="",
        session_id=None,
        team_name=team_name,
        agent_id=f"{agent_name}@{team_name}",
    )
except Exception as _e:
    print(f"update_pane: _events.emit failed: {_e}", file=sys.stderr)
