#!/usr/bin/env bash
# tests/test_clmux_pipeline.sh  (commit 1: create subcommand tests)
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

PFX="testpipe_$$"

# Test 1: create --headless
sess="${PFX}_1"
pane_id=$($PIPELINE create "$sess" --headless)
tmux has-session -t "$sess" 2>/dev/null || { fail "session '$sess' should exist"; }
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

if [[ "$fail_count" -gt 0 ]]; then
    echo "FAIL: $fail_count test(s) failed out of $test_count" >&2
    exit 1
fi

echo "PASS: $test_count tests passed"
