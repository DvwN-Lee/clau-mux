import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

test('daemon exits 2 when required args missing', async () => {
  const result = await new Promise((resolve) => {
    const proc = spawn('node', ['browser-service/browser-service.js'], { stdio: 'pipe' });
    let stderr = '';
    proc.stderr.on('data', (c) => (stderr += c));
    proc.on('exit', (code) => resolve({ code, stderr }));
  });
  assert.equal(result.code, 2);
  assert.match(result.stderr, /usage/);
});

test('core modules import successfully', async () => {
  const modules = [
    '../logger.js', '../path-utils.js', '../inbox-writer.js',
    '../subscription-watcher.js', '../framework-detector.js',
    '../source-remapper.js', '../fingerprinter.js',
    '../payload-builder.js', '../http-server.js',
    '../cdp-client.js', '../overlay-manager.js',
  ];
  for (const mod of modules) {
    const m = await import(mod);
    assert.ok(m, `${mod} should import`);
  }
});

test('cdp-client exports initCDPClient and withReconnect', async () => {
  const { initCDPClient, withReconnect } = await import('../cdp-client.js');
  assert.equal(typeof initCDPClient, 'function');
  assert.equal(typeof withReconnect, 'function');
});

test('overlay-manager exports installOverlay, setInspectMode, setOverlayLabel', async () => {
  const { installOverlay, setInspectMode, setOverlayLabel } = await import('../overlay-manager.js');
  assert.equal(typeof installOverlay, 'function');
  assert.equal(typeof setInspectMode, 'function');
  assert.equal(typeof setOverlayLabel, 'function');
});

test('fingerprinter exports enforceTokenBudget', async () => {
  const { enforceTokenBudget } = await import('../fingerprinter.js');
  assert.equal(typeof enforceTokenBudget, 'function');
  const result = enforceTokenBudget({ small: true });
  assert.equal(typeof result.ok, 'boolean');
  assert.equal(typeof result.tokenCount, 'number');
});
