# clmux Task Orchestration Protocol

> **적용 범위**: Feature / Epic 트랙 (Hotfix는 Lead 직접 수행 또는 Dev 단독 위임)
> **전제**: [clmux-phase](../SKILL.md) — 팀 구성, 모델 티어링, 2-tier 위임 구조

> **⚠ EXPERIMENTAL — Agent Teams**: Agent Teams 기능은 ECC에서 공식 문서화되지 않은 experimental 기능이다.
> Claude Code 버전 업데이트 시 동작 변경 또는 중단 가능성이 있다. 상용 프로젝트 도입 전
> 해당 버전에서 기능 동작을 직접 검증하고, 세션 Fallback 전략을 준비한다.
> Fallback 조건 및 절차: [clmux-phase](../SKILL.md) — "Agent Teams Fallback" 섹션 참조.

---

## 1. 통신 아키텍처

### 1.1 통신 채널 원칙

| 통신 방향 | 채널 | 근거 |
|-----------|------|------|
| Lead → 특정 Teammate | `SendMessage(to="teammate-name")` | 단일 수신자 지시 |
| Lead → 전체 Teammate | `SendMessage(to="*")` broadcast | VETO 안건 broadcast, Phase 브리핑 |
| Teammate → Lead | `SendMessage(to="lead")` | 완료 보고, 차단 신고, 질의 |
| Teammate → Teammate | **Lead 경유 원칙** (direct communication NEVER allowed)<br>**예외**: VETO 토론 시 peer DM 허용 ([clmux-veto §Phase A Step 1](../../clmux-veto/SKILL.md) 참조) | 교차 편향 방지, 추적 가능성 |
| User → Teammate | Teammate 직접 수신 가능 | Human 의사 직접 전달 |
| Teammate → User | **Lead 경유 원칙** | 일관된 상태 추적 |
| User → Lead | `SendMessage(to="lead")` 또는 직접 입력 | 전체 컨텍스트 보유 |

**직접 통신 예외**: P4 VERIFY에서 검증 Teammate가 구현 Teammate에게 구현 의도 설명을 요청하는 경우에 한해 Lead가 중개자(relay) 역할로 동일 메시지를 전달한다. 구현 Teammate의 응답도 Lead를 경유한다.

### 1.2 메시지 유형 정의

모든 메시지는 아래 4가지 유형 중 하나를 명시한다.

```
DISPATCH   — Lead → Teammate: 작업 할당
REVIEW_REQ — Lead → Teammate: 산출물 검토 요청
FEEDBACK   — Teammate → Lead: 검토 결과 / 수정 지시 반환
COMPLETION — Teammate → Lead: 작업 완료 보고
```

### 1.3 메시지 표준 포맷

**DISPATCH (작업 할당)**
```
type: DISPATCH
task_id: [TASK-NNN]
assignee: [teammate-name]
phase: P[N]
title: [한 줄 작업 제목]
input:
  - [참조 파일 또는 산출물 목록]
output_expected:
  - [예상 산출물]
acceptance_criteria:
  - [완료 기준 1]
  - [완료 기준 2]
deadline_condition: [다음 DISPATCH 전 / Phase Gate 전 / 즉시]
```

**COMPLETION (완료 보고)**
```
type: COMPLETION
task_id: [TASK-NNN]
reporter: [teammate-name]
status: done | blocked | partial
deliverables:
  - [실제 산출물 목록 (파일 경로 포함)]
notes: [비고 — 설계 결정, 발견된 리스크, 다음 단계 제안]
block_reason: [status가 blocked인 경우 필수]
resume_from: [status가 partial인 경우 — 재개 시작점 식별자]
completed_steps: [완료된 단계 목록]
remaining_steps: [미완료 단계 목록]
```

**FEEDBACK (검토 결과)**
```
type: FEEDBACK
task_id: [TASK-NNN]
reviewer: [teammate-name]
verdict: approve | request-change | veto
issues:
  - severity: [CRITICAL | MAJOR | MINOR]
    location: [파일:라인]
    description: [설명]
    proposal: [수정 제안]
revision_required: [true | false]
```

**REVIEW_REQ (검토 요청)**
```
type: REVIEW_REQ
task_id: [TASK-NNN]
reviewer: [teammate-name]
artifact: [검토 대상 산출물]
criteria:
  - [검토 기준 목록]
```

---

## 2. 작업 유형별 라우팅 플로우

### 요구사항 정의 작업 (P1 SPEC)

**주도**: 설계 Teammate
**보조**: 조사 Teammate (선행 조사), 구현/검증 Teammate (의견 제시)
**합의 기준**: Unanimity (VETO 0건) → [clmux-veto](../../clmux-veto/SKILL.md) 참조

**입력 산출물**: 프로젝트 요구 명세 (e.g. `project-brief.md`)
**출력 산출물**: `requirements.md`, `.claude/saga/checkpoints/gate-P1-YYYYMMDD-HHmm.md`

### 설계 작업 (P2 DESIGN)

**주도**: 설계 Teammate
**보조**: 구현 Teammate (구현 전략), 조사 Teammate (기술 대안), 검증 Teammate (검증 계획)
**합의 기준**: Supermajority (다수 Approve) → [clmux-veto](../../clmux-veto/SKILL.md) 참조

**입력 산출물**: `requirements.md`
**출력 산출물**: `design.md`, `tasks.md`, `docs/dod.md`, `.claude/saga/checkpoints/gate-P2-YYYYMMDD-HHmm.md`

### 구현 작업 (P3 BUILD)

**주도**: 구현 Teammate
**보조**: 설계 Teammate (설계 Q&A), 조사 Teammate (API/라이브러리 Grounding)
**VETO**: 없음 (Generator 단계 — 검증 Teammate 비참여)

**Wave 분할 기준**: `tasks.md` 의존성 그래프에서 독립 task 집합을 Wave로 묶는다. 동일 파일을 수정하는 task는 동일 Wave에 배치하거나 순차 실행한다.

**입력 산출물**: `design.md`, `tasks.md`, `docs/dod.md`
**출력 산출물**: 코드 + 테스트 (전체 통과), PR 생성, `.claude/saga/checkpoints/gate-P3-YYYYMMDD-HHmm.md`

### 검증 작업 (P4 VERIFY)

**주도**: 검증 Teammate
**합의 기준**: 독립 투표 + Pessimistic Consolidation → [clmux-veto](../../clmux-veto/SKILL.md) 참조
**Generator-Validator 분리**: 구현 Teammate는 투표권 없음, 검증 Teammate는 P3 비참여

**입력 산출물**: PR diff, `requirements.md`, `design.md`, `docs/dod.md`
**출력 산출물**: `docs/verify-report-YYYYMMDD.md`, `.claude/saga/checkpoints/gate-P4-YYYYMMDD-HHmm.md`

**P4 특이사항**: 검증 Teammate의 다관점 검증은 동일 Teammate가 순차 또는 내부 Subagent로 병렬 수행한다. 내부 Subagent 사용 시 `model` 파라미터 명시 필수. 관점 간 상호 참조는 Lead의 Consolidation 단계에서만 발생한다.

### 수정 및 동기화 작업 (P5 REFINE)

**주도**: 구현 Teammate (MAJOR 수정), 설계 Teammate (설계 반영), 검증 Teammate (재검증)
**입력**: verify-report 이슈 목록

**입력 산출물**: `docs/verify-report-YYYYMMDD.md`
**출력 산출물**: 수정된 코드 + 테스트, 갱신된 `design.md` (Drift 시), `.claude/saga/checkpoints/gate-P5-YYYYMMDD-HHmm.md`

---

## 3. Phase 내 반복 루프 조건

### 3.1 VETO 루프 (P1/P2)

```
[Phase A Round]
  Lead broadcast VETO 안건
    └─ Teammate 독립 투표 제출
         ├─ 합의 통과 → Phase B로 이동
         └─ VETO 존재 → 수정 작업 DISPATCH → COMPLETION 수신 → Phase A 재진입
              └─ Round limit 초과 → clmux-veto §Round 한도 적용

[Phase B Round]
  Lead 독립 검증
    ├─ Approve → Gate 통과
    └─ Reject → Phase A 재시작
         └─ Round limit 초과 → clmux-veto §Phase B Round 한도 적용
```

### 3.2 P3 BUILD 내부 루프

```
[단일 Task 루프]
  DISPATCH → 구현 Teammate 실행 (clmux-phase §P3 BUILD 참조)
    ├─ COMPLETION(status: done) → Wave 진행
    └─ COMPLETION(status: blocked) → Lead 에스컬레이션 (clmux-recovery 참조)

[Wave 루프]
  Wave N dispatch
    └─ 전체 Task COMPLETION 수신
         ├─ blocked 존재 → 해소 후 Wave N 재시도 (≤1회)
         │   └─ 재시도 실패 → Human 에스컬레이션
         └─ 전체 done → Wave N+1 dispatch
              └─ 전체 Wave 완료 → Phase 3→4 체크리스트 확인
```

### 3.3 P4 재검증 루프

```
[P4 Consolidation 후]
  CRITICAL 존재 → Phase 3 회귀 판정 (Lead가 회귀 범위 최소화 계획 수립)
  CRITICAL 0건 → Gate 통과 절차 진행
```

| 루프 유형 | 최대 Round | 초과 시 DISPATCH 대상 |
|-----------|-----------|---------------------|
| P4 재검증 요청 | 2 | CRITICAL 잔존 시 Phase 3 회귀 결정 |
| P5 MAJOR 수정 재검증 | 2 | MAJOR 잔존 시 Human 에스컬레이션 |

---

## 4. Teammate 간 통신 결정 트리

```
[통신 발생]
     |
     +-- Lead가 송신자? ─── Yes ──> SendMessage(to="teammate-name" or to="*") 직접 사용
     |
     +-- Teammate가 송신자?
           |
           +-- 수신자가 Lead? ──────> SendMessage(to="lead") 직접 사용
           |
           +-- 수신자가 다른 Teammate?
                 |
                 +-- VETO 토론 (P1/P2 Phase A Step 1)?
                 |     └──> peer DM 직접 허용 ([clmux-veto §Phase A Step 1](../../clmux-veto/SKILL.md) 예외)
                 |
                 +-- 정보 전달/질의? ──> Lead 경유 (Teammate→Lead→Teammate)
                 |
                 +-- P4 구현 의도 설명 요청? ──> Lead 경유 릴레이
                 |
                 +-- 긴급 Kill-switch 조건?
                       (CVE High/Critical, 법적 컴플라이언스 위반, Constitution 위반)
                       └──> Kill-switch: SendMessage(to="lead") + MUST stop work immediately + MUST escalate to Human
     |
     +-- User가 송신자? ─── Yes ──> §4.1 User 요청 처리 절차 참조
```

> **Kill-switch 불변 원칙**: Kill-switch 조건(CVE High/Critical, 법적 컴플라이언스 위반, Constitution 핵심 원칙 위반) 발동 시 MUST stop work immediately + MUST escalate to Human.

### 4.1 User 요청 처리 절차

**(a) User 요청 선행 확인:** Kill-switch 조건 해당 시:
    수신 Teammate → MUST send SendMessage to Lead + MUST stop work immediately + MUST escalate to Human.
    Kill-switch 조건 분류: [Kill-switch 예외](../../clmux-veto/SKILL.md#kill-switch-예외-투표-없이-즉시-발동) 참조.
    (이 경우 작업 요청을 종료한다. 이후 (b)~(d) 절차는 적용하지 않는다.)

**(b) 일반 요청 보고:** Kill-switch 미해당 시: 수신 Teammate → Lead SendMessage 보고

**(c) 기록:** Lead: MUST log to dispatch-log (§5.7 initiator: user 규칙 참조)

**(d) 충돌 판단:** 진행 중 Task와 충돌 시: Lead가 우선순위 판단
    충돌 판단 기준: 동일 파일 수정 요청, 현재 Wave 목표와 모순,
    또는 현재 Phase Gate 전제 변경에 해당하는 경우

> **User→Lead 직접 수신 시**: Lead가 Kill-switch 조건 확인을 직접 수행한 후 (c)~(d) 절차를 적용한다.

---

## 5. 구현 주의 사항

1. **TaskCreate 활용**: MUST register task via `TaskCreate` before issuing any `DISPATCH`.
2. **모델 명시 필수**: Teammate가 내부 Subagent를 spawn할 때 MUST specify `model` parameter.
3. **동시 Subagent 한도**: Teammate 1명당 ≤3개, 팀 전체 ≤8개.
4. **COMPLETION 없는 Teammate**: TeammateIdle 3회 연속 → Fallback 조건 적용.
5. **Spec 후퇴 금지**: P5 수정 시 MUST align code to Spec — reverting Spec to match code is NEVER allowed.
6. **라우팅 전 TaskList 확인**: MUST hold new DISPATCH when concurrent Subagent count reaches 80% threshold (6 or more team-wide).
7. **Dispatch Log 업데이트**: MUST log to `.claude/saga/checkpoints/dispatch-log.md` on every DISPATCH. User 요청 기반 task는 `initiator: user` 태그를 추가한다. Kill-switch 조건 해당 시 dispatch-log 기록 없이 즉시 에스컬레이션한다 (§4.1(a) 참조).
8. **VETO State 직렬화**: MUST write VETO state to `.claude/saga/checkpoints/veto-state.md` upon entering VETO.

---

## 6. Human Decision 요약 (Feature 정상 경로)

| 시점 | Gate | 유형 |
|------|------|------|
| Phase 0 시작 전 | project-brief.md 작성 | **MANDATORY** |
| Phase 4 완료 | PR Human Approve | **MANDATORY** |

**정상 경로 합계: 2회 (Feature/Epic 공통).**

### CONVERT 항목 (승인 → 통보 전환)

| 항목 | 전환 방식 |
|------|----------|
| requirements.md 승인 (P1→P2) | VETO Unanimity 통과 + Analyst 독립 검증 VETO 0건 = 자동 Gate + async 통보 (Analyst 독립 검증은 Lead=Sonnet 시에만 활성화) |
| Gate 미충족 롤백 | 자동 롤백 + gate checkpoint 기록 + async 통보 |
| CLAUDE.md 패턴 승격 | PR 초안 자동 생성 + 통보 |
