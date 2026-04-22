# Phase별 모델 선택 매트릭스

Lead/Teammate가 Subagent를 spawn할 때 아래 매트릭스를 참조한다.

## Cross-Provider 모델 배치

| Provider | 모델 | provider_family | 핵심 역할 |
|----------|------|----------------|----------|
| Anthropic | Claude Opus | `anthropic` | Lead (Protocol Manager) **only** — Teammate 사용 금지 |
| Anthropic | Claude Sonnet | `anthropic` | Lead Session OR Lead가 spawn하는 Subagent (TDD/구현/리뷰) — **Teammate 사용 금지** |
| Anthropic | Claude Haiku | `anthropic` | Subagent only (기계적 변환, 추출) — Lead가 spawn |
| Google | Gemini 3.1 Pro | `google` | Teammate — 리서치, frame challenger, alt implementation reviewer, long-context code reviewer (1M ctx), critic |
| Google | Gemini 3 Flash | `google` | Teammate — 빠른 조사, Visual Regression, Grounding |
| OpenAI | Codex GPT-5.4 | `openai` | Teammate — 구현, 코드 리뷰, secondary critic, rebuttal, Evidence Pack 정규화 (본격 보안 스캔은 Codex Security 기능으로 ChatGPT Pro $100+ 티어 한정 — 본 팀 Plus 티어 미접근) |
| GitHub | Copilot | `github` | Teammate — PR ops, GitHub 증거 자동 생성, 판정 로그 감사 |

> **provider_family 집계**: 같은 provider_family 내 복수 모델 = 1개 독립 Provider (Rule 3)
> **Anthropic teammate 금지**: TeamCreate 멤버는 비-Claude provider만. Anthropic 의견은 Lead와 Lead가 spawn한 Subagent로만 발생.

## P1 SPEC

| 서브태스크 | 모델 | 근거 |
|-----------|------|------|
| PRD 파일 읽기/텍스트 추출 | **Haiku** | 순수 Read-only |
| 모호성 태그 스캔 | **Haiku** | 기계적 텍스트 검색 |
| 완결성 체크 (항목 매핑) | **Haiku** | 존재 확인 |
| 요구사항 추출 (암묵적 의도) | Sonnet/Opus | 판단 필요 |
| EARS 변환 | Sonnet | 패턴 해석 |
| VETO 중재 | Opus | 헌법 기반 의사결정 |

## P2 DESIGN

| 서브태스크 | 모델 | 근거 |
|-----------|------|------|
| 기술 레퍼런스 raw fetch | **Haiku** | 추출만, 해석은 Teammate |
| tasks.md 순환 의존 탐지 | **Haiku** | 그래프 순회 |
| 인터페이스 완결성 체크 | **Haiku** | ID 존재 확인 |
| dod.md 템플릿 생성 | **Haiku** | 슬롯 채우기 |
| design.md 작성/리뷰 | Opus | 아키텍처 판단 |

## P3 BUILD

| 서브태스크 | 모델 | 근거 |
|-----------|------|------|
| Grounding: 문서 raw fetch | **Haiku** | 추출만 |
| Grounding: 컨텍스트 합성 | Sonnet | "어떤 API가 맞는지?" 판단 (Lead가 Subagent로 위임) |
| TDD [Plan/Red/Green/Refactor] | Sonnet | 엔지니어링 판단 (Lead가 Subagent로 위임 — Anthropic teammate 금지) |
| tasks.md 상태 업데이트 | **Haiku** | 기계적 필드 수정 |
| dispatch-log 엔트리 추가 | **Haiku** | 구조화된 로그 |
| mid-phase checkpoint 생성 | **Haiku** | 템플릿 채우기 |

## P4 VERIFY

| 서브태스크 | 모델 | 근거 |
|-----------|------|------|
| 리뷰 대상 파일 fetch | **Haiku** | Read-only |
| V-1 커버리지 수치 확인 | **Haiku** | threshold 비교 |
| V-1 순환 의존 탐지 (정적) | **Haiku** | 그래프 순회 |
| V-4 EARS ID 존재 체크 | **Haiku** | 존재 검색 |
| V-2 보안 (알려진 패턴) | Haiku (주의) | 신규 패턴 미탐지 위험 — Sonnet 검증 병행 권장. Deep 취약점 스캔은 Codex Security 필요 (Plus 티어 미접근) |
| V-4 의미적 대응 | Sonnet | 의미 판단 |
| 비관적 통합 + 보고서 | Sonnet/Opus | 교차 합성 |

## P5 REFINE

| 서브태스크 | 모델 | 근거 |
|-----------|------|------|
| MINOR 수정 (포맷팅, 네이밍, 오타) | **Haiku** | 기계적 편집 |
| Spec-Code drift 탐지 | **Haiku** | git diff + 존재 체크 |
| MAJOR 수정 (로직 수정) | Sonnet | 유지 |

## 모델 명시 규칙 (Mandatory Model Parameter)

Teammate가 Subagent를 spawn할 때 `model` 파라미터를 **MUST specify explicitly**.
미지정 시 부모 모델을 상속하므로 (기본값: `inherit`), Opus Teammate → Opus Subagent로 비용이 폭증한다.

| Subagent 용도 | 지정 모델 | 근거 |
|--------------|----------|------|
| 파일 탐색/검색/추출 | `haiku` | Sonnet 대비 3x 저렴, SWE-bench 73.3% |
| 기계적 변환 (포맷, rename, 맞춤법) | `haiku` | 패턴 매칭 강점, tool calling 0 실패 |
| 체크리스트 검증 (존재/threshold) | `haiku` | 분류/카운트 최적 |
| 템플릿 기반 생성 (checkpoint, log) | `haiku` | 슬롯 채우기, 구조화 출력 |
| 독립 코드 구현 | `sonnet` | production safety, TDD 품질 |
| 복잡 분석/해석 | `sonnet` | 추론 품질 + 비용 균형 |

> **Known Bug**: Explore subagents also inherit the parent model contrary to documentation.
> MUST specify `model` explicitly on every spawn.
>
> **Haiku Circuit Breaker**: Haiku가 3회 연속 실패 또는 looping 시 Sonnet으로 에스컬레이션 (clmux-recovery 참조).
