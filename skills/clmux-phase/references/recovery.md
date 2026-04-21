# clmux 실패 대응 지침

**MUST preserve current state via `git commit` before any automated interruption.**

| 상황 | 조치 |
|------|------|
| 동일 패턴 오류 2회 연속 | MUST retry with a different prompt/approach |
| Circuit Breaker OPEN | MUST `git commit` → spawn new Subagent with higher-tier model → MUST escalate to Human if unresolved |
| Phase Gate 체크리스트 미충족 | MUST auto-retry once → MUST roll back to previous Phase + notify Human on failure |
| `status="failed"` 응답 | MUST spot-check (output file exists + `git log`) before re-judging success |

## Circuit Breaker

**발동 조건:** 동일 Subagent에서 연속 3회 테스트 실패 코드 생성 또는 TDD cycle 3회 비수렴.

**모델 교체 매트릭스** (상위 모델로 새 Subagent spawn — Claude 자신의 모델 교체 불가):

| 현재 Subagent 모델 | 교체 대상 | 미해소 시 |
|-------------------|-----------|---------|
| Haiku | → Sonnet | → Opus |
| Sonnet | → Opus | → Human 에스컬레이션 |
| Opus | → Human 에스컬레이션 | — |

## Human 에스컬레이션 포맷

```
## 실패 요약
### 시도한 접근
### 실패 원인
### 선택지
```

## Session Restoration Breaker

세션 재개 시 checkpoint 기반 복원이 실패하는 경우의 에스컬레이션 패턴.
Circuit Breaker의 세션 복원 확장이다.

| 시도 | 조치 |
|------|------|
| 1회 복원 실패 | MUST roll back to previous checkpoint and retry (fall back to gate checkpoint if none exists) |
| 2회 복원 실패 | MUST escalate to Human — MUST NOT attempt further restoration; report current state |

**복원 실패 판정 기준**:
- 재spawn된 Teammate가 checkpoint 컨텍스트와 현재 파일 상태 간 불일치를 보고
- dispatch-log의 in-flight task 재DISPATCH 후 2건 이상 연속 실패
- Worktree 고아 정리 후 테스트 suite 실패

**Human 에스컬레이션 포맷**:
```
## 세션 복원 실패
### 중단 시점: [Phase, 작업 내용]
### 복원 시도: [1회/2회 시도 내용 및 실패 사유]
### 보존된 상태: [git commit SHA, checkpoint 파일 경로]
### 선택지:
- A: 마지막 Phase Gate부터 재시작
- B: 특정 checkpoint부터 수동 복원
- C: Phase 0부터 전체 재시작
```
