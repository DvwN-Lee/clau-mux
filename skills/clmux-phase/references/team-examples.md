# 동적 팀 구성 예시 및 역할 설계

## 역할 설계 가이드

Lead가 현재 작업을 분석하여 필요한 역할을 도출한다.

### 컨텍스트 분석 절차

1. **도메인 파악**: 현재 대화에서 프로젝트 도메인 식별 (웹, 데이터, 인프라, 문서 등)
2. **리스크 레벨 판정**: High/Medium/Low → 프로토콜 차등
3. **작업 분해**: 병렬 가능한 독립 작업 단위 식별
4. **역할 매핑**: 각 작업 단위에 필요한 역할 타입 도출 (설계/구현/검증/조사/critic/challenger)
5. **Cross-Provider 구성**: 비-Claude provider_family 최소 1개 포함 (Rule 3)
6. **팀 규모 조정**: 작업 단위 수 vs 조율 오버헤드 균형

### Phase별 역할 참여 가이드라인

| Phase | 주도 역할 유형 | 보조 역할 유형 | Cross-Provider |
|-------|-------------|-------------|---------------|
| P1 SPEC | 설계 | 조사, 구현 | Gemini: 독립 재해석 |
| P2 DESIGN | 설계 | 구현, 조사, 검증 | Gemini Pro: frame challenger |
| P3 BUILD | 구현 | 조사 (Grounding) | Codex: boilerplate, Copilot: PR review |
| P4 VERIFY | 검증 | 조사 (CVE 등) | Codex: 보안, Copilot: GitHub 증거 |
| P5 REFINE | 구현 + 설계 | 검증 | Copilot: 판정 로그 감사 |

> **Generator-Validator 분리**: P3 구현 담당자가 P4 검증도 담당하면 편향이 생긴다.
> **Cross-Provider 검증**: 동일 provider_family 내에서만 검증하는 것은 Rule 3 위반.

### 태스크 유형별 Teammate 조합 패턴

| 태스크 유형 | 주도 역할 | 보조 역할 | Cross-Provider 역할 |
|------------|---------|---------|-------------------|
| 요구사항 정의 | 설계 담당 | 조사, 구현 | Gemini: 독립 재해석 |
| 시스템 설계 | 설계 담당 | 구현, 조사, 검증 | Gemini Pro: challenger |
| TDD 구현 | 구현 담당 | 조사 (Grounding) | Codex: 병렬 구현 |
| 교차 검증 | 검증 담당 | 조사 (CVE 등) | Codex: 보안, Gemini Pro: challenger |
| 수정/Spec 동기화 | 구현 + 설계 | 검증 | Copilot: PR ops |
| Hotfix | Lead 또는 구현 담당 단독 | — | Rule 11 적용 (긴급 경로) |

## 팀 구성 예시

### Provider-Diverse 풀팀 (Cross-Provider, 5명+)

```
TeamCreate("clmux-{project}", "{설명}")
├── architect (Opus)              — 설계, EARS, 아키텍처
├── dev (Sonnet)                  — TDD, 구현 + secondary critic + rebuttal
├── analyst (Opus)                — 교차 검증, V-1~V-4
├── gemini-worker (Gemini Pro)    — 리서치, frame challenger, alt impl reviewer
├── codex-worker (Codex)          — 보안, 성능, EP 정규화 (구현과 분리)
└── copilot-worker (Copilot)      — PR ops, GitHub 증거, 판정 로그 감사
```

> **Rule 3 충족**: anthropic(Opus/Sonnet) + google(Gemini) + openai(Codex) + github(Copilot) = 4 provider_family

### Provider-Diverse 소규모 (Cross-Provider, 3명)

```
TeamCreate("clmux-{project}", "{설명}")
├── dev (Sonnet)                  — 설계+구현+검증 겸임 + critic
├── gemini-worker (Gemini Pro)    — 리서치 + challenger
└── codex-worker (Codex)          — 보안 + EP 정규화
```

### Claude-Only 소규모 (clmux 비가용, 2명)

```
TeamCreate("clmux-{project}", "{설명}")
├── designer (Opus)  — 설계 + 검증 겸임
└── builder (Sonnet) — 구현 + 조사 겸임
```

> **주의**: Rule 3 미충족 — Lead가 판정 로그에 "clmux 비가용, Cross-Provider 검증 불가" 명시 필수.

### 표준 팀 (Claude-Native, 4명)

```
TeamCreate("clmux-{project}", "{설명}")
├── architect (Opus)    — 설계, EARS, 아키텍처
├── analyst (Opus)      — 교차 검증, V-1~V-4
├── dev (Sonnet)        — TDD, Worktree 빌드
└── researcher (Sonnet) — Grounding, 선행 조사
```

### 보안 강화 팀 (5명+)

```
기본 4명
+ security-reviewer (Opus)      — P4 V-2 전담
+ codex-worker (Codex)          — Codex Security 보안 스캔 + PoC 검증
```

### 웹 개발 팀 (Cross-Provider, 4명)

```
TeamCreate("clmux-{project}", "{설명}")
├── backend-dev (Sonnet)          — API, DB, 비즈니스 로직
├── gemini-worker (Gemini Flash)  — Frontend UI 1차 (WebDev Arena #1)
├── copilot-worker (Copilot)      — PR Review + GitHub 증거
└── ux-reviewer (Opus)            — 접근성, UX 검증
```

### 데이터 파이프라인 팀 (3명)

```
TeamCreate("clmux-{project}", "{설명}")
├── data-engineer (Sonnet)  — ETL 구현, 스키마 설계
├── ml-engineer (Sonnet)    — 모델 통합, 피처 엔지니어링
└── data-validator (Opus)   — 데이터 품질, 정합성 검증
```

### 인프라/DevOps 팀 (Cross-Provider, 4명)

```
TeamCreate("clmux-{project}", "{설명}")
├── infra-builder (Sonnet)        — IaC 구현, 프로비저닝
├── security-reviewer (Opus)      — 보안 정책, 취약점 검토
├── codex-worker (Codex)          — Terraform Plan 분석, CI Pipeline
└── copilot-worker (Copilot)      — GitHub Actions, 배포 검증
```
