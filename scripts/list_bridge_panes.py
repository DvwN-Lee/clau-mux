"""List bridge teammate panes from tmux pane options.

Pane options (set in clmux.zsh _clmux_spawn_agent at spawn time):
  @clmux-agent  → agent name
  @clmux-team   → team name
  @clmux-bridge → "1" if this pane hosts a bridge teammate

When the pane dies, its options vanish, so this listing is the
authoritative live view of which bridge teammates currently exist.
config.json fields like isActive can drift; pane options cannot.

Usage:
  python3 list_bridge_panes.py             # all bridge panes
  python3 list_bridge_panes.py <team>      # filter to one team

Output: JSON array of {pane, agent, team}.
"""
import json
import subprocess
import sys


def list_bridge_panes(team_filter=None):
    fmt = '#{pane_id}|#{@clmux-agent}|#{@clmux-team}|#{@clmux-bridge}'
    try:
        out = subprocess.check_output(
            ['tmux', 'list-panes', '-a', '-F', fmt],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, FileNotFoundError):
        return []

    result = []
    for line in out.strip().split('\n'):
        if not line:
            continue
        parts = line.split('|', 3)
        if len(parts) != 4:
            continue
        pane_id, agent, team, is_bridge = parts
        if is_bridge != '1' or not agent:
            continue
        if team_filter and team != team_filter:
            continue
        result.append({'pane': pane_id, 'agent': agent, 'team': team})
    return result


if __name__ == '__main__':
    team = sys.argv[1] if len(sys.argv) > 1 else None
    print(json.dumps(list_bridge_panes(team)))
