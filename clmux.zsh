if [[ -n "$ZSH_VERSION" ]]; then
  CLMUX_DIR="${${(%):-%x}:A:h}"
else
  CLMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
export CLMUX_DIR


clmux() {
  # 전제조건 검증
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
  local gemini_team=""

  # 인자 파싱: -n <name>은 세션 이름, -g는 Gemini 스폰, -T <team>은 팀 이름 지정, 나머지는 Claude Code에 전달
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
    elif [[ "${args[$i]}" == "-T" ]]; then
      if [[ $((i+1)) -gt ${#args[@]} ]] || [[ "${args[$((i+1))]}" == -* ]]; then
        echo "error: -T requires a team name." >&2
        return 1
      fi
      gemini_team="${args[$((i+1))]}"
      ((i+=2))
    else
      clmux_args+=("${args[$i]}")
      ((i++))
    fi
  done

  # tmux 내부: 세션 관리 없이 바로 실행
  if [[ -n "$TMUX" ]]; then
    if [[ "$gemini_flag" -eq 1 ]]; then
      local g_team="${gemini_team:-$(tmux display-message -p '#{session_name}')}"
      local g_team_dir="$HOME/.claude/teams/$g_team"
      if [[ ! -d "$g_team_dir" ]]; then
        mkdir -p "$g_team_dir/inboxes"
        printf '{\n  "name": "%s",\n  "members": []\n}\n' "$g_team" > "$g_team_dir/config.json"
      fi
      _clmux_spawn_agent gemini gemini-worker "Type your message" keys 0 colour33 -t "$g_team"
    fi
    command claude "${clmux_args[@]}"
    return
  fi

  # 세션 이름 자동 결정: PWD md5 앞 6자
  if [[ -z "$session_name" ]]; then
    local dir_hash
    if command -v md5sum &>/dev/null; then
      dir_hash=$(printf '%s' "$PWD" | md5sum | head -c 6)
    else
      dir_hash=$(printf '%s' "$PWD" | md5 | head -c 6)
    fi
    session_name="$dir_hash"
  fi

  # clmux_args를 shell 명령 문자열로 직렬화 (공백/특수문자 안전 처리)
  local claude_cmd="command claude"
  local arg
  for arg in "${clmux_args[@]}"; do
    claude_cmd+=" $(printf '%q' "$arg")"
  done

  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || basename "$PWD")

  # 기존 세션 처리
  if tmux has-session -t "=$session_name" 2>/dev/null; then
    local attached_clients
    attached_clients=$(tmux list-clients -t "=$session_name" 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$attached_clients" -eq 0 ]]; then
      # 클라이언트 없음 → orphaned 세션 → 정리 후 재생성
      echo "[$session_name] restarting orphaned session."
      tmux kill-session -t "=$session_name" 2>/dev/null
    else
      # 활성 클라이언트 존재 → 새 접근 차단 (멀티 인스턴스 충돌 방지)
      echo "error: [$session_name] session is already running." >&2
      echo "  kill with: tmux kill-session -t $session_name" >&2
      return 1
    fi
  fi

  # 새 세션 생성 (명령 직접 전달 → exit 시 세션 자동 소멸)
  if ! tmux new-session -d -s "$session_name" -n "$branch" -c "$PWD" "$claude_cmd"; then
    echo "error: failed to create tmux session '$session_name'." >&2
    return 1
  fi

  # status bar model monitor: JSONL에서 모델명 추출 → tmux @clmux_model에 저장
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

  # Gemini 스폰 (-g 플래그)
  if [[ "$gemini_flag" -eq 1 ]]; then
    local g_team="${gemini_team:-$session_name}"
    local g_team_dir="$HOME/.claude/teams/$g_team"
    local g_inbox_dir="$g_team_dir/inboxes"

    mkdir -p "$g_inbox_dir"
    [[ ! -f "$g_inbox_dir/gemini-worker.json" ]] && echo '[]' > "$g_inbox_dir/gemini-worker.json"
    [[ ! -f "$g_inbox_dir/team-lead.json" ]]    && echo '[]' > "$g_inbox_dir/team-lead.json"

    if [[ ! -f "$g_team_dir/config.json" ]]; then
      printf '{\n  "name": "%s",\n  "members": []\n}\n' "$g_team" > "$g_team_dir/config.json"
    fi

    # Wait until the session has at least one pane before spawning
    tmux has-session -t "=$session_name" 2>/dev/null
    _clmux_spawn_agent_in_session "$session_name" gemini gemini-worker "Type your message" keys 0 colour33 "$g_team"
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
#                                       <team_name> [timeout_sec]
_clmux_spawn_agent_in_session() {
  local session_name="$1"
  local cli_cmd="$2"
  local default_agent_name="$3"
  local idle_pattern="$4"
  local input_method="$5"
  local needs_env_file="$6"
  local border_color="$7"
  local team_name="$8"
  local timeout="${9:-30}"

  local agent_name="$default_agent_name"
  local team_dir="$HOME/.claude/teams/$team_name"
  local inbox_dir="$team_dir/inboxes"
  local inbox="$inbox_dir/$agent_name.json"
  local outbox="$inbox_dir/team-lead.json"
  local pid_file="$team_dir/.${agent_name}-bridge.pid"
  local pane_file="$team_dir/.${agent_name}-pane"

  mkdir -p "$inbox_dir"
  [[ ! -f "$inbox" ]]  && echo '[]' > "$inbox"
  [[ ! -f "$outbox" ]] && echo '[]' > "$outbox"

  if [[ ! -f "$team_dir/config.json" ]]; then
    printf '{\n  "name": "%s",\n  "members": []\n}\n' "$team_name" > "$team_dir/config.json"
  fi

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
  tmux set-option -p -t "$agent_pane" pane-border-format "#[fg=${border_color},bold] #{pane_title} #[default]"
  tmux select-pane -t "$lead_pane"

  echo "$agent_pane" > "$pane_file"

  python3 "$CLMUX_DIR/scripts/update_pane.py" "$team_dir" "$agent_name" "$agent_pane" "$cli_cmd"

  if [[ "$needs_env_file" -eq 1 ]]; then
    printf 'CLMUX_OUTBOX=%s\nCLMUX_AGENT=%s\n' "$outbox" "$agent_name" > "$team_dir/.bridge-${agent_name}.env"
  fi

  [[ -f "$CLMUX_DIR/clmux-bridge.zsh" ]] || { echo "error: cannot find clau-mux directory" >&2; return 1; }
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$agent_pane" -i "$inbox" -t "$timeout" -w "$idle_pattern" -m "$input_method" \
    >> "/tmp/clmux-bridge-${agent_name}.log" 2>&1 &
  echo $! > "$pid_file"
  disown

  echo "[clmux] $agent_name attached — pane:$agent_pane  team:$team_name"
}

# ── _clmux_spawn_agent ────────────────────────────────────────────────────────
# Shared spawn logic for clmux-gemini and clmux-codex.
# Usage: _clmux_spawn_agent <cli_cmd> <default_agent_name> <idle_pattern> \
#                           <input_method> <needs_env_file> <border_color> \
#                           [-t <team>] [-n <agent_name>] [-x <timeout>]
_clmux_spawn_agent() {
  local cli_cmd="$1"
  local default_agent_name="$2"
  local idle_pattern="$3"
  local input_method="$4"
  local needs_env_file="$5"
  local border_color="$6"
  shift 6

  [[ -z "$TMUX" ]] && { echo "error: _clmux_spawn_agent must be run inside a tmux session" >&2; return 1; }
  command -v "$cli_cmd" &>/dev/null || { echo "error: $cli_cmd CLI not found in PATH" >&2; return 1; }

  local team_name="" agent_name="$default_agent_name" timeout=30
  local OPTIND=1
  while getopts "t:n:x:" opt; do
    case $opt in
      t) team_name="$OPTARG" ;;
      n) agent_name="$OPTARG" ;;
      x) timeout="$OPTARG" ;;
      *) echo "Usage: _clmux_spawn_agent ... -t <team_name> [-n <name>] [-x <timeout>]" >&2; return 1 ;;
    esac
  done

  [[ -z "$team_name" ]] && { echo "error: -t <team_name> required" >&2; return 1; }

  local team_dir="$HOME/.claude/teams/$team_name"
  [[ ! -d "$team_dir" ]] && { echo "error: team '$team_name' not found at $team_dir" >&2; return 1; }

  local inbox_dir="$team_dir/inboxes"
  local inbox="$inbox_dir/$agent_name.json"
  local outbox="$inbox_dir/team-lead.json"
  local pid_file="$team_dir/.${agent_name}-bridge.pid"
  local pane_file="$team_dir/.${agent_name}-pane"

  mkdir -p "$inbox_dir"
  echo '[]' > "$inbox"
  echo '[]' > "$outbox"

  local lead_pane
  lead_pane=$(tmux display-message -p '#{pane_id}')

  local pane_count
  pane_count=$(tmux list-panes -F '#{pane_id}' | wc -l | tr -d ' ')

  local agent_pane
  if (( pane_count <= 1 )); then
    agent_pane=$(tmux split-window -h -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name $cli_cmd")
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
  tmux set-option -p -t "$agent_pane" pane-border-format "#[fg=${border_color},bold] #{pane_title} #[default]"
  tmux select-pane -t "$lead_pane"

  echo "$agent_pane" > "$pane_file"

  python3 "$CLMUX_DIR/scripts/update_pane.py" "$team_dir" "$agent_name" "$agent_pane" "$cli_cmd"

  if [[ "$needs_env_file" -eq 1 ]]; then
    printf 'CLMUX_OUTBOX=%s\nCLMUX_AGENT=%s\n' "$outbox" "$agent_name" > "$team_dir/.bridge-${agent_name}.env"
  fi

  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/clmux-bridge.zsh" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/clmux-bridge.zsh" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/clmux-bridge.zsh" ]] || { echo "error: cannot find clau-mux directory" >&2; return 1; }
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$agent_pane" -i "$inbox" -t "$timeout" -w "$idle_pattern" -m "$input_method" \
    >> "/tmp/clmux-bridge-${agent_name}.log" 2>&1 &
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

# ── Public wrappers ───────────────────────────────────────────────────────────

clmux-gemini() {
  # Spawns a Gemini CLI tmux pane as a Claude Code teammate.
  # Usage: clmux-gemini -t <team_name> [-n <agent_name>] [-x <timeout_sec>]
  _clmux_spawn_agent gemini gemini-worker "Type your message" keys 0 colour33 "$@"
}

clmux-gemini-stop() {
  # Stops the Gemini bridge and closes the Gemini pane.
  # Usage: clmux-gemini-stop -t <team_name> [-n <agent_name>]
  _clmux_stop_agent clmux-gemini gemini-worker "$@"
}

clmux-codex() {
  # Spawns a Codex CLI tmux pane as a Claude Code teammate.
  # Usage: clmux-codex -t <team_name> [-n <agent_name>] [-x <timeout_sec>]
  _clmux_spawn_agent codex codex-worker "›" paste 1 colour36 "$@"
}

clmux-codex-stop() {
  # Stops the Codex bridge and closes the Codex pane.
  # Usage: clmux-codex-stop -t <team_name> [-n <agent_name>]
  _clmux_stop_agent clmux-codex codex-worker "$@"
}

clmux-ls() {
  local sessions
  sessions=$(tmux ls 2>/dev/null) || { echo "no active sessions"; return; }
  echo "$sessions"
  # orphaned 세션 경고 (attached 클라이언트 없는 세션)
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
