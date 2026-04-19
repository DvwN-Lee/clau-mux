# clau-mux Debug Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revision note (2026-04-15, post cross-review):** amended per 4-reviewer cross-review (plan-reviewer / gemini-reviewer / codex-worker / copilot-worker). Blocking fixes applied: Task 7 tmux socket mismatch, `team` field in `_emit`, Task 6 Step 3 `_lead_cwd` derivation, `_event_log.py` fail-safe wrapper, `sigterm_guard` description precision. See **Known Limitations** at the bottom for the items intentionally left out of scope (rotation, TeamDelete cascade cleanup).

**Goal:** 팀의 bridge 활동을 프로젝트 로컬 `<lead_cwd>/.claude/clmux/`에 구조화 로그(JSONL 이벤트) + 콘솔 로그 + 온디맨드 스냅샷으로 기록해 복잡한 bridge 버그(trust prompt, pane death timing, queue 드리프트)를 한 곳에서 분석할 수 있게 한다.

**Architecture:** bridge 각 라이프사이클 지점에서 `scripts/_event_log.py` 헬퍼를 통해 JSONL 이벤트 한 줄 append(파일 락 + SIGTERM 가드 포함). 경로는 팀 lead의 cwd를 기준으로 `<lead_cwd>/.claude/clmux/{logs,events,snapshots}`에 결정한다. `clmux-debug` 스냅샷 명령으로 team 상태·tmux 옵션·trust store·최근 로그를 한 번에 수집한다.

**Tech Stack:** Python 3 (stdlib only — json, os, signal, subprocess, datetime, fcntl), zsh 5, tmux.

**PR strategy (per copilot-worker review):** land this as **3 stacked PRs** for review velocity:

1. **Core helpers + zsh wiring + tests** — Tasks 1-2, 6, and the `test_event_log.py` unit tests. This is the foundation; event emission is wired through but no call sites yet fire events.
2. **Bridge event emissions + integration test** — Tasks 3-5 and Task 7. Every lifecycle point emits; end-to-end integration test confirms the happy + error paths.
3. **Snapshot + docs + setup** — Tasks 8-11. User-facing surface: `clmux-debug`, documentation, `.gitignore` nudge.

Tasks 12 final smoke applies to whichever PR closes the chain.

---

## File Structure

**Create:**
- `scripts/_event_log.py` — JSONL append helper with lock + sigterm_guard + fail-safe wrapper
- `scripts/clmux_debug.py` — snapshot dumper (team state + tmux + trust + recent logs)
- `tests/test_event_log.py` — pytest for `_event_log.py`
- `tests/test_clmux_debug.py` — pytest for `clmux_debug.py`
- `tests/test_bridge_events_integration.sh` — e2e shell integration test
- `docs/debugging.md` — user guide for new log structure (includes Known Limitations)

**Modify:**
- `clmux-bridge.zsh` — new `-E <events_file>` arg, `_emit` wrapper function, 10 event emissions
- `clmux.zsh` — compute `<lead_cwd>/.claude/clmux/` paths, create dirs, pass `-E` to bridge, redirect console log (both `_clmux_spawn_agent` AND `_clmux_spawn_agent_in_session`)
- `scripts/setup.sh` — optional prompt to append `.claude/clmux/` to project `.gitignore`
- `README.md` — add link to `docs/debugging.md`

**Rationale:**
- `_event_log.py` as separate helper (not inline shell): JSON escaping safety (user-supplied text with quotes/newlines)
- Python subprocess per event: measured at ~0.01s real (codex review) — overhead is negligible.
- `_event_log.py` wraps its whole body in a fail-safe `try/except Exception` that prints to stderr and exits 0 — logging failure must NEVER kill the bridge (gemini review principle: "logging should not kill the application")
- `clmux_debug.py` as separate script: composes state from many sources; keep shell wrapper thin
- Integration test as `.sh`: bridge is tightly coupled to tmux; simpler to script real tmux than mock. **Use the default tmux socket** (not an isolated `-S`) — the bridge's internal tmux calls do not take a socket override, so isolation breaks idle detection.

---

## Task 1: Event log helper with atomic append

**Files:**
- Create: `scripts/_event_log.py`
- Test: `tests/test_event_log.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_event_log.py
import json
import os
import subprocess
import tempfile
from pathlib import Path

HELPER = Path(__file__).parent.parent / "scripts" / "_event_log.py"


def _read_events(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def test_single_event_appends_one_line(tmp_path):
    events_file = tmp_path / "events.jsonl"
    subprocess.check_call([
        "python3", str(HELPER),
        str(events_file),
        "spawn_start",
        "agent=codex-worker",
        "team=demo",
        "pane=%42",
    ])
    events = _read_events(events_file)
    assert len(events) == 1
    assert events[0]["event"] == "spawn_start"
    assert events[0]["agent"] == "codex-worker"
    assert events[0]["team"] == "demo"
    assert events[0]["pane"] == "%42"
    assert "ts" in events[0]


def test_appends_preserve_existing(tmp_path):
    events_file = tmp_path / "events.jsonl"
    events_file.write_text('{"ts":"prev","event":"old"}\n')
    subprocess.check_call([
        "python3", str(HELPER),
        str(events_file),
        "shutdown",
        "reason=test",
    ])
    events = _read_events(events_file)
    assert len(events) == 2
    assert events[0]["event"] == "old"
    assert events[1]["event"] == "shutdown"
    assert events[1]["reason"] == "test"


def test_ten_concurrent_writers_no_loss(tmp_path):
    events_file = tmp_path / "events.jsonl"
    procs = [
        subprocess.Popen([
            "python3", str(HELPER),
            str(events_file),
            "msg",
            f"i={i}",
        ])
        for i in range(10)
    ]
    for p in procs:
        p.wait()
    events = _read_events(events_file)
    assert len(events) == 10
    seen = {int(e["i"]) for e in events}
    assert seen == set(range(10))


def test_text_with_special_chars_preserved(tmp_path):
    events_file = tmp_path / "events.jsonl"
    tricky = 'line with "quote", newline-literal-\\n, and tab-literal-\\t'
    subprocess.check_call([
        "python3", str(HELPER),
        str(events_file),
        "paste_start",
        f"preview={tricky}",
    ])
    events = _read_events(events_file)
    assert events[0]["preview"] == tricky


def test_missing_args_exits_nonzero(tmp_path):
    r = subprocess.run(["python3", str(HELPER)], capture_output=True)
    assert r.returncode != 0


def test_failsafe_never_crashes_caller(tmp_path):
    """Permission-denied events file must NOT propagate an exception.
    The fail-safe wrapper prints to stderr and exits 0 instead.
    """
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)  # cannot create files in here
    events_file = readonly / "events.jsonl"
    try:
        r = subprocess.run(
            ["python3", str(HELPER), str(events_file), "spawn_start", "agent=a"],
            capture_output=True, text=True,
        )
        assert r.returncode == 0, f"fail-safe violated: rc={r.returncode} stderr={r.stderr}"
        assert "dropped event" in r.stderr
    finally:
        readonly.chmod(0o700)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_event_log.py -v`
Expected: all 5 tests FAIL with "No such file or directory: scripts/_event_log.py" or similar.

- [ ] **Step 3: Implement `_event_log.py`**

```python
"""Append a single event to a JSONL file, atomically and safely.

Called by clmux-bridge.zsh at each lifecycle point (spawn, paste,
defer, shutdown, cleanup) to record a structured trace of the
bridge's activity. Later, debugging tools (jq, clmux_debug.py)
read the resulting <project>/.claude/clmux/events/<team>.jsonl.

Usage:
  python3 _event_log.py <events_file> <event_name> [key=val ...]

Each call:
  1. Acquires a cross-process lock on events_file (file_lock mkdir mutex)
  2. Enters a SIGTERM-guarded critical section (see note below)
  3. Writes exactly one JSON line ending in \\n
  4. Releases lock

Fields:
  ts     — ISO-8601 UTC (millisecond precision)
  event  — event name (first positional after path)
  ...    — any key=value pairs; value parsed as string

SIGTERM behavior: `_filelock.sigterm_guard()` IGNORES SIGTERM for the
duration of the critical section and restores the previous handler on
exit. It does NOT defer/redeliver the signal — TERM arriving inside
the guard is dropped entirely. Adequate for our single-write atomic
append; don't rely on post-handler redelivery.

Fail-safe principle: the whole operation is wrapped in a top-level
`try/except Exception` that prints a stderr note and exits 0. Logging
failure must NEVER propagate into the caller's process — a broken
events file cannot be allowed to kill the bridge.
"""
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _filelock import file_lock, sigterm_guard


def _now_ts():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime('%Y-%m-%dT%H:%M:%S.') + f'{now.microsecond // 1000:03d}Z'


def _do_append():
    if len(sys.argv) < 3:
        print("usage: _event_log.py <events_file> <event_name> [key=val ...]",
              file=sys.stderr)
        sys.exit(2)

    events_file = sys.argv[1]
    event_name = sys.argv[2]

    record = {"ts": _now_ts(), "event": event_name}
    for kv in sys.argv[3:]:
        if "=" not in kv:
            continue
        k, _, v = kv.partition("=")
        record[k] = v

    line = json.dumps(record, ensure_ascii=False) + "\n"

    os.makedirs(os.path.dirname(os.path.abspath(events_file)), exist_ok=True)

    with file_lock(events_file):
        with sigterm_guard():
            with open(events_file, "a", encoding="utf-8") as f:
                f.write(line)


def main():
    # Fail-safe: any exception in the logging path prints a warning and
    # exits 0 so the calling bridge cannot be killed by a broken log.
    # Usage/arg errors (sys.exit(2) in _do_append) propagate normally
    # because they indicate programmer error, not runtime pathology.
    try:
        _do_append()
    except SystemExit:
        raise
    except Exception as e:
        print(f"_event_log: dropped event ({type(e).__name__}: {e})",
              file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_event_log.py -v`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/_event_log.py tests/test_event_log.py
git commit -m "feat: add _event_log.py JSONL append helper with lock"
```

---

## Task 2: Bridge CLI args + emit wrapper

**Files:**
- Modify: `clmux-bridge.zsh:22-35` (getopts) and nearby (add helper fn)

- [ ] **Step 1: Add `-E` and `-C` args, wire `_emit` helper**

Locate the getopts section in `clmux-bridge.zsh`. Before the edit it reads:

```zsh
PANE_ID="" INBOX="" TIMEOUT=60 IDLE_PATTERN="Type your message"

while getopts "p:i:t:w:" opt; do
  case $opt in
    p) PANE_ID="$OPTARG" ;;
    i) INBOX="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    w) IDLE_PATTERN="$OPTARG" ;;
    *) echo "Usage: $0 -p <pane_id> -i <inbox> [-t <timeout>] [-w <idle_pattern>]" >&2; exit 1 ;;
  esac
done
```

Replace with:

```zsh
PANE_ID="" INBOX="" TIMEOUT=60 IDLE_PATTERN="Type your message" EVENTS_FILE=""

while getopts "p:i:t:w:E:" opt; do
  case $opt in
    p) PANE_ID="$OPTARG" ;;
    i) INBOX="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    w) IDLE_PATTERN="$OPTARG" ;;
    E) EVENTS_FILE="$OPTARG" ;;
    *) echo "Usage: $0 -p <pane_id> -i <inbox> [-t <timeout>] [-w <idle_pattern>] [-E <events_file>]" >&2; exit 1 ;;
  esac
done
```

- [ ] **Step 2: Define `_emit` helper just below `mark_read()`**

Find the block near line 55-61:

```zsh
mark_read() {
  python3 "$CLMUX_DIR/scripts/mark_read.py" "$INBOX" "$1"
}
```

Append immediately after:

```zsh

# Append a single event to the team's structured event log. No-op when
# -E wasn't passed (backward compatible with legacy spawn paths).
#
# The `team` field is derived from the events file basename
# (`<team>.jsonl` → `<team>`) using zsh's `:t:r` modifier (tail + root).
# This matches the schema documented in docs/debugging.md so every event
# carries {ts, event, agent, team, pane, ...}. Stderr is kept visible —
# _event_log.py's fail-safe wrapper already ensures the call cannot
# propagate an error, and any warning it emits belongs in the bridge log.
#
# Usage: _emit <event_name> key=val key=val ...
_emit() {
  [[ -z "$EVENTS_FILE" ]] && return 0
  local _team="${EVENTS_FILE:t:r}"
  python3 "$CLMUX_DIR/scripts/_event_log.py" "$EVENTS_FILE" "$@" \
    "agent=$AGENT_NAME" "team=$_team" "pane=$PANE_ID"
}
```

- [ ] **Step 3: Run a smoke test**

```bash
tmpdir=$(mktemp -d)
EVENTS="$tmpdir/e.jsonl"
# Source bridge in function-definition mode only (don't run main loop)
zsh -n /Users/idongju/Desktop/Git/clau-mux/clmux-bridge.zsh && echo "syntax OK"
# Direct helper call to prove _event_log still works
python3 /Users/idongju/Desktop/Git/clau-mux/scripts/_event_log.py "$EVENTS" test_event k=v
cat "$EVENTS"
rm -rf "$tmpdir"
```

Expected: one JSON line like `{"ts":"...","event":"test_event","k":"v"}`.

- [ ] **Step 4: Commit**

```bash
git add clmux-bridge.zsh
git commit -m "feat: add -E events_file arg + _emit helper to bridge"
```

---

## Task 3: Emit spawn lifecycle events

**Files:**
- Modify: `clmux-bridge.zsh` — spawn flow near line 84 (`wait_for_idle`)

- [ ] **Step 1: Emit `spawn_start` before `wait_for_idle`**

Find the line that reads:

```zsh
echo "[clmux-bridge] started — pane:$PANE_ID  agent:$AGENT_NAME  idle:\"$IDLE_PATTERN\""
```

Immediately after it, add:

```zsh
_emit spawn_start "idle_pattern=$IDLE_PATTERN" "timeout=$TIMEOUT"
```

- [ ] **Step 2: Emit `spawn_ready` vs `spawn_failed` around wait_for_idle**

Find the block:

```zsh
wait_for_idle || { echo "[clmux-bridge] error: CLI not ready (pattern: $IDLE_PATTERN)" >&2; exit 1; }
echo "[clmux-bridge] ready — polling inbox every 2s (Ctrl+C to stop)"
```

Replace with:

```zsh
if ! wait_for_idle; then
  echo "[clmux-bridge] error: CLI not ready (pattern: $IDLE_PATTERN)" >&2
  _emit spawn_failed "reason=idle_timeout"
  exit 1
fi
# Capture the last-matching line to aid B5 (false-positive) analysis
_matched_line=$(tmux capture-pane -t "$PANE_ID" -p | grep -v '^\s*$' | tail -8 | grep -E "$IDLE_PATTERN" | tail -1)
_emit spawn_ready "matched_line=${_matched_line:0:80}"
echo "[clmux-bridge] ready — polling inbox every 2s (Ctrl+C to stop)"
```

- [ ] **Step 3: Manual verification**

In a scratch tmux session, spawn a short-lived pane and run the bridge against it with `-E`:

```bash
tmpdir=$(mktemp -d)
EVENTS="$tmpdir/events.jsonl"
# Start a dummy pane that emits the gemini idle line once then sleeps
tmux new-window -d -n emit-test "printf '> Type your message or @path\\n'; sleep 300"
sleep 1
pane=$(tmux list-windows -a -F '#{window_name} #{pane_id}' | awk '$1=="emit-test"{print $2}')
# Run bridge in foreground briefly to trigger spawn_start + spawn_ready
timeout 5 zsh /Users/idongju/Desktop/Git/clau-mux/clmux-bridge.zsh \
  -p "$pane" \
  -i "$tmpdir/inbox.json" \
  -t 5 \
  -w "Type your message" \
  -E "$EVENTS" 2>/dev/null || true
cat "$EVENTS"
tmux kill-pane -t "$pane"
rm -rf "$tmpdir"
```

Expected output contains two JSON lines: one `"event":"spawn_start"` and one `"event":"spawn_ready"` with `matched_line` containing "Type your message".

- [ ] **Step 4: Commit**

```bash
git add clmux-bridge.zsh
git commit -m "feat: emit spawn_start/ready/failed events"
```

---

## Task 4: Emit message-flow events

**Files:**
- Modify: `clmux-bridge.zsh` — main loop around message read, paste, Enter

- [ ] **Step 1: Emit `message_received`**

Find the block starting with `if [[ -n "$msg" ]]; then` and the immediately following parse+log lines:

```zsh
    if (( ${#text} > 120 )); then
      echo "[clmux-bridge] → from '$from' (${#text} chars): ${text:0:120}…"
    else
      echo "[clmux-bridge] → from '$from': $text"
    fi
```

After the `fi` closing the if/else, add:

```zsh
    _emit message_received "from=$from" "text_len=${#text}" "msg_ts=$ts"
```

- [ ] **Step 2: Emit `paste_start` at start of delivery**

Find the comment block starting with `# Delivery: chunked paste-buffer for large msgs` and the line `_text_len=${#text}`. Immediately after `_text_len=${#text}` add:

```zsh
    _emit paste_start "text_len=$_text_len" "chunked=$(( _text_len > 300 ))"
```

- [ ] **Step 3: Emit `paste_chunk_failed` on chunk errors**

Find both `_chunk_fail=true; break` lines within the chunked-paste block. Insert a `_emit` call immediately before the `_chunk_fail=true` assignment, covering both load-buffer and paste-buffer branches. The two places before change look like:

```zsh
        if ! printf '%s' "${text:$_pos:$_csz}" | tmux load-buffer -b "$_buf" - 2>/dev/null; then
          echo "[clmux-bridge] error: chunk load-buffer failed (pane:$PANE_ID)" >&2
          _chunk_fail=true; break
        fi
        if ! tmux paste-buffer -d -b "$_buf" -t "$PANE_ID" 2>/dev/null; then
          echo "[clmux-bridge] error: chunk paste-buffer failed (pane:$PANE_ID)" >&2
          tmux delete-buffer -b "$_buf" 2>/dev/null
          _chunk_fail=true; break
        fi
```

After change:

```zsh
        if ! printf '%s' "${text:$_pos:$_csz}" | tmux load-buffer -b "$_buf" - 2>/dev/null; then
          echo "[clmux-bridge] error: chunk load-buffer failed (pane:$PANE_ID)" >&2
          _emit paste_chunk_failed "chunk_idx=$_ci" "phase=load_buffer"
          _chunk_fail=true; break
        fi
        if ! tmux paste-buffer -d -b "$_buf" -t "$PANE_ID" 2>/dev/null; then
          echo "[clmux-bridge] error: chunk paste-buffer failed (pane:$PANE_ID)" >&2
          tmux delete-buffer -b "$_buf" 2>/dev/null
          _emit paste_chunk_failed "chunk_idx=$_ci" "phase=paste_buffer"
          _chunk_fail=true; break
        fi
```

- [ ] **Step 4: Emit same for single-paste branch**

Find the single-paste branch (the `else` sibling of the chunked branch, around `_buf="clmux-${$}-${RANDOM}"`). Locate the `_single_fail=true` lines and mirror the instrumentation:

```zsh
      if ! printf '%s' "$text" | tmux load-buffer -b "$_buf" - 2>/dev/null; then
        echo "[clmux-bridge] error: load-buffer failed (pane:$PANE_ID)" >&2
        _emit paste_chunk_failed "chunk_idx=0" "phase=load_buffer"
        _single_fail=true
      elif ! tmux paste-buffer -d -b "$_buf" -t "$PANE_ID" 2>/dev/null; then
        echo "[clmux-bridge] error: paste-buffer failed (pane:$PANE_ID)" >&2
        tmux delete-buffer -b "$_buf" 2>/dev/null
        _emit paste_chunk_failed "chunk_idx=0" "phase=paste_buffer"
        _single_fail=true
      fi
```

- [ ] **Step 5: Emit `enter_not_accepted` after the 5-retry loop**

Find:

```zsh
    [[ "$_enter_ok" == false ]] && echo "[clmux-bridge] error: Enter not accepted after 5 retries" >&2
```

Replace with:

```zsh
    if [[ "$_enter_ok" == false ]]; then
      echo "[clmux-bridge] error: Enter not accepted after 5 retries" >&2
      _emit enter_not_accepted
    fi
```

- [ ] **Step 6: Commit**

```bash
git add clmux-bridge.zsh
git commit -m "feat: emit message_received/paste_start/paste_chunk_failed/enter_not_accepted"
```

---

## Task 5: Emit defer / shutdown / cleanup events

**Files:**
- Modify: `clmux-bridge.zsh` — defer block, shutdown_request handler, pane-gone handler, cleanup()

- [ ] **Step 1: Emit `defer_triggered` in the wait_for_idle defer block**

Find the block:

```zsh
    if ! wait_for_idle; then
      (( _defer_count++ ))
      if (( _defer_count >= 6 )); then
        # Per queue-lifecycle invariant: persistent unresponsiveness ends
        # the agent session. Killing the pane triggers cleanup() which
        # purges the inbox so messages don't linger as data loss.
        echo "[clmux-bridge] error: idle timeout after ${_defer_count} retries, killing pane (queue will be purged)" >&2
        tmux kill-pane -t "$PANE_ID" 2>/dev/null
        exit 0
      fi
      echo "[clmux-bridge] warning: not idle, deferring send (${_defer_count}/6)" >&2
      sleep 5
      continue
    fi
    _defer_count=0
```

Replace with (three `_emit` calls added):

```zsh
    if ! wait_for_idle; then
      (( _defer_count++ ))
      if (( _defer_count >= 6 )); then
        echo "[clmux-bridge] error: idle timeout after ${_defer_count} retries, killing pane (queue will be purged)" >&2
        _emit defer_triggered "count=$_defer_count" "max=6" "action=kill_pane"
        _emit shutdown "reason=defer_exhausted"
        tmux kill-pane -t "$PANE_ID" 2>/dev/null
        exit 0
      fi
      _emit defer_triggered "count=$_defer_count" "max=6" "action=retry"
      echo "[clmux-bridge] warning: not idle, deferring send (${_defer_count}/6)" >&2
      sleep 5
      continue
    fi
    _defer_count=0
```

- [ ] **Step 2: Emit `shutdown` in shutdown_request handler**

Find the shutdown_request handler:

```zsh
    if [[ "$msg_type" == "shutdown_request" ]]; then
      echo "[clmux-bridge] shutdown_request received — terminating $AGENT_NAME" >&2
```

Immediately after the echo, add:

```zsh
      _emit shutdown "reason=shutdown_request"
```

- [ ] **Step 3: Emit `shutdown` in pane-gone handler**

Find:

```zsh
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$PANE_ID" || {
    echo "[clmux-bridge] pane $PANE_ID is gone, notifying lead..." >&2
    python3 "$CLMUX_DIR/scripts/notify_shutdown.py" "$INBOX" "$AGENT_NAME"
    exit 0
  }
```

Replace with:

```zsh
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$PANE_ID" || {
    echo "[clmux-bridge] pane $PANE_ID is gone, notifying lead..." >&2
    _emit shutdown "reason=pane_gone"
    python3 "$CLMUX_DIR/scripts/notify_shutdown.py" "$INBOX" "$AGENT_NAME"
    exit 0
  }
```

- [ ] **Step 4: Emit `shutdown` in paste-failure kill path**

Find both `paste_fail_count >= 3` branches (chunked + single). Before each `tmux kill-pane` + `exit 0`, add a shutdown event:

```zsh
        if (( _paste_fail_count >= 3 )); then
          echo "[clmux-bridge] error: paste-buffer failed ${_paste_fail_count} times, killing pane (queue will be purged)" >&2
          _emit shutdown "reason=paste_exhausted"
          tmux kill-pane -t "$PANE_ID" 2>/dev/null
          exit 0
        fi
```

Apply the same change in both occurrences.

- [ ] **Step 5: Emit `cleanup` from cleanup()**

Find the `cleanup()` function:

```zsh
cleanup() {
  rm -f "$TEAM_DIR/.bridge-${AGENT_NAME}.env"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-bridge.pid"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-pane"
  python3 "$CLMUX_DIR/scripts/deactivate_pane.py" "$TEAM_DIR" "$AGENT_NAME" 2>/dev/null
  # Invariant: queue lifecycle = agent session lifecycle. On any exit,
  # discard remaining messages so the next spawn starts from a clean queue.
  python3 "$CLMUX_DIR/scripts/purge_inbox.py" "$INBOX" 2>/dev/null
  echo "[clmux-bridge] shutting down"
}
```

Add a final line before the closing brace:

```zsh
cleanup() {
  rm -f "$TEAM_DIR/.bridge-${AGENT_NAME}.env"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-bridge.pid"
  rm -f "$TEAM_DIR/.${AGENT_NAME}-pane"
  python3 "$CLMUX_DIR/scripts/deactivate_pane.py" "$TEAM_DIR" "$AGENT_NAME" 2>/dev/null
  python3 "$CLMUX_DIR/scripts/purge_inbox.py" "$INBOX" 2>/dev/null
  _emit cleanup "deactivated=1" "inbox_purged=1"
  echo "[clmux-bridge] shutting down"
}
```

- [ ] **Step 6: Commit**

```bash
git add clmux-bridge.zsh
git commit -m "feat: emit defer/shutdown/cleanup events"
```

---

## Task 6: Wire paths in spawn (clmux.zsh)

**Files:**
- Modify: `clmux.zsh` — both `_clmux_spawn_agent` and `_clmux_spawn_agent_in_session`

- [ ] **Step 1: Compute project-local paths just after `_lead_cwd` is set**

Find the existing block in `_clmux_spawn_agent`:

```zsh
  local _lead_cwd
  _lead_cwd=$(tmux display-message -t "$lead_pane" -p '#{pane_current_path}' 2>/dev/null)
```

Append below:

```zsh
  # Project-local log + events directory (<lead_cwd>/.claude/clmux/).
  # Falls back to /tmp when lead_cwd is unavailable or not writable so a
  # misconfigured team still logs *somewhere*.
  local _log_dir="/tmp" _events_dir="/tmp"
  if [[ -n "$_lead_cwd" && -w "$_lead_cwd" ]]; then
    _log_dir="$_lead_cwd/.claude/clmux/logs"
    _events_dir="$_lead_cwd/.claude/clmux/events"
    mkdir -p "$_log_dir" "$_events_dir" 2>/dev/null
  fi
  local _events_file="$_events_dir/${team_dir##*/}.jsonl"
  local _log_file="$_log_dir/bridge-${team_dir##*/}-${agent_name}.log"
```

- [ ] **Step 2: Pass `-E` and redirect to the new log path**

Find the current bridge launch:

```zsh
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$agent_pane" -i "$inbox" -t "$timeout" -w "$idle_pattern" \
    >> "/tmp/clmux-bridge-${team_name_val}-${agent_name}.log" 2>&1 &
```

Replace with:

```zsh
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$agent_pane" -i "$inbox" -t "$timeout" -w "$idle_pattern" \
    -E "$_events_file" \
    >> "$_log_file" 2>&1 &
```

- [ ] **Step 3: Mirror the change in `_clmux_spawn_agent_in_session`**

Repeat Steps 1 and 2 in the `_clmux_spawn_agent_in_session` function (same file, different function). Keep naming parallel: `_log_dir`, `_events_dir`, `_events_file`, `_log_file`.

**Important:** `_clmux_spawn_agent_in_session` does NOT inherit `TMUX_PANE` from the caller (it runs against a named tmux session, not the user's current one). You must derive `_lead_cwd` explicitly from the session's lead pane. Right after the function's existing line that computes `lead_pane` via `tmux list-panes -t "=$session_name" ...`, add:

```zsh
  local _lead_cwd
  _lead_cwd=$(tmux display-message -t "$lead_pane" -p '#{pane_current_path}' 2>/dev/null)

  local _log_dir="/tmp" _events_dir="/tmp"
  if [[ -n "$_lead_cwd" && -w "$_lead_cwd" ]]; then
    _log_dir="$_lead_cwd/.claude/clmux/logs"
    _events_dir="$_lead_cwd/.claude/clmux/events"
    mkdir -p "$_log_dir" "$_events_dir" 2>/dev/null
  fi
  local _events_file="$_events_dir/${team_dir##*/}.jsonl"
  local _log_file="$_log_dir/bridge-${team_dir##*/}-${agent_name}.log"
```

Then update this function's bridge launch command exactly as in Step 2 (add `-E "$_events_file"` and redirect to `$_log_file`).

Without the explicit `_lead_cwd` line here, `$_lead_cwd` would be unset, the writable-dir guard would fail, and events+logs would silently fall through to `/tmp` — reviewers would never see the new files under their project root.

- [ ] **Step 4: Integration sanity run**

Create a disposable team inside an empty project, spawn one gemini, send a message, then inspect the new paths.

```bash
proj=$(mktemp -d)
# Simulate a Claude Code project by just creating the dir; team-lead cwd inherits
cd "$proj"
# Manual equivalent of TeamCreate (since we're outside a Claude Code session)
team="clmux-log-smoke"
mkdir -p "$HOME/.claude/teams/$team/inboxes"
printf '{"name":"%s","leadSessionId":"test","members":[]}' "$team" \
  > "$HOME/.claude/teams/$team/config.json"
# Within a tmux session:
zsh -ic "clmux-gemini -t $team -x 120"
# Expected files shortly after spawn:
ls "$proj/.claude/clmux/logs/"
ls "$proj/.claude/clmux/events/"
# Teardown
zsh -ic "clmux-gemini-stop -t $team"
rm -rf "$HOME/.claude/teams/$team"
cd - && rm -rf "$proj"
```

Expected: `bridge-clmux-log-smoke-gemini-worker.log` exists under `logs/` and `clmux-log-smoke.jsonl` exists under `events/` with at least `spawn_start` and `spawn_ready` lines.

- [ ] **Step 5: Commit**

```bash
git add clmux.zsh
git commit -m "feat: route bridge logs + events to <lead_cwd>/.claude/clmux/"
```

---

## Task 7: End-to-end integration test

**Files:**
- Create: `tests/test_bridge_events_integration.sh`

- [ ] **Step 1: Write the integration test script**

```bash
#!/usr/bin/env bash
# tests/test_bridge_events_integration.sh
#
# End-to-end: spawn the bridge against a throwaway tmux window on the
# CALLER'S tmux server (the default socket), drive it through happy +
# error paths, then assert that the emitted events contain the expected
# sequences.
#
# NOTE (cross-review revision): an earlier draft used `tmux -S <sock>`
# to isolate the test on a private socket. That broke because
# clmux-bridge.zsh makes internal tmux calls (capture-pane, list-panes,
# send-keys) with no socket override, so the bridge would talk to the
# default server while the test pane lived on the private one. The
# bridge never saw any pane content and spawn_ready never fired.
# Fix: use the user's default tmux server with a dedicated window that
# the EXIT trap tears down so we don't disturb existing windows.
set -euo pipefail

[[ -z "${TMUX:-}" ]] && {
  echo "SKIP: tests/test_bridge_events_integration.sh requires an attached tmux session"
  exit 0
}

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir=$(mktemp -d)
win_name="clmux-it-$$"

cleanup() {
  # Kill the bridge subprocess and the disposable tmux window.
  [[ -n "${bg_pid:-}" ]] && kill "$bg_pid" 2>/dev/null || true
  tmux kill-window -t "$win_name" 2>/dev/null || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

events_file="$tmpdir/events.jsonl"
inbox="$tmpdir/inbox.json"
log_file="$tmpdir/bridge.log"
printf '[]' > "$inbox"

# Create a disposable tmux window on the DEFAULT server and pin a
# gemini-lookalike idle banner in it.
tmux new-window -d -n "$win_name" \
  'printf "> Type your message or @path/to/file\n"; exec sleep 600'
pane=$(tmux list-panes -t "$win_name" -F '#{pane_id}')

# ── Case A: happy path (spawn → ready → message → paste → pane_gone → cleanup)
(
  export CLMUX_DIR
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$pane" -i "$inbox" -t 10 -w "Type your message" \
    -E "$events_file" \
    2>&1 | tee "$log_file"
) &
bg_pid=$!

# Wait for spawn_ready (15s budget; bridge polls idle every 1s)
for _ in $(seq 1 30); do
  grep -q '"event":"spawn_ready"' "$events_file" 2>/dev/null && break
  sleep 0.5
done

grep -q '"event":"spawn_start"' "$events_file"        || { echo "FAIL: no spawn_start"; exit 1; }
grep -q '"event":"spawn_ready"' "$events_file"        || { echo "FAIL: no spawn_ready"; exit 1; }
grep -q '"team":' "$events_file"                      || { echo "FAIL: no team field"; exit 1; }

# Inject a message
ts=$(python3 -c "import datetime; d=datetime.datetime.now(datetime.timezone.utc); print(d.strftime('%Y-%m-%dT%H:%M:%S.')+f'{d.microsecond//1000:03d}Z')")
python3 - <<PY
import json
msgs = [{"from":"team-lead","text":"hello world","timestamp":"$ts","read":False}]
open("$inbox","w").write(json.dumps(msgs))
PY

for _ in $(seq 1 30); do
  grep -q '"event":"message_received"' "$events_file" 2>/dev/null && break
  sleep 0.5
done

grep -q '"event":"message_received"' "$events_file" || { echo "FAIL: no message_received"; exit 1; }
grep -q '"event":"paste_start"' "$events_file"     || { echo "FAIL: no paste_start"; exit 1; }

# Kill the pane to trigger pane_gone
tmux kill-pane -t "$pane" 2>/dev/null || true

for _ in $(seq 1 20); do
  grep -q '"event":"shutdown"' "$events_file" 2>/dev/null && break
  sleep 0.5
done

grep -q '"reason":"pane_gone"' "$events_file" || { echo "FAIL: no shutdown reason=pane_gone"; exit 1; }
grep -q '"event":"cleanup"' "$events_file"    || { echo "FAIL: no cleanup"; exit 1; }

wait "$bg_pid" 2>/dev/null || true
bg_pid=""

# ── Case B: spawn_failed path (initial wait_for_idle timeout)
events_b="$tmpdir/events_b.jsonl"
inbox_b="$tmpdir/inbox_b.json"
printf '[]' > "$inbox_b"

# Create a window that NEVER matches the idle pattern
tmux new-window -d -n "${win_name}-b" 'printf "no-match-line\n"; exec sleep 600'
pane_b=$(tmux list-panes -t "${win_name}-b" -F '#{pane_id}')

(
  export CLMUX_DIR
  # 3s timeout — bridge must give up and emit spawn_failed
  zsh "$CLMUX_DIR/clmux-bridge.zsh" \
    -p "$pane_b" -i "$inbox_b" -t 3 -w "Type your message" \
    -E "$events_b" 2>/dev/null || true
) &
wait "$!" 2>/dev/null || true

tmux kill-window -t "${win_name}-b" 2>/dev/null || true

grep -q '"event":"spawn_failed"' "$events_b" || { echo "FAIL: no spawn_failed"; exit 1; }

# ── Final shape check: every emitted line is valid JSON
python3 - <<PY
import json, sys
bad = 0
for path in ["$events_file", "$events_b"]:
    for i, line in enumerate(open(path)):
        try:
            json.loads(line)
        except Exception as e:
            print(f"{path} line {i}: {e}", file=sys.stderr); bad += 1
sys.exit(1 if bad else 0)
PY

echo "PASS: happy path (spawn/ready/message/paste/pane_gone/cleanup) + spawn_failed + well-formed JSON"
```

Make it executable:

```bash
chmod +x tests/test_bridge_events_integration.sh
```

**Coverage note:** this covers 7 of the 10 events — `spawn_start`, `spawn_ready`, `spawn_failed`, `message_received`, `paste_start`, `shutdown` (with `reason=pane_gone`), `cleanup`. The remaining three (`paste_chunk_failed`, `enter_not_accepted`, `defer_triggered`) exercise tmux internals that are hard to deterministically induce from a shell test and are validated by manual inspection during Task 12's smoke test.

- [ ] **Step 2: Run the integration test**

Run: `bash tests/test_bridge_events_integration.sh`
Expected: final line `PASS: all expected events present and well-formed` and exit code 0.

- [ ] **Step 3: Commit**

```bash
git add tests/test_bridge_events_integration.sh
git commit -m "test: add bridge events e2e integration test"
```

---

## Task 8: Snapshot dumper (`clmux_debug.py`)

**Files:**
- Create: `scripts/clmux_debug.py`
- Test: `tests/test_clmux_debug.py`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_clmux_debug.py
import json
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "scripts" / "clmux_debug.py"


def test_missing_team_arg_exits_nonzero():
    r = subprocess.run(["python3", str(SCRIPT)], capture_output=True)
    assert r.returncode != 0


def test_unknown_team_reports_gracefully(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    r = subprocess.run(
        ["python3", str(SCRIPT), "-t", "does-not-exist"],
        capture_output=True, text=True,
    )
    assert r.returncode == 1
    assert "not found" in (r.stdout + r.stderr).lower()


def test_prints_sections_for_existing_team(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    team_dir = tmp_path / ".claude" / "teams" / "demo"
    (team_dir / "inboxes").mkdir(parents=True)
    (team_dir / "config.json").write_text(json.dumps({
        "name": "demo",
        "leadSessionId": "s1",
        "members": [
            {"name": "team-lead", "agentType": "team-lead", "cwd": str(tmp_path)},
            {"name": "codex-worker", "agentType": "bridge", "isActive": True, "tmuxPaneId": "%42"},
        ],
    }))
    (team_dir / "inboxes" / "codex-worker.json").write_text("[]")
    (team_dir / "inboxes" / "team-lead.json").write_text("[]")

    r = subprocess.run(
        ["python3", str(SCRIPT), "-t", "demo"],
        capture_output=True, text=True,
    )
    assert r.returncode == 0, r.stderr
    out = r.stdout
    # At least one line per section header
    assert "# team config" in out.lower() or "team config" in out.lower()
    assert "codex-worker" in out
    assert "%42" in out
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_clmux_debug.py -v`
Expected: 3 tests FAIL with "No such file" or "returncode != 0".

- [ ] **Step 3: Implement `clmux_debug.py`**

```python
"""Dump a consolidated debugging snapshot for one clmux team.

Collects the five sources that historically required manual correlation:
  1. config.json (members + isActive + panes)
  2. live tmux panes with @clmux-* options
  3. inbox + team-lead outbox sizes
  4. trust store entries for the lead's cwd in each CLI's config
  5. tail of the bridge log + last N events from events.jsonl

Usage:
  python3 clmux_debug.py -t <team> [-o <output_file>]

If -o is omitted, the report is printed to stdout and ALSO written
to <lead_cwd>/.claude/clmux/snapshots/<team>-<ts>.txt when that path
is discoverable. Writing the file is best-effort and never fatal.
"""
import argparse
import datetime
import glob
import json
import os
import subprocess
import sys


def _ts():
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime('%Y%m%dT%H%M%SZ')


def _read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return default


def _run(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL, timeout=3)
    except Exception:
        return ""


def _team_path(team):
    return os.path.expanduser(f"~/.claude/teams/{team}")


def _tmux_bridge_panes(team):
    fmt = '#{pane_id}|#{@clmux-agent}|#{@clmux-team}|#{@clmux-bridge}|#{pane_current_path}'
    out = _run(['tmux', 'list-panes', '-a', '-F', fmt])
    rows = []
    for line in out.strip().split('\n'):
        if not line:
            continue
        parts = line.split('|', 4)
        if len(parts) != 5:
            continue
        pane_id, agent, t, is_bridge, cwd = parts
        if is_bridge != '1' or t != team:
            continue
        rows.append({"pane": pane_id, "agent": agent, "cwd": cwd})
    return rows


def _lead_cwd(cfg):
    for m in cfg.get("members", []):
        if m.get("agentType") == "team-lead" or m.get("name") == "team-lead":
            cwd = m.get("cwd")
            if cwd and os.path.isdir(cwd):
                return cwd
    return None


def _trust_status(path):
    if not path:
        return {}
    result = {}
    # codex
    codex = os.path.expanduser("~/.codex/config.toml")
    if os.path.isfile(codex):
        with open(codex) as f:
            result["codex"] = f'[projects."{path}"]' in f.read()
    else:
        result["codex"] = None
    # gemini
    gemini = _read_json(os.path.expanduser("~/.gemini/trustedFolders.json"), {})
    result["gemini"] = gemini.get(path) == "TRUST_FOLDER"
    # copilot
    copilot = _read_json(os.path.expanduser("~/.copilot/config.json"), {})
    folders = copilot.get("trusted_folders") if isinstance(copilot, dict) else None
    result["copilot"] = isinstance(folders, list) and path in folders
    return result


def _tail(path, n=30):
    try:
        with open(path) as f:
            lines = f.readlines()
        return "".join(lines[-n:])
    except FileNotFoundError:
        return "(log not found)\n"
    except Exception as e:
        return f"(error reading log: {e})\n"


def _inbox_summary(inbox_dir):
    rows = []
    if not os.path.isdir(inbox_dir):
        return rows
    for name in sorted(os.listdir(inbox_dir)):
        if not name.endswith(".json"):
            continue
        p = os.path.join(inbox_dir, name)
        msgs = _read_json(p, [])
        if not isinstance(msgs, list):
            msgs = []
        unread = sum(1 for m in msgs if not m.get("read"))
        rows.append((name, len(msgs), unread))
    return rows


def _build_report(team):
    lines = []
    lines.append(f"# clmux-debug snapshot — team={team} at {_ts()}")
    lines.append("")

    team_dir = _team_path(team)
    cfg = _read_json(os.path.join(team_dir, "config.json"))
    if cfg is None:
        lines.append(f"ERROR: team not found at {team_dir}")
        return "\n".join(lines), 1

    lead_cwd = _lead_cwd(cfg)
    lines.append(f"## team config")
    lines.append(f"leadSessionId={cfg.get('leadSessionId')}")
    lines.append(f"leadCwd={lead_cwd}")
    lines.append(f"members:")
    for m in cfg.get("members", []):
        lines.append(
            f"  - {m.get('name','?'):20} "
            f"type={m.get('agentType','?'):18} "
            f"isActive={m.get('isActive','N/A')} "
            f"pane={m.get('tmuxPaneId','')}"
        )
    lines.append("")

    lines.append(f"## live bridge panes (tmux)")
    for row in _tmux_bridge_panes(team):
        lines.append(f"  {row['pane']:6} agent={row['agent']:20} cwd={row['cwd']}")
    lines.append("")

    lines.append(f"## inbox sizes")
    for name, total, unread in _inbox_summary(os.path.join(team_dir, "inboxes")):
        lines.append(f"  {name:30} total={total:4} unread={unread}")
    lines.append("")

    lines.append(f"## trust store (lead_cwd={lead_cwd})")
    if lead_cwd:
        for cli, trusted in _trust_status(lead_cwd).items():
            lines.append(f"  {cli:8} = {trusted}")
    else:
        lines.append("  (no lead_cwd resolvable)")
    lines.append("")

    if lead_cwd:
        clmux_dir = os.path.join(lead_cwd, ".claude", "clmux")
        log_pattern = os.path.join(clmux_dir, "logs", f"bridge-{team}-*.log")
        lines.append(f"## bridge log tails ({clmux_dir}/logs/)")
        found = False
        for log in sorted(glob.glob(log_pattern)):
            found = True
            lines.append(f"--- {os.path.basename(log)} (last 30) ---")
            lines.append(_tail(log, 30).rstrip())
            lines.append("")
        if not found:
            lines.append("  (no bridge logs found)")
            lines.append("")

        events_path = os.path.join(clmux_dir, "events", f"{team}.jsonl")
        lines.append(f"## recent events (last 30 from {os.path.basename(events_path)})")
        lines.append(_tail(events_path, 30).rstrip())
        lines.append("")

    return "\n".join(lines), 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-t", "--team", required=True)
    ap.add_argument("-o", "--output", default=None,
                    help="override output file; default is stdout + snapshots dir")
    args = ap.parse_args()

    report, rc = _build_report(args.team)
    print(report)

    if rc != 0:
        sys.exit(rc)

    # Best-effort snapshot write
    cfg = _read_json(os.path.join(_team_path(args.team), "config.json"))
    lead_cwd = _lead_cwd(cfg) if cfg else None
    if args.output:
        with open(args.output, "w") as f:
            f.write(report)
    elif lead_cwd:
        snap_dir = os.path.join(lead_cwd, ".claude", "clmux", "snapshots")
        try:
            os.makedirs(snap_dir, exist_ok=True)
            with open(os.path.join(snap_dir, f"{args.team}-{_ts()}.txt"), "w") as f:
                f.write(report)
        except Exception:
            pass


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/test_clmux_debug.py -v`
Expected: 3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/clmux_debug.py tests/test_clmux_debug.py
git commit -m "feat: add clmux_debug.py snapshot dumper"
```

---

## Task 9: zsh `clmux-debug` wrapper

**Files:**
- Modify: `clmux.zsh` — add function near other `clmux-*` wrappers

- [ ] **Step 1: Add the wrapper function**

Find an appropriate location near the other `clmux-*` public functions (after `clmux-teammates` or similar if it exists; otherwise append near the end of the file, before any trailing `autoload`/`fpath` lines). Add:

```zsh
# ── clmux-debug ───────────────────────────────────────────────────────────────
# Dump a consolidated debugging snapshot for a team.
# Usage: clmux-debug -t <team_name> [-o <output_file>]
clmux-debug() {
  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/scripts/clmux_debug.py" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/scripts/clmux_debug.py" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/scripts/clmux_debug.py" ]] || {
    echo "error: cannot find clau-mux directory" >&2; return 1;
  }
  python3 "$CLMUX_DIR/scripts/clmux_debug.py" "$@"
}
```

- [ ] **Step 2: Manual verification**

From inside a tmux session with at least one active team, run:

```bash
source /Users/idongju/Desktop/Git/clau-mux/clmux.zsh
clmux-debug -t <one-of-your-teams>
```

Expected: multi-section report printed to stdout; a file named `<team>-<ts>.txt` appears under the team's lead_cwd `.claude/clmux/snapshots/` directory.

- [ ] **Step 3: Commit**

```bash
git add clmux.zsh
git commit -m "feat: add clmux-debug zsh wrapper"
```

---

## Task 10: Documentation

**Files:**
- Create: `docs/debugging.md`
- Modify: `README.md` — add link

- [ ] **Step 1: Write `docs/debugging.md`**

```markdown
← [README](../README.md)

# Debugging

clau-mux writes three kinds of artifact under the **lead's project** at
`<lead_cwd>/.claude/clmux/` so you don't have to correlate `/tmp` logs,
`~/.claude/teams/*`, tmux state, and three CLIs' trust stores by hand:

```
<lead_cwd>/.claude/clmux/
├── logs/
│   └── bridge-<team>-<agent>.log        # console output (stdout+stderr)
├── events/
│   └── <team>.jsonl                     # structured events (one per line)
└── snapshots/
    └── <team>-<yyyymmddThhmmssZ>.txt    # on-demand dumps from clmux-debug
```

## The event stream (`events/<team>.jsonl`)

Every bridge emits a compact JSON line at each lifecycle moment. Common
events:

| event                 | key fields                              | meaning |
|-----------------------|-----------------------------------------|---------|
| `spawn_start`         | `idle_pattern`, `timeout`               | bridge started, before wait_for_idle |
| `spawn_ready`         | `matched_line`                          | first line that matched the idle pattern (helps diagnose false-positive matches, e.g. trust prompts) |
| `spawn_failed`        | `reason`                                | initial wait_for_idle timed out |
| `message_received`    | `from`, `text_len`, `msg_ts`            | read one unread message from inbox |
| `paste_start`         | `text_len`, `chunked`                   | about to deliver to the pane |
| `paste_chunk_failed`  | `chunk_idx`, `phase`                    | tmux load/paste-buffer returned non-zero (usually pane vanished) |
| `enter_not_accepted`  |                                         | 5 Enter retries without any pane-hash change |
| `defer_triggered`     | `count`, `max`, `action`                | wait_for_idle failed during delivery |
| `shutdown`            | `reason`                                | bridge exiting: `shutdown_request` / `pane_gone` / `defer_exhausted` / `paste_exhausted` |
| `cleanup`             | `deactivated`, `inbox_purged`           | EXIT trap ran the queue-lifecycle cleanup |

All events carry `ts`, `agent`, `team`, `pane`.

### Common queries

Watch live:

```bash
tail -f .claude/clmux/events/<team>.jsonl | jq -c .
```

Find why a teammate died (pick the most recent `shutdown`):

```bash
tac .claude/clmux/events/<team>.jsonl | jq -c 'select(.event=="shutdown")' | head -5
```

Detect idle-pattern false positives (e.g. trust prompt lines):

```bash
jq -c 'select(.event=="spawn_ready") | {agent,matched_line}' \
  .claude/clmux/events/<team>.jsonl
```

## `clmux-debug` snapshot

One-shot consolidated dump (config, live panes, inbox sizes, CLI trust
status, recent log + events):

```bash
clmux-debug -t <team>
```

The report is printed to stdout and copied to
`<lead_cwd>/.claude/clmux/snapshots/<team>-<ts>.txt` for later sharing.
Use `-o <file>` to write somewhere else.

## `.gitignore`

Logs, events, and snapshots are best ignored in the project's repo:

```gitignore
# clau-mux debug artifacts
.claude/clmux/
```

`scripts/setup.sh` offers to append this automatically on first run. The check uses a substring match against `.gitignore`, so a commented-out or pre-existing line is treated as "already listed" and the prompt is skipped — this is intentional idempotent behavior.

## Known limitations

These are explicitly out of scope for the current implementation. Raise a separate issue if you hit them:

- **No rotation.** `events/<team>.jsonl` and `logs/bridge-*.log` grow without bound for the lifetime of the team. Manual cleanup: `rm <project>/.claude/clmux/events/*.jsonl <project>/.claude/clmux/logs/*.log`, or archive with your preferred tool. For very long-lived teams, delete + re-`clmux-<agent> -t <team>` to start fresh.
- **No cascade cleanup on `TeamDelete`.** When a team is removed via `TeamDelete`, the artifacts under `<lead_cwd>/.claude/clmux/` persist. If you later create another team with the same name, `events/<same_name>.jsonl` will append to the old file. Inspect the first event's `ts` to verify provenance.
- **No global view.** Events are partitioned per team by design. To correlate across teams, concatenate with `cat <project>/.claude/clmux/events/*.jsonl | jq -s 'sort_by(.ts)'`.
- **`matched_line` is best-effort.** It records the line present a few milliseconds after `wait_for_idle` returned, not necessarily the exact line that satisfied the idle pattern. Adequate for diagnosing false positives (e.g. trust prompts) but not as a forensic ground truth.
- **Logging is fail-open.** `_event_log.py` wraps its body in a top-level exception handler that drops the event (stderr warning) and exits 0 if anything goes wrong — the bridge never fails because of logging. Trade-off: in pathological filesystem states, events can be silently dropped. The stderr note is visible in the bridge's console log.
```

- [ ] **Step 2: Add a link to `README.md`**

Find the existing documentation section in `README.md` (search for `docs/` links). Append:

```markdown
- [Debugging](docs/debugging.md) — event log, snapshot dumper, jq recipes
```

- [ ] **Step 3: Commit**

```bash
git add docs/debugging.md README.md
git commit -m "docs: add debugging guide for clmux log + events"
```

---

## Task 11: Optional `.gitignore` nudge in `setup.sh`

**Files:**
- Modify: `scripts/setup.sh` — append a new section after the existing hooks section

- [ ] **Step 1: Add an idempotent `.gitignore` updater**

Find the closing block of the hooks section (section 7 from the previous PR, around the `[SKIP] Hooks install skipped` branch). Immediately after the entire hooks `fi`, append:

```bash
# ---------------------------------------------------------------------------
# 8. Suggest adding .claude/clmux/ to the current project's .gitignore
# ---------------------------------------------------------------------------
if [[ -d "$PWD/.git" ]]; then
  GITIGNORE="$PWD/.gitignore"
  CLMUX_IGNORE=".claude/clmux/"
  if [[ -f "$GITIGNORE" ]] && grep -qF "$CLMUX_IGNORE" "$GITIGNORE"; then
    echo "[SKIP] .gitignore already lists $CLMUX_IGNORE"
  else
    read -r -p "Append '$CLMUX_IGNORE' to $GITIGNORE? [Y/n] " gi_answer
    gi_answer="${gi_answer:-Y}"
    if [[ "$gi_answer" =~ ^[Yy]$ ]]; then
      [[ -f "$GITIGNORE" ]] || touch "$GITIGNORE"
      printf '\n# clau-mux debug artifacts\n%s\n' "$CLMUX_IGNORE" >> "$GITIGNORE"
      echo "[OK]   Appended $CLMUX_IGNORE to $GITIGNORE"
    else
      echo "[SKIP] .gitignore update skipped"
    fi
  fi
else
  echo "[SKIP] Not inside a git repo — .gitignore not touched"
fi
```

- [ ] **Step 2: Verify setup.sh still parses**

Run: `bash -n /Users/idongju/Desktop/Git/clau-mux/scripts/setup.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/setup.sh
git commit -m "feat: offer to add .claude/clmux/ to project .gitignore"
```

---

## Task 12: Final smoke + PR prep

**Files:** (no code changes)

- [ ] **Step 1: Run the full Python test suite**

Run: `cd /Users/idongju/Desktop/Git/clau-mux && python3 -m pytest tests/ -v`
Expected: all tests PASS (test_event_log.py + test_clmux_debug.py + any prior tests).

- [ ] **Step 2: Run the integration test**

Run: `bash tests/test_bridge_events_integration.sh`
Expected: `PASS: all expected events present and well-formed`.

- [ ] **Step 3: Smoke-test a real team**

Inside your primary tmux session with an existing team (e.g. `clau-mux-final-verify`), spawn a teammate and confirm the new artifacts:

```bash
zsh -ic "clmux-gemini-stop -t clau-mux-final-verify"  # if already attached
zsh -ic "clmux-gemini -t clau-mux-final-verify -x 120"
ls /Users/idongju/Desktop/Git/clau-mux/.claude/clmux/logs/
ls /Users/idongju/Desktop/Git/clau-mux/.claude/clmux/events/
zsh -ic "clmux-debug -t clau-mux-final-verify"
```

Expected: freshly-created `bridge-clau-mux-final-verify-gemini-worker.log`, `clau-mux-final-verify.jsonl`, and a snapshot under `snapshots/`.

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin feat/clmux-debug-logging
gh pr create --base main --head feat/clmux-debug-logging \
  --title "feat: project-local debug logging (events + snapshots)" \
  --body-file docs/superpowers/plans/2026-04-15-clmux-debug-logging.md
```

(Optional: replace the PR body with a shorter summary instead of the full plan file.)

---

## Self-Review Notes

- **Spec coverage:**
  - logs/ (Option A) — Task 6
  - events/ (Option B) — Tasks 1, 2, 3, 4, 5, 7
  - snapshots/ via `clmux-debug` (Option C) — Tasks 8, 9
  - documentation + `.gitignore` hook — Tasks 10, 11
- **Privacy:** `matched_line` and `text_len` are bounded (text itself is never logged verbatim, only its length and the first 80 chars of the idle-match line). `from`, `msg_ts` are structural metadata.
- **Backward compatibility:** `-E` is optional; bridges spawned without it silently skip every `_emit`.
- **Concurrency:** events.jsonl writes go through `_filelock.file_lock` + `sigterm_guard`. Lock path derivation (`<path>.lock.d`) differs from outbox lock (`team-lead.json.lock.d`), so events-logging cannot block or be blocked by bridge-mcp-server.js outbox writes.
- **Type consistency:** field names (`agent`, `team`, `pane`, `ts`, `event`) used identically across Python helper, zsh `_emit` wrapper, integration test, and docs. The `team` field is derived once in `_emit` from the events file basename (`${EVENTS_FILE:t:r}`) so it cannot drift out of sync with the filename.
- **Fail-safety:** a broken events file cannot kill the bridge. `_event_log.py`'s top-level exception handler drops the event and exits 0 — the bridge treats logging as best-effort.

### Cross-review amendments applied (2026-04-15)

Amended post-cross-review by plan-reviewer (Claude Sonnet), gemini-reviewer, codex-worker, copilot-worker:

| Review finding | Amendment |
|---|---|
| **BLOCKING** Task 7 used `-S <sock>` isolated server, bridge talks to default socket → spawn_ready never fires | Task 7 rewritten to use the default tmux server + a disposable test window (cleanup in EXIT trap). Skips when run outside tmux. |
| **HIGH** `_emit` didn't set `team` field despite docs promising it | `_emit` now derives team from `${EVENTS_FILE:t:r}` and passes it. Integration test asserts the field is present. |
| **HIGH** Task 6 Step 3 said "repeat Steps 1-2" without showing `_lead_cwd` derivation for `_clmux_spawn_agent_in_session` | Step 3 now includes the explicit `tmux display-message -t "$lead_pane" -p '#{pane_current_path}'` derivation block. |
| **MED** `sigterm_guard` incorrectly described as "deferring" SIGTERM | Task 1 docstring corrected — SIGTERM is ignored for the critical section (and dropped, not redelivered). |
| **MED** `_event_log.py` failure could kill the bridge | Top-level try/except added; logging failure → stderr warning + exit 0. New test `test_failsafe_never_crashes_caller` exercises it. |
| **MED** No rotation, no TeamDelete cascade cleanup | Documented as Known Limitations in `docs/debugging.md` with manual workarounds. Out of scope for this PR. |
| **MED** Integration test covered only 6/10 events | Added Case B covering `spawn_failed`. Remaining three (`paste_chunk_failed`, `enter_not_accepted`, `defer_triggered`) documented as manual-smoke only because they require inducing tmux pathologies. |
| **LOW** Python subprocess cost overestimated | `_event_log.py`'s actual cost is ~0.01s real (codex measurement). Plan header updated to reflect this. |
| **COPILOT** PR strategy | Plan header now prescribes 3 stacked PRs with explicit task groupings. |
