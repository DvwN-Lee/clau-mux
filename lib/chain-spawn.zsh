# ── Role one-shot helpers ─────────────────────────────────────────────────────
# clmux-master / clmux-mid / clmux-leaf — single-command role setup (+ optional
# child spawn). Replaces the 9-step tmux+chain-register+orchestrate boilerplate
# that skill bodies previously inlined. Self-init on bare call; spawn child
# with positional arg (Master → Mid, Mid → Leaf). Leaves do not fan out.

# Runs osascript with stdout/stderr merged. On success prints stdout (e.g. a
# Ghostty window id) and returns 0. On failure writes an actionable diagnostic
# to stderr — macOS TCC denial (AppleScript error -1743) gets a dedicated hint
# so the user knows Automation permission is missing instead of seeing the
# caller's silent fallback branch.
# Derive a short headline shown in a spawned pane's initial prompt so the
# human attaching the Ghostty tab sees "what this pane is working on" at a
# glance. Full scope stays in the orchestrate delegate envelope (authoritative
# source). Returns via stdout.
#   args: <explicit_label> <fallback_scope>
# - explicit_label non-empty → sanitize and return as-is
# - otherwise derive from scope: first line, then truncate to 200 chars
# - always strip single quotes / CR / LF so the result is safe to embed in
#   a shell-quoted claude prompt string.
_clmux_make_label() {
  local label="$1" scope="$2"
  if [[ -z "$label" ]]; then
    label="${scope%%$'\n'*}"
    if (( ${#label} > 200 )); then
      label="${label[1,200]}…"
    fi
  fi
  label="${label//$'\n'/ }"
  label="${label//$'\r'/ }"
  label="${label//\'/}"
  printf '%s' "$label"
}

_clmux_osascript_capture() {
  local ctx="$1"; shift
  local combined rc
  combined=$(osascript "$@" 2>&1)
  rc=$?
  if (( rc != 0 )); then
    if [[ "$combined" == *"-1743"* ]]; then
      print -u2 "[${ctx}] Ghostty auto-open blocked by macOS TCC (error -1743)."
      print -u2 "        Grant: System Settings → Privacy & Security → Automation"
      print -u2 "          → <parent app> → enable Ghostty"
      print -u2 "        Or set CLMUX_GHOSTTY_AUTO=0 to skip Ghostty auto-open."
    else
      print -u2 "[${ctx}] Ghostty auto-open failed (osascript rc=${rc}): ${combined:-<no output>}"
    fi
    return "$rc"
  fi
  printf '%s' "$combined"
  return 0
}

clmux-master() {
  local project="" scope="" criteria="" label="" force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --scope)    scope="$2"; shift 2 ;;
      --criteria) criteria="$2"; shift 2 ;;
      --label)    label="$2"; shift 2 ;;
      --force)    force=1; shift ;;
      --*) echo "error: unknown flag $1" >&2; return 1 ;;
      *) project="$1"; shift ;;
    esac
  done

  if [[ -n "$scope" && -z "$project" ]]; then
    echo "error: --scope requires a <project> argument" >&2
    return 1
  fi
  if [[ -n "$label" && -z "$scope" ]]; then
    echo "error: --label requires --scope" >&2
    return 1
  fi

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
        _held_by=$(echo "$_out" | grep -oE 'MasterLockError: master role held by [^[:space:]]+' | awk '{print $NF}')
        if [[ -z "$_held_by" ]]; then
          echo "warn: set-master failed: $_out" >&2
        elif [[ "$_held_by" == "<stale>" ]] || [[ "$_held_by" == "<unknown>" ]]; then
          echo "[master] corrupted lock detected (holder=$_held_by); auto-releasing" >&2
          clmux-orchestrate release-master --pane "$TMUX_PANE" --force >/dev/null 2>&1
          clmux-orchestrate set-master --pane "$TMUX_PANE" --label "$_label" >/dev/null 2>&1 \
            || echo "warn: set-master still failed after release; continuing" >&2
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

    # Pass literal slash command so the /clmux-mid skill's gating policy
    # ("user's most recent message must begin with /clmux-mid") is
    # satisfied. Identity/topology lives in tmux pane options; the
    # authoritative scope lives in the delegate envelope sent below. When
    # --scope is supplied we additionally embed a short headline in the
    # spawn prompt (--label explicit value, or auto-derived from scope's
    # first line / 200-char truncation) so the human who attaches the
    # Ghostty tab sees what the pane is working on at a glance.
    local _mid_prompt='/clmux-mid'
    if [[ -n "$scope" ]]; then
      local _mid_headline
      _mid_headline=$(_clmux_make_label "$label" "$scope")
      _mid_prompt=$'/clmux-mid\n\n작업: '"$_mid_headline"
    fi
    tmux new-session -d -s "$session" -c "$proj_path" \
      "claude $(printf %q "$_mid_prompt")"

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

    # Inline: auto-open Ghostty window attached to the Mid session; save the
    # returned Ghostty window id on the Mid pane so a later clmux-mid call can
    # open its Leaf as a new tab. Self-contained (no cross-function dependency)
    # to survive shell-caching edge cases in Claude Code's Bash tool.
    local _ghostty_win_id=""
    # Ghostty launches `command` via `login -flp /bin/bash --noprofile --norc
    # -c "exec -l <cmd>"`, whose PATH is the macOS login default (no
    # Homebrew). `tmux` therefore must be given as an absolute path or
    # `exec -l tmux …` fails with "Press any key to close" before attach.
    local _tmux_bin=${$(command -v tmux):-tmux}
    if [[ "${CLMUX_GHOSTTY_AUTO:-1}" != "0" ]] \
       && [[ "$(uname)" == "Darwin" ]] \
       && command -v osascript >/dev/null 2>&1; then
      # Single-step: command = tmux attach, wait-after-command keeps the
      # window alive with a "Press any key to close" prompt when tmux exits,
      # instead of closing the window.
      _ghostty_win_id=$(_clmux_osascript_capture master \
        -e 'tell application "Ghostty"' \
        -e 'set cfg to new surface configuration' \
        -e "set command of cfg to \"$_tmux_bin attach -t $session\"" \
        -e 'set wait after command of cfg to true' \
        -e 'set newWin to new window with configuration cfg' \
        -e 'return id of newWin' \
        -e 'end tell')
    fi
    if [[ -n "$_ghostty_win_id" ]]; then
      tmux set-option -p -t "$mid_pane" @clmux-ghostty-window-id "$_ghostty_win_id"
      echo "[master] Ghostty window opened: id=$_ghostty_win_id"
    else
      echo "[master] attach: tmux attach -t $session"
    fi

    # Optional scope auto-delegate — when caller supplies --scope, open a
    # parent thread to the spawned Mid so the Mid's /clmux-mid receive body
    # picks up the scope from inbox instead of idling on "waiting-for-delegate".
    if [[ -n "$scope" ]]; then
      local _delegate_args=(--from "$master_pane" --to "$mid_pane" --scope "$scope")
      [[ -n "$criteria" ]] && _delegate_args+=(--criteria "$criteria")
      clmux-orchestrate delegate "${_delegate_args[@]}"
    fi
  fi
}

clmux-mid() {
  local leaf_name="" scope="" criteria="" label="" force=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      --scope)    scope="$2"; shift 2 ;;
      --criteria) criteria="$2"; shift 2 ;;
      --label)    label="$2"; shift 2 ;;
      --force)    force=1; shift ;;
      --*) echo "error: unknown flag $1" >&2; return 1 ;;
      *)  leaf_name="$1"; shift ;;
    esac
  done

  if [[ -n "$label" && -z "$scope" ]]; then
    echo "error: --label requires --scope" >&2
    return 1
  fi

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
      _held_by=$(echo "$_out" | grep -oE 'MasterLockError: master role held by [^[:space:]]+' | awk '{print $NF}')
      if [[ -z "$_held_by" ]]; then
        echo "warn: set-master failed: $_out" >&2
      elif [[ "$_held_by" == "<stale>" ]] || [[ "$_held_by" == "<unknown>" ]]; then
        echo "[mid] corrupted lock detected (holder=$_held_by); auto-releasing" >&2
        clmux-orchestrate release-master --pane "$TMUX_PANE" --force >/dev/null 2>&1
        clmux-orchestrate set-master --pane "$TMUX_PANE" --label "$_label" >/dev/null 2>&1 \
          || echo "warn: set-master still failed after release; continuing" >&2
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

  # Pass literal slash command to satisfy /clmux-leaf gating. Upstream Mid
  # pane id lives in @clmux-chain-peer-up; authoritative scope lives in the
  # orchestrate delegate envelope sent below. When --scope is supplied we
  # additionally embed a short headline in the spawn prompt (same hybrid
  # rule as clmux-master) so Leaf pane's initial view shows what it's on.
  local _leaf_prompt='/clmux-leaf'
  if [[ -n "$scope" ]]; then
    local _leaf_headline
    _leaf_headline=$(_clmux_make_label "$label" "$scope")
    _leaf_prompt=$'/clmux-leaf\n\n작업: '"$_leaf_headline"
  fi
  tmux new-session -d -s "$session" -c "$wt_path" \
    "claude $(printf %q "$_leaf_prompt")"

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

  # Inline Ghostty presence for the Leaf:
  #   - If this Mid pane has @clmux-ghostty-window-id, open a NEW TAB in that window.
  #   - Otherwise (or if tab open fails), open a NEW WINDOW.
  # Self-contained (no cross-function dependency) to survive shell-caching
  # edge cases in Claude Code's Bash tool — same approach as BUG-4 fix.
  local _my_win_id _tab_ok=0
  _my_win_id=$(tmux show-options -p -v @clmux-ghostty-window-id 2>/dev/null)
  # tmux absolute path — Ghostty's login bash runs with minimal PATH.
  local _tmux_bin=${$(command -v tmux):-tmux}
  if [[ -n "$_my_win_id" ]] \
     && [[ "${CLMUX_GHOSTTY_AUTO:-1}" != "0" ]] \
     && [[ "$(uname)" == "Darwin" ]] \
     && command -v osascript >/dev/null 2>&1; then
    # Single-step tab: command = tmux attach, wait-after-command keeps it
    # alive when tmux exits (same pattern as Master window).
    if _clmux_osascript_capture "mid tab" \
         -e 'tell application "Ghostty"' \
         -e 'set cfg to new surface configuration' \
         -e "set command of cfg to \"$_tmux_bin attach -t $session\"" \
         -e 'set wait after command of cfg to true' \
         -e "set newTab to new tab in (window id \"$_my_win_id\") with configuration cfg" \
         -e 'end tell' >/dev/null; then
      _tab_ok=1
    fi
  fi
  if (( _tab_ok )); then
    echo "[mid] Ghostty tab opened in window id=$_my_win_id"
  else
    local _leaf_win_id=""
    if [[ "${CLMUX_GHOSTTY_AUTO:-1}" != "0" ]] \
       && [[ "$(uname)" == "Darwin" ]] \
       && command -v osascript >/dev/null 2>&1; then
      # Single-step window: same pattern as Master, keeps window alive
      # after tmux exit via wait-after-command.
      _leaf_win_id=$(_clmux_osascript_capture "mid window" \
        -e 'tell application "Ghostty"' \
        -e 'set cfg to new surface configuration' \
        -e "set command of cfg to \"$_tmux_bin attach -t $session\"" \
        -e 'set wait after command of cfg to true' \
        -e 'set newWin to new window with configuration cfg' \
        -e 'return id of newWin' \
        -e 'end tell')
    fi
    if [[ -n "$_leaf_win_id" ]]; then
      tmux set-option -p -t "$leaf_pane" @clmux-ghostty-window-id "$_leaf_win_id"
      echo "[mid] Ghostty window opened: id=$_leaf_win_id"
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
