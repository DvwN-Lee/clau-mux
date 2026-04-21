---
name: clmux-veto
description: "clmux VETO 합의 프로토콜 (Cross-Provider 합의). Phase별 합의 기준(Unanimity/Supermajority/Pessimistic Consolidation), Evidence Pack 기반 투표, provider_family 집계, Kill-switch 예외, Generator-Validator 분리. 사용자가 VETO, 합의 프로토콜, Kill-switch를 언급하거나 /clmux:clmux-veto를 호출할 때 사용한다."
user-invocable: true
metadata:
  author: clmux
  version: "1.0"
compatibility: Requires Claude Code with Agent Teams enabled
---

# clmux VETO 프로토콜 (Cross-Provider 합의)

## Teammate VETO Perspective Guide

팀 Teammate 전원이 VETO에 참여한다.
단, Generator-Validator 분리 원칙에 따라 역할별 이해 충돌이 있는 경우 Lead가 투표권 범위를 안건별로 지정한다 (§ Generator-Validator 분리 원칙 참조).
각 Teammate는 자기 전문 관점에서 투표한다.

| 역할 유형 | 전문 관점 | 주요 확인 항목 |
|---------|---------|--------------|
| 설계 역할 | 아키텍처·인터페이스·EARS 완결성 | 순환 의존성, 설계 정합성, 구현 가능성 |
| 구현 역할 | 구현 전략·DoD·기술 제약 | 실현 가능 수준, 테스트 가능성 |
| 검증 역할 | 검증 가능성·보안·성능 | V-1~V-4 사전 리스크, Spec drift 가능성 |
| 조사 역할 | 선행 사례·기술 근거 | 외부 문서 기반 evidence, 대안 존재 여부 |
| **critic** (Sonnet) | 논리 결함·가정 검증 | rebuttal, secondary critique |
| **challenger** (Gemini Pro) | 프레임 전환·대안 관점 | 대안 아키텍처, 전제 조건 재검토 |

> Lead가 투표권 범위를 명시하지 않은 경우 전 Teammate가 투표한다. Generator-Validator 분리가 필요하면 Lead가 안건별로 투표 제외 역할을 지정한다.

## Cross-Provider 참여 요건

### Rule 3 적용

채택 시 아래 조건을 **모두** 충족해야 한다:

1. **비-Claude 1개+ provider_family 독립 지지** — Claude(anthropic) 외 최소 1개 provider_family 동의
2. **교차 검증 증거 1개+** — 구현 Provider ≠ 검증/테스트 Provider인 실행 결과

provider_family 집계 규칙 상세는 [evidence-pack.md §provider_family 집계 규칙](../clmux-phase/references/evidence-pack.md#provider_family-집계-규칙) 참조.

### clmux teammate VETO 참여

| 항목 | Claude teammate | clmux teammate |
|---|---|---|
| 투표권 (Approve/VETO) | O | **X** (의견 제출만) |
| Evidence Pack 기반 의견 | O | **O** (Rule 3 판정 근거) |
| 독립 지지 인정 | anthropic 1개 | 각 provider_family 1개 |

clmux teammate의 의견은 투표가 아닌 **Evidence Pack 기반 독립 지지/반대 의견**으로 처리된다.
Lead가 Rule 3 충족 여부를 판정할 때 provider_family 단위로 집계한다.

## Lead 역할: 중재자 (Mediator)

Lead는 VETO 투표에 **참여하지 않는다**. Lead의 책임:

1. **안건 제시**: VETO 대상 산출물과 검토 기준을 Teammate에게 broadcast
2. **리스크 레벨 판정**: High/Medium/Low → 프로토콜 차등 적용
3. **토론 진행**: 라운드 관리, 시간 제한, 논점 정리
4. **반박 역할 배정**: 매 라운드 Codex/Gemini 중 1명 반박자 지정 (Rule 4)
5. **교착 해소**: 합의 실패 시 Constitution·requirements.md 기반으로 결정
6. **판정 로그 기록**: Evidence Pack 필드 기반 판정 근거 + 기각 사유 + 잔여 리스크 (Rule 6)
7. **Rule 3 확인**: 비-Claude provider_family 지지 + 교차 검증 증거 확인

Lead is excluded from voting. 앵커링 바이어스 방지 (리더 의견이 팀 판단을 왜곡).

## Phase별 합의 메커니즘

| Phase | 작업 성격 | 합의 기준 | Rule 3 | 근거 |
|-------|---------|---------|:---:|------|
| P1 SPEC | 지식·사양 정의 | **Unanimity** (Veto 0건) | 필수 | 사양 누락은 전 Phase에 전파 |
| P2 DESIGN | 설계 trade-off | **Supermajority** (75%+ Approve) | 필수 | 설계는 대안이 존재 |
| P4 VERIFY | 추론·검증 | **독립 투표 + Pessimistic Consolidation** | 필수 | 검증은 독립성이 핵심 |

### 리스크 레벨별 VETO 차등

| 리스크 | VETO 프로토콜 |
|--------|-------------|
| **High** | 풀 프로토콜: 독립 초안 + EP 2-pass + 전원 투표 + Rule 3 필수 |
| **Medium** | EP + 비-Claude 1개 확인 (간소화 투표) |
| **Low** | CI Green + Copilot PR 리뷰 자동 승인 (VETO 생략) |

## VETO 운용

### Phase A: 팀 내 토론 + Evidence Pack 기반 투표

#### Step 1: 자유 토론

1. Lead가 안건을 전 Teammate에게 broadcast (SendMessage) 후 지시:
   > "Teammate 간 자유 토론 진행. 완료 후 `votes/` 파일에 투표 기록"
2. Teammate 간 peer DM으로 논의: `SendMessage(to: "<teammate-name>")`
   (**통신 원칙 예외**: VETO 토론 예외 조항 적용)
3. **반박 역할 배정**: Lead가 Codex/Gemini 중 1명을 반박자로 지정 (Rule 4)
4. Lead MUST NOT intervene during discussion (프롬프트 수준의 soft control)

> **플랫폼 제약 고지**: Agent Teams 구조상 Lead의 완전 격리는 아키텍처적으로 불가능하다.
> Lead는 Teammate peer DM 요약이 포함된 idle 알림을 수신한다 — 이는 차단할 수 없다.
> Evidence Pack 기반 투표는 이 구조적 한계를 인지한 편향 감소 조치이며, 완전한 격리를 보장하지 않는다.

#### Step 2: Evidence Pack 기반 투표

1. 토론 완료 후 각 Teammate는 `votes/{agenda-id}-{teammate-name}.md` 파일 작성:

   ```markdown
   # VOTE: {Approve|VETO}
   ## Teammate: {name}
   ## provider_family: {anthropic|google|openai|github}
   ## 안건: {agenda-id}
   ## Evidence Pack 기반 근거
   - task_fit_score: [0.0-1.0]
   - evidence_strength_score: [0.0-1.0]
   - confidence_level: [self_reported / evidence_completeness / external_validation]
   - 교차 검증 증거: [tests/benchmark/scan/log — 구체 항목]
   ## 근거
   [evidence]
   ## 대안 (VETO 시)
   [proposal]
   ```

2. 파일 작성 후 Lead에게 "투표 완료" 통보 (SendMessage)
3. Lead가 `votes/` 디렉토리를 일괄 읽고 Phase별 합의 기준에 따라 판정:
   - **P1**: VETO가 1건이라도 있으면 해당 사유 토론 → 수정 후 재투표
     - Lead = Sonnet인 경우: 검증 역할 독립 검토 병행 — clmux-phase §Lead=Sonnet 역할 보완 참조.
   - **P2**: 75% 이상 Approve면 통과. Veto 측 사유는 기록 보존
   - **Rule 3 확인**: 비-Claude provider_family 독립 지지 존재 여부 + 교차 검증 증거 존재 여부

**Round 한도**: 5 Round → 미해소 시 Lead가 Constitution 기반 결정.
`tasks.md`에 `[중재자 결정]` 태그 기록.
> Round 한도 근거: ACL 2025 (Kaesberg) — 토론 라운드 증가 시 성능 하락.

### P4 독립 투표 모드

P4 VERIFY에서는 검증의 독립성 보장을 위해 Phase A Step 1(자유 토론)을 생략한다.

1. Lead가 안건을 전 Teammate에게 broadcast
2. 각 Teammate가 상호 참조 없이 독립적으로 `votes/{agenda-id}-{teammate-name}.md` 파일 작성
   - Evidence Pack 필드 기반 근거 기록 필수
   - provider_family 명시 필수
3. 파일 작성 후 Lead에게 "투표 완료" 통보
4. Lead가 **Pessimistic Consolidation**으로 통합 판정:
   - CRITICAL 발견 1건 이상 → single finding has blocking power (즉시 Phase 3 회귀 판정)
   - CRITICAL 0건 → Rule 3 확인 후 Gate 통과 절차 진행

> 토론 없는 독립 투표 근거: 검증 단계에서 사전 토론은 확증 편향을 유발한다 — 독립성이 핵심.

### Phase B: Lead 검증 (P1·P2만 적용)

- Lead가 합의안을 Constitution·requirements.md 기준으로 독립 검토
- **Rule 3 최종 확인**: 비-Claude provider_family 독립 지지 + 교차 검증 증거
- Approve → 확정 + 판정 로그 기록
- Reject → 사유 + 개선 방향과 함께 Phase A 재시작
- **Round 한도**: 3 Round → 미해소 시 Human 에스컬레이션

### Kill-switch 예외 (투표 없이 즉시 발동)

| 조건 | 조치 |
|------|------|
| 보안 취약점 (CVE High/Critical) | Immediate VETO + **MUST halt all work** |
| 법적 컴플라이언스 위반 | Immediate VETO + **MUST escalate to Human** |
| Constitution 핵심 원칙 위반 | Immediate VETO + **Lead MUST intervene immediately** |

## Generator-Validator 분리 원칙

Phase 3(BUILD)의 Generator와 Phase 4(VERIFY)의 Validator는
같은 Team 내의 **다른 Teammate 인스턴스**로 분리한다.

- Phase 3: 구현 담당 Teammate가 코드 생성 (Generator)
- Phase 4: 검증 담당 Teammate가 검증 주도 (Validator)
- 구현 담당 Teammate는 Phase 4 VETO에서 구현 의도 설명은 가능하나, Approve/Veto **투표권은 Lead가 지정**
- Validator Teammate MUST NOT be involved in Phase 3 BUILD

이 분리는 확증 편향(confirmation bias)을 구조적으로 차단한다.
Lead MUST explicitly designate Generator and Validator roles separately when forming the team.

### Cross-Provider 분리 강화

Generator-Validator 분리에 더해, Cross-Provider 검증을 적용한다:
- Phase 3 Generator가 Claude Sonnet이면, Phase 4에서 Codex/Gemini의 독립 의견을 필수로 수집
- 동일 provider_family 내에서만 검증하는 것은 Rule 3 위반
