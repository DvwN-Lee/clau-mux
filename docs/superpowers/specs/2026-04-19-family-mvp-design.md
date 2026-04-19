# Family v2 MVP — Design (revision 2, option e)

**Date**: 2026-04-19
**Status**: Draft revision 2 — cross-provider review 반영, **zero-code MVP** 채택
**Type**: Design (between requirements and implementation plan)
**Conforms to**: `2026-04-19-family-teammate-ux-requirements.md` (v2)

---

## 0. Scope + 핵심 가정

### 0.1 Scope

본 design은 **Family v2 MVP**만 다룬다. 확장 기능 (depth-4+, Ghostty, worktree, audit trail, wrapper functions, dedicated skill files, CI mocking 등) 은 §6 후속 트랙 참조.

**MVP의 한 줄 정의 (revision 2):**
> Lead Claude Code가 한 명령으로 Teammate 1개를 spawn하여, Teammate가 자체 Worker subagent **2개를 fan-out**하고 결과를 **consolidate**해 Lead에 native teammate-message로 보고할 수 있다.

### 0.2 핵심 가정 (Risk B 명시)

- **Lead = primary session**: 본 design은 Lead Claude가 사용자가 대화하는 메인 세션이며, **자체가 또 다른 Lead의 teammate가 아님**을 가정한다. nested teammate (teammate-of-teammate) 는 SDK 차원에서 Agent() 호출이 차단됨 (U1 spike 결과).

### 0.3 Revision 2 변화 요약

| 영역 | revision 1 | revision 2 |
|---|---|---|
| MVP scope | 1-Lead + 1-Teammate + 1-Worker (1:1:1) | **1-Lead + 1-Teammate + 2-Workers (1:1:2)** |
| C1 zsh wrapper | `lib/family.zsh` ~30 LOC | **삭제 — docs로만 안내** |
| C2 SKILL.md | `~/.claude/skills/clmux-family-child/` ~80 라인 | **삭제 — spawn prompt template로 흡수** |
| C3 자동 테스트 | wrapper assertion shell test | **삭제 — manual smoke test only** |
| 신규 코드 | ~150 LOC (zsh + skill body + test) | **0 LOC** |
| 신규 docs | smoke test 언급만 | **`docs/family-smoke-test.md` 정식 산출물** + design 본 문서 + README 섹션 |
| 통신 경로 | spawn prompt embed + inbox poll (이중) | **spawn prompt embed 단일** (inbox dead code 제거) |

---

## 1. 아키텍처 (Architecture)

```
┌──────────────────────────────────────────────────────────────┐
│ Lead pane (사용자 대화 세션, primary session)                  │
│                                                                │
│   사용자: "X 작업 family child 에게 위임"                         │
│                          │                                     │
│                          ▼                                     │
│              Lead Claude — Agent() 직접 호출                   │
│              (template은 docs/family-smoke-test.md 참조)        │
│                          │                                     │
│                          ▼                                     │
│              Agent({                                           │
│                team_name: "<현재 team>",                        │
│                name: "<child name>",                           │
│                subagent_type: "general-purpose",               │
│                model: "sonnet",                                │
│                run_in_background: true,                        │
│                prompt: "<role + scope 인라인>"                   │
│              })                                                │
│                          │                                     │
│      ┌───────────────────┴────────────────────┐                │
│      │  새 tmux pane 자동 (Claude SDK)            │                │
│      │  config.json members 자동 추가              │                │
│      └────────────────────────────────────────┘                │
│                                                                │
│   ◀──── native teammate-message ──── Teammate 응답              │
└──────────────────────────────────────────────────────────────┘
                              │
                              │ SendMessage (양방향)
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Teammate pane (Claude Code, model=sonnet)                     │
│                                                                │
│   spawn prompt 자체에 role + scope + 행동 지침이 인라인           │
│   (별도 skill 파일 / 자동발동 메커니즘 의존 X)                       │
│                          │                                     │
│                          ▼                                     │
│   prompt 지시대로 즉시 시작:                                       │
│     1. scope 분석                                                │
│     2. 2개 Worker spawn (Agent, team_name 없음, sync)            │
│     3. 두 Worker 결과 consolidate                                │
│     4. SendMessage(to: "team-lead", consolidated report)       │
│                                                                │
│   shutdown_request 수신 시 → 정상 종료                            │
└──────────────────────────────────────────────────────────────┘
                              │
                              │ Agent() 직접 호출 (sync, 2개 병렬)
                              ▼
┌──────────────────────────────────────────────────────────────┐
│ Worker A (subagent, ephemeral)    Worker B (subagent, ephem)   │
│   - team 멤버 아님                  - 동일                      │
│   - SendMessage tool 없음            - 동일                      │
│   - task 완료 → sync 결과 → Teammate에만 반환                     │
└──────────────────────────────────────────────────────────────┘
```

---

## 2. 컴포넌트 (Components, revision 2)

> revision 1의 C1~C5 중 코드 컴포넌트(C1/C2/C3/C5) 는 모두 삭제. **docs 컴포넌트 3개**만 남김.

### D1. `docs/superpowers/specs/2026-04-19-family-mvp-design.md`

본 문서. design 자체.

### D2. `docs/family-smoke-test.md` (신규, ~80 라인)

**역할**: manual smoke test 시나리오 + Agent() spawn prompt template (재사용 가능).

**구조:**
1. Test prerequisites (활성 team 1개 필요)
2. Step-by-step manual scenario (사용자가 따라하면 1:1:2 Family 구성·검증 가능)
3. Expected observation per step
4. Reusable Agent() template — 사용자/Lead Claude가 복사해서 사용
5. Spawn prompt template — Teammate 행동 지침 인라인 형태

### D3. `README.md` Family 섹션 (~30 라인 추가)

**위치**: 기존 "Copilot Teammate" 섹션 다음.

**내용:**
- Family vs Team 1줄 차이
- 핵심 워크플로 1개 (간단 예시)
- "상세 가이드 + smoke test → docs/family-smoke-test.md" 링크
- 명령어 요약표는 추가 없음 (코드 0이므로 명령어 0)

---

## 3. 데이터 플로우 (Data Flow, single primary path)

> revision 2 변화: spawn prompt embed가 **유일 primary path**. inbox 의존 경로 제거 (Risk A 해소).

### 3.1 Forward (Delegate)

```
Lead Claude
  │
  │ 1. Agent() 직접 호출 (인자에 spawn prompt 인라인)
  ▼
Claude SDK
  │
  │ 2. tmux pane 생성 + 새 Claude Code 시작
  │ 3. spawn prompt 가 첫 turn 으로 주입
  │ 4. team config.json members 추가
  ▼
Teammate Claude
  │
  │ 5. spawn prompt 의 role + scope + 지침 즉시 인지
  │ 6. 작업 수행 (Worker fanout 포함)
```

### 3.2 Reverse (Report)

```
Teammate Claude
  │
  │ 1. 2 Worker 결과 consolidate 완료
  │ 2. SendMessage(to: "team-lead", message: "<report>")
  ▼
SDK routing
  │
  │ 3. ~/.claude/teams/<team>/inboxes/team-lead.json 에 atomic write
  │ 4. idle_notification 추가
  ▼
Lead Claude
  │
  │ 5. native teammate-message 이벤트 자동 surfacing
  │ 6. 다음 turn에 자연스럽게 인지 (사용자 입력 없이) — R3 충족
```

### 3.3 Worker fanout (Teammate 내부)

```
Teammate Claude
  │
  │ 1. Agent() × 2 (병렬, run_in_background=false 또는 true 선택)
  │    각 Worker spawn prompt = 부분 task 지시
  ▼
Workers (subagents, ephemeral)
  │
  │ 2. 각자 task 수행
  │ 3. sync result 반환 (task completion)
  ▼
Teammate Claude (동일 turn 내)
  │
  │ 4. 두 결과를 받아 consolidate
```

---

## 4. 에러 처리 (Error Handling)

| 시나리오 | 처리 |
|---|---|
| Lead가 Agent() 호출 실패 (team_name 미존재 등) | SDK 에러 표면화. 사용자가 TeamCreate 먼저 호출하도록 안내 |
| Teammate spawn 후 prompt 미인지 | spawn prompt가 명확하면 거의 발생 X. 발생 시 Lead가 추가 SendMessage로 지시 |
| Worker spawn 실패 (Agent 실패) | Teammate가 catch + Lead에 partial report (가능한 결과만) |
| Teammate 가 응답 없이 idle 지속 | Lead가 timeout 인지 후 shutdown_request (운영 패턴) |
| Lead 가 nested teammate (Risk B 위반) | Agent() 호출 시 SDK가 차단 → 즉각 fail-fast |

**MVP 의도적 미처리:**
- Teammate crash recovery (재시작 로직 X)
- Worker 결과 timeout (Agent sync 호출이 처리)
- Multi-Teammate concurrency conflict (MVP는 1 Teammate 만)

---

## 5. 테스트 전략 (Testing Strategy)

| 레이어 | 자동화 | 도구 |
|---|---|---|
| 모든 동작 | ❌ Manual | `docs/family-smoke-test.md` 시나리오 |

**근거 (cross-provider 합의):**
- 신규 코드 0이므로 unit test 대상 없음
- Live SDK spawn 자동화는 CI 환경에서 불가능
- Inbox mocking 은 spawn prompt embed 단일 path에서는 의미 없음
- 진짜 검증은 사용자 환경에서 1회 manual 실행으로 충분 (회귀 risk = SDK 변경 시뿐, code 변경 시는 코드 자체가 없음)

---

## 6. 향후 확장 (Out-of-MVP, 후속 트랙)

| 기능 | 트리거 | 예상 신규 LOC |
|---|---|---|
| `lib/family.zsh` wrapper (Agent() 인자 자동 조립) | spawn 빈도가 높아지고 매번 template 복사가 번거로워질 때 | ~30 |
| Lead-side custom skill (`clmux-family-spawn`) | gemini 제안 — Lead 가 zsh 거치지 않고 native skill 로 spawn | ~50 |
| Dedicated child SKILL.md | spawn prompt 길이가 ~500자 초과해 매번 인라인이 부담될 때 | ~80 |
| CI inbox mock 테스트 | code 가 추가되어 회귀 검증 필요해질 때 | ~80 |
| Multi-Teammate fanout helper | Multi-mid use case 빈번해질 때 | +50 |
| Worker 결과 audit trail (orchestrate 부활) | "어떤 Worker가 무엇을 했는지" 추적 필요 시 | +200 |
| Ghostty 자동 창/탭 | 매번 attach 번거로움 시 | +150 |
| `isolation: "worktree"` 자동화 | git worktree 격리 작업 use case 정착 시 | +30 |
| Cleanup wrapper (`clmux-family-stop`) | 명시적 teardown 필요 시 | +40 |
| depth-4+ via custom bridge | 실제 use case 발견 시 | +500 |

---

## 7. 의사결정 기록 (Design Decisions, revision 2)

### D1. wrapper / skill / 자동 테스트 모두 삭제 (zero-code MVP)

**선택**: 신규 코드 0, docs only
**대안 (revision 1)**: zsh wrapper + dedicated SKILL.md + assertion test
**이유 (cross-provider 합의)**:
- gemini: "MVP가 1:1:1이면 Team 별칭 — 1:2 fan-out 필수 + wrapper 는 lead-side custom skill로 격상이 더 합리적"
- claude-sonnet: "wrapper 는 반자동화 인상, skill 자동발동은 user message 의존 — spawn prompt 임베드만으로 충분"
- Lead self-review: 본 chain-ux 팀 자체가 살아있는 증거 — claude-sonnet은 skill 없이 spawn prompt 만으로 정확히 child role 수행 중
- 코드가 적을수록 SDK 변경에 강건 (gemini 의 SDK 내부경로 의존성 우려 자동 해소)

### D2. MVP scope 확장: 1:1:1 → 1:1:2 (gemini 권고 수용)

**선택**: 1 Lead + 1 Teammate + 2 Workers
**대안**: 1:1:1 (revision 1)
**이유**:
- 1:1:1은 Lead↔Teammate 통신만 검증 → 기존 Pattern A의 Team 메커니즘과 사실상 동일한 검증
- Family의 unique value는 **Teammate 가 Worker 를 fan-out 하고 consolidate** 하는 것
- Worker 추가 비용 = ephemeral subagent 1개 더 (거의 0)
- 사용자의 "최소 → 확장" 원칙은 유지 — Teammate 수는 1로 고정 (Multi-Teammate 는 후속)

### D3. spawn prompt embed = 유일 primary path (Risk A 해소)

**선택**: spawn prompt 에 role + scope + 지침 모두 인라인
**대안**: prompt + inbox poll 이중
**이유**:
- inbox poll path 가 dead code 화 (sonnet Risk A)
- 단일 path = 단순 + 디버깅 쉬움
- Claude Code SDK 가 spawn prompt 를 첫 turn 으로 주입한다는 검증된 패턴 활용

### D4. Lead = primary session 가정 명시 (Risk B 해소)

**선택**: §0.2 에 명시
**이유**: nested teammate 는 SDK 차원에서 Agent() 호출 차단됨 (U1 spike). 이 가정 위반 시 즉시 fail-fast 함을 사용자가 알 수 있어야 함

---

## 8. 다음 단계

본 design revision 2 사용자 승인 후:

1. ✅ `docs/family-smoke-test.md` 작성
2. ✅ `README.md` Family 섹션 추가
3. ⏭️ Commit (3개 파일 — design + smoke + readme)
4. ⏭️ PR-B 생성 (`docs:` prefix, 코드 변경 0)
5. ⏭️ Manual smoke test 1회 (사용자 환경) — PR 머지 전 검증
6. ⏭️ PR-B merge 후 본 design 의 패턴이 정착되면, §6 후속 트랙에서 wrapper/skill/audit trail 등을 점진 추가
