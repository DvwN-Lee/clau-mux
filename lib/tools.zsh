# ── clmux-pipeline ────────────────────────────────────────────────────────────
# Thin wrapper that forwards to scripts/clmux_pipeline.sh with CLMUX_DIR root
# discovered at first call. See docs/pipeline.md.
clmux-pipeline() {
  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/scripts/clmux_pipeline.sh" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/scripts/clmux_pipeline.sh" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/scripts/clmux_pipeline.sh" ]] || {
    echo "error: cannot find clau-mux directory" >&2; return 1;
  }
  bash "$CLMUX_DIR/scripts/clmux_pipeline.sh" "$@"
}

# ── clmux-teammates ───────────────────────────────────────────────────────────
# Lists all teammates in the current tmux session, grouped by team.
# Reads tmux pane options (@agent_name, @cli_type) for bridge teammates and
# parses ps output (--agent-name, --team-name, --model) for native subagents.
# Restored 2026-04-19 — was inadvertently dropped during the lib/ split (PR #28).
# Original: commit 4738205.
clmux-teammates() {
  # Lists all teammates in the current tmux session, grouped by team.
  # Usage: clmux-teammates
  [[ -z "$TMUX" ]] && { echo "error: not inside tmux" >&2; return 1; }

  # All locals declared upfront to avoid zsh re-declaration output
  local tab=$'\t' lead_pane="$TMUX_PANE"
  local -a pane_ids=() entries=() team_order=() team_lines=()
  local -A team_entries=()
  local pane_id agent pane_pid _bteam _cli_type _alive _pid_file _bpid _td
  local child info name team model model_short etype title
  local entry rest epane ename estatus branch total i

  pane_ids=($(tmux list-panes -F '#{pane_id}' | grep -v "^${lead_pane}$"))

  if (( ${#pane_ids} == 0 )); then
    echo "no teammates in this session."
    return
  fi

  for pane_id in "${pane_ids[@]}"; do
    agent=$(tmux display-message -t "$pane_id" -p '#{@agent_name}' 2>/dev/null)
    pane_pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)

    if [[ -n "$agent" ]]; then
      _bteam="" _alive="dead"
      _cli_type=$(tmux display-message -t "$pane_id" -p '#{@cli_type}' 2>/dev/null)
      for _td in "$HOME"/.claude/teams/*/; do
        [[ -f "$_td/.${agent}-pane" ]] && { _bteam="${_td##*/teams/}"; _bteam="${_bteam%/}"; break; }
      done
      if [[ -n "$_bteam" ]]; then
        _pid_file="$HOME/.claude/teams/${_bteam}/.${agent}-bridge.pid"
        if [[ -f "$_pid_file" ]]; then
          _bpid=$(< "$_pid_file")
          kill -0 "$_bpid" 2>/dev/null && _alive="alive"
        fi
      fi
      entries+=("${_bteam:-unknown}${tab}${pane_id}${tab}${agent}${tab}${_cli_type:-bridge}${tab}${_alive}")
    else
      child=$(pgrep -P "$pane_pid" 2>/dev/null | head -1)
      if [[ -n "$child" ]]; then
        info=$(ps -p "$child" -o command= 2>/dev/null)
        name=$(echo "$info" | sed -n 's/.*--agent-name \([^ ]*\).*/\1/p')
        team=$(echo "$info" | sed -n 's/.*--team-name \([^ ]*\).*/\1/p')
        model=$(echo "$info" | sed -n 's/.*--model \([^ ]*\).*/\1/p')
        if [[ -n "$name" ]]; then
          if [[ -n "$model" ]]; then
            model_short="${model#claude-}"
            model_short="${model_short%%-[0-9]*}"
            etype="claude/${model_short}"
          else
            etype="claude"
          fi
          entries+=("${team:-unknown}${tab}${pane_id}${tab}${name}${tab}${etype}${tab}alive")
        else
          title=$(tmux display-message -t "$pane_id" -p '#{pane_title}' 2>/dev/null)
          entries+=("unknown${tab}${pane_id}${tab}${title:0:40}${tab}unknown${tab}alive")
        fi
      else
        title=$(tmux display-message -t "$pane_id" -p '#{pane_title}' 2>/dev/null)
        entries+=("unknown${tab}${pane_id}${tab}${title:0:40}${tab}unknown${tab}dead")
      fi
    fi
  done

  if (( ${#entries} == 0 )); then
    echo "no teammates detected."
    return
  fi

  for entry in "${entries[@]}"; do
    team="${entry%%${tab}*}"
    if (( ! ${+team_entries[$team]} )); then
      team_order+=("$team")
      team_entries[$team]=""
    fi
    team_entries[$team]+="${entry}"$'\n'
  done

  for team in "${team_order[@]}"; do
    echo "$team"
    team_lines=("${(@f)${team_entries[$team]%$'\n'}}")
    total=${#team_lines[@]}
    i=1
    for entry in "${team_lines[@]}"; do
      rest="${entry#*${tab}}"
      epane="${rest%%${tab}*}"; rest="${rest#*${tab}}"
      ename="${rest%%${tab}*}"; rest="${rest#*${tab}}"
      etype="${rest%%${tab}*}"
      estatus="${rest#*${tab}}"
      (( i == total )) && branch="└" || branch="├"
      echo "  ${branch} ${epane}  ${ename} (${etype}) [${estatus}]"
      (( i++ ))
    done
  done
}

# ── clmux-pane-info ───────────────────────────────────────────────────────────
# Single-entry inspection of a tmux pane: process, agent registration, team
# membership status, and recent output capture. Replaces ad-hoc combinations of
# tmux display-message + capture-pane + ~/.claude/teams/*/config.json reads.
# Usage: clmux-pane-info [<pane_id>] [-n <lines>]
# Defaults: pane=$TMUX_PANE, lines=30. -n 0 skips capture.
clmux-pane-info() {
  # All locals declared upfront (zsh style)
  local pane_id="" capture_lines=30
  local arg
  local cmd pid addr sess win pane_idx
  local agent cli_type
  local team_name member_status
  local td marker_file team_cfg isactive_line

  # ── argument parsing ─────────────────────────────────────────────────────
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -n) shift; capture_lines="$1"; shift ;;
      -*) echo "error: unknown option $arg" >&2; return 1 ;;
      *)  pane_id="$arg"; shift ;;
    esac
  done

  # ── resolve default pane ─────────────────────────────────────────────────
  if [[ -z "$pane_id" ]]; then
    if [[ -z "$TMUX_PANE" ]]; then
      echo "error: not inside tmux, specify <pane_id>" >&2; return 1
    fi
    pane_id="$TMUX_PANE"
  fi

  # ── verify pane exists ───────────────────────────────────────────────────
  if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane_id"; then
    echo "error: pane $pane_id not found" >&2; return 1
  fi

  # ── collect tmux display-message fields ──────────────────────────────────
  cmd=$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null)
  pid=$(tmux display-message -t "$pane_id" -p '#{pane_pid}' 2>/dev/null)
  sess=$(tmux display-message -t "$pane_id" -p '#{session_name}' 2>/dev/null)
  win=$(tmux display-message -t "$pane_id" -p '#{window_index}' 2>/dev/null)
  pane_idx=$(tmux display-message -t "$pane_id" -p '#{pane_index}' 2>/dev/null)
  agent=$(tmux display-message -t "$pane_id" -p '#{@agent_name}' 2>/dev/null)
  cli_type=$(tmux display-message -t "$pane_id" -p '#{@cli_type}' 2>/dev/null)

  # ── team membership lookup (via .${agent}-pane marker + grep config.json) ─
  # Only attempted when agent name is set.
  team_name="" member_status=""
  if [[ -n "$agent" ]]; then
    for td in "$HOME"/.claude/teams/*/; do
      marker_file="$td.${agent}-pane"
      if [[ -f "$marker_file" ]]; then
        team_name="${td##*/teams/}"
        team_name="${team_name%/}"
        break
      fi
    done

    if [[ -n "$team_name" ]]; then
      team_cfg="$HOME/.claude/teams/${team_name}/config.json"
      if [[ -f "$team_cfg" ]]; then
        # Approximation: grep for the agent name block then extract isActive.
        # Works for well-formed config.json; may mis-fire if field is >5 lines away.
        isactive_line=$(grep -A 5 "\"name\": \"${agent}\"" "$team_cfg" 2>/dev/null \
          | grep -o '"isActive": [a-z]*' | head -1)
        if [[ "$isactive_line" == *"true"* ]]; then
          member_status="alive"
        elif [[ "$isactive_line" == *"false"* ]]; then
          member_status="inactive"
        else
          member_status="unknown"
        fi
      fi
    fi
  fi

  # ── output ───────────────────────────────────────────────────────────────
  printf "pane:        %s\n" "$pane_id"
  printf "session:     %s\n" "$sess"
  printf "window.pane: %s.%s\n" "$win" "$pane_idx"
  printf "process:     %s (pid %s)\n" "$cmd" "$pid"

  if [[ -n "$agent" ]]; then
    printf "agent:       %s (cli_type: %s)\n" "$agent" "${cli_type:-unknown}"
  fi

  if [[ -n "$team_name" ]]; then
    printf "team:        %s (member status: %s)\n" "$team_name" "${member_status:-unknown}"
  fi

  # ── recent output capture ────────────────────────────────────────────────
  if [[ "$capture_lines" -ne 0 ]]; then
    local neg_lines=$(( -capture_lines ))
    printf "last %s lines:\n" "$capture_lines"
    printf "  %s\n" "─────────────────────────────────"
    tmux capture-pane -t "$pane_id" -p -S "$neg_lines" 2>/dev/null \
      | sed 's/^/  /'
    printf "  %s\n" "─────────────────────────────────"
  fi
}
