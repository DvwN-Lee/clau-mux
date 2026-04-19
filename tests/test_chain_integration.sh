#!/usr/bin/env bash
# tests/test_chain_integration.sh
#
# Validates the 3-layer hierarchy master → mid → leaf → master direct reporting.
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

# Step 1: set-master for %105 — assert role == "master"
$CLI set-master --pane "%105" --label "test-master"
[[ "$($CLI panes --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["%105"]["role"])')" == "master" ]] || { echo "FAIL: %105 role != master"; exit 1; }
echo "step 1 ok: %105 is master"

# Step 2: register mid sub %128 under %105 — assert master_pane == "%105"
$CLI register-sub --pane "%128" --master "%105" --label "test-mid"
[[ "$($CLI panes --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["%128"]["master_pane"])')" == "%105" ]] || { echo "FAIL: %128 master_pane != %105"; exit 1; }
echo "step 2 ok: %128 master_pane == %105"

# Step 3: register leaf sub %200 under %128 — assert master_pane == "%128" (recursive nesting)
$CLI register-sub --pane "%200" --master "%128" --label "test-leaf"
[[ "$($CLI panes --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["%200"]["master_pane"])')" == "%128" ]] || { echo "FAIL: %200 master_pane != %128"; exit 1; }
echo "step 3 ok: %200 master_pane == %128 (recursive nesting verified)"

# Step 4: delegate %105 → %128 — capture MASTER_TID
MASTER_TID=$($CLI delegate --from "%105" --to "%128" --scope "top" --criteria "mid task complete" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])')
[[ -n "$MASTER_TID" ]] || { echo "FAIL: MASTER_TID is empty"; exit 1; }
echo "step 4 ok: MASTER_TID=$MASTER_TID"

# Step 5: %128 acks the master delegation
$CLI ack --thread "$MASTER_TID" --from "%128" --to "%105"
echo "step 5 ok: %128 acked MASTER_TID"

# Step 6: delegate %128 → %200 with --parent MASTER_TID — capture LEAF_TID
LEAF_TID=$($CLI delegate --from "%128" --to "%200" --scope "sub" --criteria "leaf task complete" --parent "$MASTER_TID" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["thread_id"])')
[[ -n "$LEAF_TID" ]] || { echo "FAIL: LEAF_TID is empty"; exit 1; }
echo "step 6 ok: LEAF_TID=$LEAF_TID"

# Step 7: %200 acks the leaf delegation
$CLI ack --thread "$LEAF_TID" --from "%200" --to "%128"
echo "step 7 ok: %200 acked LEAF_TID"

# Step 8 (KEY): leaf→master direct report — cross-layer routing
$CLI report --thread "$LEAF_TID" --from "%200" --to "%105" --summary "leaf-to-master direct" --evidence "cross-layer routing proof"
echo "step 8 ok: %200 reported directly to %105 on LEAF_TID"

# Step 9: %105 inbox must contain an entry with from == "%200"
inbox_from=$($CLI inbox --pane "%105" --json | python3 -c 'import json,sys; items=json.load(sys.stdin); matches=[x for x in items if x.get("from")=="%200"]; print(len(matches))')
[[ "$inbox_from" -ge 1 ]] || { echo "FAIL: %105 inbox has no entry from %200 (got $inbox_from)"; exit 1; }
echo "step 9 ok: %105 inbox has entry from %200"

# Step 10: LEAF_TID thread must contain a report envelope with from=="%200" and to=="%105"
report_found=$($CLI thread --id "$LEAF_TID" --json | python3 -c 'import json,sys; records=json.load(sys.stdin); matches=[r for r in records if r.get("kind")=="report" and r.get("from")=="%200" and r.get("to")=="%105"]; print(len(matches))')
[[ "$report_found" -ge 1 ]] || { echo "FAIL: LEAF_TID thread has no report envelope from %200 to %105 (got $report_found)"; exit 1; }
echo "step 10 ok: LEAF_TID thread contains report from %200 to %105"

# Step 11: verify parent link — leaf thread's thread_meta has parent_thread_id == MASTER_TID
parent_tid=$($CLI thread --id "$LEAF_TID" --json | python3 -c 'import json,sys; records=json.load(sys.stdin); meta=[r for r in records if r.get("kind")=="thread_meta"]; print(meta[0]["body"]["parent_thread_id"] if meta else "")')
[[ "$parent_tid" == "$MASTER_TID" ]] || { echo "FAIL: LEAF_TID parent_thread_id=$parent_tid != MASTER_TID=$MASTER_TID"; exit 1; }
echo "step 11 ok: LEAF_TID parent_thread_id == MASTER_TID"

echo "PASS: 3-layer hierarchy master → mid → leaf → master direct reporting"
