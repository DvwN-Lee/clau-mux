# clmux Phases — Upstream (P1 SPEC + P2 DESIGN + Gate Protocol)

## P1 SPECIFICATION

### 요구사항 명세 기법

구조화된 명세 기법을 사용하여 요구사항의 명확성과 추적 가능성을 확보한다. 아래는 EARS(Easy Approach to Requirements Syntax) 패턴을 예시로 제시한다 — 프로젝트에 적합한 다른 기법으로 대체 가능.

| 패턴 | 형식 (EARS 예시) | 예시 |
|------|------|------|
| Ubiquitous | The [system] shall [action] | The system shall encrypt all passwords |
| Event-driven | When [event], the [system] shall [action] | When a user logs in, the system shall create a session |
| Unwanted | If [condition], then the [system] shall [action] | If auth fails 5 times, then the system shall lock the account |
| State-driven | While [state], the [system] shall [action] | While offline, the system shall queue requests |
| Optional | Where [feature], the [system] shall [action] | Where dark mode is enabled, the system shall apply dark theme |

**모호성 태그 권장**: 불명확한 요구사항에 태그(예: `[NEEDS CLARIFICATION]`)를 추가하고, Gate 통과 전 전체 해소를 권장한다.

### P1 프롬프트 템플릿

**1-1. 요구사항 분석 (Lead → Teammates)**
```
역할: clmux Phase 1(SPECIFICATION) Lead Agent
주입: @CLAUDE.md, [PRD/이슈 설명]

작업:
1. PRD에서 명시적/암묵적 요구사항 추출
2. 각 요구사항을 EARS 5패턴 중 하나로 변환
3. [NEEDS CLARIFICATION] 태그 추가 (모호 항목)
4. 비기능 요구사항 분리 (성능/보안/호환성)

초안 완성 후 Teammate에게 VETO 검토 요청.
Teammate: Architect (사양-비평가), Researcher (도메인 조사)
```

**1-2. VETO 투표 (Teammate)**
```
역할: Phase 1 [역할명] Agent
검토 대상: [requirements.md 초안]

검토 기준:
1. 완결성 — PRD 모든 요구사항 포함 여부
2. EARS 정확성 — 올바른 패턴 사용 여부
3. 모호성 — [NEEDS CLARIFICATION] 누락 여부
4. Constitution 정합성 — CLAUDE.md 원칙 충돌 여부
5. 구현 가능성 — 현재 기술 스택 범위 내 여부

VETO 시: 구체적 사유 + 수정안 필수. 사유 없는 VETO 무효.
```

---

## P2 DESIGN

### design.md 표준 포맷

```markdown
# design.md: [프로젝트명]

## 아키텍처 개요
[시스템 컴포넌트 구조 + 의존성 다이어그램 (텍스트)]

## 공개 인터페이스 정의
[함수 시그니처, API 엔드포인트, 클래스 인터페이스]

## 데이터 모델
[핵심 데이터 구조 및 스키마]

## 기술 결정사항
[라이브러리/패턴 선택 근거, Constitution 정합성 확인]
```

### tasks.md 표준 포맷

```markdown
| Task ID | 설명 | AC | 의존 Task | 병렬 그룹 | 상태 | 시작 | 완료 | Cycle Time |
|---------|------|----|----------|----------|------|------|------|------------|
| T-001 | [제목] | [Acceptance Criteria] | — | G1 | Todo | | | |
```

상태 모델: `Todo → In Progress → Done`. 의존성 그래프에 순환 없음 필수 (위상 정렬 검증).

### P2 프롬프트 템플릿

**2-1. 시스템 설계 (Lead → Teammates)**
```
역할: clmux Phase 2(DESIGN) Lead Agent
주입: @CLAUDE.md, @requirements.md

MUST NOT: add features beyond requirements.md, write implementation code,
           write tasks.md without design.md, include circular dependencies in tasks.md

작업:
1. design.md 작성 (위 포맷)
2. tasks.md 작성 (위 포맷) — 의존성 그래프 + 병렬 그룹 식별
3. 초안 완성 후 Teammate에게 리뷰 요청

Teammate (주도): Architect (설계-비평가), Dev (구현-전략가)
Teammate (보조): Analyst (검증 계획), Researcher (기술 대안)
```

**2-2. 설계 리뷰 (Teammate)**
```
역할: Phase 2 [설계-비평가 | 구현-전략가] Teammate
검토 기준:
1. 인터페이스 완결성 — requirements.md 전체 기능 표현 여부
2. 순환 의존성 없음 — tasks.md 그래프 검증
3. Constitution 정합성 — CLAUDE.md 원칙 준수
4. DoD 충족 가능성 — 설계로 DoD 기준 충족 가능 여부
5. 구현 가능성 — Phase 3 실현 가능 수준의 정의 여부

VETO 시: 구체적 사유 + 수정안 필수. 사유 없는 VETO 무효.
```

### dod.md 체크리스트

Phase 2 완료 시 `docs/dod.md` 작성 필수 (Phase 2→3 Gate 조건).

최소 필수 항목:
- [ ] 모든 R-NNN이 tasks.md에 task로 분해됨
- [ ] 각 task에 AC(Acceptance Criteria) 1개 이상
- [ ] design.md 공개 인터페이스 정의 완료
- [ ] tasks.md 순환 의존성 0건

---

## Phase Gate Protocol

### Permission Mode

| Phase | 명칭 | Permission Mode |
|-------|------|----------------|
| 0 | FOUNDATION | `default` |
| 1 | SPECIFICATION | `plan` |
| 2 | DESIGN | `acceptEdits` |
| 3 | BUILD | `acceptEdits` + Hooks 활성화 |
| 4 | VERIFY | `plan` |
| 5 | REFINE | `acceptEdits` |

### Phase별 필수 산출물

| 산출물 | Phase | Hotfix | Feature | Epic | 생성 주체 |
|--------|:-----:|:------:|:-------:|:----:|---------|
| `CLAUDE.md` | 0 | Y | Y | Y | Agent |
| `.claude/settings.json` | 0 | Y | Y | Y | Agent |
| `project-brief.md` | 0 입력 | — | Y | Y | Human |
| `requirements.md` (EARS) | 1 | — | — | Y | Lead + Teammates |
| `design.md` | 2 | — | Y | Y | Lead + Teammates |
| `tasks.md` | 2 | — | Y | Y | Lead + Teammates |
| `docs/dod.md` | 2 | — | Y | Y | Lead + Teammates |
| 코드 + 테스트 | 3 | Y | Y | Y | Lead + Teammates |
| `docs/verify-report-YYYYMMDD.md` | 4 | — | Y | Y | Lead + Teammates |
| `.claude/saga/checkpoints/gate-P{N}-YYYYMMDD-HHmm.md` | Gate 전환 시 | 권장 | Y | Y | **Agent** |

### Gate 조건

> 아래 조건은 권장 기준이다. 프로젝트 규모와 트랙(Hotfix/Feature/Epic)에 따라 조정 가능.

**Phase 0 → 1:**
- CLAUDE.md Constitution MUST be complete
- settings.json allow/deny/ask MUST be configured
- Hook scripts MUST be deployed and tested

**Phase 1 → 2 (Epic Track):**
- ALL requirements MUST have structured specification (e.g., EARS) applied
- Ambiguity tags (e.g., `[NEEDS CLARIFICATION]`) MUST be 0
- Unresolved VETO count MUST be 0
- Wave 분할 계획 수립
- Gate checkpoint secret scanning MUST pass: `detect-secrets scan .claude/saga/checkpoints/` 0건

**Phase 2 → 3:**
- ALL interfaces in design.md MUST be defined
- tasks.md dependency graph MUST have no cycles
- `docs/dod.md` MUST be written and complete

**Phase 3 → 4:**
- ALL tasks.md items MUST be complete (0 incomplete, Feature/Epic)
- ALL tests MUST pass + Lint/Type check MUST pass
- PR MUST be created
- Phase 4 Validator MUST NOT be the same as Phase 3 Generator (검증 Teammate ≠ 구현 Teammate)

**Phase 4/5 → 완료**: §P4 VERIFY §6 참조.

**Phase Gate commit**: `<type>(TASK-ID): <Phase N 요약>` (Conventional Commits)

### Gate Checkpoint 원칙

| 파일 | 생성 주체 | 수정 가능 여부 |
|------|----------|-------------|
| `.claude/saga/checkpoints/gate-P{N}-YYYYMMDD-HHmm.md` | Agent (Gate 전환 시) | Agent 생성 후 수정 가능 |

### Mid-Phase Checkpoint

**생성 트리거**: Wave 완료(P3), VETO Round 완료(P1·P2), partial COMPLETION 수신(전체), graceful shutdown(전체)

**위치**: `.claude/saga/checkpoints/{phase}-{context}-{YYYYMMDD-HHmm}.md`

**포맷**:
```markdown
---
type: checkpoint
phase: P[N]
context: [wave-N | veto-rN | partial | shutdown]
git_sha: [git rev-parse HEAD]
timestamp: [ISO 8601]
---
## 진행 상태
- Phase: P[N] [명칭] / 현재 단계: [Wave N / VETO Round N / Task-NNN 실행 중]

## Teammate 작업 현황
| Teammate | 마지막 Task | Status | Notes |

## 미해소 이슈
- [있는 경우 목록]
```

| 항목 | Gate Checkpoint | Mid-Phase Checkpoint |
|------|----------------|---------------------|
| 생성 시점 | Phase Gate 전환 | Phase 내부 진행 중 |
| 위치 | `.claude/saga/checkpoints/gate-P{N}-*.md` | `.claude/saga/checkpoints/{phase}-{context}-*.md` |
| 보존 기간 | 영구 (다음 Phase 완료 시까지) | 48시간 stale |
| 용도 | Phase 간 인수인계 + 장기 복원 폴백 | 세션 중단 시 정밀 복원 |
