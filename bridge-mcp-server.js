#!/usr/bin/env node
/**
 * bridge-mcp-server.js
 * Minimal MCP server for clau-mux.
 * Exposes write_to_lead(text, summary?) tool so Gemini/Codex/Copilot can write
 * directly to the Claude Code teammate outbox.
 *
 * Modes:
 *   stdio (default): JSON-RPC over stdin/stdout
 *   HTTP/SSE:        --http <port>  →  GET /sse + POST /messages
 *
 * Config resolution order (first wins):
 *   1. CLI args: --outbox <path> --agent <name>
 *   2. Env vars: CLMUX_OUTBOX, CLMUX_AGENT
 *
 * If neither is provided the server exits immediately. A previous
 * `.bridge-<agent>.env` mtime-scan fallback was removed: it caused
 * standalone CLI sessions (notably Gemini launched outside clmux-gemini)
 * to silently adopt an unrelated active team's outbox + agent identity
 * and forge write_to_lead entries into the wrong outbox. See
 * docs/investigations/orphan-env-fallback-2026-04-20.md.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ── Parse ALL CLI args first (determines mode) ───────────────────────────────

let AGENT_NAME = '';
let OUTBOX = '';
let HTTP_PORT = 0; // 0 = stdio mode

const cliArgs = process.argv.slice(2);
for (let i = 0; i < cliArgs.length; i++) {
  if (cliArgs[i] === '--outbox' && cliArgs[i + 1]) OUTBOX = cliArgs[++i];
  if (cliArgs[i] === '--agent'  && cliArgs[i + 1]) AGENT_NAME = cliArgs[++i];
  if (cliArgs[i] === '--http'   && cliArgs[i + 1]) HTTP_PORT = parseInt(cliArgs[++i], 10);
}

// ── Env vars ─────────────────────────────────────────────────────────────────

if (!OUTBOX)     OUTBOX     = process.env.CLMUX_OUTBOX || '';
if (!AGENT_NAME) AGENT_NAME = process.env.CLMUX_AGENT  || '';

// ── Fail fast: reject spawns that never got a team identity ─────────────────
// A standalone CLI (e.g. user runs `gemini` in ~/Desktop) can spawn this
// MCP server via a generic `clau-mux-bridge` entry in its settings. Without
// explicit OUTBOX/AGENT we refuse to serve — previously a mtime-based
// .bridge-<agent>.env fallback would pick the most-recently-active team
// and the standalone CLI's write_to_lead calls ended up in that team's
// outbox under the wrong `from` (the orphan-env bug, 2026-04-20).

if (!OUTBOX || !AGENT_NAME) {
  process.stderr.write(
    '[clmux-bridge] fatal: no team identity configured.\n' +
    '  Provide --outbox <path> --agent <name> OR env CLMUX_OUTBOX/CLMUX_AGENT.\n' +
    '  Standalone CLI sessions (gemini/codex/copilot not launched via clmux-*) must not\n' +
    '  register clau-mux-bridge as an MCP server — remove the entry from that tool\'s\n' +
    '  settings if you see this message.\n'
  );
  process.exit(1);
}

// ── Path validation ──────────────────────────────────────────────────────────

function validateOutboxPath(p) {
  const resolved = path.resolve(p);
  const base = path.resolve(process.env.HOME || '', '.claude');
  return resolved.startsWith(base + path.sep) && resolved.endsWith('.json') && !p.includes('..');
}

// ── Outbox write ─────────────────────────────────────────────────────────────

function nowTs() {
  return new Date().toISOString().replace(/(\.\d{3})\d*Z/, '$1Z');
}

function atomicWrite(filePath, data) {
  const dir = path.dirname(path.resolve(filePath));
  const tmp = path.join(dir, `.tmp-${crypto.randomBytes(6).toString('hex')}.json`);
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf-8');
  fs.renameSync(tmp, filePath);
}

// mkdir-based cross-process file lock. Coordinates with Python
// scripts/_filelock.py that uses the same `<path>.lock.d` mutex.
// Prevents lost updates when notify_shutdown.py and writeToLeadImpl
// concurrently read-modify-write the same team-lead.json outbox.
function withLock(targetPath, fn) {
  const lockPath = targetPath + '.lock.d';
  let acquired = false;
  for (let i = 0; i < 200; i++) {
    try {
      fs.mkdirSync(lockPath);
      acquired = true;
      break;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      const start = Date.now();
      while (Date.now() - start < 25) {} // busy-wait 25ms
    }
  }
  if (!acquired) throw new Error(`could not acquire lock on ${targetPath}`);
  try {
    return fn();
  } finally {
    try { fs.rmdirSync(lockPath); } catch (_) {}
  }
}

// Cap with read-message preference: when over cap, drop oldest READ
// message first; only drop oldest unread as a last resort. Prevents
// the double-push (response + idle_notification) from silently losing
// unread messages at the 50-cap boundary.
function trimToCap(msgs, cap) {
  while (msgs.length > cap) {
    const idx = msgs.findIndex(m => m.read);
    if (idx >= 0) msgs.splice(idx, 1);
    else msgs.shift();
  }
  return msgs;
}

function writeToLeadImpl(text, summary) {
  if (!OUTBOX)                    return 'error: CLMUX_OUTBOX not set';
  if (!validateOutboxPath(OUTBOX)) return 'error: CLMUX_OUTBOX path is invalid or outside allowed directory';
  if (!AGENT_NAME)                return 'error: AGENT_NAME not set (pass --agent or set CLMUX_AGENT)';
  try {
    return withLock(OUTBOX, () => {
      let msgs = [];
      try { msgs = JSON.parse(fs.readFileSync(OUTBOX, 'utf-8')); } catch (_) { msgs = []; }
      const ts1 = nowTs();
      const entry = { from: AGENT_NAME, text, timestamp: ts1, read: false };
      if (summary) entry.summary = summary;
      msgs.push(entry);
      trimToCap(msgs, 50);
      const ts2 = nowTs();
      const idlePayload = JSON.stringify({
        type: 'idle_notification', from: AGENT_NAME, idleReason: 'available', timestamp: ts2,
      });
      msgs.push({ from: AGENT_NAME, text: idlePayload, timestamp: ts2, read: false });
      trimToCap(msgs, 50);
      atomicWrite(OUTBOX, msgs);
      return 'ok: response delivered to lead';
    });
  } catch (exc) {
    return `error: ${exc}`;
  }
}

// ── Tool schema ───────────────────────────────────────────────────────────────

const TOOL_SCHEMA = {
  name: 'write_to_lead',
  description:
    'Send your completed response to the Claude Code lead session via the ' +
    'teammate protocol. Call this once at the end of every response.',
  inputSchema: {
    type: 'object',
    properties: {
      text:    { type: 'string', description: 'Your full response text.' },
      summary: { type: 'string', description: 'Optional short summary (first sentence, < 60 chars).' },
    },
    required: ['text'],
  },
};

// ── MCP request handler (returns response object or null) ─────────────────────

function buildResponse(msg) {
  const method = msg.method || '';
  const id = msg.id !== undefined ? msg.id : null;

  if (method === 'initialize') {
    const params = msg.params || {};
    return {
      jsonrpc: '2.0', id,
      result: {
        protocolVersion: params.protocolVersion || '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'clau-mux-bridge', version: '0.3.0' },
      },
    };
  }

  if (method === 'notifications/initialized' || method === 'initialized') {
    return null;
  }

  if (method === 'tools/list') {
    return { jsonrpc: '2.0', id, result: { tools: [TOOL_SCHEMA] } };
  }

  if (method === 'resources/list') {
    return { jsonrpc: '2.0', id, result: { resources: [] } };
  }

  if (method === 'resources/templates/list') {
    return { jsonrpc: '2.0', id, result: { resourceTemplates: [] } };
  }

  if (method === 'tools/call') {
    const params = msg.params || {};
    if (params.name === 'write_to_lead') {
      const args = params.arguments || {};
      const result = writeToLeadImpl(args.text || '', args.summary || '');
      return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: result }] } };
    }
    return { jsonrpc: '2.0', id, error: { code: -32601, message: 'Unknown tool' } };
  }

  if (id !== null) {
    return { jsonrpc: '2.0', id, error: { code: -32601, message: `Unknown method: ${method}` } };
  }

  return null;
}

// ── STDIO mode ────────────────────────────────────────────────────────────────
// CRITICAL: register stdin listener FIRST to avoid race condition.
// Codex sends `initialize` immediately after spawn; if readline isn't
// listening yet the message is lost and Codex times out (Tools: none).

function startStdio() {
  const readline = require('readline');
  const messageQueue = [];
  let ready = false;

  const rl = readline.createInterface({ input: process.stdin, terminal: false });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch (_) { return; }
    if (ready) {
      const resp = buildResponse(msg);
      if (resp) process.stdout.write(JSON.stringify(resp) + '\n');
    } else {
      messageQueue.push(msg);
    }
  });
  // Parent CLI closed stdin → exit so MCP subprocess does not linger and
  // continue accepting writes after its intended session is over.
  rl.on('close', () => process.exit(0));

  ready = true;
  for (const msg of messageQueue) {
    const resp = buildResponse(msg);
    if (resp) process.stdout.write(JSON.stringify(resp) + '\n');
  }
  messageQueue.length = 0;
}

// ── HTTP/SSE mode ─────────────────────────────────────────────────────────────
// Implements the MCP HTTP+SSE transport:
//   GET  /sse            → SSE stream; first event is `endpoint` with POST URL
//   POST /messages?sessionId=<id>  → JSON-RPC request; response via SSE `message` event

function startHttpServer(port) {
  const http = require('http');
  const sessions = new Map(); // sessionId → SSE response

  const server = http.createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    const reqUrl = new URL(req.url, `http://127.0.0.1:${port}`);

    if (req.method === 'GET' && reqUrl.pathname === '/sse') {
      const sessionId = crypto.randomBytes(8).toString('hex');
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
      });
      sessions.set(sessionId, res);
      res.write(`event: endpoint\ndata: /messages?sessionId=${sessionId}\n\n`);
      req.on('close', () => sessions.delete(sessionId));
      return;
    }

    if (req.method === 'POST' && reqUrl.pathname === '/messages') {
      const sessionId = reqUrl.searchParams.get('sessionId');
      const sseRes = sessions.get(sessionId);
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', () => {
        res.writeHead(202);
        res.end();
        let msg;
        try { msg = JSON.parse(body); } catch (_) { return; }
        const resp = buildResponse(msg);
        if (resp && sseRes) {
          sseRes.write(`event: message\ndata: ${JSON.stringify(resp)}\n\n`);
        }
      });
      return;
    }

    res.writeHead(404);
    res.end();
  });

  server.listen(port, '127.0.0.1', () => {
    process.stderr.write(`[clmux-bridge] HTTP MCP server on http://127.0.0.1:${port}/sse\n`);
  });
}

// ── Start ─────────────────────────────────────────────────────────────────────

if (HTTP_PORT > 0) {
  startHttpServer(HTTP_PORT);
} else {
  startStdio();
}
