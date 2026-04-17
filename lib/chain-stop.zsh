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
