import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildPayload, assertNoVisualData } from '../payload-builder.js';

test('buildPayload assembles all 4 top-level sections', () => {
  const payload = buildPayload({
    userIntent: 'padding 이상',
    pointing: { selector: '.card', outerHTML: '<div class="card"></div>', tag: 'div', attrs: { class: 'card' } },
    sourceLocation: { framework: 'react', file: 'src/Card.tsx', line: 42, component: 'Card', mapping_via: 'react-devtools-hook', sourceMappingConfidence: 'high', mapping_tier_used: 1 },
    fingerprint: { computed_style_subset: {}, cascade_winner: {}, bounding_box: {}, _token_budget: '<5000' },
    url: 'http://localhost:3000/dashboard',
  });

  assert.equal(payload.user_intent, 'padding 이상');
  assert.ok(payload.pointing);
  assert.ok(payload.source_location);
  assert.ok(payload.reality_fingerprint);
  assert.ok(payload.meta);
  assert.ok(payload.meta.timestamp);
  assert.equal(payload.meta.url, 'http://localhost:3000/dashboard');
});

test('buildPayload defaults empty user_intent to ""', () => {
  const payload = buildPayload({
    userIntent: null,
    pointing: { selector: '.x', outerHTML: '', tag: 'div', attrs: {} },
    sourceLocation: { framework: 'unknown', file: 'source_unknown', line: null, component: null, mapping_via: 'unknown', sourceMappingConfidence: 'none', mapping_tier_used: 4 },
    fingerprint: {},
    url: 'http://localhost:3000/',
  });
  assert.equal(payload.user_intent, '');
});

test('assertNoVisualData passes for clean payload', () => {
  const clean = { user_intent: 'x', pointing: { outerHTML: '<div></div>' } };
  assert.doesNotThrow(() => assertNoVisualData(clean));
});

test('assertNoVisualData throws when screenshot field present', () => {
  const bad = { screenshot: 'base64...' };
  assert.throws(() => assertNoVisualData(bad), /screenshot/);
});

test('assertNoVisualData throws when data:image URL present', () => {
  const bad = { user_intent: 'data:image/png;base64,abc' };
  assert.throws(() => assertNoVisualData(bad), /data:image/);
});
