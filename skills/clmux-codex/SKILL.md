---
name: clmux-codex
description: This skill should be used when the user asks to "attach codex as teammate", "add codex to team", "run clmux-codex", "start codex worker", "spawn codex pane", "clmux-codex 실행", "codex teammate 붙여줘", or wants to stop/teardown the Codex teammate with "clmux-codex-stop", "stop codex worker", "codex 종료", "remove codex pane".
version: 0.1.0
---

# clmux-codex

Spawn an OpenAI Codex CLI pane as a Claude Code teammate using the MCP bridge architecture.

## Architecture

- **Lead → Codex**: bridge (`clmux-bridge.zsh`) polls inbox → `tmux paste-buffer` + Enter to Codex pane
- **Codex → Lead**: Codex calls `write_to_lead` MCP tool → `bridge-mcp-server.js` writes directly to outbox

Note: All bridge teammates use `paste-buffer -p` (bracketed paste) for reliable text delivery.

## Spawn Codex Teammate

**CRITICAL: Follow this exact sequence. Steps 1-3 must all run in the CURRENT session.**

### Step 1: Ensure team exists in current session

TeamCreate MUST be called in the current Claude Code session to activate inbox routing. If a team already exists and you are the lead, skip this step.

```
TeamCreate(team_name: "<team_name>")
```

If TeamCreate returns "Already leading team", that's fine — routing is active.

### Step 2: Spawn Codex pane + bridge

```bash
zsh -ic "clmux-codex -t <team_name>"
```

> **Note**: Claude Code's Bash tool runs in a non-interactive shell that does not load `.zshrc`. `clmux-codex` is defined as a zsh function, so `zsh -ic` is required to load it.

This resets inbox/outbox, spawns Codex in a tmux pane, starts the bridge process with paste mode, writes env file for MCP server, and registers codex-worker in config.json.

Options:
- `-t <team_name>` — required
- `-n <agent_name>` — default: `codex-worker`
- `-m <model>` — Codex model (예: `gpt-5.4`, `gpt-5.4-mini`)
- `-x <timeout>` — idle-wait timeout, default: `30`

> 동일 이름의 teammate가 이미 존재하면 spawn이 거부됨. `-n`으로 다른 이름 지정 가능.

### Step 3: Send initial activation message

Immediately after `clmux-codex` returns, send an activation message via SendMessage. The bridge holds this message in the inbox and delivers it as soon as Codex is ready.

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

- **Paste mode**: All bridge teammates use `tmux paste-buffer -p` (bracketed paste) for text input.
- **Env file**: Codex CLI runs `env_clear()` on MCP subprocesses. The bridge writes `~/.claude/teams/<team_name>/.bridge-codex-worker.env` so the MCP server can find `CLMUX_OUTBOX` and `CLMUX_AGENT`.
- **AGENTS.md**: Codex reads `AGENTS.md` (not CODEX.md) for project instructions including `write_to_lead` usage.

## Bridge Behavior

The bridge (`clmux-bridge.zsh`) is an inbox relay only:

- Polls inbox every 2s → sends to Codex via `tmux paste-buffer -p` + Enter
- Does NOT wait for or collect responses
- On `shutdown_request`: kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → exits
- On pane gone (unexpected): writes plain-text shutdown notice to lead inbox (no `requestId`), then exits

Responses go through MCP: Codex calls `write_to_lead` → outbox → Claude Code reads via teammate protocol.

## Teammates 확인

현재 세션의 teammate 목록 확인:
```bash
zsh -ic "clmux-teammates"
```

## Error Handling

If bridge is stuck or Codex pane is unresponsive:
1. `zsh -ic "clmux-codex-stop -t <team>"` to teardown
2. `zsh -ic "clmux-codex -t <team>"` to respawn
