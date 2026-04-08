import { test } from 'node:test';
import assert from 'node:assert/strict';
import { formatLogLine, createLogger } from '../logger.js';

test('formatLogLine produces ISO-timestamp [LEVEL] [component] message format', () => {
  const line = formatLogLine({
    level: 'INFO',
    component: 'overlay-manager',
    message: 'inspect mode enabled',
    timestamp: '2026-04-08T10:23:41.123Z',
  });
  assert.equal(line, '[2026-04-08T10:23:41.123Z] [INFO] [overlay-manager] inspect mode enabled');
});

test('createLogger debug() is no-op when CLMUX_DEBUG not set', (t) => {
  const prev = process.env.CLMUX_DEBUG;
  t.after(() => {
    if (prev === undefined) delete process.env.CLMUX_DEBUG;
    else process.env.CLMUX_DEBUG = prev;
  });
  delete process.env.CLMUX_DEBUG;
  const messages = [];
  const logger = createLogger('test', { sink: (line) => messages.push(line) });
  logger.debug('secret payload');
  assert.equal(messages.length, 0);
});

test('createLogger debug() emits when CLMUX_DEBUG=1', (t) => {
  const prev = process.env.CLMUX_DEBUG;
  t.after(() => {
    if (prev === undefined) delete process.env.CLMUX_DEBUG;
    else process.env.CLMUX_DEBUG = prev;
  });
  process.env.CLMUX_DEBUG = '1';
  const messages = [];
  const logger = createLogger('test', { sink: (line) => messages.push(line) });
  logger.debug('visible');
  assert.equal(messages.length, 1);
  assert.match(messages[0], /\[DEBUG\] \[test\] visible/);
});
