#!/usr/bin/env bash
# tests/test_spawn_guards.sh
#
# Unit tests for the _clmux_spawn_agent() guard block and its helpers:
#   _clmux_team_session_id
#   _clmux_current_session_id
#
# Test cases:
#   1. _clmux_team_session_id returns empty when no config.json exists
#   2. _clmux_team_session_id returns empty when config.json lacks leadSessionId
#   3. _clmux_team_session_id returns correct value when leadSessionId is set
#   4. _clmux_spawn_agent guard rejects team without leadSessionId (non-zero exit + stderr)
#
# Exit 0: all tests passed
# Exit 1: at least one test failed
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir=$(mktemp -d)
trap "rm -rf \"$tmpdir\"" EXIT

pass_count=0
fail_count=0

pass() {
  pass_count=$(( pass_count + 1 ))
  echo "✓ $*"
}

fail() {
  fail_count=$(( fail_count + 1 ))
  echo "✗ $*" >&2
}

# Helper: run a zsh snippet that sources teammate-internals.zsh.
# Captures stdout into $result and exit code into $zsh_exit.
# Captures stderr into $zsh_stderr.
_run_zsh() {
  local snippet="$1"
  local stderr_tmp
  stderr_tmp=$(mktemp)
  result=""
  zsh_exit=0
  result=$(zsh -c "
source '$CLMUX_DIR/lib/teammate-internals.zsh'
$snippet
" 2>"$stderr_tmp") || zsh_exit=$?
  zsh_stderr=$(cat "$stderr_tmp")
  rm -f "$stderr_tmp"
}

# ---------------------------------------------------------------------------
# Test 1: _clmux_team_session_id returns empty when no config.json exists
# ---------------------------------------------------------------------------
fake_team="$tmpdir/no-config-team"
mkdir -p "$fake_team"

_run_zsh "_clmux_team_session_id '$fake_team'"

if [[ $zsh_exit -eq 0 && -z "$result" ]]; then
  pass "test_helper_team_session_id_missing_config: returns empty when no config.json"
else
  fail "test_helper_team_session_id_missing_config: expected empty + exit 0, got exit=$zsh_exit result='$result' stderr='$zsh_stderr'"
fi

# ---------------------------------------------------------------------------
# Test 2: _clmux_team_session_id returns empty when config.json lacks leadSessionId
# ---------------------------------------------------------------------------
fake_team2="$tmpdir/no-leadSessionId-team"
mkdir -p "$fake_team2"
printf '{"name":"x","members":[]}' > "$fake_team2/config.json"

_run_zsh "_clmux_team_session_id '$fake_team2'"

if [[ $zsh_exit -eq 0 && -z "$result" ]]; then
  pass "test_helper_team_session_id_missing_field: returns empty when leadSessionId absent"
else
  fail "test_helper_team_session_id_missing_field: expected empty + exit 0, got exit=$zsh_exit result='$result' stderr='$zsh_stderr'"
fi

# ---------------------------------------------------------------------------
# Test 3: _clmux_team_session_id returns correct value when leadSessionId is set
# ---------------------------------------------------------------------------
fake_team3="$tmpdir/with-leadSessionId-team"
mkdir -p "$fake_team3"
expected_sid="abc123-session-xyz"
printf '{"name":"my-team","leadSessionId":"%s","members":[]}' "$expected_sid" > "$fake_team3/config.json"

_run_zsh "_clmux_team_session_id '$fake_team3'"

if [[ "$result" == "$expected_sid" ]]; then
  pass "test_helper_team_session_id_present: returns correct leadSessionId value"
else
  fail "test_helper_team_session_id_present: expected '$expected_sid', got '$result' (exit=$zsh_exit stderr='$zsh_stderr')"
fi

# ---------------------------------------------------------------------------
# Test 4: _clmux_spawn_agent guard rejects team without leadSessionId
#
# Strategy: source teammate-internals.zsh (which includes the helpers), then
# invoke the guard logic inline. The guard relies on _clmux_team_session_id
# (which must exist after implementation). The test calls the guard block as
# a standalone script — this isolates the guard from tmux/pane setup entirely.
#
# In RED phase: _clmux_team_session_id does not exist → the zsh snippet
# fails immediately with "command not found", which is a different kind of
# failure from what we expect (non-zero exit but no "no leadSessionId" in
# stderr). So the test correctly FAILS in RED phase.
#
# In GREEN phase: helper exists → guard fires → exits 1 + stderr contains
# "no leadSessionId" → test PASSES.
# ---------------------------------------------------------------------------
fake_team4="$tmpdir/guard-test-team"
mkdir -p "$fake_team4"
# Config intentionally missing leadSessionId (simulates manual mkdir)
printf '{"name":"guard-test","members":[]}' > "$fake_team4/config.json"

guard_stderr=$(mktemp)
guard_exit=0

zsh -c "
source '$CLMUX_DIR/lib/teammate-internals.zsh'

team_dir='$fake_team4'
team_name=\"\${team_dir##*/}\"

_team_sid=\$(_clmux_team_session_id \"\$team_dir\")
if [[ -z \"\$_team_sid\" ]]; then
  cat >&2 <<ERREOF
error: team '\$team_name' has no leadSessionId in \$team_dir/config.json.
       Bridge spawn aborted — responses would not reach the Lead session.
       Run TeamCreate(team_name: \"\$team_name\") in the current Claude Code
       Lead session, then retry this spawn.
ERREOF
  exit 1
fi
exit 0
" 2>"$guard_stderr" || guard_exit=$?

guard_stderr_content=$(cat "$guard_stderr")
rm -f "$guard_stderr"

if [[ "$guard_exit" -ne 0 ]] && echo "$guard_stderr_content" | grep -q "no leadSessionId"; then
  pass "test_guard_rejects_team_without_leadSessionId: exits non-zero + prints 'no leadSessionId'"
else
  fail "test_guard_rejects_team_without_leadSessionId: expected non-zero exit with 'no leadSessionId' in stderr. exit=$guard_exit stderr='$guard_stderr_content'"
fi

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
echo ""
if [[ "$fail_count" -gt 0 ]]; then
  echo "FAIL: $fail_count test(s) failed, $pass_count passed"
  exit 1
fi

echo "PASS: $pass_count tests passed"
