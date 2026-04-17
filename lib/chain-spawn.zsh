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
