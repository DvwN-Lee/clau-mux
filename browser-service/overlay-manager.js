import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createLogger } from './logger.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const log = createLogger('overlay-manager');

const BOOTSTRAP_JS = fs.readFileSync(path.join(__dirname, 'overlay-bootstrap.js'), 'utf8');
const HISTORY_HOOK_JS = fs.readFileSync(path.join(__dirname, 'history-api-hook.js'), 'utf8');

const HIGHLIGHT_CONFIG = {
  showInfo: true,
  contentColor: { r: 66, g: 133, b: 244, a: 0.2 },
  borderColor: { r: 66, g: 133, b: 244, a: 0.8 },
  marginColor: { r: 246, g: 178, b: 107, a: 0.3 },
};

const COMMENT_TIMEOUT_MS = 30000;

/**
 * Installs overlay on the main CDP session.
 *
 * @param {import('chrome-remote-interface').Client} session main CDP session
 * @param {{ inspectModeActive: boolean, subscriber: string|null, childSessions: Map, activeCommentHandler: Function|null }} state
 * @param {(backendNodeId: number, comment: string) => Promise<void>} onElementInspected
 */
export async function installOverlay(session, state, onElementInspected) {
  // H2 fix: Register bindings BEFORE script injection so the page scripts can reach them.
  await session.Runtime.addBinding({ name: 'clmuxInspectComment' });
  await session.Runtime.addBinding({ name: 'clmuxNavigate' });

  // Inject bootstrap + history hook on every new document (survives hard navigation)
  await session.Page.addScriptToEvaluateOnNewDocument({ source: BOOTSTRAP_JS });
  await session.Page.addScriptToEvaluateOnNewDocument({ source: HISTORY_HOOK_JS });

  // Also inject into the current document (addScriptToEvaluateOnNewDocument only affects future nav)
  try {
    await session.Runtime.evaluate({ expression: BOOTSTRAP_JS });
    await session.Runtime.evaluate({ expression: HISTORY_HOOK_JS });
    // H2 fix: wire browser clmux:navigate event → clmuxNavigate binding
    await session.Runtime.evaluate({
      expression: `window.addEventListener('clmux:navigate', (e) => {
        if (typeof window.clmuxNavigate === 'function') {
          window.clmuxNavigate(JSON.stringify(e.detail || {}));
        }
      });`,
    });
  } catch (e) {
    log.warn(`initial overlay injection failed: ${e.message}`);
  }

  // H2: Handle SPA client-side route events from browser
  session.Runtime.on('bindingCalled', async ({ name, payload }) => {
    if (name === 'clmuxNavigate') {
      log.info(`SPA navigate: ${payload}`);
      try {
        // Re-inject history hook (some frameworks replace history.pushState)
        await session.Runtime.evaluate({ expression: HISTORY_HOOK_JS });
        if (state.inspectModeActive) {
          await session.Overlay.setInspectMode({
            mode: 'searchForNode',
            highlightConfig: HIGHLIGHT_CONFIG,
          });
          await setOverlayLabel(session, state.subscriber);
        }
      } catch (e) {
        log.warn(`SPA navigate handler failed: ${e.message}`);
      }
    }
  });

  // Handle hard navigation (full page reload, new document)
  session.Page.on('frameNavigated', async ({ frame }) => {
    if (frame.parentId) return; // top-level only
    log.info(`frameNavigated: ${frame.url}`);
    try {
      if (state.inspectModeActive) {
        await session.Overlay.setInspectMode({
          mode: 'searchForNode',
          highlightConfig: HIGHLIGHT_CONFIG,
        });
        await setOverlayLabel(session, state.subscriber);
      }
    } catch (e) {
      log.warn(`post-navigation overlay re-injection failed: ${e.message}`);
    }
  });

  // Handle click events
  session.Overlay.on('inspectNodeRequested', async ({ backendNodeId }) => {
    log.info(`inspectNodeRequested: backendNodeId=${backendNodeId}`);

    // H3 fix: if a previous comment handler is still pending (user didn't submit),
    // abort it before starting a new one. Prevents listener leak.
    if (state.activeCommentHandler) {
      try {
        session.Runtime.removeListener('bindingCalled', state.activeCommentHandler);
      } catch { /* already removed */ }
      state.activeCommentHandler = null;
    }

    try {
      const resolved = await session.DOM.resolveNode({ backendNodeId });
      const objectId = resolved.object.objectId;
      await session.Runtime.callFunctionOn({
        functionDeclaration: 'function() { window.__clmux_inspected_node = this; }',
        objectId,
      });

      const commentPromise = new Promise((resolve) => {
        const handler = ({ name, payload }) => {
          if (name === 'clmuxInspectComment') {
            try { session.Runtime.removeListener('bindingCalled', handler); } catch { /* ignore */ }
            state.activeCommentHandler = null;
            resolve(payload || '');
          }
        };
        state.activeCommentHandler = handler;
        session.Runtime.on('bindingCalled', handler);
      });

      await session.Runtime.evaluate({
        expression: 'window.__clmux_prompt_comment && window.__clmux_prompt_comment()',
      });

      // H3: timeout with cleanup
      let timeoutId;
      const timeoutPromise = new Promise((resolve) => {
        timeoutId = setTimeout(() => {
          if (state.activeCommentHandler) {
            try { session.Runtime.removeListener('bindingCalled', state.activeCommentHandler); } catch { /* ignore */ }
            state.activeCommentHandler = null;
          }
          resolve('');
        }, COMMENT_TIMEOUT_MS);
      });

      const comment = await Promise.race([commentPromise, timeoutPromise]);
      clearTimeout(timeoutId);

      await onElementInspected(backendNodeId, comment);

      // Re-enter inspect mode (Overlay exits after each click)
      if (state.inspectModeActive) {
        await session.Overlay.setInspectMode({
          mode: 'searchForNode',
          highlightConfig: HIGHLIGHT_CONFIG,
        });
      }
    } catch (e) {
      log.error(`click handler failed: ${e.message}`);
    }
  });

  // H4 fix: Track child sessions (iframe / worker) via Target.setAutoAttach flatten.
  // Maintain state.childSessions Map to prevent leak.
  session.Target.on('attachedToTarget', async ({ sessionId, targetInfo, waitingForDebugger }) => {
    log.info(`child target attached: ${targetInfo.type} ${targetInfo.url} (sessionId=${sessionId})`);

    // MVP: only track same-origin iframes. Cross-origin iframes are noted but skipped
    // for DOM query safety (H5 — cross-origin crash protection).
    state.childSessions.set(sessionId, {
      type: targetInfo.type,
      url: targetInfo.url,
      targetId: targetInfo.targetId,
    });

    // H5 fix: inject bootstrap into child frame with try/catch — cross-origin may throw
    try {
      // Note: with flatten:true, child target methods are accessed via session.send('<Method>', params, sessionId)
      // chrome-remote-interface surfaces these as sub-session events but DOM queries per target
      // require tracking sessionId. MVP keeps this as "tracked but not actively queried".
    } catch (e) {
      log.warn(`child session init failed (likely cross-origin): ${e.message}`);
    }
  });

  session.Target.on('detachedFromTarget', ({ sessionId }) => {
    log.info(`child target detached: sessionId=${sessionId}`);
    state.childSessions.delete(sessionId);
  });
}

/**
 * Enable or disable inspect mode. B8 fix: explicit toggle so the user can interact
 * normally with dropdowns/modals before inspecting.
 */
export async function setInspectMode(session, state, active) {
  state.inspectModeActive = !!active;
  try {
    if (active) {
      await session.Overlay.setInspectMode({
        mode: 'searchForNode',
        highlightConfig: HIGHLIGHT_CONFIG,
      });
    } else {
      await session.Overlay.setInspectMode({
        mode: 'none',
        highlightConfig: HIGHLIGHT_CONFIG,
      });
    }
    await setOverlayLabel(session, state.subscriber);
  } catch (e) {
    log.warn(`setInspectMode failed: ${e.message}`);
  }
}

/**
 * Updates the overlay label shown in the browser page.
 */
export async function setOverlayLabel(session, subscriber) {
  const expr = `window.__clmux_set_active && window.__clmux_set_active(true, ${JSON.stringify(subscriber || '(none)')})`;
  try {
    await session.Runtime.evaluate({ expression: expr });
  } catch {
    /* page may not be ready or cross-origin frame — ignore */
  }
}
