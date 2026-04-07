# R5 — Synthesis: 기존 결정 보완 + 새로운 contested 영역 + spec 업데이트 권고

**담당**: Claude teammate (또는 Lead가 직접 작성) — R1~R4 완료 후
**상태**: blocked by R1, R2, R3, R4
**입력**: 01-existing-tools-survey.md, 02-cdp-technical-deep-dive.md, 03-github-ecosystem-survey.md, 04-source-remapping-and-prompts.md
**산출 위치**: 이 파일 + spec 업데이트

## Scope

R1~R4의 발견을 종합해 다음을 결정한다:

1. brainstorming 12 결정사항 중 변경·보강이 필요한 것
2. 새로 발견된 contested 영역 (brainstorming에서 누락)
3. 기존 OSS에서 차용 가능한 모듈/패턴 목록
4. spec 문서에 박아야 할 최종 결정·근거

## Output 형식

### 1. 기존 12 결정 review 종합

| # | 결정 | R1 의견 | R2 의견 | R3 의견 | R4 의견 | 종합 권고 | 상태 |
|---|---|---|---|---|---|---|---|
| 1 | 산출물 | | | | | | confirmed |
| 2 | Lead-hosted background | | | | | | ? |
| 3 | NOT MCP | | | | | | ? |
| 4 | Tool 역할 (브리지) | | | | | | ? |
| 5 | 4-section payload | | | | | | ? |
| 6 | 소스 기반 분석 | | | | | | ? |
| 7 | -b 플래그 | | | | | | ? |
| 8 | background daemon | | | | | | ? |
| 9 | 파일 기반 구독 | | | | | | ? |
| 10 | 5-stage flow | | | | | | ? |
| 11 | research focus | | | | | | ? |
| 12 | research 팀 | | | | | | confirmed |

### 2. 새로 발견된 contested 영역

```markdown
## NEW-1: <영역 이름>
- 발견 출처: R<n>
- 문제:
- 옵션 A:
- 옵션 B:
- 권고:
```

### 3. 차용 가능한 OSS 모듈 목록

```markdown
| 모듈 | 출처 | 라이선스 | 우리 통합 위치 | 통합 비용 |
|---|---|---|---|---|
| ... | ... | ... | ... | ... |
```

### 4. spec 문서 업데이트 권고

```markdown
## Spec 업데이트 항목

### 추가해야 할 섹션
- ...

### 수정해야 할 결정
- #<n>: 현재 → 변경안 → 근거

### 명시해야 할 위험
- ...
```

### 5. 미해결 (post-spec, 구현 단계로 미루기) 영역

설계 단계에서 결정 불필요, 구현 단계에서 다룰 것.

```markdown
- [ ] ...
- [ ] ...
```

## 완료 조건

- R1~R4 모두 완료 후 시작
- 위 5 섹션 모두 작성
- spec 문서(`docs/superpowers/specs/2026-04-07-browser-inspect-tool-design.md`) 업데이트 PR-ready
- Lead에게 최종 보고
