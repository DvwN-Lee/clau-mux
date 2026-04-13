if [[ -n "$ZSH_VERSION" ]]; then
  CLMUX_DIR="${${(%):-%x}:A:h}"
else
  CLMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
export CLMUX_DIR

# ── _clmux_ensure_team ────────────────────────────────────────────────────────
# Ensures team directory and config.json exist. Idempotent.
_clmux_ensure_team() {
  local team_dir="$1" team_name="$2"
  mkdir -p "$team_dir/inboxes"
  if [[ ! -f "$team_dir/config.json" ]]; then
    printf '{\n  "name": "%s",\n  "members": []\n}\n' "$team_name" > "$team_dir/config.json"
  fi
}

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

  local -a opt_g=() opt_x=() opt_c=() opt_n=() opt_T=()
  zparseopts -D -E -- g=opt_g x=opt_x c=opt_c n:=opt_n T:=opt_T || {
    echo "error: invalid options" >&2; return 1
  }
  local gemini_flag=$(( ${#opt_g} > 0 ? 1 : 0 ))
  local codex_flag=$(( ${#opt_x} > 0 ? 1 : 0 ))
  local copilot_flag=$(( ${#opt_c} > 0 ? 1 : 0 ))
  local session_name="${opt_n[2]:-}"
  local spawn_team="${opt_T[2]:-}"
  local -a clmux_args=("$@")

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

    # Ensure team once before batch spawn
    if { [[ $gemini_flag -eq 1 ]] && _clmux_agent_enabled gemini; } || \
       { [[ $codex_flag  -eq 1 ]] && _clmux_agent_enabled codex; }  || \
       { [[ $copilot_flag -eq 1 ]] && _clmux_agent_enabled copilot; }; then
      _clmux_ensure_team "$_team_dir" "$_team"
    fi

    if [[ "$gemini_flag" -eq 1 ]] && _clmux_agent_enabled gemini; then
      _clmux_spawn_agent gemini gemini-worker "Type your message" paste 0 colour33 1 -t "$_team"
    fi
    if [[ "$codex_flag" -eq 1 ]] && _clmux_agent_enabled codex; then
      python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" \
        --outbox "$_team_dir/inboxes/team-lead.json" --agent codex-worker &>/dev/null
      _clmux_spawn_agent "codex --full-auto" codex-worker "›" paste 1 colour36 0 -t "$_team"
    fi
    if [[ "$copilot_flag" -eq 1 ]] && _clmux_agent_enabled copilot; then
      local _cp_outbox="$_team_dir/inboxes/team-lead.json"
      [[ ! -f "$_cp_outbox" ]] && echo '[]' > "$_cp_outbox"
      local _cp_port
      _cp_port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")
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
      _clmux_spawn_agent "copilot --yolo" copilot-worker "Enter @ to mention" paste 1 colour98 0 -t "$_team"
    fi
    _clmux_layout_commit "$TMUX_PANE"
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

  # Ensure team once before batch spawn
  if { [[ $gemini_flag -eq 1 ]] && _clmux_agent_enabled gemini; } || \
     { [[ $codex_flag  -eq 1 ]] && _clmux_agent_enabled codex; }  || \
     { [[ $copilot_flag -eq 1 ]] && _clmux_agent_enabled copilot; }; then
    _clmux_ensure_team "$_st_dir" "$_st_team"
  fi

  local _lead_pane
  _lead_pane=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' 2>/dev/null | head -1)

  if [[ "$gemini_flag" -eq 1 ]] && _clmux_agent_enabled gemini; then
    _clmux_spawn_agent gemini gemini-worker "Type your message" paste 0 colour33 1 -S "$session_name" -t "$_st_team"
  fi

  if [[ "$codex_flag" -eq 1 ]] && _clmux_agent_enabled codex; then
    python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" \
      --outbox "$_st_inbox_dir/team-lead.json" --agent codex-worker &>/dev/null
    _clmux_spawn_agent "codex --full-auto" codex-worker "›" paste 1 colour36 0 -S "$session_name" -t "$_st_team"
  fi

  if [[ "$copilot_flag" -eq 1 ]] && _clmux_agent_enabled copilot; then
    local _cp2_outbox="$_st_inbox_dir/team-lead.json"
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
    _clmux_spawn_agent "copilot --yolo" copilot-worker "Enter @ to mention" paste 1 colour98 0 -S "$session_name" -t "$_st_team"
  fi

  _clmux_layout_commit "$_lead_pane" "=$session_name"

  tmux attach-session -t "=$session_name"
}

# ── _clmux_make_pane ──────────────────────────────────────────────────────────
# Creates a new agent pane and sets display options. No resize.
# Usage: _clmux_make_pane <lead_pane> <outbox> <agent_name> <cli_cmd> \
#                          <border_color> [<sess_spec>]
# Outputs pane_id to stdout, or empty string on failure.
_clmux_make_pane() {
  local lead_pane="$1" outbox="$2" agent_name="$3" cli_cmd="$4" \
        border_color="$5" sess_spec="${6:-}"

  local -a _t=()
  [[ -n "$sess_spec" ]] && _t=(-t "$sess_spec")

  local pane_count
  pane_count=$(tmux list-panes "${_t[@]}" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')

  local agent_pane
  if (( pane_count <= 1 )); then
    agent_pane=$(tmux split-window -t "$lead_pane" -h -P -F '#{pane_id}' \
      "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd" 2>/dev/null)
  else
    local last_pane
    last_pane=$(tmux list-panes "${_t[@]}" -F '#{pane_id}' | grep -v "^${lead_pane}$" | tail -1)
    agent_pane=$(tmux split-window -t "$last_pane" -v -P -F '#{pane_id}' \
      "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd" 2>/dev/null)
  fi

  if [[ -z "$agent_pane" ]]; then
    echo ""
    return 1
  fi

  tmux set-option -p -t "$agent_pane" allow-rename off
  tmux select-pane -t "$agent_pane" -T "$agent_name"
  tmux set-option -p -t "$agent_pane" @agent_name "$agent_name"
  tmux set-option -p -t "$agent_pane" pane-border-format "#[fg=${border_color},bold] #{@agent_name} #[default]"
  tmux select-pane -t "$lead_pane"

  echo "$agent_pane"
}

# ── _clmux_layout_commit ─────────────────────────────────────────────────────
# Rebalances pane layout after batch spawn. Call once after all panes created.
# Usage: _clmux_layout_commit <lead_pane> [<sess_spec>]
_clmux_layout_commit() {
  local lead_pane="$1" sess_spec="${2:-}"

  local -a _t=()
  [[ -n "$sess_spec" ]] && _t=(-t "$sess_spec")

  local -a teammate_panes
  teammate_panes=($(tmux list-panes "${_t[@]}" -F '#{pane_id}' | grep -v "^${lead_pane}$"))
  local count=${#teammate_panes[@]}
  (( count == 0 )) && return 0

  # Set right-column width
  tmux resize-pane -t "${teammate_panes[1]}" -x 70%
  (( count <= 1 )) && return 0

  # Distribute vertical space equally
  local win_height
  if [[ -n "$sess_spec" ]]; then
    win_height=$(tmux display-message -t "$sess_spec" -p '#{window_height}')
  else
    win_height=$(tmux display-message -p '#{window_height}')
  fi
  local each=$(( win_height / count ))
  local p
  for p in "${teammate_panes[@]}"; do
    tmux resize-pane -t "$p" -y "$each"
  done
}

# ── _clmux_spawn_agent ────────────────────────────────────────────────────────
# Shared spawn logic. Works both inside tmux and outside (with -S <session>).
# Usage: _clmux_spawn_agent <cli_cmd> <default_agent_name> <idle_pattern> \
#                           <input_method> <needs_env_file> <border_color> \
#                           <task_capable> \
#                           [-S <session>] [-t <team>] [-n <agent_name>] [-x <timeout>]
_clmux_spawn_agent() {
  local cli_cmd="$1"
  local default_agent_name="$2"
  local idle_pattern="$3"
  local input_method="$4"
  local needs_env_file="$5"
  local border_color="$6"
  local task_capable="${7:-0}"
  shift 7

  local team_name="" agent_name="$default_agent_name" timeout=30 session_name=""
  local OPTIND=1
  while getopts "S:t:n:x:" opt; do
    case $opt in
      S) session_name="$OPTARG" ;;
      t) team_name="$OPTARG" ;;
      n) agent_name="$OPTARG" ;;
      x) timeout="$OPTARG" ;;
      *) echo "Usage: _clmux_spawn_agent ... [-S <session>] -t <team_name> [-n <name>] [-x <timeout>]" >&2; return 1 ;;
    esac
  done

  [[ -z "$team_name" ]] && { echo "error: -t <team_name> required" >&2; return 1; }

  # Determine mode: out-of-tmux (-S session) vs in-tmux
  local lead_pane sess_spec=""
  if [[ -n "$session_name" ]]; then
    lead_pane=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' 2>/dev/null | head -1)
    [[ -z "$lead_pane" ]] && { echo "error: session '$session_name' not found" >&2; return 1; }
    sess_spec="=$session_name"
  else
    [[ -z "$TMUX" ]] && { echo "error: _clmux_spawn_agent must be run inside a tmux session" >&2; return 1; }
    command -v "${cli_cmd%% *}" &>/dev/null || { echo "error: ${cli_cmd%% *} CLI not found in PATH" >&2; return 1; }
    lead_pane="${TMUX_PANE}"
  fi

  local team_dir="$HOME/.claude/teams/$team_name"
  [[ ! -d "$team_dir" ]] && { echo "error: team '$team_name' not found at $team_dir" >&2; return 1; }

  local inbox_dir="$team_dir/inboxes"
  local inbox="$inbox_dir/$agent_name.json"
  local outbox="$inbox_dir/team-lead.json"
  local pid_file="$team_dir/.${agent_name}-bridge.pid"
  local pane_file="$team_dir/.${agent_name}-pane"

  mkdir -p "$inbox_dir"
  [[ -f "$inbox" ]]  || echo '[]' > "$inbox"
  [[ -f "$outbox" ]] || echo '[]' > "$outbox"

  # Codex: update config.toml BEFORE pane spawn (env_clear() strips PATH/HOME)
  if [[ "${cli_cmd%% *}" == "codex" ]]; then
    python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" --outbox "$outbox" --agent "$agent_name" &>/dev/null
  fi

  local agent_pane
  agent_pane=$(_clmux_make_pane "$lead_pane" "$outbox" "$agent_name" "$cli_cmd" "$border_color" "$sess_spec")
  [[ -z "$agent_pane" ]] && { echo "error: failed to create pane for $agent_name" >&2; return 1; }

  echo "$agent_pane" > "$pane_file"

  python3 "$CLMUX_DIR/scripts/update_pane.py" "$team_dir" "$agent_name" "$agent_pane" "${cli_cmd%% *}" "$task_capable"

  if [[ "$needs_env_file" -eq 1 ]]; then
    local team_name_val="${team_dir##*/}"
    printf 'CLMUX_OUTBOX=%s\nCLMUX_AGENT=%s\nCLMUX_TEAM=%s\n' "$outbox" "$agent_name" "$team_name_val" > "$team_dir/.bridge-${agent_name}.env"
  fi

  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/clmux-bridge.zsh" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/clmux-bridge.zsh" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/clmux-bridge.zsh" ]] || { echo "error: cannot find clau-mux directory" >&2; return 1; }
  local team_name_val="${team_dir##*/}"
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$agent_pane" -i "$inbox" -t "$timeout" -w "$idle_pattern" \
    >> "/tmp/clmux-bridge-${team_name_val}-${agent_name}.log" 2>&1 &
  echo $! > "$pid_file"
  disown

  echo "[clmux] $agent_name attached — pane:$agent_pane  bridge PID:$(< "$pid_file")"
}

# ── _clmux_stop_agent ─────────────────────────────────────────────────────────
# Shared stop logic for clmux-gemini-stop and clmux-codex-stop.
# Usage: _clmux_stop_agent <prefix> <default_agent_name> [-t <team>] [-n <agent_name>]
_clmux_stop_agent() {
  local prefix="$1"
  local default_agent_name="$2"
  shift 2

  local team_name="" agent_name="$default_agent_name"
  local OPTIND=1
  while getopts "t:n:" opt; do
    case $opt in
      t) team_name="$OPTARG" ;;
      n) agent_name="$OPTARG" ;;
      *) echo "Usage: ${prefix}-stop -t <team_name> [-n <name>]" >&2; return 1 ;;
    esac
  done

  [[ -z "$team_name" ]] && { echo "error: -t <team_name> required" >&2; return 1; }

  local team_dir="$HOME/.claude/teams/$team_name"
  local pid_file="$team_dir/.${agent_name}-bridge.pid"
  local pane_file="$team_dir/.${agent_name}-pane"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(< "$pid_file")
    kill "$pid" 2>/dev/null && echo "[${prefix}-stop] bridge PID $pid stopped"
    rm -f "$pid_file"
  else
    echo "[${prefix}-stop] no bridge PID found for $agent_name"
  fi

  # Kill HTTP MCP server if present (Copilot)
  local http_pid_file="$team_dir/.${agent_name}-mcp-http.pid"
  if [[ -f "$http_pid_file" ]]; then
    local http_pid
    http_pid=$(< "$http_pid_file")
    kill "$http_pid" 2>/dev/null && echo "[${prefix}-stop] HTTP MCP server PID $http_pid stopped"
    rm -f "$http_pid_file"
  fi

  if [[ -f "$pane_file" ]]; then
    local pane_id
    pane_id=$(< "$pane_file")
    tmux kill-pane -t "$pane_id" 2>/dev/null && echo "[${prefix}-stop] pane $pane_id closed"
    rm -f "$pane_file"
  else
    echo "[${prefix}-stop] no pane ID found for $agent_name"
  fi

  # Clean up env file if present
  rm -f "$team_dir/.bridge-${agent_name}.env"

  # Mark agent as inactive in config.json
  if [[ -f "$team_dir/config.json" ]]; then
    python3 "$CLMUX_DIR/scripts/deactivate_pane.py" "$team_dir" "$agent_name"
  fi
}

# ── _clmux_agent_enabled ──────────────────────────────────────────────────────
_clmux_agent_enabled() {
  local agent="$1"
  local config="$CLMUX_DIR/.agents-enabled"
  [[ ! -f "$config" ]] && return 0
  local key="${agent:u}_ENABLED"
  local val=$(grep "^${key}=" "$config" 2>/dev/null | cut -d= -f2)
  [[ "$val" != "0" ]]
}

# ── Public wrappers ───────────────────────────────────────────────────────────

if _clmux_agent_enabled gemini; then
  clmux-gemini() {
    # Spawns a Gemini CLI tmux pane as a Claude Code teammate.
    # Usage: clmux-gemini -t <team_name> [-n <agent_name>] [-x <timeout_sec>]
    _clmux_spawn_agent gemini gemini-worker "Type your message" paste 0 colour33 1 "$@" || return
    _clmux_layout_commit "$TMUX_PANE"
  }

  clmux-gemini-stop() {
    # Stops the Gemini bridge and closes the Gemini pane.
    # Usage: clmux-gemini-stop -t <team_name> [-n <agent_name>]
    _clmux_stop_agent clmux-gemini gemini-worker "$@"
  }
fi

if _clmux_agent_enabled codex; then
  clmux-codex() {
    # Spawns a Codex CLI tmux pane as a Claude Code teammate.
    # Usage: clmux-codex -t <team_name> [-n <agent_name>] [-x <timeout_sec>]
    _clmux_spawn_agent "codex --full-auto" codex-worker "›" paste 1 colour36 0 "$@" || return
    _clmux_layout_commit "$TMUX_PANE"
  }

  clmux-codex-stop() {
    # Stops the Codex bridge and closes the Codex pane.
    # Usage: clmux-codex-stop -t <team_name> [-n <agent_name>]
    _clmux_stop_agent clmux-codex codex-worker "$@"
  }
fi

if _clmux_agent_enabled copilot; then
  clmux-copilot() {
    # Spawns a Copilot CLI tmux pane as a Claude Code teammate.
    # Usage: clmux-copilot -t <team_name> [-n <agent_name>] [-x <timeout_sec>]
    #
    # Copilot CLI only supports HTTP/SSE MCP servers (requires url field).
    # We start bridge-mcp-server.js in HTTP mode on a free port, write the URL
    # to ~/.copilot/mcp-config.json, then spawn the Copilot pane.

    # Pre-parse -t/-n without consuming "$@" for _clmux_spawn_agent.
    local team_name="" agent_name="copilot-worker"
    local _arg _next_t=0 _next_n=0
    for _arg in "$@"; do
      if   (( _next_t )); then team_name="$_arg";   _next_t=0
      elif (( _next_n )); then agent_name="$_arg";  _next_n=0
      elif [[ "$_arg" == "-t" ]]; then _next_t=1
      elif [[ "$_arg" == "-n" ]]; then _next_n=1
      fi
    done

    [[ -z "$team_name" ]] && { echo "error: -t <team_name> required" >&2; return 1; }

    local team_dir="$HOME/.claude/teams/$team_name"
    local outbox="$team_dir/inboxes/team-lead.json"
    local http_pid_file="$team_dir/.${agent_name}-mcp-http.pid"

    mkdir -p "$team_dir/inboxes"
    [[ -f "$outbox" ]] || echo '[]' > "$outbox"

    # Find a free port
    local port
    port=$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()")

    # Start HTTP MCP server in background
    CLMUX_OUTBOX="$outbox" CLMUX_AGENT="$agent_name" \
      node "$CLMUX_DIR/bridge-mcp-server.js" --http "$port" \
      >> "/tmp/clmux-mcp-http-${team_name}-${agent_name}.log" 2>&1 &
    echo $! > "$http_pid_file"
    disown

    # Wait up to 2s for server to be ready
    local tries=0
    until curl -sf "http://127.0.0.1:${port}/sse" -o /dev/null --max-time 0.2 2>/dev/null \
        || (( tries++ >= 10 )); do
      sleep 0.2
    done

    # Register URL in Copilot mcp-config.json
    python3 "$CLMUX_DIR/scripts/setup_copilot_mcp.py" "http://127.0.0.1:${port}/sse"

    _clmux_spawn_agent "copilot --allow-all-tools" copilot-worker "Enter @ to mention" paste 1 colour98 0 "$@" || return
    _clmux_layout_commit "$TMUX_PANE"
  }

  clmux-copilot-stop() {
    # Stops the Copilot bridge and closes the Copilot pane.
    # Usage: clmux-copilot-stop -t <team_name> [-n <agent_name>]
    _clmux_stop_agent clmux-copilot copilot-worker "$@"
  }
fi

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

# update tmux window name to current git branch after each command
_clmux_precmd() {
  [[ -n "$TMUX" ]] || return
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  tmux rename-window "$branch"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _clmux_precmd
