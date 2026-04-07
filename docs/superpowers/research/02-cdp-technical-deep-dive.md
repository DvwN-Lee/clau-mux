# R2 — Chrome DevTools Protocol 기술 심층 + Chrome 수명·보안

**담당**: codex-worker  
**상태**: completed  
**입력**: [00-INDEX.md](./00-INDEX.md)  
**최종 갱신**: 2026-04-07

## 결론 요약

- Browser Inspect Tool의 기본 경로는 **CDP Overlay inspect mode + DOM/CSS/Page/Runtime 조합**이 가장 적합하다.
- 클릭 캡처는 직접 주입 overlay보다 **`Overlay.setInspectMode` + `Overlay.inspectNodeRequested`**를 우선 권고한다. 이유는 Chrome이 이미 hit-test, UA shadow DOM, iframe 타깃 연결과 함께 제공하는 경로이기 때문이다. 공식 문서: https://chromedevtools.github.io/devtools-protocol/tot/Overlay/
- SPA 대응은 `Page.addScriptToEvaluateOnNewDocument`만으로 충분하지 않다. 초기 bootstrap에는 유효하지만, **client-side route 전환은 별도 감시**가 필요하다. 공식 문서: https://chromedevtools.github.io/devtools-protocol/tot/Page/
- cross-origin iframe / popup / worker까지 고려하면 **`Target.setAutoAttach({ autoAttach: true, flatten: true })` 기반의 session fan-out**이 필요하다. 공식 문서: https://chromedevtools.github.io/devtools-protocol/tot/Target/
- Chrome 실행은 **격리 프로필 + 랜덤 디버깅 포트 + 로컬 바인딩 + daemon supervised lifecycle**이 기본값이어야 한다.
- 보안상 `--remote-debugging-port`는 강력한 권한 채널이다. 2025년 Chrome 보안팀은 기본 프로필 대상 원격 디버깅 악용을 줄이기 위해 정책을 강화했고, **non-standard `--user-data-dir`를 함께 사용하지 않으면 기본 프로필에 대한 원격 디버깅이 차단**된다고 발표했다. 공식 블로그: https://developer.chrome.com/blog/remote-debugging-port
- Playwright는 같은 브라우저에 **`connectOverCDP`**로 붙을 수 있지만, 주 세션 소유자는 daemon이어야 한다. 검증 teammate는 attach-only 클라이언트로 제한하는 편이 안정적이다. 공식 문서: https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp

## 조사 범위와 핵심 해석

이 문서는 우리 도구의 4-section payload:

1. `user_intent`
2. `pointing`
3. `source_location`
4. `reality_fingerprint`

를 만들기 위해, CDP가 어디까지 직접 해결해 주고 어디부터는 별도 추론 계층이 필요한지를 정리한다.

핵심 해석:

- **`pointing`**: CDP가 매우 강하다. Overlay/DOM/CSS/Accessibility 조합으로 충분히 높은 신뢰도의 브라우저 현실 상태를 캡처할 수 있다.
- **`source_location`**: CDP 단독으로는 제한적이다. CSS rule source, frame URL, backend node lineage까지는 강하지만, React/Vue/Svelte 컴포넌트 원소스 역매핑은 별도 프레임워크/소스맵 계층이 필요하다.
- **`reality_fingerprint`**: CDP가 가장 적합하다. outerHTML, attributes, computed styles, matched CSS rules, AX snapshot, frame URL, viewport, scroll, DPR 등을 싸게 수집할 수 있다.

## API 카드

`Stable since`는 Chrome 버전 번호를 공식 문서가 직접 제공하지 않는 경우가 많아서, 이 문서에서는 다음처럼 표기한다.

- `stable 1.3`: stable protocol viewer `1-3`에도 존재
- `TOT`: tip-of-tree 문서에 존재
- `Experimental`: 공식 문서에 experimental 표기

정확한 최초 Chrome 버전은 공식 프로토콜 문서만으로는 일관되게 확인되지 않아, 해당 경우 추정하지 않았다.

## Overlay.setInspectMode

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#method-setInspectMode
- **시그니처**: `Overlay.setInspectMode(mode, highlightConfig?)`
- **Stable since**: `TOT`
- **우리 use case 적합도**: high
- **핵심**: 브라우저가 제공하는 inspect UX를 켜고, 사용자가 요소를 가리키고 클릭하게 만든다.
- **함정/주의사항**:
  - 선택 결과는 DOM `nodeId`가 아니라 보통 `backendNodeId` 기반 이벤트로 이어지므로 DOM 변환 단계가 추가된다.
  - overlay는 “우리 앱 DOM에 삽입된 요소”가 아니라 DevTools 레벨 시각화라서 앱 CSS와 충돌하지 않는 장점이 있다.
  - `searchForUAShadowDOM`는 UA shadow DOM까지 탐색한다. 일반 inspect에는 유용하지만 payload에 그대로 반영하면 너무 내부 구현적인 노드가 잡힐 수 있다.
- **대안 API**: DOM 이벤트 캡처용 사용자 스크립트 주입 + `Runtime.addBinding`
- **권고**: 기본 진입은 `searchForNode`; 필요할 때만 `searchForUAShadowDOM`
- **샘플 호출 시퀀스**:

```js
await cdp.send("Overlay.enable");
await cdp.send("DOM.enable");
await cdp.send("Overlay.setInspectMode", {
  mode: "searchForNode",
  highlightConfig: {
    showInfo: true,
    contentColor: { r: 111, g: 168, b: 220, a: 0.25 },
    borderColor: { r: 255, g: 153, b: 0, a: 0.8 },
    marginColor: { r: 246, g: 178, b: 107, a: 0.5 }
  }
});
```

## Overlay.inspectNodeRequested

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#event-inspectNodeRequested
- **시그니처**: event with `backendNodeId`
- **Stable since**: `TOT`
- **우리 use case 적합도**: high
- **핵심**: 사용자의 inspect click 결과를 받는 가장 직접적인 CDP 이벤트
- **함정/주의사항**:
  - 후속 처리에서 `DOM.pushNodesByBackendIdsToFrontend` 또는 `DOM.describeNode`가 필요하다.
  - auto-attach된 iframe/session에서는 **해당 session에서 받은 backendNodeId를 같은 session 문맥에서 해석**해야 안전하다.
- **대안 API**: 사용자 주입 스크립트에서 click target을 serialize 후 binding으로 전달
- **샘플 호출 시퀀스**:

```js
session.on("Overlay.inspectNodeRequested", async ({ backendNodeId }) => {
  const { nodeIds } = await session.send("DOM.pushNodesByBackendIdsToFrontend", {
    backendNodeIds: [backendNodeId]
  });
  const nodeId = nodeIds[0];
  // nodeId -> DOM/CSS/AX 수집
});
```

## Overlay.highlightNode

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Overlay/#method-highlightNode
- **시그니처**: `Overlay.highlightNode(highlightConfig, nodeId? backendNodeId? objectId? selector?)`
- **Stable since**: `TOT`
- **우리 use case 적합도**: high
- **핵심**: 사용자가 선택한 노드나 추천 후보를 다시 강조해 확인시키는 확인 단계에 적합
- **함정/주의사항**:
  - 영구 오버레이가 아니라 시각 강조용이다.
  - selection confirm UI를 자체 제작하지 않으면 클릭 직후 바로 사라지는 느낌이 날 수 있다.
- **대안 API**: DOM 내 고정 badge/tooltip 주입
- **샘플 호출 시퀀스**:

```js
await session.send("Overlay.highlightNode", {
  backendNodeId,
  highlightConfig: {
    showInfo: true,
    contentColor: { r: 64, g: 196, b: 99, a: 0.3 },
    borderColor: { r: 64, g: 196, b: 99, a: 0.9 }
  }
});
```

## DOM.getDocument

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getDocument
- **시그니처**: `DOM.getDocument(depth?, pierce?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: medium
- **핵심**: frame/session별 DOM 루트 확보
- **함정/주의사항**:
  - `pierce: true`는 iframe, shadow root, template contents까지 트리 관통을 허용하지만 비용이 커질 수 있다.
  - inspect click 기반 워크플로에서는 전체 트리를 항상 미리 가져올 필요는 없다.
- **대안 API**: `DOM.describeNode`, `DOM.pushNodesByBackendIdsToFrontend`
- **권고**: lazy strategy. 전체 preload보다 선택 후 국소 조회

## DOM.describeNode

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-describeNode
- **시그니처**: `DOM.describeNode(nodeId? backendNodeId? objectId? depth?, pierce?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: high
- **핵심**: backend node에서 최소 메타데이터를 빠르게 조회
- **함정/주의사항**:
  - 깊이를 키우면 subtree 비용이 늘어난다.
  - source code 위치를 주지 않는다. DOM 현실 위치만 준다.
- **대안 API**: `DOM.getOuterHTML`, `DOM.resolveNode`

## DOM.pushNodesByBackendIdsToFrontend

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-pushNodesByBackendIdsToFrontend
- **시그니처**: `DOM.pushNodesByBackendIdsToFrontend(backendNodeIds[])`
- **Stable since**: `TOT`
- **우리 use case 적합도**: high
- **핵심**: inspect 이벤트의 `backendNodeId`를 DOM `nodeId`로 승격하는 핵심 브리지
- **함정/주의사항**:
  - session/frame 문맥 불일치가 가장 큰 실패 원인이다.
  - node가 detach된 직후면 실패 가능성이 있다.
- **대안 API**: `DOM.describeNode(backendNodeId)`

## DOM.getOuterHTML

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/DOM/#method-getOuterHTML
- **시그니처**: `DOM.getOuterHTML(nodeId? backendNodeId? objectId?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: high
- **핵심**: payload의 `pointing.element_html` 또는 `reality_fingerprint.html_excerpt` 생성용
- **함정/주의사항**:
  - 지나치게 크면 토큰 비용이 급증한다.
  - 동적 속성이나 inline style이 들어가므로 민감정보 마스킹이 필요하다.
- **대안 API**: `DOM.getAttributes`, `DOM.describeNode`
- **권고**: raw 전체 보관 + teammate inbox에는 truncation/마스킹된 excerpt

## CSS.getMatchedStylesForNode

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/CSS/#method-getMatchedStylesForNode
- **시그니처**: `CSS.getMatchedStylesForNode(nodeId)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: high
- **핵심**: author styles, inline styles, inherited rules, pseudo element rules까지 받아 cascade 설명력을 높인다.
- **함정/주의사항**:
  - 이것만으로 “최종 winner”를 완전히 계산하려면 selector specificity, origin, importance, order를 후처리해야 한다.
  - 이미 최종값만 필요하면 `getComputedStyleForNode`가 더 직접적이다.
  - 스타일 소스는 `rule.styleSheetId`, `sourceURL`, `range` 등을 통해 CSS 파일 위치를 추적할 수 있지만, 컴포넌트 원본 파일 역매핑은 별도 문제다.
- **대안 API**: `CSS.getComputedStyleForNode`, `CSS.getInlineStylesForNode`
- **권고**: `computed style`와 함께 수집. reasoning-friendly payload를 만들려면 둘 다 필요
- **샘플 호출 시퀀스**:

```js
const matched = await session.send("CSS.getMatchedStylesForNode", { nodeId });
const computed = await session.send("CSS.getComputedStyleForNode", { nodeId });
// computed -> 현재 현실
// matched  -> 왜 그렇게 되었는지 설명
```

## Page.addScriptToEvaluateOnNewDocument

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-addScriptToEvaluateOnNewDocument
- **시그니처**: `Page.addScriptToEvaluateOnNewDocument(source, worldName?, includeCommandLineAPI?, runImmediately?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: medium-high
- **핵심**: 문서 생성 시점마다 bootstrap 스크립트를 삽입한다.
- **함정/주의사항**:
  - **full navigation / new document**에는 강하지만, SPA의 History API route 전환은 새 document가 아니므로 이것만으로는 부족하다.
  - isolated world를 쓰면 앱 전역 변수와 격리되지만, 앱 내부 상태 접근성이 줄어든다.
  - `runImmediately`는 기존 world에도 즉시 실행하게 해 주지만, 이미 로드된 frame들 전체를 완전히 동기화하는 마법은 아니다.
- **대안 API**: `Runtime.evaluate`, in-page bootstrap loader
- **권고**: 초기 bootstrap + binding 설치용으로 사용하고, inspect UX 자체는 Overlay 우선

## Page.frameNavigated

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-frameNavigated
- **시그니처**: event with `frame`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: high
- **핵심**: full navigation, iframe navigation 감지
- **함정/주의사항**:
  - SPA route 전환은 대부분 여기서 잡히지 않는다.
  - frame tree를 유지하려면 `frameAttached`, `frameDetached`도 함께 보는 편이 낫다.
- **대안 API**: injected History API hook + `Runtime.addBinding`

## Page.lifecycleEvent

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Page/#event-lifecycleEvent
- **시그니처**: event with `frameId`, `loaderId`, `name`, `timestamp`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: medium
- **핵심**: `DOMContentLoaded`, `load`, network-idle 계열 lifecycle 신호를 frame 단위로 받는다.
- **함정/주의사항**:
  - SPA route 변경 자체를 표준적으로 보장하지 않는다.
  - hydration 이후 앱 내부 라우터 완료 시점과 반드시 일치하지 않는다.
- **대안 API**: injected route hook, DOM mutation debounce
- **권고**: “새 문서가 충분히 안정화됐는지”를 보는 보조 신호로만 사용

## Runtime.evaluate

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-evaluate
- **시그니처**: `Runtime.evaluate(expression, contextId? uniqueContextId?, returnByValue?, awaitPromise?, userGesture?, ...)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: high
- **핵심**: DOM에서 바로 얻기 어려운 데이터를 현장 계산하는 만능 도구
- **함정/주의사항**:
  - `contextId`는 재사용될 수 있어 navigation/cross-process 뒤 혼선이 생길 수 있다. 공식 문서는 `uniqueContextId`가 더 안전하다고 명시한다.
  - return-by-value는 대형 객체에 비용이 크다.
  - 앱 side effect를 일으키지 않는 순수 expression만 허용해야 한다.
- **대안 API**: `Runtime.callFunctionOn`, DOM/CSS 전용 메서드
- **권고**: 최소화해서 사용. DOM/CSS 메서드가 있는 데이터는 전용 API 우선

## Runtime.addBinding

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Runtime/#method-addBinding
- **시그니처**: `Runtime.addBinding(name, executionContextId? executionContextName?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: high
- **핵심**: 페이지 스크립트가 daemon으로 메시지를 푸시할 수 있게 한다.
- **함정/주의사항**:
  - 공식 문서는 `executionContextId` 대신 `executionContextName` 사용을 권장한다.
  - 바인딩 이름은 전역 namespace 오염을 피하도록 고유 prefix가 필요하다.
  - cross-frame 환경에서는 각 context에 설치 여부를 명확히 관리해야 한다.
- **대안 API**: console 이벤트 가로채기, DOM event polling
- **권고**: direct overlay fallback, SPA History hook, in-page confirm UI가 필요할 때만 사용
- **샘플 호출 시퀀스**:

```js
await session.send("Runtime.addBinding", {
  name: "__clmuxInspectEmit",
  executionContextName: "clmux-inspect"
});

await session.send("Page.addScriptToEvaluateOnNewDocument", {
  worldName: "clmux-inspect",
  source: `
    globalThis.__clmuxBridge = (payload) =>
      globalThis.__clmuxInspectEmit(JSON.stringify(payload));
  `
});
```

## Accessibility.getPartialAXTree

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Accessibility/#method-getPartialAXTree
- **시그니처**: `Accessibility.getPartialAXTree(nodeId? backendNodeId? objectId?, fetchRelatives?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: medium-high
- **핵심**: 선택 요소의 role/name/state를 얻어, 사람이 보는 의미 레이어를 payload에 추가
- **함정/주의사항**:
  - AX tree는 DOM tree와 1:1이 아니다.
  - 토큰 비용 대비 효과를 위해 full tree보다 partial tree가 적절하다.
- **대안 API**: `Accessibility.getFullAXTree`
- **권고**: 기본값은 partial tree 1-hop

## Accessibility.getFullAXTree

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Accessibility/#method-getFullAXTree
- **시그니처**: `Accessibility.getFullAXTree(depth?, frameId?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: low-medium
- **핵심**: 전체 a11y 구조 분석용
- **함정/주의사항**:
  - 비용이 높고 inspect payload에는 과하다.
  - teammate의 정밀 분석 모드에서만 옵션으로 적합
- **대안 API**: `getPartialAXTree`

## Target.attachToTarget

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Target/#method-attachToTarget
- **시그니처**: `Target.attachToTarget(targetId, flatten?)`
- **Stable since**: stable `1.3`
- **우리 use case 적합도**: medium
- **핵심**: 특정 page/iframe/worker target에 직접 session을 붙인다.
- **함정/주의사항**:
  - 수동 attach만으로는 새 iframe/popup를 놓친다.
  - modern client는 대체로 `setAutoAttach(flatten: true)` 중심이 더 적합하다.
- **대안 API**: `Target.setAutoAttach`

## Target.setAutoAttach

- **공식 문서**: https://chromedevtools.github.io/devtools-protocol/tot/Target/#method-setAutoAttach
- **시그니처**: `Target.setAutoAttach(autoAttach, waitForDebuggerOnStart, flatten, filter?)`
- **Stable since**: stable `1.3`, `filter`는 Experimental
- **우리 use case 적합도**: high
- **핵심**: 관련 타깃(iframe, worker 등)에 자동으로 attach하고 session fan-out을 유지한다.
- **함정/주의사항**:
  - 공식 문서는 “재귀적으로 호출해 모든 auto-attached target에 attach할 수 있다”고 설명한다. 즉, 한 번만 켜서 모든 하위 target 문제가 끝나는 구조로 보면 위험하다.
  - `waitForDebuggerOnStart: true`는 앱을 멈출 수 있으므로 inspect tool에서는 기본 false가 맞다.
  - popup까지 추적 범위를 넓히면 세션 관리가 복잡해진다.
- **대안 API**: polling + attachToTarget
- **권고**: `flatten: true`, page/iframe 우선 필터

## 추천 수집 파이프라인

```js
// browser root
Target.setDiscoverTargets({ discover: true });
Target.setAutoAttach({
  autoAttach: true,
  waitForDebuggerOnStart: false,
  flatten: true
});

// per attached page/frame session
DOM.enable();
CSS.enable();
Overlay.enable();
Page.enable();
Runtime.enable();
Accessibility.enable?.(); // domain 특성상 메서드 없는 경우 생략

Overlay.setInspectMode({ mode: "searchForNode", highlightConfig });

onInspectNodeRequested(async ({ backendNodeId }, session) => {
  const { nodeIds } = await session.send("DOM.pushNodesByBackendIdsToFrontend", {
    backendNodeIds: [backendNodeId]
  });
  const nodeId = nodeIds[0];

  const [outer, desc, matched, computed, ax] = await Promise.all([
    session.send("DOM.getOuterHTML", { nodeId }),
    session.send("DOM.describeNode", { nodeId, depth: 1, pierce: true }),
    session.send("CSS.getMatchedStylesForNode", { nodeId }),
    session.send("CSS.getComputedStyleForNode", { nodeId }),
    session.send("Accessibility.getPartialAXTree", {
      nodeId,
      fetchRelatives: true
    })
  ]);

  writeInbox({
    user_intent,
    pointing: buildPointing(desc.node, outer.outerHTML),
    source_location: deriveSourceLocation(desc.node, matched),
    reality_fingerprint: buildRealityFingerprint(computed, matched, ax)
  });
});
```

## 8개 기술 결정 권고

## D1. Inspect mode 진입 방식

- **권고**: **CDP Overlay 우선, Runtime binding fallback 보조**의 하이브리드
- **이유**:
  - Overlay는 앱 DOM을 오염시키지 않는다.
  - 브라우저 내장 hit-test를 사용하므로 z-index, pointer-events, transformed element 같은 edge case에서 직접 overlay보다 덜 취약하다.
  - user click 결과가 `backendNodeId`로 바로 이어진다.
- **위험**:
  - overlay 이벤트가 target/session 맥락에 민감하다.
  - 사용자 정의 confirm UX는 추가 주입이 필요할 수 있다.
- **대안 fallback**:
  - binding + injected click capture를 켜서 브라우저/사이트 특이 케이스만 우회

## D2. Element → 정보 추출 경로

- **권고**:
  1. `inspectNodeRequested.backendNodeId`
  2. `DOM.pushNodesByBackendIdsToFrontend`
  3. `DOM.describeNode` + `DOM.getOuterHTML`
  4. `CSS.getMatchedStylesForNode` + `CSS.getComputedStyleForNode`
  5. `Accessibility.getPartialAXTree`
- **이유**:
  - backend node는 선택 시점 정체성을 잘 유지한다.
  - computed와 matched를 함께 가져가야 “지금 보이는 결과”와 “왜 그렇게 됐는지”를 같이 설명할 수 있다.
- **주의**:
  - `source_location`은 CSS source까지는 좋지만 컴포넌트 원본 파일은 별도 remapping 계층 필요

## D3. SPA route handling

- **권고**: `Page.addScriptToEvaluateOnNewDocument` + **in-page History API / Navigation API hook** + `Page.frameNavigated` 병행
- **이유**:
  - `addScriptToEvaluateOnNewDocument`는 full navigation/new frame bootstrap에 적합
  - SPA route 변화는 새 document가 아니므로 page event만으로 부족
  - route change 직후 inspect 상태 재동기화, stale target cleanup, URL 갱신이 필요
- **위험**:
  - framework router마다 동작 타이밍이 다르다.
- **대안 fallback**:
  - route hook이 실패하면 periodic URL/title poll

## D4. iframe / Shadow DOM 처리

- **권고**: `Target.setAutoAttach(flatten: true)` 기반으로 frame session을 분리 관리하고, DOM 조회는 필요 시 `pierce: true` 사용
- **이유**:
  - cross-origin iframe은 같은 JS world로 직접 주입할 수 없지만, CDP target/session attach로는 관찰 가능하다.
  - shadow DOM은 DOM API의 `pierce` 옵션과 Overlay inspect가 결합될 때 다루기 쉽다.
- **위험**:
  - UA shadow DOM까지 무분별하게 허용하면 payload 품질이 떨어질 수 있다.
- **정책**:
  - 기본은 author DOM 우선
  - “브라우저 내장 컨트롤 포함 inspect”가 필요한 진단 모드에서만 UA shadow DOM 허용

## D5. Chrome lifecycle: launch / supervise / shutdown

- **권고**: daemon이 Chrome을 **직접 launch하고 PID를 소유**해야 한다.
- **이유**:
  - lifecycle이 명확하다.
  - orphan Chrome, 포트 충돌, 프로필 충돌을 줄인다.
  - tmux/lead 세션과 수명을 맞추기 쉽다.
- **위험**:
  - 사용자가 수동으로 띄운 Chrome과 혼동될 수 있다.
- **대안 fallback**:
  - 기존 Chrome attach 모드는 개발용 고급 옵션으로만 제공

## D6. 보안 모델

- **권고**: `--remote-debugging-port=0` + `--user-data-dir=<isolated-dir>` + localhost only + 권한 0700 디렉터리
- **이유**:
  - random port는 예측 가능성을 낮춘다.
  - 격리 프로필은 기본 사용자 프로필 쿠키 탈취 위험과 충돌을 줄인다.
  - Chrome 보안팀 권고도 기본 프로필 대신 별도 user-data-dir 사용이다.
- **위험**:
  - 로그인 상태가 비어 있다.
- **정책**:
  - 도구 목적상 “개발 전용 프로필”을 기본 전제
  - 기존 사용자 로그인 컨텍스트 공유는 기본 비지원

## D7. `--remote-debugging-port` vs `--remote-debugging-pipe`

- **권고**: 기본은 **`--remote-debugging-port=0`**, pipe는 2단계 최적화 옵션
- **이유**:
  - Playwright `connectOverCDP`와 다중 클라이언트 연결은 websocket endpoint 기반 포트 모델이 가장 호환성이 높다.
  - `remote-debugging-pipe`는 TCP 노출을 줄이지만, attach ecosystem이 좁아지고 외부 도구 연동성이 떨어진다.
- **위험**:
  - port 모델은 로컬 악성 프로세스 노출면이 있다.
- **대안 fallback**:
  - 단일 프로세스 통제형 배포에서만 pipe 모드 제공

## D8. Playwright 통합 패턴

- **권고**: daemon이 브라우저를 띄우고, 검증 teammate는 **`connectOverCDP(endpoint)` attach-only client**로 접속
- **이유**:
  - 브라우저 소유권이 단일화된다.
  - inspect daemon이 CDP root 세션과 overlay/session registry를 유지하고, Playwright는 페이지 조작만 수행한다.
  - Playwright 공식 문서도 CDP 연결은 Chromium 기반 원격 디버깅 엔드포인트를 대상으로 한다.
- **위험**:
  - Playwright는 자체 launch 대비 fidelity가 낮다고 문서에서 밝힌다.
  - 여러 클라이언트가 같은 target을 건드리면 race가 생긴다.
- **운영 규칙**:
  - daemon만 Overlay/Target lifecycle 담당
  - Playwright는 테스트 액션 전용
  - 서로 다른 tool이 `Page.navigate`, `Runtime.evaluate`를 동시에 남용하지 않도록 세션 역할 분리

## Chrome lifecycle 설계

## Launch

- **명령 예시**:

```bash
open -na "Google Chrome" --args \
  --remote-debugging-port=0 \
  --user-data-dir=/tmp/clmux-browser-inspect/profile \
  --no-first-run \
  --no-default-browser-check \
  --disable-background-networking \
  --disable-component-update \
  --disable-sync \
  --new-window about:blank
```

- **이유**:
  - `--remote-debugging-port=0`는 사용 가능한 임의 포트를 고르게 한다.
  - Chrome은 선택된 포트를 `DevToolsActivePort` 파일에 기록한다. 이를 읽어 websocket endpoint를 찾는 방식이 안정적이다. 관련 공식 자료: https://developer.chrome.com/docs/devtools/remote-debugging/local-server
  - `--user-data-dir`은 격리 필수
- **profile path**:
  - 기본: `${XDG_STATE_HOME:-~/.local/state}/clau-mux/browser-inspect/chrome-profile`
  - macOS 권고: `~/Library/Application Support/clau-mux/browser-inspect/chrome-profile`
  - 세션 단위 임시 프로필도 가능하나, inspect tool은 재현성 때문에 “workspace별 지속 프로필”이 더 낫다.
- **port 선택**:
  - 명시 포트보다 `0` 권고
  - daemon은 `DevToolsActivePort` poll 후 endpoint 확정

## Supervise

- **health check 방법**:
  - PID 생존 여부 확인
  - websocket root session ping
  - 주기적 `Target.getTargets` 또는 lightweight command
- **재시작 트리거**:
  - Chrome 프로세스 종료
  - websocket disconnect
  - `DevToolsActivePort` 사라짐
- **재시작 정책**:
  - 1차: 즉시 1회
  - 2차 이후: exponential backoff
  - 반복 실패 임계치 초과 시 lead에게 경고 후 자동 중지
- **세션 재구성**:
  - browser reconnect
  - `Target.setDiscoverTargets`
  - `Target.setAutoAttach`
  - page/frame session re-enable
  - overlay mode 복구

## Shutdown

- **daemon 종료 시 처리**:
  - 기본 정책: daemon이 띄운 Chrome도 함께 종료
  - 브라우저가 살아남으면 격리 프로필 락, 포트 잔존, 고아 세션 문제가 생긴다.
- **사용자가 Chrome 창 닫으면**:
  - daemon은 종료 이벤트를 감지하고 자동 재시작 여부를 정책에 따라 결정
  - inspect active session 중이었다면 inbox에 “browser_restarted” 같은 진단 이벤트 남길 가치가 있다.
- **tmux 세션 종료 hook**:
  - lead-hosted background daemon이므로 lead 프로세스 종료 시 cleanup handler에서 Chrome terminate
  - 정상 종료 grace period 후 강제 kill

## 운영 정책 권고

- Chrome 소유자: daemon
- CDP root owner: daemon
- overlay owner: daemon
- teammate verifier: Playwright attach-only
- user 수동 Chrome attach: 기본 비권장

## payload 설계 관점의 CDP 매핑

## `user_intent`

CDP가 직접 제공하지 않는다. lead/teammate 대화 문맥 또는 inspect 시작 시 입력값으로 별도 수집해야 한다.

권고 필드:

- `task_summary`
- `expected_change`
- `user_freeform_note`

## `pointing`

CDP 직접 생성 가능:

- frame URL / frameId
- backendNodeId / nodeId
- tagName
- id / class list / attributes
- outerHTML excerpt
- box model highlight 대상
- AX role/name

## `source_location`

CDP 단독으로 직접적이지 않다. 권고 필드:

- `document_url`
- `frame_url`
- `css_sources[]`
  - `styleSheetId`
  - `sourceURL`
  - `range`
  - matched selector text
- `dom_path`
- `backend_node_id`
- `framework_mapping_status`
  - `direct_cdp_only` / `remapped_via_sourcemap` / `unknown`

핵심 판단:

- CSS source까지는 CDP가 강하다.
- JSX/TSX/SFC 원본 줄번호까지는 R4 소스 역매핑 계층과 결합해야 한다.

## `reality_fingerprint`

최소 권고 필드:

- `outer_html_excerpt`
- `computed_style_subset`
  - `display`
  - `position`
  - `width`
  - `height`
  - `color`
  - `background-color`
  - `font-size`
  - `font-weight`
  - `opacity`
  - `z-index`
  - `visibility`
  - `pointer-events`
- `matched_rules_subset`
- `bounding_box`
- `scroll_offsets`
- `viewport`
- `device_pixel_ratio`
- `ax_role_name`

## 보안 위험 매트릭스

| 위험 | 심각도 | 설명 | mitigation |
|---|---|---|---|
| `remote-debugging-port` 외부 노출 | High | 디버깅 포트는 페이지 제어, 스크립트 실행, 쿠키 접근에 직결될 수 있는 고권한 채널 | localhost only, random port, firewall 의존 금지, 사용자에게 endpoint 노출 금지 |
| 기본 Chrome 프로필에 attach | High | 기존 로그인 세션/쿠키/저장 비밀이 노출될 수 있음 | 항상 별도 `--user-data-dir`, 기본 프로필 attach 비활성화 |
| DevTools endpoint 유출 | High | 로컬 다른 프로세스가 websocket endpoint를 재사용 가능 | endpoint 파일 권한 제한, 짧은 수명, lead-only ownership |
| payload 내 민감정보 유출 | High | outerHTML, attributes, inline style에 토큰/PII가 섞일 수 있음 | 속성 allowlist/denylist, text truncation, secret regex redaction |
| 다중 CDP 클라이언트 race | Medium | Playwright와 daemon이 동시에 navigate/evaluate하면 상태 왜곡 | 세션 역할 분리, write-capable 명령 ownership 제한 |
| 자동 재시작 loop | Medium | crash-restart 반복으로 리소스 고갈 | backoff, retry cap, alert |
| extension/오염된 프로필 영향 | Medium | 확장 프로그램이 DOM/CSS/네트워크를 바꿀 수 있음 | 깨끗한 전용 프로필 기본값, extension disabled baseline |
| cross-origin iframe 처리 오판 | Medium | 같은 페이지처럼 취급하면 frame provenance가 섞일 수 있음 | frame/session 명시, payload에 frame URL 별도 기록 |
| in-page injected script 남용 | Medium | Runtime 평가가 앱 state를 깨뜨릴 수 있음 | read-only helper만 허용, side-effect-free policy |
| 고아 Chrome 프로세스 | Low-Medium | 종료 후 프로필 lock/포트 잔존 | daemon-owned shutdown, PID tracking |

## `--remote-debugging-port` 보안 메모

- Chrome DevTools 문서는 remote debugging을 통해 다른 Chrome instance를 검사하는 워크플로를 공식적으로 설명한다. 참고: https://developer.chrome.com/docs/devtools/remote-debugging/local-server
- 2025년 Chrome 보안팀은 infostealer가 원격 디버깅을 악용하는 흐름을 줄이기 위해, **기본 데이터 디렉터리를 대상으로 한 `--remote-debugging-port` / `--remote-debugging-pipe` 동작을 제한**하고, 개발자는 **반드시 non-standard `--user-data-dir`를 함께 사용**하라고 안내했다. 공식 블로그: https://developer.chrome.com/blog/remote-debugging-port

설계 영향:

- 우리 도구의 기본 설계는 이미 별도 프로필이므로 보안 방향성과 일치한다.
- “내가 쓰던 크롬 세션 그대로 inspect” 요구는 보안상 기본 지원하면 안 된다.

## Playwright 통합 평가

공식 문서: https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp

핵심 포인트:

- Playwright는 Chromium 브라우저에 CDP로 접속 가능하다.
- 문서는 이 연결이 Playwright의 기본 protocol 연결보다 fidelity가 낮다고 명시한다.
- 따라서 Browser Inspect Tool의 주 제어 plane을 Playwright로 두기보다, **CDP daemon이 주체이고 Playwright는 보조 검증자**여야 한다.

권고 패턴:

1. daemon launches Chrome
2. daemon reads `DevToolsActivePort`
3. daemon owns root websocket
4. verifier teammate uses `connectOverCDP(endpoint)`
5. verifier는 page actions/testing만 수행
6. overlay, target auto-attach, payload capture는 daemon 전담

## 브레인스토밍 결정사항 리뷰

## #7 `clmux -b` 신규 플래그

- **평가**: 유지 권고
- **이유**:
  - browser inspect는 일반 세션과 별도 수명/보안 모델을 가지므로 opt-in 플래그가 적절
  - 시작 시 Chrome launch + daemon bootstrap + subscriber setup을 묶기 좋다
- **보완**:
  - `-b`는 “격리 Chrome 프로필을 띄운다”는 의미를 문서에 명시해야 한다.

## #8 Lead-hosted background daemon

- **평가**: 강하게 유지 권고
- **이유**:
  - CDP ownership, lifecycle supervision, inbox file write 모두 daemon 모델이 가장 맞다.
  - MCP가 아닌 파일 브리지 모델과도 잘 맞는다.
- **보완**:
  - daemon만 Chrome launch/kill 권한 보유
  - teammate는 attach-only

## #10 5-stage flow

- **평가**: 유지 가능, 단 Chrome lifecycle 규약 추가 필요
- **필수 보완**:
  - stage 간 브라우저를 재사용할지 여부
  - 재사용 시 동일 profile/session을 유지할지 여부
  - 1차 검증 teammate와 lead가 동시에 같은 페이지를 만질 때 command ownership 규약

권고:

- 같은 inspect session에서는 브라우저 재사용
- stage 경계에서는 “write actor”를 1명으로 제한
- inspect payload는 immutable event log처럼 inbox에 append

## 최종 권고 아키텍처

```text
Lead process
  -> launches browser-inspect daemon
    -> launches isolated Chrome (--remote-debugging-port=0, --user-data-dir=...)
    -> owns CDP root connection
    -> auto-attaches page/frame targets
    -> enables Overlay inspect mode
    -> on click:
       backendNodeId
         -> DOM/CSS/AX hydration
         -> payload synthesis
         -> write teammate inbox file
  -> verifier teammate optionally attaches with Playwright connectOverCDP
```

## 최종 추천

1. **inspect capture는 Overlay-first**
2. **DOM/CSS/AX 조합으로 pointing + reality_fingerprint 구성**
3. **source_location은 “CDP direct + later remap” 2단계 모델로 정의**
4. **SPA는 new-document injection만 믿지 말고 route hook 추가**
5. **iframe/popup은 Target auto-attach flatten 구조 채택**
6. **Chrome은 daemon이 직접 띄우고 직접 죽인다**
7. **보안 기본값은 isolated profile + random port**
8. **Playwright는 보조 검증 클라이언트로만 사용**

## 주요 출처

- Chrome DevTools Protocol Overlay domain: https://chromedevtools.github.io/devtools-protocol/tot/Overlay/
- Chrome DevTools Protocol DOM domain: https://chromedevtools.github.io/devtools-protocol/tot/DOM/
- Chrome DevTools Protocol CSS domain: https://chromedevtools.github.io/devtools-protocol/tot/CSS/
- Chrome DevTools Protocol Page domain: https://chromedevtools.github.io/devtools-protocol/tot/Page/
- Chrome DevTools Protocol Runtime domain: https://chromedevtools.github.io/devtools-protocol/tot/Runtime/
- Chrome DevTools Protocol Accessibility domain: https://chromedevtools.github.io/devtools-protocol/tot/Accessibility/
- Chrome DevTools Protocol Target domain: https://chromedevtools.github.io/devtools-protocol/tot/Target/
- Chrome DevTools, remote debugging local server guide: https://developer.chrome.com/docs/devtools/remote-debugging/local-server
- Chrome for Developers blog, remote debugging switch hardening: https://developer.chrome.com/blog/remote-debugging-port
- Playwright `connectOverCDP`: https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp
