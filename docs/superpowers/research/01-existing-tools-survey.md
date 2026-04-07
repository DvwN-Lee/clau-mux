# R1 — Agent 기반 Frontend 생성/디버깅 OSS 서베이 + 사용자 만족도 패턴

**담당**: gemini-worker
**상태**: completed
**입력**: 00-INDEX.md
**산출 위치**: 이 파일

## Scope

### A. "AI가 페이지를 생성"하는 도구

#### 1. v0.dev
- **URL**: https://v0.dev
- **License**: Proprietary (Vercel)
- **Mechanism**: 채팅 기반 프롬프트로 React/Tailwind/shadcn 컴포넌트 생성 및 브라우저 내 렌더링. 부분 영역 선택 후 재생성(Select & Edit).
- **Click→Agent path**: 렌더링된 iframe 내에서 요소를 드래그/클릭하여 bounding box 좌표 및 해당 영역의 컴포넌트 코드 AST 노드를 추출.
- **Captured payload**: 선택 영역의 React 컴포넌트 소스 코드 스니펫, 프롬프트.
- **Agent integration**: Proprietary web UI. 코드 복사 또는 Vercel 배포.
- **Reusability for our project**: Low (폐쇄형 생태계).
- **User satisfaction signals**: UI/UX 완성도가 가장 높으나 전체 풀스택 앱 생성에는 부적합하다는 의견 다수 [https://uibakery.io/blog/bolt-new-vs-v0-dev].

#### 2. bolt.new
- **URL**: https://bolt.new
- **License**: Proprietary (StackBlitz)
- **Mechanism**: 브라우저 내 WebContainer를 사용하여 풀스택(Node, Vite, React) 앱을 생성하고 실행.
- **Click→Agent path**: 브라우저 미리보기 창에서 요소를 선택하면 해당 요소의 DOM 경로를 에디터 내 소스 코드와 매핑 (source map 활용).
- **Captured payload**: Error log, console output, 선택한 요소의 소스 파일 경로 및 줄 번호.
- **Agent integration**: Web 기반 통합 IDE.
- **Reusability for our project**: Low (WebContainer 종속성).
- **User satisfaction signals**: MVP 제작 속도 및 에러 자동 디버깅 측면에서 v0보다 우수하다는 평가 [https://nxcode.io/blog/bolt-new-vs-v0-dev].

#### 3. lovable.dev
- **URL**: https://lovable.dev
- **License**: Proprietary
- **Mechanism**: Supabase 연동을 포함한 풀스택 React 앱 생성.
- **Click→Agent path**: 렌더링된 프리뷰에서 요소를 클릭하면 React Fiber 트리를 역추적하여 원본 컴포넌트 코드 위치 식별.
- **Captured payload**: React Component 정보, 파일 경로.
- **Agent integration**: Web 기반 통합 환경 + GitHub Push.
- **Reusability for our project**: Low.
- **User satisfaction signals**: "코딩 지식 없이도 실제 작동하는 백엔드 연동 앱을 만들 수 있다"는 점이 강점 [https://uibakery.io/blog/lovable-dev-review].

#### 4. GPT Engineer App
- **URL**: https://gptengineer.app
- **License**: Proprietary (Open source CLI 버전 존재, MIT)
- **Mechanism**: 초기 Lovable과 유사, GitHub 저장소와 동기화하며 앱 생성.
- **Click→Agent path**: 웹 UI 내장 inspector.
- **Captured payload**: DOM node + React props.
- **Agent integration**: Web UI.
- **Reusability for our project**: Low.
- **User satisfaction signals**: 초기 스캐폴딩에는 좋으나 복잡한 로직 수정 시 맥락 유지가 어렵다는 피드백.

#### 5. Claude Artifacts
- **URL**: https://claude.ai
- **License**: Proprietary
- **Mechanism**: 채팅 창 옆에 단일 파일(또는 가벼운 번들) 형태의 HTML/JS/React 코드를 렌더링.
- **Click→Agent path**: 없음. 사용자가 시각적으로 확인 후 텍스트로 피드백.
- **Captured payload**: 없음.
- **Agent integration**: 웹 채팅 인터페이스.
- **Reusability for our project**: Low.
- **User satisfaction signals**: 빠른 프로토타이핑에는 좋으나, DOM 클릭을 통한 정확한 포인팅이 안 되어 "두 번째 파란 버튼" 처럼 설명해야 하는 불편함 호소.

#### 6. WebSim AI
- **URL**: https://websim.ai
- **License**: Proprietary
- **Mechanism**: 가상의 브라우저 URL을 입력하면 AI가 실시간으로 DOM을 생성.
- **Click→Agent path**: URL 기반 프롬프팅.
- **Captured payload**: URL + User text.
- **Agent integration**: 웹 UI.
- **Reusability for our project**: Low.
- **User satisfaction signals**: 창의적 실험에는 좋으나, 디버깅 도구로는 부적합.

### B. "AI agent + 브라우저 inspect 통합" 도구

#### 7. stagewise
- **URL**: https://github.com/stagewise-io/stagewise
- **License**: AGPLv3
- **Mechanism**: 로컬 개발 서버(`npm run dev`)에 플로팅 툴바를 주입하여 IDE(Cursor, Windsurf 등)와 통신.
- **Click→Agent path**: 브라우저 툴바에서 요소 클릭 → WebSocket/로컬 서버로 IDE 확장 프로그램에 메타데이터 전송.
- **Captured payload**: DOM 구조, CSS(computed style), 소스 코드 파일 경로. 스크린샷 선택적 포함.
- **Agent integration**: Cursor, Windsurf 확장 프로그램.
- **Reusability for our project**: High. Source remapping(React/Vue 등의 플러그인 활용) 및 툴바 주입 패턴(overlay) 코드를 참고할 수 있음.
- **Reusable code/UI**: `setupToolbar` 로직 및 WebSocket 브리지 패턴 [https://github.com/stagewise-io/stagewise].
- **User satisfaction signals**: 코드를 복사/붙여넣기 할 필요 없이 브라우저에서 바로 요소를 지정할 수 있어 프론트엔드 작업 시간이 대폭 단축되었다는 평가 [https://dev.to/stagewise/building-a-visual-copilot-for-your-ide-4j1a].

#### 8. BrowserTools MCP
- **URL**: https://github.com/AgentDeskAI/browser-tools-mcp
- **License**: MIT
- **Mechanism**: Chrome 확장 프로그램 + 로컬 Node 서버 + MCP 서버 3단계 아키텍처.
- **Click→Agent path**: 확장 프로그램이 브라우저 이벤트를 캡처하여 MCP 서버로 전달.
- **Captured payload**: Console logs, Network traffic, DOM 요약 정보.
- **Agent integration**: MCP.
- **Reusability for our project**: Medium. 통신 브리지 아키텍처는 유용하나, 우리는 MCP를 쓰지 않으므로 파일/소켓 기반 브리지로 개조 필요.
- **Reusable code/UI**: Chrome extension content script에서 DOM/Network를 캡처하는 로직.
- **User satisfaction signals**: AI가 브라우저 에러 로그를 직접 볼 수 있어 환각(hallucination)이 줄었다는 긍정적 피드백.

#### 9. Puppeteer MCP Server
- **URL**: https://github.com/modelcontextprotocol/server-puppeteer
- **License**: MIT
- **Mechanism**: Headless Chrome을 원격 제어 (CDP).
- **Click→Agent path**: Agent가 Puppeteer API를 통해 DOM 쿼리 및 클릭 실행.
- **Captured payload**: 스크린샷, DOM 텍스트.
- **Agent integration**: MCP.
- **Reusability for our project**: Low. (사용자 클릭 → Agent 방향이 아니라, Agent → 브라우저 방향임).

#### 10. Playwright MCP Server (Microsoft)
- **URL**: https://github.com/microsoft/playwright-mcp
- **License**: MIT
- **Mechanism**: Playwright 기반 접근성 트리(Accessibility Tree) 스냅샷 활용.
- **Click→Agent path**: Agent가 접근성 트리를 읽고 요소 식별.
- **Captured payload**: Accessibility Tree (시각적 스크린샷 배제).
- **Agent integration**: MCP.
- **Reusability for our project**: Medium. DOM 전체 대신 접근성 트리를 payload로 사용하는 아이디어는 토큰 절약에 유효함.

#### 11. Cursor IDE (Browser Inspect)
- **URL**: https://cursor.com
- **License**: Proprietary
- **Mechanism**: Cursor Composer 내에서 로컬 서버를 프리뷰하고 브라우저 이벤트를 캡처.
- **Click→Agent path**: 자체 내장 브라우저/프리뷰어에서 클릭된 요소의 소스 매핑.
- **Captured payload**: 파일 경로, 줄 번호, 컴포넌트 트리.
- **Agent integration**: Native IDE integration.
- **Reusability for our project**: Low (소스 비공개).
- **User satisfaction signals**: 코드로 돌아갈 필요 없이 프리뷰에서 바로 에러나 요소를 지적할 수 있어 만족도가 매우 높음.

#### 12. Windsurf IDE (Cascade Browser)
- **URL**: https://codeium.com/windsurf
- **License**: Proprietary
- **Mechanism**: 내장 브라우저 통합.
- **Click→Agent path**: 브라우저 프리뷰와 소스 파일의 양방향 동기화.
- **Captured payload**: Source location, console.
- **Agent integration**: Native.
- **Reusability for our project**: Low.

### C. "기존 chrome extension + AI" 도구

#### 13. Builder.io Visual Copilot
- **URL**: https://builder.io
- **License**: Proprietary
- **Mechanism**: Figma 플러그인 및 Chrome 확장 프로그램으로 디자인/DOM을 코드로 변환.
- **Captured payload**: DOM 구조, Computed CSS.

#### 14. Chrome DevTools MCP
- **URL**: Local extension
- **Mechanism**: CDP(Chrome DevTools Protocol)를 통해 런타임 인사이트 획득.
- **Reusability for our project**: Medium. CDP를 활용한 DOM Node ID 추출 기법.

---

## Findings

### F1. 사용자 만족도가 가장 높은 payload 형태
- **발견**: 시각적 스크린샷보다 **Source Map 기반의 정확한 파일 경로 및 줄 번호 (Source Location) + Computed Style 결합**이 가장 만족도가 높았습니다. 스크린샷 기반(Vision)은 UI 구조를 묘사하는 데 한계가 있고, 환각으로 엉뚱한 코드를 수정하는 경우가 잦은 반면, Stagewise나 Cursor처럼 소스로 직접 매핑되는 방식은 수정의 정확도를 보장합니다.
- **근거**: Stagewise 데모 및 사용자 리뷰 [https://dev.to/stagewise/building-a-visual-copilot-for-your-ide-4j1a].
- **우리 설계에 반영해야 할 점**: Payload에 스크린샷을 배제하기로 한 5번 결정은 타당합니다. 대신 Reality Fingerprint에 React Fiber나 Vue devtools hook을 이용한 **컴포넌트 소스 위치 역매핑** 데이터가 최우선으로 포함되어야 합니다.

### F2. 가장 흔한 실패 패턴
1. **의도와 다른 파일 수정 (Drift)**: 여러 페이지에서 재사용되는 공통 컴포넌트(예: Button)를 클릭하여 수정 요청 시, 해당 페이지의 특정 인스턴스만 수정해야 하는데 공통 컴포넌트 전체를 수정해버려 다른 페이지가 망가지는 현상.
2. **동적 렌더링 요소 인식 불가**: 드롭다운 메뉴, 모달, 호버(hover) 상태 등 상호작용 후에만 DOM에 나타나는 요소에 대한 Inspect 실패.
3. **Shadow DOM / Iframe 접근 제한**: 서드파티 위젯이나 캡슐화된 스타일 내부 요소 포인팅 실패.
4. **난독화된 프로덕션 빌드**: Source map이 없는 환경에서 클릭한 DOM과 로컬 소스 코드를 연결하지 못함.
5. **과도한 컨텍스트로 인한 토큰 낭비**: 페이지 전체의 HTML을 캡처하여 Agent에게 전송할 경우, 정작 클릭한 요소의 맥락이 희석되거나 토큰 한도를 초과함.

### F3. NOT MCP 제약 하에서 재사용 가능한 패턴
- Stagewise의 로컬 툴바 주입 스크립트(Vite/Webpack 플러그인 형태) 및 WebSocket 통신 패턴은 MCP 없이도 브라우저와 로컬 Daemon 간 통신을 구현하는 데 직접적으로 재사용 가능합니다. 접근성 트리를 활용하는 Playwright MCP 패턴(토큰 절약)도 유용합니다.

### F4. "클릭 + 코멘트" UX vs "selector 복사" UX
- **발견**: "클릭하여 요소를 하이라이트한 뒤, 그 자리에서 바로 프롬프트를 입력(코멘트)"하는 UX(예: Stagewise, v0.dev)가 개발자들에게 압도적으로 선호됩니다. selector 문자열이나 xpath를 복사하여 채팅창에 붙여넣는 방식은 인지적 부하(cognitive load)가 큽니다.
- **근거**: Stagewise UI 철학 및 커뮤니티 피드백 분석.
- **우리 설계에 반영해야 할 점**: 브라우저 단에서 사용자의 텍스트 입력(user_intent)을 받아 payload와 함께 `clmux` 브리지로 넘기는 UI/UX 층이 필요합니다.

---

## 기존 결정 12개에 대한 검토

| # | 결정 | 검토 의견 | 근거 |
|---|---|---|---|
| 4 | Tool = 브리지 (분석기 아님) | **동의** | 브라우저 툴바에 AI 무거운 로직을 넣으면 성능이 저하됨. 브리지 역할(메타데이터 추출 후 전달)에 집중한 Stagewise 모델이 성공적. |
| 5 | 스크린샷 없음, payload 구성 | **강력 동의** | 시각적 스크린샷은 Vision 모델의 해석 오류를 유발할 수 있으며 토큰이 무거움. Playwright MCP가 접근성 트리를 쓰는 것처럼, 구조적 텍스트 데이터가 코드 수정에 훨씬 효과적. |
| 6 | 소스 코드 Read + drift 비교 | **동의** | 실패 패턴(F2)의 '공통 컴포넌트 전체 수정'을 방지하려면 단순히 DOM만 볼 게 아니라 실제 소스 파일의 호출 맥락을 Read하는 과정이 필수적임. |
| 7 | `clmux -b` 활성화 | **수정 제안** | 브라우저에 툴바를 주입하려면 프로세스 실행 시 뿐만 아니라 프론트엔드 번들러(Vite/Webpack) 레벨의 플러그인 연동이 필요할 수 있음. |
| 8 | Daemon + CLI 아키텍처 | **동의** | BrowserTools MCP의 아키텍처(Extension -> Local Server) 패턴과 일치하여 독립적인 브라우저-에이전트 통신에 적합함. |
