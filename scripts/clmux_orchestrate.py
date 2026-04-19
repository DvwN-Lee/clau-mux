#!/usr/bin/env python3
"""CLI for the pane orchestration protocol.

Subcommands:
  set-master       — claim master role for a pane
  handover         — transfer master role atomically
  release-master   — release master role (held by caller)
  register-sub     — register a pane as a sub of a given master
  delegate         — master → sub task assignment (creates thread)
  ack              — sub acknowledges receipt of delegation
  progress         — sub reports progress
  report           — sub delivers final result with evidence
  accept           — master accepts a sub's report
  reject           — master rejects with feedback
  blocked          — sub posts a clarification question to master
  reply            — master posts an answer to sub
  close            — master closes an accepted thread
  meeting          — subcommands: start, end
  inbox            — show/mark-read pending alerts for a pane
  thread           — show full history of a thread
  panes            — list registered panes
  resume           — reconstruct a pane's in-flight state

Every sub-command accepts --json for machine-readable output.
"""
import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _orch


def _emit(data, as_json: bool):
    if as_json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        if isinstance(data, str):
            print(data)
        else:
            print(json.dumps(data, ensure_ascii=False, indent=2))


def cmd_set_master(args):
    _orch.claim_master(args.pane, label=args.label or "")
    _orch.register_pane(args.pane, role="master", master=None, label=args.label or "")
    _emit({"master": _orch.current_master()}, args.json)


def cmd_handover(args):
    _orch.handover_master(from_pane=args.from_pane, to_pane=args.to_pane,
                          label=args.label or "")
    # Demote the previous master in panes.json so list_panes() reflects the
    # new hierarchy; otherwise the registry drifts (two panes with role=master
    # after a successful handover).
    panes = _orch.list_panes()
    if args.from_pane in panes and panes[args.from_pane].get("role") == "master":
        existing_label = panes[args.from_pane].get("label", "")
        _orch.register_pane(
            args.from_pane, role="former_master", master=None,
            label=existing_label + " (handed over)" if existing_label else "handed over",
        )
    _orch.register_pane(args.to_pane, role="master", master=None, label=args.label or "")
    _emit({"master": _orch.current_master()}, args.json)


def cmd_release_master(args):
    # [H3] --force lets operators clear a stuck lock after crash recovery
    # [H2 v3] after successful release, demote any pane currently holding
    # the master role in panes.json — prevents registry drift where the
    # lock is cleared but the registry still lists the dead pane as Master.
    prior_master = _orch.current_master() or {}
    prior_pane = (prior_master or {}).get("pane_id")
    _orch.release_master(args.pane, force=bool(args.force))
    if prior_pane:
        panes = _orch.list_panes()
        if prior_pane in panes and panes[prior_pane].get("role") == "master":
            # Re-register as "former" (keeps audit trail) — or unregister if
            # the caller is %999-style synthetic recovery.
            _orch.register_pane(
                prior_pane, role="former_master",
                master=None,
                label=panes[prior_pane].get("label", "") + " (released)",
            )
            panes = _orch.list_panes()
            panes[prior_pane]["stale_master_released_at"] = _orch._now_ts()
            _orch.atomic_json_write(_orch._panes_path(), panes)
    _emit({"released": args.pane, "force": bool(args.force),
           "prior_master_demoted": prior_pane}, args.json)


def cmd_register_sub(args):
    _orch.register_pane(
        args.pane, role="sub", master=args.master,
        label=args.label or "",
    )
    _emit({"registered": args.pane}, args.json)


def cmd_delegate(args):
    tid = _orch.open_thread(delegator=args.from_pane, assignee=args.to_pane,
                             parent_thread_id=args.parent, label=args.label or "")
    body = {"scope": args.scope, "success_criteria": args.criteria}
    if args.non_goals:
        body["non_goals"] = args.non_goals
    if args.deliverable:
        body["deliverable"] = args.deliverable
    if args.urgency:
        body["urgency"] = args.urgency
    env = _orch.make_envelope(
        thread_id=tid, from_=args.from_pane, to=args.to_pane,
        kind="delegate", body=body,
    )
    _orch.post_envelope(env)
    _orch.add_inbox_alert(args.to_pane, {
        "thread_id": tid, "kind": "delegate", "from": args.from_pane,
        "summary": args.scope[:80],
    })
    # Best-effort tmux notification (requires tmux)
    _orch.notify_pane(args.to_pane, f"# orch:delegate thread={tid} from={args.from_pane} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": tid, "envelope_id": env["id"]}, args.json)


def cmd_ack(args):
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="ack", body={"note": args.note or ""},
    )
    _orch.post_envelope(env)
    _emit({"thread_id": args.thread, "state": _orch.read_thread_index()[args.thread]["state"]},
          args.json)


def cmd_progress(args):
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="progress", body={"status": args.status, "note": args.note or ""},
    )
    _orch.post_envelope(env)
    _emit({"thread_id": args.thread, "status": args.status}, args.json)


def cmd_report(args):
    evidence = args.evidence or []
    body = {"summary": args.summary, "evidence": evidence}
    if args.risks:
        body["risks"] = args.risks
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="report", body=body,
    )
    _orch.post_envelope(env)
    _orch.add_inbox_alert(args.to_pane, {
        "thread_id": args.thread, "kind": "report", "from": args.from_pane,
        "summary": args.summary[:80],
    })
    _orch.notify_pane(args.to_pane, f"# orch:report thread={args.thread} from={args.from_pane} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "envelope_id": env["id"],
           "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_accept(args):
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="accept", body={"note": args.note or ""},
    )
    _orch.post_envelope(env)
    _orch.notify_pane(args.to_pane, f"# orch:accept thread={args.thread} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_reject(args):
    body = {"feedback": args.feedback}
    if args.required_changes:
        body["required_changes"] = args.required_changes
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="reject", body=body,
    )
    _orch.post_envelope(env)
    _orch.notify_pane(args.to_pane, f"# orch:reject thread={args.thread} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_blocked(args):
    body = {"question": args.question}
    if args.options:
        body["options"] = args.options
    if args.urgency:
        body["urgency"] = args.urgency
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="blocked", body=body,
    )
    _orch.post_envelope(env)
    _orch.add_inbox_alert(args.to_pane, {
        "thread_id": args.thread, "kind": "blocked", "from": args.from_pane,
        "summary": args.question[:80],
    })
    _orch.notify_pane(args.to_pane, f"# orch:blocked thread={args.thread} from={args.from_pane} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "envelope_id": env["id"],
           "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_reply(args):
    body = {"answer": args.answer}
    if args.note:
        body["note"] = args.note
    env = _orch.make_envelope(
        thread_id=args.thread, from_=args.from_pane, to=args.to_pane,
        kind="reply", body=body,
    )
    _orch.post_envelope(env)
    _orch.add_inbox_alert(args.to_pane, {
        "thread_id": args.thread, "kind": "reply", "from": args.from_pane,
        "summary": args.answer[:80],
    })
    _orch.notify_pane(args.to_pane, f"# orch:reply thread={args.thread} from={args.from_pane} — run: clmux-orchestrate inbox --pane {args.to_pane}")
    _emit({"thread_id": args.thread, "envelope_id": env["id"],
           "state": _orch.read_thread_index()[args.thread]["state"]}, args.json)


def cmd_close(args):
    _orch.close_thread(args.thread, note=args.note or "")
    _emit({"thread_id": args.thread, "state": "CLOSED"}, args.json)


def cmd_meeting_start(args):
    mid = _orch.start_meeting(started_by=args.pane, topic=args.topic,
                              team_name=args.team)
    _emit({"meeting_id": mid}, args.json)


def cmd_meeting_end(args):
    synthesis = args.synthesis
    if args.synthesis_file:
        synthesis = Path(args.synthesis_file).read_text(encoding="utf-8")
    _orch.end_meeting(args.meeting_id, synthesis=synthesis or "")
    _emit({"meeting_id": args.meeting_id, "status": "archived"}, args.json)


def cmd_meeting_release(args):
    # [H3] --force teardown after crash leaves lock stuck
    _orch.release_meeting(args.meeting_id, force=bool(args.force))
    _emit({"meeting_id": args.meeting_id, "released": True,
           "force": bool(args.force)}, args.json)


def cmd_inbox(args):
    pending = _orch.read_inbox(args.pane)
    if args.mark_read and pending:
        _orch.mark_inbox_read(args.pane)
    _emit(pending, args.json)


def cmd_thread(args):
    records = _orch.read_thread(args.id)
    _emit(records, args.json)


def cmd_panes(args):
    _emit(_orch.list_panes(), args.json)


def cmd_resume(args):
    _emit(_orch.resume_pane(args.pane), args.json)


def cmd_threads(args):
    _emit(_orch.list_threads(
        pane_id=args.pane,
        role=args.role,
        state=args.state,
    ), args.json)


def cmd_notify(args):
    eid = _orch.post_notify(
        from_pane=args.from_pane,
        to_pane=args.to_pane,
        kind=args.kind,
        summary=args.summary,
        body=args.body or "",
    )
    _emit({"envelope_id": eid, "kind": "notify"}, args.json)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="clmux-orchestrate",
                                description="Pane orchestration protocol CLI")
    p.add_argument("--json", action="store_true", help="JSON output")
    # Shared parent parser so every subcommand also accepts --json after it.
    # argparse does not propagate top-level flags to subparsers by default;
    # `parents=[common]` gives each subparser its own --json option.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="JSON output")
    sub = p.add_subparsers(dest="cmd", required=True)

    # Master
    sp = sub.add_parser("set-master", parents=[common]); sp.add_argument("--pane", required=True); sp.add_argument("--label"); sp.set_defaults(func=cmd_set_master)
    sp = sub.add_parser("handover", parents=[common]); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--label"); sp.set_defaults(func=cmd_handover)
    sp = sub.add_parser("release-master", parents=[common])
    sp.add_argument("--pane", required=True)
    sp.add_argument("--force", action="store_true",
                    help="[H3] clear lock even if held by a different pane (crash recovery)")
    sp.set_defaults(func=cmd_release_master)

    # Sub
    sp = sub.add_parser("register-sub", parents=[common])
    sp.add_argument("--pane", required=True)
    sp.add_argument("--master", required=True)
    sp.add_argument("--label")
    sp.set_defaults(func=cmd_register_sub)

    # Thread lifecycle
    sp = sub.add_parser("delegate", parents=[common])
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--scope", required=True)
    sp.add_argument("--criteria", default="",
                    help="optional success criteria; empty string is valid")
    sp.add_argument("--non-goals", dest="non_goals")
    sp.add_argument("--deliverable")
    sp.add_argument("--urgency", choices=["blocker", "high", "normal", "low"])
    sp.add_argument("--parent", help="parent thread id (for sub-recursion)")
    sp.add_argument("--label")
    sp.set_defaults(func=cmd_delegate)

    sp = sub.add_parser("ack", parents=[common]); sp.add_argument("--thread", required=True); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_ack)

    sp = sub.add_parser("progress", parents=[common]); sp.add_argument("--thread", required=True); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--status", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_progress)

    sp = sub.add_parser("report", parents=[common])
    sp.add_argument("--thread", required=True)
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--summary", required=True)
    sp.add_argument("--evidence", action="append", help="repeatable evidence string")
    sp.add_argument("--risks", action="append")
    sp.set_defaults(func=cmd_report)

    sp = sub.add_parser("accept", parents=[common]); sp.add_argument("--thread", required=True); sp.add_argument("--from", dest="from_pane", required=True); sp.add_argument("--to", dest="to_pane", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_accept)

    sp = sub.add_parser("reject", parents=[common])
    sp.add_argument("--thread", required=True)
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--feedback", required=True)
    sp.add_argument("--required-changes", dest="required_changes", action="append")
    sp.set_defaults(func=cmd_reject)

    sp = sub.add_parser("blocked", parents=[common])
    sp.add_argument("--thread", required=True)
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--question", required=True)
    sp.add_argument("--options", action="append", help="repeatable option string")
    sp.add_argument("--urgency")
    sp.set_defaults(func=cmd_blocked)

    sp = sub.add_parser("reply", parents=[common])
    sp.add_argument("--thread", required=True)
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--answer", required=True)
    sp.add_argument("--note")
    sp.set_defaults(func=cmd_reply)

    sp = sub.add_parser("close", parents=[common]); sp.add_argument("--thread", required=True); sp.add_argument("--note"); sp.set_defaults(func=cmd_close)

    # Meeting
    sp = sub.add_parser("meeting", parents=[common])
    msub = sp.add_subparsers(dest="meeting_cmd", required=True)
    sps = msub.add_parser("start", parents=[common]); sps.add_argument("--pane", required=True); sps.add_argument("--topic", required=True); sps.add_argument("--team", required=True); sps.set_defaults(func=cmd_meeting_start)
    spe = msub.add_parser("end", parents=[common]); spe.add_argument("--meeting-id", dest="meeting_id", required=True); spe.add_argument("--synthesis"); spe.add_argument("--synthesis-file", dest="synthesis_file"); spe.set_defaults(func=cmd_meeting_end)
    spr = msub.add_parser("release", parents=[common])
    spr.add_argument("--meeting-id", dest="meeting_id", required=True)
    spr.add_argument("--force", action="store_true",
                     help="[H3] clear meeting lock after crash (skips ownership check)")
    spr.set_defaults(func=cmd_meeting_release)

    # Queries
    sp = sub.add_parser("inbox", parents=[common]); sp.add_argument("--pane", required=True); sp.add_argument("--mark-read", dest="mark_read", action="store_true"); sp.set_defaults(func=cmd_inbox)
    sp = sub.add_parser("thread", parents=[common]); sp.add_argument("--id", required=True); sp.set_defaults(func=cmd_thread)
    sp = sub.add_parser("panes", parents=[common]); sp.set_defaults(func=cmd_panes)
    sp = sub.add_parser("resume", parents=[common]); sp.add_argument("--pane", required=True); sp.set_defaults(func=cmd_resume)

    # AX extensions
    sp = sub.add_parser("threads", parents=[common])
    sp.add_argument("--pane")
    sp.add_argument("--role", choices=["target", "delegator", "any"], default="any")
    sp.add_argument("--state", choices=["open", "closed", "any"], default="any")
    sp.set_defaults(func=cmd_threads)

    sp = sub.add_parser("notify", parents=[common])
    sp.add_argument("--from", dest="from_pane", required=True)
    sp.add_argument("--to", dest="to_pane", required=True)
    sp.add_argument("--kind", required=True)
    sp.add_argument("--summary", required=True)
    sp.add_argument("--body")
    sp.set_defaults(func=cmd_notify)

    return p


def main(argv=None):
    p = build_parser()
    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
