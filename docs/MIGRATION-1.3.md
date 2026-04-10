# Migrating to clau-mux 1.3.0 (Browser Inspect Tool)

## TL;DR
- **Breaking changes**: NONE. `-b` flag is opt-in.
- **New requirement**: Node.js 20+ (enforced via `package.json` engines field)
- **New CLI tool**: `clmux-inspect` (registered by `scripts/setup.sh`)

## What changed

### New `-b` flag
`clmux -n proj -gb -T proj-team` launches an isolated Chrome + daemon alongside Lead.
Without `-b`, clmux behavior is 100% unchanged (existing `-g`, `-x`, `-c` flags work as before).

### New dependency
`chrome-remote-interface@^0.33.2` added to `package.json`. Run `npm install` in the clau-mux directory.

### Node 20+ required
`package.json` now specifies `"engines": { "node": ">=20.0.0" }`. Node 16/18 users will see npm warnings.
Upgrade via `nvm install 20 && nvm use 20` before running `npm install`.

## What didn't change
- `clmux -n`, `-g`, `-x`, `-c`, `-T` flags — identical behavior
- Existing tmux session handling
- Existing teammate inbox format (BIT reuses it for payload delivery)
- Existing `bridge-mcp-server.js` lifecycle

## Rollback
Remove the `-b` flag. To fully remove BIT artifacts:
```bash
bash ~/clau-mux/scripts/remove.sh browser
```

This stops any running browser-service / Chrome processes and removes isolated profiles.

## Known limitations (MVP)
- macOS primary target (Linux supported via `$XDG_STATE_HOME` but less tested)
- React 19 requires `react-dev-inspector` plugin (auto-fallback from removed `_debugSource`)
- Cross-origin iframes skipped (same-origin only)
- Tier 3 source-map stacktrace deferred to post-MVP
