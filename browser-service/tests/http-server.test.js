import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { startHTTPServer } from '../http-server.js';

function httpJson(port, method, pathname, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const req = http.request({
      hostname: '127.0.0.1', port, path: pathname, method,
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) },
    }, (res) => {
      let chunks = '';
      res.on('data', (c) => (chunks += c));
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: chunks ? JSON.parse(chunks) : null }); }
        catch { resolve({ status: res.statusCode, body: chunks }); }
      });
    });
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

test('GET /status returns running', async () => {
  const handlers = {
    status: async () => ({ status: 'running', subscriber: 'gemini-worker', chrome_pid: 1234, uptime: 10, last_payload_at: null }),
  };
  const server = await startHTTPServer({ port: 0, handlers });
  const port = server.address().port;
  try {
    const res = await httpJson(port, 'GET', '/status');
    assert.equal(res.status, 200);
    assert.equal(res.body.status, 'running');
    assert.equal(res.body.subscriber, 'gemini-worker');
  } finally {
    server.close();
  }
});

test('POST /subscribe accepts agent name', async () => {
  const handlers = {
    subscribe: async ({ agent }) => ({ ok: true, agent }),
  };
  const server = await startHTTPServer({ port: 0, handlers });
  const port = server.address().port;
  try {
    const res = await httpJson(port, 'POST', '/subscribe', { agent: 'gemini-worker' });
    assert.equal(res.status, 200);
    assert.equal(res.body.ok, true);
    assert.equal(res.body.agent, 'gemini-worker');
  } finally {
    server.close();
  }
});

test('unknown route returns 404', async () => {
  const server = await startHTTPServer({ port: 0, handlers: {} });
  const port = server.address().port;
  try {
    const res = await httpJson(port, 'GET', '/nope');
    assert.equal(res.status, 404);
  } finally {
    server.close();
  }
});

test('server binds to 127.0.0.1 only', async () => {
  const server = await startHTTPServer({ port: 0, handlers: {} });
  const addr = server.address();
  assert.equal(addr.address, '127.0.0.1');
  server.close();
});
