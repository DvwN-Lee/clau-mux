import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildDetectionExpression, parseDetectionResult } from '../framework-detector.js';

test('buildDetectionExpression returns executable JS string', () => {
  const expr = buildDetectionExpression();
  assert.ok(typeof expr === 'string');
  assert.ok(expr.includes('__reactFiber'));
  assert.ok(expr.includes('__vue__'));
  assert.ok(expr.includes('__svelte_meta'));
});

test('parseDetectionResult recognizes react', () => {
  assert.equal(parseDetectionResult('react'), 'react');
});

test('parseDetectionResult recognizes vue', () => {
  assert.equal(parseDetectionResult('vue'), 'vue');
});

test('parseDetectionResult returns "unknown" on null/empty', () => {
  assert.equal(parseDetectionResult(null), 'unknown');
  assert.equal(parseDetectionResult(''), 'unknown');
  assert.equal(parseDetectionResult('garbage'), 'unknown');
});
