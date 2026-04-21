# Copilot Teammate (clmux-copilot)

## 역할 특성

- **핵심 강점**: GitHub 네이티브 통합 (PR, Issue, Review, 60M+ 리뷰 처리), Enterprise Governance
- **비용**: $10~$39/월 정액 (Premium Request 기반)
- **적합 영역**: PR 리뷰, Issue→PR 파이프라인, 배포 후 Smoke Test, Changelog 생성

## Phase별 역할 상세

### P3 BUILD — PR Code Review

Copilot은 P3에서 Claude teammate가 생성한 코드의 **PR 기반 리뷰**를 담당한다. GitHub 네이티브 통합으로 PR 코멘트, 리뷰 요청, 자동 라벨링을 처리한다.

**프롬프트 예시:**
```
SendMessage(to: "copilot-worker", message:
  "PR #[번호]에 대한 코드 리뷰 진행.
  1. 변경 파일별 리뷰 코멘트 작성
  2. Approve/Request Changes 판정
  3. 리뷰 결과를 write_to_lead로 전달")
```

### P4 VERIFY — PR 기반 검증 보조

Claude teammate의 V-1~V-4 검증 완료 후, Copilot이 PR 레벨에서 추가 검증을 수행한다.

**프롬프트 예시:**
```
SendMessage(to: "copilot-worker", message:
  "PR #[번호]의 검증 결과를 GitHub PR 코멘트로 정리.
  1. verify-report.md의 이슈 목록을 PR 코멘트로 변환
  2. CRITICAL 항목은 Request Changes로 표시
  3. 결과를 write_to_lead로 전달")
```

### P5 REFINE — PR 생성 + 배포 + Smoke Test

Copilot은 P5에서 **PR 생성부터 배포 검증까지** GitHub 워크플로 전체를 담당한다.

| 작업 | 구체 내용 |
|---|---|
| PR 생성 | 변경 사항 요약, 리뷰어 지정, 라벨 설정 |
| Changelog | 변경 이력 정리, Release Notes 초안 |
| Smoke Test | 배포 후 Health Check + 핵심 Endpoint 검증 |
| 리뷰 대응 | PR 코멘트 대응, Merge 파이프라인 처리 |

**프롬프트 예시 (PR 생성):**
```
SendMessage(to: "copilot-worker", message:
  "현재 브랜치의 변경사항으로 PR 생성.
  1. 변경 파일 목록 + 핵심 변경 요약
  2. 리뷰어 지정: [reviewer]
  3. 결과를 write_to_lead로 전달")
```

**프롬프트 예시 (Smoke Test):**
```
SendMessage(to: "copilot-worker", message:
  "배포 후 Smoke Test 실행.
  1. Health Check Endpoint 응답 확인
  2. 핵심 기능 Endpoint 3개 정상 응답 확인
  3. 결과를 write_to_lead로 전달")
```

## Copilot 고유 설정

- **Spawn 명령**: `clmux-copilot`
- **기본 agent 이름**: `copilot-worker`
- **실행 모드**: `copilot --allow-all-tools`
- **Idle pattern**: `/ commands`
- **모델 예시**: `claude-sonnet-4`, `gpt-5`, `claude-opus-4.5`
- **모델 지정**: `clmux-copilot -t <team> -m claude-sonnet-4`
- **MCP 서버**: HTTP/SSE 모드 — `bridge-mcp-server.js --http <port>` + `~/.copilot/mcp-config.json` 등록
- **Env file**: Copilot이 MCP subprocess에서 env를 클리어하므로 `.bridge-copilot-worker.env` 작성

> Spawn/Stop/에러 대응 공통 절차는 [SKILL.md §8](../SKILL.md#8-bridge-공통-사항) 참조.
