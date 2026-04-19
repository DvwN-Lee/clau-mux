# ── Chain topology helpers ────────────────────────────────────────────────────
# Used by the clmux-chain-{master,mid,leaf} skills to enforce a strict tree
# chain: Master → Mid(s) → Leaf(s). Each pane stores its role + peers as tmux
# pane options so the skill can read them at runtime without a separate
# registry file. Pane options vanish when the pane dies, so "alive role" is
# structurally tied to pane lifecycle (same pattern as @clmux-agent).

# clmux-chain-register — assign role + peers to a pane.
#
# Usage:
#   clmux-chain-register --role master                  --pane <id> [--peer-down <csv>]
#   clmux-chain-register --role mid     --peer-up <id> --pane <id> [--peer-down <csv>]
#   clmux-chain-register --role leaf    --peer-up <id> --pane <id>
#
# Where <csv> is a comma-separated list of pane IDs. --peer-down is optional
# at register time because Mid/Master may add leaves incrementally; they can
# call --add-peer-down later.
clmux-chain-register() {
  local role="" pane="" peer_up="" peer_down="" add_peer_down=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --role)           role="$2"; shift 2 ;;
      --pane)           pane="$2"; shift 2 ;;
      --peer-up)        peer_up="$2"; shift 2 ;;
      --peer-down)      peer_down="$2"; shift 2 ;;
      --add-peer-down)  add_peer_down="$2"; shift 2 ;;
      *) echo "error: unknown arg $1" >&2; return 1 ;;
    esac
  done
  [[ -z "$role" || -z "$pane" ]] && { echo "error: --role and --pane required" >&2; return 1; }
  [[ "$role" =~ ^(master|mid|leaf)$ ]] || { echo "error: --role must be master|mid|leaf" >&2; return 1; }
  tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$pane" || { echo "error: pane $pane not found" >&2; return 1; }

  tmux set-option -p -t "$pane" @clmux-chain-role "$role"
  [[ -n "$peer_up" ]]   && tmux set-option -p -t "$pane" @clmux-chain-peer-up "$peer_up"
  [[ -n "$peer_down" ]] && tmux set-option -p -t "$pane" @clmux-chain-peer-down "$peer_down"
  if [[ -n "$add_peer_down" ]]; then
    local cur
    cur=$(tmux show-options -p -t "$pane" -v @clmux-chain-peer-down 2>/dev/null)
    [[ -n "$cur" ]] && tmux set-option -p -t "$pane" @clmux-chain-peer-down "${cur},${add_peer_down}" \
                    || tmux set-option -p -t "$pane" @clmux-chain-peer-down "$add_peer_down"
  fi
  echo "[chain] pane=$pane role=$role peer-up=${peer_up:-none} peer-down=$(tmux show-options -p -t "$pane" -v @clmux-chain-peer-down 2>/dev/null || echo none)"
}

# clmux-chain-check — alive check of the chain for a given pane.
# Returns 0 if all declared peers are alive; prints missing peers to stderr
# and returns 1 otherwise. Skill handlers call this before every send.
#
# Usage:
#   clmux-chain-check [<pane>] [--verbose]
#   clmux-chain-check [--verbose] [<pane>]
#
# --verbose appends a diagnostic block (helper availability, env) without
# affecting the exit status.
clmux-chain-check() {
  local verbose=0 pane=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --verbose) verbose=1; shift ;;
      -*) echo "error: unknown arg $1" >&2; return 1 ;;
      *)  [[ -z "$pane" ]] && pane="$1" || { echo "error: unexpected $1" >&2; return 1; }; shift ;;
    esac
  done
  pane="${pane:-$TMUX_PANE}"

  local peer_up peer_down
  peer_up=$(tmux show-options -p -t "$pane" -v @clmux-chain-peer-up 2>/dev/null)
  peer_down=$(tmux show-options -p -t "$pane" -v @clmux-chain-peer-down 2>/dev/null)
  local alive_panes missing=()
  alive_panes=$(tmux list-panes -a -F '#{pane_id}')
  [[ -n "$peer_up" ]] && ! grep -qx -- "$peer_up" <<< "$alive_panes" && missing+=("peer-up:$peer_up")
  if [[ -n "$peer_down" ]]; then
    local p
    for p in ${(s:,:)peer_down}; do
      [[ -n "$p" ]] && ! grep -qx -- "$p" <<< "$alive_panes" && missing+=("peer-down:$p")
    done
  fi
  if (( ${#missing[@]} > 0 )); then
    echo "[chain] BROKEN at $pane: ${missing[*]}" >&2
    if (( verbose )); then
      echo "[diag] CLMUX_DIR=${CLMUX_DIR:-<unset>}"
      echo "[diag] tmux=$(tmux -V 2>/dev/null | head -1)"
      echo "[diag] claude=$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | head -1 || echo '<not found>')"
      echo "[diag] zsh=${ZSH_VERSION:-<unknown>}"
      echo "[diag] helper availability:"
      local _expected=(
        clmux clmux-ls clmux-cleanup clmux-orchestrate clmux-pipeline
        clmux-chain-register clmux-chain-check clmux-chain-map clmux-chain-unregister
        clmux-master clmux-mid clmux-leaf
        clmux-master-stop clmux-mid-stop clmux-leaf-stop
        clmux-gemini clmux-gemini-stop clmux-codex clmux-codex-stop
        clmux-copilot clmux-copilot-stop
        clmux-send clmux-teammate-check
      )
      local _missing_count=0
      local _fn
      for _fn in $_expected; do
        if typeset -f "$_fn" >/dev/null 2>&1; then
          printf '  + %s\n' "$_fn"
        else
          printf '  - %s   <MISSING>\n' "$_fn"
          _missing_count=$(( _missing_count + 1 ))
        fi
      done
      if (( _missing_count > 0 )); then
        echo "[diag] $_missing_count helper(s) missing. Remediation: exec zsh (reloads .zshrc → clmux.zsh dispatcher → lib/*.zsh)"
      fi
    fi
    return 1
  fi
  echo "[chain] OK pane=$pane peer-up=${peer_up:-none} peer-down=${peer_down:-none}"
  if (( verbose )); then
    echo "[diag] CLMUX_DIR=${CLMUX_DIR:-<unset>}"
    echo "[diag] tmux=$(tmux -V 2>/dev/null | head -1)"
    echo "[diag] claude=$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | head -1 || echo '<not found>')"
    echo "[diag] zsh=${ZSH_VERSION:-<unknown>}"
    echo "[diag] helper availability:"
    local _expected=(
      clmux clmux-ls clmux-cleanup clmux-orchestrate clmux-pipeline
      clmux-chain-register clmux-chain-check clmux-chain-map clmux-chain-unregister
      clmux-master clmux-mid clmux-leaf
      clmux-master-stop clmux-mid-stop clmux-leaf-stop
      clmux-gemini clmux-gemini-stop clmux-codex clmux-codex-stop
      clmux-copilot clmux-copilot-stop
      clmux-send clmux-teammate-check
    )
    local _missing_count=0
    local _fn
    for _fn in $_expected; do
      if typeset -f "$_fn" >/dev/null 2>&1; then
        printf '  + %s\n' "$_fn"
      else
        printf '  - %s   <MISSING>\n' "$_fn"
        _missing_count=$(( _missing_count + 1 ))
      fi
    done
    if (( _missing_count > 0 )); then
      echo "[diag] $_missing_count helper(s) missing. Remediation: exec zsh (reloads .zshrc → clmux.zsh dispatcher → lib/*.zsh)"
    fi
  fi
}

# clmux-chain-map — JSON snapshot of all chain-registered panes. Master uses
# this for on-demand monitoring; leaves/mids don't need it.
clmux-chain-map() {
  local entries=()
  local p role up down
  for p in $(tmux list-panes -a -F '#{pane_id}'); do
    role=$(tmux show-options -p -t "$p" -v @clmux-chain-role 2>/dev/null)
    [[ -z "$role" ]] && continue
    up=$(tmux show-options -p -t "$p" -v @clmux-chain-peer-up 2>/dev/null)
    down=$(tmux show-options -p -t "$p" -v @clmux-chain-peer-down 2>/dev/null)
    entries+=("{\"pane\":\"$p\",\"role\":\"$role\",\"peer_up\":\"${up:-}\",\"peer_down\":\"${down:-}\"}")
  done
  if (( ${#entries} == 0 )); then
    echo "[]"
  else
    printf '%s\n' "${entries[@]}" | python3 -c "import json,sys; print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()], indent=2))"
  fi
}

# clmux-chain-snapshot — one-shot diagnostic: answers "can I send upstream right
# now?" without requiring 8 separate commands. Always emits JSON.
#
# Usage:
#   clmux-chain-snapshot [--pane <id>]
#
# --pane <id>   Inspect a specific pane. Default: $TMUX_PANE.
#
# Output fields: pane, role, peer_up, peer_down, open_threads_up,
#   open_threads_down, inbox_pending_count, can_send_up,
#   reason_cannot_send_up, last_chain_check.
clmux-chain-snapshot() {
  local _pane="${TMUX_PANE}"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --pane) _pane="$2"; shift 2 ;;
      *) echo "error: unknown arg $1" >&2; return 1 ;;
    esac
  done

  # --- collect raw state ---
  local _role _peer_up_id _peer_down_csv
  _role=$(tmux show-options -p -t "$_pane" -v @clmux-chain-role 2>/dev/null)
  _peer_up_id=$(tmux show-options -p -t "$_pane" -v @clmux-chain-peer-up 2>/dev/null)
  _peer_down_csv=$(tmux show-options -p -t "$_pane" -v @clmux-chain-peer-down 2>/dev/null)

  local _alive_panes
  _alive_panes=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null)

  # --- peer_up alive check ---
  local _peer_up_alive="false"
  if [[ -n "$_peer_up_id" ]] && grep -qx -- "$_peer_up_id" <<< "$_alive_panes"; then
    _peer_up_alive="true"
  fi

  # --- peer_up JSON object ---
  local _peer_up_json
  if [[ -z "$_peer_up_id" ]]; then
    _peer_up_json="null"
  else
    _peer_up_json="{\"pane\":\"$_peer_up_id\",\"alive\":$_peer_up_alive,\"label\":\"\"}"
  fi

  # --- peer_down JSON array ---
  local _peer_down_json="[]"
  if [[ -n "$_peer_down_csv" ]]; then
    local _pd_entries=() _p _pa
    for _p in ${(s:,:)_peer_down_csv}; do
      if grep -qx -- "$_p" <<< "$_alive_panes"; then
        _pa="true"
      else
        _pa="false"
      fi
      _pd_entries+=("{\"pane\":\"$_p\",\"alive\":$_pa,\"label\":\"\"}")
    done
    _peer_down_json="[$(IFS=,; echo "${_pd_entries[*]}")]"
  fi

  # --- threads up / down ---
  local _threads_up_json _threads_down_json
  _threads_up_json=$(clmux-orchestrate threads --pane "$_pane" --role target --state open --json 2>/dev/null || echo '[]')
  _threads_down_json=$(clmux-orchestrate threads --pane "$_pane" --role delegator --state open --json 2>/dev/null || echo '[]')

  # --- inbox pending count ---
  local _inbox_count
  _inbox_count=$(clmux-orchestrate inbox --pane "$_pane" --json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "0")
  [[ -z "$_inbox_count" ]] && _inbox_count="0"

  # --- can_send_up logic ---
  local _can_send_up _reason_json
  local _open_up_count
  _open_up_count=$(printf '%s' "$_threads_up_json" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  [[ -z "$_open_up_count" ]] && _open_up_count="0"

  if [[ -z "$_peer_up_id" ]]; then
    _can_send_up="false"
    _reason_json="no peer_up registered (Mode B or pre-registration)"
  elif [[ "$_peer_up_alive" == "false" ]]; then
    _can_send_up="false"
    _reason_json="peer_up pane is not alive"
  elif (( _open_up_count > 0 )); then
    _can_send_up="true"
    _reason_json=""
  else
    _can_send_up="false"
    _reason_json="no open parent thread; upstream can open delegate, or use clmux-orchestrate notify for unsolicited send"
  fi

  # --- chain check ---
  local _cc_output _cc_exit _last_cc_raw
  _cc_output=$(clmux-chain-check "$_pane" 2>&1)
  _cc_exit=$?
  if (( _cc_exit == 0 )); then
    _last_cc_raw="OK"
  else
    _last_cc_raw="$_cc_output"
  fi

  # --- assemble JSON via python3 tempfile (no heredoc) ---
  local _pyscript
  _pyscript=$(mktemp -t clmux-snap.XXXXXX)
  printf '%s\n' \
    'import json, os, sys' \
    'peer_up_raw  = os.environ["SNAP_PEER_UP"]' \
    'peer_down_raw= os.environ["SNAP_PEER_DOWN"]' \
    'tup_raw      = os.environ["SNAP_THREADS_UP"]' \
    'tdn_raw      = os.environ["SNAP_THREADS_DOWN"]' \
    'reason_raw   = os.environ["SNAP_REASON"]' \
    'last_cc_raw  = os.environ["SNAP_LAST_CC"]' \
    'can_up_raw   = os.environ["SNAP_CAN_SEND_UP"]' \
    'doc = {' \
    '    "pane":               os.environ["SNAP_PANE"],' \
    '    "role":               os.environ["SNAP_ROLE"],' \
    '    "peer_up":            json.loads(peer_up_raw),' \
    '    "peer_down":          json.loads(peer_down_raw),' \
    '    "open_threads_up":    json.loads(tup_raw),' \
    '    "open_threads_down":  json.loads(tdn_raw),' \
    '    "inbox_pending_count":int(os.environ["SNAP_INBOX_COUNT"]),' \
    '    "can_send_up":        can_up_raw == "true",' \
    '    "reason_cannot_send_up": reason_raw if reason_raw else None,' \
    '    "last_chain_check":   last_cc_raw,' \
    '}' \
    'print(json.dumps(doc, indent=2, ensure_ascii=False))' \
    > "$_pyscript"

  SNAP_PANE="$_pane" \
  SNAP_ROLE="$_role" \
  SNAP_PEER_UP="$_peer_up_json" \
  SNAP_PEER_DOWN="$_peer_down_json" \
  SNAP_THREADS_UP="$_threads_up_json" \
  SNAP_THREADS_DOWN="$_threads_down_json" \
  SNAP_INBOX_COUNT="$_inbox_count" \
  SNAP_CAN_SEND_UP="$_can_send_up" \
  SNAP_REASON="$_reason_json" \
  SNAP_LAST_CC="$_last_cc_raw" \
    python3 "$_pyscript"
  local _py_exit=$?
  rm -f "$_pyscript"
  if (( _py_exit != 0 )); then
    echo "error: snapshot render failed" >&2
    return 1
  fi
}
