#!/usr/bin/env bash
# tests/test_parity_integration.sh
#
# End-to-end: simulate hook inputs + update_pane invocation + bridge
# helper call; then run analyzer; verify matrix mentions all three
# synthetic teammates and flags the bridge's missing 'registered' step.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"

repo="$(cd "$(dirname "$0")/.." && pwd)"
events="$tmp/.claude/clmux/events.jsonl"

echo '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"TeamCreate","tool_input":{"team_name":"probe"},"tool_response":{"team_name":"probe"}}' \
  | python3 "$repo/hooks/emit_tool_event.py"

for i in native-1 native-2; do
  echo "{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s\",\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"name\":\"$i\"},\"tool_response\":{\"agent_id\":\"$i@probe\"}}" \
    | python3 "$repo/hooks/emit_tool_event.py"
done

mkdir -p "$tmp/.claude/teams/probe"
python3 "$repo/scripts/update_pane.py" \
    "$tmp/.claude/teams/probe" "bridge-1" "%999" "codex-cli" "0"

echo '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"SendMessage","tool_input":{"to":"native-1","message":"hi","summary":"p"},"tool_response":{"success":true,"routing":{"sender":"team-lead","target":"@native-1"}}}' \
  | python3 "$repo/hooks/emit_tool_event.py"

python3 "$repo/scripts/_events_zsh_helper.py" teammate.message_delivered \
    --source bridge_daemon --teammate native-1 --team-name probe \
    --agent-type bridge --backend external-cli --pane-id "%999"

echo '{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"SendMessage","tool_input":{"to":"bridge-1","message":"hi","summary":"p"},"tool_response":{"success":true,"routing":{"sender":"team-lead","target":"@bridge-1"}}}' \
  | python3 "$repo/hooks/emit_tool_event.py"

test -s "$events"
n=$(wc -l < "$events")
[[ "$n" -ge 8 ]] || { echo "FAIL: expected >=8 events, got $n"; cat "$events"; exit 1; }

out="$tmp/matrix.md"
python3 "$repo/scripts/analyze_events.py" --output "$out"

grep -q "probe" "$out" || { echo "FAIL: team 'probe' missing"; exit 1; }
grep -q "native-1" "$out" || { echo "FAIL: native-1 missing"; exit 1; }
grep -q "bridge-1" "$out" || { echo "FAIL: bridge-1 missing"; exit 1; }
grep -q "Message drop" "$out" || grep -qi "drops" "$out" \
  || { echo "FAIL: drop section missing"; exit 1; }
grep -q "bridge-1.*1 dropped" "$out" || grep -E "bridge-1.*\| *1 *\|" "$out" >/dev/null \
  || { echo "FAIL: bridge-1 drop not flagged"; cat "$out"; exit 1; }

echo "PASS: parity integration end-to-end"
