# Changelog

## 1.3.5 — 2026-04-16

### Fixed
- **Phase 2 #14 — idle-aware `notify_pane` (Issue #25 root fix).** v1.3.1's prefix change (`[orch]` → `# orch:`) silenced the zsh glob error but left the blind-paste problem intact: panes running Claude Code absorbed the alert into the user-input box, and editors / REPLs received random keystrokes. `notify_pane` now detects the target pane's foreground command via `tmux display-message -p '#{pane_current_command}'` and routes per receiver:
  - shell (`zsh`/`bash`/`fish`/`sh`/`dash`/`ksh`) → existing paste path
  - Claude Code / Node (`claude`/`node`) → `tmux set-option @orch_last_alert <msg[:80]>` (side-channel, surfaces via status-line format)
  - unknown / detection failure → skip (inbox record remains authoritative)
  
  Inbox records are always written by the CLI handler *before* `notify_pane`, so every alert is durable regardless of notify outcome. See `docs/orchestration.md` "notify_pane behavior" for the full decision tree.
- **New env var `CLMUX_ORCH_NOTIFY_MODE=auto|paste|status|skip`** — operator escape hatch. `auto` (default) is the new idle-aware routing; `paste` restores v1.3.1 unconditional paste behavior; `status`/`skip` force the respective modes.

### Tests
- 84 unit tests (was 78; +6 TestNotify: claude-code skips paste, zsh uses paste, unknown foreground skips, status-mode option truncation, env-override forces paste, graceful degradation when `display-message` fails). Integration shell tests and the 13-test pipeline suite unaffected.

## 1.3.4 — 2026-04-16

### Fixed
- **Issue #24: native Agent-tool subagent shutdown leaves `isActive=true`
  stale.** Bridge teammates self-clean via `clmux-bridge.zsh`'s
  `trap cleanup INT TERM EXIT`, but Agent-tool subagents (agentType
  `general-purpose`) have no wrapper process, so config.json drifts whenever
  a subagent's pane/process dies (shutdown_request, turn end, OS kill). New
  reconciliation path closes the gap uniformly for all agentTypes: any member
  with `isActive=true` and a `tmuxPaneId` that is no longer in
  `tmux list-panes -a` is flipped to `isActive=false`.
- **Issue #3: copilot-worker `isActive=false` regression guard.** No
  copilot-specific branch in `update_pane.py` — regression test locks in that
  copilot-worker is treated identically to gemini/codex on both fresh spawn
  and respawn after shutdown.

### Added
- `scripts/reconcile_active.py` — standalone CLI that reconciles a single
  team's config.json against tmux pane liveness. Locks the config via the
  same mkdir mutex used by `update_pane.py` / `deactivate_pane.py` so a race
  with a concurrent spawn can't clobber either write.
- `hooks/reconcile-active.py` — `SessionStart` hook wrapper that scopes
  reconciliation to teams with `leadSessionId == session_id` (avoids touching
  other sessions' teams in a multi-session environment).
- `scripts/setup.sh` installs the new hook alongside `guard-task-bridge.py`
  and prints the `SessionStart` registration snippet.

### Tests
- `tests/test_cleanup_hooks.py` — 10 tests: reconcile flips dead-pane
  isActive to false (bridge + general-purpose), preserves live-pane true,
  skips empty `tmuxPaneId`, is idempotent, degrades safely on missing
  config; hook scopes by `leadSessionId`; update_pane.py copilot regression
  (new and respawn). 88 pytest + 13 pipeline shell tests total.

## 1.3.3 — 2026-04-15

### CI
- `.github/workflows/orchestrate.yml` now runs `tests/test_clmux_pipeline.sh` on
  PR/push so regressions in the pipeline wrapper are caught before merge. Path
  triggers extended to include `scripts/clmux_pipeline.py` and
  `tests/test_clmux_pipeline*`.

### Docs
- `docs/orchestration.md` — added **Runtime silencing** section documenting
  `CLMUX_ORCH_NO_NOTIFY=1` for headless / demo / automated-script operators.
  Previously only mentioned in the 1.3.1 test-isolation context.
- `docs/investigations/issue-10-outbox-rmw.md` — investigation report
  concluding that the bridge outbox RMW race (Issue #10) was fixed in
  commit `ef2cdcd` (`withLock()` mkdir-mutex around `writeToLeadImpl`'s
  read-modify-write sequence). Recommend closing Issue #10.

## 1.3.2 — 2026-04-15

### Added
- **clmux-pipeline**: tmux + iTerm session lifecycle wrapper. Subcommands
  `create / shutdown / shutdown-tagged / list / info / kill`. Graceful-first
  shutdown (Claude Code `/exit`, shell `exit`, fallback `C-d`) with
  timeout-based force fallback. iTerm window close by stored window-id only —
  never pattern matching. See `docs/pipeline.md`.
- `docs/pipeline.md` — user guide + architecture + safety invariants

### Fixed
- Regression guard for prior-session incident where AppleScript
  `contents of session` grep closed unrelated iTerm windows. Pipeline's safety
  invariants (id-only close, graceful-first, per-session isolation) codified
  and covered by `tests/test_clmux_pipeline.sh` T12 (safety regression test).

### Tests
- `tests/test_clmux_pipeline.sh` — 13 shell integration tests covering create
  (headless + iTerm + tag + cwd), shutdown (graceful / dry-run / force /
  timeout fallback), shutdown-tagged, list, info, safety regression, and
  session-name injection rejection. Baseline 78 pytest suite unaffected.

## 1.3.1 — 2026-04-15

### Added
- **Pane orchestration Phase 2 #1 — `blocked` / `reply` state machine.** Sub can now formally pause for clarification instead of relying on an out-of-band channel. New envelope kinds `blocked` (Sub→Master, body: `question`, optional `options[]` + `urgency`) and `reply` (Master→Sub, body: `answer`, optional `note`). New state transitions: `IN_PROGRESS --blocked--> BLOCKED` and `BLOCKED --reply--> IN_PROGRESS`. CLI: `clmux-orchestrate blocked` + `clmux-orchestrate reply`. See `docs/orchestration.md` "State machine" + "Sub asks for clarification" sections.

### Fixed
- **Issue #25: `notify_pane` prefix → `# orch:` (was `[orch]`).** The `[orch]` prefix was glob-expanded by zsh on the receiving pane, producing `no matches found: [orch]` errors and prompt pollution. Switched to `# orch:<kind> ...` — a shell comment prefix — so the paste is discarded silently regardless of shell.
- **Test isolation** — `TestCLI` subprocesses no longer invoke real `tmux paste-buffer` against the operator's live panes. `notify_pane()` now short-circuits when `CLMUX_ORCH_NO_NOTIFY=1`; `TestCLI._run` sets this env var in every subprocess. Operators can also use this flag to silence notifications transiently.

### Tests
- 78 unit tests (was 65; +4 BLOCKED transitions, +5 blocked/reply envelope validation, +2 CLI blocked/reply, +1 notify prefix guard, +1 notify isolation env var).

## 1.3.0 — 2026-04-15

### Added
- **Pane orchestration protocol (Phase 1 MVP)** — hierarchical Master/Sub delegation across Claude Code panes, with thread-level audit (JSONL), meeting 1-off with WORM archive, and resume-across-sessions. CLI: `clmux-orchestrate` (set-master, handover, register-sub, delegate, ack, progress, report, accept, reject, close, meeting {start,end,release}, inbox, thread, panes, resume). See `docs/orchestration.md`.
- **Corporate Hierarchy Pattern** documented for Desktop → Project → Worktree org layouts; use `--label` to identify which worktree each Sub serves.
- **Crash-recovery flags** — `release-master --force` and `meeting release --force` for clearing stuck locks after pane death.

### Tests
- `tests/test_orchestrate.py` — 65 unit tests across storage, envelope, lock, panes, thread, inbox, notify, meeting, resume, CLI.
- `tests/test_orchestrate_integration.sh` — end-to-end shell test covering full delegate→ack→report→accept→close cycle plus meeting archive.

### Known limitations (Phase 2 candidates)
See `docs/orchestration.md` "Known limitations". No `blocked`/`reply` state yet, no cascade cancel, no cross-machine coordination, advisory-only WORM semantics.

## [Unreleased]

### Fixed

#### clmux-bridge: 대용량 메시지 truncation 수정 (2026-04-14)

**문제**: Gemini/Codex CLI로 전달되는 메시지가 ~1024 bytes에서 무음으로 잘리는 버그.  
**원인**: macOS PTY 커널 버퍼 한계 — bracketed paste 이벤트 1회당 ~1024 bytes 초과 시 truncation 발생.

**수정 내용** (`clmux-bridge.zsh`):
- **청크 분할 전달**: 300자(≤900 bytes) 단위로 나눠 `tmux paste-buffer` 반복 호출
- **PTY drain 대기**: 5 chunk마다 0.3s pause 추가 (버퍼 포화 방지)
- **Post-paste delay**: `0.5s + chunk수 × 0.2s` (최대 8s)
- **Enter 감지 개선**: idle 패턴 유무 → pane 해시 비교 방식으로 교체  
  (Gemini가 빠르게 응답 후 idle 복귀 시 false retry 방지)
- **Enter retry**: 최대 5회, 간격 3s
- **Idle 감지 개선**: `tail -5` → 공백 제거 후 `tail -8`로 변경
- **로그 개선**: 메시지 길이와 앞 120자 표시
- **defer 한도**: 3→6회, 대기 2→5s
- **타임아웃 기본값**: 30→60s
- **디버그 노이즈 제거**: 메인 루프 내 `local` 선언 제거 (zsh typeset 출력 방지)

**수정 내용** (`scripts/update_pane.py`):
- `config.json` 없을 때 `FileNotFoundError` 수정 (수동 생성 팀 지원)

**검증**: Gemini CLI, Codex CLI 양쪽에서 500b / 2048b / 4096b / 8093b 모두 4/4 통과.
