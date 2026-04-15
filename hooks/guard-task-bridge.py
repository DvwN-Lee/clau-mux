#!/usr/bin/env python3
"""PreToolUse hook: block TaskCreate/TaskUpdate assignment to any bridge teammate.

Claude Code's TaskUpdate(owner=...) auto-emits a raw JSON envelope via SendMessage
to the assignee. Bridge teammates (Gemini/Codex/Copilot via clmux) cannot parse
this envelope and receive it as plain text. Therefore TaskUpdate routing to
bridge members is forbidden — the lead must use SendMessage with natural language.

Source of truth (since the Tmux-Native State refactor):
  PRIMARY   — tmux pane options @clmux-bridge / @clmux-agent / @clmux-team set by
              clau-mux's clmux.zsh _clmux_spawn_agent. These vanish with the pane,
              so the answer is always live — a dead bridge cannot be flagged.
  FALLBACK  — config.json `agentType: "bridge"` marker. Used when tmux is not
              reachable (e.g., the hook fires from a non-tmux context) or for
              cross-session safety in the unlikely case where a stale config
              still describes a now-dead bridge.

Session isolation: scope to the current session's team(s) by matching
`leadSessionId` in config.json. The pane options carry the team name, so we
only need config.json to map session_id → team_name (a near-static field).

Installation: run scripts/setup.sh (copies this file to ~/.claude/hooks/).
Register in ~/.claude/settings.json under PreToolUse with matcher "TaskCreate|TaskUpdate".
"""
import glob
import json
import os
import subprocess
import sys


def _teams_for_session(session_id: str) -> set:
    """Map current session_id to team name(s) via config.json."""
    teams = set()
    if not session_id:
        return teams
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        if cfg.get("leadSessionId") != session_id:
            continue
        team = cfg.get("name") or os.path.basename(os.path.dirname(cfg_path))
        teams.add(team)
    return teams


def _bridge_members_from_tmux(teams: set) -> set:
    """Query tmux pane options for live bridge teammates in the given teams."""
    if not teams:
        return set()
    fmt = '#{@clmux-agent}|#{@clmux-team}|#{@clmux-bridge}'
    try:
        out = subprocess.check_output(
            ['tmux', 'list-panes', '-a', '-F', fmt],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (subprocess.CalledProcessError, FileNotFoundError, subprocess.TimeoutExpired):
        return set()
    names = set()
    for line in out.strip().split('\n'):
        if not line:
            continue
        parts = line.split('|', 2)
        if len(parts) != 3:
            continue
        agent, team, is_bridge = parts
        if is_bridge != '1' or not agent or team not in teams:
            continue
        names.add(agent)
    return names


def _bridge_members_from_config(teams: set) -> set:
    """Fallback: derive bridge member names from config.json agentType field."""
    names = set()
    if not teams:
        return names
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        team = cfg.get("name") or os.path.basename(os.path.dirname(cfg_path))
        if team not in teams:
            continue
        for m in cfg.get("members", []):
            if m.get("agentType") != "bridge":
                continue
            name = m.get("name", "")
            if name:
                names.add(name)
            agent_id = m.get("agentId", "")
            if agent_id:
                names.add(agent_id)
    return names


def get_blocked_bridge_members(session_id: str) -> set:
    """Return names/agentIds of all bridge members in the current session's team(s).

    Tmux pane options are the primary source of truth (live, can't drift). Falls
    back to config.json so a stale bridge that hasn't fully cleaned up still
    blocks TaskUpdate routing — fail-safe rather than fail-open.
    """
    teams = _teams_for_session(session_id)
    return _bridge_members_from_tmux(teams) | _bridge_members_from_config(teams)


if __name__ == "__main__":
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        session_id = data.get("session_id", "")

        assignee = tool_input.get("assignee", "") or tool_input.get("owner", "")
        if not assignee:
            sys.exit(0)

        blocked = get_blocked_bridge_members(session_id)
        if assignee in blocked:
            json.dump(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": f"'{assignee}': bridge teammate (TaskUpdate 불가, SendMessage 사용)",
                    }
                },
                sys.stdout,
            )
            sys.exit(0)

        sys.exit(0)
    except Exception:
        sys.exit(0)
