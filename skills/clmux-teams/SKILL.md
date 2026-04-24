---
name: clmux-teams
description: "다중 AI Tool teammates 구성. clmux bridge 기반 Gemini/Codex/Copilot teammates만 사용 (Anthropic teammate 금지 — anthropic 의견은 Lead와 Lead spawn Subagent에서만 발생). Cross-Provider Evidence Pack 기반 판정 + 확증 편향 방지. clmux-teams, 멀티 에이전트, clmux, Cross-Provider."
---

# clmux Multi-Tool Teammates

> **전제**: [clmux-phase](../clmux-phase/SKILL.md) — 팀 라우팅, Phase 워크플로, 프로토콜
> **판정 프로세스**: [evidence-pack.md](../clmux-phase/references/evidence-pack.md) — Evidence Pack 스키마, 정규화, 판정 절차

## 활성화 조건

- clmux-phase에서 Agent Teams 라우팅 판정 시 invoke
- **Anthropic 계열(Claude Opus/Sonnet/Haiku) teammate 사용 금지** — Lead와 Subagent에서만 사용. Teammate(`TeamCreate` 멤버)는 비-Claude provider(Gemini/Codex/Copilot)로만 구성
- **clmux bridge ≥1명 필수** — bridge 없으면 clmux-phase 기본 모드(Lead + Subagent only)로 fallback

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
[2] Lead가 Subagent 위임 게이트키퍼 역할 자리매김
    → TDD/파일수정 ≥2 file/≥20 line/코드 리뷰는 Lead가 `Agent(model="sonnet"|"haiku")` Subagent로 위임
    → Anthropic teammate(`TeamCreate` 멤버)는 spawn 금지
[3] 가용성 감지 실행
[4] 가용한 clmux bridge를 스폰 (개별 명령, -t = team name):
    gemini  → zsh -ic "clmux-gemini -t <team_name> -n <name>"   # -n 필수, [-m <model>] — §9 참조 (Gemini는 env var 필수)
    codex   → zsh -ic "clmux-codex -t <team_name> -n <name>"    # -n 필수, [-m <model>] — §9 참조
    copilot → zsh -ic "clmux-copilot -t <team_name> -n <name>"   # -n 필수, 기본 모델 고정 (-m 금지)
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
| **Claude Opus 4.7** (Lead) | 추론 깊이, 시스템 정합성 | Protocol Manager — 문제 정의, rubric, Evidence Pack 판정, 품질 게이트, **Subagent 위임 게이트키퍼** (TDD/구현/리뷰는 `Agent(model="sonnet"|"haiku")` 로 위임) |
| **Claude Sonnet/Haiku** (Subagent only) | TDD, 코드 작성, 기계적 변환 | Lead가 직접 spawn하는 1회성 위임 — `model="sonnet"` (TDD/구현/리뷰), `model="haiku"` (탐색/추출/포맷) |
| **Gemini 3.1 Pro** (bridge teammate) | 1M Context[^gemini-pro-context], ARC-AGI-2 77.1% (ARC Prize Verified)[^gemini-pro-arc], LiveCodeBench Pro Elo 2887 (#1, self-reported)[^gemini-pro-lcb] | 리서치, Deep analysis + **frame challenger + alt implementation reviewer + long-context code reviewer (1M ctx)** |
| **Gemini 3 Flash** (bridge teammate) | Low latency (TTFT 1.1-1.4s, 172-218 tok/s)[^flash-lat], SWE-bench Verified 78%[^flash-swe] | 빠른 조사, Visual Regression, Grounding |
| **GPT-5.4 (Codex integrated)** (bridge teammate) | SWE-Bench Pro 57.7% (OpenAI Standard reasoning)[^codex-pro], Terminal-Bench 2.0 77.3% (GPT-5.3-Codex + Droid)[^codex-terminal-teams] | 구현, 테스트, 코드 리뷰 + **secondary critic + rebuttal + Evidence Pack 정규화 (구현과 분리)**. 본격 보안 스캔은 Plus 티어 미접근 |
| **Copilot** (bridge teammate) | PR Review @ scale (60M / 2025-04~2026-03, >20% of GitHub PRs, 71% actionable)[^copilot-review], Autofix (CodeQL) on public repos (460K alerts/년, time-to-fix −49%)[^copilot-autofix] | PR ops + Autofix (public repo) + **코드/테스트 생성 보조 + GitHub 증거 자동 생성** |

[^flash-lat]: Artificial Analysis 실측, 2026-04. Flash-Live 음성 전용 변종만 960ms TTFT.
[^flash-swe]: blog.google/gemini-3-flash 2025-12 발표. 2026-04 기준 Gemini 3.1 Pro 80.6%로 추월됨.
[^codex-pro]: OpenAI 공식 Standard 설정. Scale AI xHigh 59.1%.
[^copilot-review]: GitHub Blog "60 million Copilot code reviews and counting" (2026-03-05). 12K+ org 자동 리뷰 활성, 71% actionable / 29% silent, 평균 5.1 comments/review.
[^copilot-autofix]: GitHub Blog "GitHub expands application security coverage with AI-powered detections" (2026-03-23). 2025 연간 460,258 alert 수정, 1.29h→0.66h (−49%), 170K 내부 테스트 >80% positive feedback. FP rate 미공개.
[^codex-terminal-teams]: Terminal-Bench 2.0 leaderboard, https://www.tbench.ai/leaderboard/terminal-bench/2.0 (evaluated 2026-02-24). GPT-5.3-Codex + Droid agent: 77.3% ± 2.2. Agent-configuration-dependent.
[^gemini-pro-context]: DeepMind Model Card, "Gemini 3.1 Pro" (2026-02-19), https://deepmind.google/models/model-cards/gemini-3-1-pro/ — 1M input / 64K output tokens.
[^gemini-pro-arc]: DeepMind Model Card + Google Blog, "Gemini 3.1 Pro" (2026-02-19) — ARC-AGI-2: 77.1% (ARC Prize Verified); Gemini 3 Pro baseline was ~31%.
[^gemini-pro-lcb]: DeepMind Model Card — LiveCodeBench Pro Elo 2887, #1 of 4 entries at livecodebenchpro.com. All scores self-reported / unverified; leaderboard is sparse.

### 역할 경계 규칙

| 규칙 | 내용 | 근거 |
|------|------|------|
| 요구사항 정제 독점 금지 | Lead가 spawn한 Subagent(sonnet) 초안 + Gemini 독립 재해석 → Lead가 공통 구조 추출 | 최상류 편향 진입점 차단 |
| 구현↔정규화 분리 | 자기 산출물을 정규화하는 Provider ≠ 구현 Provider | 이해충돌 방지 |
| provider_family 단위 집계 | Gemini 3.1 Pro + 3 Flash = 1개 Provider (`google`) | 독립성 과대평가 방지 |
| Evidence Pack 정규화 순환 | Codex 단독 고정 금지 → Codex/Gemini/Copilot 순환 배정 | 단일 모델 독점 편향 방지 |
| 교차 검증 증거 필수 | 채택 시 교차 검증 증거 1개+ 필수 (구현 Provider ≠ 검증 Provider) | 구현↔검증 분리로 자기 검증 방지 |

### 가용 조합별 역할 재배정

> **Lead/Subagent 흡수 역할**: Anthropic teammate가 없으므로, 비-Claude bridge가 부족하면 Lead 또는 Lead가 spawn한 Subagent(sonnet)가 해당 역할을 대신 수행한다. (단 Subagent는 conversation isolated → SendMessage 불가)

| 가용 조합 | Lead/Subagent 추가 역할 | clmux 배정 |
|---|---|---|
| Gemini + Codex + Copilot | — | 기본 매핑 적용 |
| Gemini + Codex | PR/리뷰 + 판정 감사를 Lead가 흡수 | Gemini: 리서치+challenger+long-ctx review, Codex: 보안+정규화+critic |
| Gemini + Copilot | 보안/성능을 Lead가 흡수 (정규화는 비-Claude 유지) | Gemini: 리서치+challenger+critic + EP 정규화 순환 진입, Copilot: PR+증거+정규화 순환 진입 |
| Codex + Copilot | 리서치/challenger를 Lead가 흡수 | Codex: 보안+정규화+critic, Copilot: PR+감사 |
| Gemini only | 보안+PR+정규화를 Lead가 흡수 | Gemini: 리서치+challenger+critic |
| Codex only | 리서치+PR+challenger를 Lead가 흡수 | Codex: 보안+정규화+critic |
| Copilot only | 리서치+보안+정규화를 Lead가 흡수 | Copilot: PR+증거+감사 |
| 없음 | clmux-teams 비활성화 | clmux-phase 기본 모드(Lead + Subagent only) fallback |
| — | **주의**: Gemini only / Codex only / Copilot only 시 Rule 8 순환 불가 + Cross-Provider 합의 자동 충족 불가 → 판정 로그에 "단일 비-Claude Provider 운영" 명시 + Lead 단독 판정 사유 기록 필수 |

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

| Phase | Lead + Subagent (anthropic) | Gemini 3.1 Pro | Gemini 3 Flash | Codex | Copilot |
|---|---|---|---|---|---|
| P1 SPEC | 요구사항 초안 spawn(sonnet), Lead 중재 | 리서치 1차, **독립 재해석** | — | **rebuttal** | — |
| P2 DESIGN | 설계 검토(Lead), 합의 중재 | 기술 대안, **frame challenger + secondary critic** | 빠른 조사 | **secondary critic 보조** | — |
| P3 BUILD | TDD 구현 위임 spawn(sonnet) | **alt implementation review + long-context reviewer** | Frontend/UI 1차 | Boilerplate, IaC + **EP 정규화 (초기 라운드)** | PR Review + **코드/테스트 보조** |
| P4 VERIFY | V-1~V-4 위임 spawn(sonnet/haiku), Lead 통합 판정 | **frame challenger + long-context reviewer** | Visual Regression | 보안 1차, 성능 1차, 코드 리뷰 보조 | PR 검증 + **GitHub 증거 자동 생성** |
| P5 REFINE | 수정 위임 spawn(sonnet) | 문서화 1차, Changelog | — | 보안 재검증, CI/CD | PR 생성, Smoke Test + **판정 로그 감사** |

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
  │     │         + Lead → Subagent(sonnet) (E2E Playwright + Healer, Accessibility)
  │     └── NO  → Skip
  │
  ├── Backend API 변경이 있는가?
  │     ├── YES → Lead → Subagent(sonnet) (API Integration Test, DB 상태 검증)
  │     │         + Gemini Pro (frame challenger — 대안 아키텍처 관점)
  │     └── NO  → Skip
  │
  ├── 보안 민감 코드가 변경되었는가?
  │     ├── YES → Codex (보안 스캔 — 취약점 탐지 + PoC 검증)
  │     │         → Lead → Subagent(sonnet) (수정)
  │     └── NO  → Codex (diff 기준 기본 보안 검토)
  │
  ├── 성능 영향이 예상되는가?
  │     ├── YES → Codex (N+1 쿼리, 알고리즘 복잡도, 캐싱 분석)
  │     │         → Lead → Subagent(sonnet) (병목 수정)
  │     └── NO  → Skip
  │
  └── PR 제출 전
        ├── Codex  → 최종 코드 리뷰 (Error Path, Edge Case)
        ├── Copilot → PR 생성 + GitHub 증거 자동 채우기
        ├── Copilot → 배포 후 Smoke Test
        └── Copilot → 판정 로그 감사 (Phase 종료 시)
```

## 6. Provider 고유 제약사항

§5 Phase별 활용 시 인지해야 할 provider별 동작 특성. 상세는 각 reference 파일 참조.

### Codex (`--full-auto`)
- **Shell network-disabled** — `git push`, `npm install`, `curl` 등 네트워크 명령 차단 (kernel sandbox)
- **Approval mode `on-request`** — 모델이 위험 명령 판단 시 prompt 가능 (완전 unattended 아님)
- **Contamination risk** — shell + 외부 송신 패턴 누적 시 bridge MCP 자동 차단 → task별 fresh spawn 권장
- 상세: [references/clmux-codex.md](references/clmux-codex.md#codex-고유-제약사항)

### Copilot (`--yolo --autopilot --max-autopilot-continues 10`)
- 단일 지시에서 최대 10단계 자율 실행 (autopilot 다단계 루프)
- 무한 루프 방지를 위해 continuation 상한 강제
- 상세: [references/clmux-copilot.md](references/clmux-copilot.md)

### Gemini (`--yolo`)
- 모든 도구 자동 승인; CLI가 Docker sandbox 자동 부착
- 상세: [references/clmux-gemini.md](references/clmux-gemini.md)

## 7. 역할별 능력 매트릭스

| 항목 | Lead (anthropic) | Subagent (anthropic, Lead spawn) | clmux teammate (비-Claude) |
|---|---|---|---|
| VETO 투표권 | X (중재자) | X | **O** (Cross-Provider 합의 — clmux-veto §clmux teammate VETO) |
| Subagent 스폰 | O (위임 게이트키퍼) | X | X |
| TDD 루프 실행 | O (Subagent 위임) | O (실행) | X |
| 파일 직접 수정 | X (Subagent 위임) | O | Gemini/Codex (sandbox 내, --yolo / --full-auto 시); Copilot 제한적 (autopilot) |
| SendMessage 수신/발신 | O | X (conversation isolated) | O (bridge 경유) |
| Evidence Pack 정규화 | X | X | **O** (Codex/Gemini/Copilot 순환) |
| 판정 로그 감사 | X | X | **Copilot 담당** |

Lead는 VETO 투표에 참여하지 않고 중재만 수행한다 (Anchoring bias 방지). 투표는 clmux teammate 전원이 provider_family 단위로 수행한다 — Cross-Provider 합의 모델.
Rule 3 채택 조건: 비-Claude provider_family ≥1개 독립 지지 + 교차 검증 증거 (구현 Provider ≠ 검증 Provider). Anthropic teammate가 없으므로 비-Claude 독립 지지는 본질적으로 보장됨 — 단 ≥2개 provider_family 다양성을 추가 권장 (단일 provider 운영 시 §3 가용 조합 표 주의 사항 적용).

## 8. Fallback 규칙

| 상황 | 동작 |
|---|---|
| clmux bridge spawn 실패 | 해당 bridge 건너뛰고 나머지로 진행 |
| clmux teammate 응답 없음 (30초) | Lead가 해당 역할 흡수 (또는 Subagent 위임), bridge teardown |
| 전체 clmux bridge 비가용 | **clmux-teams 비활성화** → Lead + Subagent only로 clmux-phase 기본 모드 fallback (Cross-Provider 합의 불가 → 판정 로그에 "anthropic 단독 운영" 명시 + Human 검토 권장) |
| EP 정규화 담당 비가용 | 순환 배정에서 건너뛰고 다음 가용 Provider |

## 9. Bridge 공통 사항

### 아키텍처

모든 bridge teammate는 동일한 전달 방식을 사용한다:
- **Lead → Agent**: `clmux-bridge.zsh` polls inbox → `tmux paste-buffer -p` (bracketed paste) → `send-keys Enter`
- **Agent → Lead**: Agent calls `write_to_lead` MCP tool → outbox → Claude Code 수신
- Bridge는 inbox relay만 담당. 응답 수집 안 함.

### Spawn/Stop 공통 절차

**Spawn:**
```bash
zsh -ic "clmux-<agent> -t <team_name> -n <task>-<provider>[-<variant>] [-m <model>] [-x <timeout>]"
```

공통 옵션:
- `-t <team_name>` — 필수
- `-n <agent_name>` — **필수 명시** (Naming Convention 참조). 패턴: `<task>-<provider>` 또는 `<task>-<provider>-<variant>`. default `<agent>-worker`는 backward compat 용으로 **clmux-teams 워크플로에서 사용 금지**. 동일 이름 존재 시 spawn 거부
- `-m <model>` — CLI 모델 지정 (미지정 시 기본값).
  > ⚠️ **Gemini는 반드시 env var 사용** — `clmux-gemini -m "$CLMUX_GEMINI_MODEL_PRO"` (Pro) 또는 `-m "$CLMUX_GEMINI_MODEL_FLASH"` (Flash). literal alias (`gemini-pro`, `gemini-flash` 등)는 Gemini CLI가 silent fallback하여 default 모델로 로딩됨 — **에러 없이 의도와 다른 모델 사용 위험**. 상세: [references/clmux-gemini.md §모델 env var](references/clmux-gemini.md)
- `-x <timeout>` — idle-wait 타임아웃 (초). bridge가 CLI의 idle pattern을 감지할 때까지 대기하는 시간. 기본: `30`

### Naming Convention (필수)

teammate name은 **`<task>-<provider>`** 형태로 spawn한다. 사용자가 "어떤 작업을 맡았는지 + 어떤 모델인지" 한눈에 식별 가능해야 한다.

| Provider | 모델 차별 | 패턴 | 예시 |
|---|---|---|---|
| Gemini | YES (Pro vs Flash) | `<task>-gemini-<pro\|flash>` | `research-gemini-pro`, `frontend-gemini-flash` |
| Codex | NO (단일 모델) | `<task>-codex` | `security-codex`, `perf-codex` |
| Copilot | NO (단일 모델) | `<task>-copilot` | `pr-review-copilot`, `audit-copilot` |

> **주의**: 위 패턴(`-pro` / `-flash` 접미사)은 **agent name suffix**이며 **model ID 아님**. 모델 지정은 §9 `-m <model>`의 env var 사용 — `gemini-pro` 같은 literal alias는 model ID로 사용 시 silent fallback 위험.

#### Task 명 가이드

- **명사형, kebab-case, 1-2 단어**
- 역할/영역을 직관적으로 표현
- 표준 task vocabulary:
  - 조사/리서치: `research`, `tech-survey`, `apispec`, `docs`
  - 비평/도전: `critic`, `challenger`, `rebuttal`, `alt-impl`
  - 구현 보조: `boilerplate`, `frontend`, `backend`, `iac`
  - 검증: `security`, `perf`, `review`, `visual`, `accessibility`
  - PR/배포: `pr-review`, `pr-verify`, `pr-ops`, `smoke`, `deploy`
  - 운영: `audit`, `normalize`

> 다중 역할을 한 worker가 담당하면 가장 핵심/리드 task로 naming. 예: 보안+성능+critic 모두 담당 시 `security-codex`.

#### 다중 인스턴스 (드문 경우)

같은 task + provider가 둘 이상 필요 시 numeric suffix:
- `frontend-gemini-flash-1`, `frontend-gemini-flash-2`

#### 예외

`/clmux:clmux-{gemini,codex,copilot}` 단독 호출(Phase 워크플로 외부, demo/test) 시 default `<agent>-worker` 허용. clmux-teams 워크플로에서는 금지.

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

bridge / pane 무응답 시 진단 + teardown + respawn 절차는 [clmux-tools §5 시나리오 C](../clmux-tools/SKILL.md#5-통합-워크플로-사용-예) 참조 → 진단 후 본 skill §9 의 stop / respawn 명령으로 복구.

## 참조 자료

- [Evidence Pack 스키마 + 판정 프로세스](../clmux-phase/references/evidence-pack.md) — 2-pass 정규화, 리스크 차등, 판정 로그
- [Gemini teammate](references/clmux-gemini.md) — Phase별 역할 + 모델 목록
- [Codex teammate](references/clmux-codex.md) — Phase별 역할 + MCP 설정 + 모델 목록
- [Copilot teammate](references/clmux-copilot.md) — Phase별 역할 + HTTP MCP + 모델 목록
