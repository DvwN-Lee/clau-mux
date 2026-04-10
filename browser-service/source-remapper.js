/**
 * Multi-tier source remapper.
 * Tier 1: framework runtime hook (React/Vue/Svelte/Solid)
 * Tier 2: build-time injected data-source-file attribute
 * Tier 4: honest failure (source_unknown)
 * Tier 3 (source-map stacktrace) deferred per R4.
 *
 * Framework hook patterns referenced from (M3 OSS citation):
 *   - svelte-grab: https://github.com/PuruVJ/svelte-grab (svelte-inspector pattern)
 *   - react-dev-inspector: https://github.com/zthxxx/react-dev-inspector (data-inspector-* attrs)
 *   - vite-plugin-vue-inspector: https://github.com/webfansplz/vite-plugin-vue-inspector
 *   - @solid-devtools/locator: https://github.com/thetarnav/solid-devtools
 * See R1 OSS survey (docs/superpowers/research/01-existing-tools-survey.md) for full list.
 */

export function buildReactExtractionExpression() {
  return `
    (() => {
      const el = window.__clmux_inspected_node;
      if (!el) return null;
      const fiberKey = Object.keys(el).find(k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$'));
      if (!fiberKey) return null;
      const fiber = el[fiberKey];
      let src = fiber && fiber._debugSource;
      let component = fiber && fiber.type && (fiber.type.displayName || fiber.type.name);
      let via = 'react-devtools-hook';
      if (!src && fiber && fiber._debugOwner) {
        let owner = fiber._debugOwner;
        while (owner && !owner._debugSource) owner = owner._debugOwner;
        if (owner && owner._debugSource) {
          src = owner._debugSource;
          component = owner.type && (owner.type.displayName || owner.type.name);
          via = 'react-devtools-hook-debugOwner';
        }
      }
      if (!src) return null;
      let props = null;
      try {
        if (fiber.memoizedProps && typeof fiber.memoizedProps === 'object') {
          const SAFE_PROPS = new Set(['className', 'id', 'style', 'role', 'type', 'disabled', 'placeholder', 'href', 'src', 'alt', 'name', 'value']);
          props = {};
          for (const k of Object.keys(fiber.memoizedProps)) {
            if (SAFE_PROPS.has(k)) {
              const v = fiber.memoizedProps[k];
              props[k] = typeof v === 'string' && v.length > 100 ? v.slice(0, 100) + '…' : v;
            }
          }
        }
      } catch { /* ignore */ }
      return {
        file: src.fileName, line: src.lineNumber, col: src.columnNumber,
        component, props, via,
      };
    })()
  `;
}

export function buildVueExtractionExpression() {
  return `
    (() => {
      const el = window.__clmux_inspected_node;
      if (!el) return null;
      if (el.__vue__) {
        const vm = el.__vue__;
        const file = vm.$options && vm.$options.__file;
        if (file) return { file, line: null, col: null, component: vm.$options.name || null, via: 'vue2-__vue__' };
      }
      let parent = el.__vueParentComponent;
      if (parent) {
        const file = parent.type && parent.type.__file;
        if (file) return { file, line: null, col: null, component: parent.type.name || null, via: 'vue3-component' };
      }
      return null;
    })()
  `;
}

export function buildSvelteExtractionExpression() {
  return `
    (() => {
      const el = window.__clmux_inspected_node;
      if (!el || !el.__svelte_meta) return null;
      const loc = el.__svelte_meta.loc;
      if (!loc) return null;
      return { file: loc.file, line: loc.line || null, col: loc.column || null, component: null, via: 'svelte-meta' };
    })()
  `;
}

export function buildSolidExtractionExpression() {
  return `
    (() => {
      const el = window.__clmux_inspected_node;
      if (!el) return null;
      const attr = el.getAttribute && el.getAttribute('data-source-loc');
      if (!attr) return null;
      const parts = attr.split(':');
      const col = parseInt(parts.pop(), 10);
      const line = parseInt(parts.pop(), 10);
      const file = parts.join(':');
      return { file, line: isNaN(line) ? null : line, col: isNaN(col) ? null : col, component: null, via: 'solid-locator' };
    })()
  `;
}

export function buildDataSourceExtractionExpression() {
  return `
    (() => {
      let el = window.__clmux_inspected_node;
      if (!el) return null;
      while (el && el.nodeType === 1) {
        const file = el.getAttribute && (el.getAttribute('data-source-file') || el.getAttribute('data-inspector-relative-path'));
        if (file) {
          const line = el.getAttribute('data-source-line') || el.getAttribute('data-inspector-line');
          const col = el.getAttribute('data-source-column') || el.getAttribute('data-inspector-column');
          const component = el.getAttribute('data-inspector-component-name') || null;
          return {
            file, line: line ? parseInt(line, 10) : null, col: col ? parseInt(col, 10) : null,
            component, via: 'data-source-attr',
          };
        }
        el = el.parentElement;
      }
      return null;
    })()
  `;
}

export function honestUnknown(framework, reason) {
  return {
    framework,
    file: 'source_unknown',
    line: null,
    component: null,
    mapping_via: 'unknown',
    sourceMappingConfidence: 'none',
    fallbackReason: reason,
    mapping_tier_used: 4,
  };
}

export async function resolveSourceLocation(session, framework) {
  let tier1Expr;
  if (framework === 'react') tier1Expr = buildReactExtractionExpression();
  else if (framework === 'vue') tier1Expr = buildVueExtractionExpression();
  else if (framework === 'svelte') tier1Expr = buildSvelteExtractionExpression();
  else if (framework === 'solid') tier1Expr = buildSolidExtractionExpression();

  if (tier1Expr) {
    try {
      const r = await session.Runtime.evaluate({ expression: tier1Expr, returnByValue: true });
      if (r.result && r.result.value) {
        const v = r.result.value;
        return {
          framework,
          file: v.file,
          line: v.line,
          component: v.component || null,
          props: v.props || null,
          mapping_via: v.via,
          sourceMappingConfidence: v.line ? 'high' : 'medium',
          fallbackReason: null,
          mapping_tier_used: 1,
        };
      }
    } catch { /* fall through */ }
  }

  try {
    const r = await session.Runtime.evaluate({ expression: buildDataSourceExtractionExpression(), returnByValue: true });
    if (r.result && r.result.value) {
      const v = r.result.value;
      return {
        framework,
        file: v.file,
        line: v.line,
        component: v.component,
        mapping_via: 'data-source-attr',
        sourceMappingConfidence: v.line ? 'medium' : 'low',
        fallbackReason: framework === 'react' ? 'react19-no-debugSource-or-no-runtime-hook' : 'tier1-unavailable',
        mapping_tier_used: 2,
      };
    }
  } catch { /* fall through */ }

  return honestUnknown(framework, 'no source metadata found (all tiers exhausted)');
}
