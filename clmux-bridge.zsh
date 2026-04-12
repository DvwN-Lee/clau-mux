#!/usr/bin/env zsh
# clmux-bridge.zsh
# Generic bridge: Claude Code teammate inbox ↔ CLI tmux pane.
# Supports Gemini CLI, Codex CLI, or any MCP-capable CLI.
#
# Usage: clmux-bridge.zsh -p <pane_id> -i <inbox> [-t <timeout>] [-w <idle_pattern>] [-m paste]
#   -p  tmux pane ID                    (e.g. %72)
#   -i  inbox JSON file                 (lead → agent)
#   -t  idle-wait timeout in seconds    (default: 30)
#   -w  grep pattern for idle detection (default: "Type your message")
#   -m  input method: "keys" (default) or "paste" (for TUIs like Codex)

set -uo pipefail

# Ensure PATH includes common binary locations
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Resolve script directory so we can locate scripts/ helpers
CLMUX_DIR="${${(%):-%x}:A:h}"

PANE_ID="" INBOX="" TIMEOUT=30 IDLE_PATTERN="Type your message" INPUT_METHOD="keys"

while getopts "p:i:t:w:m:" opt; do
  case $opt in
    p) PANE_ID="$OPTARG" ;;
    i) INBOX="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    w) IDLE_PATTERN="$OPTARG" ;;
    m) INPUT_METHOD="$OPTARG" ;;
    *) echo "Usage: $0 -p <pane_id> -i <inbox> [-t <timeout>] [-w <idle_pattern>] [-m paste]" >&2; exit 1 ;;
  esac
done

[[ -z "$PANE_ID" ]] && { echo "error: -p required" >&2; exit 1; }
[[ -z "$INBOX" ]]   && { echo "error: -i required" >&2; exit 1; }

[[ ! -f "$INBOX" ]] && echo '[]' > "$INBOX"

# Derive agent name from inbox filename (e.g. gemini-worker.json → gemini-worker)
AGENT_NAME=$(basename "$INBOX" .json)

# ── Functions ─────────────────────────────────────────────────────────────────

wait_for_idle() {
  local elapsed=0
  while (( elapsed < TIMEOUT )); do
    tmux capture-pane -t "$PANE_ID" -p -S -30 | grep -qF "$IDLE_PATTERN" && return 0
    sleep 1
    (( elapsed++ ))
  done
  echo "[clmux-bridge] warning: idle timeout after ${TIMEOUT}s" >&2
  return 1
}

read_unread() {
  python3 "$CLMUX_DIR/scripts/read_unread.py" "$INBOX"
}

mark_read() {
  python3 "$CLMUX_DIR/scripts/mark_read.py" "$INBOX" "$1"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "[clmux-bridge] started — pane:$PANE_ID  agent:$AGENT_NAME  idle:\"$IDLE_PATTERN\""

wait_for_idle || { echo "[clmux-bridge] error: CLI not ready (pattern: $IDLE_PATTERN)" >&2; exit 1; }
echo "[clmux-bridge] ready — polling inbox every 2s (Ctrl+C to stop)"

TEAM_DIR=$(dirname "$(dirname "$INBOX")")

cleanup() {
  rm -f "$TEAM_DIR/.bridge-${AGENT_NAME}.env"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-bridge.pid"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-pane"
  echo "[clmux-bridge] shutting down"
}
trap 'cleanup; exit 0' INT TERM EXIT

while true; do
  if ! command -v tmux &>/dev/null; then
    echo "[clmux-bridge] error: tmux not in PATH, retrying..." >&2
    sleep 5
    continue
  fi
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$PANE_ID" || {
    echo "[clmux-bridge] pane $PANE_ID is gone, notifying lead..." >&2
    python3 "$CLMUX_DIR/scripts/notify_shutdown.py" "$INBOX" "$AGENT_NAME" 2>/dev/null
    exit 0
  }

  msg=$(read_unread)

  if [[ -n "$msg" ]]; then
    text=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['text'])" "$msg")
    ts=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('timestamp',''))" "$msg")
    from=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('from','lead'))" "$msg")

    echo "[clmux-bridge] → from '$from': ${text:0:80}"

    # Intercept shutdown_request before forwarding to pane
    msg_type=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1]); print(d.get('type',''))
except: print('')
" "$text" 2>/dev/null)
    if [[ "$msg_type" == "shutdown_request" ]]; then
      echo "[clmux-bridge] shutdown_request received — terminating $AGENT_NAME" >&2
      request_id=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1]); print(d.get('requestId',''))
except: print('')
" "$text" 2>/dev/null)
      [[ -n "$ts" ]] && mark_read "$ts"
      tmux kill-pane -t "$PANE_ID" 2>/dev/null
      python3 "$CLMUX_DIR/scripts/notify_shutdown.py" "$INBOX" "$AGENT_NAME" "$request_id" 2>/dev/null
      python3 "$CLMUX_DIR/scripts/deactivate_pane.py" "$TEAM_DIR" "$AGENT_NAME" 2>/dev/null
      exit 0
    fi

    wait_for_idle || { echo "[clmux-bridge] warning: not idle before sending" >&2; }

    # Named buffer paste + delayed Enter (eliminates global buffer race + minimizes Enter race)
    _buf="clmux-${$}-${RANDOM}"
    if ! printf '%s' "$text" | tmux load-buffer -b "$_buf" - 2>/dev/null; then
      echo "[clmux-bridge] error: load-buffer failed (pane:$PANE_ID)" >&2
      sleep 2
      continue
    fi
    if ! tmux paste-buffer -d -b "$_buf" -t "$PANE_ID" 2>/dev/null; then
      echo "[clmux-bridge] error: paste-buffer failed (pane:$PANE_ID)" >&2
      tmux delete-buffer -b "$_buf" 2>/dev/null
      sleep 2
      continue
    fi

    # Wait for CLI to render pasted text before sending Enter
    sleep 0.3
    tmux send-keys -t "$PANE_ID" Enter

    [[ -n "$ts" ]] && mark_read "$ts"
  fi

  sleep 2
done
