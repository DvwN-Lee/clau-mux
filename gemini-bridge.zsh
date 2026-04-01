#!/usr/bin/env zsh
# gemini-bridge.zsh
# Bridges Claude Code teammate inbox/outbox protocol ↔ Gemini CLI tmux pane.
#
# Usage: gemini-bridge.zsh -p <pane_id> -i <inbox> -o <outbox> [-n <name>] [-t <timeout>]
#   -p  tmux pane ID                    (e.g. %72)
#   -i  inbox JSON file                 (lead → gemini)
#   -o  outbox JSON file                (gemini → lead)
#   -n  agent name in outgoing messages (default: gemini-worker)
#   -t  response timeout in seconds     (default: 120)

set -uo pipefail

PANE_ID="" INBOX="" OUTBOX="" AGENT_NAME="gemini-worker" TIMEOUT=120

while getopts "p:i:o:n:t:" opt; do
  case $opt in
    p) PANE_ID="$OPTARG" ;;
    i) INBOX="$OPTARG" ;;
    o) OUTBOX="$OPTARG" ;;
    n) AGENT_NAME="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    *) echo "Usage: $0 -p <pane_id> -i <inbox> -o <outbox> [-n <name>] [-t <timeout>]" >&2; exit 1 ;;
  esac
done

[[ -z "$PANE_ID" ]] && { echo "error: -p required" >&2; exit 1; }
[[ -z "$INBOX" ]]   && { echo "error: -i required" >&2; exit 1; }
[[ -z "$OUTBOX" ]]  && { echo "error: -o required" >&2; exit 1; }

[[ ! -f "$INBOX" ]]  && echo '[]' > "$INBOX"
[[ ! -f "$OUTBOX" ]] && echo '[]' > "$OUTBOX"

# ── Python helpers ────────────────────────────────────────────────────────────

cat > /tmp/gbridge_read_unread.py << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    msgs = json.load(f)
unread = [m for m in msgs if not m.get('read', False)]
print(json.dumps(unread[0]) if unread else '', end='')
PYEOF

cat > /tmp/gbridge_mark_read.py << 'PYEOF'
import json, sys
path, ts = sys.argv[1], sys.argv[2]
with open(path) as f:
    msgs = json.load(f)
for m in msgs:
    if m.get('timestamp') == ts:
        m['read'] = True
with open(path, 'w') as f:
    json.dump(msgs, f, indent=2)
PYEOF

cat > /tmp/gbridge_append.py << 'PYEOF'
import json, sys, datetime
path, from_name = sys.argv[1], sys.argv[2]
# 3rd arg: explicit summary ('' = no summary, omit = auto-generate from text)
explicit_summary = sys.argv[3] if len(sys.argv) > 3 else None
text = sys.stdin.read().strip()
if explicit_summary is None:
    first = text.split('\n')[0].strip()
    summary = first[:60] + ('…' if len(first) > 60 else '')
else:
    summary = explicit_summary
try:
    with open(path) as f:
        msgs = json.load(f)
except Exception:
    msgs = []
now = datetime.datetime.utcnow()
ts = now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'
entry = {"from": from_name, "text": text, "timestamp": ts, "read": False}
if summary:
    entry["summary"] = summary
msgs.append(entry)
with open(path, 'w') as f:
    json.dump(msgs, f, indent=2)
PYEOF

cat > /tmp/gbridge_extract.py << 'PYEOF'
import sys
lines = sys.stdin.read().splitlines()
blocks, current, in_block = [], [], False
for line in lines:
    if line.startswith('✦ '):
        if current:
            blocks.append('\n'.join(current))
        current = [line[2:]]
        in_block = True
    elif in_block and line.startswith('  ') and not line.startswith('    '):
        current.append(line[2:])
    else:
        if in_block and current:
            blocks.append('\n'.join(current))
            current = []
        in_block = False
if in_block and current:
    blocks.append('\n'.join(current))
print(blocks[-1].strip() if blocks else '', end='')
PYEOF

cat > /tmp/gbridge_summarize.py << 'PYEOF'
import sys
text = sys.stdin.read().strip()
# Extract first sentence or first line for summary
lines = text.split('\n')
first = lines[0].strip()
if len(first) > 60:
    summary = first[:57] + '...'
else:
    summary = first
print(summary, end='')
PYEOF

cat > /tmp/gbridge_count_blocks.py << 'PYEOF'
import sys
print(sum(1 for l in sys.stdin.read().splitlines() if l.startswith('✦ ')))
PYEOF

# ── Functions ─────────────────────────────────────────────────────────────────

# Count visible ✦ response blocks in pane
count_blocks() {
  tmux capture-pane -t "$PANE_ID" -p -S -200 | python3 /tmp/gbridge_count_blocks.py
}

# Wait until a NEW ✦ block appears (beyond the baseline count), then wait for idle
wait_for_response() {
  local before="$1"
  local elapsed=0
  # Phase 1: wait for new block to appear
  while (( elapsed < TIMEOUT )); do
    local after
    after=$(count_blocks)
    if (( after > before )); then
      break
    fi
    sleep 0.5
    (( elapsed++ ))
  done
  if (( elapsed >= TIMEOUT )); then
    echo "[gemini-bridge] warning: new response never appeared after ${TIMEOUT}s" >&2
    return 1
  fi
  # Phase 2: wait for Gemini to finish (idle prompt)
  while (( elapsed < TIMEOUT )); do
    tmux capture-pane -t "$PANE_ID" -p -S -5 | grep -qF "Type your message" && return 0
    sleep 0.5
    (( elapsed++ ))
  done
  echo "[gemini-bridge] warning: idle timeout after ${TIMEOUT}s" >&2
  return 1
}

# Poll until Gemini shows idle prompt ("Type your message")
wait_for_idle() {
  local elapsed=0
  while (( elapsed < TIMEOUT )); do
    tmux capture-pane -t "$PANE_ID" -p -S -5 | grep -qF "Type your message" && return 0
    sleep 1
    (( elapsed++ ))
  done
  echo "[gemini-bridge] warning: timeout after ${TIMEOUT}s" >&2
  return 1
}

# Extract the last ✦ response block from current pane
extract_response() {
  tmux capture-pane -t "$PANE_ID" -p -S -150 | python3 /tmp/gbridge_extract.py
}

read_unread() {
  python3 /tmp/gbridge_read_unread.py "$INBOX"
}

mark_read() {
  python3 /tmp/gbridge_mark_read.py "$INBOX" "$1"
}

append_outbox() {
  printf '%s' "$1" | python3 /tmp/gbridge_append.py "$OUTBOX" "$AGENT_NAME" "${2:-}"
}

send_idle() {
  printf '{"type":"idle_notification","from":"%s","idleReason":"available"}' "$AGENT_NAME" | \
    python3 /tmp/gbridge_append.py "$OUTBOX" "$AGENT_NAME" ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "[gemini-bridge] started — pane:$PANE_ID  inbox:$INBOX  outbox:$OUTBOX"

wait_for_idle || { echo "[gemini-bridge] error: Gemini not ready" >&2; exit 1; }
echo "[gemini-bridge] Gemini ready — polling inbox every 2s (Ctrl+C to stop)"

trap 'echo "[gemini-bridge] shutting down"; exit 0' INT TERM

while true; do
  msg=$(read_unread)

  if [[ -n "$msg" ]]; then
    text=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['text'])" "$msg")
    ts=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('timestamp',''))" "$msg")
    from=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('from','lead'))" "$msg")

    echo "[gemini-bridge] → from '$from': ${text:0:80}"

    # Ensure Gemini is ready before sending
    wait_for_idle || { echo "[gemini-bridge] warning: not idle before sending message" >&2; }

    local before
    before=$(count_blocks)

    tmux send-keys -t "$PANE_ID" -l "$text"
    sleep 0.1
    tmux send-keys -t "$PANE_ID" Enter

    [[ -n "$ts" ]] && mark_read "$ts"

    if wait_for_response "$before"; then
      # Extra delay to ensure pane rendering is complete (especially for multi-line/unicode)
      sleep 1
      response=$(extract_response)
      echo "[gemini-bridge] ← response: ${response:0:80}"

      # Auto-generate summary from response text (first line/sentence)
      summary=$(printf '%s' "$response" | python3 /tmp/gbridge_summarize.py)
      [[ -n "$summary" ]] && echo "[gemini-bridge] ← summary: $summary"

      append_outbox "$response" "$summary"
      send_idle
    else
      append_outbox "error: response timeout"
      send_idle
    fi
  fi

  sleep 2
done
