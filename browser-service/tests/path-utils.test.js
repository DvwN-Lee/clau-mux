import { test } from 'node:test';
import assert from 'node:assert/strict';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { validateInboxPath, InvalidInboxPathError } from '../path-utils.js';

const home = os.homedir();

test('accepts valid inbox path under ~/.claude/teams/<team>/inboxes/', () => {
  const p = path.join(home, '.claude', 'teams', 'proj', 'inboxes', 'gemini-worker.json');
  assert.doesNotThrow(() => validateInboxPath(p));
});

test('rejects path outside ~/.claude', () => {
  assert.throws(() => validateInboxPath('/tmp/evil.json'), InvalidInboxPathError);
});

test('rejects ~/.claude but not in teams/*/inboxes/', () => {
  const p = path.join(home, '.claude', 'random.json');
  assert.throws(() => validateInboxPath(p), InvalidInboxPathError);
});

test('rejects teams/*/config.json (not inboxes)', () => {
  const p = path.join(home, '.claude', 'teams', 'proj', 'config.json');
  assert.throws(() => validateInboxPath(p), InvalidInboxPathError);
});

test('rejects .. traversal via unresolved path', () => {
  const p = home + '/.claude/teams/proj/inboxes/../../../../etc/passwd.json';
  assert.throws(() => validateInboxPath(p), InvalidInboxPathError);
});

test('rejects non-json extension', () => {
  const p = path.join(home, '.claude', 'teams', 'proj', 'inboxes', 'foo.txt');
  assert.throws(() => validateInboxPath(p), InvalidInboxPathError);
});

test('rejects nested subdirectory under inboxes', () => {
  const p = path.join(home, '.claude', 'teams', 'proj', 'inboxes', 'nested', 'foo.json');
  assert.throws(() => validateInboxPath(p), InvalidInboxPathError);
});

test('accepts nested team path (e.g. repo/custom)', () => {
  const p = path.join(home, '.claude', 'teams', 'repo', 'custom', 'inboxes', 'agent.json');
  assert.doesNotThrow(() => validateInboxPath(p));
});
