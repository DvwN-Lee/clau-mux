# clmux Phases — Downstream (P3 BUILD + P4 VERIFY + P5 REFINE)

## P3 BUILD

### Grounding Protocol

TDD 루프 시작 전 핵심 의존 라이브러리 최신 API를 확인하여 hallucination을 방지한다.

1. 담당 task의 핵심 의존 라이브러리 1~3개 식별 (design.md 기술 결정사항 + task AC 기준)
2. Context7 MCP 호출: `resolve-library-id` → `query-docs`
3. Grounding 결과 요약 후 TDD 루프 컨텍스트에 유지

### TDD 접근법

아래는 권장 5단계 TDD 루프(TDAID 패턴)다. 프로젝트 규모와 팀 합의에 따라 단계를 조정할 수 있다.

```
[Plan]     테스트 전략 수립, PBT 적용 결정, 경계 조건 식별
[Red]      실패 테스트 작성 (Contract 우선)
[Green]    최소 구현 (YAGNI)
[Refactor] 리팩터링 (3조건 충족 시에만)
[Validate] 통합 테스트 + 커버리지 + DoD 체크리스트
```

- **[Plan]**: AC 기반 테스트 목록. 우선순위: Contract → Integration → E2E → Unit. 경계 조건(null, 빈값, 최대값, 음수) 식별.
- **[Red]**: Contract tests (interface signature verification) MUST come first. Integration MUST NOT be written before Contract passes. 엣지 케이스 최소 2개.
- **[Green]**: ONLY write minimum code to pass tests. MUST NOT add excessive abstraction or future-facing code.
- **[Refactor]**: ALL three conditions MUST be met simultaneously — all tests pass AND coverage does not decrease AND no new features added.
- **[Validate]**: 통합 테스트 + 커버리지 검증 + DoD 체크리스트. Feature/Epic Track에만 적용.

### P3 프롬프트 템플릿

**3-0. Grounding**
```
역할: Phase 3(BUILD) Dev Teammate
작업: TDD 루프 시작 전 Grounding
1. 담당 task 핵심 의존 라이브러리 식별 (1~3개)
2. Context7 호출: resolve-library-id → query-docs
3. Grounding 결과 요약 후 3-1 TDD 루프 시작
```

**3-1. TDD 루프 (단일 task)**
```
역할: Phase 3(BUILD) Dev Teammate
주입: @CLAUDE.md, [task 내용], [design.md 관련 섹션], [Grounding 결과]

실행: [Plan] → [Red] → [Green] → [Refactor] → [Validate] → git commit
커밋 형식: feat([task-id]): [task 제목]
Constitution 위반 발견 시 즉시 중단 + Human 보고.
```

**3-2. Worktree 병렬 실행**
```
역할: Phase 3(BUILD) Dev Teammate
배치:
1. 독립 task 그룹별 Subagent spawn (isolation: "worktree")
2. 완료 후 메인 브랜치 통합
```

### Worktree 병렬 실행 규칙

- **동일 파일 수정 금지**: tasks.md 의존성 그래프로 파일 소유권 확인. Teammates MUST NOT modify the same file concurrently.
- **의존성 확인**: task 간 의존 관계 있으면 순차 실행. Tasks with dependencies MUST run sequentially.
- **충돌 해결**: merge conflict 시 의미적 우선순위 기준 Lead 해소 → 판단 불가 시 Human 에스컬레이션
- **비정상 종료**: `git worktree list` 확인 → 내용 검토 후 cherry-pick → `git worktree remove`

### PBT Quick Reference

**적용 기준**: EARS 요구사항에 "ANY", "ALL", "EVERY" 등 범위 표현이 있는 경우.

```
EARS:     WHEN [event], THE SYSTEM SHALL [action]
Property: forAll(input) => trigger(event, input) implies action(result) == true
```

프레임워크: Python → Hypothesis, JS/TS → fast-check.

---

## P4 VERIFY

### 다관점 검증 체크리스트

다음은 4가지 관점(V-1~V-4)의 검증 항목 예시다. 프로젝트 맥락에 따라 관점을 추가·조정할 수 있다.

**V-1 정확성**
- [ ] Constitution 아키텍처 원칙 준수
- [ ] 레이어 역전/순환 의존성 없음
- [ ] 모든 공개 인터페이스에 테스트 존재
- [ ] 테스트 커버리지 ≥ 프로젝트 기준
- [ ] 코드 중복 없음

**V-2 보안**
- [ ] 외부 입력 검증 누락 없음
- [ ] 인증/인가 우회 가능성 없음
- [ ] 민감 데이터 노출 위험 없음
- [ ] SQL Injection, XSS, Command Injection 취약점 없음
- [ ] 의존성 보안 취약점 없음

**V-3 성능**
- [ ] N+1 쿼리 또는 불필요 반복 호출 없음
- [ ] 대량 데이터 시 메모리/시간 복잡도 적절
- [ ] 캐싱 전략 적용 확인 (필요 시)
- [ ] 비동기 필요 작업의 블로킹 호출 없음

**V-4 Spec 정합성**
- [ ] requirements.md 모든 요구사항 항목 구현 확인
- [ ] Acceptance Criteria 충족
- [ ] design.md 인터페이스와 실제 구현 일치
- [ ] 엣지 케이스 커버

### 심각도 분류

| 심각도 | 정의 | 처리 |
|--------|------|------|
| **CRITICAL** | Constitution 위반, 보안 취약점, 데이터 유실, 핵심 미작동 | Phase 3 회귀 |
| **MAJOR** | 요구사항 미충족, 커버리지 미달, 아키텍처 위반, 성능 미달 | Teammate 위임 |
| **MINOR** | 코드 스타일, 네이밍, 문서 오타 | 일괄 처리 |

**Pessimistic Consolidation**: V-1~V-4 간 심각도 상충 시 최상위 등급 적용.
**Lead Override**: 오탐 판단 시 등급 하향 가능. 단, '등급 조정 사유(Overriding Rationale)' 필수 추가.

### verify-report.md 포맷

```markdown
# 검증 리포트: [기능/PR명]
**검증일**: YYYY-MM-DD | **검증 대상**: PR #[번호] — [제목]
**검증 관점**: V-1 정확성 / V-2 보안 / V-3 성능 / V-4 Spec 정합성

## 이슈 요약
| 이슈 # | 심각도 | 관점 | 위치 | 한 줄 설명 |
**집계**: CRITICAL N건 / MAJOR N건 / MINOR N건

## Phase Gate 판정
- [ ] CRITICAL 0건 → Phase 5 진입 가능 (Epic)
- [ ] CRITICAL + MAJOR 0건 → PR Merge 가능 (Feature)
**판정**: ✅ 통과 / ❌ 차단 — [이유]

## 이슈 상세
### 이슈 #N
- **심각도**: CRITICAL | MAJOR | MINOR | **관점**: V-N
- **위치**: `파일:라인` | **내용**: [설명] | **제안**: [수정 방향]

## Spec↔Code 동기화 확인
- [ ] 구현이 design.md 인터페이스 정의와 일치
- [ ] 새 함수/클래스/API가 design.md에 반영
- [ ] 모든 EARS 요구사항이 구현과 1:1 추적 가능
```

### P4 프롬프트 템플릿

**4-1. 교차 검증**
```
역할: Phase 4(VERIFY) [V-1 정확성 | V-2 보안 | V-3 성능 | V-4 Spec 정합성] Agent
검증 대상: [PR diff / 변경 파일 목록]
주입: @CLAUDE.md, @requirements.md, @design.md

위 다관점 검증 체크리스트의 해당 관점 항목을 검증.
이슈 보고 형식: 이슈 #N — 심각도: [등급] / 위치: [파일:라인] / 내용: [설명] / 제안: [수정안]
```

**4-2. verify-report 작성 (Lead)**
```
역할: Phase 4(VERIFY) Lead Agent
작업: 4-1 검증 결과를 위 포맷으로 docs/verify-report-YYYYMMDD.md 작성.
심각도 상충 시 Pessimistic Consolidation 적용.
```

---

## P5 REFINE

### 심각도별 수정 라우팅

```
역할: Phase 5(REFINE) Lead Agent
주입: Phase 4 검증 리포트 이슈 목록

MAJOR: Dev Teammate에게 수정 위임 → 수정 후 Phase 4 해당 항목 재검증
MINOR: 동일 파일 일괄 처리 → lint/format 자동 실행
Spec↔Code: Code MUST be corrected to match Spec. Spec MUST NOT be downgraded to match code.

MUST run full test suite after all MAJOR fixes.
```

### Spec↔Code Drift Protocol

**원칙**: Code MUST be corrected to match Spec. Correcting Spec to match code (Spec regression) is NEVER allowed.

**감지**: `git diff HEAD -- docs/design.md docs/requirements.md`

**처리**:
- CRITICAL drift (인터페이스 파괴) → Phase 2 재시작 (Human 개입)
- 의도적 설계 변경 → Phase 5에서 요구사항 변경 절차 후 Spec 갱신

### Phase 4→5/완료 조건

| 트랙 | 완료 조건 |
|------|----------|
| **Hotfix** | ALL tests MUST pass + Lint/Type check MUST pass |
| **Feature** | 검증 리포트 완성 + CRITICAL 0건 + PR Human Approve |
| **Epic P4→5** | 검증 리포트 + CRITICAL 0건 + Spec↔Code 검증 |
| **Epic P5→완료** | ALL CRITICAL/MAJOR MUST be resolved + Spec synchronized + Human approved |
