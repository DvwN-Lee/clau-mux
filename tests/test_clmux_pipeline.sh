#!/usr/bin/env bash
# tests/test_clmux_pipeline.sh  (commit 3: shutdown-tagged + safety regression)
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

PFX="testpipe_$$"

# Test 1: create --headless
sess="${PFX}_1"
pane_id=$($PIPELINE create "$sess" --headless)
assert_session_exists "$sess"
[[ "$pane_id" == %* ]] || { fail "pane_id should start with % got='$pane_id'"; }
wid=$(tmux show-option -t "$sess" -v @iterm_window_id 2>/dev/null || true)
assert_eq "$wid" "" "no @iterm_window_id in headless mode"
pass "create --headless creates session, prints pane id, no iterm window id"

# Test 2: create --headless --tag
sess="${PFX}_2"
$PIPELINE create "$sess" --headless --tag "foo" >/dev/null
tag=$(tmux show-option -t "$sess" -v @pipeline_tag 2>/dev/null || true)
assert_eq "$tag" "foo" "@pipeline_tag should be foo"
pass "create --headless --tag foo sets @pipeline_tag"

# Test 3: create --headless --cwd
sess="${PFX}_3"
$PIPELINE create "$sess" --headless --cwd /tmp >/dev/null
sleep 0.5
actual_cwd=$(tmux display-message -p -t "$sess" '#{pane_current_path}' 2>/dev/null || true)
resolved_tmp=$(cd /tmp && pwd -P)
if [[ "$actual_cwd" != "/tmp" && "$actual_cwd" != "$resolved_tmp" ]]; then
    fail "pane_current_path should be /tmp or $resolved_tmp, got '$actual_cwd'"
fi
pass "create --headless --cwd /tmp — pane_current_path is /tmp (or resolved)"

# Test 4: shutdown --dry-run
sess="${PFX}_4"
$PIPELINE create "$sess" --headless --tag "drytest" >/dev/null
output=$($PIPELINE shutdown "$sess" --dry-run)
assert_session_exists "$sess"
[[ "$output" == *"DRY-RUN"* ]] || { fail "dry-run output should contain DRY-RUN"; }
[[ "$output" == *"$sess"* ]] || { fail "dry-run output should contain session name"; }
pass "shutdown --dry-run does not kill session and prints info"

# Test 5: shutdown graceful (zsh-only pane)
sess="${PFX}_5"
$PIPELINE create "$sess" --headless >/dev/null
sleep 0.5
ec=0
$PIPELINE shutdown "$sess" --timeout 8 || ec=$?
assert_eq "$ec" "0" "graceful shutdown of zsh session should exit 0"
assert_session_gone "$sess"
pass "shutdown zsh-only pane — graceful exit code 0, session gone"

# Test 6: shutdown timeout -> force fallback (exit 2)
sess="${PFX}_6"
$PIPELINE create "$sess" --headless >/dev/null
sleep 0.3
tmux send-keys -t "$sess" "sleep 60" Enter
sleep 0.3
ec=0
$PIPELINE shutdown "$sess" --timeout 2 || ec=$?
assert_eq "$ec" "2" "force fallback exit code should be 2"
assert_session_gone "$sess"
pass "shutdown with sleep 60 + --timeout 2 triggers force fallback, exit 2"

# Test 7: shutdown --force
sess="${PFX}_7"
$PIPELINE create "$sess" --headless >/dev/null
ec=0
$PIPELINE shutdown "$sess" --force || ec=$?
assert_eq "$ec" "0" "force shutdown exit code should be 0"
assert_session_gone "$sess"
pass "shutdown --force immediate kill, exit 0"

# Test 8: shutdown non-existent -> exit 0
nonexist="${PFX}_nonexistent_$$"
ec=0
$PIPELINE shutdown "$nonexist" || ec=$?
assert_eq "$ec" "0" "shutdown on missing session should be idempotent (exit 0)"
pass "shutdown non-existent session exits 0 (idempotent)"

# Test 9: shutdown-tagged kills only tagged sessions
sess_a="${PFX}_9a"
sess_b="${PFX}_9b"
sess_c="${PFX}_9c"
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
tmux kill-session -t "$sess_c" 2>/dev/null || true
pass "shutdown-tagged kills only tagged sessions, leaves untagged intact"

# Test 12 (safety regression — placed here for early guard)
# Create 2 unrelated sessions with no pipeline tags; shut down a pipeline session;
# assert unrelated sessions survived.
unrelated_a="${PFX}_unrelated_a"
unrelated_b="${PFX}_unrelated_b"
pipeline_target="${PFX}_safety_target"

tmux new-session -d -s "$unrelated_a" "exec zsh"
tmux new-session -d -s "$unrelated_b" "exec zsh"
$PIPELINE create "$pipeline_target" --headless --tag "safety-test" >/dev/null
sleep 0.3
$PIPELINE shutdown "$pipeline_target" --timeout 5 || true

assert_session_exists "$unrelated_a"
assert_session_exists "$unrelated_b"
assert_session_gone "$pipeline_target"

tmux kill-session -t "$unrelated_a" 2>/dev/null || true
tmux kill-session -t "$unrelated_b" 2>/dev/null || true
pass "SAFETY REGRESSION: unrelated sessions unaffected by targeted shutdown"

if [[ "$fail_count" -gt 0 ]]; then
    echo "FAIL: $fail_count test(s) failed out of $test_count" >&2
    exit 1
fi

echo "PASS: $test_count tests passed"
