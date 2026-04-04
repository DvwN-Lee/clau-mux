# VETO-REVIEW
## Teammate: sonnet-worker

1. FIX — bridge-mcp-server.js fallback이 `/tmp/clmux-bridge-*.env`를 스캔하는데, 리팩토링 후 env 파일 위치가 `$team_dir/.bridge-<agent>.env`로 변경됨(clmux.zsh:310). 현재 fallback은 파일을 아예 못 찾는 상태 — 다중 팀 문제 이전에 단일 팀에서도 broken.

2. FIX — `_clmux_spawn_agent_in_session`은 positional args만 받아 agent_name과 timeout이 하드코딩(default_agent_name 그대로, timeout=30 고정). `_clmux_spawn_agent`의 `-n`/`-x` 옵션 패리티 미달. `clmux -g` 경로에서 커스텀 agent 이름 지정 불가.

3. FIX — sync-protocol.sh 미실행으로 GEMINI.md/AGENTS.md 상단에 생성 주석 없음. 직접 확인했으며, 파일이 수동 작성 상태로 남아있음.

4. FIX — clmux.zsh에 `-g`/`-T` 플래그 및 `clmux-codex`/`clmux-codex-stop` 구현됨(line 391, 397)에도 README 명령어 요약 테이블에 전혀 없음. 직접 확인했음.

5. FIX — clmux.zsh:307과 :213에서 `$cli_cmd`("gemini"/"codex")가 update_pane.py의 `model_name` 파라미터로 전달됨. 현재는 cli_cmd와 model명이 일치해 기능적으로 작동하지만, 의미상 오류이며 다른 CLI 추가 시 버그가 됨. 호출부에서 명시적 model 이름을 전달하거나 파라미터명 정렬 필요.

6. FIX — `_clmux_stop_agent`(line 331-372)가 pid 종료, pane 닫기, env 파일 삭제만 하고 config.json의 `isActive: true`를 갱신하지 않음. stop 후 config.json이 stale 상태로 남아 다음 spawn에서 중복 member 등록 로직에 영향 가능.

7. FIX — package.json에 `"scripts": {"sync": "bash scripts/sync-protocol.sh"}` 추가 권장. 작은 변경이지만 GEMINI.md/AGENTS.md 동기화 진입점을 노출시켜 이슈 3 재발 방지에 도움.

8. FIX — dead code는 유지 비용만 올리고 오독 위험이 있음. 제거가 맞음.

9. SKIP — 이상 없음, 수정 불필요.
