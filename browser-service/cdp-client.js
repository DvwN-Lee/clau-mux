import CDP from 'chrome-remote-interface';
import fs from 'node:fs';
import { createLogger } from './logger.js';

const log = createLogger('cdp-client');

export async function initCDPClient(endpoint) {
  const url = new URL(endpoint);
  const client = await CDP({ host: url.hostname, port: parseInt(url.port, 10) });

  await Promise.all([
    client.DOM.enable(),
    client.CSS.enable(),
    client.Overlay.enable(),
    client.Accessibility.enable(),
    client.Page.enable(),
    client.Runtime.enable(),
  ]);

  // H1 fix: Target.setAutoAttach.flatten is experimental — try with fallback
  try {
    await client.Target.setAutoAttach({
      autoAttach: true,
      waitForDebuggerOnStart: false,
      flatten: true,
    });
    log.info('Target.setAutoAttach(flatten: true) enabled');
  } catch (err) {
    log.warn(`Target.setAutoAttach(flatten) unavailable: ${err.message}. Falling back without flatten — iframe session management degraded.`);
    try {
      await client.Target.setAutoAttach({ autoAttach: true, waitForDebuggerOnStart: false });
    } catch (err2) {
      log.warn(`Target.setAutoAttach unavailable: ${err2.message}. Cross-frame inspection disabled.`);
    }
  }

  log.info(`CDP client initialized (${endpoint})`);
  return client;
}

// B3 fix: SRS NFR-201 requires 3-attempt cap (was 5 in initial draft)
const BACKOFFS_MS = [1000, 2000, 4000];  // 1s immediate, then 2s, 4s

/**
 * Wraps daemon work with reconnect logic.
 * Detects disconnect via 3 sources:
 *   1. client.on('disconnect') — WebSocket-level disconnect
 *   2. Target.targetCrashed — tab/worker crash event
 *   3. Chrome PID watcher — OS-level process exit (FR-202 < 10s detection)
 *
 * @param {string} endpoint
 * @param {(client) => Promise<void>} work
 * @param {{ chromePidPath?: string, onReconnect?: (attempt: number) => void, onGiveUp?: () => void }} opts
 */
export async function withReconnect(endpoint, work, opts = {}) {
  let attempt = 0;

  while (true) {
    let client;
    try {
      client = await initCDPClient(endpoint);
    } catch (err) {
      if (attempt >= BACKOFFS_MS.length) {
        log.error(`CDP reconnect cap reached (${BACKOFFS_MS.length} attempts). Giving up.`);
        if (opts.onGiveUp) opts.onGiveUp();
        throw err;
      }
      const delay = BACKOFFS_MS[attempt];
      log.warn(`CDP connect failed (attempt ${attempt + 1}/${BACKOFFS_MS.length}): ${err.message}. Retry in ${delay}ms`);
      await new Promise((r) => setTimeout(r, delay));
      attempt++;
      if (opts.onReconnect) opts.onReconnect(attempt);
      continue;
    }

    // Wire up disconnect detection — fires lost-connection error inside work()
    let disconnected = false;
    let disconnectReject; // captured here so pidWatcher can reject the promise
    const disconnectPromise = new Promise((_resolve, reject) => {
      disconnectReject = reject;
      client.on('disconnect', () => {
        disconnected = true;
        reject(new Error('CDP_DISCONNECT: WebSocket closed'));
      });
      client.on('error', (err) => {
        disconnected = true;
        reject(new Error(`CDP_ERROR: ${err.message}`));
      });
      // Target.targetCrashed (experimental)
      try {
        client.Target.on('targetCrashed', ({ targetId }) => {
          disconnected = true;
          reject(new Error(`CDP_TARGET_CRASHED: ${targetId}`));
        });
      } catch { /* event not available */ }
    });

    // Chrome PID watcher — polls OS process every 2s, rejects if dead
    let pidWatcher = null;
    if (opts.chromePidPath) {
      pidWatcher = setInterval(() => {
        try {
          const pid = parseInt(fs.readFileSync(opts.chromePidPath, 'utf8').trim(), 10);
          if (!pid) return;
          try { process.kill(pid, 0); } // signal 0 = existence check
          catch {
            disconnected = true;
            log.error(`Chrome PID ${pid} dead (OS-level detection)`);
            disconnectReject(new Error(`CDP_CHROME_DEAD: PID ${pid}`));
          }
        } catch { /* pid file missing */ }
      }, 2000);
    }

    try {
      await Promise.race([work(client), disconnectPromise]);
      return; // work completed normally
    } catch (err) {
      log.warn(`CDP session ended: ${err.message}`);
      try { await client.close(); } catch { /* ignore */ }
      if (pidWatcher) clearInterval(pidWatcher);

      if (attempt >= BACKOFFS_MS.length) {
        log.error('CDP reconnect cap reached after session failure. Giving up.');
        if (opts.onGiveUp) opts.onGiveUp();
        throw err;
      }

      // NFR-201: 1차 즉시, 2차+ exponential backoff
      const delay = attempt === 0 ? 0 : BACKOFFS_MS[attempt];
      log.warn(`Reconnecting in ${delay}ms (attempt ${attempt + 1}/${BACKOFFS_MS.length})`);
      if (delay > 0) await new Promise((r) => setTimeout(r, delay));
      attempt++;
      if (opts.onReconnect) opts.onReconnect(attempt);
    }
  }
}
