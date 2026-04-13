# Changelog

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
