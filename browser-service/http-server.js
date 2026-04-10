import http from 'node:http';
import { createLogger } from './logger.js';

const log = createLogger('http-server');

// Returns a Promise that resolves with the bound server after 'listening' fires.
// Using a callback in server.listen() is the correct way to wait for the OS to
// assign a port — server.address() returns null until that moment.
export function startHTTPServer({ port, handlers }) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(async (req, res) => {
      const remote = req.socket.remoteAddress;
      if (remote !== '127.0.0.1' && remote !== '::1' && remote !== '::ffff:127.0.0.1') {
        res.writeHead(403, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: 'forbidden', code: 403 }));
        return;
      }

      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', async () => {
        let parsed = null;
        if (body) {
          try { parsed = JSON.parse(body); } catch { /* ignore */ }
        }
        try {
          const result = await routeRequest(req.method, req.url, parsed, handlers);
          res.writeHead(result.status, { 'content-type': 'application/json' });
          res.end(JSON.stringify(result.body));
        } catch (err) {
          log.error(`handler threw: ${err.message}`);
          res.writeHead(500, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ error: 'internal', reason: err.message, code: 500 }));
        }
      });
    });

    server.listen(port, '127.0.0.1', () => resolve(server));
    server.on('error', reject);
  });
}

async function routeRequest(method, url, body, handlers) {
  if (method === 'GET' && url === '/status') {
    if (!handlers.status) return notFound();
    return { status: 200, body: await handlers.status() };
  }
  if (method === 'POST' && url === '/subscribe') {
    if (!handlers.subscribe) return notFound();
    return { status: 200, body: await handlers.subscribe(body || {}) };
  }
  if (method === 'POST' && url === '/unsubscribe') {
    if (!handlers.unsubscribe) return notFound();
    return { status: 200, body: await handlers.unsubscribe() };
  }
  // B8 fix: inspect mode on/off toggle (Gemini F1)
  if (method === 'POST' && url === '/toggle-inspect') {
    if (!handlers.toggleInspect) return notFound();
    return { status: 200, body: await handlers.toggleInspect(body || {}) };
  }
  if (method === 'POST' && url === '/query') {
    if (!handlers.query) return notFound();
    try { return { status: 200, body: await handlers.query(body || {}) }; }
    catch (e) { return selectorError(e); }
  }
  if (method === 'POST' && url === '/snapshot') {
    if (!handlers.snapshot) return notFound();
    try { return { status: 200, body: await handlers.snapshot(body || {}) }; }
    catch (e) { return selectorError(e); }
  }
  return notFound();
}

function notFound() {
  return { status: 404, body: { error: 'not_found', code: 404 } };
}

function selectorError(err) {
  if (err && err.code === 'SELECTOR_NOT_FOUND') {
    return { status: 404, body: { error: 'selector_not_found', reason: err.message, code: 404 } };
  }
  throw err;
}
