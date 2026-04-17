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
      python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" \
        --outbox "$_team_dir/inboxes/team-lead.json" --agent codex-worker &>/dev/null
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
      _clmux_spawn_agent "copilot --yolo" copilot-worker "Enter @ to mention" paste 1 colour98 0 -t "$_team"
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
    python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" \
      --outbox "$_st_inbox_dir/team-lead.json" --agent codex-worker &>/dev/null
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
    _clmux_spawn_agent_in_session "$session_name" "copilot --yolo" copilot-worker "Enter @ to mention" paste 1 colour98 0 "$_st_team"
  fi

  tmux attach-session -t "=$session_name"
}

# ── _clmux_spawn_agent_in_session ─────────────────────────────────────────────
# Used by clmux() to spawn a Gemini agent inside an already-created session
# (outside tmux context — uses tmux send-keys trick is not needed, we just
# call _clmux_spawn_agent directly after attach would be too late, so we
# replicate the pane-split logic here directly via tmux commands).
# Usage: _clmux_spawn_agent_in_session <session> <cli_cmd> <agent_name> \
#                                       <idle_pattern> <input_method> \
#                                       <needs_env_file> <border_color> \
#                                       <task_capable> <team_name> [timeout_sec]
_clmux_spawn_agent_in_session() {
  local session_name="$1"
  local cli_cmd="$2"
  local default_agent_name="$3"
  local idle_pattern="$4"
  local input_method="$5"
  local needs_env_file="$6"
  local border_color="$7"
  local task_capable="${8:-0}"
  local team_name="$9"
  local timeout="${10:-30}"

  local agent_name="$default_agent_name"
  local team_dir="$HOME/.claude/teams/$team_name"
  local inbox_dir="$team_dir/inboxes"
  local inbox="$inbox_dir/$agent_name.json"
  local outbox="$inbox_dir/team-lead.json"
  local pid_file="$team_dir/.${agent_name}-bridge.pid"
  local pane_file="$team_dir/.${agent_name}-pane"

  _clmux_ensure_team "$team_dir" "$team_name"
  [[ ! -f "$inbox" ]]  && echo '[]' > "$inbox"
  [[ ! -f "$outbox" ]] && echo '[]' > "$outbox"

  local lead_pane
  lead_pane=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' | head -1)

  local pane_count
  pane_count=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' | wc -l | tr -d ' ')

  local agent_pane
  if (( pane_count <= 1 )); then
    agent_pane=$(tmux split-window -t "$lead_pane" -h -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")
    tmux resize-pane -t "$agent_pane" -x 70%
  else
    local last_pane
    last_pane=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' | grep -v "^${lead_pane}$" | tail -1)
    agent_pane=$(tmux split-window -t "$last_pane" -v -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")

    local teammate_panes
    teammate_panes=($(tmux list-panes -t "=$session_name" -F '#{pane_id}' | grep -v "^${lead_pane}$"))
    local count=${#teammate_panes[@]}
    if (( count > 1 )); then
      local win_height
      win_height=$(tmux display-message -t "=$session_name" -p '#{window_height}')
      local each=$(( win_height / count ))
      for p in "${teammate_panes[@]}"; do
        tmux resize-pane -t "$p" -y "$each"
      done
    fi
  fi

  tmux set-option -p -t "$agent_pane" allow-rename off
  tmux select-pane -t "$agent_pane" -T "$agent_name"
  tmux set-option -p -t "$agent_pane" @agent_name "$agent_name"
  tmux set-option -p -t "$agent_pane" pane-border-format "#[fg=${border_color},bold] #{@agent_name} #[default]"
  # Tmux-Native State: bridge identity stored on the pane itself.
  # When the pane dies, these options vanish — making "agent alive" =
  # "pane alive" structurally true (no separate config field can drift).
  tmux set-option -p -t "$agent_pane" @clmux-agent "$agent_name"
  tmux set-option -p -t "$agent_pane" @clmux-team "${team_dir##*/}"
  tmux set-option -p -t "$agent_pane" @clmux-bridge "1"
  tmux select-pane -t "$lead_pane"

  echo "$agent_pane" > "$pane_file"

  python3 "$CLMUX_DIR/scripts/update_pane.py" "$team_dir" "$agent_name" "$agent_pane" "${cli_cmd%% *}" "$task_capable"

  if [[ "$needs_env_file" -eq 1 ]]; then
    local team_name_val="${team_dir##*/}"
    printf 'CLMUX_OUTBOX=%s\nCLMUX_AGENT=%s\nCLMUX_TEAM=%s\n' "$outbox" "$agent_name" "$team_name_val" > "$team_dir/.bridge-${agent_name}.env"
  fi

  [[ -f "$CLMUX_DIR/clmux-bridge.zsh" ]] || { echo "error: cannot find clau-mux directory" >&2; return 1; }
  local team_name_val="${team_dir##*/}"
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$agent_pane" -i "$inbox" -t "$timeout" -w "$idle_pattern" \
    >> "/tmp/clmux-bridge-${team_name_val}-${agent_name}.log" 2>&1 &
  echo $! > "$pid_file"
  disown

  echo "[clmux] $agent_name attached — pane:$agent_pane  team:$team_name"
}

# ── _clmux_spawn_agent ────────────────────────────────────────────────────────
# Shared spawn logic for clmux-gemini and clmux-codex.
# Usage: _clmux_spawn_agent <cli_cmd> <default_agent_name> <idle_pattern> \
#                           <input_method> <needs_env_file> <border_color> \
#                           <task_capable> \
#                           [-t <team>] [-n <agent_name>] [-x <timeout>]
_clmux_spawn_agent() {
  local cli_cmd="$1"
  local default_agent_name="$2"
  local idle_pattern="$3"
  local input_method="$4"
  local needs_env_file="$5"
  local border_color="$6"
  local task_capable="${7:-0}"
  shift 7

  [[ -z "$TMUX" ]] && { echo "error: _clmux_spawn_agent must be run inside a tmux session" >&2; return 1; }
  command -v "${cli_cmd%% *}" &>/dev/null || { echo "error: ${cli_cmd%% *} CLI not found in PATH" >&2; return 1; }

  local team_name="" agent_name="$default_agent_name" timeout=30 model=""
  local OPTIND=1
  while getopts "t:n:x:m:" opt; do
    case $opt in
      t) team_name="$OPTARG" ;;
      n) agent_name="$OPTARG" ;;
      x) timeout="$OPTARG" ;;
      m) model="$OPTARG" ;;
      *) echo "Usage: _clmux_spawn_agent ... -t <team_name> [-n <name>] [-x <timeout>] [-m <model>]" >&2; return 1 ;;
    esac
  done

  [[ -z "$team_name" ]] && { echo "error: -t <team_name> required" >&2; return 1; }

  # Inject --model after the CLI binary name if -m was supplied.
  # All three bridge CLIs (codex, gemini, copilot 0.0.365) expose
  # --model <val>; syntax is consistent across them. Earlier wrappers
  # only supported model via the CLI's own config file, which is
  # inconvenient for per-team overrides. This injection lets callers
  # pin a model per spawn without touching global config.
  if [[ -n "$model" ]]; then
    local cli_bin="${cli_cmd%% *}"
    local cli_rest=""
    [[ "$cli_bin" != "$cli_cmd" ]] && cli_rest="${cli_cmd#* }"
    cli_cmd="$cli_bin --model $model${cli_rest:+ $cli_rest}"
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

  local lead_pane="${TMUX_PANE}"

  # Pre-trust the lead pane's cwd (= cwd the new pane will inherit via
  # tmux split-window) in the CLI's trust store. All three CLIs show an
  # interactive "Do you trust this folder?" prompt on first launch in an
  # unknown directory; that prompt blocks idle detection and, for codex,
  # its `› 1. Yes, continue` option line also falsely matches the bridge
  # idle pattern and crashes the pane on first paste.
  local _lead_cwd
  _lead_cwd=$(tmux display-message -t "$lead_pane" -p '#{pane_current_path}' 2>/dev/null)

  # Codex: update config.toml BEFORE pane spawn (env_clear() strips PATH/HOME)
  if [[ "${cli_cmd%% *}" == "codex" ]]; then
    python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" --outbox "$outbox" --agent "$agent_name" &>/dev/null
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_codex_project.py" "$_lead_cwd" 2>/dev/null
  elif [[ "${cli_cmd%% *}" == "gemini" ]]; then
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_gemini_project.py" "$_lead_cwd" 2>/dev/null
  elif [[ "${cli_cmd%% *}" == "copilot" ]]; then
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_copilot_project.py" "$_lead_cwd" 2>/dev/null
  fi

  local pane_count
  pane_count=$(tmux list-panes -F '#{pane_id}' | wc -l | tr -d ' ')

  local agent_pane
  if (( pane_count <= 1 )); then
    agent_pane=$(tmux split-window -t "$lead_pane" -h -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")
    tmux resize-pane -t "$agent_pane" -x 70%
  else
    local last_teammate
    last_teammate=$(tmux list-panes -F '#{pane_id}' | grep -v "^${lead_pane}$" | tail -1)
    agent_pane=$(tmux split-window -t "$last_teammate" -v -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")

    local teammate_panes
    teammate_panes=($(tmux list-panes -F '#{pane_id}' | grep -v "^${lead_pane}$"))
    local count=${#teammate_panes[@]}
    if (( count > 1 )); then
      local win_height
      win_height=$(tmux display-message -p '#{window_height}')
      local each_height=$(( win_height / count ))
      for p in "${teammate_panes[@]}"; do
        tmux resize-pane -t "$p" -y "$each_height"
      done
    fi
  fi

  tmux set-option -p -t "$agent_pane" allow-rename off
  tmux select-pane -t "$agent_pane" -T "$agent_name"
  tmux set-option -p -t "$agent_pane" @agent_name "$agent_name"
  tmux set-option -p -t "$agent_pane" pane-border-format "#[fg=${border_color},bold] #{@agent_name} #[default]"
  # Tmux-Native State: bridge identity stored on the pane itself.
  # When the pane dies, these options vanish — making "agent alive" =
  # "pane alive" structurally true (no separate config field can drift).
  tmux set-option -p -t "$agent_pane" @clmux-agent "$agent_name"
  tmux set-option -p -t "$agent_pane" @clmux-team "${team_dir##*/}"
  tmux set-option -p -t "$agent_pane" @clmux-bridge "1"
  tmux select-pane -t "$lead_pane"

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

  echo "[clmux-${cli_cmd}] $agent_name attached — pane:$agent_pane  bridge PID:$(< "$pid_file")"
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
    # Usage: clmux-gemini -t <team_name> [-n <agent_name>] [-x <timeout_sec>] [-m <model>]
    _clmux_spawn_agent gemini gemini-worker "Type your message" paste 0 colour33 1 "$@"
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
    # Usage: clmux-codex -t <team_name> [-n <agent_name>] [-x <timeout_sec>] [-m <model>]
    _clmux_spawn_agent "codex -a never" codex-worker "^[[:space:]]*›" paste 1 colour36 0 "$@"
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
    # Usage: clmux-copilot -t <team_name> [-n <agent_name>] [-x <timeout_sec>] [-m <model>]
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

    _clmux_spawn_agent "copilot --allow-all-tools" copilot-worker "Enter @ to mention" paste 1 colour98 0 "$@"
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

# ── clmux-orchestrate ─────────────────────────────────────────────────────────
# Thin wrapper that forwards to scripts/clmux_orchestrate.py with the
# CLMUX_DIR root discovered at first call.
clmux-orchestrate() {
  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/scripts/clmux_orchestrate.py" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/scripts/clmux_orchestrate.py" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/scripts/clmux_orchestrate.py" ]] || {
    echo "error: cannot find clau-mux directory" >&2; return 1;
  }
  python3 "$CLMUX_DIR/scripts/clmux_orchestrate.py" "$@"
}

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

# ── Role one-shot helpers ─────────────────────────────────────────────────────
# clmux-master / clmux-mid / clmux-leaf — single-command role setup (+ optional
# child spawn). Replaces the 9-step tmux+chain-register+orchestrate boilerplate
# that skill bodies previously inlined. Self-init on bare call; spawn child
# with positional arg (Master → Mid, Mid → Leaf). Leaves do not fan out.

clmux-master() {
  local project="" force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=1; shift ;;
      --*) echo "error: unknown flag $1" >&2; return 1 ;;
      *) project="$1"; shift ;;
    esac
  done

  [[ -z "$TMUX" ]] && { echo "error: must be run inside a tmux session" >&2; return 1; }

  if [[ -z "$project" ]]; then
    # Bare form: self-init current pane as Master.
    if (( force == 0 )); then
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "error: cwd is inside a git repo; use --force to override" >&2
        return 1
      fi
      local existing_role
      existing_role=$(tmux show-options -p -v @clmux-chain-role 2>/dev/null)
      if [[ -n "$existing_role" ]]; then
        echo "error: @clmux-chain-role already set to '$existing_role'; use --force to override" >&2
        return 1
      fi
    fi
    clmux-chain-register --role master --pane "$TMUX_PANE"
    clmux-orchestrate set-master --pane "$TMUX_PANE" --label "master-$(basename "$PWD")" || true
    echo "[master] pane=$TMUX_PANE cwd=$PWD ready"
  else
    # With <project>: self-init + spawn Mid.
    local proj_path
    case $project in
      /*|~*) proj_path="${project/#\~/$HOME}" ;;
      *)     proj_path="$PWD/$project" ;;
    esac

    if ! git -C "$proj_path" rev-parse --show-toplevel >/dev/null 2>&1; then
      echo "error: $proj_path is not a git repo (hint: cd $proj_path && git init)" >&2
      return 1
    fi

    # Self-init current pane as Master (force to skip git-repo guard).
    clmux-master --force
    local master_pane="$TMUX_PANE"

    local proj_slug session
    proj_slug=$(basename "$proj_path")
    session="${proj_slug}-mid"

    tmux new-session -d -s "$session" -c "$proj_path" \
      "claude 'clmux-mid 역할로 ${proj_slug} 프로젝트 진행한다. 상위 Master pane=${master_pane}'"

    local mid_pane
    mid_pane=$(tmux display-message -p -t "$session" '#{pane_id}')
    if [[ -z "$mid_pane" ]]; then
      echo "error: failed to capture pane_id for session $session" >&2
      return 1
    fi

    clmux-chain-register --role master --pane "$master_pane" --add-peer-down "$mid_pane"
    tmux set-option -p -t "$mid_pane" @clmux-chain-role mid
    tmux set-option -p -t "$mid_pane" @clmux-chain-peer-up "$master_pane"
    clmux-orchestrate register-sub --pane "$mid_pane" --master "$master_pane" --label "mid-${proj_slug}"

    echo "[master] mid spawned: pane=$mid_pane session=$session project=$proj_path"
    echo "[master] attach: tmux attach -t $session"
  fi
}

clmux-mid() {
  local leaf_name="" scope="" criteria="" force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --scope)    scope="$2"; shift 2 ;;
      --criteria) criteria="$2"; shift 2 ;;
      --force)    force=1; shift ;;
      --*) echo "error: unknown flag $1" >&2; return 1 ;;
      *)  leaf_name="$1"; shift ;;
    esac
  done

  if [[ -n "$leaf_name" && -z "$scope" ]]; then
    echo "error: --scope required when spawning a leaf" >&2
    return 1
  fi

  [[ -z "$TMUX" ]] && { echo "error: must be run inside a tmux session" >&2; return 1; }

  # Bare self-init logic (also executed before spawn path).
  local _do_init=1
  if (( force == 0 )); then
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "error: cwd is not inside a git repo" >&2
      return 1
    fi
    case $PWD in
      *'/.worktrees/'*)
        echo "error: cwd is inside a worktree (.worktrees); Mid must run from the main tree" >&2
        return 1
        ;;
    esac
    local existing_role
    existing_role=$(tmux show-options -p -v @clmux-chain-role 2>/dev/null)
    if [[ -n "$existing_role" && -z "$leaf_name" ]]; then
      echo "error: @clmux-chain-role already set to '$existing_role'; use --force to override" >&2
      return 1
    fi
  fi

  local peer_up mode
  peer_up=$(tmux show-options -p -v @clmux-chain-peer-up 2>/dev/null)
  [[ -n "$peer_up" ]] && mode=A || mode=B

  clmux-chain-register --role mid --pane "$TMUX_PANE"
  clmux-orchestrate set-master --pane "$TMUX_PANE" --label "mid-$(basename "$(git rev-parse --show-toplevel)")" || true
  echo "[mid] pane=$TMUX_PANE mode=$mode project=$(git rev-parse --show-toplevel)"

  [[ -z "$leaf_name" ]] && return 0

  # Spawn Leaf with worktree.
  local proj_path wt_path proj_slug session
  proj_path=$(git rev-parse --show-toplevel)
  wt_path="$proj_path/.worktrees/$leaf_name"
  proj_slug=$(basename "$proj_path")
  session="${proj_slug}-leaf-${leaf_name}"

  if ! git -C "$proj_path" worktree add "$wt_path" -b "$leaf_name"; then
    echo "error: git worktree add failed for $wt_path" >&2
    return 1
  fi

  tmux new-session -d -s "$session" -c "$wt_path" \
    "claude 'clmux-leaf 역할로 \"${leaf_name}\" 작업. 상위 Mid pane=${TMUX_PANE}'"

  local leaf_pane
  leaf_pane=$(tmux display-message -p -t "$session" '#{pane_id}')
  if [[ -z "$leaf_pane" ]]; then
    echo "error: failed to capture pane_id for session $session" >&2
    return 1
  fi

  clmux-chain-register --role mid --pane "$TMUX_PANE" --add-peer-down "$leaf_pane"
  tmux set-option -p -t "$leaf_pane" @clmux-chain-role leaf
  tmux set-option -p -t "$leaf_pane" @clmux-chain-peer-up "$TMUX_PANE"
  clmux-orchestrate register-sub --pane "$leaf_pane" --master "$TMUX_PANE" --label "leaf-${leaf_name}"

  local delegate_args=(--from "$TMUX_PANE" --to "$leaf_pane" --scope "$scope")
  [[ -n "$criteria" ]] && delegate_args+=(--criteria "$criteria")
  clmux-orchestrate delegate "${delegate_args[@]}"

  echo "[mid] leaf spawned: pane=$leaf_pane session=$session branch=$leaf_name worktree=$wt_path"
  echo "[mid] attach: tmux attach -t $session"
}

clmux-leaf() {
  local force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=1; shift ;;
      *) echo "error: unknown arg $1" >&2; return 1 ;;
    esac
  done

  [[ -z "$TMUX" ]] && { echo "error: must be run inside a tmux session" >&2; return 1; }

  case $PWD in
    *'/.worktrees/'*) ;;
    *)
      echo "error: cwd is not inside a worktree (.worktrees); leaf must run from a worktree path" >&2
      return 1
      ;;
  esac

  local peer_up
  peer_up=$(tmux show-options -p -v @clmux-chain-peer-up 2>/dev/null)
  if [[ -z "$peer_up" ]]; then
    echo "error: leaf pane requires @clmux-chain-peer-up to be set (expected from parent Mid's spawn)" >&2
    return 1
  fi

  if (( force == 0 )); then
    local existing_role
    existing_role=$(tmux show-options -p -v @clmux-chain-role 2>/dev/null)
    if [[ -n "$existing_role" ]]; then
      echo "error: @clmux-chain-role already set to '$existing_role'; use --force to override" >&2
      return 1
    fi
  fi

  clmux-chain-register --role leaf --pane "$TMUX_PANE"
  echo "[leaf] pane=$TMUX_PANE peer-up=$peer_up worktree=$PWD branch=$(git rev-parse --abbrev-ref HEAD)"
}

# ── Role teardown helpers ─────────────────────────────────────────────────────
# Cleanup mirrors of clmux-master / clmux-mid / clmux-leaf. `clmux-leaf-stop`
# handles worktree + branch removal after a leaf's work is merged or discarded.
# `clmux-mid-stop` / `clmux-master-stop` handle tmux session + chain option
# cleanup without cascading (explicit opt-in via --cascade).

clmux-chain-unregister() {
  local pane="${TMUX_PANE}"
  local upstream=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      --pane)
        pane="$2"; shift 2 ;;
      --peer-of)
        upstream="$2"; shift 2 ;;
      *)
        echo "error: unknown argument: $1" >&2; return 1 ;;
    esac
  done

  # Unset chain options on pane if it is still alive
  if tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$pane"; then
    tmux set-option -pu -t "$pane" @clmux-chain-role 2>/dev/null
    tmux set-option -pu -t "$pane" @clmux-chain-peer-up 2>/dev/null
    tmux set-option -pu -t "$pane" @clmux-chain-peer-down 2>/dev/null
  fi

  # Remove pane from upstream's peer-down CSV if upstream is alive
  if [[ -n "$upstream" ]] && tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$upstream"; then
    local cur
    cur=$(tmux show-options -p -t "$upstream" -v @clmux-chain-peer-down 2>/dev/null)
    if [[ -n "$cur" ]]; then
      local arr filtered new
      arr=(${(s:,:)cur})
      filtered=(${arr:#$pane})
      new=${(j:,:)filtered}
      if [[ -z "$new" ]]; then
        tmux set-option -pu -t "$upstream" @clmux-chain-peer-down 2>/dev/null
      else
        tmux set-option -p -t "$upstream" @clmux-chain-peer-down "$new"
      fi
    fi
  fi

  echo "[chain-unregister] pane=$pane upstream=${upstream:-none}"
}

clmux-leaf-stop() {
  if [[ -z "$TMUX" ]]; then
    echo "error: not inside a tmux session" >&2; return 1
  fi

  local leaf_name=""
  local force=0
  local keep_branch=0
  local keep_worktree=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      --force)        force=1; shift ;;
      --keep-branch)  keep_branch=1; shift ;;
      --keep-worktree) keep_worktree=1; shift ;;
      -*)
        echo "error: unknown flag: $1" >&2; return 1 ;;
      *)
        if [[ -z "$leaf_name" ]]; then
          leaf_name="$1"; shift
        else
          echo "error: unexpected argument: $1" >&2; return 1
        fi ;;
    esac
  done

  if [[ -z "$leaf_name" ]]; then
    echo "error: usage: clmux-leaf-stop <leaf-name> [--force] [--keep-branch] [--keep-worktree]" >&2
    return 1
  fi

  local role
  role=$(tmux show-options -p -v @clmux-chain-role 2>/dev/null)
  if [[ "$role" != "mid" ]]; then
    echo "error: clmux-leaf-stop must be run from a Mid pane (current role=${role:-unset})" >&2
    return 1
  fi

  local proj_path
  proj_path=$(git rev-parse --show-toplevel 2>/dev/null)
  if [[ -z "$proj_path" ]]; then
    echo "error: could not determine git project root" >&2; return 1
  fi
  local proj_slug
  proj_slug=$(basename "$proj_path")
  local session="${proj_slug}-leaf-${leaf_name}"
  local wt_path="$proj_path/.worktrees/${leaf_name}"

  local leaf_pane
  leaf_pane=$(tmux display-message -p -t "$session" '#{pane_id}' 2>/dev/null)

  # Safety check: verify branch is merged (skip if --force or --keep-branch)
  if (( force == 0 && keep_branch == 0 )); then
    if ! git -C "$proj_path" merge-base --is-ancestor "$leaf_name" HEAD 2>/dev/null; then
      echo "error: branch $leaf_name has unmerged commits (use --force to discard, or --keep-branch to preserve)" >&2
      return 1
    fi
  fi

  # Step 1: chain-unregister
  if [[ -n "$leaf_pane" ]]; then
    clmux-chain-unregister --pane "$leaf_pane" --peer-of "$TMUX_PANE"
  else
    echo "warn: leaf session already gone; skipping chain-unregister" >&2
  fi

  # Step 2: kill leaf tmux session
  tmux kill-session -t "$session" 2>/dev/null || true

  # Step 3: remove worktree
  if (( keep_worktree == 0 )); then
    if [[ -d "$wt_path" ]]; then
      local rm_args=(-C "$proj_path" worktree remove "$wt_path")
      (( force == 1 )) && rm_args+=(--force)
      git "${rm_args[@]}" || { echo "warn: git worktree remove failed for $wt_path" >&2; }
    fi
  fi

  # Step 4: delete branch
  if (( keep_branch == 0 )); then
    if git -C "$proj_path" show-ref --verify --quiet "refs/heads/$leaf_name"; then
      local del_flag="-d"; (( force == 1 )) && del_flag="-D"
      git -C "$proj_path" branch "$del_flag" "$leaf_name" || { echo "warn: git branch $del_flag $leaf_name failed" >&2; }
    fi
  fi

  # Step 5: summary
  local kept=""
  (( keep_branch == 1 )) && kept+=" [branch kept]"
  (( keep_worktree == 1 )) && kept+=" [worktree kept]"
  echo "[leaf-stop] $leaf_name removed (session=$session wt=$wt_path branch=$leaf_name)${kept}"
}

clmux-mid-stop() {
  if [[ -z "$TMUX" ]]; then
    echo "error: not inside a tmux session" >&2; return 1
  fi

  local project=""
  local force=0
  local cascade=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      --force)   force=1; shift ;;
      --cascade) cascade=1; shift ;;
      -*)
        echo "error: unknown flag: $1" >&2; return 1 ;;
      *)
        if [[ -z "$project" ]]; then
          project="$1"; shift
        else
          echo "error: unexpected argument: $1" >&2; return 1
        fi ;;
    esac
  done

  local role
  role=$(tmux show-options -p -v @clmux-chain-role 2>/dev/null)

  if [[ -n "$project" ]]; then
    # Mode A: invoked from Master pane with a project name
    if [[ "$role" != "master" ]]; then
      echo "error: clmux-mid-stop <project> must be run from a Master pane (current role=${role:-unset})" >&2
      return 1
    fi

    local session="${project}-mid"
    local mid_pane
    mid_pane=$(tmux display-message -p -t "$session" '#{pane_id}' 2>/dev/null)
    if [[ -z "$mid_pane" ]]; then
      echo "error: no Mid session named $session" >&2; return 1
    fi

    local mid_peer_down
    mid_peer_down=$(tmux show-options -p -t "$mid_pane" -v @clmux-chain-peer-down 2>/dev/null)
    if [[ -n "$mid_peer_down" ]] && (( cascade == 0 && force == 0 )); then
      echo "error: Mid has active leaves ($mid_peer_down). Stop them first with clmux-leaf-stop, or pass --cascade to kill without cleanup (does not remove worktrees/branches), or --force for force kill." >&2
      return 1
    fi

    if (( cascade == 1 )); then
      echo "warn: --cascade kills leaf sessions but does not remove worktrees/branches; run clmux-leaf-stop per-leaf for full cleanup" >&2
      local leaf_id
      for leaf_id in ${(s:,:)mid_peer_down}; do
        local leaf_sess
        leaf_sess=$(tmux list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null | awk -v id="$leaf_id" '$1==id{print $2}')
        if [[ -n "$leaf_sess" ]]; then
          tmux kill-session -t "$leaf_sess" 2>/dev/null || true
        fi
      done
    fi

    clmux-chain-unregister --pane "$mid_pane" --peer-of "$TMUX_PANE"
    tmux kill-session -t "$session" 2>/dev/null || true
    echo "[mid-stop] $project mid killed (session=$session pane=$mid_pane)"

  else
    # Mode B: self-cleanup from Mid pane
    if [[ "$role" != "mid" ]]; then
      echo "error: clmux-mid-stop (no args) must be run from a Mid pane (current role=${role:-unset})" >&2
      return 1
    fi

    local own_peer_down
    own_peer_down=$(tmux show-options -p -v @clmux-chain-peer-down 2>/dev/null)
    if [[ -n "$own_peer_down" ]] && (( cascade == 0 && force == 0 )); then
      echo "error: this Mid has active leaves ($own_peer_down). Stop them first with clmux-leaf-stop, or pass --cascade to kill without cleanup (does not remove worktrees/branches), or --force for force kill." >&2
      return 1
    fi

    if (( cascade == 1 )); then
      echo "warn: --cascade kills leaf sessions but does not remove worktrees/branches; run clmux-leaf-stop per-leaf for full cleanup" >&2
      local leaf_id
      for leaf_id in ${(s:,:)own_peer_down}; do
        local leaf_sess
        leaf_sess=$(tmux list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null | awk -v id="$leaf_id" '$1==id{print $2}')
        if [[ -n "$leaf_sess" ]]; then
          tmux kill-session -t "$leaf_sess" 2>/dev/null || true
        fi
      done
    fi

    local peer_up
    peer_up=$(tmux show-options -p -v @clmux-chain-peer-up 2>/dev/null)
    if [[ -n "$peer_up" ]]; then
      clmux-chain-unregister --pane "$TMUX_PANE" --peer-of "$peer_up"
    else
      clmux-chain-unregister --pane "$TMUX_PANE"
    fi

    echo "[mid-stop] self-killing session..."
    tmux kill-session -t "$(tmux display-message -p '#S')"
  fi
}

clmux-master-stop() {
  if [[ -z "$TMUX" ]]; then
    echo "error: not inside a tmux session" >&2; return 1
  fi

  local force=0

  while [[ $# -gt 0 ]]; do
    case $1 in
      --force) force=1; shift ;;
      *)
        echo "error: unknown argument: $1" >&2; return 1 ;;
    esac
  done

  local role
  role=$(tmux show-options -p -v @clmux-chain-role 2>/dev/null)
  if [[ "$role" != "master" ]]; then
    echo "error: clmux-master-stop must be run from a Master pane (current role=${role:-unset})" >&2
    return 1
  fi

  local peer_down
  peer_down=$(tmux show-options -p -v @clmux-chain-peer-down 2>/dev/null)
  if [[ -n "$peer_down" ]] && (( force == 0 )); then
    local N=${#${(s:,:)peer_down}}
    echo "error: $N Mid panes still registered: $peer_down. Stop them first with clmux-mid-stop <project>, or use --force to unregister anyway." >&2
    return 1
  fi

  clmux-chain-unregister --pane "$TMUX_PANE"
  echo "[master-stop] pane=$TMUX_PANE unregistered (tmux session preserved)"
}
