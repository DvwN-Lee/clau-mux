# Browser Inspect Tool — Deep Research Index

## 목적

clau-mux에 frontend 디버깅 전용 "Browser Inspect Tool"을 추가하기 위한 설계 연구.
사용자가 브라우저에서 inspect mode로 요소를 클릭하면, 그 요소의 정보가 인계받은 teammate(혹은 Lead)의 입력으로 직접 주입되어, 해당 agent가 소스 코드 기반으로 drift를 분석·수정하는 워크플로를 만든다.

## Brainstorming 확정 사항 (research 진입 전)

| # | 결정 | 값 |
|---|---|---|
| 1 | 산출물 | 설계 문서(spec) 단일 |
| 2 | 구현 방식 | Lead-hosted background daemon + CLI tool (방식 A) |
| 3 | MCP 사용 | 금지 (CLI + 파일 브리지만) |
| 4 | Tool 역할 | Pointing + Source Remapping + Reality Fingerprint 브리지 (분석기 아님) |
| 5 | Payload 구성 | user_intent / pointing / source_location / reality_fingerprint (스크린샷 없음) |
| 6 | Agent 분석 방식 | 소스 코드 Read + drift 비교 (시각 데이터 사용 금지) |
| 7 | 활성화 | `clmux -b` 신규 플래그 (또는 `clmux-browser -t` 수동) |
| 8 | 프로세스 모델 | Lead 세션과 수명 동조되는 background Node daemon (Copilot MCP 서버 패턴 복제) |
| 9 | 구독 모델 | `.inspect-subscriber` 파일 기반. Lead가 `clmux-inspect subscribe`로 전환 |
| 10 | 5-stage flow | Implement(teammate) → 1차검증(teammate active) → 2차검증(Lead active) → 3차검증(user passive→Lead) → 재작업 |
| 11 | Research focus | 7개 영역 (아래) |
| 12 | Research 팀 | Claude Lead + Claude teammate(아키텍처) + Gemini(OSS) + Codex(CDP/보안) + Copilot(GitHub 생태계) |

## Research 영역 → 담당

| # | 주제 | 담당 | 산출 |
|---|---|---|---|
| R1 | Agent 기반 frontend 생성/디버깅 OSS 서베이 + 사용자 만족도 패턴 | Gemini | 01-existing-tools-survey.md |
| R2 | CDP 기술 심층 (Overlay/CSS/Page API, Chrome 수명·권한) | Codex | 02-cdp-technical-deep-dive.md |
| R3 | GitHub 생태계 + recent 2025-2026 프로젝트 + issue tracker pain point | Copilot | 03-github-ecosystem-survey.md |
| R4 | Source 역매핑 기법 + Agent prompt 템플릿 패턴 | Claude teammate | 04-source-remapping-and-prompts.md |
| R5 | Synthesis: 기존 결정 보완 + 새로운 contested 영역 정리 + spec 업데이트 권고 | Claude teammate + Lead | 05-synthesis-and-design-updates.md |

## 연구가 답해야 할 핵심 질문

1. **Agent 기반 frontend 디버깅에서 사용자 만족도가 가장 높았던 inspect payload 형태는 무엇인가?** (정량적·정성적 근거 인용)
2. **현재 확정된 12개 결정사항 중 보완·수정이 필요한 것은?** (각 항목별 evidence)
3. **brainstorming에서 미처 발견하지 못한 contested 영역은 무엇인가?** (예: SPA 라우팅 시 overlay 재주입, iframe·Shadow DOM 경계, source map이 없는 production 빌드)
4. **재사용 가능한 OSS 코드/패턴이 있는가?** 라이선스·성숙도·Claude Code 통합 가능성 평가.
5. **Source 역매핑 신뢰도가 가장 높은 기법은 무엇인가?** (React/Vue/Svelte/vanilla별)
6. **Reality fingerprint의 최소 필드 세트는?** (drift 탐지 sensitivity 대비 토큰 비용)
7. **Agent prompt에 어떤 system instruction을 박아야 "소스 먼저 Read 후 drift 비교" 패턴을 강제할 수 있는가?**

## 진행 규약

- 각 담당자는 자신의 파일을 작성·갱신
- WebSearch / WebFetch 적극 활용
- 인용은 모든 주장에 URL 출처 명시
- 추측 금지 — 근거 없는 주장은 "추정" 명시
- R5(synthesis)는 R1~R4 완료 후 작성
