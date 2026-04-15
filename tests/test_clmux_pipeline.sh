#!/usr/bin/env bash
# tests/test_clmux_pipeline.sh
#
# Integration tests for scripts/clmux_pipeline.sh
# All tests use --headless (no iTerm). AppleScript paths gated by
# CLMUX_PIPELINE_TEST_ITERM=1.
#
# Exit 0: all tests passed
# Exit 1: at least one test failed
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE="bash $CLMUX_DIR/scripts/clmux_pipeline.sh"

tmpdir=$(mktemp -d)
_cleanup() {
    rm -rf "$tmpdir"
    # shellcheck disable=SC2046
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^testpipe_$$" \
        | while IFS= read -r _s; do tmux kill-session -t "$_s" 2>/dev/null || true; done \
        || true
}
trap '_cleanup' EXIT

test_count=0
fail_count=0

pass() {
    test_count=$(( test_count + 1 ))
    echo "✓ test $test_count: $*"
}

fail() {
    fail_count=$(( fail_count + 1 ))
    echo "FAIL: $*" >&2
}

assert_eq() {
    local got="$1" want="$2" msg="${3:-}"
    if [[ "$got" != "$want" ]]; then
        fail "${msg:-assert_eq}: got='$got' want='$want'"
        return 1
    fi
}

assert_session_exists() {
    tmux has-session -t "$1" 2>/dev/null || { fail "session '$1' should exist but does not"; return 1; }
}

assert_session_gone() {
    if tmux has-session -t "$1" 2>/dev/null; then
        fail "session '$1' should be gone but still exists"
        return 1
    fi
}

# Poll for a session's first pane to be running zsh, up to ~3s.
# Returns 0 on success, 1 on timeout. Avoids flakes on loaded CI runners where
# a fixed 'sleep 0.3' after tmux new-session may fire before zsh is ready and
# cause send-keys to drop.
_wait_for_zsh() {
    local target="$1"
    local cmd attempts=0
    while (( attempts < 30 )); do
        cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || true)
        if [[ "$cmd" == "zsh" ]]; then
            return 0
        fi
        sleep 0.1
        attempts=$(( attempts + 1 ))
    done
    return 1
}

# Unique prefix per run to avoid collision with user sessions
PFX="testpipe_$$"

# ---------------------------------------------------------------------------
# Test 1: create --headless creates tmux session, prints pane id,
#         no @iterm_window_id set
# ---------------------------------------------------------------------------
sess="${PFX}_1"
pane_id=$($PIPELINE create "$sess" --headless)
assert_session_exists "$sess"
[[ "$pane_id" == %* ]] || { fail "pane_id should start with % got='$pane_id'"; }
wid=$(tmux show-option -t "$sess" -v @iterm_window_id 2>/dev/null || true)
assert_eq "$wid" "" "no @iterm_window_id in headless mode"
pass "create --headless creates session, prints pane id, no iterm window id"

# ---------------------------------------------------------------------------
# Test 2: create --headless --tag sets @pipeline_tag
# ---------------------------------------------------------------------------
sess="${PFX}_2"
$PIPELINE create "$sess" --headless --tag "foo" >/dev/null
tag=$(tmux show-option -t "$sess" -v @pipeline_tag 2>/dev/null || true)
assert_eq "$tag" "foo" "@pipeline_tag should be foo"
pass "create --headless --tag foo sets @pipeline_tag"

# ---------------------------------------------------------------------------
# Test 3: create --headless --cwd sets session default path
# ---------------------------------------------------------------------------
sess="${PFX}_3"
$PIPELINE create "$sess" --headless --cwd /tmp >/dev/null
# Wait for zsh to be ready so pane_current_path reflects the real cwd
_wait_for_zsh "$sess" || { fail "test 3: zsh did not become ready within 3s"; }
actual_cwd=$(tmux display-message -p -t "$sess" '#{pane_current_path}' 2>/dev/null || true)
# macOS resolves /tmp -> /private/tmp; accept either
resolved_tmp=$(cd /tmp && pwd -P)
if [[ "$actual_cwd" != "/tmp" && "$actual_cwd" != "$resolved_tmp" ]]; then
    fail "pane_current_path should be /tmp or $resolved_tmp, got '$actual_cwd'"
fi
pass "create --headless --cwd /tmp — pane_current_path is /tmp (or resolved)"

# ---------------------------------------------------------------------------
# Test 4: shutdown --dry-run does NOT kill session; prints expected info
# ---------------------------------------------------------------------------
sess="${PFX}_4"
$PIPELINE create "$sess" --headless --tag "drytest" >/dev/null
output=$($PIPELINE shutdown "$sess" --dry-run)
assert_session_exists "$sess"
[[ "$output" == *"DRY-RUN"* ]] || { fail "dry-run output should contain DRY-RUN"; }
[[ "$output" == *"$sess"* ]] || { fail "dry-run output should contain session name"; }
pass "shutdown --dry-run does not kill session and prints info"

# ---------------------------------------------------------------------------
# Test 5: shutdown on zsh-only pane -> graceful exit, exit code 0
# ---------------------------------------------------------------------------
sess="${PFX}_5"
$PIPELINE create "$sess" --headless >/dev/null
# Wait for zsh to be ready — fixed sleeps race on loaded runners
_wait_for_zsh "$sess" || { fail "test 5: zsh did not become ready within 3s"; }
ec=0
$PIPELINE shutdown "$sess" --timeout 8 || ec=$?
assert_eq "$ec" "0" "graceful shutdown of zsh session should exit 0"
assert_session_gone "$sess"
pass "shutdown zsh-only pane — graceful exit code 0, session gone"

# ---------------------------------------------------------------------------
# Test 6: shutdown on pane running 'sleep 60' with short timeout -> force
#         fallback (exit code 2), session gone
# ---------------------------------------------------------------------------
sess="${PFX}_6"
$PIPELINE create "$sess" --headless >/dev/null
# Wait for zsh before send-keys; otherwise on slow runners the keystrokes
# get dropped and the shell exits normally, giving the wrong exit code.
_wait_for_zsh "$sess" || { fail "test 6: zsh did not become ready within 3s"; }
# Send sleep 60 so the shell won't exit on 'exit' quickly
tmux send-keys -t "$sess" "sleep 60" Enter
# Give tmux a moment to deliver the keys and start the sleep
sleep 0.3
ec=0
$PIPELINE shutdown "$sess" --timeout 2 || ec=$?
assert_eq "$ec" "2" "force fallback exit code should be 2"
assert_session_gone "$sess"
pass "shutdown with sleep 60 + --timeout 2 triggers force fallback, exit 2"

# ---------------------------------------------------------------------------
# Test 7: shutdown --force — immediate kill, no graceful steps, exit 0
# ---------------------------------------------------------------------------
sess="${PFX}_7"
$PIPELINE create "$sess" --headless >/dev/null
ec=0
$PIPELINE shutdown "$sess" --force || ec=$?
assert_eq "$ec" "0" "force shutdown exit code should be 0"
assert_session_gone "$sess"
pass "shutdown --force immediate kill, exit 0"

# ---------------------------------------------------------------------------
# Test 8: shutdown on non-existent session -> exit 0 (idempotent)
# ---------------------------------------------------------------------------
nonexist="${PFX}_nonexistent_$$"
ec=0
$PIPELINE shutdown "$nonexist" || ec=$?
assert_eq "$ec" "0" "shutdown on missing session should be idempotent (exit 0)"
pass "shutdown non-existent session exits 0 (idempotent)"

# ---------------------------------------------------------------------------
# Test 9: shutdown-tagged with 2 tagged sessions + 1 untagged -> only tagged killed
# ---------------------------------------------------------------------------
sess_a="${PFX}_9a"
sess_b="${PFX}_9b"
sess_c="${PFX}_9c"  # untagged
$PIPELINE create "$sess_a" --headless --tag "orch-test" >/dev/null
$PIPELINE create "$sess_b" --headless --tag "orch-test" >/dev/null
$PIPELINE create "$sess_c" --headless >/dev/null
sleep 0.3
ec=0
$PIPELINE shutdown-tagged "orch-test" --timeout 8 || ec=$?
[[ "$ec" -eq 0 ]] || { fail "shutdown-tagged exit code should be 0, got $ec"; }
assert_session_gone "$sess_a"
assert_session_gone "$sess_b"
assert_session_exists "$sess_c"
# Clean up untagged
tmux kill-session -t "$sess_c" 2>/dev/null || true
pass "shutdown-tagged kills only tagged sessions, leaves untagged intact"

# ---------------------------------------------------------------------------
# Test 10: list with 2 sessions -> both appear; list --tag -> only tagged appears
# ---------------------------------------------------------------------------
sess_d="${PFX}_10d"
sess_e="${PFX}_10e"
$PIPELINE create "$sess_d" --headless --tag "listtag" >/dev/null
$PIPELINE create "$sess_e" --headless >/dev/null
list_all=$($PIPELINE list)
[[ "$list_all" == *"$sess_d"* ]] || { fail "list should show $sess_d"; }
[[ "$list_all" == *"$sess_e"* ]] || { fail "list should show $sess_e"; }
list_tagged=$($PIPELINE list --tag "listtag")
[[ "$list_tagged" == *"$sess_d"* ]] || { fail "list --tag listtag should show $sess_d"; }
[[ "$list_tagged" != *"$sess_e"* ]] || { fail "list --tag listtag should NOT show untagged $sess_e"; }
tmux kill-session -t "$sess_d" 2>/dev/null || true
tmux kill-session -t "$sess_e" 2>/dev/null || true
pass "list shows all sessions; list --tag filters correctly"

# ---------------------------------------------------------------------------
# Test 11: info shows name, tag, panes
# ---------------------------------------------------------------------------
sess="${PFX}_11"
$PIPELINE create "$sess" --headless --tag "infotag" >/dev/null
info_out=$($PIPELINE info "$sess")
[[ "$info_out" == *"name: $sess"* ]] || { fail "info should show name: $sess"; }
[[ "$info_out" == *"tag: infotag"* ]] || { fail "info should show tag: infotag"; }
[[ "$info_out" == *"panes:"* ]] || { fail "info should show panes: section"; }
# Pane id line starts with %
[[ "$info_out" == *"%"* ]] || { fail "info should show at least one pane id (%...)"; }
pass "info shows name, tag, and panes"

# ---------------------------------------------------------------------------
# Test 12: SAFETY REGRESSION — unrelated sessions unaffected by targeted shutdown
# ---------------------------------------------------------------------------
# This guards against the AppleScript-contents-grep class of bug:
# create 2 sessions with NO pipeline tags, shut down a third pipeline session,
# assert the two unrelated sessions are untouched.
unrelated_a="${PFX}_unrelated_a"
unrelated_b="${PFX}_unrelated_b"
pipeline_target="${PFX}_safety_target"

# Create unrelated sessions (no tag — raw tmux, not via pipeline, to be safe)
tmux new-session -d -s "$unrelated_a" "exec zsh"
tmux new-session -d -s "$unrelated_b" "exec zsh"

# Create pipeline session to shut down
$PIPELINE create "$pipeline_target" --headless --tag "safety-test" >/dev/null
sleep 0.3

# Shut down ONLY the pipeline session
$PIPELINE shutdown "$pipeline_target" --timeout 5 || true

# Verify unrelated sessions survived
assert_session_exists "$unrelated_a"
assert_session_exists "$unrelated_b"
assert_session_gone "$pipeline_target"

tmux kill-session -t "$unrelated_a" 2>/dev/null || true
tmux kill-session -t "$unrelated_b" 2>/dev/null || true
pass "SAFETY REGRESSION: unrelated sessions unaffected by targeted shutdown"

# ---------------------------------------------------------------------------
# Test 13: Session-name injection via tmux target syntax is rejected
# ---------------------------------------------------------------------------
# Names containing ':' or '.' are tmux target syntax. If accepted, -t would
# silently retarget. We must reject them before touching tmux.
bad_name="bad:name"
ec=0
$PIPELINE create "$bad_name" --headless >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || { fail "create '$bad_name' should exit non-zero, got $ec"; }
# Ensure no session was accidentally created under the colon-prefix
if tmux has-session -t "bad" 2>/dev/null; then
    fail "create '$bad_name' must not create a 'bad' session"
    tmux kill-session -t "bad" 2>/dev/null || true
fi

bad_name2="bad.name"
ec=0
$PIPELINE create "$bad_name2" --headless >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || { fail "create '$bad_name2' should exit non-zero, got $ec"; }

# shutdown also rejects it (argument validation happens before tmux call)
ec=0
$PIPELINE shutdown "$bad_name" >/dev/null 2>&1 || ec=$?
[[ "$ec" -ne 0 ]] || { fail "shutdown '$bad_name' should exit non-zero, got $ec"; }
pass "session-name injection rejected (':' and '.' in name)"

# ---------------------------------------------------------------------------
# iTerm tests (only if CLMUX_PIPELINE_TEST_ITERM=1)
# ---------------------------------------------------------------------------
if [[ "${CLMUX_PIPELINE_TEST_ITERM:-0}" == "1" ]]; then
    echo "--- iTerm integration tests ---"
    sess_iterm="${PFX}_iterm"
    $PIPELINE create "$sess_iterm" --tag "iterm-test" >/dev/null
    wid_i=$(tmux show-option -t "$sess_iterm" -v @iterm_window_id 2>/dev/null || true)
    [[ -n "$wid_i" ]] || { fail "iTerm create: @iterm_window_id should be set"; }
    [[ "$wid_i" =~ ^[0-9]+$ ]] || { fail "iTerm window id should be integer, got '$wid_i'"; }
    $PIPELINE shutdown "$sess_iterm" --force
    echo "✓ iTerm: create stores integer window id, shutdown closes window"
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [[ "$fail_count" -gt 0 ]]; then
    echo "FAIL: $fail_count test(s) failed out of $test_count" >&2
    exit 1
fi

echo "PASS: $test_count tests passed"
