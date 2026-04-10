#!/usr/bin/env node
/**
 * browser-service — main daemon entry point.
 *
 * Usage:
 *   node browser-service.js --team=<name> --endpoint=ws://127.0.0.1:PORT [--http-port=0]
 *
 * Launched by clmux.zsh with disown. Connects to an already-running Chrome instance
 * (Chrome is launched separately by clmux.zsh).
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createLogger } from './logger.js';
import { initCDPClient, withReconnect } from './cdp-client.js';
import { installOverlay, setInspectMode, setOverlayLabel } from './overlay-manager.js';
import { buildDetectionExpression, parseDetectionResult } from './framework-detector.js';
import { resolveSourceLocation } from './source-remapper.js';
import { buildFingerprint, TRACKED_STYLE_PROPS, truncateOuterHTML, enforceTokenBudget } from './fingerprinter.js';
import { buildPayload } from './payload-builder.js';
import { watchSubscriber, readSubscriber, writeSubscriber } from './subscription-watcher.js';
import { writeToInbox } from './inbox-writer.js';
import { startHTTPServer } from './http-server.js';

const log = createLogger('main');

function parseArgs(argv) {
  const args = {};
  for (const a of argv.slice(2)) {
    const [k, v] = a.replace(/^--/, '').split('=');
    args[k] = v ?? true;
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv);
  const team = args.team;
  const endpoint = args.endpoint;
  const httpPort = parseInt(args['http-port'] || '0', 10);

  if (!team || !endpoint) {
    console.error('usage: node browser-service.js --team=<name> --endpoint=ws://127.0.0.1:PORT [--http-port=0]');
    process.exit(2);
  }

  const teamDir = path.join(os.homedir(), '.claude', 'teams', team);
  fs.mkdirSync(path.join(teamDir, 'inboxes'), { recursive: true });

  log.info(`starting browser-service for team=${team} endpoint=${endpoint}`);

  // State shared with overlay-manager. childSessions/activeCommentHandler added for H3/H4.
  const state = {
    inspectModeActive: false, // B8 fix: start disabled — user must explicitly enable via clmux-inspect toggle
    subscriber: readSubscriber(teamDir),
    pendingComment: '',
    childSessions: new Map(),
    activeCommentHandler: null,
    clickGeneration: 0,
  };

  let cdpSession = null;
  let framework = 'unknown';

  const stopWatcher = watchSubscriber(teamDir, async (sub) => {
    state.subscriber = sub;
    log.info(`subscriber changed: ${sub || '(none)'}`);
    if (cdpSession) {
      try { await setOverlayLabel(cdpSession, sub); } catch { /* ignore */ }
    }
  });
  stopWatcherForCleanup = stopWatcher;

  const startedAt = Date.now();
  let lastPayloadAt = null;

  const handlers = {
    status: async () => ({
      status: 'running',
      subscriber: state.subscriber,
      chrome_pid: readPid(path.join(teamDir, '.chrome.pid')),
      uptime: Math.floor((Date.now() - startedAt) / 1000),
      last_payload_at: lastPayloadAt,
      inspect_mode_active: state.inspectModeActive,
      child_sessions: state.childSessions.size,
    }),
    subscribe: async ({ agent }) => {
      if (!agent) throw new Error('agent required');
      writeSubscriber(teamDir, agent);
      return { ok: true, agent };
    },
    unsubscribe: async () => {
      writeSubscriber(teamDir, '');
      return { ok: true };
    },
    // B8 fix: Inspect mode toggle (Gemini F1)
    toggleInspect: async ({ active }) => {
      if (!cdpSession) throw new Error('CDP not connected');
      const next = typeof active === 'boolean' ? active : !state.inspectModeActive;
      await setInspectMode(cdpSession, state, next);
      return { ok: true, inspect_mode_active: state.inspectModeActive };
    },
    query: async ({ selector, props }) => {
      if (!cdpSession) throw new Error('CDP not connected');
      return await querySelector(cdpSession, selector, props || TRACKED_STYLE_PROPS);
    },
    snapshot: async ({ selector }) => {
      if (!cdpSession) throw new Error('CDP not connected');
      return await snapshotSelector(cdpSession, selector, framework);
    },
  };

  // startHTTPServer returns a Promise (resolves after 'listening')
  const server = await startHTTPServer({ port: httpPort, handlers });
  httpServerForCleanup = server;
  const actualPort = server.address().port;
  // B1 fix: HTTP server port → .browser-service.port (NOT .chrome-debug.port).
  // Chrome CDP port is owned by chrome-launcher.js which writes .chrome-debug.port separately.
  const httpPortFile = path.join(teamDir, '.browser-service.port');
  fs.writeFileSync(httpPortFile, String(actualPort), { mode: 0o600 });
  try { fs.chmodSync(httpPortFile, 0o600); } catch { /* best-effort */ }
  log.info(`HTTP server listening on 127.0.0.1:${actualPort}`);

  const onElementInspected = async (backendNodeId, comment) => {
    try {
      const payload = await buildPayloadFromBackendNode(cdpSession, backendNodeId, comment, framework);
      const subscriber = state.subscriber || 'team-lead';
      writeToInbox(teamDir, subscriber, payload);
      lastPayloadAt = new Date().toISOString();
      log.info(`payload delivered to ${subscriber}`);
    } catch (e) {
      log.error(`payload delivery failed: ${e.message}`);
    }
  };

  const chromePidPath = path.join(teamDir, '.chrome.pid');

  await withReconnect(endpoint, async (client) => {
    cdpSession = client;

    try {
      const detection = await client.Runtime.evaluate({ expression: buildDetectionExpression(), returnByValue: true });
      framework = parseDetectionResult(detection.result && detection.result.value);
      log.info(`framework detected: ${framework}`);
    } catch { framework = 'unknown'; }

    await installOverlay(client, state, onElementInspected);
    // B8: start with inspect mode off. User must explicitly enable via clmux-inspect toggle.
    await setInspectMode(client, state, false);

    // Wait for disconnect (withReconnect handles the wait loop via disconnectPromise)
    await new Promise(() => {});
  }, {
    chromePidPath, // B3: OS-level Chrome PID watcher
    onReconnect: (attempt) => {
      log.warn(`CDP reconnect attempt ${attempt}`);
      cdpSession = null;
    },
    onGiveUp: () => {
      isAlertShutdown = true;
      log.error('CDP reconnect cap reached — writing alert and exiting');
      try {
        fs.writeFileSync(
          path.join(teamDir, '.browser-service-alert'),
          `[${new Date().toISOString()}] CDP reconnect cap reached. Manual restart required.\n`,
          { mode: 0o600 },
        );
      } catch { /* best-effort */ }
    },
  });

  stopWatcher();
  server.close();
}

function readPid(file) {
  try { return parseInt(fs.readFileSync(file, 'utf8').trim(), 10); }
  catch { return null; }
}

async function querySelector(session, selector, props) {
  const root = await session.DOM.getDocument({ depth: 0 });
  const { nodeId } = await session.DOM.querySelector({ nodeId: root.root.nodeId, selector });
  if (!nodeId) {
    const err = new Error(`selector not found: ${selector}`);
    err.code = 'SELECTOR_NOT_FOUND';
    throw err;
  }
  const computed = await session.CSS.getComputedStyleForNode({ nodeId });
  const subset = {};
  for (const { name, value } of computed.computedStyle) {
    if (props.includes(name)) subset[name] = value;
  }
  return { selector, computed: subset };
}

async function snapshotSelector(session, selector, framework) {
  const root = await session.DOM.getDocument({ depth: 0 });
  const { nodeId } = await session.DOM.querySelector({ nodeId: root.root.nodeId, selector });
  if (!nodeId) {
    const err = new Error(`selector not found: ${selector}`);
    err.code = 'SELECTOR_NOT_FOUND';
    throw err;
  }

  // M7 fix: DOM.resolveNode can race with DOM mutations (e.g., React re-render between
  // querySelector and resolveNode). If it fails, return selector_not_found instead of
  // crashing the daemon.
  let objectId;
  try {
    const resolved = await session.DOM.resolveNode({ nodeId });
    objectId = resolved.object.objectId;
  } catch (err) {
    const e = new Error(`node resolution failed (DOM may have mutated): ${err.message}`);
    e.code = 'SELECTOR_NOT_FOUND';
    throw e;
  }

  await session.Runtime.callFunctionOn({
    functionDeclaration: 'function() { window.__clmux_inspected_node = this; }',
    objectId,
  });

  return await buildPayloadFromNodeId(session, nodeId, '', framework);
}

async function buildPayloadFromBackendNode(session, backendNodeId, comment, framework) {
  const { nodeIds } = await session.DOM.pushNodesByBackendIdsToFrontend({ backendNodeIds: [backendNodeId] });
  return await buildPayloadFromNodeId(session, nodeIds[0], comment, framework);
}

async function buildPayloadFromNodeId(session, nodeId, comment, framework) {
  const desc = await session.DOM.describeNode({ nodeId });
  const outerHTML = await session.DOM.getOuterHTML({ nodeId });

  const [matchedStyles, computedStyle, axTree, boxModel, pageUrl, scrollInfo] = await Promise.all([
    session.CSS.getMatchedStylesForNode({ nodeId }).catch(() => ({ matchedCSSRules: [] })),
    session.CSS.getComputedStyleForNode({ nodeId }).catch(() => ({ computedStyle: [] })),
    session.Accessibility.getPartialAXTree({ nodeId }).catch(() => ({ nodes: [] })),
    session.DOM.getBoxModel({ nodeId }).catch(() => ({ model: null })),
    session.Runtime.evaluate({ expression: 'location.href', returnByValue: true }).catch(() => ({ result: { value: '' } })),
    session.Runtime.evaluate({
      expression: '({scrollX: window.scrollX, scrollY: window.scrollY, innerWidth: window.innerWidth, innerHeight: window.innerHeight, dpr: window.devicePixelRatio})',
      returnByValue: true,
    }).catch(() => ({ result: { value: {} } })),
  ]);

  const boxContent = boxModel.model && boxModel.model.content;
  const boundingBox = boxContent && boxContent.length === 8
    ? { x: boxContent[0], y: boxContent[1], w: boxContent[2] - boxContent[0], h: boxContent[5] - boxContent[1] }
    : { x: 0, y: 0, w: 0, h: 0 };

  const axNode = (axTree.nodes || []).find((n) => n.backendDOMNodeId === desc.node.backendNodeId);

  const scroll = scrollInfo.result.value || {};
  const fingerprint = buildFingerprint({
    matchedRules: matchedStyles.matchedCSSRules || [],
    computedStyle: computedStyle.computedStyle || [],
    boundingBox,
    viewport: { w: scroll.innerWidth || 0, h: scroll.innerHeight || 0 },
    scrollOffsets: { x: scroll.scrollX || 0, y: scroll.scrollY || 0 },
    devicePixelRatio: scroll.dpr || 1,
    axRoleName: axNode?.role?.value || 'generic',
    axAccessibleName: axNode?.name?.value,
  });

  const sourceLocation = await resolveSourceLocation(session, framework);

  const attrs = {};
  if (desc.node.attributes) {
    for (let i = 0; i < desc.node.attributes.length; i += 2) {
      attrs[desc.node.attributes[i]] = desc.node.attributes[i + 1];
    }
  }

  const payload = buildPayload({
    userIntent: comment,
    pointing: {
      selector: computeSelector(desc.node),
      outerHTML: truncateOuterHTML(outerHTML.outerHTML),
      tag: desc.node.nodeName.toLowerCase(),
      attrs,
    },
    sourceLocation,
    fingerprint,
    url: pageUrl.result.value || '',
  });
  const { ok, tokenCount } = enforceTokenBudget(payload);
  if (!ok) {
    log.warn(`Payload exceeds 5000 token budget (${tokenCount}). Truncating outerHTML.`);
    payload.pointing.outerHTML = (payload.pointing.outerHTML || '').slice(0, 200) + '...[budget-truncated]';
    payload.pointing.attrs = {};
  }
  return payload;
}

/**
 * Best-effort CSS selector generator.
 * M4 WARN: this selector is NOT guaranteed to be unique. If the clicked element
 * is one of many matching `.card` divs, `querySelector(selector)` in query/snapshot
 * will return the FIRST match — possibly the wrong element. For click-triggered
 * events this is safe because we use backendNodeId directly; for CLI-invoked
 * query/snapshot, users must pass more specific selectors.
 *
 * Post-MVP: add nth-child index or XPath fallback for guaranteed uniqueness.
 */
function computeSelector(node) {
  const parts = [];
  parts.push(node.nodeName.toLowerCase());
  if (node.attributes) {
    const attrs = {};
    for (let i = 0; i < node.attributes.length; i += 2) attrs[node.attributes[i]] = node.attributes[i + 1];
    if (attrs.id) parts.push('#' + attrs.id);
    if (attrs.class) parts.push(...attrs.class.trim().split(/\s+/).map((c) => '.' + c));
  }
  return parts.join('');
}

// B2 fix: Complete cleanup — all resources, both port files, process exit escalation.
const teamDirForCleanup = path.join(os.homedir(), '.claude', 'teams', parseArgs(process.argv).team || 'unknown');
let isAlertShutdown = false;
let cleanupInProgress = false;
let httpServerForCleanup = null;
let stopWatcherForCleanup = null;

function cleanup() {
  if (cleanupInProgress) return;
  cleanupInProgress = true;
  log.info('browser-service shutting down (graceful)');

  // Stop the subscription watcher
  try { if (stopWatcherForCleanup) stopWatcherForCleanup(); } catch { /* ignore */ }

  // Close HTTP server
  try { if (httpServerForCleanup) httpServerForCleanup.close(); } catch { /* ignore */ }

  // Remove runtime files (do NOT touch .chrome-debug.port or .chrome.pid — those are
  // owned by chrome-launcher / clmux.zsh cleanup, which kills Chrome separately)
  const toRemove = [
    '.browser-service.port',
    ...(isAlertShutdown ? [] : ['.browser-service-alert']),
  ];
  for (const f of toRemove) {
    try { fs.unlinkSync(path.join(teamDirForCleanup, f)); } catch { /* ignore */ }
  }

  // Grace period before force exit (10s per spec)
  setTimeout(() => {
    log.warn('graceful shutdown timeout — forcing exit');
    process.exit(0);
  }, 10000).unref();

  process.exit(0);
}

process.on('SIGTERM', cleanup);
process.on('SIGINT', cleanup);
process.on('uncaughtException', (err) => {
  log.error(`uncaughtException: ${err.message}`);
  log.error(err.stack);
  cleanup();
});

main().then(() => {
  // main() returned normally — cleanup already ran inside via withReconnect give-up
  cleanup();
}).catch((err) => {
  log.error(`fatal: ${err.message}`);
  log.error(err.stack);
  cleanup();
});
