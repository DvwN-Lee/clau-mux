clmux() {
  # Validate prerequisites
  if ! command -v tmux &>/dev/null; then
    echo "error: tmux is not installed." >&2
    return 1
  fi
  if ! command -v claude &>/dev/null; then
    echo "error: claude is not installed." >&2
    return 1
  fi

  local session_name=""
  local -a clmux_args=()
  local gemini_flag=0
  local codex_flag=0
  local copilot_flag=0
  local spawn_team=""

  # Parse args: -n <name> sets session name, -g/-x/-c spawn AI agents, -T <team> sets team name, rest passed to Claude Code
  local args=("$@")
  local i=1
  while [[ $i -le ${#args[@]} ]]; do
    if [[ "${args[$i]}" == "-n" ]]; then
      if [[ $((i+1)) -gt ${#args[@]} ]] || [[ "${args[$((i+1))]}" == -* ]]; then
        echo "error: -n requires a session name." >&2
        return 1
      fi
      session_name="${args[$((i+1))]}"
      ((i+=2))
    elif [[ "${args[$i]}" == "-g" ]]; then
      gemini_flag=1
      ((i++))
    elif [[ "${args[$i]}" == "-x" ]]; then
      codex_flag=1
      ((i++))
    elif [[ "${args[$i]}" == "-c" ]]; then
      copilot_flag=1
      ((i++))
    elif [[ "${args[$i]}" == "-T" ]]; then
      if [[ $((i+1)) -gt ${#args[@]} ]] || [[ "${args[$((i+1))]}" == -* ]]; then
        echo "error: -T requires a team name." >&2
        return 1
      fi
      spawn_team="${args[$((i+1))]}"
      ((i+=2))
    else
      clmux_args+=("${args[$i]}")
      ((i++))
    fi
  done

  # Inject all valid plugins under CLMUX_PLUGIN_DIR (those with .claude-plugin/) as --plugin-dir args
  if [[ -n "$CLMUX_PLUGIN_DIR" ]]; then
    local _plugin_args=()
    for _pd in "$CLMUX_PLUGIN_DIR"/*/; do
      [[ -d "$_pd/.claude-plugin" ]] && _plugin_args+=("--plugin-dir" "${_pd%/}")
    done
    clmux_args=("${_plugin_args[@]}" "${clmux_args[@]}")
  fi

  # Inside tmux: run directly without session management
  if [[ -n "$TMUX" ]]; then
    local _team="${spawn_team:-$(tmux display-message -p '#{session_name}')}"
    local _team_dir="$HOME/.claude/teams/$_team"

    if [[ "$gemini_flag" -eq 1 ]] && _clmux_agent_enabled gemini; then
      _clmux_ensure_team "$_team_dir" "$_team"
      _clmux_spawn_agent gemini gemini-worker "Type your message" paste 0 colour33 1 -t "$_team"
    fi
    if [[ "$codex_flag" -eq 1 ]] && _clmux_agent_enabled codex; then
      _clmux_ensure_team "$_team_dir" "$_team"
      # setup_codex_mcp.py is now called by _clmux_spawn_agent with the
      # required --home <team-dir>/.codex-home; calling it here without
      # --home would exit(2) under the new per-team isolation model.
      _clmux_spawn_agent "codex -a never" codex-worker "^[[:space:]]*›" paste 1 colour36 0 -t "$_team"
    fi
    if [[ "$copilot_flag" -eq 1 ]] && _clmux_agent_enabled copilot; then
      local _cp_outbox="$_team_dir/inboxes/team-lead.json"
      _clmux_ensure_team "$_team_dir" "$_team"
      [[ ! -f "$_cp_outbox" ]] && echo '[]' > "$_cp_outbox"
      local _cp_port
      _cp_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
      CLMUX_OUTBOX="$_cp_outbox" CLMUX_AGENT="copilot-worker" \
        node "$CLMUX_DIR/bridge-mcp-server.js" --http "$_cp_port" \
        >> "/tmp/clmux-mcp-http-${_team}-copilot-worker.log" 2>&1 &
      printf '%s\n' "$!" > "$_team_dir/.copilot-worker-mcp-http.pid"
      disown
      local _cp_tries=0
      until curl -sf "http://127.0.0.1:${_cp_port}/sse" -o /dev/null --max-time 0.2 2>/dev/null \
          || (( _cp_tries++ >= 10 )); do
        sleep 0.2
      done
      python3 "$CLMUX_DIR/scripts/setup_copilot_mcp.py" "http://127.0.0.1:${_cp_port}/sse"
      _clmux_spawn_agent "copilot --yolo" copilot-worker "/ commands" paste 1 colour98 0 -t "$_team"
    fi
    command claude "${clmux_args[@]}"
    return
  fi

  # Auto-determine session name: first 6 chars of PWD md5
  if [[ -z "$session_name" ]]; then
    local dir_hash
    if command -v md5sum &>/dev/null; then
      dir_hash=$(printf '%s' "$PWD" | md5sum | head -c 6)
    else
      dir_hash=$(printf '%s' "$PWD" | md5 | head -c 6)
    fi
    session_name="$dir_hash"
  else
    # Prepend dir basename to -n value to prevent name collisions
    local dir_basename="${PWD##*/}"
    session_name="${dir_basename}/${session_name}"
  fi

  # Serialize clmux_args to a shell command string (safe for spaces and special chars)
  local claude_cmd="command claude"
  local arg
  for arg in "${clmux_args[@]}"; do
    claude_cmd+=" $(printf '%q' "$arg")"
  done

  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || basename "$PWD")

  # Handle existing session
  if tmux has-session -t "=$session_name" 2>/dev/null; then
    local attached_clients
    attached_clients=$(tmux list-clients -t "=$session_name" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$attached_clients" -eq 0 ]]; then
      # No clients → orphaned session → clean up and recreate
      echo "[$session_name] restarting orphaned session."
      tmux kill-session -t "=$session_name" 2>/dev/null
    else
      # Active client exists → block new access (prevent multi-instance conflict)
      echo "error: [$session_name] session is already running." >&2
      echo "  kill with: tmux kill-session -t $session_name" >&2
      return 1
    fi
  fi

  # Create new session (command passed directly → session auto-destroys on exit)
  if ! tmux new-session -d -s "$session_name" -n "$branch" -c "$PWD" "$claude_cmd"; then
    echo "error: failed to create tmux session '$session_name'." >&2
    return 1
  fi

  # Status bar model monitor: extract model name from JSONL → store in tmux @clmux_model
  (
    projdir="$HOME/.claude/projects/-$(printf '%s' "$PWD" | sed 's|/|-|g')"
    while tmux has-session -t "=$session_name" 2>/dev/null; do
      f=$(ls -1t "$projdir"/*.jsonl 2>/dev/null | head -1)
      if [[ -n "$f" ]]; then
        m=$(tail -c 5000 "$f" 2>/dev/null | grep -oE '"model":"claude-[^"]*"' | tail -1 | sed 's/.*claude-//;s/"//;s/-[0-9].*//')
        [[ -n "$m" ]] && tmux set -t "$session_name" @clmux_model "$m" 2>/dev/null
      fi
      sleep 30
    done
  ) &>/dev/null &
  disown

  # Spawn teammates (-g/-x/-c flags)
  local _st_team="${spawn_team:-$session_name}"
  local _st_dir="$HOME/.claude/teams/$_st_team"
  local _st_inbox_dir="$_st_dir/inboxes"

  if [[ "$gemini_flag" -eq 1 ]] && _clmux_agent_enabled gemini; then
    _clmux_ensure_team "$_st_dir" "$_st_team"
    [[ ! -f "$_st_inbox_dir/gemini-worker.json" ]] && echo '[]' > "$_st_inbox_dir/gemini-worker.json"
    [[ ! -f "$_st_inbox_dir/team-lead.json" ]]    && echo '[]' > "$_st_inbox_dir/team-lead.json"
    _clmux_spawn_agent_in_session "$session_name" gemini gemini-worker "Type your message" paste 0 colour33 1 "$_st_team"
  fi

  if [[ "$codex_flag" -eq 1 ]] && _clmux_agent_enabled codex; then
    _clmux_ensure_team "$_st_dir" "$_st_team"
    [[ ! -f "$_st_inbox_dir/codex-worker.json" ]] && echo '[]' > "$_st_inbox_dir/codex-worker.json"
    [[ ! -f "$_st_inbox_dir/team-lead.json" ]]    && echo '[]' > "$_st_inbox_dir/team-lead.json"
    # setup_codex_mcp.py is now called by _clmux_spawn_agent_in_session with
    # the required --home <team-dir>/.codex-home; calling it here without
    # --home would exit(2) under the new per-team isolation model.
    _clmux_spawn_agent_in_session "$session_name" "codex -a never" codex-worker "^[[:space:]]*›" paste 1 colour36 0 "$_st_team"
  fi

  if [[ "$copilot_flag" -eq 1 ]] && _clmux_agent_enabled copilot; then
    local _cp2_outbox="$_st_inbox_dir/team-lead.json"
    _clmux_ensure_team "$_st_dir" "$_st_team"
    [[ ! -f "$_st_inbox_dir/copilot-worker.json" ]] && echo '[]' > "$_st_inbox_dir/copilot-worker.json"
    [[ ! -f "$_cp2_outbox" ]] && echo '[]' > "$_cp2_outbox"
    local _cp2_port
    _cp2_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
    CLMUX_OUTBOX="$_cp2_outbox" CLMUX_AGENT="copilot-worker" \
      node "$CLMUX_DIR/bridge-mcp-server.js" --http "$_cp2_port" \
      >> "/tmp/clmux-mcp-http-${_st_team}-copilot-worker.log" 2>&1 &
    printf '%s\n' "$!" > "$_st_dir/.copilot-worker-mcp-http.pid"
    disown
    local _cp2_tries=0
    until curl -sf "http://127.0.0.1:${_cp2_port}/sse" -o /dev/null --max-time 0.2 2>/dev/null \
        || (( _cp2_tries++ >= 10 )); do
      sleep 0.2
    done
    python3 "$CLMUX_DIR/scripts/setup_copilot_mcp.py" "http://127.0.0.1:${_cp2_port}/sse"
    _clmux_spawn_agent_in_session "$session_name" "copilot --yolo" copilot-worker "/ commands" paste 1 colour98 0 "$_st_team"
  fi

  tmux attach-session -t "=$session_name"
}
