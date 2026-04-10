import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  buildReactExtractionExpression,
  buildVueExtractionExpression,
  buildSvelteExtractionExpression,
  buildSolidExtractionExpression,
  buildDataSourceExtractionExpression,
  honestUnknown,
} from '../source-remapper.js';

test('buildReactExtractionExpression references __reactFiber and _debugSource', () => {
  const expr = buildReactExtractionExpression();
  assert.ok(expr.includes('__reactFiber$'));
  assert.ok(expr.includes('_debugSource'));
});

test('buildVueExtractionExpression references __vue__', () => {
  const expr = buildVueExtractionExpression();
  assert.ok(expr.includes('__vue__'));
  assert.ok(expr.includes('__file'));
});

test('buildSvelteExtractionExpression references __svelte_meta.loc', () => {
  const expr = buildSvelteExtractionExpression();
  assert.ok(expr.includes('__svelte_meta'));
  assert.ok(expr.includes('loc'));
});

test('buildSolidExtractionExpression references data-source-loc', () => {
  const expr = buildSolidExtractionExpression();
  assert.ok(expr.includes('data-source-loc'));
});

test('buildDataSourceExtractionExpression references data-source-file attr', () => {
  const expr = buildDataSourceExtractionExpression();
  assert.ok(expr.includes('data-source-file') || expr.includes('data-inspector'));
});

test('honestUnknown returns valid source_location with confidence none', () => {
  const result = honestUnknown('react', 'no metadata found');
  assert.equal(result.framework, 'react');
  assert.equal(result.file, 'source_unknown');
  assert.equal(result.line, null);
  assert.equal(result.sourceMappingConfidence, 'none');
  assert.equal(result.fallbackReason, 'no metadata found');
  assert.equal(result.mapping_tier_used, 4);
});
