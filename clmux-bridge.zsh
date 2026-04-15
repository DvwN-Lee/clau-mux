#!/usr/bin/env zsh
# clmux-bridge.zsh
# Generic bridge: Claude Code teammate inbox ↔ CLI tmux pane.
# Supports Gemini CLI, Codex CLI, or any MCP-capable CLI.
#
# Usage: clmux-bridge.zsh -p <pane_id> -i <inbox> [-t <timeout>] [-w <idle_pattern>]
#   -p  tmux pane ID                    (e.g. %72)
#   -i  inbox JSON file                 (lead → agent)
#   -t  idle-wait timeout in seconds    (default: 60)
#   -w  grep pattern for idle detection (default: "Type your message")
#
# All CLIs use named buffer paste + delayed Enter for input delivery.

set -uo pipefail

# Ensure PATH includes common binary locations
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# Resolve script directory so we can locate scripts/ helpers
CLMUX_DIR="${${(%):-%x}:A:h}"

PANE_ID="" INBOX="" TIMEOUT=60 IDLE_PATTERN="Type your message"

while getopts "p:i:t:w:" opt; do
  case $opt in
    p) PANE_ID="$OPTARG" ;;
    i) INBOX="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    w) IDLE_PATTERN="$OPTARG" ;;
    *) echo "Usage: $0 -p <pane_id> -i <inbox> [-t <timeout>] [-w <idle_pattern>]" >&2; exit 1 ;;
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
  # Match the IDLE_PATTERN (extended regex) within the last 8 non-empty
  # lines — the prompt area. gemini's prompt sits 4-5 lines above the
  # bottom due to its workspace/branch/model footer, so we can't narrow
  # below tail -8 safely. Using grep -qE (not -qF) lets each CLI wrapper
  # anchor its pattern to reduce false positives from the CLI's own
  # response text that happens to contain the pattern (e.g. a code
  # example quoting the › prompt glyph).
  while (( elapsed < TIMEOUT )); do
    tmux capture-pane -t "$PANE_ID" -p | grep -v '^\s*$' | tail -8 | grep -qE "$IDLE_PATTERN" && return 0
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

# Trap MUST be set before wait_for_idle: an early `exit 1` from a failed
# initial idle-wait would otherwise skip cleanup and leave config.json with
# isActive:true (Ghost Agent) and orphan marker files.
TEAM_DIR=$(dirname "$(dirname "$INBOX")")

cleanup() {
  # Skip all cleanup work if the team directory is already gone
  # (external TeamDelete, manual rm, TeamCreate rebuild race). Nothing
  # to clean up, nothing to notify, and calling the Python helpers
  # would just generate noisy tracebacks.
  if [[ ! -d "$TEAM_DIR" ]]; then
    echo "[clmux-bridge] team dir gone, skipping cleanup" >&2
    return 0
  fi
  rm -f "$TEAM_DIR/.bridge-${AGENT_NAME}.env"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-bridge.pid"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-pane"
  python3 "$CLMUX_DIR/scripts/deactivate_pane.py" "$TEAM_DIR" "$AGENT_NAME" 2>/dev/null
  # Invariant: queue lifecycle = agent session lifecycle. On any exit,
  # discard remaining messages so the next spawn starts from a clean queue.
  python3 "$CLMUX_DIR/scripts/purge_inbox.py" "$INBOX" 2>/dev/null
  echo "[clmux-bridge] shutting down"
}
trap 'cleanup; exit 0' INT TERM EXIT

wait_for_idle || { echo "[clmux-bridge] error: CLI not ready (pattern: $IDLE_PATTERN)" >&2; exit 1; }
echo "[clmux-bridge] ready — polling inbox every 2s (Ctrl+C to stop)"

_defer_count=0
_paste_fail_count=0
while true; do
  if ! command -v tmux &>/dev/null; then
    echo "[clmux-bridge] error: tmux not in PATH, retrying..." >&2
    sleep 5
    continue
  fi
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$PANE_ID" || {
    echo "[clmux-bridge] pane $PANE_ID is gone, notifying lead..." >&2
    # Skip notify_shutdown if the team dir is already gone — there's
    # no one to notify. notify_shutdown.py itself degrades gracefully,
    # but short-circuiting here avoids even the silent stderr warning.
    if [[ -d "$TEAM_DIR" ]]; then
      python3 "$CLMUX_DIR/scripts/notify_shutdown.py" "$INBOX" "$AGENT_NAME"
    else
      echo "[clmux-bridge] team dir gone, skipping lead notification" >&2
    fi
    exit 0
  }

  msg=$(read_unread)

  if [[ -n "$msg" ]]; then
    _parsed=""
    if ! _parsed=$(python3 "$CLMUX_DIR/scripts/parse_message.py" "$msg" 2>/dev/null) || [[ -z "$_parsed" ]]; then
      echo "[clmux-bridge] error: failed to parse message, skipping" >&2
      ts=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('timestamp',''))" "$msg" 2>/dev/null)
      [[ -n "$ts" ]] && mark_read "$ts"
      sleep 2
      continue
    fi
    text="${_parsed%%$'\0'*}"; _parsed="${_parsed#*$'\0'}"
    ts="${_parsed%%$'\0'*}"
    from="${_parsed#*$'\0'}"

    if (( ${#text} > 120 )); then
      echo "[clmux-bridge] → from '$from' (${#text} chars): ${text:0:120}…"
    else
      echo "[clmux-bridge] → from '$from': $text"
    fi

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
      python3 "$CLMUX_DIR/scripts/notify_shutdown.py" "$INBOX" "$AGENT_NAME" "$request_id"
      exit 0   # cleanup trap calls deactivate_pane.py
    fi

    if ! wait_for_idle; then
      (( _defer_count++ ))
      if (( _defer_count >= 6 )); then
        # Per queue-lifecycle invariant: persistent unresponsiveness ends
        # the agent session. Killing the pane triggers cleanup() which
        # purges the inbox so messages don't linger as data loss.
        echo "[clmux-bridge] error: idle timeout after ${_defer_count} retries, killing pane (queue will be purged)" >&2
        tmux kill-pane -t "$PANE_ID" 2>/dev/null
        exit 0
      fi
      echo "[clmux-bridge] warning: not idle, deferring send (${_defer_count}/6)" >&2
      sleep 5
      continue
    fi
    _defer_count=0

    # Delivery: chunked paste-buffer for large msgs, single paste for small.
    # paste-buffer uses bracketed paste (\e[200~...\e[201~) which protects newlines
    # from being interpreted as Enter. But Gemini CLI truncates at ~1024 bytes per
    # paste event. Fix: split into <=300 char chunks (<=900 bytes for 3-byte UTF-8),
    # each pasted separately with bracketed paste protection.
    _text_len=${#text}
    if (( _text_len > 300 )); then
      _pos=0; _csz=300; _chunk_fail=false; _ci=0
      while (( _pos < _text_len )); do
        _buf="clmux-${$}-${RANDOM}"
        if ! printf '%s' "${text:$_pos:$_csz}" | tmux load-buffer -b "$_buf" - 2>/dev/null; then
          echo "[clmux-bridge] error: chunk load-buffer failed (pane:$PANE_ID)" >&2
          _chunk_fail=true; break
        fi
        if ! tmux paste-buffer -d -p -b "$_buf" -t "$PANE_ID" 2>/dev/null; then
          echo "[clmux-bridge] error: chunk paste-buffer failed (pane:$PANE_ID)" >&2
          tmux delete-buffer -b "$_buf" 2>/dev/null
          _chunk_fail=true; break
        fi
        (( _pos += _csz ))
        (( _ci++ ))
        # Batch pause: every 5 chunks, let PTY drain to prevent buffer saturation
        if (( _ci % 5 == 0 )); then
          sleep 0.3
        else
          sleep 0.05
        fi
      done
      if [[ "$_chunk_fail" == true ]]; then
        (( _paste_fail_count++ ))
        if (( _paste_fail_count >= 3 )); then
          echo "[clmux-bridge] error: paste-buffer failed ${_paste_fail_count} times, killing pane (queue will be purged)" >&2
          tmux kill-pane -t "$PANE_ID" 2>/dev/null
          exit 0
        fi
        sleep 2; continue
      fi
    else
      _buf="clmux-${$}-${RANDOM}"
      _single_fail=false
      if ! printf '%s' "$text" | tmux load-buffer -b "$_buf" - 2>/dev/null; then
        echo "[clmux-bridge] error: load-buffer failed (pane:$PANE_ID)" >&2
        _single_fail=true
      elif ! tmux paste-buffer -d -p -b "$_buf" -t "$PANE_ID" 2>/dev/null; then
        echo "[clmux-bridge] error: paste-buffer failed (pane:$PANE_ID)" >&2
        tmux delete-buffer -b "$_buf" 2>/dev/null
        _single_fail=true
      fi
      if [[ "$_single_fail" == true ]]; then
        (( _paste_fail_count++ ))
        if (( _paste_fail_count >= 3 )); then
          echo "[clmux-bridge] error: paste-buffer failed ${_paste_fail_count} times, killing pane (queue will be purged)" >&2
          tmux kill-pane -t "$PANE_ID" 2>/dev/null
          exit 0
        fi
        sleep 2
        continue
      fi
    fi

    # Send Enter with retry. Detection strategy: compare pane content hash before
    # and after Enter. Any change (Thinking..., response, etc.) means accepted.
    # Idle-pattern check alone is unreliable: Gemini may process fast and return
    # to idle before the 2s sleep completes, making it look like Enter was ignored.
    _nchunks=$(( (_text_len / 300) + 1 ))
    _delay=$(( 0.5 + _nchunks * 0.2 ))
    (( _delay > 8.0 )) && _delay=8.0
    sleep $_delay
    _pre_hash=$(tmux capture-pane -t "$PANE_ID" -p 2>/dev/null | md5)
    _enter_ok=false
    for _try in 1 2 3 4 5; do
      tmux send-keys -t "$PANE_ID" Enter
      sleep 3
      _post_hash=$(tmux capture-pane -t "$PANE_ID" -p 2>/dev/null | md5)
      if [[ "$_pre_hash" != "$_post_hash" ]]; then
        _enter_ok=true; break
      fi
      echo "[clmux-bridge] warning: Enter not accepted, retry (${_try}/5)" >&2
    done
    [[ "$_enter_ok" == false ]] && echo "[clmux-bridge] error: Enter not accepted after 5 retries" >&2

    [[ -n "$ts" ]] && mark_read "$ts"
    _paste_fail_count=0
  fi

  sleep 2
done
