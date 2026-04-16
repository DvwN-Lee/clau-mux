#!/usr/bin/env python3
"""SessionStart / UserPromptSubmit hook: reconcile stale isActive=true entries
across all teams led by the current session.

Issue #24: native Agent-tool subagents (agentType="general-purpose") leave
config.json with isActive=true after their process dies, because only bridge
teammates run a wrapper process with a cleanup trap. This hook sweeps the
current session's teams on session start (and optionally on each user turn)
so stale state auto-corrects without manual intervention.

Scope: only teams where cfg["leadSessionId"] == session_id — avoids touching
other active sessions' teams in a multi-session environment.

Exit behavior: always exit 0. This hook is best-effort cleanup; never block
a session start or user prompt.

Installation: scripts/setup.sh copies this to ~/.claude/hooks/. Register in
~/.claude/settings.json under SessionStart (and optionally UserPromptSubmit):

  "SessionStart": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "python3 ~/.claude/hooks/reconcile-active.py",
          "timeout": 5
        }
      ]
    }
  ]
"""
import glob
import json
import os
import subprocess
import sys


def _teams_for_session(session_id: str) -> list:
    """Return team_dir paths where leadSessionId matches the current session."""
    if not session_id:
        return []
    dirs = []
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        if cfg.get("leadSessionId") == session_id:
            dirs.append(os.path.dirname(cfg_path))
    return dirs


def _find_reconcile_script() -> str:
    """Locate scripts/reconcile_active.py. Prefer $CLMUX_DIR (set by clmux.zsh
    in the Lead's shell env and inherited into hook subprocesses). Fall back to
    the common clone locations for users who haven't sourced clmux.zsh yet."""
    clmux_dir = os.environ.get("CLMUX_DIR") or ""
    candidates = []
    if clmux_dir:
        candidates.append(os.path.join(clmux_dir, "scripts", "reconcile_active.py"))
    candidates += [
        os.path.expanduser("~/Desktop/Git/clau-mux/scripts/reconcile_active.py"),
        os.path.expanduser("~/clau-mux/scripts/reconcile_active.py"),
    ]
    for p in candidates:
        if os.path.isfile(p):
            return p
    return ""


if __name__ == "__main__":
    try:
        data = json.load(sys.stdin)
        session_id = data.get("session_id", "")
    except Exception:
        sys.exit(0)

    script = _find_reconcile_script()
    if not script:
        sys.exit(0)

    for team_dir in _teams_for_session(session_id):
        try:
            subprocess.run(
                ["python3", script, team_dir],
                capture_output=True,
                timeout=3,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass

    sys.exit(0)
