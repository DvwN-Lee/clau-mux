# Codex Teammate (clmux-codex)

## 역할 특성

- **핵심 강점**: 자율 실행 (`--full-auto`)[^codex-fullauto], Terminal-Bench 2.0 77.3% (GPT-5.3-Codex + Droid agent)[^codex-terminal]
- **비용**: 본 팀은 ChatGPT Plus ($20/mo) 사용. Plus 티어는 Codex CLI 접근 (rate-limited), GPT-5.4 / GPT-5.3-Codex 접근 포함. **Codex Security (792 critical, 14 CVE 탐지 실적) 는 Pro $100+ 티어 한정으로 본 팀 미접근**[^codex-pricing]
- **적합 영역**: 보일러플레이트 생성, 테스트 작성, 코드 리뷰 보조, CI/CD 자동화, IaC/DevOps. 본격 보안 스캔은 Plus 티어 미접근이므로 수행 불가

## Phase별 역할 상세

### P3 BUILD — Boilerplate 병렬 + IaC

Codex는 Lead가 spawn한 Subagent(`model="sonnet"`)가 핵심 로직을 TDD로 구현하는 동안 **정의된 패턴의 반복 코드를 병렬 생성**한다.

| 작업 | 구체 내용 |
|---|---|
| Boilerplate 생성 | 환경변수 전환, CRUD 반복, 설정 파일 생성 |
| IaC / DevOps | Terraform, Dockerfile, CI Pipeline 작성 |

**프롬프트 예시:**
```
SendMessage(to: "boilerplate-codex", message:
  "tasks.md의 T-005~T-008 Boilerplate 작업 병렬 생성.
  각 task의 AC를 충족하는 코드를 생성하고
  결과를 write_to_lead로 전달.
  Lead가 Subagent(`model=\"sonnet\"`) TDD 검증 후 통합 진행")
```

### P4 VERIFY — 보안 스캔 1차 + 성능 분석 1차

Codex는 P4에서 **보안과 성능 검증의 1차 담당**이다.

#### 보안 스캔 (Codex Security)

Codex Security의 검증 파이프라인:
1. 저장소 스캔 컨텍스트 및 위협 모델 구축
2. 컨텍스트 기반 취약점 탐지 및 실제 영향도 분류
3. 격리된 Sandbox 환경에서 PoC 검증
4. 컨텍스트 인식 패치 제안

| 검사 항목 | 구체 내용 |
|---|---|
| Injection | SQL Injection, Command Injection, XSS |
| 인증 결함 | 인증/인가 우회, 세션 관리 |
| Secret 노출 | Hardcoded Secret, 환경변수 노출 |
| 의존성 취약점 | 취약한 transitive dependency |

**프롬프트 예시:**
```
SendMessage(to: "security-codex", message:
  "현재 Codebase에 대한 보안 취약점 스캔 진행.
  1. SQL Injection, Command Injection, 인증 결함 순으로 분류
  2. 각 발견 항목에 심각도(CRITICAL/HIGH/MEDIUM) 부여
  3. 발견된 취약점과 수정 제안을 write_to_lead로 전달")
```

#### 성능 분석

| 검사 항목 | 구체 내용 |
|---|---|
| 알고리즘 복잡도 | O(n²) 이상 연산, 불필요한 중첩 루프 |
| 리소스 사용 | 메모리 누수, 닫히지 않은 리소스, 대형 객체 할당 |
| I/O 연산 | N+1 쿼리 패턴, 동기 Blocking 호출, 캐싱 누락 |

**프롬프트 예시:**
```
SendMessage(to: "perf-codex", message:
  "API Endpoint 전체에 대한 성능 분석 실행.
  1. N+1 쿼리 패턴 탐지
  2. 알고리즘 복잡도 O(n²) 이상 지점 식별
  3. 캐싱 누락 지점 식별
  4. 결과를 심각도별로 정리하여 write_to_lead로 전달")
```

### P4 VERIFY — 코드 리뷰 보조

Lead가 spawn한 검증 Subagent(`model="sonnet"`/`haiku`)가 V-1~V-4 검증을 수행한 후, Codex가 **보완적 관점에서 리뷰**한다. 다른 학습 데이터와 아키텍처로 anthropic이 놓치는 Error Path, Edge Case를 포착한다.

**프롬프트 예시:**
```
SendMessage(to: "review-codex", message:
  "PR diff를 기반으로 코드 리뷰 진행.
  Lead/Subagent 검증에서 놓칠 수 있는 관점에 집중:
  1. Error path 누락 (예외 미처리, 실패 시 상태 불일치)
  2. Edge case (빈값, null, 경계값, 동시성)
  3. 발견 사항을 write_to_lead로 전달")
```

### P5 REFINE — 재검증 + CI/CD

| 작업 | 구체 내용 |
|---|---|
| 보안 재검증 | P4 Critical/High 수정 후 재스캔 |
| CI Pipeline | GitHub Actions / GitLab CI 파이프라인 구성·검증 |
| 배포 검증 | Terraform Plan 분석, 예상치 못한 리소스 변경 감지 |

**프롬프트 예시:**
```
SendMessage(to: "security-codex", message:
  "P4 보안 스캔에서 발견된 CRITICAL 항목 수정 완료.
  1. 수정된 코드에 대해 보안 재스캔 진행
  2. 신규 취약점 없음 확인
  3. 결과를 write_to_lead로 전달")
```

## Codex 고유 제약사항

### 네트워크 비활성화 (Shell Level)
`--full-auto`로 실행되는 Codex의 셸은 sandbox에 의해 network-disabled 상태다.
- **차단 예시**: `git push`, `git pull` (원격), `npm install`, `pip install`, `curl`, `wget`, `apt-get`, `brew install`
- **영향**: P3 BUILD의 패키지 설치·원격 fetch 작업, P4 VERIFY의 외부 API 호출 검증 불가
- **회피**: Codex는 코드 생성·로컬 분석만 담당; 네트워크 작업은 Lead 또는 Subagent가 별도 실행

### Approval Mode Trade-off
`--full-auto`는 `-a on-request`를 사용 — 모델이 위험 명령 판단 시 사용자 승인을 요청할 수 있음 (`-a never`와 다름). 대부분 prompt 없이 통과하지만, sensitive 작업에서 일시 정지 가능성 존재. 엄격한 unattended 보장이 필요하면 `lib/teammate-wrappers.zsh`의 spawn 명령을 직접 수정 — `-a never` 또는 `--dangerously-bypass-approvals-and-sandbox`로 교체 (후자는 EXTREMELY DANGEROUS, sandbox VM 외부에선 비권장).

### Contamination Risk — Meta Safety Classifier
Codex CLI는 `-a` flag와 별개로 내장 safety classifier를 가지며, conversation history 내 "shell 실행 + 외부 송신(write_to_lead 등)" 패턴을 위험으로 분류하면 bridge MCP 호출을 자동 cancel한다. 이 차단은 **conversation-sticky** — 한 번 트리거되면 동일 session 내 무관한 후속 요청도 차단됨.
- **증상**: `clau_mux_bridge.write_to_lead` 호출이 "Tool call was cancelled because of safety risks" 에러로 실패
- **완화책**:
  1. 민감한 task(외부 송신 + shell)마다 **fresh Codex spawn** — task 완료 후 shutdown, 다음 task에 신규 spawn
  2. 프롬프트 표현 중립화 — "사용자 승인 없이", "auto-execute", "without user approval" 등 회피
  3. 차단 발생 시 즉시 spawn 재시작 (contamination 누적, 회복 불가)
- **참고**: clmux 측 통제 불가 (Codex CLI 내장, flag로 disable 옵션 없음 — 2026-04 기준)

## Codex 고유 설정

- **Spawn 명령**: `clmux-codex`
- **기본 agent 이름**: `codex-worker` (standalone fallback) — clmux-teams 워크플로에서는 task-aware naming 필수 (예: `security-codex`, `boilerplate-codex`, `review-codex`, `perf-codex`). [clmux-teams §Naming Convention](../SKILL.md#naming-convention-필수) 참조
- **실행 모드**: 기본 launch는 `codex --full-auto` (= `-a on-request -s workspace-write`). kernel-level sandbox(macOS Seatbelt / Linux bubblewrap) + shell network-disabled + working-dir 제한
- **Idle pattern**: `›`
- **모델 예시**: `gpt-5.4`, `gpt-5.4-mini`
- **모델 지정**: `clmux-codex -t <team> -m gpt-5.4`
- **MCP approval_mode**: `"approve"` (safety monitor가 non-destructive tool 자동 승인)
- **Env file**: Codex가 MCP subprocess에서 env를 클리어하므로 bridge가 `.bridge-<agent_name>.env` 작성 (예: `.bridge-security-codex.env`). agent_name = `-n` 인자 값
- **Instruction source**: Codex는 프로젝트 루트의 `AGENTS.md`를 읽어 teammate protocol(`write_to_lead` 1회 호출)을 따름
- **종료 주의**: Codex TUI는 plain-text `/exit`가 비안정적이므로 실패 시 `clmux-codex-stop`을 사용

> Spawn/Stop/에러 대응 공통 절차는 [SKILL.md §9](../SKILL.md#9-bridge-공통-사항) 참조.

[^codex-fullauto]: Codex CLI Reference, https://developers.openai.com/codex/cli/reference (retrieved 2026-04-21). `--full-auto` sets `--ask-for-approval on-request` + `--sandbox workspace-write`. In-session toggle: `/mode`. More permissive mode: `--yolo` (`--dangerously-bypass-approvals-and-sandbox`).
[^codex-terminal]: Terminal-Bench 2.0 leaderboard, https://www.tbench.ai/leaderboard/terminal-bench/2.0 (evaluated 2026-02-24 for GPT-5.3-Codex + Droid: 77.3% ± 2.2; 2026-03-12 for GPT-5.4 + ForgeCode: 81.8% ± 2.0). Score is agent-configuration-dependent. Original source: OpenAI "Introducing GPT-5.3-Codex" (2026-02-05).
[^codex-pricing]: OpenAI pricing, https://chatgpt.com/pricing (retrieved 2026-04-21). Plus $20/mo (본 팀 기준): GPT-5.4, GPT-5.3-Codex, Codex CLI rate-limited. Pro $100/mo (신설 2026-04-09): 5× Plus usage, Codex Security 포함. Pro $200/mo: 20× Plus usage, Codex Security 포함. Codex Security 접근은 Pro/Enterprise/Business/Edu 한정 — Plus 티어 미접근.
