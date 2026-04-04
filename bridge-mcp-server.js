#!/usr/bin/env node
/**
 * bridge-mcp-server.js
 * Minimal stdio MCP server for clau-mux.
 * Exposes write_to_lead(text, summary?) tool so Gemini/Codex can write
 * directly to the Claude Code teammate outbox.
 *
 * Env vars (set by clmux-gemini/clmux-codex):
 *   CLMUX_OUTBOX  — path to outbox.json
 *   CLMUX_AGENT   — agent name (default: gemini-worker)
 *
 * Fallback: reads /tmp/clmux-bridge-<agent>.env when env vars are missing
 * (Codex CLI clears parent env via env_clear()).
 */

'use strict';

const fs = require('fs');
const path = require('path');
const readline = require('readline');
const crypto = require('crypto');

// ── CRITICAL: register stdin listener FIRST to avoid race condition ──────────
// Codex sends `initialize` immediately after spawn. If readline isn't
// listening yet, the message is lost and Codex times out (Tools: none).

const messageQueue = [];
let ready = false;

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (_) {
    return;
  }
  if (ready) {
    handle(msg);
  } else {
    messageQueue.push(msg);
  }
});

// ── Resolve config (env vars or /tmp/ fallback) ─────────────────────────────

let AGENT_NAME = process.env.CLMUX_AGENT || '';
let OUTBOX = process.env.CLMUX_OUTBOX || '';

if (!OUTBOX) {
  try {
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
          OUTBOX = cfg.CLMUX_OUTBOX;
          AGENT_NAME = AGENT_NAME || cfg.CLMUX_AGENT || 'codex-worker';
          break;
        }
      } catch (_) {}
    }
  } catch (_) {}
}
if (!AGENT_NAME) AGENT_NAME = 'gemini-worker';

// ── Flush queued messages now that config is ready ──────────────────────────

ready = true;
for (const msg of messageQueue) {
  handle(msg);
}
messageQueue.length = 0;

// ── Protocol helpers ────────────────────────────────────────────────────────

function nowTs() {
  const d = new Date();
  return d.toISOString().replace(/(\.\d{3})\d*Z/, '$1Z');
}

function sendMsg(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

// ── Outbox write ────────────────────────────────────────────────────────────

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
      msgs = JSON.parse(fs.readFileSync(OUTBOX, 'utf-8'));
    } catch (_) {
      msgs = [];
    }

    const ts1 = nowTs();
    const entry = { from: AGENT_NAME, text, timestamp: ts1, read: false };
    if (summary) entry.summary = summary;
    msgs.push(entry);

    const ts2 = nowTs();
    const idlePayload = JSON.stringify({
      type: 'idle_notification',
      from: AGENT_NAME,
      idleReason: 'available',
      timestamp: ts2,
    });
    msgs.push({ from: AGENT_NAME, text: idlePayload, timestamp: ts2, read: false });

    if (msgs.length > 50) msgs = msgs.slice(-50);

    atomicWrite(OUTBOX, msgs);
    return 'ok: response delivered to lead';
  } catch (exc) {
    return `error: ${exc}`;
  }
}

// ── MCP request handlers ────────────────────────────────────────────────────

const TOOL_SCHEMA = {
  name: 'write_to_lead',
  description:
    'Send your completed response to the Claude Code lead session via the ' +
    'teammate protocol. Call this once at the end of every response.',
  inputSchema: {
    type: 'object',
    properties: {
      text: { type: 'string', description: 'Your full response text.' },
      summary: { type: 'string', description: 'Optional short summary (first sentence, < 60 chars).' },
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
      id,
      result: {
        protocolVersion: protoVersion,
        capabilities: { tools: {} },
        serverInfo: { name: 'clau-mux-bridge', version: '0.2.0' },
      },
    });
  } else if (method === 'notifications/initialized' || method === 'initialized') {
    // no response needed
  } else if (method === 'tools/list') {
    sendMsg({ jsonrpc: '2.0', id, result: { tools: [TOOL_SCHEMA] } });
  } else if (method === 'tools/call') {
    const params = msg.params || {};
    if (params.name === 'write_to_lead') {
      const args = params.arguments || {};
      const result = writeToLeadImpl(args.text || '', args.summary || '');
      sendMsg({ jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: result }] } });
    } else {
      sendMsg({ jsonrpc: '2.0', id, error: { code: -32601, message: 'Unknown tool' } });
    }
  } else if (id !== null) {
    sendMsg({ jsonrpc: '2.0', id, error: { code: -32601, message: `Unknown method: ${method}` } });
  }
}
