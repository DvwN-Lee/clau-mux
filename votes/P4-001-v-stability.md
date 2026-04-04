# VOTE: Approve
## Teammate: v-stability
## 안건: P4-VERIFY (implementation correctness)
## Severity: IMPORTANT
## 근거

### 1. Race condition between MCP server and bridge — LOW RISK

Both `bridge-mcp-server.py:63-70` (`atomic_write`) and `gbridge_append.py` (line 80-84 in gemini-bridge.zsh) use atomic temp-file + `os.replace` for writes. Classic read-modify-write race (lost update) is theoretically possible if both read concurrently.

**However, the hybrid detection mitigates this:**
- `wait_for_hybrid()` (`gemini-bridge.zsh:240-274`) checks outbox count FIRST, then pane blocks. If MCP writes before the first pane block appears, "mcp" path is taken and the bridge never writes — no race.
- If pane blocks appear first (Gemini renders output before MCP tool completes), bridge takes "pane" path. MCP tool call completes before Gemini shows idle prompt (MCP is synchronous within Gemini's response generation), so by the time `wait_for_pane_complete` returns and bridge reads outbox, MCP's write is already committed. Bridge reads the updated file and appends — no lost update.
- **Remaining risk**: duplicate responses (both MCP and bridge write). Low probability in practice because MCP detection has priority and MCP writes are fast.

**Verdict**: Acceptable. Not a data-loss issue in normal operation.

### 2. Hybrid detection correctness — CORRECT

`wait_for_hybrid()` at `gemini-bridge.zsh:248-251`: `count_outbox` reads the file, which is always in a consistent state due to atomic rename. The count comparison `cur_outbox > before_outbox` is a sound heuristic — MCP server writes 2 entries (response + idle), so count always increases by >= 2.

No missed-detection risk from partial writes. Atomic rename guarantees the file is either old or fully new.

### 3. Pane fallback Phase 2a/2b — CORRECT with timeout note

`wait_for_pane_complete()` at `gemini-bridge.zsh:221-236`:
- Phase 2a: waits for idle prompt to disappear (grep fails → break) — correct
- Phase 2b: waits for idle prompt to reappear (grep succeeds → return 0) — correct

**Timeout inconsistency (MINOR)**: `wait_for_pane_complete` uses its own `elapsed=0` (`gemini-bridge.zsh:222`), independent of `wait_for_hybrid`'s elapsed. Total wall time can reach `TIMEOUT + TIMEOUT` = 240s. Compare with `wait_for_response()` (`gemini-bridge.zsh:173-206`) which shares a single `elapsed` across all phases, capping at TIMEOUT. Not a bug but an inconsistency.

### 4. Timeout math — CONSERVATIVE, ACCEPTABLE

All loops: `sleep 1` + `(( elapsed++ ))`. The work done per iteration (tmux capture-pane, python3 invocations) adds ~0.2-0.5s overhead not counted in `elapsed`. So actual wall time per "second" is ~1.2-1.5s. For TIMEOUT=120, real time ≈ 150-180s. Timeouts are never shorter than TIMEOUT, only longer. Safe for a reliability mechanism.

### 5. Error paths — MINOR ISSUES

- **Empty `extract_response`**: `gemini-bridge.zsh:337-341` — empty response is written to outbox as a message with empty text. Claude Code lead receives an empty message. Not a crash, but unhelpful. A simple `[[ -z "$response" ]]` guard would improve this.

- **`count_outbox` failure**: `gbridge_count_outbox.py` catches all exceptions → returns 0. MCP detection silently degrades to pane-only fallback. Acceptable.

- **MCP server write failure**: `bridge-mcp-server.py:106` catches exceptions, returns error string to Gemini. Orphan temp files possible on crash between create and rename, but Python `with` block + OS cleanup handles this adequately.

- **Non-atomic `mark_read`**: `gbridge_mark_read.py` at gemini-bridge.zsh lines 44-53 uses `open(path, 'w')` — NOT atomic, unlike all other writes. If bridge is killed mid-write, inbox JSON is corrupted. Next `read_unread` catches parse error → returns empty → no message processed → safe degradation. But the inbox requires manual repair. MINOR inconsistency.

### 6. Process lifecycle — ONE IMPORTANT ISSUE

**MCP server cleanup — CORRECT**: `bridge-mcp-server.py:44-46` — `sys.stdin.buffer.readline()` returns empty bytes on stdin EOF (Gemini exits). `recv_msg()` returns None → `main()` breaks → clean exit.

**Zombie bridge — IMPORTANT**: When the Gemini pane dies unexpectedly (crash, manual close, not via `clmux-gemini-stop`):
- Bridge does NOT detect pane death
- `tmux capture-pane -t "$PANE_ID"` fails silently (returns empty)
- `grep -qF "Type your message"` never matches → bridge loops in timeout cycles (120s each)
- `tmux send-keys -t "$PANE_ID"` for new messages fails silently
- Bridge persists as an orphan process, writing timeout errors to outbox every ~122s if messages arrive
- Only stoppable via `clmux-gemini-stop` or manual `kill`

**Mitigation suggestion**: Add a pane-alive check at the top of the main loop:
```zsh
tmux has-session -t "$PANE_ID" 2>/dev/null || { echo "[gemini-bridge] pane gone — exiting"; exit 1; }
```
(Actually `tmux display-message -t "$PANE_ID" -p ''` would be more precise for pane vs session check.)

## 수정 필요 사항

No VETO-worthy issues. Recommendations for future improvement:

1. **(IMPORTANT)** Add pane-alive guard in bridge main loop to prevent zombie bridge after pane death
2. **(MINOR)** Make `gbridge_mark_read.py` use atomic write for consistency
3. **(MINOR)** Guard empty `extract_response` to avoid writing empty messages to outbox
4. **(MINOR)** Consider unifying timeout accounting between `wait_for_hybrid` + `wait_for_pane_complete`
