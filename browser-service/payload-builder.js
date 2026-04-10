export function buildPayload({ userIntent, pointing, sourceLocation, fingerprint, url }) {
  const payload = {
    user_intent: userIntent || '',
    pointing: {
      selector: pointing.selector,
      outerHTML: pointing.outerHTML,
      tag: pointing.tag,
      attrs: pointing.attrs || {},
      shadowPath: pointing.shadowPath || [],
      iframeChain: pointing.iframeChain || [],
    },
    source_location: sourceLocation,
    reality_fingerprint: fingerprint,
    meta: {
      timestamp: new Date().toISOString(),
      url,
    },
  };
  assertNoVisualData(payload);
  return payload;
}

/**
 * Fails loudly if the payload contains any visual / image data.
 * Enforces FR-405 — hard constraint.
 */
export function assertNoVisualData(obj) {
  const json = JSON.stringify(obj);
  const forbidden = [
    /"screenshot"\s*:/i,
    /"image"\s*:/i,
    /data:image\//i,
    /;base64,[A-Za-z0-9+/=]{40,}/,
  ];
  for (const re of forbidden) {
    if (re.test(json)) {
      const match = json.match(re);
      throw new Error(`FR-405 violation: visual data detected (matched: ${match?.[0]?.slice(0, 40)})`);
    }
  }
}
