---
name: clmux-codex
description: This skill should be used when the user asks to "attach codex as teammate", "add codex to team", "run clmux-codex", "start codex worker", "spawn codex pane", "clmux-codex 실행", "codex teammate 붙여줘", or wants to stop/teardown the Codex teammate with "clmux-codex-stop", "stop codex worker", "codex 종료", "remove codex pane".
---

# clmux-codex

Spawn an OpenAI Codex CLI pane as a Claude Code teammate using the MCP bridge architecture.

## Architecture

- **Lead → Codex**: bridge (`clmux-bridge.zsh`) polls inbox → `tmux paste-buffer` + Enter to Codex pane
- **Codex → Lead**: Codex calls `write_to_lead` MCP tool → `bridge-mcp-server.js` writes directly to outbox

Note: Codex uses paste-buffer input mode (not send-keys) because its TUI doesn't accept standard key injection.

## Spawn Codex Teammate

**CRITICAL: Follow this exact sequence. Steps 1-3 must all run in the CURRENT session.**

### Step 1: Ensure team exists in current session

TeamCreate MUST be called in the current Claude Code session to activate inbox routing. If a team already exists and you are the lead, skip this step.

```
TeamCreate(team_name: "<team_name>")
```

If TeamCreate returns "Already leading team", that's fine — routing is active.

If you skip this step, `clmux-codex` will abort with an error: "team '<name>' has no leadSessionId". This is enforced by a guard in `_clmux_spawn_agent`.

### Step 2: Spawn Codex pane + bridge

```bash
zsh -ic "clmux-codex -t <team_name>"
```

> **Note**: Claude Code's Bash tool runs in a non-interactive shell that does not load `.zshrc`. `clmux-codex` is defined as a zsh function, so `zsh -ic` is required to load it.

This resets inbox/outbox, spawns Codex in a tmux pane, starts the bridge process with paste mode, writes env file for MCP server, and registers codex-worker in config.json.

Options:
- `-t <team_name>` — required
- `-n <agent_name>` — **clmux-teams 워크플로에서 필수 명시** (예: `security-codex`, `boilerplate-codex`, `review-codex`). standalone 호출 시 default: `codex-worker`. Naming Convention 상세는 [clmux-teams §Naming Convention](../clmux-teams/SKILL.md#naming-convention-필수) 참조
- `-x <timeout>` — idle-wait timeout, default: `30`

### Step 3: Send initial activation message

Immediately after `clmux-codex` returns, send an activation message via SendMessage. The bridge holds this message in the inbox and delivers it as soon as Codex is ready (idle pattern: `^[[:space:]]*›`).

```
SendMessage(to: "codex-worker", message: "<user's initial message or default greeting>")
```

If the user did not specify an initial message, use:
```
SendMessage(to: "codex-worker", message: "You are now connected as a Claude Code teammate. Briefly introduce yourself in Korean.")
```

### Step 4: Communicate

```
SendMessage(to: "codex-worker", message: "your message here")
```

## Stop Codex Teammate

**Graceful shutdown (preferred):**

```
SendMessage(to: "codex-worker", message: {"type": "shutdown_request"})
```

Bridge intercepts `shutdown_request` → kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → sets `isActive: false` in config.json → bridge exits. Same protocol as native Claude Code Agent teammates.

**Manual teardown (fallback):**

```bash
zsh -ic "clmux-codex-stop -t <team_name>"
```

## Codex-specific Notes

- **Paste mode**: Codex TUI requires `tmux paste-buffer` instead of `send-keys` for text input.
- **Env file**: Codex CLI runs `env_clear()` on MCP subprocesses. The bridge writes `~/.claude/teams/<team_name>/.bridge-<agent_name>.env` (예: `.bridge-security-codex.env`) so the MCP server can find `CLMUX_OUTBOX` and `CLMUX_AGENT`.
- **AGENTS.md**: Codex reads `AGENTS.md` (not CODEX.md) for project instructions including `write_to_lead` usage.
- **Idle pattern**: Bridge waits for `^[[:space:]]*›` before delivering queued messages.

## Bridge Behavior

The bridge (`clmux-bridge.zsh`) is an inbox relay only:

- Polls inbox every 0.5s → sends to Codex via `tmux paste-buffer` + Enter
- Does NOT wait for or collect responses
- On `shutdown_request`: kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → exits
- On pane gone (unexpected): writes plain-text shutdown notice to lead inbox (no `requestId`), then exits

Responses go through MCP: Codex calls `write_to_lead` → outbox → Claude Code reads via teammate protocol.

## Error Handling

If bridge is stuck or Codex pane is unresponsive:
1. `zsh -ic "clmux-codex-stop -t <team>"` to teardown
2. `zsh -ic "clmux-codex -t <team>"` to respawn
