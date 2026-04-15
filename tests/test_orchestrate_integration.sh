#!/usr/bin/env bash
# tests/test_orchestrate_integration.sh
#
# Exercises the full master → sub flow without tmux.
# Uses an isolated HOME so the test never touches the user's real
# orchestration state.
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

export HOME="$tmpdir"
# [test isolation] suppress notify_pane so subprocess CLI calls don't paste
# into the operator's real tmux panes (e.g. %105/%128 if they happen to exist).
export CLMUX_ORCH_NO_NOTIFY=1
CLI="python3 $CLMUX_DIR/scripts/clmux_orchestrate.py"

# Step 1: master claim
$CLI set-master --pane "%105" --label "test-main"
[[ "$($CLI panes --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["%105"]["role"])')" == "master" ]] || { echo "FAIL: master not registered"; exit 1; }

# Step 2: register sub
$CLI register-sub --pane "%128" --master "%105" --label "test-sub"

# Step 3: delegate
tid=$($CLI delegate --from "%105" --to "%128" \
      --scope "test task" --criteria "done when asserted" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])')
echo "delegated thread: $tid"

# Step 4: %128 inbox has one alert
alerts=$($CLI inbox --pane "%128" --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
[[ "$alerts" == "1" ]] || { echo "FAIL: %128 inbox size != 1 ($alerts)"; exit 1; }

# Step 5: sub acks
$CLI ack --thread "$tid" --from "%128" --to "%105"

# Step 6: sub reports
$CLI report --thread "$tid" --from "%128" --to "%105" \
  --summary "all good" --evidence "test passed"

state=$($CLI thread --id "$tid" --json | python3 -c 'import json,sys; kinds=[r["kind"] for r in json.load(sys.stdin)]; print(",".join(kinds))')
echo "thread kinds: $state"
[[ "$state" == *"thread_meta"* && "$state" == *"delegate"* && "$state" == *"ack"* && "$state" == *"report"* ]] \
  || { echo "FAIL: thread events missing"; exit 1; }

# Step 7: master accepts
$CLI accept --thread "$tid" --from "%105" --to "%128"

# Step 8: master closes
$CLI close --thread "$tid" --note "test approved"

# Step 9: resume shows no in-flight for %105
inflight=$($CLI resume --pane "%105" --json \
         | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["in_flight_threads"]))')
[[ "$inflight" == "0" ]] || { echo "FAIL: %105 still has in-flight threads ($inflight)"; exit 1; }

# Step 10: meeting lifecycle
# Pre-create a fake team dir that end_meeting will archive
mkdir -p "$tmpdir/.claude/teams/meeting-it1/inboxes"
echo '{"name":"meeting-it1","members":[{"name":"codex","agentType":"bridge"}]}' \
  > "$tmpdir/.claude/teams/meeting-it1/config.json"
echo '[]' > "$tmpdir/.claude/teams/meeting-it1/inboxes/team-lead.json"
echo '[]' > "$tmpdir/.claude/teams/meeting-it1/inboxes/codex.json"

mid=$($CLI meeting start --pane "%105" --topic "test meeting" --team "meeting-it1" --json \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["meeting_id"])')
echo "meeting: $mid"

# Meeting should be locked
if $CLI meeting start --pane "%105" --topic "second" --team "meeting-it2" --json 2>/dev/null; then
  echo "FAIL: concurrent meeting should have been rejected"; exit 1
fi

$CLI meeting end --meeting-id "$mid" --synthesis "Decision: merge"

# Archive exists and is WORM
archive="$tmpdir/.claude/orchestration/meetings/$mid"
[[ -f "$archive/metadata.json" ]] || { echo "FAIL: archive metadata missing"; exit 1; }
mode=$(stat -f '%Mp%Lp' "$archive/metadata.json" 2>/dev/null || stat -c '%a' "$archive/metadata.json")
[[ "$mode" == *"444" ]] || { echo "FAIL: archive not WORM (mode=$mode)"; exit 1; }

echo "PASS: full orchestration cycle + meeting archive"
