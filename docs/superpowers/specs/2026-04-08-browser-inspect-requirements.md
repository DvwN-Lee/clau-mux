# Software Requirements Specification — Browser Inspect Tool (BIT)

---

## 1. 문서 정보

### 1.1 기본 정보

| 항목 | 값 |
|---|---|
| **문서 ID** | SRS-BIT-001 |
| **버전** | 0.1 |
| **작성일** | 2026-04-08 |
| **작성자** | clau-mux 설계팀 |
| **상태** | Draft → Review |
| **브랜치** | feat/browser-inspect-research |
| **Worktree** | .worktrees/feat-browser-inspect |

### 1.2 변경 이력

| 버전 | 날짜 | 작성자 | 변경 내용 |
|---|---|---|---|
| 0.1 | 2026-04-08 | clau-mux 설계팀 | 최초 작성 — brainstorming + R1~R5 synthesis 반영 |

### 1.3 관련 문서

| 문서 | 경로 | 비고 |
|---|---|---|
| Design Spec | `docs/superpowers/specs/2026-04-07-browser-inspect-tool-design.md` | 1차 참고 — 동기·제약·결정 포함 |
| Research Index | `docs/superpowers/research/00-INDEX.md` | brainstorming 확정 사항 + 연구 영역 |
| R5 Synthesis | `docs/superpowers/research/05-synthesis-and-design-updates.md` | 최종 결정 + payload 확장 + 위험 항목 |

### 1.4 독자

- **구현 개발자**: FR/NFR를 기준으로 구현 범위·우선순위 결정
- **Code Reviewer**: acceptance criteria로 PR 검증
- **Lead Claude Code**: 5-stage flow 실행 시 시스템 동작 기준 참조
- **사용자(Frontend 개발자)**: 워크플로와 기대 행동 이해

---

## 2. 목적 및 범위

### 2.1 시스템 목적

Browser Inspect Tool(BIT)은 clau-mux 기반 Claude Code frontend 개발 워크플로에서 사용자 의도와 실제 렌더 결과 간의 drift를 해소하기 위한 pointing bridge이다. 사용자가 브라우저에서 inspect mode로 요소를 클릭하면, 해당 요소의 DOM 정보·소스 위치·렌더 상태를 담은 구조화된 payload가 인계받은 teammate(또는 Lead)의 입력으로 자동 주입된다. 이를 통해 agent는 스크린샷 없이 소스 코드 Read + drift 분석만으로 코드 수정 방향을 결정할 수 있다.

### 2.2 범위 (In-Scope)

- `clmux -b` 플래그로 격리 Chrome 프로필 자동 launch 및 background daemon 기동
- CDP(Chrome DevTools Protocol) 기반 overlay 주입 + inspect mode toggle + click 캡처
- Multi-tier source remapping (React 18/19, Vue, Svelte, Solid) + confidence 표기
- Reality fingerprint payload 생성 (computed_style_subset, cascade_winner, bounding_box, a11y 등)
- `.inspect-subscriber` 파일 기반 구독 모델 + teammate inbox atomic append
- `clmux-inspect` CLI (subscribe / unsubscribe / query / snapshot / status)
- SPA navigation 시 overlay 자동 재주입 (History API hook + Page.frameNavigated)
- Shadow DOM / iframe pierce 처리 (MVP: same-origin)
- Lead 세션 수명 동조 background daemon 운영 + 자동 재시작

### 2.3 범위 외 (Out-of-Scope)

- MCP(Model Context Protocol) 통합 — 금지 (C2)
- 스크린샷·이미지 데이터 payload 포함 — 금지 (C3)
- Full-page visual regression — 별도 Playwright 트랙
- Production 빌드(minified, no source map) 환경 지원
- Cross-origin iframe 완전 지원 — post-MVP
- Windows / Linux 환경 지원
- 브라우저 확장(Extension) 기반 구현
- caller_chain 자동 수집 — post-MVP (MVP는 agent prompt 규약만, NEW-1)

### 2.4 향후 작업 (Post-MVP)

- `caller_chain` payload 자동 수집 — `_debugOwner` chain 최대 5단계 (NEW-1 보강)
- Cross-origin iframe 완전 지원
- MutationObserver 활성화 옵션 (SPA 프레임워크 종류별 런타임 선택)
- Vite/Webpack plugin 레이어 — React 19 Tier 2 remapping 자동화
- failure cap 동적 설정 (초기값 3회 → 사용자 구성 가능)

---

## 3. 정의 / 약어

| 용어 / 약어 | 정의 |
|---|---|
| **BIT** | Browser Inspect Tool — 본 SRS가 기술하는 시스템 |
| **CDP** | Chrome DevTools Protocol — Chrome 원격 제어 프로토콜 (WebSocket 기반) |
| **SPA** | Single-Page Application — client-side routing을 사용하는 웹 앱 |
| **fingerprint** | reality_fingerprint — 브라우저 런타임에서 수집한 요소 렌더 상태 스냅샷 |
| **subscriber** | `.inspect-subscriber` 파일에 등록된 현재 click 이벤트 수신 agent |
| **inbox** | `~/.claude/teams/$team/inboxes/{agent}.json` — teammate 수신 메시지 큐 파일 |
| **payload** | BIT가 생성·주입하는 JSON 데이터 (user_intent / pointing / source_location / reality_fingerprint) |
| **drift** | 코드 의도와 브라우저 실제 렌더 결과 간의 불일치 |
| **intent** | 사용자가 inspect mode에서 입력한 자연어 코멘트 (`user_intent` 필드) |
| **tier** | source remapping 전략 계층 (T1: 런타임 hook, T2: build-time injection, T4: CSS sourcemap) |
| **daemon** | `browser-service` — Lead 세션 수명 동조로 운영되는 background Node.js 프로세스 |
| **CLI** | `clmux-inspect` — agent 및 사용자가 daemon과 통신하는 명령줄 인터페이스 |
| **cascade_winner** | CDP CSS.getMatchedStylesForNode로 추출한 최종 CSS 규칙 승자 (파일:라인 포함) |
| **confidence** | source remapping 신뢰도 (high / medium / low / none) |
| **teammate** | clau-mux에서 Lead Claude Code와 협력하는 AI agent (Gemini, Codex, Copilot, Sonnet 등) |
| **lead** | Lead Claude Code — 팀 전체 워크플로를 조율하는 주 agent |
| **bridge** | agentType이 "bridge"인 teammate (gemini-worker, codex-worker, copilot-worker 등) |
| **pane** | tmux 화면 분할 단위 — Lead pane, teammate pane 등 |
| **overlay** | BIT가 브라우저 페이지에 주입하는 inspect mode UI 레이어 |
| **atomic append** | inbox 파일에 쓰기 시 중간 상태 없이 완전한 JSON 단위로만 기록 |
| **DevToolsActivePort** | Chrome이 `--remote-debugging-port=0` 로 실행 시 실제 포트를 기록하는 파일 |

---

## 4. 이해관계자 (Stakeholders)

### 4.1 User (Frontend 개발자)

| 항목 | 내용 |
|---|---|
| **관심사** | 브라우저에서 요소를 클릭하는 1회 동작만으로 agent에게 의도를 전달하고 싶다 |
| **책임** | inspect mode 활성화, 요소 클릭, 코멘트 입력, 3차 시각 검증 |
| **성공 기준** | 클릭 1회 + 코멘트 입력 후 agent가 올바른 파일·라인을 수정함 |

### 4.2 Lead Claude Code

| 항목 | 내용 |
|---|---|
| **관심사** | payload 신뢰도, 구독 상태 전환 정확성, 2차 검증 결과 |
| **책임** | clmux-inspect subscribe/unsubscribe로 구독 전환, snapshot으로 2차 검증, teammate에 재작업 지시 |
| **성공 기준** | snapshot payload로 drift를 5분 이내 특정하고 teammate에 정확한 재작업 지시 가능 |

### 4.3 Frontend Teammate (Gemini / Claude Sonnet teammate / Codex)

| 항목 | 내용 |
|---|---|
| **관심사** | inbox에서 payload 수신, query 명령으로 자체 검증, 소스 코드 Read 후 drift 분석 |
| **책임** | 구현 + clmux-inspect query로 1차 자체 검증 + Playwright E2E 검증 |
| **성공 기준** | payload의 source_location을 기반으로 올바른 파일을 수정하고 query로 결과 확인 |

### 4.4 Verifier Teammate (1차 검증 담당)

| 항목 | 내용 |
|---|---|
| **관심사** | 구현 완료 후 실제 렌더 결과가 payload의 source_location + reality_fingerprint와 일치하는지 |
| **책임** | clmux-inspect query 실행, Playwright 검증, 검증 결과 Lead에 보고 |
| **성공 기준** | query 결과와 expected 값이 일치하면 "1차 검증 완료"로 Lead에 보고 |

---

## 5. 시스템 컨텍스트 + 가정

### 5.1 시스템 컨텍스트

BIT는 clau-mux tmux 세션 내에서 Lead Claude Code 세션의 수명에 동조하는 background 프로세스(browser-service daemon)와 CLI(clmux-inspect)로 구성된다. daemon은 CDP를 통해 격리 Chrome 인스턴스를 단독 소유하며, 사용자 click 이벤트를 수신해 구독 중인 teammate의 inbox에 payload를 atomic append한다. Lead는 clmux-inspect CLI를 통해 구독 전환·스냅샷·상태 확인을 수행하며, 전체 통신은 MCP 없이 파일 bridge + localhost HTTP로만 이루어진다.

### 5.2 가정 (Assumptions)

| # | 가정 |
|---|---|
| A-1 | 사용자는 macOS 13+ (Ventura 이상) 환경에서 iTerm2 + zsh를 사용한다 |
| A-2 | 사용자는 tmux 세션 안에서 clmux로 Lead 세션을 기동한다 |
| A-3 | 사용자는 Vite 기반 React 18/19 dev server를 로컬에서 구동 중이다 (localhost:3000 또는 사용자 지정 포트) |
| A-4 | Chrome 130+ 이상이 macOS 기본 경로(`/Applications/Google Chrome.app`)에 설치되어 있다 |
| A-5 | `clmux -b` 플래그로 시작한 세션은 BIT 전용 격리 Chrome 프로필을 사용한다 (기존 Chrome 프로필과 분리) |
| A-6 | 팀 디렉토리(`~/.claude/teams/$team/`)가 존재하며 읽기·쓰기 가능하다 |
| A-7 | teammate(gemini-worker, codex-worker 등)는 이미 spawn되어 inbox polling 중이다 |
| A-8 | BIT는 분석기가 아닌 pointing bridge이므로 agent가 소스 코드를 직접 Read해 drift를 분석한다 |

### 5.3 의존성

| 의존성 | 버전 | 용도 |
|---|---|---|
| Node.js | 20+ | browser-service daemon 런타임 |
| Chrome | 130+ | CDP target, overlay 주입 |
| tmux | 3.3+ | pane 관리, send-keys |
| zsh | 5.9+ | clmux-inspect CLI 래퍼, clmux.zsh 통합 |
| clau-mux | 현재 브랜치 | teammate inbox, bridge, team 디렉토리 규약 |

---

## 6. Use Cases (UC-1 ~ UC-7)

---

### UC-1: Frontend 작업 시작

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-1 |
| **제목** | Frontend 작업 시작 — Lead가 BIT를 teammate에 인계 |
| **주요 Actor** | User, Lead Claude Code, Frontend Teammate |

**사전 조건**
- clmux 세션이 `-b` 플래그로 기동됨 (browser-service daemon + Chrome 실행 중)
- teammate가 spawn되어 inbox polling 중
- dev server가 localhost에서 실행 중

**정상 흐름**
1. User가 Lead에게 "이 페이지 레이아웃 수정해줘" 등 frontend 작업 요청
2. Lead가 `clmux-inspect subscribe <teammate>` 실행 → `.inspect-subscriber` 파일 갱신
3. Lead가 teammate에게 SendMessage로 작업 지시 (payload 수신 대기 안내 포함)
4. Teammate가 구독 등록 확인 후 작업 준비 완료
5. User가 브라우저에서 inspect mode 활성화

**대안 흐름**
- A1: daemon이 중단된 경우 → `clmux-inspect status`로 확인 후 재시작
- A2: Chrome이 응답 없는 경우 → daemon이 10초 내 감지 후 재시작

**사후 조건**
- `.inspect-subscriber`에 teammate 이름 기록됨
- teammate가 다음 click 이벤트 payload를 수신할 준비 완료

**관련 FR** FR-101, FR-103, FR-501, FR-502

---

### UC-2: Teammate 자체 검증 (1차)

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-2 |
| **제목** | Teammate 자체 검증 — clmux-inspect query + Playwright |
| **주요 Actor** | Frontend Teammate |

**사전 조건**
- Teammate가 구현 완료
- Teammate가 구독 중 (`.inspect-subscriber`에 등록됨)
- BIT daemon 실행 중

**정상 흐름**
1. Teammate가 `clmux-inspect query <selector> <props...>` 실행
2. daemon이 CDP로 해당 selector의 computed style 등 실측 값 반환
3. Teammate가 반환 값과 소스 코드 의도 값을 비교 (drift 확인)
4. Teammate가 Playwright `connectOverCDP`로 E2E 검증 실행
5. 모든 검증 통과 시 Lead에게 "1차 검증 완료" 보고

**대안 흐름**
- A1: query 결과와 의도 값 불일치 → Teammate가 소스 수정 후 재검증
- A2: Playwright 테스트 실패 → Teammate가 실패 원인 분석 후 수정

**사후 조건**
- 1차 검증 결과(통과/실패)가 Lead에게 전달됨

**관련 FR** FR-601, FR-602, FR-604

---

### UC-3: Lead 검증 (2차)

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-3 |
| **제목** | Lead 검증 — clmux-inspect snapshot으로 직접 측정 |
| **주요 Actor** | Lead Claude Code |

**사전 조건**
- Teammate가 1차 검증 완료 보고
- BIT daemon 실행 중

**정상 흐름**
1. Lead가 `clmux-inspect subscribe team-lead` 실행 (구독 전환)
2. Lead가 `clmux-inspect snapshot <selector>` 실행
3. daemon이 full payload(pointing + source_location + reality_fingerprint) 생성·반환
4. Lead가 payload의 source_location·cascade_winner를 소스 코드와 교차 검증
5. 검증 통과 시 3차(User) 검증으로 이관

**대안 흐름**
- A1: snapshot의 mapping_confidence가 "low" 또는 "none" → Lead가 source_unknown 상태로 수동 파일 탐색
- A2: cascade_winner가 예상 외 파일 → Lead가 해당 파일을 직접 Read

**사후 조건**
- Lead가 수정 결과의 정확성을 기술적으로 확인함
- 3차 검증 준비 완료

**관련 FR** FR-401, FR-403, FR-501, FR-602, FR-305

---

### UC-4: 사용자 시각 검증 (3차)

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-4 |
| **제목** | 사용자 시각 검증 — inspect mode + click + 코멘트 |
| **주요 Actor** | User, Lead Claude Code |

**사전 조건**
- Lead가 2차 검증 완료
- `clmux-inspect subscribe team-lead` 활성 (Lead가 구독 중)
- 브라우저 overlay 활성화

**정상 흐름**
1. User가 브라우저에서 inspect mode 활성화
2. User가 마음에 들지 않는 요소 위로 마우스 이동 (target indicator 표시)
3. User가 요소 클릭 → browser-service가 click 이벤트 캡처
4. 브라우저 overlay에 코멘트 입력 UI 표시
5. User가 짧은 코멘트 입력 ("padding 이상", "색상이 틀려" 등)
6. browser-service가 payload 생성 → Lead inbox에 atomic append
7. Lead가 clmux pane에서 payload 자동 수신 (send-keys / paste-buffer)
8. Lead가 payload 분석 후 수정 방향 결정

**대안 흐름**
- A1: User가 코멘트 입력 없이 클릭만 → user_intent 필드 빈 문자열로 payload 생성
- A2: User가 잘못된 요소 클릭 → 재클릭으로 덮어쓰기 가능

**사후 조건**
- payload가 Lead inbox에 기록됨
- Lead가 user_intent + source_location 기반으로 재작업 지시 준비

**관련 FR** FR-201, FR-202, FR-203, FR-401, FR-503

---

### UC-5: 재작업 Cycle

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-5 |
| **제목** | 재작업 Cycle — Lead가 사용자 피드백 수신 후 teammate에 재작업 지시 |
| **주요 Actor** | Lead Claude Code, Frontend Teammate |

**사전 조건**
- UC-4 완료, Lead inbox에 payload 수신됨

**정상 흐름**
1. Lead가 payload의 user_intent + source_location + reality_fingerprint 분석
2. Lead가 공통 컴포넌트 여부 판단 (import 횟수 확인 prompt 규약 포함, FR-605)
3. Lead가 `clmux-inspect subscribe <teammate>` 실행 (구독 teammate로 전환)
4. Lead가 teammate에게 SendMessage로 재작업 지시 (payload 첨부)
5. Teammate가 UC-2 자체 검증 cycle 재실행
6. UC-2 → UC-3 → UC-4 반복

**대안 흐름**
- A1: 공통 컴포넌트 수정 위험 감지 → Lead가 "instance-only 수정" 명시적 지시
- A2: 같은 요소에 반복 피드백 → payload append-only, 이전 기록 보존

**사후 조건**
- 재작업 cycle이 시작됨
- payload는 append-only로 히스토리 보존

**관련 FR** FR-503, FR-504, FR-601, FR-604, FR-605

---

### UC-6: SPA Navigation 처리

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-6 |
| **제목** | SPA Navigation 처리 — inspect mode 활성 중 페이지 이동 |
| **주요 Actor** | User, browser-service daemon |

**사전 조건**
- inspect mode 활성화 중
- SPA(React Router, Vue Router 등) dev server 실행 중

**정상 흐름**
1. User가 inspect mode 활성화 상태에서 내비게이션 링크 클릭 또는 URL 변경
2. browser-service가 History API hook(pushState/replaceState)으로 route 변경 감지
3. CDP Page.frameNavigated 이벤트 수신 확인
4. browser-service가 overlay 재주입 (새 URL에서 inspect mode 복원)
5. 구독 상태(`meta.url`) 갱신
6. User가 새 페이지에서 계속 inspect 가능

**대안 흐름**
- A1: full page reload(hard navigation) → Page.frameNavigated만으로 처리 (History API hook 불필요)
- A2: iframe 내 navigation → same-origin인 경우 overlay 재주입, cross-origin은 skip + 로그 기록

**사후 조건**
- 새 URL에서 overlay가 정상 활성화됨
- 이전 구독 상태 유지

**관련 FR** FR-204, FR-205

---

### UC-7: 공통 컴포넌트 Wrong-File 방지

| 항목 | 내용 |
|---|---|
| **UC-ID** | UC-7 |
| **제목** | 공통 컴포넌트 Wrong-File 방지 — agent가 import 횟수 확인 후 판단 |
| **주요 Actor** | Frontend Teammate, Lead Claude Code |

**사전 조건**
- payload에 source_location.file 포함
- Teammate가 해당 파일을 수정하려는 시점

**정상 흐름**
1. Teammate가 payload의 source_location.file 확인
2. Teammate가 agent prompt checklist에 따라 import 횟수 확인 (`grep -c import <file>`)
3. import 횟수 1회 → instance-only 파일로 판단 → 직접 수정 진행
4. import 횟수 ≥ 2회 → 공통 컴포넌트로 판단 → Lead에 보고 후 대기
5. Lead가 "instance-only 수정" 또는 "공통 수정" 명시적 승인

**대안 흐름**
- A1: import 횟수 확인 불가(파일 탐색 실패) → Lead에 즉시 보고

**사후 조건**
- 공통 컴포넌트 의도치 않은 수정 방지
- 수정 범위가 명시적으로 확정됨

**관련 FR** FR-604, FR-605

---

## 7. 기능 요구사항 (Functional Requirements)

---

### FR-1xx — 활성화 / 생명주기

**FR-101: clmux -b 플래그로 inspect tool 활성화**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | `clmux -b` 플래그를 지정하면 BIT(browser-service daemon + 격리 Chrome)가 세션 시작 시 자동 기동된다. |
| **Acceptance Criteria** | - Given: `clmux -n proj -b -T team`으로 세션 시작 / When: 세션 기동 완료 / Then: `.browser-service.pid`, `.browser-service.port` 파일이 `~/.claude/teams/team/`에 생성되고, `clmux-inspect status`가 "running" 반환 |
| **관련 UC** | UC-1 |

**FR-102: 격리 Chrome 프로필 자동 launch**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | daemon이 Chrome을 `--remote-debugging-port=0 --user-data-dir=<isolated-dir>` 조합으로 launch한다. 기본 Chrome 프로필을 절대 사용하지 않는다. |
| **Acceptance Criteria** | - Given: BIT 활성화 / When: Chrome 프로세스 시작 / Then: `ps aux`에서 Chrome 명령에 `--user-data-dir`이 `/tmp/clmux-chrome-*` 형태로 포함됨; 사용자 기존 Chrome 세션과 독립 |
| **관련 UC** | UC-1 |

**FR-103: browser-service daemon 자동 spawn (Lead 세션 수명 동조)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | browser-service daemon은 Lead 세션 시작 시 background로 spawn되며, Lead 세션 종료 시 자동 종료된다. Copilot MCP 서버 패턴을 복제한다. |
| **Acceptance Criteria** | - Given: Lead 세션 기동 / When: daemon spawn 완료 / Then: PID 파일 기록, 로그 파일(`/tmp/clmux-browser-service-$team.log`) 생성; Lead 세션 종료 시 daemon + Chrome 프로세스 모두 종료됨 |
| **관련 UC** | UC-1 |

**FR-104: 세션 종료 시 cleanup**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | Lead 세션 종료(정상 또는 비정상) 시 daemon, Chrome, 임시 파일(PID, port, isolated profile)이 모두 정리된다. |
| **Acceptance Criteria** | - Given: 세션 종료 이벤트 / When: cleanup 완료 / Then: `.browser-service.pid`, `.browser-service.port` 파일 삭제; Chrome 프로세스 없음; `/tmp/clmux-chrome-*` 디렉토리 삭제 |
| **관련 UC** | UC-1 |

---

### FR-2xx — Pointing 캡처

**FR-201: Inspect mode toggle (CDP Overlay.setInspectMode)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 사용자가 브라우저 overlay의 toggle 버튼 또는 `clmux-inspect` 명령으로 inspect mode를 켜고 끌 수 있다. |
| **Acceptance Criteria** | - Given: overlay 주입 완료 / When: toggle 활성화 / Then: 마우스 호버 시 target indicator(하이라이트) 표시; toggle 비활성화 시 정상 브라우저 동작 복원 |
| **관련 UC** | UC-4 |

**FR-202: 사용자 click 이벤트 캡처 (Overlay.inspectNodeRequested)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | inspect mode 활성화 상태에서 사용자가 요소를 클릭하면 CDP Overlay.inspectNodeRequested 이벤트로 대상 노드 정보를 캡처한다. |
| **Acceptance Criteria** | - Given: inspect mode 활성 / When: 요소 클릭 / Then: 해당 노드의 selector, outerHTML(200자 truncate), attrs가 daemon에 전달됨 |
| **관련 UC** | UC-4 |

**FR-203: 사용자 코멘트 입력 캡처**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | click 이벤트 후 overlay에 코멘트 입력 UI가 표시되며, 사용자가 입력한 자연어 코멘트가 `user_intent` 필드로 payload에 포함된다. |
| **Acceptance Criteria** | - Given: 요소 클릭 후 / When: 코멘트 UI에 텍스트 입력 후 확인 / Then: payload.user_intent에 입력 텍스트 포함; 입력 없이 확인 시 user_intent는 빈 문자열 |
| **관련 UC** | UC-4 |

**FR-204: SPA navigation 시 overlay 자동 재주입**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | client-side routing 발생 시 History API hook(pushState/replaceState) + CDP Page.frameNavigated 이벤트로 감지하고 overlay를 자동 재주입한다. MutationObserver는 기본 비활성화. |
| **Acceptance Criteria** | - Given: inspect mode 활성 중 / When: SPA 내비게이션 발생 / Then: 500ms 이내 overlay 재주입 완료; 구독 상태의 url 필드 갱신됨 |
| **관련 UC** | UC-6 |

**FR-205: Shadow DOM / iframe pierce 처리**

| 항목 | 내용 |
|---|---|
| **우선순위** | SHOULD |
| **설명** | Shadow DOM은 CDP pierce 모드로 접근하고, same-origin iframe은 Target.setAutoAttach(flatten:true)로 처리한다. Cross-origin iframe은 MVP에서 skip하고 로그 기록. |
| **Acceptance Criteria** | - Given: Shadow DOM 내 요소 클릭 / When: click 캡처 / Then: pointing.shadowPath에 Shadow DOM 경계 chain 포함; Given: cross-origin iframe 클릭 / Then: 처리 불가 로그 기록 후 skip |
| **관련 UC** | UC-6 |

---

### FR-3xx — Source Remapping

**FR-301: Multi-tier source 역매핑 (T1→T2→T4)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 런타임 감지를 통해 T1(runtime hook) → T2(build-time injection) → T4(CSS sourcemap) 순으로 소스 위치를 역매핑한다. |
| **Acceptance Criteria** | - Given: React 18 프로젝트 / When: 요소 클릭 / Then: `__reactFiber$*._debugSource`에서 file:line 추출; Given: React 19 / Then: T2(Vite plugin) fallback 자동 선택 |
| **관련 UC** | UC-3 |

**FR-302: 프레임워크 자동 감지 (React/Vue/Svelte/Solid)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 페이지 로드 시 `__reactFiber$*`, `__vue__`, `__svelte_meta`, `data-source-loc` 등 프레임워크 시그니처로 자동 감지하고 적절한 remapping tier를 선택한다. |
| **Acceptance Criteria** | - Given: Vue 3 프로젝트 / When: 페이지 초기화 / Then: source_location.framework = "vue"; Given: 미감지 / Then: framework = "unknown", tier 건너뜀 |
| **관련 UC** | UC-2, UC-3 |

**FR-303: source mapping confidence 표기**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 매핑 결과의 신뢰도를 `sourceMappingConfidence` 필드에 'high' / 'medium' / 'low' / 'none' 중 하나로 표기한다. confidence < high 시 `fallbackReason` 필드에 원인 기술. |
| **Acceptance Criteria** | - Given: T1 매핑 성공 / Then: confidence = "high", fallbackReason = null; Given: T2 fallback 사용 / Then: confidence = "medium", fallbackReason에 원인 기술 |
| **관련 UC** | UC-3 |

**FR-304: React 19 fallback (Tier 2 자동 전환)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | React 19 감지 시(`_debugSource` 미존재, PR #28265) T1 건너뛰고 T2(Vite plugin 기반 build-time injection) 자동 선택. |
| **Acceptance Criteria** | - Given: React 19 + Vite 환경 / When: 요소 클릭 / Then: source_location.mapping_via = "vite-plugin-react-source"; confidence = "medium" 이상 |
| **관련 UC** | UC-3 |

**FR-305: 매핑 실패 시 honest "source_unknown"**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 모든 tier 실패 시 source_location.file = "source_unknown"으로 설정하고 추측값을 반환하지 않는다. |
| **Acceptance Criteria** | - Given: 모든 remapping tier 실패 / When: payload 생성 / Then: file = "source_unknown", confidence = "none"; 추측 파일 경로 반환 없음 |
| **관련 UC** | UC-3 |

---

### FR-4xx — Reality Fingerprint

**FR-401: 4-section payload 생성**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 클릭 이벤트마다 user_intent / pointing / source_location / reality_fingerprint 4개 섹션을 포함한 완전한 JSON payload를 생성한다. |
| **Acceptance Criteria** | - Given: 요소 클릭 + 코멘트 입력 / When: payload 생성 / Then: 4개 최상위 키 모두 존재; meta.timestamp와 meta.url 포함 |
| **관련 UC** | UC-4 |

**FR-402: <5,000 토큰 budget 준수**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 전체 payload 토큰 수가 5,000을 초과하지 않도록 reality_fingerprint 내용을 제한한다. 토큰 초과 시 낮은 우선순위 필드를 truncate한다. |
| **Acceptance Criteria** | - Given: 복잡한 요소 클릭 / When: payload 생성 / Then: tiktoken 기준 전체 payload ≤ 5,000 토큰; `_token_budget: "<5000"` 필드 포함 |
| **관련 UC** | UC-3, UC-4 |

**FR-403: cascade_winner 추출 (CDP CSS.getMatchedStylesForNode)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | CDP CSS.getMatchedStylesForNode를 사용해 CSS cascade에서 최종 승자 규칙(파일:라인 포함)을 추출하고 `cascade_winner` 필드로 제공한다. |
| **Acceptance Criteria** | - Given: CSS가 적용된 요소 / When: snapshot / Then: cascade_winner에 "padding: src/styles/card.css:23 (.card--highlighted)" 형태로 파일 위치 포함 |
| **관련 UC** | UC-3 |

**FR-404: a11y tree 기반 컴팩트 표현**

| 항목 | 내용 |
|---|---|
| **우선순위** | SHOULD |
| **설명** | reality_fingerprint에 CDP Accessibility.getFullAXTree 기반 `ax_role_name` 및 accessible name을 포함한다. 전체 DOM 트리 대신 a11y tree로 토큰 비용을 절감한다. |
| **Acceptance Criteria** | - Given: `<article>` 요소 / When: payload / Then: reality_fingerprint.ax_role_name = "article"; scroll_offsets, viewport, device_pixel_ratio 포함 |
| **관련 UC** | UC-3 |

**FR-405: 스크린샷 / 이미지 데이터 포함 금지**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | payload에 이미지, 스크린샷, base64 인코딩 시각 데이터를 절대 포함하지 않는다. |
| **Acceptance Criteria** | - Given: 어떤 상황에서든 / When: payload 생성 / Then: payload JSON에 "data:image", "base64", "screenshot" 키 없음 |
| **관련 UC** | UC-3, UC-4 |

---

### FR-5xx — 구독 / 라우팅

**FR-501: `.inspect-subscriber` 파일 기반 구독 모델**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | 현재 click 이벤트를 수신할 subscriber는 `~/.claude/teams/$team/.inspect-subscriber` 파일에 agent 이름 단일 값으로 기록한다. WebSocket 기반 실시간 채널을 사용하지 않는다. |
| **Acceptance Criteria** | - Given: `clmux-inspect subscribe gemini-worker` 실행 / When: 완료 / Then: `.inspect-subscriber` 파일에 "gemini-worker" 기록; 파일 권한 0600 |
| **관련 UC** | UC-1 |

**FR-502: clmux-inspect subscribe / unsubscribe 명령**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | `clmux-inspect subscribe <agent>` 와 `clmux-inspect unsubscribe` 명령으로 구독자를 전환하거나 해제한다. |
| **Acceptance Criteria** | - Given: subscribe 실행 / Then: 파일 갱신 + 이전 구독자 알림; Given: unsubscribe 실행 / Then: 파일 내용 빈 문자열로 설정 |
| **관련 UC** | UC-1, UC-5 |

**FR-503: 사용자 click 시 현재 구독자 inbox에 atomic append**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | click 이벤트 발생 시 `.inspect-subscriber` 파일을 읽어 현재 구독자를 확인하고, 해당 agent의 inbox 파일에 JSON payload를 atomic append한다. |
| **Acceptance Criteria** | - Given: "gemini-worker" 구독 중 / When: click 발생 / Then: `inboxes/gemini-worker.json`에 payload append; 기존 inbox 내용 유지 |
| **관련 UC** | UC-4 |

**FR-504: 구독자 변경 시 in-flight 이벤트 보존**

| 항목 | 내용 |
|---|---|
| **우선순위** | SHOULD |
| **설명** | 구독자 변경 중 처리 중인 click 이벤트가 있을 경우 이전 구독자 inbox에 완전히 기록 후 변경한다. |
| **Acceptance Criteria** | - Given: click 처리 중 subscribe 변경 / When: 완료 / Then: click payload는 이전 구독자 inbox에 완전히 기록됨; 이후 클릭은 새 구독자에게 전달 |
| **관련 UC** | UC-5 |

---

### FR-6xx — Agent CLI 도구

**FR-601: clmux-inspect query (active 측정)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | `clmux-inspect query <selector> [props...]` 명령으로 현재 브라우저에서 특정 요소의 computed style 등을 실측한다. 응답 시간 p95 < 500ms. |
| **Acceptance Criteria** | - Given: daemon 실행 중 / When: `clmux-inspect query .card padding` / Then: 500ms 이내 JSON 응답; 해당 속성값 포함 |
| **관련 UC** | UC-2 |

**FR-602: clmux-inspect snapshot (full payload)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | `clmux-inspect snapshot <selector>` 명령으로 특정 요소의 full payload(pointing + source_location + reality_fingerprint)를 생성·반환한다. |
| **Acceptance Criteria** | - Given: daemon 실행 중 / When: `clmux-inspect snapshot .card` / Then: 1초 이내 4-section payload JSON 출력; 토큰 ≤ 5,000 |
| **관련 UC** | UC-3 |

**FR-603: clmux-inspect status**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | `clmux-inspect status` 명령으로 daemon 상태, 현재 구독자, Chrome 연결 상태를 확인한다. |
| **Acceptance Criteria** | - Given: daemon 실행 중 / When: status 명령 / Then: {status: "running", subscriber: "gemini-worker", chrome: "connected"} 형태 출력; 비실행 시 {status: "stopped"} |
| **관련 UC** | UC-1 |

**FR-604: agent prompt template (Candidate 2 Checklist-Driven) 기본 적용**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | BIT payload를 수신한 agent에게 적용할 기본 prompt template은 Candidate 2 (Checklist-Driven with anti-hallucination guards)를 사용한다. Gemini: compact variant, Claude: strict variant. |
| **Acceptance Criteria** | - Given: payload 주입 / When: agent가 작업 시작 / Then: "source 파일 Read → drift 비교 → 수정" 순서로 체크리스트 기반 진행; 소스 Read 전 수정 없음 |
| **관련 UC** | UC-2, UC-3 |

**FR-605: agent prompt에 "공통 컴포넌트 사용처 확인" 단계 포함 (NEW-1 mitigation)**

| 항목 | 내용 |
|---|---|
| **우선순위** | MUST |
| **설명** | MVP에서는 agent prompt 규약으로 NEW-1 위험을 완화한다. prompt checklist에 "공통 컴포넌트 수정 전 반드시 import 횟수 확인 (`grep -c import <file>`)" 단계를 포함한다. caller_chain 자동 수집은 post-MVP. |
| **Acceptance Criteria** | - Given: agent가 source_location.file 파일 수정 시도 / When: import 횟수 2 이상 / Then: Lead에 즉시 보고 후 명시적 승인 대기; import 횟수 1 / Then: 직접 수정 진행 |
| **관련 UC** | UC-7 |

---

## 8. 비기능 요구사항 (Non-functional Requirements)

---

### NFR-1xx — 성능

**NFR-101: clmux-inspect query 응답 시간**

| 항목 | 내용 |
|---|---|
| **설명** | query 명령의 응답 시간 |
| **기준** | p95 < 500ms (로컬 dev server 기준, CDP round-trip 포함) |

**NFR-102: payload 생성 시간**

| 항목 | 내용 |
|---|---|
| **설명** | snapshot 명령 및 click 이벤트 기반 payload 전체 생성 시간 |
| **기준** | p95 < 1,000ms (source remapping + fingerprint 수집 포함) |

**NFR-103: payload 총 토큰**

| 항목 | 내용 |
|---|---|
| **설명** | 생성되는 payload의 LLM 토큰 비용 |
| **기준** | tiktoken(cl100k_base) 기준 payload 전체 ≤ 5,000 토큰 |

**NFR-104: daemon 메모리 사용**

| 항목 | 내용 |
|---|---|
| **설명** | browser-service Node.js daemon의 RSS 메모리 사용량 |
| **기준** | 정상 운영 시 < 100MB (Chrome 제외) |

---

### NFR-2xx — 신뢰성

**NFR-201: daemon crash 재시작**

| 항목 | 내용 |
|---|---|
| **설명** | daemon 비정상 종료 시 자동 재시작 정책 |
| **기준** | 1차: 즉시 재시작; 2차+: exponential backoff (1s → 2s → 4s …); 3회 실패 후 Lead 알림 |

**NFR-202: Chrome crash 감지**

| 항목 | 내용 |
|---|---|
| **설명** | Chrome 프로세스 비정상 종료 감지 속도 |
| **기준** | < 10초 이내 감지; 감지 후 NFR-201 재시작 정책 적용 |

**NFR-203: source remap 성공률**

| 항목 | 내용 |
|---|---|
| **설명** | React 18 + Vite 환경에서 T1 remapping 성공률 |
| **기준** | ≥ 90% (React 18 + Vite 5 dev build 기준); React 19는 T2 fallback 포함 시 ≥ 80% |

---

### NFR-3xx — 보안

**NFR-301: Chrome 격리 프로필 강제**

| 항목 | 내용 |
|---|---|
| **설명** | Chrome launch 시 반드시 격리 프로필 사용 |
| **기준** | `--user-data-dir` 없이 Chrome launch 시 daemon이 즉시 실패 처리; 기본 Chrome profile 접근 불가 |

**NFR-302: localhost only binding**

| 항목 | 내용 |
|---|---|
| **설명** | daemon HTTP 엔드포인트 및 CDP 포트의 네트워크 바인딩 |
| **기준** | 127.0.0.1 또는 ::1 에만 바인딩; 외부 인터페이스(0.0.0.0) 바인딩 금지 |

**NFR-303: 파일 권한**

| 항목 | 내용 |
|---|---|
| **설명** | 구독 파일, port 파일, env 파일의 접근 권한 |
| **기준** | `.inspect-subscriber`, `.browser-service.port`, `.browser-service.pid` 파일 권한 0600 |

**NFR-304: payload 내 secret 후보 redaction**

| 항목 | 내용 |
|---|---|
| **설명** | payload 생성 시 secret 가능성이 있는 값 자동 마스킹 |
| **기준** | outerHTML 내 `password`, `token`, `secret`, `api_key`, `Authorization` 패턴 → `[REDACTED]` 치환; allowlist(class, id, data-*)는 통과 |

---

### NFR-4xx — 사용성

**NFR-401: 사용자 1회 클릭으로 inspect 완료**

| 항목 | 내용 |
|---|---|
| **설명** | 사용자의 inspect 동작 최소화 |
| **기준** | overlay 활성화 후 클릭 1회 + 코멘트 입력(선택) → payload 주입 완료 (추가 개발자 도구 조작 불필요) |

**NFR-402: 명령어 4개 이하로 전체 워크플로**

| 항목 | 내용 |
|---|---|
| **설명** | 전체 BIT 워크플로에서 사용하는 CLI 명령어 수 |
| **기준** | subscribe / unsubscribe / query / snapshot / status — 5개 이하로 완결; 추가 설치·설정 명령 불필요 |

**NFR-403: 에러 메시지 한국어/영어 병기**

| 항목 | 내용 |
|---|---|
| **설명** | CLI 에러 및 상태 메시지 언어 규약 |
| **기준** | 모든 에러 메시지에 한국어 설명 + 영어 기술 용어 병기 (clau-mux README 컨벤션 준수) |

---

### NFR-5xx — 호환성

**NFR-501: macOS 13+ (Ventura 이상)**

| 항목 | 내용 |
|---|---|
| **설명** | 지원 OS |
| **기준** | macOS 13.0 이상에서 정상 동작; Linux/Windows 비보증 |

**NFR-502: Chrome 130+**

| 항목 | 내용 |
|---|---|
| **설명** | CDP Stable API 지원 최소 Chrome 버전 |
| **기준** | Chrome 130 이상; Chromium-based 브라우저(Edge 등) 동작 보증 불가 |

**NFR-503: Node.js 20+**

| 항목 | 내용 |
|---|---|
| **설명** | daemon 런타임 최소 버전 |
| **기준** | Node.js 20 LTS 이상; npm 10 이상 |

**NFR-504: 기존 teammate와 충돌 없음**

| 항목 | 내용 |
|---|---|
| **설명** | BIT 활성화 시 기존 clau-mux teammate(gemini-worker, codex-worker, copilot-worker)와 공존 |
| **기준** | `-b` 플래그 추가 시 기존 `-g`/`-x`/`-c` teammate 기능에 영향 없음; inbox 파일 충돌 없음 |

---

### NFR-6xx — 관측성

**NFR-601: daemon 로그 파일**

| 항목 | 내용 |
|---|---|
| **설명** | daemon 운영 로그 |
| **기준** | `/tmp/clmux-browser-service-$team.log`에 실시간 append; 타임스탬프 + 이벤트 유형 포함 |

**NFR-602: clmux-inspect status 명령으로 daemon 상태 확인**

| 항목 | 내용 |
|---|---|
| **설명** | 실시간 daemon 상태 조회 |
| **기준** | 응답에 {status, subscriber, chrome_pid, uptime, last_payload_at} 포함; 500ms 이내 응답 |

**NFR-603: payload 생성 이벤트 기록 (debug mode)**

| 항목 | 내용 |
|---|---|
| **설명** | debug 모드에서 모든 payload 생성 이벤트 기록 |
| **기준** | `CLMUX_DEBUG=1` 환경변수 설정 시 payload JSON을 로그 파일에 전체 기록 |

---

## 9. 외부 인터페이스 요구사항

### 9.1 사용자 인터페이스

**브라우저 Overlay**
- inspect mode toggle 버튼 (화면 우상단 고정, 클릭 시 활성화/비활성화)
- target indicator: 마우스 hover 시 해당 요소 하이라이트 (1px 파란색 outline + 반투명 배경)
- 코멘트 입력 UI: 클릭 후 팝업 형태, 확인/취소 버튼, Enter 키 확인 지원

**tmux Pane (Lead Pane)**
- click 이벤트 발생 시 payload가 Lead pane에 자동 주입 (clmux-bridge 경유 send-keys / paste-buffer)
- payload는 JSON 형식으로 pane에 직접 표시

### 9.2 시스템 인터페이스

**Chrome (CDP)**
- 연결: `--remote-debugging-port=0` → DevToolsActivePort 파일 poll로 실제 포트 발견
- 사용 CDP 도메인: Overlay, CSS, DOM, Page, Target, Accessibility, Runtime

**파일 시스템 (`~/.claude/teams/$team/`)**

| 파일 | 용도 | 권한 |
|---|---|---|
| `.browser-service.pid` | daemon PID | 0600 |
| `.browser-service.port` | daemon HTTP 포트 | 0600 |
| `.inspect-subscriber` | 현재 구독 agent 이름 | 0600 |
| `inboxes/{agent}.json` | teammate inbox (기존 bridge 재사용) | 0600 |

**tmux**
- clmux-bridge.zsh 경유 send-keys (Gemini) 또는 paste-buffer (Codex, Copilot)
- Lead pane 식별: `$CLMUX_LEAD_PANE` 환경변수

**shell PATH**
- `clmux-inspect` 명령이 `$PATH`에 등록됨 (setup.sh 경유)

### 9.3 통신 프로토콜

| 채널 | 프로토콜 | 비고 |
|---|---|---|
| daemon ↔ CLI | localhost HTTP (random port, 0600 포트 파일) | JSON request/response |
| daemon ↔ Chrome | CDP WebSocket | DevToolsActivePort로 포트 발견 |
| daemon ↔ teammate inbox | 파일 atomic write | append-only JSON |
| clmux-bridge.zsh ↔ tmux pane | tmux send-keys / paste-buffer | 기존 bridge 재사용 |

---

## 10. 제약사항

| ID | 제약 | 근거 | 영향 |
|---|---|---|---|
| C1 | macOS + tmux + zsh + iTerm2 환경 전제 | clau-mux 기존 제약 — 기반 환경 고정 | NFR-501; Linux/Windows 포팅 불가 |
| C2 | NOT MCP — CLI + 파일 브리지만 사용 | 사용자 명시 금지; clau-mux 아키텍처 일관성 | FR-501, FR-503; MCP 레이어 추가 불가 |
| C3 | 스크린샷·이미지 데이터를 payload에 포함하지 않음 | LLM 시각 처리 약점 회피; 토큰 비용 절감 | FR-405; 시각 기반 분석 방법론 배제 |
| C4 | Lead 세션과 수명 동조하는 background 프로세스 모델 | clau-mux 패턴 일관성 (Copilot MCP 서버 패턴) | FR-103; 별도 독립 서비스 구조 불가 |
| C5 | 분석은 항상 소스 코드 Read 기반 | LLM 강점(코드 이해) 활용; drift 분석 정확도 보장 | FR-604; 추측 기반 수정 금지 |
| C6 | Chrome launch 시 `--remote-debugging-port=0 --user-data-dir=<isolated-dir>` 필수 | 2025 Chrome 보안 mandate — infostealer 취약점 (NEW-4) | NFR-301, FR-102; 기본 Chrome profile 사용 절대 금지 |

---

## 11. 가정 / 위험 / 미해결 (Open Issues)

### 11.1 위험 항목 요약

| Risk ID | 설명 | 심각도 | 상태 | 관련 FR/NFR |
|---|---|---|---|---|
| NEW-1 | 공통 컴포넌트 잘못된 파일 수정 — Page A Button 클릭 → 공유 Button.tsx 수정 → Page B/C/D 망가짐 | High | **결정**: MVP는 agent prompt 규약(B); post-MVP에서 caller_chain payload 추가(A) 검토 | FR-605 |
| NEW-2 | SPA navigation overlay 소멸 — client-side routing 시 overlay 소멸, 구독 상태 stale | Medium | **해결**: History API hook + Page.frameNavigated → overlay 재주입 (Decision #8 amendment) | FR-204 |
| NEW-3 | reality_fingerprint 토큰 초과 — 전체 DOM ~400k 토큰, LLM context 초과 | High | **해결**: a11y tree 기반 + viewport clipping + CSS 핵심 12개 속성만. <5,000 토큰 budget | FR-402, NFR-103 |
| NEW-4 | Chrome 2025 보안 mandate — infostealer가 기본 profile + `--remote-debugging-port` 악용 | High | **해결**: `--remote-debugging-port=0 --user-data-dir=<isolated>` 필수. DevToolsActivePort poll | NFR-301, FR-102 |
| NEW-5 | React 19 `_debugSource` 제거 (PR #28265) — Tier 1 source remapping 불가 | Medium | **해결**: React 19 감지 시 Tier 2 (Vite plugin) 자동 fallback; `sourceMappingConfidence` 필드로 신뢰도 표기 | FR-304, FR-303 |

### 11.2 구현 시 결정 사항 (TBD)

| 항목 | 내용 | 초기 권고값 |
|---|---|---|
| caller_chain 깊이 | `_debugOwner` chain 최대 몇 단계 따라갈 것인가 | 최대 5단계 |
| MutationObserver 활성화 여부 | R2 비권고, R3 권고 — SPA 프레임워크별 런타임 선택 | 기본 비활성화 |
| cascade_winner 표시 방식 | `!important` 체인 전체 vs. 최종 승자만 | 토큰 budget 내에서 최종 승자만 |
| failure cap 임계값 | Chrome 재시작 몇 회 실패 시 Lead alert | 3회 |
| cross-origin iframe 지원 범위 | MVP same-origin만 vs. 완전 지원 | MVP: same-origin만 |

---

## 12. Acceptance Criteria 종합 + Traceability

### 12.1 Phase 별 Acceptance Gate

**MVP Gate (P1~P6 완료 시 만족해야 할 조건)**

- [ ] `clmux -b` 실행 시 browser-service daemon + Chrome 격리 프로필로 기동 (FR-101, FR-102)
- [ ] inspect mode toggle + click 1회로 payload가 구독 teammate inbox에 전달됨 (FR-201~203, FR-503)
- [ ] payload에 4개 섹션 모두 존재하며 토큰 ≤ 5,000 (FR-401, FR-402)
- [ ] source_location.file이 실제 소스 파일 경로를 포함하거나 "source_unknown"으로 honest fallback (FR-301, FR-305)
- [ ] cascade_winner에 파일:라인 포함 (FR-403)
- [ ] SPA navigation 후 overlay 재활성화 (FR-204)
- [ ] `clmux-inspect status` 명령이 500ms 이내 응답 (FR-603, NFR-602)
- [ ] 세션 종료 시 daemon + Chrome + 임시 파일 cleanup (FR-104)
- [ ] 기존 `-g`/`-x`/`-c` teammate 기능에 영향 없음 (NFR-504)

**Pre-merge Gate**

- [ ] NFR-101 (query p95 < 500ms) 측정 값 문서화
- [ ] NFR-203 (React 18+Vite source remap ≥ 90%) 측정 값 문서화
- [ ] NFR-301 (격리 profile 강제) 자동화 테스트 통과
- [ ] FR-405 (이미지 데이터 금지) 자동화 검증 통과

### 12.2 Traceability Matrix (핵심 항목)

> 전체 매트릭스는 별도 부록(Appendix) 문서로 관리. 아래는 핵심 15개 항목.

| FR/NFR | Use Case | Constraint | Risk |
|---|---|---|---|
| FR-101 | UC-1 | C4 | — |
| FR-102 | UC-1 | C6 | NEW-4 |
| FR-103 | UC-1 | C4 | — |
| FR-201 | UC-4, UC-6 | — | NEW-2 |
| FR-204 | UC-6 | — | NEW-2 |
| FR-205 | UC-6 | — | — |
| FR-301 | UC-2, UC-3 | C5 | NEW-5 |
| FR-304 | UC-3 | C5 | NEW-5 |
| FR-305 | UC-3 | C5 | — |
| FR-401 | UC-3, UC-4 | C3 | NEW-3 |
| FR-402 | UC-3, UC-4 | C3 | NEW-3 |
| FR-403 | UC-3 | C3 | — |
| FR-405 | UC-3, UC-4 | C3 | — |
| FR-501 | UC-1, UC-5 | C2 | — |
| FR-605 | UC-7, UC-5 | C5 | NEW-1 |
| NFR-301 | UC-1 | C6 | NEW-4 |
| NFR-103 | UC-3, UC-4 | C3 | NEW-3 |

---

*SRS-BIT-001 v0.1 — 2026-04-08*
