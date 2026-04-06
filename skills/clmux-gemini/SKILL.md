---
name: clmux-gemini
description: This skill should be used when the user asks to "attach gemini as teammate", "add gemini to team", "run clmux-gemini", "start gemini worker", "spawn gemini pane", "clmux-gemini 실행", "gemini teammate 붙여줘", or wants to stop/teardown the Gemini teammate with "clmux-gemini-stop", "stop gemini worker", "gemini 종료", "remove gemini pane".
version: 0.6.0
---

# clmux-gemini

Spawn a Gemini CLI pane as a Claude Code teammate using the MCP bridge architecture.

## Architecture

- **Lead → Gemini**: bridge (`clmux-bridge.zsh`) polls inbox → `tmux send-keys` to Gemini pane
- **Gemini → Lead**: Gemini calls `write_to_lead` MCP tool → `bridge-mcp-server.js` writes directly to outbox

## Spawn Gemini Teammate

**CRITICAL: Follow this exact sequence. Steps 1-3 must all run in the CURRENT session.**

### Step 1: Ensure team exists in current session

TeamCreate MUST be called in the current Claude Code session to activate inbox routing. If a team already exists and you are the lead, skip this step.

```
TeamCreate(team_name: "<team_name>")
```

If TeamCreate returns "Already leading team", that's fine — routing is active.

### Step 2: Spawn Gemini pane + bridge

```bash
zsh -ic "clmux-gemini -t <team_name>"
```

> **Note**: Claude Code's Bash tool runs in a non-interactive shell that does not load `.zshrc`. `clmux-gemini` is defined as a zsh function, so `zsh -ic` is required to load it.

This resets inbox/outbox, spawns Gemini in a tmux pane, starts the bridge process, and registers gemini-worker in config.json.

Options:
- `-t <team_name>` — required
- `-n <agent_name>` — default: `gemini-worker`
- `-x <timeout>` — idle-wait timeout, default: `30`

### Step 3: Send initial activation message

Immediately after `clmux-gemini` returns, send an activation message via SendMessage. The bridge holds this message in the inbox and delivers it as soon as Gemini's MCP servers are ready.

```
SendMessage(to: "gemini-worker", message: "<user's initial message or default greeting>")
```

If the user did not specify an initial message, use:
```
SendMessage(to: "gemini-worker", message: "You are now connected as a Claude Code teammate. Briefly introduce yourself in Korean.")
```

### Step 4: Communicate

```
SendMessage(to: "gemini-worker", message: "your message here")
```

## Stop Gemini Teammate

**Graceful shutdown (preferred):**

```
SendMessage(to: "gemini-worker", message: {"type": "shutdown_request"})
```

Bridge intercepts `shutdown_request` → kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → sets `isActive: false` in config.json → bridge exits. Same protocol as native Claude Code Agent teammates.

**Manual teardown (fallback):**

```bash
zsh -ic "clmux-gemini-stop -t <team_name>"
```

## Why TeamCreate is required

Claude Code's `SendMessage` only routes to file-based inboxes for teams initialized in the current session via `TeamCreate`. Without it, messages are not written to the inbox file, and the bridge cannot deliver them to Gemini.

## Bridge Behavior

The bridge (`clmux-bridge.zsh`) is an inbox relay only:

- Polls inbox every 2s → sends to Gemini via `tmux send-keys`
- Does NOT wait for or collect responses
- On `shutdown_request`: kills pane → writes `shutdown_approved` JSON (with `requestId`) to lead inbox → exits
- On pane gone (unexpected): writes plain-text shutdown notice to lead inbox (no `requestId`), then exits

Responses go through MCP: Gemini calls `write_to_lead` → outbox → Claude Code reads via teammate protocol.

## Error Handling

If bridge is stuck or Gemini pane is unresponsive:
1. `zsh -ic "clmux-gemini-stop -t <team>"` to teardown
2. `zsh -ic "clmux-gemini -t <team>"` to respawn
