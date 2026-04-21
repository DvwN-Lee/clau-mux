---
name: clmux-teams
description: "다중 AI Tool teammates 구성. clmux bridge 기반 Gemini/Codex/Copilot teammates를 Claude Code native teammate와 함께 구성한다. Cross-Provider Evidence Pack 기반 판정 + 확증 편향 방지. clmux-teams, 멀티 에이전트, clmux, Cross-Provider."
user-invocable: true
metadata:
  author: clmux
  version: "2.0"
compatibility: Requires Claude Code with Agent Teams enabled + clmux bridge installed
---

# clmux Multi-Tool Teammates

> **전제**: [clmux-phase](../clmux-phase/SKILL.md) — 팀 라우팅, Phase 워크플로, 프로토콜
> **판정 프로세스**: [evidence-pack.md](../clmux-phase/references/evidence-pack.md) — Evidence Pack 스키마, 정규화, 판정 절차

## 활성화 조건

- clmux-phase에서 Agent Teams 라우팅 판정 시 invoke
- **Claude Code native teammate ≥1명 필수** — clmux teammate만으로 팀 구성 불가
- clmux bridge가 하나도 없으면 clmux-phase 기본 모드로 fallback

> **진단 / 송수신 명령**: 본 skill 은 bridge teammate **운영** 책임. 명령 inventory + 사용 패턴 + raw tmux anti-pattern + target resolve decision tree는 [clmux-tools](../clmux-tools/SKILL.md) 참조.

## 1. 가용성 감지

```bash
zsh -ic "type clmux-gemini  2>/dev/null && echo 'gemini:available'  || echo 'gemini:unavailable'"
zsh -ic "type clmux-copilot 2>/dev/null && echo 'copilot:available' || echo 'copilot:unavailable'"
zsh -ic "type clmux-codex   2>/dev/null && echo 'codex:available'   || echo 'codex:unavailable'"
```

## 2. 팀 구성 흐름

```
[1] clmux-phase에서 TeamCreate 완료 확인
[2] Claude Code native teammate 스폰 (필수, model="sonnet")
    → 설계/구현/검증 핵심 실행 + secondary critic + long-context code reviewer
[3] 가용성 감지 실행
[4] 가용한 clmux bridge를 스폰 (개별 명령, -t = team name):
    gemini  → zsh -ic "clmux-gemini -t <team_name>"   # [-m <model>] 등 §8 참조
    codex   → zsh -ic "clmux-codex -t <team_name>"    # [-m <model>] 등 §8 참조
    copilot → zsh -ic "clmux-copilot -t <team_name>"   # [-m <model>] 등 §8 참조
    ※ 3개 모두 필요할 경우 3개를 순차 실행
[4.5] 검증 (단일 진입점):
    zsh -ic "clmux-teammates"   # 진단 명령 상세는 clmux-tools 참조
    → 모든 spawn된 teammate가 [alive] 표시되어야 [5] 진입.
      하나라도 [dead] 면 §"에러 대응" → clmux-tools §5 시나리오 C 절차 진행.
[5] 역할 배정 (§3 참조) + Evidence Pack 정규화 담당 배정 (§4 참조)
```

## 3. Provider별 최적 배치

### 역할 매핑 (4-Provider 교차 분석 + 3-Provider 검증 기반)

> **기준일**: 2026-04-21. 모델 ID는 해당 날짜 기준. 분기별 재검증 필요.

| Provider | 핵심 강점 | 역할 |
|---|---|---|
| **Claude Opus 4.7** (Lead) | 추론 깊이, 시스템 정합성 | Protocol Manager — 문제 정의, rubric, Evidence Pack 판정, 품질 게이트 |
| **Claude Sonnet 4.6** (native) | 1M Context, TDD, Multi-file Refactoring | 설계/구현/검증 실행 + **secondary critic + rebuttal + long-context code reviewer** |
| **Gemini 3.1 Pro** (bridge) | 1M Context, ARC-AGI-2 77.1% | 리서치, Deep analysis + **frame challenger + alt implementation reviewer** |
| **Gemini 3 Flash** (bridge) | Low latency (TTFT 1.1-1.4s, 172-218 tok/s)[^flash-lat], SWE-bench Verified 78%[^flash-swe] | 빠른 조사, Visual Regression, Grounding |
| **GPT-5.4 (Codex integrated)** (bridge) | SWE-Bench Pro 57.7%[^codex-pro] \| **별도 제품**: Codex Security (ChatGPT Pro/Enterprise research preview, 2026-03-06) | 구현, 테스트, 보안 검증 + **Evidence Pack 정규화 (구현과 분리)** |
| **Copilot** (bridge) | GitHub 네이티브, 60M+ 리뷰 | PR ops, CodeQL + **코드/테스트 생성 보조 + GitHub 증거 자동 생성 + 판정 로그 감사** |

[^flash-lat]: Artificial Analysis 실측, 2026-04. Flash-Live 음성 전용 변종만 960ms TTFT.
[^flash-swe]: blog.google/gemini-3-flash 2025-12 발표. 2026-04 기준 Gemini 3.1 Pro 80.6%로 추월됨.
[^codex-pro]: OpenAI 공식 Standard 설정. Scale AI xHigh 59.1%.

### 역할 경계 규칙

| 규칙 | 내용 | 근거 |
|------|------|------|
| 요구사항 정제 독점 금지 | Sonnet 초안 + Gemini 독립 재해석 → Lead가 공통 구조 추출 | 최상류 편향 진입점 차단 |
| 구현↔정규화 분리 | 자기 산출물을 정규화하는 Provider ≠ 구현 Provider | 이해충돌 방지 |
| provider_family 단위 집계 | Gemini 3.1 Pro + 3 Flash = 1개 Provider (`google`) | 독립성 과대평가 방지 |
| Evidence Pack 정규화 순환 | Codex 단독 고정 금지 → Codex/Gemini/Copilot 순환 배정 | 단일 모델 독점 편향 방지 |
| 교차 검증 증거 필수 | 채택 시 교차 검증 증거 1개+ 필수 (구현 Provider ≠ 검증 Provider) | 구현↔검증 분리로 자기 검증 방지 |

### 가용 조합별 역할 재배정

| 가용 조합 | Claude 추가 역할 | clmux 배정 |
|---|---|---|
| Gemini + Codex + Copilot | — | 기본 매핑 적용 |
| Gemini + Codex | PR/리뷰 + 판정 감사 흡수 | Gemini: 리서치+challenger, Codex: 보안+정규화 |
| Gemini + Copilot | 보안/성능 흡수 (정규화는 비-Claude 유지) | Gemini: 리서치+challenger + EP 정규화 순환 진입, Copilot: PR+증거+정규화 순환 진입 |
| Codex + Copilot | 리서치/challenger 흡수 | Codex: 보안+정규화, Copilot: PR+감사 |
| Gemini only | 보안+PR+정규화 흡수 | Gemini: 리서치+challenger |
| Codex only | 리서치+PR+challenger 흡수 | Codex: 보안+정규화 |
| Copilot only | 리서치+보안+정규화 흡수 | Copilot: PR+증거+감사 |
| 없음 | 전체 흡수 | clmux-phase 기본 모드 fallback |
| — | **주의**: Gemini only / Codex only / Copilot only 시 Rule 8 순환 불가 → 판정 로그에 "단일 비-Claude Provider 운영" 명시 필수 |

## 4. Evidence Pack 정규화 배정

Evidence Pack 정규화는 구현 담당과 분리한 2-pass 프로세스로 운용한다.
상세 스키마와 판정 절차는 [evidence-pack.md](../clmux-phase/references/evidence-pack.md) 참조.

### 2-pass 프로세스

```
Pass 1: 모델 출력 → Evidence Pack 변환 (순환 배정 — Codex/Gemini/Copilot)
Pass 2: 다른 Provider가 교차 검토 (누락/왜곡 확인)
GitHub 필드 (ci_runs, codeql_alerts, coverage, reviews): Copilot 항시 담당
```

### 순환 배정표

순환 배정 상세는 [evidence-pack.md §순환 배정](../clmux-phase/references/evidence-pack.md#순환-배정-rule-8) 참조.

> **참고**: §5 Phase 표의 EP 정규화 담당 (예: P3 Codex)은 Round 1 배정 예시다. 실제 배정은 순환 카운터 기준이며 §4 순환 배정이 Phase 표보다 우선한다.

### 스타일 중립화

완전 blind 평가는 현실적으로 불가 (스타일로 저자 식별 가능).
대신 정규화 단계에서 스타일 중립화를 적용한다:
- 프로즈/산문 → Evidence Pack structured fields로 변환
- Lead는 정규화된 필드값만으로 1차 판정
- 이의 제기/동률/고위험 시에만 raw artifact 제한 검토 허용

## 5. Phase별 clmux 활용

| Phase | Claude Sonnet | Gemini 3.1 Pro | Gemini 3 Flash | Codex | Copilot |
|---|---|---|---|---|---|
| P1 SPEC | 요구사항 초안, VETO, **rebuttal** | 리서치 1차, **독립 재해석** | — | — | — |
| P2 DESIGN | 설계, VETO, **secondary critic** | 기술 대안, **frame challenger** | 빠른 조사 | — | — |
| P3 BUILD | TDD 구현 (핵심 로직) | **alt implementation review** | Frontend/UI 1차 | Boilerplate, IaC + **EP 정규화 (초기 라운드)** | PR Review + **코드/테스트 보조** |
| P4 VERIFY | V-1~V-4, **long-context reviewer** | **frame challenger** (검증 관점) | Visual Regression | 보안 1차, 성능 1차, 코드 리뷰 보조 | PR 검증 + **GitHub 증거 자동 생성** |
| P5 REFINE | 수정 | 문서화 1차, Changelog | — | 보안 재검증, CI/CD | PR 생성, Smoke Test + **판정 로그 감사** |

> **EP 정규화 배정 일관성**: §5 table의 "EP 정규화" 셀은 **초기 라운드 기본 배정**이다. 후속 라운드는 Rule 8 순환 (Codex → Gemini → Copilot) 적용. 상세: [evidence-pack.md §순환 배정](../clmux-phase/references/evidence-pack.md#순환-배정-rule-8)

### P3 alt implementation review 프로토콜 (Gemini Pro)

§5 table의 P3 Gemini Pro "alt implementation review"는 아래 프로토콜로 실행한다:

| 단계 | 내용 |
|---|---|
| 실행 시점 | P3 구현 Teammate가 COMPLETION 보고 직후, P4 진입 전 |
| 입력 | 구현 Teammate diff + design.md + tasks.md |
| 출력 | Evidence Pack (counterevidence.strongest_objection, unresolved_assumptions, judgment.task_fit_score) |
| 전달 경로 | P4 Lead Consolidation의 독립 input으로 집계 (구현 Provider 의견과 분리) |
| Rule 3 연결 | Gemini Pro 지지 = google provider_family 독립 지지로 계산 |

> Generator-Validator 분리 (clmux-veto §Generator-Validator) 원칙 준수: Gemini Pro가 P3 구현에 관여했으면 P3 alt review 불참 — 다른 provider로 대체.

### 리스크 레벨별 프로토콜 차등

Lead가 작업 수신 시 리스크 레벨을 판정하여 프로토콜 수준을 결정한다.

| 리스크 | 프로토콜 | clmux 활용 |
|--------|---------|-----------|
| **High** | 풀 프로토콜: 독립 초안 + EP 2-pass + 3-way vote + 교차 검증 증거 | 전 Provider 참여 |
| **Medium** | EP + 비-Claude 1개 확인 | Codex 또는 Gemini 1개+ |
| **Low** | CI Green + Copilot PR 리뷰 자동 승인 | Copilot만 |

### 검증 의사결정 트리 (P4/P5)

구현 완료 후 Lead는 아래 트리에 따라 검증 작업을 라우팅한다:

```
구현 완료 후 검증 시작
  │
  ├── Frontend 변경이 있는가?
  │     ├── YES → Gemini Flash (Visual Regression, BrowserMCP)
  │     │         + Claude (E2E Playwright + Healer, Accessibility)
  │     └── NO  → Skip
  │
  ├── Backend API 변경이 있는가?
  │     ├── YES → Claude (API Integration Test, DB 상태 검증)
  │     │         + Gemini Pro (frame challenger — 대안 아키텍처 관점)
  │     └── NO  → Skip
  │
  ├── 보안 민감 코드가 변경되었는가?
  │     ├── YES → Codex (보안 스캔 — 취약점 탐지 + PoC 검증)
  │     │         → Claude (수정)
  │     └── NO  → Codex (diff 기준 기본 보안 검토)
  │
  ├── 성능 영향이 예상되는가?
  │     ├── YES → Codex (N+1 쿼리, 알고리즘 복잡도, 캐싱 분석)
  │     │         → Claude (병목 수정)
  │     └── NO  → Skip
  │
  └── PR 제출 전
        ├── Codex  → 최종 코드 리뷰 (Error Path, Edge Case)
        ├── Copilot → PR 생성 + GitHub 증거 자동 채우기
        ├── Copilot → 배포 후 Smoke Test
        └── Copilot → 판정 로그 감사 (Phase 종료 시)
```

## 6. clmux teammate 제약

| 항목 | Claude teammate | clmux teammate |
|---|---|---|
| VETO 투표권 | O | **X** (의견 제출만 가능) |
| Subagent 스폰 | O | X |
| TDD 루프 실행 | O | X |
| 파일 직접 수정 | O | 제한적 (Codex만 --full-auto 시) |
| SendMessage 수신/발신 | O | O (bridge 경유) |
| Evidence Pack 정규화 | O (순환 시) | **O** (Codex/Gemini/Copilot 순환) |
| 판정 로그 감사 | X | **Copilot 담당** |

Lead는 clmux teammate의 의견을 수신하여 VETO 근거 자료로 활용하되, 투표 자체는 Claude teammate만 수행한다.
단, Evidence Pack 기반 판정에서 비-Claude provider_family의 독립 지지가 채택 필수 조건이다 (Rule 3).

## 7. Fallback 규칙

| 상황 | 동작 |
|---|---|
| clmux bridge spawn 실패 | 해당 bridge 건너뛰고 나머지로 진행 |
| clmux teammate 응답 없음 (30초) | Lead가 해당 역할 흡수, bridge teardown |
| Claude teammate 스폰 실패 | **clmux-teams 비활성화** → clmux-phase fallback |
| 전체 clmux 비가용 | Claude teammate만으로 clmux-phase 기본 모드 |
| EP 정규화 담당 비가용 | 순환 배정에서 건너뛰고 다음 가용 Provider |

## 8. Bridge 공통 사항

### 아키텍처

모든 bridge teammate는 동일한 전달 방식을 사용한다:
- **Lead → Agent**: `clmux-bridge.zsh` polls inbox → `tmux paste-buffer -p` (bracketed paste) → `send-keys Enter`
- **Agent → Lead**: Agent calls `write_to_lead` MCP tool → outbox → Claude Code 수신
- Bridge는 inbox relay만 담당. 응답 수집 안 함.

### Spawn/Stop 공통 절차

**Spawn:**
```bash
zsh -ic "clmux-<agent> -t <team_name> [-m <model>] [-n <agent_name>] [-x <timeout>]"
```

공통 옵션:
- `-t <team_name>` — 필수
- `-m <model>` — CLI 모델 지정 (미지정 시 기본값)
- `-n <agent_name>` — 기본: `<agent>-worker`. 동일 이름 존재 시 spawn 거부
- `-x <timeout>` — idle-wait 타임아웃 (초). bridge가 CLI의 idle pattern을 감지할 때까지 대기하는 시간. 기본: `30`

Spawn 후 반드시 활성화 메시지 전송:
```
SendMessage(to: "<agent_name>", message: "<초기 지시>")
```

**Stop (graceful):**
```
SendMessage(to: "<agent_name>", message: {"type": "shutdown_request"})
```

**Stop (manual fallback):**
```bash
zsh -ic "clmux-<agent>-stop -t <team_name>"
```

### 에러 대응

bridge / pane 무응답 시 진단 + teardown + respawn 절차는 [clmux-tools §5 시나리오 C](../clmux-tools/SKILL.md#5-통합-워크플로-사용-예) 참조 → 진단 후 본 skill §8 의 stop / respawn 명령으로 복구.

## 참조 자료

- [Evidence Pack 스키마 + 판정 프로세스](../clmux-phase/references/evidence-pack.md) — 2-pass 정규화, 리스크 차등, 판정 로그
- [Gemini teammate](references/clmux-gemini.md) — Phase별 역할 + 모델 목록
- [Codex teammate](references/clmux-codex.md) — Phase별 역할 + MCP 설정 + 모델 목록
- [Copilot teammate](references/clmux-copilot.md) — Phase별 역할 + HTTP MCP + 모델 목록
