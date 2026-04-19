# Family Teammate UX — Requirements

**Date**: 2026-04-19
**Status**: Draft v2 (post U1 spike — depth-3 한정으로 정정)
**Type**: Requirements (precedes design and implementation plan)
**Authority**: Captures user-stated goals and constraints. All design / implementation choices for the new pane communication abstraction MUST conform to this document.

> **Naming history**: 본 추상은 brainstorming 초기에 "Chain"으로 시작했으나, 멤버 명칭이 Parent/Children (1:N tree)로 결정되면서 "Chain"(linear sequence)이 의미적으로 misalign됨. Cross-provider review (Anthropic Sonnet + Google Gemini Pro)를 거쳐 **Family**로 확정 (§9 참조).
>
> **Scope revision (U1 spike)**: 초기 v1에서 "무한 깊이 자동 재귀"를 가정했으나, U1 spike 결과 **Claude Code SDK가 'teammates cannot spawn other teammates' 제약**을 강제함. 따라서 native teammate-message UX는 **depth-3 한정** (Lead → Teammate → Subagent). depth-3+ 는 추후 별도 설계로 분리 (§4 / §10 참조).

---

## 0. Document scope

이 문서는 **요구사항 정의**만 다룬다. 구현 방식 선택, 코드 변경, 우선순위 결정은 **별도의 design doc + implementation plan**에서 다룬다. 본 문서의 목적은 다음 단계(design)에서 사용할 **변하지 않는 기준선(baseline)**을 확립하는 것이다.

---

## 1. 프로젝트 목표 (Goal)

**clau-mux의 multi-pane Family 통신은, 기존 Claude Code teammates 패턴과 동일한 UX를 제공해야 한다.**

여기서 "동일한 UX"는 다음을 의미한다:
- 수신자(receiver)가 **수동 polling 없이** 메시지 도착을 인지함
- 수신은 Claude Code의 **native "teammate-message" 이벤트**로 surfaced됨 (사용자 입력처럼 paste되는 것이 아님)
- 수신자는 메시지 도착 즉시 응답/처리 가능

---

## 2. 두 가지 통신 패턴 (Communication Patterns)

### Pattern A — Team (✅ 이미 구현)

- **하나의 Lead pane** (Claude Code 인스턴스) 내부에 가상 multi-pane 구성
- Lead가 다음 teammates를 동시 운용:
  - **Bridge teammates** — Gemini CLI / Codex CLI / Copilot CLI (MCP bridge → tmux paste relay 경유)
  - **Native teammates** — Claude Code 서브에이전트 (sonnet / haiku / opus, `TeamCreate` 경유)
- 수신 경로: 모든 teammate 응답이 Lead의 Claude Code 대화에 **native teammate-message로 직접 surfaced**
- 사용자 perspective: Lead 대화 내에서 모든 teammate와 단일 흐름으로 협업
- 어휘: **"team"** + **"Lead / teammate"**

### Pattern B — Family (🎯 본 문서의 대상, depth-3 한정)

**SDK 강제 3-tier 구조:**

```
Tier 1: Lead (root)          ← 사용자가 대화하는 메인 Claude Code 세션
   │
   │ Agent(team_name=X, name=Y) → 비동기 native teammate-message
   ▼
Tier 2: Teammate (child)     ← persistent, 별도 tmux pane, native messaging 양방향
   │
   │ Agent() (team_name 없음) → 동기 subagent, sync 결과 반환
   ▼
Tier 3: Worker (grandchild)  ← ephemeral, 1회성 task, sync 결과만 반환
```

**용어 매핑:**

| 위치 | 어휘 | 라이프사이클 | 통신 방식 |
|---|---|---|---|
| Tier 1 (root) | **Lead** | 사용자 세션과 동일 | native teammate-message (양방향) |
| Tier 2 (child) | **Teammate** (또는 family child) | persistent, shutdown_request 까지 | native teammate-message (양방향) |
| Tier 3 (grandchild) | **Worker** (subagent) | ephemeral, 작업 완료 시 종료 | sync task result return (단방향, parent's turn 내) |

**핵심 차이 (Pattern A 대비):**
- Pattern A의 teammates는 "Lead의 가상 부속물" — 하나의 Lead 세션에 모두 attach
- Pattern B의 Tier 2 teammates는 **각자 독립된 tmux pane + Claude Code 세션** — 자기 작업 컨텍스트를 가지고 자율 수행
- Pattern B의 Tier 3 workers는 Tier 2가 spawn하는 표준 subagent — focused task용

**Topology 비교:**

```
Pattern A (Team, flat):              Pattern B (Family, 3-tier):

   ┌─── Lead pane ───┐                Lead pane (root)
   │                 │                  ├── Teammate pane #1 (child)
 [gemini] [codex] [sonnet]              │     ├── [Worker subagent A] (sync, ephemeral)
                                        │     └── [Worker subagent B] (sync, ephemeral)
                                        ├── Teammate pane #2 (child)
                                        │     └── [Worker subagent C] (sync, ephemeral)
                                        └── Teammate pane #3 (child)
```

---

## 3. 통신 규칙 (Communication Rules)

### 3.1 Forward — Delegation

| 출발 | 도착 | 메커니즘 | 동기성 |
|---|---|---|---|
| Lead | Teammate (직속 child) | `SendMessage(to: <name>)` | 비동기 |
| Teammate | Worker (자기 subagent) | `Agent()` spawn with prompt | 동기 (parent's turn 내) |

각 노드는 자기 직속 하위에게만 위임. cross-tier 직접 위임 불가:
- ❌ Lead → Worker 직접 (반드시 Teammate 경유)
- ❌ Teammate A → Teammate B의 Worker 직접

### 3.2 Reverse — Reporting

| 출발 | 도착 | 메커니즘 | 동기성 |
|---|---|---|---|
| Worker | Teammate (자기 spawner) | task result return | 동기 (Teammate의 turn 내) |
| Teammate | Lead | `SendMessage(to: "team-lead")` | 비동기 (native teammate-message로 도착) |

각 노드는 자기 직속 상위에게만 보고. cross-tier 직접 보고 불가:
- ❌ Worker → Lead 직접 (SDK 차원에서 불가능 — Worker는 SendMessage 미보유)
- ❌ Teammate A → Teammate B 직접 (peer 간 통신 없음, Lead 경유 필요)

### 3.3 명시적 비통신 경로 (Explicit non-paths)

**SDK가 architecturally 보장하는 격리:**
- Worker는 SendMessage tool이 없음 → Lead나 다른 Teammate에게 직접 통신 자체가 **기술적으로 불가**
- Worker의 결과는 자기 spawner (Teammate) 에게만 sync 반환
- Teammate가 Worker 결과를 종합한 후 Lead에게 SendMessage로 보고

**컨벤션으로 enforce하는 격리:**
- Teammate 간 직접 SendMessage는 SDK 차원에서 가능하나, **표준 워크플로에서는 사용하지 않음** (Lead 경유)
- 위반 시 Lead의 inbox에 비표준 트래픽이 보이므로 즉시 인지 가능

> **이유**: 정보 격리(isolation) + 각 Teammate의 인지 부하 감소. Lead는 각 Teammate의 consolidated 결과만 보면 충분하며, sub-task의 세부 진행 상황은 Teammate 레이어에서 흡수.

### 3.4 수신자 UX 요구사항

각 receiver 노드 (Lead 및 모든 Teammate)에 대해 다음을 만족해야 함:

- **R1.** 수신자의 Claude Code 인스턴스는, 사용자 입력 없이 메시지 도착을 인지해야 한다.
- **R2.** 도착 알림은 Claude Code의 **native teammate-message 이벤트**로 surfaced되어야 한다.
- **R3.** 수신자는 메시지 도착 즉시 (다음 turn에) 응답·처리 액션을 수행할 수 있어야 한다.
- **R4.** 수신자 Claude는 **polling loop를 직접 실행하지 않는다** — 수신은 event-driven으로 inbound channel에서 발생.

R1~R4는 Tier 1↔2 (native teammate-message) 통신에만 적용. Tier 2→3 (Worker 호출)은 동기 방식이므로 별도 UX 요구 없음 (parent's turn 내에서 자연스럽게 처리).

---

## 4. 명시적 Out-of-scope

**MVP 제외:**
- **Tier 4+ (depth >3)**: SDK 차원에서 native teammate-message로는 불가. 무한 깊이 필요시 별도 설계 (custom bridge 등) 추후 트랙
- **Cross-tier 직접 라우팅** (Worker → Lead 직접 등) — SDK 차원에서 불가능 (Worker는 SendMessage 미보유)
- **Teammate 간 직접 통신 (peer-to-peer)** — 표준 워크플로 아님, Lead 경유
- **Claude Code 측의 능동 polling loop** (예: Teammate가 5초마다 inbox 재조회) — R4 위반
- **하나의 envelope으로 양방향 동시 통신** (delegate ↔ report 동시) — 한 envelope은 한 방향만
- **PR #20 (debug logging)의 로깅 계층 인프라** — 별도 트랙

**확장 단계로 분류 (MVP 검증 후):**
- Worker 결과를 Lead에 native teammate-message 로 surfacing (현재는 Teammate 경유)
- depth-4+ 지원 (custom bridge로 SDK 제약 우회)
- Multi-Lead (Lead 자체가 여러 개) 시나리오
- Family 간 cross-team 통신

---

## 5. 수용 기준 (Acceptance Criteria)

본 요구사항이 충족되었다고 판정하는 객관적 기준:

- **AC1.** Lead가 Teammate (Tier 2) 의 SendMessage 메시지를 native teammate-message로 수신함이 검증된다 (사용자 입력 없이).
- **AC2.** Teammate가 Lead의 SendMessage 메시지를 native teammate-message로 수신함이 검증된다.
- **AC3.** Teammate가 `Agent()` 으로 Worker (Tier 3) 를 spawn하여 작업 위임 + sync 결과 수신이 동작한다.
- **AC4.** Worker의 결과가 자기 Teammate에게만 도달하고, **Lead에 직접 도달하지 않음**이 검증된다 (정보 격리).
- **AC5.** 모든 Claude Code 노드 (Lead, Teammate)가 lifetime 동안 polling loop를 실행하지 않는다 (R4).
- **AC6.** Family lifecycle: Teammate는 `shutdown_request` 송수신 시 정상 종료. Worker는 자기 task 완료 시 자동 종료.
- **AC7.** 1-Lead + 1-Teammate + 1-Worker (3-tier 1-hop each) E2E 자동 테스트 통과.

**MVP 범위 외 AC (확장 단계):**
- Multi-Teammate (Lead + N teammates) 동시 운영 검증
- Multi-Worker per Teammate fanout 검증
- depth-4+ (이 요구사항의 out-of-scope)

---

## 6. 기존 자산과의 관계 (Relationship to existing assets)

### 본 요구사항이 영향을 주는 항목

| 항목 | 영향 |
|---|---|
| **#39** | 재정의됨 — "leaf→master 직접 라우팅 검증"이 아니라 **3-tier hop-by-hop teammate-message 수신 + Worker isolation 검증** |
| **#38** | 본 요구사항과 직접 관련 없음 (cosmetic CLI bug). 별도로 처리 가능. |
| **`tests/test_chain_integration.sh`** | 현재 leaf→master 직접 routing 검증 — Family 사용자 표준 흐름과 불일치. **CLI primitive capability test로 재분류** (삭제 X, 회귀 방지 목적은 유지) |
| **`bridge-mcp-server.js` + `clmux-bridge.zsh`** | Pattern A 구현체. **수정 불필요.** Pattern B는 SDK 자체 기능 사용 (Agent + SendMessage), bridge 재사용 X |
| **`clmux-orchestrate notify_pane`** | Pattern B는 native teammate-message 사용 → Family 흐름에서 미사용. 기존 chain 코드 호환용으로만 잔존 가능. design 단계에서 deprecate 여부 결정. |
| **`~/.claude/skills/clmux-{master-mid,mid,mid-leaf,leaf}/`** | 4종 skill — Pattern B 채택 시 **재구성**: Family child용 단일 skill (Tier 2 receive 패턴) + Worker는 일반 subagent 패턴이라 별도 skill 불필요 |
| **`lib/chain-*.zsh`** | Pattern B는 **얇은 wrapper만** 신설 (`lib/family.zsh` ~30 라인): Agent() 호출 + 합리적 default. 기존 `chain-*.zsh`는 deprecation/migration 트랙 별도 |
| **`clmux-{master,mid,leaf}` wrapper 함수** | Pattern B는 단일 `clmux-family-spawn-child` (Lead가 호출) + Worker는 Teammate가 직접 Agent() 호출. 기존 wrapper와 병존 후 추후 마이그레이션 |
| **tmux options `@clmux-chain-*`** | Pattern B는 SDK가 team config.json 으로 멤버십 관리 → tmux options 사용 X. 기존 chain 호환용으로만 잔존 |

### 본 요구사항이 영향을 주지 않는 항목

- Pattern A (team) 동작 — 100% 유지
- `clmux` 세션 관리 (`-n`, `-g`, `-x`, `-c` 플래그)
- bridge teammates (`clmux-{gemini,codex,copilot}`)

---

## 7. 비요구사항 / Anti-requirements (오해 방지)

명시적으로 **요구하지 않는** 사항:

- ❌ Lead가 Worker 작업을 실시간으로 모니터링 (Worker는 spawn한 Teammate에만 보고)
- ❌ Teammate가 Worker의 progress를 stream으로 받음 (sync 결과 수신만)
- ❌ depth-4+ 깊이 지원 (out-of-scope, 별도 트랙)
- ❌ Worker가 또 다른 Worker를 spawn (Worker의 Agent 호출 능력 미검증, MVP 미사용)
- ❌ Teammate 간 직접 통신 (P2P) — Lead 경유
- ❌ Pattern A를 Pattern B로 대체 — 두 패턴은 공존
- ❌ 무한 재귀 native UX (SDK 차원에서 불가능 — U1 spike 결과)

---

## 8. 다음 단계 (Next steps after approval)

1. ✅ 본 요구사항 doc v2 사용자 승인
2. ⏭️ **B 항목 결정** — Over-engineering 정리 범위
   - (i) Family 추상 도입 + `notify_pane` 제거 (Pattern B용) + `orchestrate`는 thin metadata로 유지 (권장)
   - (ii) 위 + `orchestrate` 완전 제거 (audit trail 포기)
   - (iii) Family 추상 도입만, 기존 `orchestrate` / `notify_pane` 모두 보존 (보존적)
3. ⏭️ Design phase — Family 3-tier가 R1~R4를 충족하는 구체적 구현 (Agent 호출 default, skill body 패턴, Worker 결과 consolidation 패턴 등)
4. ⏭️ Design doc 작성 + 승인
5. ⏭️ Implementation plan (writing-plans skill)
6. ⏭️ MVP 구현 (~2.5h estimated)
7. ⏭️ E2E 테스트 + AC 검증

---

## 9. Naming 결정 기록 (Naming Decision Log)

본 요구사항 명세 과정에서 결정된 어휘 목록.

### 9.1 추상 이름: **Family** (Pattern B)

| 단계 | 후보 | 결과 |
|---|---|---|
| 1차 brainstorm | Chain / Delegation / Lineage / Crew / Tier | Chain 권장 (cross-provider gemini + sonnet 합의) |
| 멤버 명칭 변경 후 재검토 | Family / Tree / Lineage / Chain / Clan / Brood | **Family 채택** — Parent/Children과 자연어 정합성 최강, Pattern A "team"과 분리 명확 |

### 9.2 멤버 명칭: **Lead / Teammate / Worker** (3-tier)

| 단계 | 후보 | 결과 |
|---|---|---|
| 1차 후보 | Master/Slave (deprecated), Master/Mid/Leaf (3-tier 고정) | 모두 거부 → recursive 2-party로 전환 |
| 2차 후보 | upstream/downstream / parent/child / 등 | Cross-provider review → **parent/children 채택** |
| **U1 spike 결과 반영** | SDK 제약으로 무한 재귀 불가 → 3-tier 강제 | **Lead / Teammate / Worker** (SDK 자연 구조 매핑) |

**최종 어휘 진화:**
- v1: Master/Mid/Leaf (3-tier 고정 라벨, recursive 미지원)
- v1.5: parent/children (recursive 2-party, 무한 깊이 가정)
- **v2 (현재): Lead/Teammate/Worker** (3-tier, SDK 자연 매핑, depth-3 한정)

**탈락 이유 (v2 결정):**
- **무한 재귀 모델**: SDK가 "teammates cannot spawn other teammates" 강제 → 기술적 불가능
- **parent/children 일관 사용**: depth-3 한정에서는 children 안에 다시 children이 없으므로 의미 일관성 약화
- **Lead/Teammate/Worker가 SDK 자연 구조에 정확 매핑**: 추가 추상 비용 0

### 9.3 채택된 핵심 어휘 (요약, v2)

| 개념 | 어휘 |
|---|---|
| Pattern A 추상 | **team** (기존 유지) |
| Pattern A 멤버 | **Lead** + **teammate** (기존 유지) |
| Pattern B 추상 | **family** (신규) |
| Pattern B Tier 1 | **Lead** (Pattern A와 동명, 컨텍스트로 구분) |
| Pattern B Tier 2 | **Teammate** (또는 명확화 시 "family child" / "family teammate") |
| Pattern B Tier 3 | **Worker** (또는 SDK 직접 표현 시 "subagent") |
| Pattern B 이벤트 (Tier 1↔2) | **family-message** (개념상) / SDK 레벨에선 teammate-message |
| Pattern B 위임 (Lead → Teammate) | `SendMessage` |
| Pattern B 위임 (Teammate → Worker) | `Agent()` spawn |
| Pattern B 보고 (Teammate → Lead) | `SendMessage` |
| Pattern B 보고 (Worker → Teammate) | task result return |

이 어휘는 wrapper 함수명, skill body, docs, 이벤트 명에 일관 적용된다.

---

## 10. 검증 결과 부록 — U1 Spike

**Date**: 2026-04-19
**Scope**: "spawned teammate가 자기 자리에서 Agent tool을 호출해 sub-teammate (grandchild)를 spawn할 수 있는가?"

**시험 절차**: chain-ux 팀의 claude-sonnet (sonnet teammate, pane %3) 가 Agent tool로 spike-grandchild (haiku) spawn 시도

**결과 요약**:

| 항목 | 결과 |
|---|---|
| Agent tool 호출 자체 | ✅ teammate context에서 정상 호출 가능 |
| `team_name` / `name` 파라미터 사용 | ❌ teammate context에서 사용 불가 ("teammates cannot spawn other teammates" 시스템 제약) |
| 결과로 spawn된 것 | subagent (team 멤버 아님, config.json members 미등록) |
| Subagent의 SendMessage 사용 | ❌ Subagent 환경에 SendMessage tool 자체가 없음 |
| Subagent → spawner 통신 | ✅ task result return (sync, parent's turn 내) |
| Subagent → Lead 직접 통신 | ❌ 불가능 (SendMessage 미보유) |
| Lead가 subagent 메시지 직접 수신 | ❌ 안 봄 (정보 격리 자동) |

**결론**:
- **무한 재귀 native teammate-message는 SDK 차원에서 불가능**
- **3-tier (Lead → Teammate → Subagent/Worker) 구조가 SDK가 강제하는 자연스러운 형태**
- 사용자 요구사항 중 정보 격리 / 직접 보고 없음은 SDK가 자동 충족
- 무한 깊이만 양보 → depth-3 한정으로 v2 정정

**이 결과가 본 요구사항 v2의 §2 Pattern B 정의 근거.**
