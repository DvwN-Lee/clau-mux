#!/usr/bin/env python3
"""Thin CLI wrapper for shell scripts (clmux-bridge.zsh) to emit events
without reimplementing schema validation and locking. Arguments map
directly to _events.emit() keyword args.

Usage:
  _events_zsh_helper.py <event> --source <s> --teammate <t> [--team-name T]
                                [--agent-type A] [--backend B] [--note N]
                                [--pane-id P] [--session-id S]

Silent on success. Prints to stderr on error. Exit code always 0
(observability must not fail the caller).
"""
import argparse
import sys
import traceback
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("event")
    ap.add_argument("--source", default="bridge_daemon")
    ap.add_argument("--teammate", default=None)
    ap.add_argument("--team-name", dest="team_name", default=None)
    ap.add_argument("--agent-type", dest="agent_type", default=None)
    ap.add_argument("--backend", default=None)
    ap.add_argument("--note", default="")
    ap.add_argument("--pane-id", dest="pane_id", default=None)
    ap.add_argument("--session-id", dest="session_id", default=None)
    args = ap.parse_args()

    try:
        import _events
        _events.emit(
            event=args.event,
            source=args.source,
            teammate=args.teammate,
            agent_type=args.agent_type,
            backend=args.backend,
            tool=None,
            args={"pane_id": args.pane_id} if args.pane_id else {},
            result={},
            notes=args.note,
            session_id=args.session_id,
            team_name=args.team_name,
        )
    except Exception as e:
        print(f"[_events_zsh_helper] {e}\n{traceback.format_exc()}", file=sys.stderr)


try:
    main()
except Exception as e:
    print(f"[_events_zsh_helper] fatal: {e}", file=sys.stderr)

sys.exit(0)
