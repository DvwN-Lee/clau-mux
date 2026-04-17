# ── Role one-shot helpers ─────────────────────────────────────────────────────
# clmux-master / clmux-mid / clmux-leaf — single-command role setup (+ optional
# child spawn). Replaces the 9-step tmux+chain-register+orchestrate boilerplate
# that skill bodies previously inlined. Self-init on bare call; spawn child
# with positional arg (Master → Mid, Mid → Leaf). Leaves do not fan out.

# _clmux_iterm_open_window — open a new iTerm window running `tmux attach -t <session>`.
# Echoes the iTerm window id on success; empty (non-zero exit not guaranteed) otherwise.
# Skipped on non-macOS, missing osascript, CLMUX_ITERM_AUTO=0, or iTerm not installed.
# Caller should tolerate empty return (fallback to tmux attach hint).
_clmux_iterm_open_window() {
  local session="$1"
  [[ "${CLMUX_ITERM_AUTO:-1}" == "0" ]] && return 0
  [[ "$(uname)" != "Darwin" ]] && return 0
  command -v osascript >/dev/null 2>&1 || return 0

  local win_id
  win_id=$(osascript \
    -e 'tell application "iTerm"' \
    -e "set newWin to (create window with default profile command \"tmux attach -t $session\")" \
    -e 'return id of newWin as text' \
    -e 'end tell' 2>/dev/null)

  [[ -n "$win_id" ]] && echo "$win_id"
}

# _clmux_iterm_open_tab_in — create a new tab in the iTerm window with given id,
# running `tmux attach -t <session>`. Returns non-zero on failure so caller can
# fall back to _clmux_iterm_open_window.
_clmux_iterm_open_tab_in() {
  local win_id="$1" session="$2"
  [[ "${CLMUX_ITERM_AUTO:-1}" == "0" ]] && return 1
  [[ "$(uname)" != "Darwin" ]] && return 1
  command -v osascript >/dev/null 2>&1 || return 1
  [[ -z "$win_id" ]] && return 1

  osascript \
    -e 'tell application "iTerm"' \
    -e "tell window id $win_id" \
    -e "create tab with default profile command \"tmux attach -t $session\"" \
    -e 'end tell' \
    -e 'end tell' >/dev/null 2>&1
}

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
    # Inline: claim orchestrate master role; auto-release stale lock if holder
    # is not alive in tmux. Self-contained (no cross-function dependency) to
    # survive shell-caching edge cases in Claude Code's Bash tool.
    {
      local _label="master-$(basename "$PWD")"
      local _out
      if _out=$(clmux-orchestrate set-master --pane "$TMUX_PANE" --label "$_label" 2>&1); then
        :
      else
        local _held_by
        _held_by=$(echo "$_out" | grep -oE 'master role held by %[0-9]+' | awk '{print $NF}')
        if [[ -z "$_held_by" ]]; then
          echo "warn: set-master failed: $_out" >&2
        elif tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$_held_by"; then
          echo "warn: master lock held by $_held_by (alive); not auto-releasing. Transfer: clmux-orchestrate release-master --pane $_held_by --force" >&2
        else
          echo "[master] stale lock detected (holder=$_held_by not alive); auto-releasing" >&2
          clmux-orchestrate release-master --pane "$_held_by" --force >/dev/null 2>&1
          clmux-orchestrate set-master --pane "$TMUX_PANE" --label "$_label" >/dev/null 2>&1 \
            || echo "warn: set-master still failed after release; continuing" >&2
        fi
      fi
    }
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

    # Auto-open iTerm window attached to the Mid session; save window id on
    # the Mid pane so a later clmux-mid call can open its Leaf as a new tab.
    local _iterm_win_id
    _iterm_win_id=$(_clmux_iterm_open_window "$session")
    if [[ -n "$_iterm_win_id" ]]; then
      tmux set-option -p -t "$mid_pane" @clmux-iterm-window-id "$_iterm_win_id"
      echo "[master] iTerm window opened: id=$_iterm_win_id"
    else
      echo "[master] attach: tmux attach -t $session"
    fi
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
  # Inline: claim orchestrate master role (Mid is master to its own Leaves);
  # auto-release stale lock if holder is not alive. Self-contained.
  {
    local _label="mid-$(basename "$(git rev-parse --show-toplevel)")"
    local _out
    if _out=$(clmux-orchestrate set-master --pane "$TMUX_PANE" --label "$_label" 2>&1); then
      :
    else
      local _held_by
      _held_by=$(echo "$_out" | grep -oE 'master role held by %[0-9]+' | awk '{print $NF}')
      if [[ -z "$_held_by" ]]; then
        echo "warn: set-master failed: $_out" >&2
      elif tmux list-panes -a -F '#{pane_id}' | grep -qx -- "$_held_by"; then
        echo "warn: master lock held by $_held_by (alive); not auto-releasing. Transfer: clmux-orchestrate release-master --pane $_held_by --force" >&2
      else
        echo "[mid] stale lock detected (holder=$_held_by not alive); auto-releasing" >&2
        clmux-orchestrate release-master --pane "$_held_by" --force >/dev/null 2>&1
        clmux-orchestrate set-master --pane "$TMUX_PANE" --label "$_label" >/dev/null 2>&1 \
          || echo "warn: set-master still failed after release; continuing" >&2
      fi
    fi
  }
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

  # Auto-open iTerm presence for the Leaf:
  #   - If this Mid pane has @clmux-iterm-window-id, open a NEW TAB in that window.
  #   - Otherwise, open a NEW WINDOW (Mode B case, or Master didn't set a window id).
  local _my_win_id
  _my_win_id=$(tmux show-options -p -v @clmux-iterm-window-id 2>/dev/null)
  if [[ -n "$_my_win_id" ]] && _clmux_iterm_open_tab_in "$_my_win_id" "$session"; then
    echo "[mid] iTerm tab opened in window id=$_my_win_id"
  else
    local _leaf_win_id
    _leaf_win_id=$(_clmux_iterm_open_window "$session")
    if [[ -n "$_leaf_win_id" ]]; then
      tmux set-option -p -t "$leaf_pane" @clmux-iterm-window-id "$_leaf_win_id"
      echo "[mid] iTerm window opened: id=$_leaf_win_id"
    else
      echo "[mid] attach: tmux attach -t $session"
    fi
  fi
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
