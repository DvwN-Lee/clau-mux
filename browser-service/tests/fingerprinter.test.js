import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  TRACKED_STYLE_PROPS,
  extractCascadeWinner,
  computeSubsetFromComputedStyles,
  truncateOuterHTML,
  estimateTokenCount,
} from '../fingerprinter.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

test('TRACKED_STYLE_PROPS contains 12 core properties', () => {
  assert.equal(TRACKED_STYLE_PROPS.length, 12);
  assert.ok(TRACKED_STYLE_PROPS.includes('padding'));
  assert.ok(TRACKED_STYLE_PROPS.includes('color'));
  assert.ok(TRACKED_STYLE_PROPS.includes('display'));
});

test('extractCascadeWinner picks last-wins per property', () => {
  const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, 'fixtures', 'sample-matched-styles.json'),
    'utf8'
  ));
  const winner = extractCascadeWinner(fixture.matchedCSSRules, ['padding']);
  assert.ok(winner.padding);
  assert.match(winner.padding, /card--highlighted/);
  assert.match(winner.padding, /src\/styles\/card\.css/);
});

test('extractCascadeWinner ignores properties not in tracked list', () => {
  const fixture = JSON.parse(fs.readFileSync(
    path.join(__dirname, 'fixtures', 'sample-matched-styles.json'),
    'utf8'
  ));
  const winner = extractCascadeWinner(fixture.matchedCSSRules, ['margin']);
  assert.deepEqual(winner, {});
});

test('computeSubsetFromComputedStyles returns only tracked props', () => {
  const computed = [
    { name: 'padding', value: '12px' },
    { name: 'background-image', value: 'url(foo.png)' },
    { name: 'color', value: 'rgb(0, 0, 0)' },
    { name: 'display', value: 'flex' },
  ];
  const subset = computeSubsetFromComputedStyles(computed);
  assert.equal(subset.padding, '12px');
  assert.equal(subset.color, 'rgb(0, 0, 0)');
  assert.equal(subset.display, 'flex');
  assert.equal(subset['background-image'], undefined);
});

test('computeSubsetFromComputedStyles redacts base64 data URLs in values (B9)', () => {
  const computed = [
    { name: 'background-color', value: 'url(data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQMAAAAl21bKAAAABlBMVEUAAADFEx0hAAAAAXRSTlMAQObYZgAAAApJREFUCNdjYAAAAAIAAeIhvDMAAAAASUVORK5CYII=) rgb(0,0,0)' },
  ];
  const subset = computeSubsetFromComputedStyles(computed);
  assert.ok(subset['background-color'].includes('[REDACTED]'));
  assert.ok(!subset['background-color'].includes('iVBORw'));
});

test('truncateOuterHTML limits to 500 chars and strips script tags', () => {
  const html = '<div>' + 'a'.repeat(1000) + '<script>evil()</script>' + '</div>';
  const result = truncateOuterHTML(html);
  assert.ok(result.length <= 520);
  assert.ok(!result.includes('<script'));
});

test('estimateTokenCount returns positive number roughly proportional to length', () => {
  const short = estimateTokenCount('hello');
  const long = estimateTokenCount('hello '.repeat(1000));
  assert.ok(short > 0);
  assert.ok(long > short * 100);
});
