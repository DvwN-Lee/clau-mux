#!/usr/bin/env python3
"""PreToolUse hook: block SendMessage when target is not in any active team.

Root cause (documented in docs/investigations/sendmessage-drop.md):
After session resume, Claude Code's teamContext.teamName may not be restored.
SendMessage then falls through to a literal "default" team path, silently
dropping the message into ~/.claude/teams/default/inboxes/ where no teammate
reads it.

This hook makes the failure loud: if the target name is not found in any
team whose leadSessionId matches the current session, the tool call is denied.

Broadcast (to="*") is always allowed — Claude Code resolves it internally.
If no teams exist at all (non-team usage), the hook allows the call (fail-open).

Installation: register in settings.json under PreToolUse with matcher "SendMessage".
"""
import glob
import json
import sys


def _find_member_names(session_id):
    """Return set of all member names + agentIds across teams for this session."""
    import os
    names = set()
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        if cfg.get("leadSessionId") != session_id:
            continue
        for m in cfg.get("members", []):
            name = m.get("name", "")
            if name:
                names.add(name)
            agent_id = m.get("agentId", "")
            if agent_id:
                names.add(agent_id)
    return names


def _has_any_team(session_id):
    """Return True if at least one team exists for this session."""
    import os
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        if cfg.get("leadSessionId") == session_id:
            return True
    return False


if __name__ == "__main__":
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        session_id = data.get("session_id", "")
        target = tool_input.get("to", "")

        # Broadcast — always allow
        if target == "*":
            sys.exit(0)

        # No teams for this session — fail-open (non-team usage)
        if not _has_any_team(session_id):
            sys.exit(0)

        # Check membership
        known = _find_member_names(session_id)
        if target in known:
            sys.exit(0)

        # Target not found in any team — block
        print(
            f"[guard-sendmessage] BLOCKED: '{target}' not in session teams",
            file=sys.stderr,
        )
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"SendMessage target '{target}' not found in any active "
                        f"team — possible teamContext loss after session resume. "
                        f"Known members: {sorted(known)}"
                    ),
                }
            },
            sys.stdout,
        )
        sys.exit(0)

    except Exception:
        # Hook must never break the agent turn
        sys.exit(0)
