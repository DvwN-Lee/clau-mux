/**
 * Reality Fingerprinter.
 * Target: entire fingerprint <5,000 tokens (FR-402). NO screenshots (FR-405).
 *
 * M3 OSS citation: The 12-property subset + accessibility tree approach is
 * inspired by Zendriver-MCP's token optimization technique (96% reduction from
 * full DOM dump → accessibility tree). See R3 research
 * (docs/superpowers/research/03-github-ecosystem-survey.md).
 */

// M3: 12-property subset from Zendriver-MCP-inspired optimization.
// Covers box model (4), typography (2), color (2), layout (2), visibility (2) = 12 total.
export const TRACKED_STYLE_PROPS = [
  'display', 'position', 'width', 'height',
  'color', 'background-color', 'font-size', 'font-weight',
  'padding', 'margin', 'opacity', 'z-index',
];

const OUTER_HTML_LIMIT = 500;

export function redactSensitiveAttrs(html) {
  if (!html) return html;
  // Pass 1: redact explicitly named sensitive attributes (handles data-token, api_key, etc.)
  let result = html.replace(
    /(\b(?:password|token|secret|api[_-]?key|authorization)\b)([\s]*[=:][\s]*)(["'])((?:(?!\3)[^])*)\3/gi,
    (m, attr, eq, q, val) => `${attr}${eq}${q}[REDACTED]${q}`,
  );
  // Pass 2 (NFR-304): redact value attribute on password-type inputs
  result = result.replace(
    /(<input[^>]*\btype=(["'])password\2[^>]*)\bvalue=(["'])[^"']*\3/gi,
    (m, prefix, q1, q2) => `${prefix}value=${q2}[REDACTED]${q2}`,
  );
  return result;
}

export function truncateOuterHTML(html) {
  if (!html) return '';
  let cleaned = html.replace(/<script[\s\S]*?<\/script>/gi, '<!--script-stripped-->');
  cleaned = redactSensitiveAttrs(cleaned);
  if (cleaned.length > OUTER_HTML_LIMIT) {
    cleaned = cleaned.slice(0, OUTER_HTML_LIMIT) + '...[truncated]';
  }
  return cleaned;
}

/**
 * Filters out base64 data: URLs embedded in computed style values.
 * B9 fix (Gemini F5): `background-image: url(data:image/png;base64,...)` can leak
 * large inline images into the payload, wasting tokens and potentially exposing secrets.
 * @param {string} value
 * @returns {string}
 */
export function redactBase64DataUrl(value) {
  if (typeof value !== 'string') return value;
  // Replace data:image/*;base64,<content> with data:image/*;base64,[REDACTED]
  return value.replace(
    /data:image\/[a-z.+-]+;base64,[A-Za-z0-9+/=]+/gi,
    'data:image/*;base64,[REDACTED]',
  );
}

export function computeSubsetFromComputedStyles(computed) {
  const subset = {};
  const tracked = new Set(TRACKED_STYLE_PROPS);
  for (const { name, value } of computed) {
    if (tracked.has(name)) {
      // B9 fix: strip inline base64 data URLs before inclusion (FR-405 intent: no visual data)
      subset[name] = redactBase64DataUrl(value);
    }
  }
  return subset;
}

export function extractCascadeWinner(matchedRules, trackedProps) {
  const tracked = new Set(trackedProps);
  const winner = {};
  for (const matched of matchedRules) {
    const rule = matched.rule;
    if (!rule || !rule.style || !rule.style.cssProperties) continue;
    for (const decl of rule.style.cssProperties) {
      if (!tracked.has(decl.name)) continue;
      if (decl.disabled) continue;
      const sheet = rule.styleSheetId || 'inline';
      const range = rule.style.range;
      const loc = range ? `${sheet}:${range.startLine}` : sheet;
      const selectorText = rule.selectorList && rule.selectorList.text ? rule.selectorList.text : '';
      winner[decl.name] = `${loc} (${selectorText})`;
    }
  }
  return winner;
}

export function estimateTokenCount(text) {
  if (!text) return 0;
  return Math.ceil(text.length / 4);
}

export function buildFingerprint(ctx) {
  return {
    computed_style_subset: computeSubsetFromComputedStyles(ctx.computedStyle || []),
    cascade_winner: extractCascadeWinner(ctx.matchedRules || [], TRACKED_STYLE_PROPS),
    bounding_box: ctx.boundingBox || { x: 0, y: 0, w: 0, h: 0 },
    viewport: ctx.viewport || { w: 0, h: 0 },
    scroll_offsets: ctx.scrollOffsets || { x: 0, y: 0 },
    device_pixel_ratio: ctx.devicePixelRatio || 1,
    ax_role_name: ctx.axRoleName || 'generic',
    ax_accessible_name: ctx.axAccessibleName || null,
    _token_budget: '<5000',
  };
}

export function enforceTokenBudget(payload) {
  const json = JSON.stringify(payload);
  const tokenCount = estimateTokenCount(json);
  return { ok: tokenCount < 5000, tokenCount };
}
