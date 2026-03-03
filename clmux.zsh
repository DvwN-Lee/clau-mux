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

  # 인자 파싱: -n <name>은 세션 이름, 나머지는 Claude Code에 전달
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
    else
      clmux_args+=("${args[$i]}")
      ((i++))
    fi
  done

  # tmux 내부: 세션 관리 없이 바로 실행
  if [[ -n "$TMUX" ]]; then
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
  if tmux has-session -t "$session_name" 2>/dev/null; then
    local pane_dead
    pane_dead=$(tmux list-panes -t "$session_name" -F '#{pane_dead}' 2>/dev/null | head -1)
    if [[ "$pane_dead" == "1" ]]; then
      # 좀비 세션 → 자동 정리 후 재생성
      echo "[$session_name] restarting stale session."
      tmux kill-session -t "$session_name"
    else
      # 라이브 세션 → 새 접근 차단 (멀티 인스턴스 충돌 방지)
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
  tmux attach-session -t "$session_name"
}

alias clmux-ls='tmux ls 2>/dev/null || echo "no active sessions"'

# update tmux window name to current git branch after each command
_clmux_precmd() {
  [[ -n "$TMUX" ]] || return
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  tmux rename-window "$branch"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _clmux_precmd
