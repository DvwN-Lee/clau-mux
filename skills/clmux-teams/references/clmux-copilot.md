# Copilot Teammate (clmux-copilot)

## 역할 특성

Copilot 은 **플랫폼 통합 워크플로** 3축에서 다른 provider 로 대체 불가한 고유 이점을 보유한다.

### 축 1: Security Loop — CodeQL + Autofix

GitHub 네이티브 폐회로 (탐지 → AI 수정 → PR 머지) 가 동일 플랫폼 안에서 실행되는 **유일 provider**.

- **2025 연간 460,258 alert 자동 수정** (primary: GitHub Blog, 2026-03-23)[^axis1-autofix]
- **Time-to-fix 1.29h → 0.66h (−49%)**
- **취약점의 50% 를 PR 단계에서 직접 해결** (개발자 컨텍스트 내부 remediation)
- 2026-03 확장: Shell/Bash, Dockerfile, Terraform/HCL, PHP — static analysis 취약 영역을 AI detection 으로 커버

> **유의**: false-positive rate / precision-recall 미공개. "80% positive feedback" 은 개발자 thumbs-up 이며 precision 지표 아님.

### 축 2: PR Review at Platform Scale

GitHub PR UI 에 1급 리뷰어로 native 임베드된 유일 provider. Cross-Provider 판정 테이블의 "PR ops = Copilot" 근거.

- **2025-04~2026-03 기간 60M 리뷰 처리** (11개월 10x 성장, primary: GitHub Blog 2026-03-05)[^axis2-reviews]
- **전체 GitHub PR 의 >20%** 에 Copilot 관여
- **71% actionable / 29% silent** (품질 signal — 불필요한 noise 를 억제)
- 평균 **5.1 comments/review**
- **12,000+ org 자동 리뷰 활성**
- Reasoning model 업그레이드로 **+6% positive feedback** (latency +16% 수용)

**피어-리뷰 검증된 코드 품질 효과** (blind peer review, n=243)[^axis2-quality]:
- Copilot 코드의 unit test 전체 통과 확률 **+53.2%** (p<0.01)
- 리뷰어 승인률 **+5%** (p=0.014)
- Readability +3.62%, reliability +2.94%, maintainability +2.47%, conciseness +4.16% (모두 통계적 유의)

### 축 3: Enterprise Compliance

Codex CLI / Claude Code / Gemini CLI 에 현재 동등물이 **없는** 규정 준수 스택.

- **US / EU data residency GA 2026-04-13** (모든 inference 지정 지역 내부 유지). Japan / AU 로드맵 late 2026[^axis3-residency]
- **FedRAMP Moderate** 동시 GA (2026-04 롤아웃)
- **SAML SSO + SCIM** identity field 가 audit log 에 기록 (GA 2024-03)
- **Audit log 180일 보관, SIEM streaming 지원** — 정책 변경 / seat 할당 / agent 활동 로깅. 단 **클라이언트-side prompt 는 미로깅**
- **Content exclusion**: repo/file 레벨 rule → completion + chat + review 3경로 동시 차단
- **Business ($19/seat) vs Enterprise ($39/seat) 델타**: Knowledge bases (org codebase indexing), 커스텀 fine-tuned inline model, github.com chat, premium request **300 → 1,000 / seat / month**

> **유의**: Customer-Managed Keys (CMK) 는 Microsoft Copilot Studio 에만 확증, GitHub Copilot inference 는 **공식 문서 확증 없음**. PrivateLink / VPC peering 도 Copilot inference 엔드포인트에 대해 미확증. IP allowlist 는 존재.

### 기저 모델 (2026-04-21 기준)

Copilot CLI 는 기본 **GPT-5.3-Codex** (2026-02-05 출시) 로 라우팅. OpenAI 공식 벤치마크[^model-codex]:

| 벤치마크 | GPT-5.3-Codex | vs 5.2-Codex |
|---|---|---|
| Terminal-Bench 2.0 | **77.3%** | +13.3pp |
| OSWorld-Verified | **64.7%** | +26.5pp |
| SWE-Bench Pro | **56.8%** | +0.4pp |
| Cybersecurity CTF | **77.6%** | +10.2pp |
| SWE-Lancer IC Diamond | **81.4%** | +5.4pp |

> OpenAI 는 SWE-Bench Verified / HumanEval / LiveCodeBench 를 이번 launch 에 미공개 (HumanEval 은 ≥95% 포화로 non-differentiating).

Copilot Agent Mode (Workspace) 는 Claude 3.7 Sonnet 기반 **SWE-Bench Verified 56.0%** (GitHub 공식 blog 주장, swebench.com 리더보드 제출 없음 — **blog claim only**)[^model-agent].

### 라우팅 모델 정책

> **본 팀은 Copilot CLI 기본 모델 (GPT-5.3-Codex) 만 사용한다. 다른 모델로의 라우팅은 허용하지 않는다.**

**이유**:
- Cross-Provider 매트릭스는 **Copilot = GitHub-native / GPT-5.3-Codex** 1:1 매핑으로 설계됨
- Claude Sonnet / Opus 를 Copilot 경유로 쓰면 `anthropic` provider_family 와 중첩되어 **Rule 3 독립 지지 산정이 오염** (동일 모델군이 두 provider 로 이중 등장)
- GPT-5.4 는 `openai` family 내에서 Codex CLI 전용 — Copilot 이 또 GPT-5.4 를 쓰면 `openai` 내 중복

**참고** — Copilot 플랫폼이 라우팅 가능한 모델 목록 (본 팀 **사용 금지**):
- ✅ GPT-5.3-Codex (기본, **본 팀 사용**)
- ❌ GPT-5.4 (Codex CLI 경유로만)
- ❌ Claude Sonnet 4.6 (native Claude teammate 경유로만)
- ❌ Claude Opus 4.6 (Lead 경유로만)

**운용 제약**:
- `clmux-copilot -t <team>` 만 사용, **`-m` 옵션 지정 금지**
- Data-resident endpoint (US/EU) 선택 시에도 기본 모델 유지

### 비용

- **Copilot Pro**: $10 / **Pro+**: $39 / **Business**: $19 per seat / **Enterprise**: $39 per seat
- Premium Request 기반 (Business 300 / Enterprise 1,000 per seat·month)
- **Data-resident endpoint 사용 시 premium request 10% 할증**
- FY26 Q2 (2026-01 기준) 유료 가입자 ~4.7M, YoY +75%

### 적합 영역

- PR Review 및 GitHub 네이티브 워크플로 (Issue → PR → Merge 파이프라인)
- 취약점 탐지 후 자동 수정 (CodeQL Autofix 폐회로)
- 배포 후 Smoke Test + Changelog 생성
- 규정 준수가 엄격한 엔터프라이즈 (FedRAMP / data residency 필수)

[^axis1-autofix]: GitHub Blog "GitHub expands application security coverage with AI-powered detections" (2026-03-23). 460,258 = 2025 전체 연도 GitHub 자체 집계.
[^axis2-reviews]: GitHub Blog "60 million Copilot code reviews and counting" (2026-03-05). 기간 2025-04 출시 ~ 2026-03.
[^axis2-quality]: GitHub Blog "Does GitHub Copilot improve code quality? Here's what the data says" (Nov 2024, updated Feb 2025). n=243 Python 개발자 (≥5yrs), 25 senior 리뷰어의 1,293 blind peer review. GitHub 후원 외부 수행.
[^axis3-residency]: GitHub Changelog "Copilot data residency in US/EU and FedRAMP compliance now available" (2026-04-13).
[^model-codex]: OpenAI "Introducing GPT-5.3-Codex" (2026-02-05).
[^model-agent]: GitHub Blog "GitHub Copilot agent mode activated" (2025-04, updated 2026-04). 메서드 disclosure 없음, swebench.com 리더보드 엔트리 없음.

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
- **모델**: `GPT-5.3-Codex` (Copilot CLI 기본, 본 팀 정책상 **고정** — `-m` 지정 금지. 상세: §라우팅 모델 정책)
- **MCP 서버**: HTTP/SSE 모드 — `bridge-mcp-server.js --http <port>` + `~/.copilot/mcp-config.json` 등록
- **Env file**: Copilot이 MCP subprocess에서 env를 클리어하므로 `.bridge-copilot-worker.env` 작성

> Spawn/Stop/에러 대응 공통 절차는 [SKILL.md §8](../SKILL.md#8-bridge-공통-사항) 참조.
