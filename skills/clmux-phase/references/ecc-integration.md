# ECC 스킬 통합 참조

> ECC(Enterprise Claude Code) 환경에서 clmux 팀 운용을 강화하는 스킬 목록.

## HIGH 우선순위 — 즉시 도입 권장

| ID | ECC 스킬 | clmux 적용 시점 |
|----|----------|--------------|
| CG-01 | `autonomous-loops` | P3 BUILD Wave 자동화, 반복 TDAID 루프 관리 |
| CG-02 | `ralphinho-rfc-pipeline` | Epic Track P1→P2 요구사항 → 설계 전환 자동화 |
| CG-03 | `team-builder` | Phase 시작 시 Teammate spawn 자동화 |
| CG-04 | `continuous-agent-loop` | Wave 루프 / VETO 루프 연속 실행 유지 |
| CG-05 | `orchestrate` | Lead → Teammate DISPATCH 흐름 조율 |
| CG-06 | `multi-execute` / `multi-workflow` | Worktree 병렬 빌드 (≤8 동시 Subagent) |
| CG-07 | `agent-harness-construction` | clmux 팀 초기화 + 역할 브리핑 자동화 |
| CG-08 | `harness-optimizer` | clmux 멀티에이전트 운영 비용 최적화 |

## MEDIUM 우선순위 — 프로젝트 규모에 따라 선택

| ID | ECC 스킬 | clmux 적용 시점 |
|----|----------|--------------|
| CG-09 | `loop-operator` | clmux 세션 복구 자동화, 스톨 감지 |
| CG-10 | `eval-harness` | P4 VERIFY 자동화, V-1~V-4 병렬 평가 |
| CG-11 | `enterprise-agent-ops` | 대규모 프로젝트 팀 모니터링 + 비용 관리 |
| CG-12 | `strategic-compact` | Epic Track 장기 Phase 전략 압축 실행 |
| CG-13 | `agentic-engineering` | clmux 팀 구조 자체를 코드로 정의 |
| CG-14 | `devfleet` | 구현 Teammate 내부 Subagent 플릿 관리 |
| CG-15 | Stop hooks | 세션 기억 아키텍처, 비용 메트릭 추적 |

## 스킬 선택 결정 트리

```
프로젝트 트랙 결정
├── Hotfix → ECC 스킬 불필요
├── Feature → HIGH 중 3개 이상 선택
│   권장: autonomous-loops + orchestrate + multi-execute
└── Epic → HIGH 전체 + MEDIUM 선택
    필수: team-builder + agent-harness-construction + harness-optimizer
```

## findings.md 최소 포맷

```markdown
# findings: [팀명 / 검증 관점]

**생성일**: YYYY-MM-DD
**팀**: [Team명]

## 결론 (Conclusions)
- [핵심 발견 사항 요약]

## 근거 (Evidence)
| 항목 | 위치 | 내용 |
|------|------|------|
| E-1  | [파일:라인] | [설명] |

## 권장 조치
- [CRITICAL/MAJOR/MINOR]: [권장 사항]
```
