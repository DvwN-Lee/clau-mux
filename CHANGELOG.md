# Changelog

All notable changes to clau-mux will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.3.0] - 2026-04-08

### Added
- **Browser Inspect Tool (`clmux -b` flag)**: Frontend debugging via CDP-driven click capture.
  Browser element clicks → 4-section payload (pointing / source_location / reality_fingerprint / user_intent) → subscribed agent's inbox.
  See `docs/browser-inspect-tool.md`.
- `clmux-inspect` CLI (5 commands: subscribe / unsubscribe / toggle / query / snapshot / status)
- `browser-service/` Node.js daemon (Lead-hosted background process, mirrors `bridge-mcp-server.js` pattern)
- Multi-tier source remapping: React 18/19, Vue 3, Svelte 4, Solid (T1 runtime hook → T2 data-source-file → T4 honest unknown)
- Agent prompt template with NEW-1 mitigation (공통 컴포넌트 wrong-file 수정 방지 via import count check)
- `"engines": { "node": ">=20.0.0" }` — explicit Node version requirement

### Changed
- `clmux.zsh` adds `-b` flag + `_clmux_launch_browser_service`/`_clmux_stop_browser_service` functions
- `scripts/setup.sh` registers `bin/clmux-inspect` in PATH
- `scripts/remove.sh` adds platform-aware Chrome profile cleanup
- `package.json` adds `chrome-remote-interface@^0.33.2` dependency

### Security
- Chrome launched with `--remote-debugging-port=0 --user-data-dir=<isolated>` (mandatory, 2025 Chrome security policy compliance)
- HTTP server binds to `127.0.0.1` only
- All runtime files `chmod 0600`
- Path validation scoped to `~/.claude/teams/<team>/inboxes/<agent>.json`
- `FR-405` — no screenshots or base64 image data in payload
