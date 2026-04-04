#!/usr/bin/env node
/**
 * bridge-mcp-server.js
 * Minimal stdio MCP server for clau-mux.
 * Exposes write_to_lead(text, summary?) tool so Gemini can write directly
 * to the Claude Code teammate outbox without tmux pane-watching.
 *
 * Reads from env:
 *   CLMUX_OUTBOX  — path to outbox.json
 *   CLMUX_AGENT   — agent name (default: gemini-worker)
 *
 * Usage (registered via `gemini mcp add`):
 *   gemini mcp add clau-mux-bridge node /path/to/bridge-mcp-server.js
 */

'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');

// Read from env first, then fallback to config file (for CLIs like Codex
// that don't pass parent env to MCP server subprocesses)
let AGENT_NAME = process.env.CLMUX_AGENT || '';
let OUTBOX = process.env.CLMUX_OUTBOX || '';

if (!OUTBOX) {
  const envFiles = fs.readdirSync('/tmp').filter(f => f.startsWith('clmux-bridge-') && f.endsWith('.env'));
  for (const f of envFiles) {
    try {
      const lines = fs.readFileSync(path.join('/tmp', f), 'utf-8').split('\n');
      const cfg = {};
      for (const line of lines) {
        const [k, ...v] = line.split('=');
        if (k) cfg[k.trim()] = v.join('=').trim();
      }
      if (cfg.CLMUX_OUTBOX) {
        OUTBOX = OUTBOX || cfg.CLMUX_OUTBOX;
        AGENT_NAME = AGENT_NAME || cfg.CLMUX_AGENT || 'codex-worker';
        break;
      }
    } catch (_) {}
  }
}
if (!AGENT_NAME) AGENT_NAME = 'gemini-worker';

// ── Protocol helpers ──────────────────────────────────────────────────────────

function nowTs() {
  const d = new Date();
  return d.toISOString().replace(/(\.\d{3})\d*Z/, '$1Z');
}

function sendMsg(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

// ── Outbox write ──────────────────────────────────────────────────────────────

function atomicWrite(filePath, data) {
  const dir = path.dirname(path.resolve(filePath));
  const tmp = path.join(dir, `.tmp-${crypto.randomBytes(6).toString('hex')}.json`);
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf-8');
  fs.renameSync(tmp, filePath);
}

function writeToLeadImpl(text, summary) {
  if (!OUTBOX) {
    return 'error: CLMUX_OUTBOX not set';
  }
  try {
    let msgs = [];
    try {
      const raw = fs.readFileSync(OUTBOX, 'utf-8');
      msgs = JSON.parse(raw);
    } catch (_) {
      msgs = [];
    }

    // Response entry
    const ts1 = nowTs();
    const entry = { from: AGENT_NAME, text: text, timestamp: ts1, read: false };
    if (summary) {
      entry.summary = summary;
    }
    msgs.push(entry);

    // Idle notification (JSON-in-text format required by Claude Code)
    const ts2 = nowTs();
    const idlePayload = JSON.stringify({
      type: 'idle_notification',
      from: AGENT_NAME,
      idleReason: 'available',
      timestamp: ts2,
    });
    msgs.push({ from: AGENT_NAME, text: idlePayload, timestamp: ts2, read: false });

    // Trim to 50 entries
    if (msgs.length > 50) {
      msgs = msgs.slice(msgs.length - 50);
    }

    atomicWrite(OUTBOX, msgs);
    return 'ok: response delivered to lead';
  } catch (exc) {
    return `error: ${exc}`;
  }
}

// ── MCP request handlers ──────────────────────────────────────────────────────

const TOOL_SCHEMA = {
  name: 'write_to_lead',
  description:
    'Send your completed response to the Claude Code lead session via the ' +
    'teammate protocol. Call this once at the end of every response.',
  inputSchema: {
    type: 'object',
    properties: {
      text: {
        type: 'string',
        description: 'Your full response text.',
      },
      summary: {
        type: 'string',
        description: 'Optional short summary (first sentence, < 60 chars).',
      },
    },
    required: ['text'],
  },
};

function handle(msg) {
  const method = msg.method || '';
  const id = msg.id !== undefined ? msg.id : null;

  if (method === 'initialize') {
    const params = msg.params || {};
    const protoVersion = params.protocolVersion || '2024-11-05';
    sendMsg({
      jsonrpc: '2.0',
      id: id,
      result: {
        protocolVersion: protoVersion,
        capabilities: { tools: {} },
        serverInfo: { name: 'clau-mux-bridge', version: '0.1.0' },
      },
    });
  } else if (method === 'notifications/initialized' || method === 'initialized') {
    // notifications need no response
  } else if (method === 'tools/list') {
    sendMsg({
      jsonrpc: '2.0',
      id: id,
      result: { tools: [TOOL_SCHEMA] },
    });
  } else if (method === 'tools/call') {
    const params = msg.params || {};
    if (params.name === 'write_to_lead') {
      const args = params.arguments || {};
      const result = writeToLeadImpl(
        args.text || '',
        args.summary || ''
      );
      sendMsg({
        jsonrpc: '2.0',
        id: id,
        result: { content: [{ type: 'text', text: result }] },
      });
    } else {
      sendMsg({
        jsonrpc: '2.0',
        id: id,
        error: { code: -32601, message: 'Unknown tool' },
      });
    }
  } else if (id !== null) {
    sendMsg({
      jsonrpc: '2.0',
      id: id,
      error: { code: -32601, message: `Unknown method: ${method}` },
    });
  }
}

// ── Entry point ───────────────────────────────────────────────────────────────

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (_) {
    return;
  }
  handle(msg);
});
