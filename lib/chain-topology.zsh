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
clmux-chain-check() {
  local pane="${1:-$TMUX_PANE}"
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
    return 1
  fi
  echo "[chain] OK pane=$pane peer-up=${peer_up:-none} peer-down=${peer_down:-none}"
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
