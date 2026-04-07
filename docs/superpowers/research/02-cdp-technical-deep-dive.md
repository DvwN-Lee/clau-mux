# R2 — Chrome DevTools Protocol 기술 심층 + Chrome 수명·권한

**담당**: codex-worker
**상태**: pending
**입력**: 00-INDEX.md
**산출 위치**: 이 파일

## Scope

CDP의 어떤 API를 어떻게 조합하면 우리 4-section payload(pointing / source_location / reality_fingerprint)를 신뢰성 있게 만들 수 있는지 기술 평가.

### Must-cover CDP API

| 도메인 | 메서드/이벤트 | 우리가 알아야 할 것 |
|---|---|---|
| Overlay | `setInspectMode`, `inspectNodeRequested`, `highlightNode`, `setShowHighlight*` | 사용자 클릭 캡처 가능? overlay UX는? |
| DOM | `getDocument`, `querySelector`, `getOuterHTML`, `describeNode`, `pushNodesByBackendIds` | element 식별·정보 추출 패턴 |
| CSS | `getMatchedStylesForNode`, `getInlineStylesForNode`, `getComputedStyleForNode`, `getBackgroundColors` | cascade winner / computed style 추출 |
| Page | `addScriptToEvaluateOnNewDocument`, `frameNavigated`, `lifecycleEvent` | overlay 주입 + SPA 라우팅 대응 |
| Runtime | `evaluate`, `callFunctionOn`, `addBinding` | 임의 JS 실행 + 양방향 통신 |
| Accessibility | `getFullAXTree`, `getPartialAXTree` | a11y 데이터 (선택적) |
| Target | `attachToTarget`, `setAutoAttach` | iframe / popup 처리 |

### Must-cover 기술 결정 포인트

1. **Inspect mode 진입**
   - `Overlay.setInspectMode("searchForNode" | "searchForUAShadowDOM" | "captureAreaScreenshot" | "showDistances", highlightConfig)` 의 모드별 차이
   - `inspectNodeRequested` 이벤트의 backendNodeId → DOM API 변환
   - vs 직접 주입한 overlay의 click capture (어느 것이 더 안정적?)

2. **Element → 정보 추출 경로**
   - backendNodeId → outerHTML, computed style, source location
   - cascade winner 추출 정확도 (`getMatchedStylesForNode`의 ruleMatch 배열)

3. **SPA route 변경 대응**
   - `Page.addScriptToEvaluateOnNewDocument`로 주입한 overlay가 client-side route 변경 시 살아남는가?
   - `Page.frameNavigated` / `Page.lifecycleEvent` 모니터링 필요?
   - History API hook 우회 필요?

4. **iframe / Shadow DOM**
   - Cross-origin iframe의 inspect 가능?
   - Shadow DOM piercing (`pierce` 옵션) 동작 방식

5. **Chrome 수명 관리**
   - `--remote-debugging-port=N --user-data-dir=...` 시작 패턴
   - profile 격리 (다른 Chrome 인스턴스와 충돌 회피)
   - daemon 시작 시 자동 launch + Chrome 종료 감지 + 재시작 정책
   - macOS에서 `Google Chrome.app` 실행 옵션 vs Chromium binary

6. **권한·보안**
   - `--remote-debugging-port` 노출 위험 (CVE 사례, mitigation: localhost only, random port, --remote-debugging-pipe?)
   - `--remote-debugging-pipe` 사용 시 트레이드오프
   - `--user-data-dir`로 프로필 격리하면 사용자 기존 Chrome과 분리되는데 cookie/login은? (개발 전용 가정 OK?)
   - extension 설치된 환경 vs 깨끗한 프로필

7. **Process lifecycle**
   - daemon이 죽으면 Chrome이 살아남나? (정책 결정)
   - Chrome이 죽으면 daemon은 어떻게 감지·재시작?
   - tmux 세션 종료 시 cleanup hook

8. **Playwright 통합**
   - 같은 Chrome 인스턴스를 daemon과 Playwright가 동시 사용 가능?
   - Playwright의 `connectOverCDP(endpoint)` 패턴
   - port conflict 가능성
   - teammate가 1차 검증 시 어떤 패턴이 가장 안정적?

## Output 형식

### 1. API 카드

각 CDP 메서드/이벤트별:

```markdown
## Overlay.setInspectMode

- **공식 문서**: <chromedevtools.github.io URL>
- **시그니처**: <params>
- **Stable since**: <Chrome version>
- **우리 use case 적합도**: high/medium/low
- **함정/주의사항**: ...
- **대안 API**: ...
- **샘플 호출 시퀀스** (의사코드):
  ```js
  ...
  ```
```

### 2. 기술 결정 권고

```markdown
## 결정 권고

### D1. Inspect mode 진입 방식
- **권고**: <CDP Overlay API / 직접 주입 overlay / 하이브리드>
- **이유**:
- **위험**:
- **대안 fallback**:

### D2. SPA route 대응
- **권고**: ...
...
```

### 3. Chrome 수명 관리 설계

```markdown
## Chrome lifecycle 설계

### Launch
- 명령:
- profile path:
- port 선택:

### Supervise
- health check 방법:
- 재시작 트리거:

### Shutdown
- daemon 종료 시 처리:
- 사용자가 Chrome 창 닫으면:
- tmux 세션 종료 hook:
```

### 4. 보안 평가

```markdown
## 보안 위험 매트릭스

| 위험 | 심각도 | mitigation |
|---|---|---|
| remote-debugging-port 외부 노출 | High | localhost bind + random port |
| ... | ... | ... |
```

### 5. brainstorming 결정사항 review

CDP 관점에서 12개 결정 검토. 특히 #7 (`-b` 플래그), #8 (background daemon), #10 (5-stage flow의 Chrome lifecycle 측면).

## 검색 키워드 힌트

- "chrome devtools protocol overlay inspect mode 2026"
- "CDP Page addScriptToEvaluateOnNewDocument SPA"
- "playwright connectOverCDP shared instance"
- "chrome remote-debugging-port security CVE"
- "chrome --user-data-dir isolation pattern"
- "CDP CSS getMatchedStylesForNode cascade"

## 완료 조건

- 모든 Must-cover API 카드 작성
- 8개 결정 포인트 모두 권고 + 근거
- Chrome lifecycle 설계 완성
- 보안 평가 표 작성
- 모든 주장 URL 인용 (Chrome DevTools Protocol 공식 docs 우선)
- 산출: 이 파일 갱신 + Lead에게 SendMessage로 완료 보고
