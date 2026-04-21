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

    _clmux_spawn_agent "copilot --allow-all-tools" copilot-worker "/ commands" paste 1 colour98 0 "$@"
  }

  clmux-copilot-stop() {
    # Stops the Copilot bridge and closes the Copilot pane.
    # Usage: clmux-copilot-stop -t <team_name> [-n <agent_name>]
    _clmux_stop_agent clmux-copilot copilot-worker "$@"
  }
fi
