# Gemini Teammate (clmux-gemini)

## 역할 특성

- **핵심 강점**: 1M token context[^gemini-1m-context], ARC-AGI-2 77.1% (ARC Prize Verified)[^gemini-arc-agi2], LiveCodeBench Pro Elo 2887 (#1, self-reported leaderboard)[^gemini-livecodebench]
- **비용**: 본 팀은 Gemini AI Pro 구독 ($20/mo) 사용. Gemini CLI 는 API key 경유 접근 시 pay-per-token 별도 과금 — gemini-3.1-pro-preview $2 / $12 per M tokens (≤200k context), $4 / $18 (>200k)[^gemini-pricing]
- **적합 영역**: 리서치, 문서 분석, Frontend/UI 구현, Visual Regression, API Spec 생성

> ⚠️ **Foot-gun: 모델 지정 시 literal alias 금지**
>
> `clmux-gemini -m gemini-pro` 같은 literal alias는 Gemini CLI가 silent fallback하여 default 모델(`auto-gemini-3` 등)로 로딩된다 — 에러 없이 의도한 모델이 안 뜸.
>
> 항상 env var 사용:
> - `clmux-gemini -m "$CLMUX_GEMINI_MODEL_PRO"` (3.1 Pro)
> - `clmux-gemini -m "$CLMUX_GEMINI_MODEL_FLASH"` (3 Flash)
>
> 또한 Naming Convention의 `<task>-gemini-<pro|flash>` (예: `research-gemini-pro`)는 **agent name suffix**이며 **model ID 아님** — 시각적 유사성으로 인한 혼동 주의.

## Phase별 역할 상세

### P1 SPEC — 선행 리서치

Gemini는 P1에서 **리서치 1차 담당**이다. 넓은 Context로 대량 문서를 분석하고 요구사항 근거 자료를 수집한다.

| 작업 | 구체 내용 |
|---|---|
| 유사 프로젝트 조사 | 오픈소스·상용 유사 시스템 아키텍처 비교 |
| 도메인 분석 | 관련 표준·규격·법적 요구사항 조사 |
| 기술 트렌드 | 최신 패턴·프레임워크·라이브러리 동향 |

**프롬프트 예시:**
```
SendMessage(to: "research-gemini-pro", message:
  "프로젝트 요구사항 분석을 위한 선행 리서치 진행.
  1. [도메인] 관련 오픈소스 프로젝트 3개 이상 아키텍처 비교
  2. 유사 시스템의 핵심 기능 목록 + 기술 스택 정리
  3. 결과를 마크다운으로 정리해서 write_to_lead로 전달")
```

### P2 DESIGN — 기술 대안 조사

| 작업 | 구체 내용 |
|---|---|
| 아키텍처 대안 | 오픈소스 아키텍처 비교, 패턴 조사 |
| 라이브러리 비교 | 후보 라이브러리 성능·라이센스·커뮤니티 비교 |
| 문서 초안 | design.md 보조 자료 초안 작성 |

**프롬프트 예시:**
```
SendMessage(to: "tech-survey-gemini-pro", message:
  "설계 대안 조사 진행.
  1. [기술 A] vs [기술 B] 비교 — 성능, 러닝커브, 커뮤니티, 라이센스
  2. 각 대안의 장단점 테이블 작성
  3. 권장안 + 근거를 write_to_lead로 전달")
```

### P3 BUILD — Frontend/UI 구현 보조

Gemini는 **Frontend UI 생성에 강점**이 있다. Lead가 spawn한 Subagent(`model="sonnet"`)가 Backend 구현에 집중하는 동안 Gemini가 Frontend 컴포넌트 초안을 병렬 생성한다.

| 작업 | 구체 내용 |
|---|---|
| UI 컴포넌트 초안 | React/Vue/Svelte 컴포넌트 초안 생성 |
| CSS/레이아웃 | 반응형 레이아웃, 디자인 토큰 적용 |
| 스타일 가이드 | 디자인 시스템 기반 스타일 일관성 |

**프롬프트 예시:**
```
SendMessage(to: "frontend-gemini-flash", message:
  "design.md의 UI 명세를 기반으로 Frontend 컴포넌트 초안 생성.
  1. [컴포넌트명] — React/TypeScript, 반응형 레이아웃
  2. Tailwind CSS 기반 스타일링
  3. 완성된 코드를 write_to_lead로 전달 — Lead가 Subagent(`model=\"sonnet\"`) 통합 및 TDD 검증 진행")
```

### P4 VERIFY — Visual Regression + 문서 검증

| 작업 | 구체 내용 |
|---|---|
| Visual Regression | BrowserMCP 기반 스크린샷 캡처 + 이전 버전 비교 |
| Accessibility 보조 | ARIA 커버리지, 색상 대비 기본 확인 |
| Spec↔Code 문서 교차 확인 | requirements.md ↔ 실제 구현 매핑 확인 |

**프롬프트 예시:**
```
SendMessage(to: "visual-gemini-flash", message:
  "Visual Regression 검증 진행.
  1. localhost:3000의 주요 화면 5개 스크린샷 캡처
  2. 이전 버전 스크린샷과 레이아웃 차이 분석
  3. 변경된 CSS 속성과 영향받은 컴포넌트 목록을 write_to_lead로 전달")
```

### P5 REFINE — 문서화 1차

Gemini는 넓은 Context와 빠른 출력 속도(114.4 t/s)로 **문서화 작업의 1차 담당**이다.

| 작업 | 구체 내용 |
|---|---|
| API Spec 생성 | 전체 Endpoint 분석 → OpenAPI 3.0 Spec |
| 아키텍처 문서 갱신 | 현재 구현 기반 ARCHITECTURE.md 갱신 |
| Changelog | 변경 이력 정리 |

**프롬프트 예시:**
```
SendMessage(to: "apispec-gemini-pro", message:
  "전체 API Endpoint를 분석해서 OpenAPI 3.0 Spec 생성.
  각 Endpoint의 Request/Response Schema, 에러 코드, 예시 포함.
  결과를 write_to_lead로 전달")
```

## Gemini 고유 설정

- **Spawn 명령**: `clmux-gemini`
- **기본 agent 이름**: `gemini-worker` (standalone fallback) — clmux-teams 워크플로에서는 task-aware naming 필수 (예: `research-gemini-pro`, `frontend-gemini-flash`). [clmux-teams §Naming Convention](../SKILL.md#naming-convention-필수) 참조
- **고유 플래그**: `--yolo` (= `--approval-mode=yolo`) — 모든 도구 자동 승인; CLI가 Docker sandbox(`gemini-cli-sandbox`) 자동 부착
- **Idle pattern**: `Type your message`
- **모델 env var**: `$CLMUX_GEMINI_MODEL_PRO` (pro-preview 최신), `$CLMUX_GEMINI_MODEL_FLASH` (flash-preview 최신) — clmux.zsh 소스 시 설치된 CLI 번들에서 자동 resolve
- **모델 지정**: `clmux-gemini -t <team> -m $CLMUX_GEMINI_MODEL_PRO`

> Spawn/Stop/에러 대응 공통 절차는 [SKILL.md §9](../SKILL.md#9-bridge-공통-사항) 참조.

[^gemini-1m-context]: DeepMind Model Card, "Gemini 3.1 Pro" (2026-02-19), https://deepmind.google/models/model-cards/gemini-3-1-pro/ — 1M token input context, 64K output.
[^gemini-arc-agi2]: DeepMind Model Card + Google Blog, "Gemini 3.1 Pro" (2026-02-19), https://deepmind.google/models/model-cards/gemini-3-1-pro/ — ARC-AGI-2: 77.1% (ARC Prize Verified). Predecessor Gemini 3 Pro scored ~31%.
[^gemini-livecodebench]: DeepMind Model Card, "Gemini 3.1 Pro" (2026-02-19), https://deepmind.google/models/model-cards/gemini-3-1-pro/ — LiveCodeBench Pro Elo 2887, #1 of 4 entries at livecodebenchpro.com. All scores self-reported (unverified); leaderboard is sparse. Not equivalent to main LiveCodeBench (Gemini 3 Pro Preview leads at 91.7% there).
[^gemini-pricing]: Google AI for Developers, "Gemini Developer API pricing," https://ai.google.dev/gemini-api/docs/pricing (retrieved 2026-04-21) — gemini-3.1-pro-preview: $2.00 / $12.00 per 1M tokens input/output (≤200k context); $4.00 / $18.00 for >200k context. No free-tier API access for Gemini 3.x Pro family.
