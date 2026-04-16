#!/usr/bin/env python3
"""Stop hook: rescue messages from ~/.claude/teams/default/inboxes/.

When Claude Code's teamContext.teamName is lost after session resume,
SendMessage writes to a literal "default" team path. No teammate reads
from there, so the message is silently dropped.

This hook runs at every turn end (Stop event) and:
1. Checks if ~/.claude/teams/default/inboxes/ has any JSON files.
2. Finds the active team for the current session (by leadSessionId).
3. Moves each file to the matching inbox under the active team.
   If the target inbox already has files, the rescued file is placed
   alongside them (no overwrite — unique filename).

If no active team is found, the orphan messages are left in place
and a warning is printed to stderr.

Installation: register in settings.json under Stop (no matcher needed).
"""
import glob
import json
import os
import shutil
import sys
import time


def _active_team_for_session(session_id):
    """Find the active team name for this session. Returns (name, path) or (None, None).

    If multiple teams match, pick the one with the most recent createdAt.
    """
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    candidates = []
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except Exception:
            continue
        if cfg.get("leadSessionId") != session_id:
            continue
        team_name = cfg.get("name") or os.path.basename(os.path.dirname(cfg_path))
        created = cfg.get("createdAt", "")
        candidates.append((created, team_name, os.path.dirname(cfg_path)))

    if not candidates:
        return None, None
    # Most recent createdAt wins
    candidates.sort(reverse=True)
    return candidates[0][1], candidates[0][2]


def _rescue(session_id):
    default_inboxes = os.path.expanduser("~/.claude/teams/default/inboxes")
    if not os.path.isdir(default_inboxes):
        return

    # Collect JSON files — handle BOTH flat layout (default/inboxes/<name>.json)
    # and nested layout (default/inboxes/<owner>/<file>.json).
    # Real SendMessage mis-route creates flat files; handle both for safety.
    rescued_count = 0

    team_name, team_path = _active_team_for_session(session_id)
    if not team_name:
        orphans = [f for f in os.listdir(default_inboxes) if f.endswith(".json")]
        if orphans:
            print(
                f"[rescue-default-inbox] WARNING: found {len(orphans)} orphan "
                f"message(s) in teams/default/inboxes/ but no active "
                f"team for session {session_id!r}",
                file=sys.stderr,
            )
        return

    target_inboxes = os.path.join(team_path, "inboxes")
    os.makedirs(target_inboxes, exist_ok=True)

    for entry in os.listdir(default_inboxes):
        src = os.path.join(default_inboxes, entry)

        # Flat file: default/inboxes/<name>.json → active/inboxes/<name>.json
        if os.path.isfile(src) and entry.endswith(".json"):
            dst = os.path.join(target_inboxes, entry)
            if os.path.exists(dst):
                base, ext = os.path.splitext(entry)
                dst = os.path.join(
                    target_inboxes,
                    f"{base}_rescued_{int(time.time() * 1000)}{ext}",
                )
            shutil.move(src, dst)
            rescued_count += 1

        # Nested dir: default/inboxes/<owner>/*.json → active/inboxes/<owner>/*.json
        elif os.path.isdir(src):
            json_files = [f for f in os.listdir(src) if f.endswith(".json")]
            if not json_files:
                continue
            target_dir = os.path.join(target_inboxes, entry)
            os.makedirs(target_dir, exist_ok=True)
            for fname in json_files:
                fsrc = os.path.join(src, fname)
                fdst = os.path.join(target_dir, fname)
                if os.path.exists(fdst):
                    base, ext = os.path.splitext(fname)
                    fdst = os.path.join(
                        target_dir,
                        f"{base}_rescued_{int(time.time() * 1000)}{ext}",
                    )
                shutil.move(fsrc, fdst)
                rescued_count += 1

    if rescued_count > 0:
        print(
            f"[rescue-default-inbox] rescued {rescued_count} message(s) "
            f"from teams/default/ to teams/{team_name}/",
            file=sys.stderr,
        )


if __name__ == "__main__":
    try:
        data = json.load(sys.stdin)
        session_id = data.get("session_id", "")
        _rescue(session_id)
    except Exception:
        # Hook must never break the agent turn
        pass
    sys.exit(0)
