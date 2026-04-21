---
name: clmux-copilot
description: This skill should be used when the user asks to "attach copilot as teammate", "add copilot to team", "run clmux-copilot", "start copilot worker", "spawn copilot pane", "clmux-copilot 실행", "copilot teammate 붙여줘", or wants to stop/teardown the Copilot teammate with "clmux-copilot-stop", "stop copilot worker", "copilot 종료", "remove copilot pane".
version: 0.1.0
---

# clmux-copilot

Spawn a GitHub Copilot CLI pane as a Claude Code teammate using the MCP bridge architecture.

## Architecture

- **Lead → Copilot**: bridge (`clmux-bridge.zsh`) polls inbox → `tmux paste-buffer` + Enter to Copilot pane
- **Copilot → Lead**: Copilot calls `write_to_lead` MCP tool → `bridge-mcp-server.js` writes directly to outbox

Note: Copilot uses paste-buffer input mode (not send-keys) because its TUI doesn't accept standard key injection.

## Spawn Copilot Teammate

**CRITICAL: Follow this exact sequence. Steps 1-3 must all run in the CURRENT session.**

### Step 1: Ensure team exists in current session

TeamCreate MUST be called in the current Claude Code session to activate inbox routing. If a team already exists and you are the lead, skip this step.

```
TeamCreate(team_name: "<team_name>")
```

If TeamCreate returns "Already leading team", that's fine — routing is active.

### Step 2: Spawn Copilot pane + bridge

```bash
zsh -ic "clmux-copilot -t <team_name>"
```

> **Note**: Claude Code's Bash tool runs in a non-interactive shell that does not load `.zshrc`. `clmux-copilot` is defined as a zsh function, so `zsh -ic` is required to load it.

This resets inbox/outbox, spawns Copilot in a tmux pane, starts the bridge process with paste mode, writes env file for MCP server, and registers copilot-worker in config.json.

Options:
- `-t <team_name>` — required
- `-n <agent_name>` — default: `copilot-worker`
- `-x <timeout>` — idle-wait timeout, default: `30`

### Step 3: Send initial activation message

Immediately after `clmux-copilot` returns, send an activation message via SendMessage. The bridge holds this message in the inbox and delivers it as soon as Copilot is ready (idle pattern: `/ commands`).

```
SendMessage(to: "copilot-worker", message: "<user's initial message or default greeting>")
```

If the user did not specify an initial message, use:
```
SendMessage(to: "copilot-worker", message: "You are now connected as a Claude Code teammate. Briefly introduce yourself in Korean.")
```

### Step 4: Communicate

```
SendMessage(to: "copilot-worker", message: "your message here")
```

## Stop Copilot Teammate

**Graceful shutdown (preferred):**

```
SendMessage(to: "copilot-worker", message: {"type": "shutdown_request"})
```

Bridge intercepts `shutdown_request` → kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → sets `isActive: false` in config.json → bridge exits.

**Manual teardown (fallback):**

```bash
zsh -ic "clmux-copilot-stop -t <team_name>"
```

## Copilot-specific Notes

- **Paste mode**: Copilot TUI requires `tmux paste-buffer` instead of `send-keys` for text input.
- **Env file**: Copilot CLI runs env_clear on MCP subprocesses. The bridge writes `~/.claude/teams/<team_name>/.bridge-copilot-worker.env` so the MCP server can find `CLMUX_OUTBOX` and `CLMUX_AGENT`.
- **AGENTS.md**: Copilot reads `AGENTS.md` for project instructions including `write_to_lead` usage.
- **Idle pattern**: Bridge waits for `/ commands` before delivering queued messages.

## Bridge Behavior

The bridge (`clmux-bridge.zsh`) is an inbox relay only:

- Polls inbox every 0.5s → sends to Copilot via `tmux paste-buffer` + Enter
- Does NOT wait for or collect responses
- On `shutdown_request`: kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → exits
- On pane gone (unexpected): writes plain-text shutdown notice to lead inbox (no `requestId`), then exits

Responses go through MCP: Copilot calls `write_to_lead` → outbox → Claude Code reads via teammate protocol.

## Error Handling

If bridge is stuck or Copilot pane is unresponsive:
1. `zsh -ic "clmux-copilot-stop -t <team>"` to teardown
2. `zsh -ic "clmux-copilot -t <team>"` to respawn
