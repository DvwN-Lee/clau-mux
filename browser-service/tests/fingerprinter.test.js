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
  redactSensitiveAttrs,
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

test('redactSensitiveAttrs redacts password attr value', () => {
  const result = redactSensitiveAttrs('<input password="s3cr3t">');
  assert.equal(result, '<input password="[REDACTED]">');
});

test('redactSensitiveAttrs redacts token attr value', () => {
  const result = redactSensitiveAttrs('<meta token=\'Bearer abc\'>');
  assert.equal(result, '<meta token=\'[REDACTED]\'>');
});

test('redactSensitiveAttrs redacts api_key attr value', () => {
  const result = redactSensitiveAttrs('<div api_key="sk-123">');
  assert.equal(result, '<div api_key="[REDACTED]">');
});

test('redactSensitiveAttrs redacts Authorization attr value (case-insensitive)', () => {
  const result = redactSensitiveAttrs('<div Authorization="token xyz">');
  assert.equal(result, '<div Authorization="[REDACTED]">');
});

test('redactSensitiveAttrs preserves non-sensitive attrs like class, id, data-foo', () => {
  const html = '<div class="hero" id="main" data-foo="bar">';
  assert.equal(redactSensitiveAttrs(html), html);
});

test('truncateOuterHTML redacts password/token/secret attrs (NFR-304)', () => {
  const html = '<input type="password" value="hunter2"> <div data-token="Bearer abc123">';
  const result = truncateOuterHTML(html);
  assert.ok(!result.includes('hunter2'));
  assert.ok(!result.includes('abc123'));
  assert.ok(result.includes('[REDACTED]'));
});

test('truncateOuterHTML redacts before truncating (integration)', () => {
  const secret = 'sk-' + 'x'.repeat(600);
  const html = `<input token="${secret}">`;
  const result = truncateOuterHTML(html);
  assert.ok(!result.includes(secret));
  assert.ok(result.includes('[REDACTED]'));
});
