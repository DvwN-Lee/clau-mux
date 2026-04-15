"""Reconcile config.json isActive flag against tmux pane liveness.

Closes Issue #24: native Agent-tool subagents (agentType="general-purpose")
have no wrapper process like clmux-bridge.zsh, so when their OS process dies
there is no hook that flips isActive to false. This leaves stale "active"
members in ~/.claude/teams/<team>/config.json forever.

Bridge teammates already self-clean via clmux-bridge.zsh's trap-cleanup on
EXIT/TERM/INT, but the logic here applies uniformly to both kinds — a dead
pane always means the member is gone, regardless of agentType.

Algorithm:
  1. Read team_dir/config.json.
  2. Query tmux for the set of live pane IDs.
  3. For each member with isActive=true and a non-empty tmuxPaneId that is
     NOT in the live set, flip isActive to false.
  4. If anything changed, atomic-replace config.json. Otherwise skip the
     write (idempotent; keeps mtime stable).

Usage: python3 reconcile_active.py <team_dir>

Intended callers:
  - SessionStart hook (catches zombies from prior sessions on resume).
  - Manual invocation during debugging.
"""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _filelock import file_lock, sigterm_guard


def _live_pane_ids() -> set:
    """Return the set of currently-live tmux pane IDs, or empty set if tmux
    is unavailable. Returning empty on tmux failure is INTENTIONAL: the
    caller treats "no panes live" as "flip everything to false", which is
    safe — if tmux is actually down all panes really are gone."""
    try:
        out = subprocess.check_output(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        )
    except (subprocess.CalledProcessError, FileNotFoundError,
            subprocess.TimeoutExpired):
        return set()
    return {line.strip() for line in out.splitlines() if line.strip()}


def reconcile(team_dir: str) -> int:
    """Return number of members whose isActive was flipped to false."""
    cfg_path = os.path.join(team_dir, "config.json")
    if not os.path.isfile(cfg_path):
        return 0

    live_panes = _live_pane_ids()

    # Lock the config against concurrent update_pane.py / deactivate_pane.py
    # writers. Both use os.replace with a sibling tempfile, so racing
    # without a lock is lost-update territory.
    try:
        _lock_cm = file_lock(cfg_path)
        _lock_cm.__enter__()
    except (TimeoutError, FileNotFoundError, PermissionError) as e:
        print(f"reconcile_active: cannot lock {cfg_path}: {e}", file=sys.stderr)
        return 0

    try:
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            print(f"reconcile_active: cannot read {cfg_path}: {e}",
                  file=sys.stderr)
            return 0

        changed = 0
        for m in cfg.get("members", []):
            if not m.get("isActive"):
                continue
            pane_id = m.get("tmuxPaneId") or ""
            if not pane_id:
                continue
            if pane_id in live_panes:
                continue
            m["isActive"] = False
            changed += 1

        if changed == 0:
            return 0

        dir_ = os.path.dirname(os.path.abspath(cfg_path))
        try:
            with sigterm_guard():
                with tempfile.NamedTemporaryFile(
                    mode="w", dir=dir_, delete=False, suffix=".tmp"
                ) as tf:
                    json.dump(cfg, tf, indent=2)
                    tmp_name = tf.name
                os.replace(tmp_name, cfg_path)
        except FileNotFoundError as e:
            print(f"reconcile_active: team dir gone, skipping: {e}",
                  file=sys.stderr)
            return 0

        return changed
    finally:
        _lock_cm.__exit__(None, None, None)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: reconcile_active.py <team_dir>", file=sys.stderr)
        sys.exit(2)
    team_dir = sys.argv[1]
    changed = reconcile(team_dir)
    if changed:
        print(f"reconcile_active: flipped {changed} stale isActive=true → false "
              f"in {team_dir}", file=sys.stderr)
    sys.exit(0)
