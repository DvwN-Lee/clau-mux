# Agent Teams Lifecycle 상세

## 세션 재개 프로토콜

Agent Teams는 세션 재개 시 Teammate 인스턴스가 복원되지 않는다.
아래 프로토콜로 checkpoint 기반 정밀 복원을 수행한다.

```
[재개 0] 복원 소스 결정:
         .claude/saga/checkpoints/ 최근 파일 존재?
           ├─ mid-phase checkpoint (48시간 이내) → 정밀 복원
           ├─ gate checkpoint (영구) → Gate 시점 기반 복원
           └─ checkpoint 없음 → Phase 0 폴백
[재개 1] checkpoint git_sha vs 현재 HEAD 비교
         ├─ 일치 → 진행
         └─ 불일치 → git diff 확인, 검증 담당 Teammate에게 검토 DISPATCH
[재개 2] TeamCreate (동일 team_name 또는 신규)
[재개 3] Teammate 전원 재spawn — 각 프롬프트에 주입:
         (a) checkpoint 전문 (mid-phase 또는 gate)
         (b) 마지막 TaskID + status
         (c) 미해소 VETO 요약 (있는 경우)
         (d) dispatch-log의 in-flight 항목
[재개 4] in-flight 항목 처리:
         ├─ status: done → 스킵
         ├─ status: partial → resume_from 기반 재진입
         ├─ status: in_progress → 재DISPATCH (중복 실행보다 정합성 우선)
         └─ status: blocked → 에스컬레이션 재판단
[재개 5] 중단 시점부터 Phase 재개
[재개 6] 복원 실패 시 → Session Restoration Breaker 적용
         (clmux-recovery §Session Restoration Breaker 참조)
```

### 자동 복원 금지 케이스

아래 조건에서는 자동 복원을 시도하지 않고 Human 에스컬레이션한다:
- VETO 교착 중 중단 (Phase A Round 3 이상 도달)
- Phase Gate 상태 ambiguous (Gate commit 완료 + gate checkpoint 미생성)
- Worktree 복수 고아 + 테스트 불일치
- 중단 시점 불명 (checkpoint 없음 + git commit만 존재)
- 48시간 이상 경과 후 재개

## Compaction 대응 프로토콜

Context compaction 시 Lead의 컨텍스트가 압축되어 Teammate 인식이 소실되는 알려진 문제가 있다 ([anthropics/claude-code#23620](https://github.com/anthropics/claude-code/issues/23620)).

### 팀 상태 파일

MUST update `.claude/saga/team-state.md` on any team composition change.

```markdown
---
team: clmux-{project}
phase: P3
updated: 2026-03-26T12:00:00
---
| Name | Model | Role | Status |
|------|-------|------|--------|
| design-gemini-pro | $CLMUX_GEMINI_MODEL_PRO | 설계+challenger | active |
| boilerplate-codex | gpt-5.4 | 구현+critic | busy:TASK-012 |
```

> **Anthropic teammate 금지**: Teammate(`TeamCreate` 멤버)는 비-Claude provider만(Gemini/Codex/Copilot). Lead와 Subagent에서만 anthropic 사용.

**갱신 시점**: TeamCreate / Teammate spawn·제거 / Phase 전환 / DISPATCH·COMPLETION

### 방어 계층

| 계층 | 매체 | 메커니즘 |
|------|------|---------|
| **1차** | 프로젝트 CLAUDE.md | PreCompact hook이 `team-state.md` → `## clmux Team State` 섹션 동기화 |
| **2차** | UserPromptSubmit hook | 매 턴 `systemMessage`로 팀 상태 요약 주입 |
| **3차** | Plan/Todo | Phase 진입 시 Plan에 팀 구성 기록 |

### Lead 복원 행동 규칙

```
[1] CLAUDE.md의 `## clmux Team State` 섹션 확인
[2] team-state.md 읽기 → 팀 구성 + 현재 Phase 파악
[3] SendMessage(to="*", content="ping: compaction 후 상태 확인")
[4] 응답 있는 Teammate → 정상 운용 재개
[5] 응답 없는 Teammate → 세션 재개 프로토콜 [재개 3] 기반 재spawn
```

> **NEVER**: MUST NOT call a new `TeamCreate` after compaction without first verifying team existence.

## TeammateIdle Hook 경고

**TeammateIdle Hook은 소프트 게이트다.** exit 2 피드백은 전달되지만 강제 차단 불가.
모든 Teammate spawn 시 프롬프트에 아래 문구 명시:

> "TeammateIdle 훅 피드백 수신 시 MUST follow the instruction. Ignoring → Lead forced shutdown."

Teammate가 3회 연속 응답 없으면 Agent Teams Fallback 조건 적용.

## Agent Teams Fallback

발동 조건:
- Agent Teams 기능 불안정 (spawn 오류 2회 연속)
- Teammate 응답 없음 (TeammateIdle 3회 연속)
- 세션당 1 Team 제약으로 운용 불가

**절차**:
1. `git commit` + gate checkpoint 생성
2. Subagent 전환: Teammate role prompt를 인라인 주입
3. gate checkpoint 컨텍스트 포함하여 중단 시점부터 재개
4. VETO 대체: Lead가 직접 다관점 검토

> **Fallback ≠ 팀 해체**: mode switch. 조건 해소 시 Agent Teams 재구성.
