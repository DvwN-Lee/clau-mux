import fs from 'node:fs';
import path from 'node:path';

const SUB_FILE = '.inspect-subscriber';
const POLL_INTERVAL_MS = 2000;

export function readSubscriber(teamDir) {
  const file = path.join(teamDir, SUB_FILE);
  try {
    const content = fs.readFileSync(file, 'utf8').trim();
    return content.length > 0 ? content : null;
  } catch {
    return null;
  }
}

export function writeSubscriber(teamDir, agent) {
  const file = path.join(teamDir, SUB_FILE);
  fs.writeFileSync(file, agent, { mode: 0o600 });
  // M6 fix: explicit chmod — mode option only affects creation
  try { fs.chmodSync(file, 0o600); } catch { /* best-effort */ }
}

export function watchSubscriber(teamDir, onChange) {
  const file = path.join(teamDir, SUB_FILE);
  let lastValue = readSubscriber(teamDir);
  onChange(lastValue);

  let watcher = null;
  let pollTimer = null;
  let stopped = false;

  const check = () => {
    if (stopped) return;
    const current = readSubscriber(teamDir);
    if (current !== lastValue) {
      lastValue = current;
      onChange(current);
    }
  };

  const tryFsWatch = () => {
    try {
      watcher = fs.watch(file, { persistent: false }, check);
      watcher.on('error', () => {
        if (watcher) watcher.close();
        watcher = null;
        startPolling();
      });
    } catch {
      startPolling();
    }
  };

  const startPolling = () => {
    pollTimer = setInterval(check, POLL_INTERVAL_MS);
  };

  if (fs.existsSync(file)) {
    tryFsWatch();
  } else {
    startPolling();
    try {
      const dirWatcher = fs.watch(teamDir, { persistent: false }, (_event, name) => {
        if (name === SUB_FILE && fs.existsSync(file)) {
          dirWatcher.close();
          if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
          tryFsWatch();
          check();
        }
      });
    } catch { /* directory doesn't exist yet */ }
  }

  return () => {
    stopped = true;
    if (watcher) watcher.close();
    if (pollTimer) clearInterval(pollTimer);
  };
}
