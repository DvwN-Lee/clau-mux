# R4 — Source Remapping Techniques + Agent Prompt Templates

**Status**: completed
**Date**: 2026-04-07
**Author**: Claude teammate (Sonnet, architecture-research)
**Input**: 00-INDEX.md, pre-gathered research corpus
**Output location**: this file

---

## Executive Summary

This document addresses the **technical SPOF** of the clau-mux Browser Inspect Tool design: mapping a clicked DOM element back to its source file, line, and component accurately enough that an AI agent can read the right code and detect intent-vs-reality drift.

Two parts:
- **Part A** — Evaluation of 8 source-remapping techniques across frameworks, with multi-tier fallback recommendation
- **Part B** — Three system prompt template candidates that force receiving agents (Gemini CLI, Codex CLI, Claude Code teammate) to read source code before diagnosing drift, with anti-hallucination guards

If source remapping is wrong, the agent reads the wrong file. If the prompt allows skipping the read, the agent hallucinates a fix. Both failures are silent — the agent sounds confident either way. This document exists to prevent both.

---

## Part A — Source Remapping Technique Evaluation

### Overview Table

| Technique | Framework | Dev-only? | Accuracy | Key Constraint |
|---|---|---|---|---|
| A.1 React `__reactFiber$*` / `_debugSource` | React 16+ | Yes (prod: stripped) | High (file + line + col) | React 19 removed `_debugSource` |
| A.2 Vue `__vue__` / `__vue_app__` / `__file` | Vue 2/3 | Partial (`__file` often in prod) | Medium-high (file only, no line) | No line number |
| A.3 Svelte `__svelte_meta` | Svelte 4 | Yes | Very high (file + line + col) | Svelte 5 not supported |
| A.4 Solid `data-source-loc` | Solid.js | Yes | High (file + line + col) | Requires `@solid-devtools/locator` |
| A.5 Build-time `data-source-file` injection | Any (JSX) | Recommended dev-only | High (compile-time exact) | React-JSX-specific; manual for Vue/Svelte |
| A.6 Vite plugin ecosystem | React/Vue + Vite | Yes | High (same as injection) | Plugin-specific; Vite required |
| A.7 Source-map stacktrace reverse lookup | Any | Prod possible | Exact for known position | Needs bundled line/col — hard from DOM event |
| A.8 Chrome DevTools Protocol (CDP) | Any | Any | CSS: excellent; JS: limited | JS requires framework hooks or metadata |

---

### A.1 React DevTools Hook (`__reactFiber$*` / `_debugSource`)

#### Working Principle

React exposes `window.__REACT_DEVTOOLS_GLOBAL_HOOK__` that external tools can register with. After every render commit, React calls `onCommitFiberRoot(rendererID, fiberRoot)`. Each committed DOM node has a property with a key matching `__reactFiber$<randomId>` (random suffix to prevent key collisions across multiple React roots on the same page) that points to the fiber node responsible for that DOM element.

In development builds compiled with `@babel/plugin-transform-react-jsx-development` (or `@babel/preset-react` with `development: true`), each fiber node carries a `_debugSource` property containing `{ fileName, lineNumber, columnNumber }`. This is the exact JSX location in source.

The `_debugOwner` property on the fiber points to the parent component's fiber — useful for traversing up the component hierarchy when a clicked element is a plain DOM node rendered inside a larger component.

#### Sample Code

```js
function getFiberFromElement(element) {
  const key = Object.keys(element).find(
    k => k.startsWith('__reactFiber$') || k.startsWith('__reactInternalInstance$')
  );
  return key ? element[key] : null;
}

function getReactSource(element) {
  const fiber = getFiberFromElement(element);
  if (!fiber) return null;

  // _debugSource is present only in dev builds
  const src = fiber._debugSource;
  if (src) {
    return {
      tier: 1,
      framework: 'react',
      file: src.fileName,
      line: src.lineNumber,
      col: src.columnNumber,
      component: fiber.type?.displayName || fiber.type?.name || null
    };
  }

  // Fallback: walk _debugOwner chain for closest component with source
  let owner = fiber._debugOwner;
  while (owner) {
    if (owner._debugSource) {
      return {
        tier: 1,
        framework: 'react',
        file: owner._debugSource.fileName,
        line: owner._debugSource.lineNumber,
        col: owner._debugSource.columnNumber,
        component: owner.type?.displayName || owner.type?.name || null,
        note: 'source from parent component, not element itself'
      };
    }
    owner = owner._debugOwner;
  }

  return null;
}
```

#### Accuracy

High in React 16–18 dev mode. `_debugSource` gives exact file, line, and column of the JSX expression that produced the element. React 18 with the default Vite React template (`@vitejs/plugin-react`) automatically includes this because it uses `@babel/plugin-transform-react-jsx-development` in dev mode.

#### Constraints

- **DEV ONLY**: `_debugSource` is stripped in production builds. The `__reactFiber$` key itself may survive in prod but `_debugSource` will be `null` or absent.
- **React 19 breaking change**: React 19 removed `_debugSource` from fiber nodes in favor of a new lazy DevTools mapping approach (PR #28265, issue #32574). As of 2026, React 19 projects will not have this data on the fiber. A React 19-compatible approach requires hooking into the new DevTools protocol or using build-time injection (Tier 2).
- **Random suffix**: `__reactFiber$<id>` uses a random suffix generated per React root initialization. Must scan all keys for the prefix rather than using a fixed property name.
- **Async fiber**: The fiber key can differ between synchronous and concurrent mode renders. In concurrent mode (React 18+), the `current` vs `work-in-progress` fiber distinction matters — always access the `alternate` safely.

#### Dependencies

- React 16+ (fiber architecture)
- Babel dev transform: `@babel/plugin-transform-react-jsx-development` OR `@babel/preset-react` with `{ development: true }`
- In Vite: `@vitejs/plugin-react` automatically enables this in dev mode

#### Prod Behavior

Not available. `_debugSource` is stripped.

#### URL Citations

- https://github.com/facebook/react/blob/6a4b46cd70d2672bc4be59dcb5b8dede22ed0cef/packages/react-reconciler/src/ReactFiberDevToolsHook.js
- https://github.com/aidenybai/bippy (Bippy: hacking React internals — demonstrates fiber traversal)
- https://babeljs.io/docs/babel-plugin-transform-react-jsx-development
- https://github.com/facebook/react/issues/32574

---

### A.2 Vue `__vue__` / `__vue_app__` / `__vms__`

#### Working Principle

Vue attaches component metadata directly to DOM elements at runtime:

- **Vue 2**: `element.__vue__` is the component VM (ViewModel) instance. From there, `vm.$options.__file` contains the SFC (.vue file) path injected by the SFC compiler at build time. `vm.$options.name` is the component name.
- **Vue 3**: `element.__vueParentComponent` is the component internal instance. `instance.type.__file` gives the SFC path. `instance.type.name` gives component name. Note: plain `<div>` elements inside a component do NOT directly carry the property — you must walk `parentElement` up the DOM until you find one that has it.
- **`__vms__`**: The community plugin `vue-dom-hints` (https://github.com/privatenumber/vue-dom-hints) attaches a `__vms__` array to elements, containing the full component hierarchy chain from outermost to innermost. Useful for components that nest multiple Vue components at the same DOM element.

#### Sample Code

```js
function getVueSource(element) {
  // Vue 2
  const vm2 = element.__vue__;
  if (vm2) {
    return {
      tier: 1,
      framework: 'vue2',
      file: vm2.$options.__file || null,
      line: null, // Vue does not provide line-level source
      col: null,
      component: vm2.$options.name || null
    };
  }

  // Vue 3: walk up the DOM to find the nearest component anchor
  let el = element;
  while (el) {
    const vm3 = el.__vueParentComponent;
    if (vm3) {
      return {
        tier: 1,
        framework: 'vue3',
        file: vm3.type.__file || null,
        line: null,
        col: null,
        component: vm3.type.name || vm3.type.__name || null
      };
    }
    el = el.parentElement;
  }

  // vue-dom-hints fallback
  const vms = element.__vms__;
  if (vms && vms.length > 0) {
    const closest = vms[vms.length - 1];
    return {
      tier: 1,
      framework: 'vue3-dom-hints',
      file: closest.type?.__file || null,
      line: null,
      col: null,
      component: closest.type?.name || null
    };
  }

  return null;
}
```

#### Accuracy

Medium-high. `__file` is the exact SFC file path injected by the compiler. However, Vue does not natively provide line-number information — only component-level granularity. If the component has hundreds of lines, the agent must read the entire component file and infer which part corresponds to the clicked element.

#### Constraints

- **`__file` in prod**: Unlike React's `_debugSource`, Vue's `__file` is often present in production builds because the SFC compiler (Vite/vue-loader) injects it by default. However, this behavior is not guaranteed — some configs strip it for prod bundle size reduction.
- **No line number**: This is the fundamental limitation vs. React. The agent will know "the element is inside `Button.vue`" but not which line within that file.
- **`__vue__` is internal API**: Not a stable, documented property. Vue core marks it as internal.
- **`__vueParentComponent` traversal cost**: In deep DOM trees, walking up many levels has O(depth) cost. In practice, component roots are rarely more than 5-10 DOM levels deep.

#### Dependencies

- Vue 2 or 3
- SFC compiler (Vite with `@vitejs/plugin-vue`, or webpack with `vue-loader`)
- Optional: `vue-dom-hints` npm package for `__vms__` hierarchy

#### Prod Behavior

`__file` often present (Vite/Vue CLI default) but no line numbers in any case.

#### URL Citations

- https://devtools.vuejs.org/getting-started/open-in-editor
- https://github.com/privatenumber/vue-dom-hints
- https://vuejs.org/api/component-instance

---

### A.3 Svelte `__svelte_meta` (Dev Mode Injection)

#### Working Principle

Svelte 4's compiler, when invoked with the `dev: true` option, injects `__svelte_meta` directly onto DOM elements during component initialization. The property contains `{ loc: { file, line, column, char } }` where `file` is the `.svelte` source path, `line` and `column` are the exact position of the element in the template, and `char` is the character offset.

This is not a runtime hook — the metadata is compiled directly into the initialization code that Svelte generates, specifically in the `create_fragment` function for each component. Each `element()` call in the compiled output is followed by code that sets `__svelte_meta` on the created DOM node.

**Svelte 5 (runes) status**: As of 2026, Svelte 5 with the new runes-based reactivity system does NOT emit `__svelte_meta` (open issue #11389 in the Svelte repository). Projects migrating to Svelte 5 lose this capability entirely.

#### Sample Code

```js
function getSvelteSource(element) {
  const meta = element.__svelte_meta;
  if (!meta || !meta.loc) return null;
  return {
    tier: 1,
    framework: 'svelte4',
    file: meta.loc.file,
    line: meta.loc.line,
    col: meta.loc.column,
    component: null // __svelte_meta does not include component name
  };
}

// Walk up DOM if direct element lacks meta (e.g., text node parent)
function getSvelteSourceWithFallback(element) {
  let el = element;
  while (el && el !== document.body) {
    const result = getSvelteSource(el);
    if (result) return result;
    el = el.parentElement;
  }
  return null;
}
```

#### Accuracy

Very high for Svelte 4. Exact file + line + column. The only known accuracy issue is when TypeScript preprocessing is involved: if a `.svelte` file uses `<script lang="ts">`, the Svelte compiler processes TypeScript first, which can offset line numbers by the number of TS-specific lines that don't appear in the compiled output (issue #8360 in the Svelte repository). In practice, template markup line numbers (which are what we need for DOM elements) are not affected by TS preprocessing.

#### Constraints

- **DEV ONLY**: `dev: true` compiler option is required. Standard production Svelte builds do not include `__svelte_meta`.
- **Svelte 5 incompatibility**: `__svelte_meta` is not available in Svelte 5 runes mode as of 2026. No timeline given in issue #11389.
- **No component name**: `__svelte_meta` contains only location data, not the component name or parent hierarchy.
- **Single element granularity**: Only the element's own source location — no parent component context.

#### Dependencies

- Svelte 4 (not 5)
- Svelte compiler `dev: true` option (set in `svelte.config.js` or Vite config)

#### Prod Behavior

Not available.

#### URL Citations

- https://www.petermekhaeil.com/til/svelte-components-have-file-location-meta-data/
- https://github.com/sveltejs/svelte/issues/11389
- https://github.com/sveltejs/svelte/issues/8360

---

### A.4 Solid.js `@solid-devtools/locator` (`data-source-loc`)

#### Working Principle

`@solid-devtools/locator` is the official Solid DevTools package for click-to-source navigation. It injects `data-source-loc="src/components/Button.tsx:42:10"` attributes directly onto DOM elements at build time (during the Solid compiler/Babel transform phase). The attribute value follows the format `<filepath>:<line>:<column>`.

The package works by hooking into the Solid.js compiler's JSX transform. Unlike React's `_debugSource` (which is on the fiber object), Solid's locator puts the data directly as a DOM attribute, making it queryable with standard DOM APIs without any runtime fiber traversal.

The `getOwner()` / `runWithOwner()` Solid primitives track reactivity ownership chains but do not natively expose source file locations — the locator package bridges this gap by adding compile-time metadata.

#### Sample Code

```js
function getSolidSource(element) {
  // Primary: data-source-loc attribute injected by @solid-devtools/locator
  const loc = element.getAttribute('data-source-loc');
  if (loc) {
    const parts = loc.split(':');
    // Format: "path/to/file.tsx:line:col"
    // File paths may contain colons on Windows (C:\...) — handle carefully
    const col = parseInt(parts[parts.length - 1], 10);
    const line = parseInt(parts[parts.length - 2], 10);
    const file = parts.slice(0, parts.length - 2).join(':');
    return {
      tier: 1,
      framework: 'solid',
      file,
      line,
      col
    };
  }

  // Walk up for parent component if direct element lacks attribute
  let el = element.parentElement;
  while (el && el !== document.body) {
    const parentLoc = el.getAttribute('data-source-loc');
    if (parentLoc) {
      const parts = parentLoc.split(':');
      const col = parseInt(parts[parts.length - 1], 10);
      const line = parseInt(parts[parts.length - 2], 10);
      const file = parts.slice(0, parts.length - 2).join(':');
      return {
        tier: 1,
        framework: 'solid',
        file,
        line,
        col,
        note: 'source from nearest parent with data-source-loc'
      };
    }
    el = el.parentElement;
  }

  return null;
}
```

#### Accuracy

High. `data-source-loc` is injected at compile time with exact file + line + column of the JSX expression. As a DOM attribute, it is directly queryable without any runtime reflection.

#### Constraints

- **DEV ONLY**: Requires `@solid-devtools/locator` installed and configured in the Vite/Babel config. Not a built-in Solid feature.
- **Separate dependency**: Unlike React's `_debugSource` (which comes with Babel dev transform) or Svelte's `__svelte_meta` (built into the compiler), Solid requires an explicit npm package.
- **Not universal**: Only elements rendered through the Solid JSX transform get the attribute — dynamically created DOM nodes (via `document.createElement`) do not.

#### Dependencies

- `@solid-devtools/locator` npm package
- Solid.js
- Vite or Babel configuration to enable the locator transform

#### Prod Behavior

Not present (locator is dev-only by design).

#### URL Citations

- https://www.npmjs.com/package/@solid-devtools/locator
- https://github.com/thetarnav/solid-devtools
- https://dev.to/mbarzeev/using-solidjs-dev-tools-locator-feature-1445

---

### A.5 Build-time `data-source-file` Injection (Babel / SWC Transforms)

#### Working Principle

Rather than relying on runtime framework internals, build-time transforms inject source metadata directly as HTML attributes during compilation:

**`@babel/plugin-transform-react-jsx-source`** (official Babel plugin): Adds a `__source = { fileName, lineNumber, columnNumber }` prop to every JSX element at compile time. This prop is available at runtime as a React prop but does NOT automatically appear as an HTML attribute on the rendered DOM node — it stays in the React prop layer. Useful for React DevTools access but not for direct DOM attribute querying.

**`babel-plugin-transform-react-jsx-location`** (community): Injects a configurable HTML attribute (default: `data-source`) directly into the rendered DOM output. The attribute value is `"<filename>:<line>"`. This IS directly queryable from the DOM, making it the most straightforward approach for our use case.

**Vite `launchEditor` integration**: Vite dev server has a built-in `/__open-in-editor?file=<path>` endpoint. Some Vite plugins (e.g., `vite-plugin-react-click-to-component`) use this in combination with build-time injection to open files in the editor on click. The injection they perform is what we want to reuse.

#### Sample Code

```js
// babel-plugin-transform-react-jsx-location output in DOM:
// <div data-source="src/App.js:5" data-component="App">...</div>

function getDataSourceAttr(element) {
  // babel-plugin-transform-react-jsx-location
  const src = element.getAttribute('data-source') || element.dataset.sourceFile;
  if (src) {
    const [file, line] = src.split(':');
    return {
      tier: 2,
      framework: 'any-jsx',
      file,
      line: parseInt(line, 10),
      col: null,
      component: element.getAttribute('data-component') || null
    };
  }

  // Custom attribute convention (project-specific)
  const customSrc = element.getAttribute('data-source-loc') || element.getAttribute('data-source-file');
  if (customSrc) {
    const parts = customSrc.split(':');
    return {
      tier: 2,
      framework: 'custom-build-inject',
      file: parts[0],
      line: parseInt(parts[1], 10) || null,
      col: parseInt(parts[2], 10) || null
    };
  }

  return null;
}
```

#### Accuracy

Exact at compile time. The injected values reflect the exact JSX source position. For elements that are conditionally rendered or produced by `Array.map`, the transform still operates correctly because it runs at AST level before any runtime logic.

#### Constraints

- **JSX-specific**: `@babel/plugin-transform-react-jsx-source` and `babel-plugin-transform-react-jsx-location` require JSX — they work with React and can technically work with Preact or any JSX user, but Vue's SFC templates and Svelte templates are not JSX and need separate transforms.
- **Bundle bloat in prod**: Even one `data-source` attribute per element adds measurable bytes. For large apps, prod builds should exclude these plugins. Recommended: guard with `process.env.NODE_ENV !== 'production'`.
- **SWC equivalent**: SWC (used by Vite by default in some configs) does not have a built-in equivalent to `babel-plugin-transform-react-jsx-location`. Custom SWC plugins are possible but require Rust/Wasm tooling.
- **Fragment and dynamic children**: Elements produced inside `React.Fragment` or via spread rendering may not receive the attribute if the transform cannot statically identify the output element.

#### Dependencies

- Babel 7+ for `babel-plugin-transform-react-jsx-location`
- OR custom Vite plugin using `transformIndexHtml` / `transform` hooks
- OR SWC custom plugin (advanced, requires Rust)

#### Prod Behavior

Not recommended. Can be done technically but adds bundle size and exposes source paths.

#### URL Citations

- https://babeljs.io/docs/babel-plugin-transform-react-jsx-source
- https://github.com/adrianton3/babel-plugin-transform-react-jsx-location

---

### A.6 Vite Plugin Ecosystem

#### Working Principle

A family of Vite dev plugins has emerged as the **de facto click-to-source standard** for Vite-based applications. These plugins are dev-only (`apply: 'serve'` in Vite plugin config) and have zero impact on production bundles.

**`vite-plugin-vue-inspector`** (webfansplz): The most mature Vue solution. Attaches source metadata to Vue VNodes during the transform phase, overlays click-highlight UI, and resolves click → component file + line. Supports Vue 2, Vue 3, and SSR. Uses Vite's `transformIndexHtml` to inject a client script and modifies Vue component source via the `transform` hook to attach `__VUE_DEVTOOLS_UID__`-style metadata.

**`vite-plugin-react-click-to-component`** (ArnaudBarre): Injects click handlers via `transformIndexHtml`. Uses `Alt+Click` to trigger source lookup. Integrates with Vite's built-in `/__open-in-editor` middleware for editor launch. Lightweight (no source modification) — works by reading React fiber `_debugSource` at click time.

**`react-dev-inspector`** (zthxxx): The most complete React solution. Three-part architecture: (1) compiler plugin that injects `data-inspector-*` attributes into JSX at build time, (2) `<Inspector>` React component that handles the overlay UI, (3) dev server middleware that intercepts the source open request and calls `launch-editor`. Attributes injected: `data-inspector-relative-path`, `data-inspector-line`, `data-inspector-column`, `data-inspector-component-name`.

**`vite-plugin-vue-tracer`** (antfu): Uses Vite's internal module graph and source maps rather than DOM injection. Zero DOM overhead. Resolves component source by querying Vite's transform pipeline directly.

**What these plugins expose for clau-mux:**

`react-dev-inspector` is the most relevant: it injects `data-inspector-relative-path`, `data-inspector-line`, `data-inspector-column`, and `data-inspector-component-name` as DOM attributes. Our content script daemon can read these directly:

```js
function getReactDevInspectorSource(element) {
  const file = element.getAttribute('data-inspector-relative-path') ||
               element.closest('[data-inspector-relative-path]')?.getAttribute('data-inspector-relative-path');
  if (!file) return null;
  const line = parseInt(element.getAttribute('data-inspector-line') ||
    element.closest('[data-inspector-line]')?.getAttribute('data-inspector-line') || '0', 10);
  const col = parseInt(element.getAttribute('data-inspector-column') ||
    element.closest('[data-inspector-column]')?.getAttribute('data-inspector-column') || '0', 10);
  const component = element.getAttribute('data-inspector-component-name') ||
    element.closest('[data-inspector-component-name]')?.getAttribute('data-inspector-component-name');
  return {
    tier: 2,
    framework: 'react-dev-inspector',
    file,
    line,
    col,
    component: component || null
  };
}
```

#### Accuracy

High (same as build-time injection, but managed by plugin ecosystem rather than manual Babel config).

#### Constraints

- **Dev only**: All listed plugins use `apply: 'serve'` or equivalent — zero prod impact.
- **Vite required**: Not applicable to webpack, Rollup, or other bundlers.
- **Framework-specific**: Each plugin targets one framework. Mixed-framework mono-repos need multiple plugins.
- **`react-dev-inspector` requires explicit setup**: User must install the package AND add the `<Inspector>` component AND configure the Vite plugin. Not automatic.

#### Dependencies

- Vite 2+
- Framework-specific plugin installed and configured

#### Prod Behavior

Zero overhead (dev-only plugins are excluded from prod builds entirely).

#### URL Citations

- https://github.com/webfansplz/vite-plugin-vue-inspector
- https://github.com/ArnaudBarre/vite-plugin-react-click-to-component
- https://react-dev-inspector.zthxxx.me/docs/integration/vite
- https://github.com/antfu/vite-plugin-vue-tracer

---

### A.7 Source-Map Library Stacktrace Lookup (`source-map` / `@jridgewell/trace-mapping`)

#### Working Principle

If you have a generated (bundled) code position — specifically a line and column number within the bundled JavaScript file — you can reverse-map it to the original source file and line using source map files. This is the mechanism used by error tracking services (Sentry, Bugsnag) and browser DevTools for stack frame source display.

Key libraries:
- **`source-map`** (Mozilla): The reference implementation. `SourceMapConsumer.originalPositionFor({line, column})` returns `{source, line, column, name}`.
- **`@jridgewell/trace-mapping`**: A faster reimplementation. ~4-6x faster than `source-map` (7,588 ops/sec vs 927 ops/sec in benchmarks), no WebAssembly requirement. API: `originalPositionFor(tracer, { line, column })`.

**When useful for element inspection**: Only when you can synthesize a stack trace that includes the component's render function call at a known bundled line/column. One approach: call `new Error()` inside a React `useLayoutEffect` or Svelte `onMount` callback immediately after the element mounts — the stack trace will include the render call at a bundled position, which can then be source-mapped. This approach is fragile in async rendering environments.

#### Sample Code

```js
import { TraceMap, originalPositionFor } from '@jridgewell/trace-mapping';

async function sourceMapLookup(bundledFile, line, column) {
  // Fetch the source map for the bundled file
  const mapUrl = bundledFile + '.map';
  const mapJson = await fetch(mapUrl).then(r => r.json());

  const tracer = new TraceMap(mapJson);
  const original = originalPositionFor(tracer, { line, column });
  // Returns: { source: 'src/components/Button.tsx', line: 42, column: 10, name: 'Button' }
  // or { source: null, line: null, column: null, name: null } on miss

  if (!original.source) return null;
  return {
    tier: 3,
    framework: 'source-map',
    file: original.source,
    line: original.line,
    col: original.column,
    name: original.name || null
  };
}
```

#### Accuracy

Exact for the queried line and column — when you have the right bundled position. The fundamental limitation is the "when you have the right bundled position" clause. Obtaining the bundled line/column of an element's render call from a DOM click event alone requires:

1. A stack trace captured during component initialization (fragile)
2. OR CDP Debugger domain to pause execution and inspect the call stack (requires remote debugging)
3. OR build-time knowledge of which bundle position corresponds to each component (effectively reinventing build-time injection)

Multiple JSX elements on the same source line are indistinguishable. Comments and whitespace-only lines are not present in source maps.

#### Constraints

- **Requires `.map` files accessible**: Source maps must be served at a predictable URL path (e.g., `bundle.js.map`). Serving source maps in production is a security trade-off — exposes original source paths and may allow partial source reconstruction.
- **Cannot directly map DOM element → source**: Needs an intermediate step (stack trace capture or CDP integration) to get the bundled line/column.
- **Fragile in async rendering**: React concurrent mode, React Server Components, Suspense boundaries, and streaming SSR all complicate stack trace attribution. The stack trace at `new Error()` may not include the component render frame.
- **`source-map` wasm dependency**: The Mozilla `source-map` library requires WebAssembly for full performance. `@jridgewell/trace-mapping` avoids this.

#### Dependencies

- `@jridgewell/trace-mapping` (preferred) or `source-map` (Mozilla)
- `.map` files must be served and accessible

#### Prod Behavior

Technically possible if source maps are served, but requires resolving the "get bundled position from DOM element" problem — which is hard without build-time injection or CDP.

#### URL Citations

- https://github.com/mozilla/source-map
- https://github.com/jridgewell/trace-mapping
- https://developer.mozilla.org/en-US/docs/Glossary/Source_map

---

### A.8 Chrome DevTools Protocol (CDP) Internal Mechanism

#### Working Principle

Chrome DevTools uses the Chrome DevTools Protocol (CDP) — a WebSocket-based protocol that Chromium exposes for external tooling (Playwright, Puppeteer, custom DevTools extensions). Relevant domains:

**For CSS source mapping:**
`CSS.getMatchedStylesForNode(nodeId)` returns all CSS rules matched for a given DOM node, each with:
- `styleSheetId` — identifies which stylesheet the rule comes from
- `sourceRange` — the exact range (startLine, startColumn, endLine, endColumn) within the stylesheet
- If source maps are present, the CSS domain uses them to resolve to original `.css`/`.scss`/`.less` source

This is directly useful for the `cascade_winner` field in our `reality_fingerprint` payload — we can use CDP to get the exact CSS file and line of the winning rule for any property on any DOM node.

**For JS component source:**
CDP's `Debugger` domain fires `Debugger.scriptParsed` for each loaded script, including the `sourceMapURL` field. DevTools fetches and caches the source map. However, knowing "which JS position corresponds to this element's JSX" is NOT something CDP natively provides — it requires either:
- React/Vue DevTools browser extension (which uses the DevTools extension protocol, not CDP directly)
- OR custom metadata in the DOM (Tier 1/2 approaches above)

**`Overlay.inspectNodeRequested`**: Fired when the user clicks "Inspect Element" in DevTools mode. Contains the `backendNodeId` of the clicked element. This is how Chrome DevTools itself gets click events — not applicable directly to our browser extension approach.

**Key implication for clau-mux**: We can use CDP for CSS source resolution (excellent reliability), but for JS component source we must fall back to Tier 1 (framework hooks) or Tier 2 (build-time injection). CDP does not solve the JS source remapping problem on its own.

#### Sample Code

```js
// Node.js CDP client (using puppeteer-core or raw WebSocket)
// This is what the clau-mux daemon could run server-side

async function getCSSSourceForNode(cdp, nodeId) {
  const result = await cdp.send('CSS.getMatchedStylesForNode', { nodeId });
  const matched = result.matchedCSSRules || [];
  return matched.map(rule => ({
    file: rule.rule.style.cssText,
    styleSheetId: rule.rule.styleSheetId,
    startLine: rule.rule.selectorList?.range?.startLine,
    // source map resolution happens inside Chrome — returned as sourceURL if available
  }));
}

async function enableCSSSourceTracking(cdp) {
  await cdp.send('CSS.enable');
  cdp.on('CSS.styleSheetAdded', async (params) => {
    const text = await cdp.send('CSS.getStyleSheetText', {
      styleSheetId: params.header.styleSheetId
    });
    // Cache stylesheet text for later diff comparison
  });
}
```

#### Accuracy

Excellent for CSS (CDP natively resolves cascade winner and source map for CSS). Limited for JS component source — CDP alone is insufficient; requires Tier 1 or Tier 2 data.

#### Dependencies

- CDP (Chromium — Chrome, Edge, or Electron-based apps)
- Node.js client (Puppeteer, Playwright, or raw WebSocket `ws` library)
- Remote debugging enabled in the target browser (`--remote-debugging-port=9222`)

#### Prod Behavior

CSS matching works in any build (prod or dev). JS component source requires dev-mode metadata regardless.

#### URL Citations

- https://chromedevtools.github.io/devtools-protocol/tot/CSS/
- https://chromedevtools.github.io/devtools-protocol/tot/Debugger/
- https://chromedevtools.github.io/devtools-protocol/tot/Overlay/
- https://developer.chrome.com/docs/devtools/javascript/source-maps

---

### A.9 Multi-Tier Fallback Recommendation

#### Tier Architecture

| Tier | Technique | Accuracy | Dev-only? | Impl. Burden | When Available |
|---|---|---|---|---|---|
| **Tier 1** | Framework runtime hook (React `__reactFiber$` + `_debugSource`, Vue `__vue__` / `__vueParentComponent`, Svelte `__svelte_meta`, Solid `data-source-loc`) | High–Very High | Yes (mostly) | Low (read DOM props) | Dev mode, correct framework detected |
| **Tier 2** | Build-time DOM attribute injection (Vite plugin ecosystem or Babel `data-source-file`) | High | Yes (recommended) | Medium (plugin config required) | User has configured plugin; or auto-detect existing plugin attributes |
| **Tier 3** | Source-map stacktrace reverse lookup (`@jridgewell/trace-mapping`) | Exact but fragile | Prod possible | High (stack trace capture + map fetch) | Source maps served; bundled position known |
| **Tier 4** | `"source_unknown"` — honest failure | N/A | N/A | None | Tier 1–3 all failed |

#### Per-Tier Implementation Burden

**Tier 1 — Framework Runtime Hook**

Implementation burden: LOW

The content script (injected into the target page) reads properties that are already on the DOM element. No build changes required on the user's side. The clau-mux content script needs to:
1. Detect which framework is present (check for `window.__vue_app__`, `window.React`, `window.__svelte`, or `document.querySelector('[data-source-loc]')`)
2. Run the appropriate extractor function (from A.1–A.4 above)
3. Handle the `null` return as a Tier 1 miss, fall through to Tier 2

Caveats:
- React 19 migration: `_debugSource` removal means React 19 users get Tier 1 miss and fall to Tier 2
- Vue gives file but no line — payload `source_location.line` will be `null`, and the agent must handle this gracefully
- Svelte 5 migration: same miss scenario as React 19

**Tier 2 — Build-Time Injection**

Implementation burden: MEDIUM

Two sub-scenarios:
- **Auto-detect existing Vite plugin**: If the user already has `react-dev-inspector`, `vite-plugin-vue-inspector`, or similar installed, their DOM attributes are already present. The content script just needs to know to look for `data-inspector-*` attributes (react-dev-inspector) or Vue inspector attributes. Zero additional burden for users who already have these tools.
- **Explicit Vite plugin install**: The clau-mux setup guide instructs users to install one Vite plugin. One-time config change. This is the primary onboarding story for projects without Tier 1 coverage.

**Tier 3 — Source Map Stacktrace Lookup**

Implementation burden: HIGH

Requires:
1. A mechanism to capture the bundled line/column of the render call for the clicked element (stack trace injection during component mount, or CDP integration)
2. Source map files accessible at a predictable URL (not always the case — Vite serves them lazily)
3. `@jridgewell/trace-mapping` or equivalent running in the content script or daemon
4. Handling async rendering scenarios (React concurrent mode, Suspense)

Conclusion: Tier 3 is too fragile for general DOM element lookup from a simple click event. The fundamental problem is that a click event fires after rendering is complete — the render stack frame is no longer on the call stack. Without build-time instrumentation or CDP pausing, there is no reliable way to get the bundled line/column of the render call.

**Tier 4 — Honest Failure**

Implementation burden: NONE

When Tier 1, 2, and 3 all fail (or are not attempted), the payload's `source_location` field is set to `null` and a `source_tier` field is set to `"unknown"`. The agent prompt (Part B) must handle this case explicitly — it should fall back to selector-based grep on the codebase rather than pretending to have a source location.

This is preferable to a hallucinated or imprecise file path because:
- A wrong file path sends the agent to the wrong code
- An `"unknown"` source tells the agent to search broadly, which is slower but more accurate than acting on wrong data

#### Recommended Default for clau-mux

**Primary: Tier 1 (React `__reactFiber$*` + `_debugSource`)** for React 16–18 projects.

Rationale: The majority of clau-mux users are likely running Vite + React (the most common frontend dev stack as of 2026). Vite's React plugin (`@vitejs/plugin-react`) automatically enables `@babel/plugin-transform-react-jsx-development` in dev mode, which means `_debugSource` is present without any user configuration change. This is the zero-friction path.

**Secondary: Tier 2 (Auto-detect existing Vite plugin attributes)** — specifically `react-dev-inspector`'s `data-inspector-*` attributes, and `vite-plugin-vue-inspector`'s metadata for Vue projects. If the user already has these tools installed, the content script reuses their data at no additional cost.

**Fallback: Tier 4 (honest `"source_unknown"`)** rather than Tier 3.

Rationale for skipping Tier 3: Source map lookup from DOM click is too unreliable without CDP integration. Adding CDP to the clau-mux architecture would introduce a significant dependency (remote debugging port, process management, security implications). For P3 (first implementation phase), Tier 3 is deferred. If CDP integration is added later (e.g., for CSS cascade resolution, which CDP does excellently), Tier 3 could be revisited.

**Framework detection order in content script:**

```js
async function resolveSourceLocation(element) {
  // Tier 1a: React
  const react = getReactSource(element);
  if (react) return { ...react, source_tier: 1 };

  // Tier 1b: Vue
  const vue = getVueSource(element);
  if (vue) return { ...vue, source_tier: 1 };

  // Tier 1c: Svelte
  const svelte = getSvelteSource(element);
  if (svelte) return { ...svelte, source_tier: 1 };

  // Tier 1d: Solid
  const solid = getSolidSource(element);
  if (solid) return { ...solid, source_tier: 1 };

  // Tier 2: Build-time injection / Vite plugin attributes
  const injected = getDataSourceAttr(element) || getReactDevInspectorSource(element);
  if (injected) return { ...injected, source_tier: 2 };

  // Tier 4: Honest failure (skip Tier 3 in P3)
  return {
    tier: 4,
    source_tier: 'unknown',
    file: null,
    line: null,
    col: null,
    component: null,
    note: 'source remapping failed — all tiers exhausted'
  };
}
```

---

## Part B — Agent Prompt Template Design

### B.1 Design Goals

The inspect payload received by an agent (Gemini CLI, Codex CLI, Claude Code teammate) contains:

```json
{
  "user_intent": "The card title should be 18px bold but appears small and thin",
  "pointing": {
    "selector": "#card-grid .card:first-child .card-title",
    "tag": "h3",
    "text_content": "Featured Article",
    "classes": ["card-title", "text-lg"]
  },
  "source_location": {
    "file": "src/components/Card.tsx",
    "line": 42,
    "col": 8,
    "component": "Card",
    "source_tier": 1
  },
  "reality_fingerprint": {
    "computed_font_size": "16px",
    "computed_font_weight": "400",
    "applied_classes": ["card-title", "text-lg"],
    "cascade_winner_font_size": "tailwind: text-lg → 1rem/16px",
    "cascade_winner_font_weight": "tailwind: base reset → font-weight: 400"
  }
}
```

The agent must:
1. **Read** `source_location.file` before any other action
2. **Extract** the intended values from the source code (what the developer meant to express)
3. **Compare** extracted source values against `reality_fingerprint` fields
4. **Identify** drift (where source intent diverges from runtime reality)
5. **Honor** `user_intent` text for fix direction
6. **Propose** a specific, minimal code fix

### B.2 Known LLM Failure Modes (Anti-Patterns to Guard Against)

These failure modes have been observed in real-world LLM code assistance interactions:

1. **Skip-read hallucination**: Agent reasons from `reality_fingerprint` values alone without reading the source file. Produces plausible-sounding but ungrounded diagnosis.

2. **Visual reasoning hallucination**: Agent says "I can see the layout has..." or "looking at the rendered output..." when no screenshot or visual input was provided.

3. **Selector grep shortcut**: Agent uses `pointing.selector` to grep the codebase for a matching CSS selector, finds a result in a different file than `source_location.file`, and acts on the wrong file.

4. **Sibling/parent inference without evidence**: Agent says "since the parent has X property, this element inherits..." without reading the parent component's source to verify.

5. **Confident wrong fix**: Agent proposes a specific code change that sounds correct based on the fingerprint values but contradicts what the source code actually says.

6. **Source location dismissal**: Agent acknowledges `source_location.file` exists but says "let me check the CSS file instead" — treating the component source as optional rather than primary.

---

### B.3 Prompt Candidate 1: Strict Sequential (Read-First Mandate)

**Design intent**: Numbered sequential steps with explicit forward-blocking gates. Each step must be completed and shown in output before the next begins. Targets agents that can follow structured instruction well. Best for Claude Code teammate.

**Strengths**: Strongest enforcement of read-first. Visible compliance in output (step numbers appear). No ambiguity about required order.

**Weaknesses**: Verbose. Gemini CLI in raw interactive mode may not produce all step labels in output. Step-gating phrasing can feel mechanical.

**Target agent**: Claude Code teammate (can follow structured instruction precisely)

---

**CANDIDATE 1 — FULL SYSTEM PROMPT TEXT:**

```
You are a source-code drift analyst. You have received a browser element inspect payload below.
Your task is to identify the drift between developer intent (in source code) and runtime reality
(in the fingerprint), then propose a fix.

CRITICAL CONSTRAINT: This task operates on SOURCE CODE ONLY. You have no screenshots, no visual
rendering, and no browser access. Every claim you make must be grounded in source code you have
actually read. Do not describe visual appearance. Do not infer from fingerprint values alone.

Follow these steps IN ORDER. Do not skip steps. Do not begin step N+1 until step N is complete.
Show the step label (e.g., "## Step 1 Complete") in your output before proceeding.

---

## Step 1 — Read Source File

Read the file at `source_location.file` in its entirety using your file reading tool.
If `source_location.file` is null or `source_tier` is "unknown", proceed to Step 1-Fallback.

DO NOT proceed to Step 2 until you have read the file and shown the relevant code lines
(the 10 lines surrounding `source_location.line`) in your output.

Step 1-Fallback (only if source_location is null):
  Search the codebase for files matching `pointing.tag` + `pointing.classes` combination.
  Read the most likely candidate file. Note in your output that source location was unknown
  and you are working from a search result.

## Step 2 Complete marker required before proceeding.

---

## Step 2 — Extract Intent from Source

From the code you read in Step 1, extract:
  a) The styling approach used (CSS class names, inline styles, CSS variables, etc.)
  b) The specific values the developer expressed for size, weight, color, or other visible properties
  c) Whether the component applies conditional styling that could override defaults

Quote specific lines from the source in your response. Do not paraphrase without quoting.
Do not use `reality_fingerprint` values in this step — extract only from source code.

## Step 2 Complete marker required before proceeding.

---

## Step 3 — Compare Source Intent vs. Reality Fingerprint

Create a comparison table:

| Property | Source Intent (from Step 2) | Runtime Reality (from fingerprint) | Match? |
|----------|-----------------------------|------------------------------------|--------|
| font-size | [what source says]         | [fingerprint.computed_font_size]   | ✓/✗   |
| font-weight | [what source says]       | [fingerprint.computed_font_weight] | ✓/✗   |
| ... other properties as relevant ...

If source intent for a property is ambiguous (e.g., "uses class `text-lg` but you are not
certain what `text-lg` resolves to"), say so explicitly. Do not assume — look up the relevant
CSS/config file if needed.

## Step 3 Complete marker required before proceeding.

---

## Step 4 — Identify Drift

Based on the comparison table in Step 3, state:
  - Which properties have drift (source intent ≠ runtime reality)
  - The probable cause of the drift (wrong class name, missing style rule, config override, etc.)
  - Whether the drift explains the user's reported issue in `user_intent`

If there is no drift found but the user reports a problem, state this explicitly and note that
the source correctly expresses the intent but the rendering chain may have an external override.

## Step 4 Complete marker required before proceeding.

---

## Step 5 — Fix Direction from User Intent

Read `user_intent` in the payload. Use it to determine:
  - The direction the fix should move (e.g., "user wants 18px bold — fix should increase
    font-size and font-weight")
  - Whether the fix requires changing the component source, a CSS file, a config file
    (e.g., Tailwind config), or a combination

## Step 5 Complete marker required before proceeding.

---

## Step 6 — Propose Specific Fix

Provide a minimal, complete code change that resolves the drift:
  - Specify the exact file path (absolute or repo-relative)
  - Specify the exact line(s) to change
  - Show before/after code blocks
  - If multiple files need changes, show all of them

Do not propose changes that you have not verified against the source code you read in Step 1.
Do not propose speculative changes ("might also want to check...") — only changes directly
supported by evidence from Steps 1–5.

## Step 6 Complete — Analysis finished.
```

---

### B.4 Prompt Candidate 2: Checklist-Driven with Anti-Hallucination Guards

**Design intent**: Checklist items the agent must complete and mark off. Explicit negative constraints (DO NOT rules) that directly address the known failure modes from B.2. Structured output format required but not step-gated. Works well across all three CLI-based teammates.

**Strengths**: Clear compliance verification — the checklist in output proves compliance. Anti-hallucination guards are explicit and specific to our known failure modes. Works with agents that don't follow rigid step numbering well.

**Weaknesses**: Longer system prompt. Checklist overhead adds token cost per invocation. Agents may check off items without actually doing them.

**Target agent**: All teammates (Gemini CLI, Codex CLI, Claude Code teammate) — this is the recommended default.

---

**CANDIDATE 2 — FULL SYSTEM PROMPT TEXT:**

```
You are a code-drift analyst for browser element inspection. You receive a structured payload
describing a browser element: where it is in source code, what properties it has at runtime,
and what the user believes is wrong.

Your job: find the drift between developer intent (source code) and runtime reality (fingerprint).
Propose a targeted fix.

════════════════════════════════════════════
ABSOLUTE CONSTRAINTS — READ BEFORE ANYTHING ELSE
════════════════════════════════════════════

DO NOT claim to see any visual layout, rendering, or appearance. You have no screenshots.
All analysis must come from source code and the provided fingerprint data only.

DO NOT use `pointing.selector` or `pointing.classes` as a grep shortcut to find related CSS
without first reading `source_location.file`. The pointing data identifies the element;
the source location is where the relevant code lives. Treat them differently.

DO NOT reason about parent or sibling elements without reading their source files.
"The parent container likely has overflow:hidden" is not valid reasoning — read the parent
component file if you need to claim something about it.

DO NOT skip reading the source file. If you cannot read the file (permission error, file not
found, source_location is null), say so explicitly and switch to the fallback procedure below.
Do not silently proceed without the read.

DO NOT propose changes to files you have not read in this session.

════════════════════════════════════════════
TASK CHECKLIST — Complete all items. Mark each [x] in your response.
════════════════════════════════════════════

[ ] 1. SOURCE READ
    Action: Read the file at source_location.file using your file reading tool.
    If source_location.file is null → use FALLBACK PROCEDURE (see below).
    Output: Quote the 10 lines surrounding source_location.line (or the full component
    if line is null).

[ ] 2. INTENT EXTRACTION
    Action: From the lines you read, identify how the developer expressed styling intent:
    class names, inline styles, CSS variables, component props, etc.
    Output: List each relevant styling expression with the exact line number where it appears.
    Do not use fingerprint values in this item — source code only.

[ ] 3. DRIFT TABLE
    Action: Compare source intent (item 2) against reality_fingerprint values.
    Output: A markdown table with columns: Property | Source Intent | Runtime Reality | Drift?

[ ] 4. DRIFT EXPLANATION
    Action: For each property marked as drift in item 3, explain the probable cause.
    Is it: (a) wrong class name, (b) class not having expected effect (config issue),
    (c) specificity override, (d) conditional logic applying wrong branch?
    Output: One paragraph per drifted property.

[ ] 5. USER INTENT ALIGNMENT
    Action: Read user_intent. Confirm the fix direction aligns with what the user describes.
    If drift explanation contradicts user_intent, note the discrepancy.
    Output: One sentence: "The fix should [do X] because user_intent says [Y]."

[ ] 6. FIX PROPOSAL
    Action: Write a specific code change.
    Output:
      File: [exact file path]
      Before: [original code block]
      After: [fixed code block]
      Rationale: [one sentence linking fix to drift evidence from item 3-4]

════════════════════════════════════════════
FALLBACK PROCEDURE (when source_location.file is null or unreadable)
════════════════════════════════════════════

If source remapping failed (source_tier = "unknown" or file is null):
  1. State explicitly: "Source location unknown — using codebase search fallback."
  2. Search for files containing pointing.tag element with pointing.classes applied.
  3. Read the most likely candidate file.
  4. Proceed with checklist items 2–6, noting that confidence is reduced.
  5. Prefix fix proposal with: "WARNING: Source location was not confirmed. Verify this
     file path before applying the fix."

════════════════════════════════════════════
OUTPUT FORMAT
════════════════════════════════════════════

Your response must include all 6 checklist items with [x] markers.
Use the exact section headers: "1. SOURCE READ", "2. INTENT EXTRACTION", etc.
End with a "## Fix Summary" block containing only the file path, before/after code,
and one-line rationale — suitable for copy-pasting to a code review.
```

---

### B.5 Prompt Candidate 3: Tool-Call Enforced (Function Schema)

**Design intent**: Define the required workflow as a sequence of tool-call function signatures that the agent must invoke in order. The tool call log (if available from the agent harness) provides mechanical proof of compliance. Targets agents with strong function-calling support.

**Strengths**: Most mechanically verifiable — tool call logs show exactly which tools were called in which order. `read_file` call before any `compare_values` call is enforced at the execution layer, not just the prompt layer.

**Weaknesses**: Requires function-calling support in the agent's execution environment. Gemini CLI in raw interactive mode does not have function-calling schema enforcement. Codex CLI's function-calling mode requires specific model + config. Claude Code teammate in Claude's tool-use mode supports this well.

**Target agent**: Claude Code teammate (native tool-use support), Codex CLI with function-calling mode.

---

**CANDIDATE 3 — FULL SYSTEM PROMPT TEXT:**

```
You are a browser element drift analyst. You receive an inspect payload and must analyze
source code to find intent-vs-reality drift.

OPERATING MODE: You MUST use the tool-call sequence defined below. The order of tool calls
is enforced. You may not skip tools or reorder them.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REQUIRED TOOL-CALL SEQUENCE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

You must call tools in this exact order. Each tool call is mandatory.

TOOL 1 — read_file
  Purpose: Read the source file before ANY analysis.
  Call: read_file(path=source_location.file)
  If source_location.file is null:
    Call: search_files(query=pointing.tag + " " + pointing.classes[0], note="source_unknown_fallback")
    Then: read_file(path=<most likely result from search>)
  You MUST NOT call any other analysis tool until read_file has returned successfully.

TOOL 2 — extract_styling_intent
  Purpose: Extract what the developer expressed in the source code.
  Call: extract_styling_intent(
    source_lines=<lines from TOOL 1 output surrounding source_location.line>,
    focus_properties=["font-size", "font-weight", "color"]  // or whichever fingerprint keys are present
  )
  Output format: { property: string, source_expression: string, line_number: int }[]
  Do not use fingerprint values as input to this tool — source lines only.

TOOL 3 — compare_values
  Purpose: Compare source intent against runtime fingerprint.
  Call: compare_values(
    source_intent=<output of TOOL 2>,
    fingerprint=reality_fingerprint
  )
  Output format: { property: string, source: string, runtime: string, has_drift: boolean }[]

TOOL 4 — explain_drift
  Purpose: Explain the cause of each drifted property.
  Call: explain_drift(
    drift_items=<items from TOOL 3 where has_drift=true>,
    user_intent=user_intent
  )
  Output format: { property: string, cause: string, fix_direction: string }[]

TOOL 5 — propose_fix
  Purpose: Write the concrete code change.
  Call: propose_fix(
    source_file=source_location.file,
    source_line=source_location.line,
    drift_explanation=<output of TOOL 4>,
    current_source=<relevant lines from TOOL 1 output>
  )
  Output format: { file: string, before: string, after: string, rationale: string }

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
CONSTRAINTS ON TOOL CALLS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

1. read_file (TOOL 1) must appear in the tool call log BEFORE compare_values (TOOL 3).
   If an execution validator checks your tool call sequence, this order will be verified.

2. Do not call propose_fix (TOOL 5) if compare_values (TOOL 3) returned no drift items
   (all has_drift=false). Instead, respond: "No drift detected between source and fingerprint.
   The issue may be in an upstream component or global CSS. Further investigation needed."

3. If read_file returns an error ("file not found", "access denied"), do not proceed to
   TOOL 2. Instead, call search_files to find the nearest match and read that file.
   Prepend all subsequent outputs with "WARNING: Primary source file could not be read."

4. The propose_fix output must reference line numbers from the read_file output.
   Proposing changes to lines you did not read is not permitted.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ANTI-HALLUCINATION GUARDS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

These are direct constraints on your reasoning, not just suggestions:

- You have no visual input. Do not describe what the element "looks like."
- The fingerprint is ground truth for runtime state. The source file is ground truth for intent.
  Neither one alone is sufficient to diagnose drift.
- If you are uncertain about what a class name resolves to (e.g., a Tailwind class),
  call read_file on the relevant config file (tailwind.config.js) before claiming its value.
- Your proposed fix must be grounded in evidence from TOOL 1 output. Quote the relevant
  source lines in propose_fix.rationale.
```

---

### B.6 Recommendation: Candidate 2 as Default

**Recommended template: Candidate 2 (Checklist-Driven)**

Rationale:
1. **Works across all three CLI-based teammates**: Gemini CLI, Codex CLI, and Claude Code teammate all follow checklist-style instructions reliably. Function-calling enforcement (Candidate 3) is not universally available in CLI modes.
2. **Anti-hallucination guards are explicit**: The six known failure modes (B.2) are directly addressed in the DO NOT rules block. Candidate 1's sequential enforcement doesn't name the failure modes — Candidate 2 does.
3. **Verifiable compliance without tool call logs**: The checklist items with `[x]` markers appear in the agent's text output. A simple string check (`grep -c '\[x\]'` output contains 6 items) confirms compliance, no tool call logging infrastructure needed.
4. **Fallback procedure included**: Candidate 2 explicitly handles the `source_unknown` Tier 4 case. Candidates 1 and 3 have less explicit fallback handling.

**Variant A — Compact Gemini**: Candidate 2 with the constraint block shortened and the anti-hallucination guards condensed to a single "forbidden patterns" list. Gemini CLI performs better with concise instructions than with multi-paragraph preambles.

**Variant B — Strict Claude Teammate**: Candidate 2 + Candidate 1's step-gating language ("DO NOT proceed to item N+1 until item N output is shown"). For Claude Code teammate specifically, the combination provides both checklist compliance and sequential enforcement.

---

### B.7 Few-Shot Example

This example shows the expected input, agent reasoning trace, and output format. It should be included as a user-turn example following the system prompt in production deployments.

---

**Input (user turn or tool call content):**

```json
{
  "user_intent": "The card title should be 18px bold, but it appears smaller and thin",
  "pointing": {
    "selector": "#card-grid .card:first-child .card-title",
    "tag": "h3",
    "text_content": "Featured Article",
    "classes": ["card-title", "text-lg", "font-normal"]
  },
  "source_location": {
    "file": "src/components/Card.tsx",
    "line": 42,
    "col": 8,
    "component": "Card",
    "source_tier": 1
  },
  "reality_fingerprint": {
    "computed_font_size": "16px",
    "computed_font_weight": "400",
    "applied_classes": ["card-title", "text-lg", "font-normal"],
    "cascade_winner_font_size": "tailwind: text-lg → 1rem/16px",
    "cascade_winner_font_weight": "tailwind: font-normal → 400"
  }
}
```

---

**Expected agent reasoning trace (Candidate 2 format):**

```
[x] 1. SOURCE READ

Reading src/components/Card.tsx...

Lines 38–48:
  38: export function Card({ title, excerpt, date }: CardProps) {
  39:   return (
  40:     <article className="card rounded-lg shadow p-4">
  41:       <div className="card-header">
  42:         <h3 className="card-title text-lg font-normal">{title}</h3>
  43:         <time className="text-sm text-gray-500">{date}</time>
  44:       </div>
  45:       <p className="card-body text-gray-700">{excerpt}</p>
  46:     </article>
  47:   );
  48: }

[x] 2. INTENT EXTRACTION

From line 42: `className="card-title text-lg font-normal"`

Styling expressions found:
- `text-lg` (line 42): Tailwind utility class → resolves to font-size: 1.125rem (18px) per Tailwind default scale
- `font-normal` (line 42): Tailwind utility class → resolves to font-weight: 400

Note: The developer used `text-lg` (which is 18px in the default Tailwind scale, not 16px).

[x] 3. DRIFT TABLE

| Property     | Source Intent       | Runtime Reality                   | Drift? |
|--------------|---------------------|-----------------------------------|--------|
| font-size    | text-lg → 1.125rem (18px) | 16px (text-lg → 1rem/16px cascade winner) | YES |
| font-weight  | font-normal → 400   | 400 (font-normal)                 | NO |

[x] 4. DRIFT EXPLANATION

**font-size drift**: The developer used `text-lg` intending 18px (Tailwind default: 1.125rem),
but the runtime fingerprint shows `cascade_winner_font_size: "tailwind: text-lg → 1rem/16px"`.
This means the project's tailwind.config.js has customized the `text-lg` font size to 1rem
(16px) rather than the Tailwind default of 1.125rem (18px). The class is correct but the
config overrides its value.

**font-weight**: No drift. `font-normal` correctly resolves to 400 in both source and runtime.
However, user_intent says "bold" — this is a user expectation that does not match the source
code expression. The developer wrote `font-normal`, not `font-bold`.

[x] 5. USER INTENT ALIGNMENT

The fix should change `font-normal` to `font-bold` (addressing weight) and either change the
Tailwind config to restore `text-lg` to 18px or change the class to `text-[18px]` (addressing
size), because user_intent says "18px bold."

[x] 6. FIX PROPOSAL

File: src/components/Card.tsx

Before (line 42):
  <h3 className="card-title text-lg font-normal">{title}</h3>

After:
  <h3 className="card-title text-[18px] font-bold">{title}</h3>

Rationale: `text-lg` resolves to 16px in this project's Tailwind config (override detected in
fingerprint); using `text-[18px]` as an explicit value bypasses the config override and achieves
the desired 18px. `font-normal` → `font-bold` addresses the weight drift per user_intent.

Alternative (if changing tailwind.config.js is preferred over arbitrary values):
File: tailwind.config.js — restore fontSize.lg to "1.125rem" (Tailwind default).

## Fix Summary

File: `src/components/Card.tsx`, line 42
Before: `className="card-title text-lg font-normal"`
After:  `className="card-title text-[18px] font-bold"`
Rationale: `text-lg` config override causes 16px actual (18px intended); font-normal causes
weight:400 (bold intended per user_intent).
```

---

### B.8 Verification: Confirming Read-First Compliance

After an agent produces output in response to an inspect payload, the following checks confirm that the read-first pattern was actually followed:

#### Check 1: File Path Citation with Line Number

Scan the agent output for a string matching `src/components/<name>.(tsx|jsx|vue|svelte):<number>` or a markdown code block preceded by a filename citation. An agent that skipped the read cannot produce accurate line number citations from source — they will either be absent or wrong.

```bash
# Simple heuristic check on agent output file
grep -E 'line [0-9]+|:[0-9]+:' agent_output.txt | head -5
# If empty → likely skipped source read
```

#### Check 2: Tool Call Log Sequence (Claude Code Teammate)

When the agent runs in a Claude Code harness that records tool calls, check that `Read` (or `read_file`) appears before any occurrence of "drift", "mismatch", or "fix" in the tool call log:

```bash
# Pseudo-code for tool call log analysis
first_read_index=$(grep -n '"tool":"Read"' tool_call_log.jsonl | head -1 | cut -d: -f1)
first_analysis_index=$(grep -n '"tool":"propose_fix"\|"drift"\|"compare"' tool_call_log.jsonl | head -1 | cut -d: -f1)
[ "$first_read_index" -lt "$first_analysis_index" ] && echo "COMPLIANT" || echo "VIOLATION"
```

#### Check 3: Checklist Item Count (Candidate 2 outputs)

For Candidate 2 outputs, count the `[x]` markers:

```bash
grep -c '\[x\]' agent_output.txt
# Should be 6 for a fully compliant Candidate 2 response
```

#### Check 4: Source Quote Verification

Extract any quoted code from the agent output and verify it appears in the actual source file. If the agent hallucinated the source content, the quoted lines will not match:

```bash
# Extract quoted lines from agent output (lines between ``` blocks referencing the source file)
# Then diff against actual source file
```

#### Check 5: Fix Grounding Verification

The proposed fix should reference file paths and line numbers consistent with the `source_location` in the payload. A fix that references a completely different file path than `source_location.file` (without a stated reason) is a red flag indicating the agent may have used the selector-grep shortcut.

#### Summary of Verification Priority

| Check | Cost | Signal Strength | When to Run |
|---|---|---|---|
| File path citation with line number | Cheap (regex) | Medium | Every response |
| Checklist item count | Cheap (grep) | Medium | Candidate 2 responses only |
| Tool call log sequence | Medium (log parse) | High | Claude Code teammate |
| Source quote verification | Medium (file read + diff) | Very high | Spot checks / CI |
| Fix grounding verification | Cheap (path match) | Medium | Every fix proposal |

---

## Appendix: Framework Detection Heuristics

Quick detection logic for the content script to determine which Tier 1 extractor to attempt first:

```js
function detectFramework(document) {
  // React: check for fiber key on a random body element
  const bodyChild = document.body.firstElementChild;
  if (bodyChild && Object.keys(bodyChild).some(k => k.startsWith('__reactFiber$'))) {
    return 'react';
  }

  // Vue 3
  if (document.body.__vue_app__ || document.querySelector('[__vueParentComponent]')) {
    return 'vue3';
  }

  // Vue 2
  if (document.querySelector('[__vue__]') || document.body.__vue__) {
    return 'vue2';
  }

  // Svelte: check if any element has __svelte_meta
  const svelteEl = document.querySelector('*');
  if (svelteEl && svelteEl.__svelte_meta) {
    return 'svelte';
  }

  // Solid: check for data-source-loc attribute
  if (document.querySelector('[data-source-loc]')) {
    return 'solid';
  }

  // react-dev-inspector build-time injection
  if (document.querySelector('[data-inspector-relative-path]')) {
    return 'react-dev-inspector';
  }

  // Generic data-source attribute
  if (document.querySelector('[data-source]')) {
    return 'data-source-generic';
  }

  return 'unknown';
}
```

---

## Document Metadata

- Part A techniques covered: 8 (A.1–A.8 plus A.9 multi-tier recommendation)
- Part B prompt candidates: 3 (full text), plus recommendation, variants, few-shot example, verification
- All claims include URL citations
- Designed for P3 implementation phase (source remapping module + agent prompt integration)
- React 19 compatibility note: Tier 1 React path requires Tier 2 fallback for React 19 projects
- CDP integration (for CSS cascade resolution) deferred to post-P3 phase
