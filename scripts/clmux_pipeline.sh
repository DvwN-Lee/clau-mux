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

_session_exists() {
    tmux has-session -t "$1" 2>/dev/null
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

    [[ -z "$name" ]] && { echo "ERROR: session name required" >&2; exit 1; }

    _require_tmux

    tmux new-session -d -s "$name" -c "$cwd" "exec zsh"
    tmux set-option -t "$name" @pipeline_created_at "$(date +%s)"

    if [[ -n "$tag" ]]; then
        tmux set-option -t "$name" @pipeline_tag "$tag"
    fi

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

    tmux list-panes -t "$name" -F '#{pane_id}' | head -1
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
    create)    cmd_create "$@" ;;
    --help|-h) _usage ;;
    *)
        echo "ERROR: unknown subcommand '$subcmd'" >&2
        _usage
        ;;
esac
