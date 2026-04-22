# 동적 팀 구성 예시 및 역할 설계

## 역할 설계 가이드

Lead가 현재 작업을 분석하여 필요한 역할을 도출한다.

### 컨텍스트 분석 절차

1. **도메인 파악**: 현재 대화에서 프로젝트 도메인 식별 (웹, 데이터, 인프라, 문서 등)
2. **리스크 레벨 판정**: High/Medium/Low → 프로토콜 차등
3. **작업 분해**: 병렬 가능한 독립 작업 단위 식별
4. **역할 매핑**: 각 작업 단위에 필요한 역할 타입 도출 (설계/구현/검증/조사/critic/challenger)
5. **Cross-Provider 구성**: 비-Claude provider_family 최소 1개 포함 (Rule 3) — **Anthropic teammate 금지**, anthropic은 Lead와 Subagent에서만 사용
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

### Provider-Diverse 풀팀 (Cross-Provider, 3-bridge + Lead+Subagent)

```
TeamCreate("clmux-{project}", "{설명}")
├── research-gemini-pro (Gemini Pro)    — 리서치, frame challenger, alt impl reviewer, long-context reviewer
├── security-codex (Codex)              — 보안, 성능, EP 정규화 (구현과 분리), secondary critic + rebuttal
└── pr-ops-copilot (Copilot)            — PR ops, GitHub 증거, 판정 로그 감사

Lead (Opus/Sonnet, 사용자 세션) — Protocol Manager + Subagent 위임 게이트키퍼
└── 직접 spawn하는 Subagent (1회성):
    ├── Agent(model="sonnet") — TDD/구현/리뷰 (architect, dev, analyst 역할 흡수)
    └── Agent(model="haiku")  — 탐색, 추출, 포맷팅, 체크리스트 검증
```

> **Rule 3 충족**: google(Gemini) + openai(Codex) + github(Copilot) = 3 provider_family (비-Claude 독립 지지 자동 보장)
> **Anthropic 의견**: Lead 또는 Lead spawn Subagent로만 발생 — Teammate에는 등장 안 함

### Provider-Diverse 소규모 (Cross-Provider, 2-bridge + Lead+Subagent)

```
TeamCreate("clmux-{project}", "{설명}")
├── research-gemini-pro (Gemini Pro)  — 리서치 + challenger + critic + long-context reviewer
└── security-codex (Codex)            — 보안 + EP 정규화 + 구현 보조

Lead (사용자 세션) — Protocol Manager
└── Subagent(sonnet) — 설계+구현+검증 위임 (TDD 루프 실행)
```

### Lead+Subagent only (clmux bridge 비가용, fallback)

```
TeamCreate 없이 Lead 단독 운영
Lead (Opus/Sonnet)
└── 직접 spawn하는 Subagent
    ├── Agent(model="sonnet") — 설계, 구현, 검증
    └── Agent(model="haiku")  — 탐색, 추출, 포맷팅
```

> **주의**: Rule 3 미충족 (Cross-Provider 합의 불가) — Lead가 판정 로그에 "clmux bridge 비가용, anthropic 단독 운영" 명시 필수 + 가능한 한 Human 검토 권장.

### 보안 강화 팀 (3-bridge + 보안 보강)

```
TeamCreate("clmux-{project}", "{설명}")
├── research-gemini-pro (Gemini Pro)  — 리서치, challenger, long-context reviewer
├── security-codex (Codex)            — Codex Security 보안 스캔 + PoC 검증 + critic
└── pr-ops-copilot (Copilot)          — PR ops, Autofix(public repo), 판정 로그 감사

Lead (Opus/Sonnet) — 보안 결정 중재 + 수정 위임
└── Subagent(sonnet) — V-2 보안 수정, 패치 구현
```

### 웹 개발 팀 (Cross-Provider, 3-bridge)

```
TeamCreate("clmux-{project}", "{설명}")
├── backend-gemini-pro (Gemini Pro)      — Backend 설계 + frame challenger + UX 접근성 리뷰
├── frontend-gemini-flash (Gemini Flash) — Frontend UI 1차 (WebDev Arena #1) + Visual Regression
└── pr-review-copilot (Copilot)          — PR Review + GitHub 증거

Lead (Opus/Sonnet)
└── Subagent(sonnet) — API/DB/비즈니스 로직 구현, E2E 테스트
```

### 데이터 파이프라인 팀 (Cross-Provider, 2-bridge + Lead+Subagent)

```
TeamCreate("clmux-{project}", "{설명}")
├── etl-review-codex (Codex)              — ETL 코드 리뷰, 스키마 검증, 성능 분석
└── data-quality-gemini-pro (Gemini Pro)  — 데이터 품질 검증, 정합성 challenger

Lead (Opus/Sonnet)
└── Subagent(sonnet) — ETL 구현, 모델 통합, 피처 엔지니어링
```

### 인프라/DevOps 팀 (Cross-Provider, 2-bridge + Lead+Subagent)

```
TeamCreate("clmux-{project}", "{설명}")
├── iac-codex (Codex)              — Terraform Plan 분석, CI Pipeline, 보안 정책
└── deploy-copilot (Copilot)       — GitHub Actions, 배포 검증, PR ops

Lead (Opus/Sonnet)
└── Subagent(sonnet) — IaC 구현, 프로비저닝
```
