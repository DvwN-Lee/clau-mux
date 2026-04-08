import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  detectChromeBinary,
  pollDevToolsActivePort,
  DevToolsPortTimeoutError,
} from '../chrome-launcher.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

test('detectChromeBinary returns string path on macOS', { skip: process.platform !== 'darwin' }, () => {
  const bin = detectChromeBinary();
  assert.ok(typeof bin === 'string');
  assert.ok(bin.includes('Chrome') || bin.includes('chrome'));
});

test('pollDevToolsActivePort reads port from file', async () => {
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'clmux-chrome-test-'));
  try {
    fs.copyFileSync(
      path.join(__dirname, 'fixtures', 'devtools-active-port.txt'),
      path.join(profileDir, 'DevToolsActivePort'),
    );
    const port = await pollDevToolsActivePort(profileDir, { timeoutMs: 500, retryIntervalMs: 50 });
    assert.equal(port, 54321);
  } finally {
    fs.rmSync(profileDir, { recursive: true, force: true });
  }
});

test('pollDevToolsActivePort throws DevToolsPortTimeoutError on timeout', async () => {
  const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'clmux-chrome-test-'));
  try {
    await assert.rejects(
      pollDevToolsActivePort(profileDir, { timeoutMs: 200, retryIntervalMs: 50 }),
      DevToolsPortTimeoutError,
    );
  } finally {
    fs.rmSync(profileDir, { recursive: true, force: true });
  }
});
