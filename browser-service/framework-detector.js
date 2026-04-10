/**
 * Returns a JS expression that runs in the browser page context
 * and returns 'react' | 'vue' | 'svelte' | 'solid' | 'unknown'.
 */
export function buildDetectionExpression() {
  return `
    (() => {
      try {
        const bodyChild = document.body && document.body.firstElementChild;
        if (bodyChild) {
          const keys = Object.keys(bodyChild);
          if (keys.some(k => k.startsWith('__reactFiber$'))) return 'react';
          if (bodyChild.__vue__) return 'vue';
        }
        if (document.body && document.body.__vue_app__) return 'vue';
        if (document.querySelector && document.querySelector('[data-source-loc]')) return 'solid';
        const anyEl = document.body && document.body.querySelector('*');
        if (anyEl && anyEl.__svelte_meta) return 'svelte';
        return 'unknown';
      } catch (e) { return 'unknown'; }
    })()
  `;
}

const VALID = new Set(['react', 'vue', 'svelte', 'solid']);

export function parseDetectionResult(value) {
  if (typeof value === 'string' && VALID.has(value)) return value;
  return 'unknown';
}
