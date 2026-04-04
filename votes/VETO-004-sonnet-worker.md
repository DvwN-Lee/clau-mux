# VOTE: Approve
## Teammate: sonnet-worker
## 안건: VETO-004
## 근거

GEMINI.md와 AGENTS.md를 직접 비교한 결과, 두 파일은 agent name(`gemini-worker` vs `codex-worker`) 한 단어만 다르고 나머지 22줄이 완전히 동일하다. 이 수준의 중복은 유지보수 부채가 명확하다 — 프로토콜 규칙을 바꾸면 두 파일을 모두 수정해야 하며, 한쪽만 바뀌는 drift가 실제로 발생할 수 있다.

통합의 기술적 위험도 낮다. Gemini CLI는 `GEMINI.md`를, Codex CLI는 `AGENTS.md`를 자동 로드하지만, `clmux-gemini`/`clmux-codex` spawn 시점에 템플릿에서 실제 파일을 생성하면 각 CLI는 기존과 동일하게 동작한다. 이미 분석 결과에서 두 spawn 함수를 `_clmux_spawn_agent`로 통합하는 방안을 제안했는데, 그 맥락에서 파일 생성도 함께 처리하면 자연스럽다.

## 구현 조건

1. 템플릿 파일(`teammate-protocol.md`)에 `{{AGENT_NAME}}` placeholder 사용
2. spawn 함수에서 CLI 실행 직전에 sed로 치환 후 각 파일에 기록
3. `GEMINI.md`와 `AGENTS.md`는 `.gitignore`에 추가(generated files)하거나, 템플릿이 source of truth임을 파일 상단에 명시
4. CLI를 clmux 외부에서 직접 실행하는 경우를 위해 README에 수동 생성 방법 기록
