clmux-ls() {
  local sessions
  sessions=$(tmux ls 2>/dev/null) || { echo "no active sessions"; return; }
  echo "$sessions"
  # Warn about orphaned sessions (sessions with no attached clients)
  local orphaned=0
  local sess_name
  while IFS= read -r sess_name; do
    local client_count
    client_count=$(tmux list-clients -t "=$sess_name" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$client_count" -eq 0 ]]; then
      (( orphaned += 1 ))
    fi
  done < <(tmux ls -F '#{session_name}' 2>/dev/null)
  if [[ "$orphaned" -gt 0 ]]; then
    echo ""
    echo "warning: $orphaned orphaned session(s) detected. run clmux-cleanup to remove."
  fi
}

clmux-cleanup() {
  local count=0
  local sess_name
  while IFS= read -r sess_name; do
    local client_count
    client_count=$(tmux list-clients -t "=$sess_name" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$client_count" -eq 0 ]]; then
      if tmux kill-session -t "=$sess_name" 2>/dev/null; then
        (( count += 1 ))
      fi
    fi
  done < <(tmux ls -F '#{session_name}' 2>/dev/null)
  if [[ "$count" -eq 0 ]]; then
    echo "no orphaned sessions."
  else
    echo "removed $count orphaned session(s)."
  fi
}

# _clmux_send_resolve_target — resolve a target string to a tmux pane id (%X).
# Tries 4 stages in order. Prints resolved pane id to stdout on success.
# Returns 0 on success, 1 on not-found, 2 on ambiguous.
_clmux_send_resolve_target() {
  local target="$1"
  local resolved=""

  # Stage 1: %X exact pane id
  if [[ "$target" =~ ^%[0-9]+$ ]]; then
    if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$target"; then
      echo "$target"
      return 0
    fi
  fi

  # Stage 2: session_name (tmux has-session + get active pane)
  if tmux has-session -t "$target" 2>/dev/null; then
    resolved=$(tmux list-panes -t "$target:" -F '#{?pane_active,#{pane_id},}' 2>/dev/null | grep -v '^$' | head -1)
    if [[ -n "$resolved" ]]; then
      echo "$resolved"
      return 0
    fi
  fi

  # Stage 3: team:agent (contains colon)
  if [[ "$target" == *:* ]]; then
    local team="${target%%:*}" agent="${target#*:}"
    local cfg="$HOME/.claude/teams/$team/config.json"
    if [[ -f "$cfg" ]]; then
      resolved=$(grep -A 5 "\"name\": \"$agent\"" "$cfg" 2>/dev/null | grep '"tmuxPaneId":' | head -1 | sed -E 's/.*"tmuxPaneId": "([^"]+)".*/\1/')
      if [[ -n "$resolved" ]]; then
        echo "$resolved"
        return 0
      fi
    fi
  fi

  # Stage 4: bare agent_name (scan all teams, no colon, no %prefix)
  if [[ "$target" != *:* && "$target" != %* ]]; then
    local matches=()
    local cfg team_name pane_id
    for cfg in "$HOME"/.claude/teams/*/config.json; do
      [[ -f "$cfg" ]] || continue
      team_name="${cfg:h:t}"
      if grep -q "\"name\": \"$target\"" "$cfg" 2>/dev/null; then
        pane_id=$(grep -A 5 "\"name\": \"$target\"" "$cfg" 2>/dev/null | grep '"tmuxPaneId":' | head -1 | sed -E 's/.*"tmuxPaneId": "([^"]+)".*/\1/')
        if [[ -n "$pane_id" ]]; then
          matches+=("$team_name:$target=$pane_id")
        fi
      fi
    done
    if (( ${#matches} == 1 )); then
      echo "${matches[1]##*=}"
      return 0
    elif (( ${#matches} > 1 )); then
      local m cand_team cand_pane
      echo "error: target '$target' matches ${#matches} candidates:" >&2
      for m in "${matches[@]}"; do
        cand_team="${m%%:*}"
        cand_pane="${m##*=}"
        echo "  - $cand_team:$target (pane $cand_pane)" >&2
      done
      echo "use exact form: clmux-send team:agent \"...\"" >&2
      return 2
    fi
  fi

  # No match — emit error with tried stages and suggestions
  echo "error: target '$target' not found" >&2
  echo "  tried: pane-id (%X), session, team:agent, agent" >&2
  local sugg=() s n cfg
  while IFS= read -r s; do
    [[ -n "$s" ]] && sugg+=("$s")
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null | head -3)
  for cfg in "$HOME"/.claude/teams/*/config.json; do
    [[ -f "$cfg" ]] || continue
    while IFS= read -r n; do
      [[ -n "$n" ]] && sugg+=("$n")
    done < <(grep '"name":' "$cfg" 2>/dev/null | sed -E 's/.*"name": "([^"]+)".*/\1/' | head -3)
  done
  if (( ${#sugg} > 0 )); then
    echo "  suggestions: ${sugg[*]:0:5}" >&2
  fi
  return 1
}

# clmux-send — send a prompt to a tmux pane via paste-buffer + Enter.
#
# Usage:
#   clmux-send <target> "<text>"                       # positional shortcut
#   clmux-send --to <pane_id> --prompt "<text>"        # send literal text
#   clmux-send --to <pane_id> --file <path>            # send file contents
#   clmux-send --to <pane_id> --prompt "..." --clear   # Ctrl-U first to clear stale input
#   clmux-send --to <pane_id> --prompt "..." --no-enter  # paste without pressing Enter
#   clmux-send --to <pane_id> --prompt "..." --wait-idle [--timeout 30]
#                                                      # block until Claude pane shows idle prompt "❯"
#
# Target resolution order (positional <target> or --to <target>):
#   1. %X          — exact pane id
#   2. session_name — tmux session's active pane
#   3. team:agent  — lookup ~/.claude/teams/<team>/config.json
#   4. agent_name  — scan all teams, exact 1 match required
#
# Flags:
#   --to <target>     target (pane id, session, team:agent, or bare agent). required.
#   --prompt <text>   literal text to send. mutually exclusive with --file.
#   --file <path>     path to file whose contents are sent. alternative to --prompt.
#   --clear           send Ctrl-U to target before pasting (clears partial input).
#   --no-enter        skip the trailing Enter keypress.
#   --wait-idle       poll until Claude idle prompt "❯" appears as last non-empty line.
#   --timeout <sec>   timeout for --wait-idle. default 30. ignored without --wait-idle.
#   --force           bypass slash-command pre-check.
clmux-send() {
  local pane="" prompt="" file="" clear=0 no_enter=0 wait_idle=0 timeout=30 force=0
  local positional_count=0

  # Positional shortcut: consume up to 2 leading non-flag args as <target> <text>.
  while [[ $# -gt 0 && "$1" != --* ]]; do
    (( positional_count += 1 ))
    if (( positional_count == 1 )); then
      pane="$1"; shift
    elif (( positional_count == 2 )); then
      prompt="$1"; shift
    else
      break
    fi
  done
  # If extra positional args remain after consuming 2, user forgot to quote text.
  if (( positional_count >= 2 )) && [[ $# -gt 0 && "$1" != --* ]]; then
    local extra_count=$(( positional_count + $# ))
    echo "error: text must be quoted (got $extra_count args, expected 2)" >&2
    echo "  usage: clmux-send <target> \"<text>\"" >&2
    return 1
  fi

  while [[ $# -gt 0 ]]; do
    case $1 in
      --to)        pane="$2"; shift 2 ;;
      --prompt)    prompt="$2"; shift 2 ;;
      --file)      file="$2"; shift 2 ;;
      --clear)     clear=1; shift ;;
      --no-enter)  no_enter=1; shift ;;
      --wait-idle) wait_idle=1; shift ;;
      --timeout)   timeout="$2"; shift 2 ;;
      --force)     force=1; shift ;;
      *) echo "error: unknown arg $1" >&2; return 1 ;;
    esac
  done

  # Pre-check 1: target is required.
  [[ -z "$pane" ]] && { echo "error: target is required (use --to <target> or positional: clmux-send <target> \"<text>\")" >&2; return 1; }

  # Pre-check 2: exactly one of --prompt or --file.
  if [[ -n "$prompt" && -n "$file" ]]; then
    echo "error: --prompt and --file are mutually exclusive" >&2; return 1
  fi
  if [[ -z "$prompt" && -z "$file" ]]; then
    echo "error: one of --prompt or --file is required" >&2; return 1
  fi

  # Pre-check 3: --file path exists and is readable.
  if [[ -n "$file" ]]; then
    [[ -f "$file" && -r "$file" ]] || { echo "error: file not found or not readable: $file" >&2; return 1; }
  fi

  # Pre-check 4: resolve target to pane id via 4-stage resolver.
  local resolved_pane
  resolved_pane=$(_clmux_send_resolve_target "$pane") || return $?
  pane="$resolved_pane"

  # Pre-check 5: slash-command guard (only for --prompt; --file is user's responsibility).
  if [[ -n "$prompt" && "$force" -eq 0 ]]; then
    local first_char
    first_char=$(printf '%s' "$prompt" | sed 's/^[[:space:]]*//' | cut -c1)
    if [[ "$first_char" == "/" ]]; then
      echo "warning: prompt starts with '/' — may be interpreted as a slash command; use --force to suppress" >&2
      return 1
    fi
  fi

  # Resolve content to a temp file.
  local tmpfile
  local tmpfile_owned=0
  if [[ -n "$file" ]]; then
    tmpfile="$file"
  else
    tmpfile=$(mktemp -t clmux-send.XXXXXX)
    tmpfile_owned=1
    printf '%s' "$prompt" > "$tmpfile"
  fi

  local buf_name="clmux-send-$$"

  # Load content into a named tmux buffer.
  tmux load-buffer -b "$buf_name" "$tmpfile"

  # Optionally clear stale input.
  if [[ "$clear" -eq 1 ]]; then
    tmux send-keys -t "$pane" C-u
    sleep 0.1
  fi

  # Paste buffer into target pane.
  tmux paste-buffer -b "$buf_name" -t "$pane"

  # Delete named buffer.
  tmux delete-buffer -b "$buf_name" 2>/dev/null

  # Send Enter unless --no-enter.
  if [[ "$no_enter" -eq 0 ]]; then
    sleep 0.2
    tmux send-keys -t "$pane" Enter
  fi

  # Wait for Claude idle prompt if requested.
  if [[ "$wait_idle" -eq 1 ]]; then
    local elapsed=0
    local found=0
    local last_line=""
    while [[ "$elapsed" -lt "$timeout" ]]; do
      last_line=$(tmux capture-pane -p -t "$pane" -S -3 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*[mKHJABCDGsu]//g' \
        | awk 'NF { last=$0 } END { print last }')
      if printf '%s' "$last_line" | grep -qE '^[[:space:]]*❯([[:space:]]|$)'; then
        found=1
        break
      fi
      sleep 0.5
      (( elapsed += 1 ))
    done
    if [[ "$found" -eq 0 ]]; then
      echo "[clmux-send] warning: timed out after ${timeout}s waiting for idle prompt on pane $pane" >&2
      [[ "$tmpfile_owned" -eq 1 ]] && rm -f "$tmpfile"
      return 1
    fi
  fi

  # Clean up temp file if we created it.
  [[ "$tmpfile_owned" -eq 1 ]] && rm -f "$tmpfile"

  # Compute char count.
  local char_count
  if [[ -n "$prompt" ]]; then
    char_count=${#prompt}
  else
    char_count=$(wc -c < "$file" | tr -d ' ')
  fi

  # Build flags summary.
  local flags_summary=""
  [[ "$clear"     -eq 1 ]] && flags_summary+="clear "
  [[ "$no_enter"  -eq 1 ]] && flags_summary+="no-enter "
  [[ "$wait_idle" -eq 1 ]] && flags_summary+="wait-idle(${timeout}s) "
  [[ "$force"     -eq 1 ]] && flags_summary+="force "
  flags_summary="${flags_summary%% }"
  [[ -z "$flags_summary" ]] && flags_summary="none"

  echo "[clmux-send] pane=$pane (chars=$char_count, flags=$flags_summary)"
}

# clmux-teammate-check — pre-flight check before SendMessage tool call.
# Validates that the named teammate's pane is alive AND its bridge process is
# running. Exits 0 if all checks pass; 1 otherwise. Runs all checks even on
# failure so the user gets a complete diagnostic.
#
# Usage:
#   clmux-teammate-check --team <team_name> --to <agent_name>
#
# Required:
#   --team <team>   team directory name (under ~/.claude/teams/)
#   --to <agent>    teammate agent name (e.g. gemini-worker, codex-worker)
clmux-teammate-check() {
  local team="" agent=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --team) team="$2"; shift 2 ;;
      --to)   agent="$2"; shift 2 ;;
      -*) echo "error: unknown arg $1" >&2; return 1 ;;
      *) echo "error: unexpected $1" >&2; return 1 ;;
    esac
  done
  [[ -z "$team" ]]  && { echo "error: --team required" >&2; return 1; }
  [[ -z "$agent" ]] && { echo "error: --to required" >&2; return 1; }

  local teams_root="${HOME}/.claude/teams"
  local team_dir="${teams_root}/${team}"
  local failed=0

  echo "[teammate-check] team=${team} agent=${agent}"

  # Check 1: team_dir exists
  if [[ -d "$team_dir" ]]; then
    echo "[teammate-check] team_dir: OK (${team_dir})"
  else
    echo "[teammate-check] team_dir: MISSING (${team_dir})"
    failed=1
  fi

  # Check 2: inbox file present
  local inbox_file="${team_dir}/inboxes/${agent}.json"
  if [[ -f "$inbox_file" ]]; then
    echo "[teammate-check] inbox:    OK (${inbox_file})"
  else
    echo "[teammate-check] inbox:    MISSING (${inbox_file})"
    failed=1
  fi

  # Check 3: pane_file present + references an alive pane
  local pane_file="${team_dir}/.${agent}-pane"
  if [[ ! -f "$pane_file" ]]; then
    echo "[teammate-check] pane:     MISSING (${pane_file})"
    failed=1
  else
    local pane_id
    pane_id=$(< "$pane_file")
    pane_id="${pane_id//[[:space:]]/}"
    if [[ -z "$pane_id" ]]; then
      echo "[teammate-check] pane:     MISSING (file empty)"
      failed=1
    elif tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$pane_id"; then
      echo "[teammate-check] pane:     OK (${pane_id})"
    else
      echo "[teammate-check] pane:     DEAD (${pane_id} not in tmux list-panes)"
      failed=1
    fi
  fi

  # Check 4: bridge pid alive
  local pid_file="${team_dir}/.${agent}-bridge.pid"
  if [[ ! -f "$pid_file" ]]; then
    echo "[teammate-check] bridge:   MISSING (${pid_file})"
    failed=1
  else
    local bridge_pid
    bridge_pid=$(< "$pid_file")
    bridge_pid="${bridge_pid//[[:space:]]/}"
    if [[ -z "$bridge_pid" ]]; then
      echo "[teammate-check] bridge:   MISSING (file empty)"
      failed=1
    elif kill -0 "$bridge_pid" 2>/dev/null; then
      echo "[teammate-check] bridge:   OK (pid=${bridge_pid})"
    else
      echo "[teammate-check] bridge:   DEAD (pid=${bridge_pid} not signalable)"
      failed=1
    fi
  fi

  # Check 5: pane has @clmux-agent option matching agent
  local pane_file2="${team_dir}/.${agent}-pane"
  if [[ -f "$pane_file2" ]]; then
    local pane_id2
    pane_id2=$(< "$pane_file2")
    pane_id2="${pane_id2//[[:space:]]/}"
    if [[ -n "$pane_id2" ]]; then
      local pane_tag
      pane_tag=$(tmux show-options -p -t "$pane_id2" -v @clmux-agent 2>/dev/null)
      if [[ "$pane_tag" == "$agent" ]]; then
        echo "[teammate-check] pane_tag: OK (@clmux-agent=${pane_tag})"
      elif [[ -n "$pane_tag" ]]; then
        echo "[teammate-check] pane_tag: MISMATCH (=${pane_tag})"
        failed=1
      else
        echo "[teammate-check] pane_tag: MISSING (@clmux-agent not set on ${pane_id2})"
        failed=1
      fi
    fi
  fi

  if (( failed )); then
    echo "[teammate-check] status:   DEAD"
    return 1
  else
    echo "[teammate-check] status:   ALIVE"
    return 0
  fi
}
