#!/usr/bin/env python3
"""Read ~/.claude/clmux/events.jsonl and produce a parity matrix.

Usage:
  analyze_events.py [--input PATH] [--output PATH]

Defaults to reading $HOME/.claude/clmux/events.jsonl and writing to
./teammate-parity-matrix.md.
"""
import argparse
import collections
import datetime
import json
import os
from pathlib import Path

LIFECYCLE_STEPS = [
    "registered", "spawned", "message_sent", "message_delivered",
    "state_changed", "terminated",
]

GAP_MARK = "—"
PRESENT_MARK = "✓"


def _read_events(path: Path):
    if not path.is_file():
        return []
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def _build_per_teammate(events):
    """Returns {(team, teammate): {step: [event_records]}}."""
    out = collections.defaultdict(lambda: collections.defaultdict(list))
    for e in events:
        team = e.get("team_name") or "_no_team"
        tm = e.get("teammate")
        if tm is None:
            continue
        name = e.get("event", "")
        if not name.startswith("teammate."):
            continue
        step = name.split(".", 1)[1]
        if step in LIFECYCLE_STEPS:
            out[(team, tm)][step].append(e)
    return out


def _parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def _count_drops(events, window_seconds=30):
    """Messages sent without a matching delivered within `window_seconds` after."""
    drops = collections.Counter()
    delivered = collections.defaultdict(list)
    for e in events:
        if e.get("event") == "teammate.message_delivered":
            tm = e.get("teammate")
            if tm:
                delivered[tm].append(_parse_ts(e.get("ts")))
    for e in events:
        if e.get("event") != "teammate.message_sent":
            continue
        tm = e.get("teammate")
        if not tm:
            continue
        sent_ts = _parse_ts(e.get("ts"))
        if sent_ts is None:
            continue
        matched = any(
            d is not None and 0 <= (d - sent_ts).total_seconds() <= window_seconds
            for d in delivered.get(tm, [])
        )
        if not matched:
            drops[tm] += 1
    return drops


def _render(per_teammate, drops, events):
    lines = ["# Teammate Parity Matrix", ""]
    lines.append(f"Generated: {datetime.datetime.now(datetime.timezone.utc).isoformat()}")
    lines.append(f"Events analyzed: {len(events)}")
    lines.append("")

    teams = sorted({t for t, _ in per_teammate.keys()})
    team_events = [e for e in events if e.get("event") in ("team.created", "team.deleted")]
    observed_teams = sorted({e.get("team_name") for e in team_events if e.get("team_name")} | set(teams))
    lines.append(f"Teams observed: {', '.join(observed_teams) if observed_teams else '(none)'}")
    lines.append(f"Team.created/deleted events: {len(team_events)}")
    lines.append("")

    header = ["Team", "Teammate", "Backend"] + LIFECYCLE_STEPS + ["Drops"]
    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(["---"] * len(header)) + "|")
    for (team, tm), steps in sorted(per_teammate.items()):
        backend = "?"
        for step_events in steps.values():
            if step_events:
                backend = step_events[0].get("backend") or "?"
                break
        row = [team, tm, backend]
        for s in LIFECYCLE_STEPS:
            row.append(PRESENT_MARK if steps.get(s) else GAP_MARK)
        row.append(str(drops.get(tm, 0)))
        lines.append("| " + " | ".join(row) + " |")

    lines.append("")
    lines.append("## Message drop summary")
    if drops:
        lines.append("")
        for tm, n in drops.most_common():
            lines.append(f"- **{tm}**: {n} dropped messages (sent but no delivered within 30s)")
    else:
        lines.append("")
        lines.append("No drops detected.")

    lines.append("")
    lines.append("## Observed gaps")
    gap_rows = []
    for (team, tm), steps in sorted(per_teammate.items()):
        missing = [s for s in LIFECYCLE_STEPS if not steps.get(s)]
        if missing:
            backend = "?"
            for step_events in steps.values():
                if step_events:
                    backend = step_events[0].get("backend") or "?"
                    break
            gap_rows.append((team, tm, backend, missing))
    if gap_rows:
        for team, tm, backend, missing in gap_rows:
            lines.append(f"- `{team}/{tm}` ({backend}): missing {', '.join(missing)}")
    else:
        lines.append("")
        lines.append("No gaps observed — all teammates hit every lifecycle step.")

    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", default=None)
    ap.add_argument("--output", default="teammate-parity-matrix.md")
    args = ap.parse_args()

    if args.input:
        input_path = Path(args.input)
    else:
        input_path = Path(os.environ.get("HOME", str(Path.home()))) / ".claude" / "clmux" / "events.jsonl"

    events = _read_events(input_path)
    per_tm = _build_per_teammate(events)
    drops = _count_drops(events)
    matrix = _render(per_tm, drops, events)

    Path(args.output).write_text(matrix, encoding="utf-8")
    print(f"Wrote {args.output} ({len(events)} events, {len(per_tm)} teammates, {sum(drops.values())} drops)")


if __name__ == "__main__":
    main()
