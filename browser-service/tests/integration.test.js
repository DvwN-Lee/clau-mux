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
