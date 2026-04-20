# Investigation: orphan env-fallback cross-team contamination

**Status**: fixed
**Date**: 2026-04-20
**Reporter**: user bug report — "clmux bug report — codex bridge 6x off-topic loop"

## Symptom

A `trade-crosscheck` team was spawned at 17:38 KST with Claude Code Lead +
`codex-worker` + `gemini-worker` + `reviewer-claude`. Lead sent one security
validation task to `codex-worker` (1328 chars). Codex answered correctly
once, then produced 7 additional "Claude Code 글로벌 설정 정리 (CLAUDE.md
cleanup)" responses over the next 3 minutes — topic entirely unrelated to
the assigned trade task. Each drift response reached Lead as a fully
formatted `from=codex-worker` outbox entry with paired `idle_notification`,
so Lead treated codex as context-polluted and requested shutdown.

## Root cause

**The drift responses were not authored by codex at all.** They came from
a **standalone Gemini CLI** session the user launched in `~/Desktop` at
17:45 KST, routed through a different `clau-mux-bridge` MCP subprocess that
adopted codex-worker's identity via a fallback env lookup.

Mechanism:

1. `~/.gemini/settings.json` registers `clau-mux-bridge` MCP globally with
   `args: ["-y", "clau-mux-bridge"]` — no `--outbox`, no `--agent`.
2. When the standalone Gemini spawns the MCP subprocess, it inherits none
   of the per-team env vars that `clmux-gemini` normally injects (because
   this Gemini was not launched via `clmux-gemini`).
3. `bridge-mcp-server.js` used to resolve config in three tiers: CLI args,
   env vars, then a fallback that scanned `~/.claude/teams/*/.bridge-*.env`
   and picked the **mtime-newest** match.
4. At 17:45, the mtime-newest bridge env file was `.bridge-codex-worker.env`
   in `~/.claude/teams/trade-crosscheck/` (written 7 minutes earlier by
   `clmux-codex`). The fallback adopted its `CLMUX_OUTBOX` +
   `CLMUX_AGENT=codex-worker`.
5. Every `write_to_lead` call Gemini made about CLAUDE.md cleanup landed in
   `trade-crosscheck/inboxes/team-lead.json` as `from=codex-worker`.

## Evidence

| Signal | Finding |
|---|---|
| `/tmp/clmux-bridge-trade-crosscheck-codex-worker.log` | Only 2 lead→codex deliveries: the initial task + `shutdown_request`. |
| `~/.codex/sessions/2026/04/20/rollout-…T17-38-…jsonl` | Ends with `task_complete` at 17:43:22; contains exactly **1** `write_to_lead` call (the correct Pass-1 response). No drift content. |
| 104 codex rollouts scanned | **0 matches** for any drift signature (`항목 7`, `원클릭 클린업`, `NEEDS CAVEAT`, `최종 정리 체크리스트`, `글로벌 설정 정리`, `12가지 항목`). |
| `~/.gemini/tmp/desktop/chats/session-2026-04-20T08-45-…json` | Standalone Gemini session started at exactly the drift start time. **6 of 6** drift signatures match. |
| `~/.gemini/tmp/inv/chats/session-2026-04-20T08-38-…json` | The team-attached gemini-worker session (legitimate). 0 drift signature matches. |

## Fix

`bridge-mcp-server.js`:

- Removed the `.bridge-<agent>.env` mtime-scan fallback (was ~45 lines).
- Fail fast if neither CLI args nor env vars provide OUTBOX + AGENT —
  stderr explains the cause and tells the user to remove the registration
  from standalone CLI settings.
- Added `rl.on('close', () => process.exit(0))` to the stdio mode so the
  MCP subprocess exits immediately when its parent CLI closes stdin,
  rather than lingering and potentially accepting further writes.

The fail-fast check covers both the specific Gemini scenario and any
future tool whose config forgets to pass per-team args. The team-path
matching guard that existed at the fallback's inner loop (lines 78–79)
is no longer needed because the fallback itself is gone.

## Follow-up risks

- **Orphan HTTP MCP servers**: `ps aux` currently shows 11 `node …
  bridge-mcp-server.js --http <port>` processes dating back to 2026-04-13.
  These are Copilot-mode bridges that leaked across sessions. They do not
  contribute to the present bug (each has its own `CLMUX_OUTBOX`/`CLMUX_AGENT`
  env that was set at `clmux-copilot` spawn time), but they represent an
  orthogonal lifecycle issue. Recommend a `clmux-cleanup --mcp` helper or
  a SIGTERM broadcast on team teardown. Deferred — not in this fix.
- **Codex config.toml single-namespace mutation**: `setup_codex_mcp.py`
  rewrites the global `[mcp_servers.clau_mux_bridge]` block every spawn,
  which means simultaneous codex sessions targeting different teams still
  share one outbox pointer at config-read time. Consider switching to
  codex `[profiles.clmux-<team>]` scoping. Deferred — not in this fix.

## Cleanup residue

The 7 impostor entries (`#2`–`#8` in `trade-crosscheck/inboxes/team-lead.json`)
remain in the outbox file from the original session. They are harmless now
(the bridge is torn down) but will reappear if that team is reactivated
and Lead re-reads history. Manual purge or per-session outbox rotation is
the user's call.
