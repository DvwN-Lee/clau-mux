# Bridge Enforcement: Team-gated `write_to_lead` for Gemini/Codex/Copilot

**Date**: 2026-04-23
**Status**: Design — awaiting user review
**Scope**: clau-mux bridge (Gemini/Codex/Copilot CLI teammates)

## Problem

The `clau_mux_bridge` MCP server exposes `write_to_lead` to non-Claude CLIs (Gemini/Codex/Copilot). Two failure modes are in production today:

1. **Standalone leakage**: When a user runs `gemini`/`codex` outside of a `clmux-<agent>` spawn (no team context), the CLI still has the bridge MCP registered globally. Historically (and likely still today for most users), `write_to_lead` calls succeed against whichever team's outbox the CLI most recently touched, posting phantom teammate messages into unrelated teams' conversations. The user expectation is that standalone sessions must never call `write_to_lead`.
2. **In-team under-forward (Codex)**: When a Codex worker is spawned into a team, `write_to_lead` calls hang indefinitely on MCP-level approval because `approval_mode = "approve"` is hardcoded in `setup_codex_mcp.py`. The worker pane has no human; Codex either gives up and replies in its terminal (invisible to lead) or blocks forever. Result: the lead observes Codex as unresponsive even though it generated output.

The user-facing requirement:
- Team context present → MUST forward to lead via `write_to_lead`.
- No team context → MUST NOT forward (behave as standalone CLI).

## Root causes (verified via file inspection + live runtime tests against Codex CLI v0.123.0 and Gemini CLI)

1. **npm publish gap**: `clau-mux-bridge@1.2.0` (2026-04-06) is the latest published version. The local repo is at `1.3.6` and includes a 2026-04-20 fail-fast patch that exits on startup when `CLMUX_OUTBOX`/`CLMUX_AGENT` are missing. Every `npx -y clau-mux-bridge` invocation across user setups still fetches `1.2.0` without the guard. **The 2026-04-20 patch is not actually deployed.** This is the single largest contributor to standalone leakage.
2. **Gemini duplicate-key coexistence**: `~/.gemini/settings.json` carries a legacy `clau-mux-bridge` (dash) key with `trust: true`. `setup_gemini_mcp.py` writes a new `clau_mux_bridge` (underscore) key without removing the dash key. Gemini CLI treats the two keys as **independent MCP servers** and spawns both. `setup_codex_mcp.py` has a legacy-removal pattern (`names_to_remove`); the Gemini setup script does not.
3. **Codex global-block overwrite**: `~/.codex/config.toml` contains a single global `[mcp_servers.clau_mux_bridge]` block with `--outbox`/`--agent` hardcoded. Each teammate spawn rewrites this block. Two concurrent team spawns cause identity takeover: the later spawn's block overwrites the earlier one, and the earlier Codex worker starts writing to the new team's outbox.
4. **Codex approval hang**: `approval_mode = "approve"` requires interactive approval per tool call. Confirmed by live reproduction: a diag-codex worker generated a complete response, issued `write_to_lead`, and hung on the approval prompt (no human in the worker pane).
5. **Codex `--profile` does not scope `mcp_servers`**: Verified via `codex --profile p -c 'profiles.p.mcp_servers.foo.command="true"' mcp list` — only the top-level `clau_mux_bridge` appears; the profile-scoped server does not. GitHub issue `openai/codex#9325` is still open. Profile-based isolation is not viable.
6. **Prompt protocol is unconditional**: `prompt/GEMINI.md`, `prompt/AGENTS.md`, `prompt/COPILOT.md` instruct workers to "end every response with `write_to_lead`" without a team-context gate. Combined with globally-registered MCP, this drives standalone CLIs to attempt forwarding when they should not.

## Non-goals

- Replacing the Claude Code teammate message protocol (`SendMessage`, outbox files) — out of scope.
- Adding a generic worker-framework watchdog that auto-nags when `write_to_lead` is skipped — deferred; the `approval_mode` fix eliminates the current dominant cause of Codex under-forward.
- Migrating any worker off `npx` to a repo-local `node bridge-mcp-server.js` invocation — the npm republish path is simpler and keeps install ergonomics.

## Design

### Architecture (components affected)

```
┌──────────────────────────┐
│  npm: clau-mux-bridge    │  ← republish 1.3.x (P0 blocker)
│  (bridge-mcp-server.js)  │    Pin setup scripts to ^1.3.0.
└──────────────────────────┘
              ▲
              │ spawned via npx
┌──────────────────────────┐      ┌──────────────────────────┐
│  Gemini CLI              │      │  Codex CLI               │
│  ~/.gemini/settings.json │      │  ~/.codex/config.toml    │
│  - remove legacy dash    │      │  - remove global block   │
│  - keep global register  │      │  - per-spawn CODEX_HOME  │
└──────────────────────────┘      └──────────────────────────┘
              ▲                                 ▲
              │                                 │ CODEX_HOME=<team-dir>/.codex-home
              └──────────── clmux spawn ────────┘ (per-team isolated config.toml)
                            lib/teammate-internals.zsh
                            env CLMUX_OUTBOX, CLMUX_AGENT
                            + optional spawn-token
```

### Components

**C1. `clau-mux-bridge` npm republish (P0)**
- Bump `package.json` to `1.3.7` (or next available); verify `bridge-mcp-server.js` contains the 2026-04-20 fail-fast guard.
- Publish to npm.
- Update `setup_gemini_mcp.py`, `setup_codex_mcp.py`, `setup_copilot_mcp.py` to pin: `npx -y clau-mux-bridge@^1.3.0`.
- **Interface**: unchanged. `write_to_lead(text, summary?)` stdio/HTTP MCP.
- **Depends on**: nothing.
- **Verifies**: standalone defense by making `exit(1)` reach end users.

**C2. Gemini legacy-key cleanup**
- Modify `scripts/setup_gemini_mcp.py`:
  - Before writing `clau_mux_bridge`, delete any existing `mcpServers` key in `{ "clau_mux_bridge", "clau-mux-bridge" }` (mirroring `setup_codex_mcp.py`'s `names_to_remove`).
  - Idempotent: running twice yields the same file.
- **Interface**: same CLI args as today.
- **Depends on**: C1 (so the single surviving key points at a guarded bridge).
- **Verifies**: Gemini CLI spawns exactly one bridge process per session.

**C3. Codex global-block removal + per-spawn `CODEX_HOME`**
- Modify `scripts/setup_codex_mcp.py`:
  - Default behavior (no args): only register the project trust entry and `approval_mode` default. Do **not** write `[mcp_servers.clau_mux_bridge]` to `~/.codex/config.toml`. The global block is removed.
  - With `--outbox`/`--agent` args (spawn-time call): write a per-team `config.toml` to a path supplied via `--home <dir>` (typically `<team-dir>/.codex-home/config.toml`). Invoked from `lib/teammate-internals.zsh`.
- Modify `lib/teammate-internals.zsh` `_clmux_spawn_agent_in_session` Codex branch:
  - Compute `codex_home="$team_dir/.codex-home"`, create dir, run `setup_codex_mcp.py --home "$codex_home" --outbox ... --agent ...`.
  - Prepend `CODEX_HOME=$codex_home` to the `env ...` preamble in `tmux split-window`.
- **Interface**: `clmux-codex -t <team> -n <agent>` unchanged on the user side.
- **Depends on**: C1 (pinned npx), `setup_codex_mcp.py` already accepts `--outbox`/`--agent`.
- **Verifies**: concurrent teams have isolated configs; no global block to overwrite.

**C4. Codex `approval_mode` correction**
- Keep `approval_mode = "approve"` — the earlier plan to switch to `"auto"` was incorrect.
- **Rationale** (revised after cross-check 2026-04-23): Live ground-truth test in bridge-xcheck team with verify5-codex confirmed that `approval_mode = "approve"` auto-approves simple `write_to_lead` payloads without prompting. The earlier diag-codex hang was content-triggered (Codex's content-safety layer flagged a specific payload containing "encrypted reasoning blob" / "sensitive operational claims"), NOT driven by `approval_mode`. Testing `approval_mode = "auto"` showed the OPPOSITE: it prompts every call. Codex CLI 0.123.0 schema documents `approve = automatically approve without user intervention`, `auto = system decides based on safety rules, likely prompts`, `prompt = always ask`.
- **Interface**: none.
- **Depends on**: C3.
- **Verifies**: Codex worker `write_to_lead` completes without hang for typical payloads (live-verified 2026-04-23). Edge case: very large/sensitive payloads may still trigger Codex's content-review UI — orthogonal to our config and not addressable at the approval_mode layer.

**C5. Prompt `write_to_lead` availability gate**
- Modify `prompt/GEMINI.md`, `prompt/AGENTS.md`, `prompt/COPILOT.md`:
  - Change the opening rule from unconditional "end every response with `write_to_lead`" to conditional:
    > If the `write_to_lead` tool is listed among your available tools, you are attached to a team and MUST end every response with `write_to_lead(...)`. If it is not listed, respond normally in the terminal — do not attempt to call it.
  - Keep the rest of the protocol (error handling, payload format) unchanged.
- **Interface**: none (prompt file content).
- **Depends on**: C1+C2+C3 (so that tool availability genuinely reflects team context).
- **Verifies**: even if someone re-adds a global MCP registration by accident, the prompt defaults to standalone behavior when tool is absent.

### Data Flow

**Spawn (team case)**:
```
user: clmux-codex -t myteam -n security-codex
  └─ _clmux_spawn_agent_in_session
       ├─ mkdir -p ~/.claude/teams/myteam/.codex-home
       ├─ python3 setup_codex_mcp.py \
       │     --home ~/.claude/teams/myteam/.codex-home \
       │     --outbox ~/.claude/teams/myteam/inboxes/team-lead.json \
       │     --agent security-codex
       │   (writes config.toml with mcp_servers block pointing at this team's outbox)
       └─ tmux split-window 'exec env \
             CODEX_HOME=~/.claude/teams/myteam/.codex-home \
             CLMUX_OUTBOX=... CLMUX_AGENT=security-codex \
             codex -a never'
            └─ codex reads $CODEX_HOME/config.toml → loads team-specific mcp_servers
                └─ npx -y clau-mux-bridge@^1.3.0 --outbox ... --agent ...
                    ├─ bridge gets CLMUX_OUTBOX/CLMUX_AGENT (double-redundant with CLI args)
                    └─ registers write_to_lead with approval_mode="auto"

Lead → Codex:
  SendMessage("security-codex", "...") → inbox file → bridge polls → tmux paste

Codex → Lead:
  Codex ends turn with write_to_lead(text, summary)
    → auto-approved (approval_mode="auto")
    → bridge writes to CLMUX_OUTBOX
    → Claude Code teammate protocol delivers to lead
```

**Standalone (non-team)**:
```
user: gemini (from ~/Desktop)
  └─ gemini CLI reads ~/.gemini/settings.json
       └─ clau_mux_bridge (underscore, only key) → npx -y clau-mux-bridge@^1.3.0
           └─ bridge sees no CLMUX_OUTBOX, no --outbox arg
               └─ exit(1) — tool vanishes from Gemini tool list
  └─ GEMINI.md prompt: "if write_to_lead available, team mode; else standalone"
     └─ tool not available → respond in terminal only. No leakage.
```

### Error Handling

- **Bridge exits immediately**: Gemini/Codex CLI drops the tool silently. Prompt gate keeps worker on standalone behavior. No retry loop.
- **npm stale version served**: Prevention only — if user pins `^1.3.0` and npm still serves `1.2.0`, npm install fails with `No matching version`. Explicit failure better than silent leakage.
- **Per-team `CODEX_HOME` dir missing**: `setup_codex_mcp.py --home <dir>` creates it. If creation fails, script exits non-zero, spawn function aborts, user sees error.
- **Approval denied**: `approval_mode="auto"` never prompts, so this path vanishes for `write_to_lead`. Other tools retain default (prompt/approve) as before.

### Testing

- **Unit-ish** (`tests/`):
  - `test_setup_gemini_mcp_legacy_cleanup`: seed settings.json with both keys → run setup → assert only `clau_mux_bridge` remains.
  - `test_setup_codex_mcp_no_global_block`: run setup without `--outbox` → assert `[mcp_servers.clau_mux_bridge]` absent from `~/.codex/config.toml`.
  - `test_setup_codex_mcp_per_home`: run setup with `--home /tmp/X --outbox Y --agent Z` → assert `/tmp/X/config.toml` contains the block with correct args and `approval_mode = "auto"`.
- **Integration** (manual, documented in this spec):
  - Spawn two teams concurrently via `clmux-codex`; assert each Codex sees only its own outbox via `codex mcp get clau_mux_bridge` inside each pane.
  - Standalone Gemini/Codex in a scratch directory; attempt `write_to_lead` invocation (verbal prompt); assert tool not available / not called.
  - In-team Codex: issue a simple probe; assert response reaches lead inbox without any pane-side approval action.

## Scope and Sequencing

Bundled PR (single change): C1 must land first (republish + pin), then C2–C5 can be applied together. The user previously confirmed bundled scope is preferred. All five components are cohesive: fixing only a subset leaves either standalone leakage (skip C1/C2/C5) or in-team under-forward (skip C3/C4) in production.

## Open Questions (for the plan phase, not blocking design)

1. Does Gemini CLI support a `GEMINI_HOME`-equivalent env var to redirect `~/.gemini/settings.json`? If yes, a parallel C3-style per-team isolation for Gemini becomes available; if no, standalone defense for Gemini relies on C1+C2+C5 only. Needs runtime verification.
2. Does a `.codex/config.toml` at the project root merge with or replace the user-level `mcp_servers`? Affects whether C3's per-team `CODEX_HOME` approach should also write a project-local override as a secondary defense.
3. Spawn-token (outbox signature validated by bridge) was considered as a third redundancy layer but is **deferred**: C1+C3 already make the bridge identity-bound via env args, and the token adds complexity without covering a concrete remaining attack. Revisit if a specific leak path is found post-deployment.
