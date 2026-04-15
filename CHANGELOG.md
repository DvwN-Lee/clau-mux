# Changelog

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
