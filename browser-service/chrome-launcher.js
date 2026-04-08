import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

const MACOS_PATHS = [
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
];

const LINUX_PATHS = [
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium-browser',
  '/usr/bin/chromium',
];

export class ChromeBinaryNotFoundError extends Error {
  constructor() {
    super('Chrome/Chromium binary not found. Install Google Chrome or set CHROME_BIN env var.');
    this.name = 'ChromeBinaryNotFoundError';
  }
}

export class DevToolsPortTimeoutError extends Error {
  constructor(profileDir) {
    super(`DevToolsActivePort file not created within timeout: ${profileDir}`);
    this.name = 'DevToolsPortTimeoutError';
  }
}

export function detectChromeBinary() {
  if (process.env.CHROME_BIN && fs.existsSync(process.env.CHROME_BIN)) {
    return process.env.CHROME_BIN;
  }
  const candidates = process.platform === 'darwin' ? MACOS_PATHS : LINUX_PATHS;
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  throw new ChromeBinaryNotFoundError();
}

export async function pollDevToolsActivePort(profileDir, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 5000;
  const retryIntervalMs = opts.retryIntervalMs ?? 200;
  const portFile = path.join(profileDir, 'DevToolsActivePort');
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    if (fs.existsSync(portFile)) {
      try {
        const content = fs.readFileSync(portFile, 'utf8');
        const firstLine = content.split('\n')[0].trim();
        const port = parseInt(firstLine, 10);
        if (!isNaN(port) && port > 0) return port;
      } catch { /* retry */ }
    }
    await new Promise((r) => setTimeout(r, retryIntervalMs));
  }
  throw new DevToolsPortTimeoutError(profileDir);
}

export async function launchChrome({ teamDir, profileDir, logPath }) {
  fs.mkdirSync(profileDir, { recursive: true });
  const stalePort = path.join(profileDir, 'DevToolsActivePort');
  if (fs.existsSync(stalePort)) fs.unlinkSync(stalePort);

  const chromeBin = detectChromeBinary();
  const logFd = fs.openSync(logPath, 'a');

  const proc = spawn(chromeBin, [
    '--remote-debugging-port=0',
    `--user-data-dir=${profileDir}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-default-apps',
    '--disable-background-networking',
    '--disable-component-update',
    '--disable-sync',
    'about:blank',
  ], { detached: true, stdio: ['ignore', logFd, logFd] });
  proc.unref();

  const port = await pollDevToolsActivePort(profileDir, { timeoutMs: 5000, retryIntervalMs: 200 });
  const endpoint = `ws://127.0.0.1:${port}`;

  // B1 fix: Chrome CDP port written to .chrome-debug.port (NOT .browser-service.port).
  // .browser-service.port is reserved for the Node HTTP server (written by browser-service.js).
  const chromePidPath = path.join(teamDir, '.chrome.pid');
  const chromeDebugPortPath = path.join(teamDir, '.chrome-debug.port');
  fs.writeFileSync(chromePidPath, String(proc.pid), { mode: 0o600 });
  fs.writeFileSync(chromeDebugPortPath, String(port), { mode: 0o600 });
  // M6 fix: explicit chmod on overwrite
  try {
    fs.chmodSync(chromePidPath, 0o600);
    fs.chmodSync(chromeDebugPortPath, 0o600);
  } catch { /* best-effort */ }

  return { endpoint, pid: proc.pid, port };
}
