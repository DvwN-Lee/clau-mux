#!/usr/bin/env bash
# scripts/clmux_pipeline.sh
#
# Pipeline lifecycle manager: create / shutdown / list / info tmux sessions
# with iTerm window tracking (id-based, never text-grep).
#
# Safety invariants:
#   - iTerm window close uses `id of window` ONLY (integer, never text-grep)
#   - Store iTerm window id in @iterm_window_id user-option on the session
#   - Graceful-first shutdown; force only after timeout
#   - Dry-run support: prints impact without executing
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_require_tmux() {
    if ! command -v tmux >/dev/null 2>&1; then
        echo "ERROR: tmux not found in PATH" >&2
        exit 1
    fi
}

# Reject session names that tmux would interpret as target-syntax
# (e.g. "bad:window" or "bad.pane"). Also rejects empty names.
_validate_name() {
    local n="$1"
    if [[ -z "$n" ]]; then
        echo "ERROR: session name required" >&2
        exit 1
    fi
    if [[ "$n" == *:* || "$n" == *.* ]]; then
        echo "ERROR: session name must not contain ':' or '.' (got: $n)" >&2
        exit 1
    fi
}

_iterm_close_by_id() {
    local wid="$1"
    [[ -z "$wid" ]] && return 0
    osascript - "$wid" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set wid to (item 1 of argv) as integer
    tell application "iTerm2"
        try
            close (first window whose id is wid)
        end try
    end tell
end run
APPLESCRIPT
}

_format_uptime() {
    local secs="$1"
    local h m s
    h=$(( secs / 3600 ))
    m=$(( (secs % 3600) / 60 ))
    s=$(( secs % 60 ))
    printf "%02d:%02d:%02d" "$h" "$m" "$s"
}

_date_from_epoch() {
    local ts="$1"
    [[ -z "$ts" ]] && { echo "-"; return; }
    # macOS (BSD) date uses -r; GNU date uses -d
    if date -r "$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null; then
        return
    fi
    date -d "@$ts" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "-"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

_usage() {
    cat >&2 <<'USAGE'
Usage: clmux_pipeline.sh <subcommand> [options]

Subcommands:
  create <name> [--headless] [--cwd <path>] [--tag <tag>]
      Create a tmux session. Without --headless, opens an iTerm2 window
      and stores its integer window id in @iterm_window_id.
      Prints the first pane id (e.g. %141) on stdout.

  shutdown <name> [--timeout <sec>] [--force] [--dry-run]
      Gracefully shut down a session (default timeout: 10s).
      Exit codes: 0=clean, 2=force fallback used, 3=iTerm close failed.

  shutdown-tagged <tag> [--timeout <sec>]
      Gracefully shut down all sessions tagged with <tag>.

  list [--tag <filter>]
      List pipeline sessions with NAME, PANE, WINDOW_ID, TAG, UPTIME columns.

  info <name>
      Detailed dump of a single session.

  kill <name>
      Alias for: shutdown <name> --force
USAGE
    exit 1
}

# ---------------------------------------------------------------------------
# create
# ---------------------------------------------------------------------------

cmd_create() {
    local name=""
    local headless=0
    local cwd="$PWD"
    local tag=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --headless) headless=1; shift ;;
            --cwd)      cwd="$2"; shift 2 ;;
            --tag)      tag="$2"; shift 2 ;;
            -*)         echo "ERROR: unknown option $1" >&2; exit 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    echo "ERROR: unexpected argument $1" >&2; exit 1
                fi
                ;;
        esac
    done

    _validate_name "$name"
    _require_tmux

    # Create tmux session
    tmux new-session -d -s "$name" -c "$cwd" "exec zsh"

    # Store creation timestamp
    tmux set-option -t "$name" @pipeline_created_at "$(date +%s)"

    # Store tag if provided
    if [[ -n "$tag" ]]; then
        tmux set-option -t "$name" @pipeline_tag "$tag"
    fi

    # iTerm path (skipped in headless mode)
    if [[ "$headless" -eq 0 ]]; then
        local wid
        wid=$(osascript - "$name" <<'APPLESCRIPT' 2>/dev/null
on run argv
    set sname to item 1 of argv
    tell application "iTerm2"
        set w to create window with default profile
        tell current session of current tab of w
            write text ("tmux attach-session -t " & sname)
        end tell
        return id of w
    end tell
end run
APPLESCRIPT
        ) || true
        if [[ -n "$wid" ]]; then
            tmux set-option -t "$name" @iterm_window_id "$wid"
        fi
    fi

    # Print first pane id
    tmux list-panes -t "$name" -F '#{pane_id}' | head -1
}

# ---------------------------------------------------------------------------
# shutdown
# ---------------------------------------------------------------------------

cmd_shutdown() {
    local name=""
    local timeout=10
    local force=0
    local dry_run=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) timeout="$2"; shift 2 ;;
            --force)   force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            -*)        echo "ERROR: unknown option $1" >&2; exit 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    echo "ERROR: unexpected argument $1" >&2; exit 1
                fi
                ;;
        esac
    done

    _validate_name "$name"
    _require_tmux

    # Idempotent: not-found is success
    if ! tmux has-session -t "$name" 2>/dev/null; then
        return 0
    fi

    # Capture iTerm window id BEFORE any destructive action
    local wid
    wid=$(tmux show-option -t "$name" -v @iterm_window_id 2>/dev/null || true)

    # --dry-run: print info and exit without destroying anything
    if [[ "$dry_run" -eq 1 ]]; then
        echo "DRY-RUN: session=$name"
        echo "  iterm_window_id=${wid:--}"
        local tag
        tag=$(tmux show-option -t "$name" -v @pipeline_tag 2>/dev/null || true)
        echo "  tag=${tag:--}"
        echo "  panes:"
        tmux list-panes -t "$name" -F '    #{pane_id} #{pane_current_command}'
        return 0
    fi

    # --force: immediate kill
    if [[ "$force" -eq 1 ]]; then
        tmux kill-session -t "$name"
        if [[ -n "$wid" ]]; then
            _iterm_close_by_id "$wid" || true
        fi
        return 0
    fi

    # -----------
    # Graceful path
    # -----------

    # Capture pane list ONCE at the start. Reuse it for the C-c fallback so we
    # don't re-query after the session may have self-destructed (which would
    # produce stderr noise and a TOCTOU window).
    local pane_list
    pane_list=$(tmux list-panes -t "$name" -F '#{pane_id} #{pane_current_command}' 2>/dev/null || true)

    # Send appropriate exit signal to each pane
    while IFS=' ' read -r pane_id pane_cmd; do
        [[ -z "$pane_id" ]] && continue
        case "$pane_cmd" in
            claude|node)
                tmux send-keys -t "$pane_id" Escape 2>/dev/null || true
                tmux send-keys -t "$pane_id" Escape 2>/dev/null || true
                sleep 0.3
                tmux send-keys -t "$pane_id" "/exit" Enter 2>/dev/null || true
                ;;
            zsh|bash|fish|sh)
                tmux send-keys -t "$pane_id" "exit" Enter 2>/dev/null || true
                ;;
            *)
                tmux send-keys -t "$pane_id" C-d 2>/dev/null || true
                ;;
        esac
    done <<< "$pane_list"

    # Wait loop — session may self-destruct once all shells exit
    local elapsed=0
    while tmux has-session -t "$name" 2>/dev/null && (( elapsed < timeout )); do
        sleep 1
        (( elapsed++ )) || true
    done

    # If session already gone, skip C-c fallback entirely
    if tmux has-session -t "$name" 2>/dev/null; then
        # C-c fallback — reuse the captured pane_list (no re-query).
        # Panes may no longer exist; send-keys failures are expected and tolerated.
        while IFS=' ' read -r pane_id _; do
            [[ -z "$pane_id" ]] && continue
            tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
            tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
        done <<< "$pane_list"
        sleep 2
    fi

    local exit_code=0

    # Still alive after C-c? Force kill with exit code 2
    if tmux has-session -t "$name" 2>/dev/null; then
        echo "WARNING: graceful shutdown timed out; force-killing $name" >&2
        tmux kill-session -t "$name"
        exit_code=2
    fi

    # Close iTerm window ONLY by captured integer id
    if [[ -n "$wid" ]]; then
        if ! _iterm_close_by_id "$wid"; then
            echo "WARNING: failed to close iTerm window id=$wid" >&2
            if [[ "$exit_code" -eq 0 ]]; then
                exit_code=3
            fi
        fi
    fi

    return "$exit_code"
}

# ---------------------------------------------------------------------------
# shutdown-tagged
# ---------------------------------------------------------------------------

cmd_shutdown_tagged() {
    local target_tag=""
    local pass_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) pass_args+=("--timeout" "$2"); shift 2 ;;
            -*)        echo "ERROR: unknown option $1" >&2; exit 1 ;;
            *)
                if [[ -z "$target_tag" ]]; then
                    target_tag="$1"; shift
                else
                    echo "ERROR: unexpected argument $1" >&2; exit 1
                fi
                ;;
        esac
    done

    [[ -z "$target_tag" ]] && { echo "ERROR: tag required" >&2; exit 1; }

    _require_tmux

    local overall=0
    local sess t ec
    # Use while-read-line to tolerate whitespace in session names
    while IFS= read -r sess; do
        [[ -z "$sess" ]] && continue
        t=$(tmux show-option -t "$sess" -v @pipeline_tag 2>/dev/null || true)
        if [[ "$t" == "$target_tag" ]]; then
            ec=0
            cmd_shutdown "$sess" "${pass_args[@]}" || ec=$?
            if [[ "$ec" -ne 0 ]]; then
                overall="$ec"
            fi
        fi
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)

    return "$overall"
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

cmd_list() {
    local tag_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag) tag_filter="$2"; shift 2 ;;
            -*)    echo "ERROR: unknown option $1" >&2; exit 1 ;;
            *)     echo "ERROR: unexpected argument $1" >&2; exit 1 ;;
        esac
    done

    _require_tmux

    local now
    now=$(date +%s)

    printf "%-16s %-8s %-12s %-14s %s\n" "NAME" "PANE" "WINDOW_ID" "TAG" "UPTIME"

    local sess
    # Use while-read-line to tolerate whitespace in session names
    while IFS= read -r sess; do
        [[ -z "$sess" ]] && continue
        local wid tag created_at uptime pane_id
        wid=$(tmux show-option -t "$sess" -v @iterm_window_id 2>/dev/null || true)
        tag=$(tmux show-option -t "$sess" -v @pipeline_tag 2>/dev/null || true)
        created_at=$(tmux show-option -t "$sess" -v @pipeline_created_at 2>/dev/null || true)
        pane_id=$(tmux list-panes -t "$sess" -F '#{pane_id}' 2>/dev/null | head -1 || true)

        # Apply tag filter if set
        if [[ -n "$tag_filter" && "$tag" != "$tag_filter" ]]; then
            continue
        fi

        if [[ -n "$created_at" ]]; then
            uptime=$(_format_uptime $(( now - created_at )))
        else
            uptime="-"
        fi

        printf "%-16s %-8s %-12s %-14s %s\n" \
            "$sess" \
            "${pane_id:--}" \
            "${wid:--}" \
            "${tag:--}" \
            "$uptime"
    done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)
}

# ---------------------------------------------------------------------------
# info
# ---------------------------------------------------------------------------

cmd_info() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -*) echo "ERROR: unknown option $1" >&2; exit 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"; shift
                else
                    echo "ERROR: unexpected argument $1" >&2; exit 1
                fi
                ;;
        esac
    done

    _validate_name "$name"
    _require_tmux

    if ! tmux has-session -t "$name" 2>/dev/null; then
        echo "ERROR: session '$name' not found" >&2
        exit 1
    fi

    local wid tag created_at
    wid=$(tmux show-option -t "$name" -v @iterm_window_id 2>/dev/null || true)
    tag=$(tmux show-option -t "$name" -v @pipeline_tag 2>/dev/null || true)
    created_at=$(tmux show-option -t "$name" -v @pipeline_created_at 2>/dev/null || true)

    echo "name: $name"
    echo "window_id: ${wid:--}"
    echo "tag: ${tag:--}"
    if [[ -n "$created_at" ]]; then
        echo "created_at: $(_date_from_epoch "$created_at")"
    else
        echo "created_at: -"
    fi
    echo "panes:"
    tmux list-panes -t "$name" -F '  #{pane_id}  #{pane_current_command}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# kill (legacy alias)
# ---------------------------------------------------------------------------

cmd_kill() {
    cmd_shutdown "$@" --force
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

_require_tmux

if [[ $# -eq 0 ]]; then
    _usage
fi

subcmd="$1"
shift

case "$subcmd" in
    create)          cmd_create "$@" ;;
    shutdown)        cmd_shutdown "$@" ;;
    shutdown-tagged) cmd_shutdown_tagged "$@" ;;
    list)            cmd_list "$@" ;;
    info)            cmd_info "$@" ;;
    kill)            cmd_kill "$@" ;;
    --help|-h)       _usage ;;
    *)
        echo "ERROR: unknown subcommand '$subcmd'" >&2
        _usage
        ;;
esac
