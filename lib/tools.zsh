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
