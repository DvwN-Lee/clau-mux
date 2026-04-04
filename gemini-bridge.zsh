#!/usr/bin/env zsh
# gemini-bridge.zsh
# Bridges Claude Code teammate inbox/outbox protocol ↔ Gemini CLI tmux pane.
#
# Usage: gemini-bridge.zsh -p <pane_id> -i <inbox> [-t <timeout>]
#   -p  tmux pane ID                    (e.g. %72)
#   -i  inbox JSON file                 (lead → gemini)
#   -t  idle-wait timeout in seconds    (default: 30)

set -uo pipefail

# Ensure PATH includes common binary locations
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

PANE_ID="" INBOX="" TIMEOUT=30

while getopts "p:i:t:" opt; do
  case $opt in
    p) PANE_ID="$OPTARG" ;;
    i) INBOX="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    *) echo "Usage: $0 -p <pane_id> -i <inbox> [-t <timeout>]" >&2; exit 1 ;;
  esac
done

[[ -z "$PANE_ID" ]] && { echo "error: -p required" >&2; exit 1; }
[[ -z "$INBOX" ]]   && { echo "error: -i required" >&2; exit 1; }

[[ ! -f "$INBOX" ]] && echo '[]' > "$INBOX"

# Derive agent name from inbox filename (e.g. gemini-worker.json → gemini-worker)
AGENT_NAME=$(basename "$INBOX" .json)

# ── Python helpers ────────────────────────────────────────────────────────────

cat > /tmp/gbridge_read_unread.py << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    msgs = json.load(f)
unread = [m for m in msgs if not m.get('read', False)]
print(json.dumps(unread[0]) if unread else '', end='')
PYEOF

cat > /tmp/gbridge_mark_read.py << 'PYEOF'
import json, sys, tempfile, os
path, ts = sys.argv[1], sys.argv[2]
with open(path) as f:
    msgs = json.load(f)
for m in msgs:
    if m.get('timestamp') == ts:
        m['read'] = True
dir_ = os.path.dirname(os.path.abspath(path))
with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(msgs, tf, indent=2)
    tmp_name = tf.name
os.replace(tmp_name, path)
PYEOF

cat > /tmp/gbridge_notify_shutdown.py << 'PYEOF'
import json, sys, datetime, tempfile, os
inbox_path, agent_name = sys.argv[1], sys.argv[2]
outbox_path = os.path.join(os.path.dirname(inbox_path), 'team-lead.json')
try:
    with open(outbox_path) as f:
        msgs = json.load(f)
except Exception:
    msgs = []
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'
msgs.append({"from": agent_name, "text": f"{agent_name} has shut down.", "timestamp": ts, "read": False, "summary": f"{agent_name} terminated"})
if len(msgs) > 50:
    msgs = msgs[-50:]
dir_ = os.path.dirname(os.path.abspath(outbox_path))
with tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(msgs, tf, indent=2, ensure_ascii=False)
    tmp_name = tf.name
os.replace(tmp_name, outbox_path)
PYEOF

# ── Functions ─────────────────────────────────────────────────────────────────

# Poll until Gemini shows idle prompt ("Type your message")
wait_for_idle() {
  local elapsed=0
  while (( elapsed < TIMEOUT )); do
    tmux capture-pane -t "$PANE_ID" -p -S -5 | grep -qF "Type your message" && return 0
    sleep 1
    (( elapsed++ ))
  done
  echo "[gemini-bridge] warning: idle timeout after ${TIMEOUT}s" >&2
  return 1
}

read_unread() {
  python3 /tmp/gbridge_read_unread.py "$INBOX"
}

mark_read() {
  python3 /tmp/gbridge_mark_read.py "$INBOX" "$1"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "[gemini-bridge] started — pane:$PANE_ID  inbox:$INBOX"

wait_for_idle || { echo "[gemini-bridge] error: Gemini not ready" >&2; exit 1; }
echo "[gemini-bridge] Gemini ready — sending activation prompt"

# Send initial activation prompt so lead receives a ready notification
tmux send-keys -t "$PANE_ID" -l "You are now connected as a Claude Code teammate. Briefly introduce yourself in Korean."
sleep 0.1
tmux send-keys -t "$PANE_ID" Enter

echo "[gemini-bridge] polling inbox every 2s (Ctrl+C to stop)"

trap 'echo "[gemini-bridge] shutting down"; exit 0' INT TERM

while true; do
  # Guard: exit if tmux is not available or pane is gone
  if ! command -v tmux &>/dev/null; then
    echo "[gemini-bridge] error: tmux not in PATH, retrying..." >&2
    sleep 5
    continue
  fi
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q "$PANE_ID" || {
    echo "[gemini-bridge] pane $PANE_ID is gone, notifying lead..." >&2
    python3 /tmp/gbridge_notify_shutdown.py "$INBOX" "$AGENT_NAME" 2>/dev/null
    echo "[gemini-bridge] shutting down" >&2; exit 0
  }

  msg=$(read_unread)

  if [[ -n "$msg" ]]; then
    text=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['text'])" "$msg")
    ts=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('timestamp',''))" "$msg")
    from=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('from','lead'))" "$msg")

    echo "[gemini-bridge] → from '$from': ${text:0:80}"

    wait_for_idle || { echo "[gemini-bridge] warning: not idle before sending" >&2; }

    tmux send-keys -t "$PANE_ID" -l "$text"
    sleep 0.1
    tmux send-keys -t "$PANE_ID" Enter

    [[ -n "$ts" ]] && mark_read "$ts"
    # MCP 서버가 응답 전달을 담당하므로 응답 대기 불필요
  fi

  sleep 2
done
