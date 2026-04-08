import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { watchSubscriber, readSubscriber, writeSubscriber } from '../subscription-watcher.js';

let teamDir;

beforeEach(() => {
  teamDir = fs.mkdtempSync(path.join(os.tmpdir(), 'clmux-sub-'));
});
afterEach(() => {
  fs.rmSync(teamDir, { recursive: true, force: true });
});

test('readSubscriber returns null when file missing', () => {
  assert.equal(readSubscriber(teamDir), null);
});

test('writeSubscriber + readSubscriber round-trip', () => {
  writeSubscriber(teamDir, 'gemini-worker');
  assert.equal(readSubscriber(teamDir), 'gemini-worker');
});

test('writeSubscriber creates file with 0600 permission', () => {
  writeSubscriber(teamDir, 'codex-worker');
  const mode = fs.statSync(path.join(teamDir, '.inspect-subscriber')).mode & 0o777;
  assert.equal(mode, 0o600);
});

test('writeSubscriber("") clears subscriber', () => {
  writeSubscriber(teamDir, 'gemini-worker');
  writeSubscriber(teamDir, '');
  assert.equal(readSubscriber(teamDir), null);
});

test('watchSubscriber fires onChange when file updated', async () => {
  const changes = [];
  const stop = watchSubscriber(teamDir, (sub) => changes.push(sub));
  await new Promise((r) => setTimeout(r, 100));
  writeSubscriber(teamDir, 'gemini-worker');
  await new Promise((r) => setTimeout(r, 300));
  stop();
  assert.ok(changes.includes('gemini-worker'), `expected gemini-worker in ${JSON.stringify(changes)}`);
});
