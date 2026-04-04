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
      clmux-gemini -t "$g_team"
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
    local g_agent="gemini-worker"
    local g_team_dir="$HOME/.claude/teams/$g_team"
    local g_inbox_dir="$g_team_dir/inboxes"
    local g_inbox="$g_inbox_dir/$g_agent.json"
    local g_outbox="$g_inbox_dir/team-lead.json"
    local g_pid_file="$g_team_dir/.${g_agent}-bridge.pid"
    local g_pane_file="$g_team_dir/.${g_agent}-pane"

    mkdir -p "$g_inbox_dir"
    [[ ! -f "$g_inbox" ]]  && echo '[]' > "$g_inbox"
    [[ ! -f "$g_outbox" ]] && echo '[]' > "$g_outbox"

    # config.json 자동 생성
    if [[ ! -f "$g_team_dir/config.json" ]]; then
      printf '{\n  "name": "%s",\n  "members": []\n}\n' "$g_team" > "$g_team_dir/config.json"
    fi

    # Lead pane 가져오기
    local g_lead_pane
    g_lead_pane=$(tmux list-panes -t "=$session_name" -F '#{pane_id}' | head -1)

    # Gemini pane 스폰
    local g_gemini_pane
    g_gemini_pane=$(tmux split-window -t "$g_lead_pane" -h -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$g_outbox CLMUX_AGENT=$g_agent gemini")

    # 스타일 적용
    tmux select-pane -t "$g_gemini_pane" -P "fg=#4285F4"
    tmux select-pane -t "$g_gemini_pane" -T "$g_agent"
    tmux set-option -t "=$session_name" pane-border-status top
    tmux set-option -t "=$session_name" pane-border-format ' #{pane_title} '
    tmux resize-pane -t "$g_gemini_pane" -x 70%
    tmux select-pane -t "$g_lead_pane"

    echo "$g_gemini_pane" > "$g_pane_file"

    # config.json에 pane ID 업데이트
    cat > /tmp/clmux_update_pane.py << 'PYEOF'
import json, sys, time
team_dir, agent_name, pane_id = sys.argv[1], sys.argv[2], sys.argv[3]
cfg_path = f"{team_dir}/config.json"
with open(cfg_path) as f:
    cfg = json.load(f)
team_name = cfg.get('name', team_dir.split('/')[-1])
updated = False
for m in cfg['members']:
    if m.get('name') == agent_name or m.get('agentId', '').startswith(f'{agent_name}@'):
        m['tmuxPaneId'] = pane_id
        m['isActive'] = True
        updated = True
        break
if not updated:
    cfg['members'].append({
        "agentId": f"{agent_name}@{team_name}",
        "name": agent_name,
        "model": "gemini",
        "joinedAt": int(time.time() * 1000),
        "tmuxPaneId": pane_id,
        "cwd": ".",
        "backendType": "tmux",
        "isActive": True
    })
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF
    python3 /tmp/clmux_update_pane.py "$g_team_dir" "$g_agent" "$g_gemini_pane"

    # Bridge 시작
    if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/gemini-bridge.zsh" ]]; then
      for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
        [[ -f "$_d/gemini-bridge.zsh" ]] && { CLMUX_DIR="$_d"; break; }
      done
    fi
    [[ -f "$CLMUX_DIR/gemini-bridge.zsh" ]] || { echo "error: cannot find clau-mux directory" >&2; return 1; }
    zsh "$CLMUX_DIR/gemini-bridge.zsh" \
      -p "$g_gemini_pane" -i "$g_inbox" -t 30 \
      >> "/tmp/gbridge-${g_agent}.log" 2>&1 &
    echo $! > "$g_pid_file"
    disown

    echo "[clmux] $g_agent attached — pane:$g_gemini_pane  team:$g_team"
  fi

  tmux attach-session -t "=$session_name"
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

clmux-gemini() {
  # Spawns a Gemini CLI tmux pane as a Claude Code teammate.
  # Usage: clmux-gemini -t <team_name> [-n <agent_name>] [-c <color>] [-x <timeout_sec>]
  #   -t  team name (matches ~/.claude/teams/<team_name>/)
  #   -n  agent name used in messages          (default: gemini-worker)
  #   -c  tmux pane fg color                   (default: #4285F4 — Google Blue)
  #   -x  idle-wait timeout in seconds         (default: 30)

  [[ -z "$TMUX" ]] && { echo "error: clmux-gemini must be run inside a tmux session" >&2; return 1; }
  command -v gemini &>/dev/null || { echo "error: gemini CLI not found in PATH" >&2; return 1; }

  local team_name="" agent_name="gemini-worker" color="#4285F4" timeout=30
  local OPTIND=1
  while getopts "t:n:c:x:" opt; do
    case $opt in
      t) team_name="$OPTARG" ;;
      n) agent_name="$OPTARG" ;;
      c) color="$OPTARG" ;;
      x) timeout="$OPTARG" ;;
      *) echo "Usage: clmux-gemini -t <team_name> [-n <name>] [-c <color>] [-x <timeout>]" >&2; return 1 ;;
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

  # Spawn Gemini pane to the right
  local gemini_pane
  gemini_pane=$(tmux split-window -h -P -F '#{pane_id}' "exec env CLMUX_OUTBOX=$outbox CLMUX_AGENT=$agent_name gemini")

  # Style the Gemini pane
  tmux select-pane -t "$gemini_pane" -P "fg=$color"
  tmux select-pane -t "$gemini_pane" -T "$agent_name"
  tmux set-option pane-border-status top
  tmux set-option pane-border-format ' #{pane_title} '

  # Resize Gemini pane to 70% of total window width
  tmux resize-pane -t "$gemini_pane" -x 70%

  # Return focus to lead pane
  tmux select-pane -t "$lead_pane"

  # Persist pane ID for stop command
  echo "$gemini_pane" > "$pane_file"

  # Update team config.json with the live pane ID
  cat > /tmp/clmux_update_pane.py << 'PYEOF'
import json, sys, time
team_dir, agent_name, pane_id = sys.argv[1], sys.argv[2], sys.argv[3]
cfg_path = f"{team_dir}/config.json"
with open(cfg_path) as f:
    cfg = json.load(f)
team_name = cfg.get('name', team_dir.split('/')[-1])
updated = False
for m in cfg['members']:
    if m.get('name') == agent_name or m.get('agentId', '').startswith(f'{agent_name}@'):
        m['tmuxPaneId'] = pane_id
        m['isActive'] = True
        updated = True
        break
if not updated:
    cfg['members'].append({
        "agentId": f"{agent_name}@{team_name}",
        "name": agent_name,
        "model": "gemini",
        "joinedAt": int(time.time() * 1000),
        "tmuxPaneId": pane_id,
        "cwd": ".",
        "backendType": "tmux",
        "isActive": True
    })
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF
  python3 /tmp/clmux_update_pane.py "$team_dir" "$agent_name" "$gemini_pane"

  # Start bridge in background
  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/gemini-bridge.zsh" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/gemini-bridge.zsh" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/gemini-bridge.zsh" ]] || { echo "error: cannot find clau-mux directory" >&2; return 1; }
  zsh "$CLMUX_DIR/gemini-bridge.zsh" \
    -p "$gemini_pane" -i "$inbox" -t "$timeout" \
    >> "/tmp/gbridge-${agent_name}.log" 2>&1 &
  echo $! > "$pid_file"
  disown

  echo "[clmux-gemini] $agent_name attached — pane:$gemini_pane  bridge PID:$(< "$pid_file")"
}

clmux-gemini-stop() {
  # Stops the Gemini bridge and closes the Gemini pane.
  # Usage: clmux-gemini-stop -t <team_name> [-n <agent_name>]

  local team_name="" agent_name="gemini-worker"
  local OPTIND=1
  while getopts "t:n:" opt; do
    case $opt in
      t) team_name="$OPTARG" ;;
      n) agent_name="$OPTARG" ;;
      *) echo "Usage: clmux-gemini-stop -t <team_name> [-n <name>]" >&2; return 1 ;;
    esac
  done

  [[ -z "$team_name" ]] && { echo "error: -t <team_name> required" >&2; return 1; }

  local team_dir="$HOME/.claude/teams/$team_name"
  local pid_file="$team_dir/.${agent_name}-bridge.pid"
  local pane_file="$team_dir/.${agent_name}-pane"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid=$(< "$pid_file")
    kill "$pid" 2>/dev/null && echo "[clmux-gemini-stop] bridge PID $pid stopped"
    rm -f "$pid_file"
  else
    echo "[clmux-gemini-stop] no bridge PID found for $agent_name"
  fi

  if [[ -f "$pane_file" ]]; then
    local pane_id
    pane_id=$(< "$pane_file")
    tmux kill-pane -t "$pane_id" 2>/dev/null && echo "[clmux-gemini-stop] pane $pane_id closed"
    rm -f "$pane_file"
  else
    echo "[clmux-gemini-stop] no pane ID found for $agent_name"
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
