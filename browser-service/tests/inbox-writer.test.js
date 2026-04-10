import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { writeToInbox, MAX_ENTRIES } from '../inbox-writer.js';

let tmpHome;
let teamDir;
let originalHome;

beforeEach(() => {
  originalHome = process.env.HOME;
  tmpHome = fs.mkdtempSync(path.join(os.tmpdir(), 'clmux-test-'));
  process.env.HOME = tmpHome;
  teamDir = path.join(tmpHome, '.claude', 'teams', 'test-team');
  fs.mkdirSync(path.join(teamDir, 'inboxes'), { recursive: true });
});

afterEach(() => {
  process.env.HOME = originalHome;
  fs.rmSync(tmpHome, { recursive: true, force: true });
});

test('appends entry to empty inbox', () => {
  const payload = { user_intent: 'padding 이상', pointing: {}, source_location: {}, reality_fingerprint: {} };
  writeToInbox(teamDir, 'gemini-worker', payload);

  const inbox = path.join(teamDir, 'inboxes', 'gemini-worker.json');
  const entries = JSON.parse(fs.readFileSync(inbox, 'utf8'));
  assert.equal(entries.length, 1);
  assert.equal(entries[0].from, 'browser-inspect');
  assert.match(entries[0].summary, /browser-inspect:/);
  assert.ok(entries[0].text);
});

test('atomic write does not leave .tmp files on success', () => {
  writeToInbox(teamDir, 'gemini-worker', { user_intent: 'test' });
  const files = fs.readdirSync(path.join(teamDir, 'inboxes'));
  assert.deepEqual(files.filter(f => f.endsWith('.tmp')), []);
});

test('caps at MAX_ENTRIES (50)', () => {
  for (let i = 0; i < MAX_ENTRIES + 10; i++) {
    writeToInbox(teamDir, 'gemini-worker', { user_intent: `msg ${i}` });
  }
  const entries = JSON.parse(fs.readFileSync(path.join(teamDir, 'inboxes', 'gemini-worker.json'), 'utf8'));
  assert.equal(entries.length, MAX_ENTRIES);
  assert.match(entries[MAX_ENTRIES - 1].text, /msg 59/);
});

test('file permission 0600 after write', () => {
  writeToInbox(teamDir, 'gemini-worker', { user_intent: 'test' });
  const mode = fs.statSync(path.join(teamDir, 'inboxes', 'gemini-worker.json')).mode & 0o777;
  assert.equal(mode, 0o600);
});

test('rejects path outside ~/.claude', () => {
  assert.throws(() => writeToInbox('/tmp/evil', 'worker', {}));
});
