# ── _clmux_current_session_id ─────────────────────────────────────────────────
# Extracts current Claude Code session ID by finding the most recently modified
# JSONL in the project session dir. Heuristic — Bash tool env does not expose
# CLAUDE_SESSION_ID. Uses CLAUDE_PROJECT_DIR if set, falls back to PWD.
# Prints session id on stdout, empty string if not found.
_clmux_current_session_id() {
  local base_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
  local proj_key="${base_dir//\//-}"
  local proj_dir="$HOME/.claude/projects/${proj_key}"
  [[ -d "$proj_dir" ]] || return 0
  local latest
  latest=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1)
  [[ -n "$latest" ]] && basename "$latest" .jsonl
}

# ── _clmux_team_session_id ────────────────────────────────────────────────────
# Extracts leadSessionId from a team's config.json.
# Prints value on stdout; empty string if config missing or field absent.
_clmux_team_session_id() {
  local cfg="$1/config.json"
  [[ -f "$cfg" ]] || return 0
  python3 -c "
import json, sys
try: print(json.load(open('$cfg')).get('leadSessionId',''))
except Exception: pass" 2>/dev/null
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

  # Codex: per-team CODEX_HOME + whitelisted auth symlinks. Mirrors
  # _clmux_spawn_agent exactly, including trust-before-setup ordering
  # (see that function for the detailed rationale).
  local extra_env=""
  if [[ "${cli_cmd%% *}" == "codex" ]]; then
    local _lead_cwd
    _lead_cwd=$(tmux display-message -t "$lead_pane" -p '#{pane_current_path}' 2>/dev/null)
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_codex_project.py" "$_lead_cwd" 2>/dev/null
    local codex_home="$team_dir/.codex-home"
    mkdir -p "$codex_home"
    if [[ -d "$HOME/.codex" ]]; then
      local _auth_items=(auth.json credentials.json installation_id .personality_migration models_cache.json instructions.md rules memories)
      for _name in $_auth_items; do
        local _src="$HOME/.codex/$_name"
        [[ -e "$_src" ]] || continue
        [[ -e "$codex_home/$_name" || -L "$codex_home/$_name" ]] && continue
        ln -s "$_src" "$codex_home/$_name"
      done
    fi
    python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" \
      --home "$codex_home" --outbox "$outbox" --agent "$agent_name" &>/dev/null
    extra_env="CODEX_HOME=$codex_home "
  fi

  local pane_count
  pane_count=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' | wc -l | tr -d ' ')

  local agent_pane
  if (( pane_count <= 1 )); then
    agent_pane=$(tmux split-window -t "$lead_pane" -h -P -F '#{pane_id}' "exec env ${extra_env}CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")
    tmux resize-pane -t "$agent_pane" -x 70%
  else
    local last_pane
    last_pane=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' | grep -v "^${lead_pane}$" | tail -1)
    agent_pane=$(tmux split-window -t "$last_pane" -v -P -F '#{pane_id}' "exec env ${extra_env}CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")

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

  # Guard: team must be TeamCreate-registered for Claude Code orchestrator
  # to push write_to_lead responses as <teammate-message> conversation turns.
  # Without leadSessionId, bridge spawns successfully but messages are orphaned.
  local _team_sid _cur_sid
  _team_sid=$(_clmux_team_session_id "$team_dir")
  if [[ -z "$_team_sid" ]]; then
    cat >&2 <<ERREOF
error: team '$team_name' has no leadSessionId in $team_dir/config.json.
       Bridge spawn aborted — responses would not reach the Lead session.
       Run TeamCreate(team_name: "$team_name") in the current Claude Code
       Lead session, then retry this spawn.
ERREOF
    return 1
  fi

  _cur_sid=$(_clmux_current_session_id)
  if [[ -n "$_cur_sid" && "$_cur_sid" != "$_team_sid" ]]; then
    cat >&2 <<WARNEOF
warning: team '$team_name' leadSessionId ($_team_sid) does not match
         current session ($_cur_sid). Responses may not reach this Lead.
         Re-run TeamCreate(team_name: "$team_name") if you want this session
         to own the team.
WARNEOF
    # proceed — user may intentionally reuse across sessions
  fi

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

  # Codex: per-team isolation via CODEX_HOME. config.toml is written fresh
  # for this team; only auth-related state from ~/.codex is symlinked so the
  # worker inherits OAuth/API-key login. History, sessions, logs, sqlite,
  # skills, cache are NOT shared — each team gets its own to avoid cross-
  # team bleed and sqlite WAL contention under parallel workers.
  #
  # Ordering matters: trust_codex_project.py MUST run before setup_codex_mcp.py
  # because setup seeds the per-team config.toml from the user's global
  # ~/.codex/config.toml, and the trust entry for $_lead_cwd is written INTO
  # that global config. If seeding runs first, the per-team config would lack
  # the trust entry and codex would hang on the "trust this directory?" prompt.
  local extra_env=""
  if [[ "${cli_cmd%% *}" == "codex" ]]; then
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_codex_project.py" "$_lead_cwd" 2>/dev/null
    local codex_home="$team_dir/.codex-home"
    mkdir -p "$codex_home"
    if [[ -d "$HOME/.codex" ]]; then
      local _auth_items=(auth.json credentials.json installation_id .personality_migration models_cache.json instructions.md rules memories)
      for _name in $_auth_items; do
        local _src="$HOME/.codex/$_name"
        [[ -e "$_src" ]] || continue
        [[ -e "$codex_home/$_name" || -L "$codex_home/$_name" ]] && continue
        ln -s "$_src" "$codex_home/$_name"
      done
    fi
    python3 "$CLMUX_DIR/scripts/setup_codex_mcp.py" \
      --home "$codex_home" --outbox "$outbox" --agent "$agent_name" &>/dev/null
    extra_env="CODEX_HOME=$codex_home "
  elif [[ "${cli_cmd%% *}" == "gemini" ]]; then
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_gemini_project.py" "$_lead_cwd" 2>/dev/null
  elif [[ "${cli_cmd%% *}" == "copilot" ]]; then
    [[ -n "$_lead_cwd" ]] && python3 "$CLMUX_DIR/scripts/trust_copilot_project.py" "$_lead_cwd" 2>/dev/null
  fi

  local pane_count
  pane_count=$(tmux list-panes -F '#{pane_id}' | wc -l | tr -d ' ')

  local agent_pane
  if (( pane_count <= 1 )); then
    agent_pane=$(tmux split-window -t "$lead_pane" -h -P -F '#{pane_id}' "exec env ${extra_env}CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")
    tmux resize-pane -t "$agent_pane" -x 70%
  else
    local last_teammate
    last_teammate=$(tmux list-panes -F '#{pane_id}' | grep -v "^${lead_pane}$" | tail -1)
    agent_pane=$(tmux split-window -t "$last_teammate" -v -P -F '#{pane_id}' "exec env ${extra_env}CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")

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

# ── _clmux_gemini_latest ──────────────────────────────────────────────────────
# Resolves the highest-versioned Gemini model name for a given tier by parsing
# the installed Gemini CLI bundle. Results are cached in ~/.cache/clmux/ keyed
# by CLI version, so re-parsing only happens after a CLI update.
#
# Usage: _clmux_gemini_latest <tier>
#   tier: "pro"   → highest gemini-X.Y-pro-preview
#         "flash" → highest gemini-X.Y-flash-preview (excludes -lite- variants)
#         <regex> → raw ERE passed directly for extensibility
# Returns: model name on stdout; exits 1 if gemini not found or no match.
_clmux_gemini_latest() {
  local tier="${1:?_clmux_gemini_latest: tier required (pro|flash|<regex>)}"

  local gemini_bin
  gemini_bin="$(command -v gemini 2>/dev/null)" || return 1
  local pkg_dir="${gemini_bin:h:h}/lib/node_modules/@google/gemini-cli"
  [[ -d "$pkg_dir" ]] || return 1

  local version
  version="$(grep -m1 '"version"' "$pkg_dir/package.json" 2>/dev/null | grep -o '[0-9][0-9.]*')"
  [[ -n "$version" ]] || version="unknown"

  local cache_dir="$HOME/.cache/clmux"
  local cache_file="$cache_dir/gemini-models-${version}.txt"

  if [[ ! -f "$cache_file" ]]; then
    mkdir -p "$cache_dir"
    # Extract quoted model-name strings from all bundle JS files, deduplicate.
    grep -oh '"gemini-[0-9][^"]*"' "$pkg_dir/bundle/"*.js 2>/dev/null \
      | tr -d '"' \
      | grep -E '^gemini-[0-9]' \
      | sort -Vu > "$cache_file"
    # Remove stale caches from older CLI versions.
    find "$cache_dir" -name "gemini-models-*.txt" \
      ! -name "gemini-models-${version}.txt" -delete 2>/dev/null
  fi

  local pattern
  case "$tier" in
    pro)   pattern='^gemini-[0-9][0-9.]*-pro-preview$' ;;
    flash) pattern='^gemini-[0-9][0-9.]*-flash-preview$' ;;
    *)     pattern="$tier" ;;
  esac

  local result
  result="$(sort -Vr "$cache_file" 2>/dev/null | grep -Em1 "$pattern")"
  [[ -n "$result" ]] && echo "$result" || return 1
}
