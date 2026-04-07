# Browser Inspect Tool — Design Spec

**상태**: Draft (R5 synthesis 반영 완료 — implementation-ready)
**작성일**: 2026-04-07
**최종 업데이트**: 2026-04-08 (R5 synthesis)
**브랜치**: feat/browser-inspect-research
**Worktree**: .worktrees/feat-browser-inspect

> 이 spec은 brainstorming 결과 + R1~R5 research 결과를 종합해 작성됐습니다.
> R5 synthesis 반영 완료. 신규 필드, 위험 항목, 참고 문헌 추가됨.

## 1. Motivation

Claude Code 기반 frontend 개발 시 가장 자주 발생하는 문제는 사용자의 의도와 다른 코드가 만들어지는 것이고, 이를 수정할 때 사용자가 "이 페이지 마음에 안 들어" 같은 모호한 프롬프트에 의존해야 한다는 점이다. 사용자가 개발자 모드에서 직접 태그를 복사·붙여넣기하는 우회 패턴은 번거롭고 오류가 잦다.

이 spec은 다음을 가능하게 한다:

1. 사용자가 브라우저에서 결과물을 확인하면서 마음에 들지 않는 요소를 **inspect mode + click**으로 직접 가리킨다
2. 가리킨 요소의 정보가 **인계받은 teammate(또는 Lead)의 입력으로 자동 주입**된다
3. 주입받은 agent는 **소스 코드를 직접 Read**해서 의도와 실제 렌더 결과 사이의 drift를 분석한다
4. 사용자의 짧은 코멘트("padding 이상")를 의도 신호로 결합해 코드 수정 방향을 결정한다

## 2. Non-goals

- LLM에게 시각적(스크린샷 기반) 판단을 요구하지 않는다
- MCP 통합을 사용하지 않는다
- 본 도구는 분석기가 아니라 **pointing bridge + source remapper + reality fingerprinter**이다
- 풀-페이지 visual regression은 별개 트랙(Playwright)에서 처리

## 3. Constraints

| # | 제약 | 근거 |
|---|---|---|
| C1 | macOS + tmux + zsh + iTerm2 환경 전제 | clau-mux 기존 제약 |
| C2 | NOT MCP — CLI + 파일 브리지만 사용 | 사용자 명시 |
| C3 | 스크린샷·이미지 데이터를 payload에 포함하지 않음 | LLM 시각 처리 약점 회피 |
| C4 | Lead 세션과 수명 동조하는 background 프로세스 모델 | clau-mux 패턴 일관성 |
| C5 | 분석은 항상 소스 Read 기반 | LLM 강점 활용 |
| C6 | Chrome launch 시 `--remote-debugging-port=0 --user-data-dir=<isolated-dir>` 필수 조합; 기본 Chrome profile 사용 금지 | 2025 Chrome 보안 mandate (infostealer 취약점); port는 `DevToolsActivePort` 파일 poll로 발견 (R2, NEW-4) |

## 4. Decisions (brainstorming-confirmed + R5 amendments)

| # | 결정 | 값 | R5 Status |
|---|---|---|---|
| 1 | 산출물 | 설계 spec 단일 | confirmed |
| 2 | 구현 방식 | Lead-hosted background daemon + CLI tool | confirmed |
| 3 | MCP 사용 | 금지 | confirmed |
| 4 | Tool 역할 | Pointing + Source Remapping + Reality Fingerprint 브리지 | confirmed |
| 5 | Payload | user_intent / pointing / source_location / reality_fingerprint | **amended** — payload 확장 (see R5, Section 6) |
| 6 | Agent 분석 방식 | 소스 코드 Read + drift 비교 | confirmed |
| 7 | 활성화 | `clmux -b` 신규 플래그 (또는 `clmux-browser -t`); -b는 isolated Chrome profile launch를 의미 | confirmed-with-note |
| 8 | 프로세스 모델 | background Node daemon (Copilot MCP 서버 패턴 복제) | **amended** — SPA navigation handling 추가: History API hook + Page.frameNavigated (see R5) |
| 9 | 구독 모델 | `.inspect-subscriber` 파일 기반, `clmux-inspect subscribe`로 전환 | confirmed — R3 WebSocket 제안 rejected (see R5 Section 7) |
| 10 | 5-stage flow | Implement → 1차검증(teammate) → 2차검증(Lead active) → 3차검증(user passive→Lead) → 재작업 | confirmed-with-note: (1) 같은 session 내 browser reuse, (2) stage boundary마다 write actor 1명, (3) payload append-only |

## 5. Architecture (skeleton)

```
tmux session
├── Lead pane (Claude Code)
├── teammate pane(s) (Gemini, Sonnet teammate, …)

Background (Lead 세션 수명 동조, headless)
├── Chrome (--remote-debugging-port=N --user-data-dir=...)
└── browser-service (Node.js daemon)
    ├── Chrome CDP 연결 소유
    ├── Page.addScriptToEvaluateOnNewDocument로 overlay 주입
    ├── 구독 상태 파일 감시 (~/.claude/teams/$team/.inspect-subscriber)
    ├── 로컬 HTTP/Unix socket 엔드포인트 (CLI 통신용)
    ├── Source 역매핑 로직
    ├── Reality fingerprint 수집 로직
    └── 클릭 이벤트 → subscriber inbox에 JSON append

CLI: clmux-inspect (PATH)
├── subscribe <agent>
├── unsubscribe
├── query <selector> <props...>
├── snapshot <selector>
└── status

파일 (clau-mux 규약)
├── ~/.claude/teams/$team/.browser-service.pid
├── ~/.claude/teams/$team/.browser-service.port
├── ~/.claude/teams/$team/.inspect-subscriber
├── ~/.claude/teams/$team/inboxes/{agent}.json  (기존 brigde 재사용)
└── /tmp/clmux-browser-service-$team.log
```

## 6. Payload Format (working draft)

```json
{
  "user_intent": "padding이 이상해",
  "pointing": {
    "selector": "main > .grid > div.card:nth-child(3)",
    "outerHTML": "<div class=\"card card--highlighted\" data-id=\"42\">...</div>",
    "tag": "div",
    "attrs": { "class": "card card--highlighted" },
    "shadowPath": [],                        // NEW (R5) — Shadow DOM 경계 chain
    "iframeChain": []                        // NEW (R5) — iframe frame URLs (중첩 순)
  },
  "source_location": {
    "framework": "react",
    "file": "src/components/Card.tsx",
    "line": 18,
    "component": "Card",
    "props": { "variant": "highlighted", "id": 42 },
    "mapping_confidence": "high",
    "mapping_via": "react-devtools-hook",
    "sourceMappingConfidence": "high",       // NEW (R5) — 'high' | 'medium' | 'low' | 'none'
    "fallbackReason": null,                  // NEW (R5) — confidence < high 일 때 원인 (예: "react19-no-debugSource")
    "caller_chain": [                        // NEW (R5) — 공통 컴포넌트 drift 방지 (NEW-1); 선택적
      { "component": "DashboardPage", "file": "src/pages/Dashboard.tsx", "line": 54 }
    ]
  },
  "reality_fingerprint": {
    "computed_style_subset": {               // 12개 핵심 속성만 (토큰 budget 제약)
      "display": "flex",
      "position": "relative",
      "width": "320px",
      "height": "180px",
      "color": "rgb(30, 41, 59)",
      "background-color": "rgba(0, 0, 0, 0)",
      "font-size": "14px",
      "font-weight": "400",
      "opacity": "1",
      "z-index": "auto",
      "visibility": "visible",
      "pointer-events": "auto"
    },
    "cascade_winner": {
      "padding": "src/styles/card.css:23 (.card--highlighted)"
    },
    "bounding_box": { "w": 320, "h": 180, "x": 120, "y": 340 },
    "ax_role_name": "article",               // NEW (R5) — accessibility role (CDP Accessibility.getFullAXTree)
    "scroll_offsets": { "x": 0, "y": 340 }, // NEW (R5) — 스크롤 위치
    "viewport": { "w": 1440, "h": 900 },    // NEW (R5) — viewport 크기 (metaから移動)
    "device_pixel_ratio": 2,                // NEW (R5) — DPR
    "_token_budget": "<5000"                // NEW (R5) — 전체 fingerprint 토큰 budget 제약 (NEW-3)
  },
  "meta": {
    "timestamp": "2026-04-07T12:34:56Z",
    "url": "http://localhost:3000/dashboard"
  }
}
```

> **R5 업데이트**: reality_fingerprint 필드 세트 확정 (OQ2 resolved). computed_style_subset 12개 속성으로 제한. 전체 fingerprint <5,000 토큰 budget 적용 (NEW-3). source_location에 sourceMappingConfidence + caller_chain 추가 (NEW-1, NEW-5). pointing에 shadowPath/iframeChain 추가 (OQ4).

## 7. 5-Stage Flow

(brainstorming 결과 그대로, 자세한 상태 전이는 R5 synthesis 후 확정)

```
[0] clmux -n proj -gb -T proj-team
[1] User → Lead: "frontend 작업해줘"
    Lead: clmux-inspect subscribe gemini-worker
    Lead → SendMessage(gemini-worker, "...")
[2] gemini-worker 구현 + clmux-inspect query 자체 검증 + Playwright
[3] Lead clmux-inspect snapshot active 검증
[4] Lead: clmux-inspect subscribe team-lead
    User: 브라우저에서 inspect mode + click + comment
    → browser-service → team-lead.json inbox → Lead pane send-keys
[5] Lead: 분석 → clmux-inspect subscribe gemini-worker → cycle 재시작
```

## 8. Open Questions (R5 기준 전체 resolved)

- [x] **OQ1**: source 역매핑 multi-tier fallback의 default 구성 (R4)
  → **답**: Multi-tier T1→T2→T4. React 18: `__reactFiber$*`/`_debugSource`. React 19: Tier 2 (Vite plugin, PR #28265로 `_debugSource` 제거). Vue: `__vue__`/`__file`. Svelte 4: `__svelte_meta`. Svelte 5: Tier 2. Solid: `data-source-loc`. 런타임 감지 후 자동 선택.

- [x] **OQ2**: reality_fingerprint 필드 세트 확정 (R1, R2)
  → **답**: computed_style_subset (12개), cascade_winner, bounding_box, ax_role_name, scroll_offsets, viewport, device_pixel_ratio. 전체 <5,000 토큰 budget. Section 6 JSON 예시 참조.

- [x] **OQ3**: SPA route 변경 시 overlay 재주입 전략 (R2)
  → **답**: History API hook (pushState/replaceState wrap) + CDP `Page.frameNavigated` 이벤트 → overlay 재주입. MutationObserver는 선택적(기본 비활성화).

- [x] **OQ4**: iframe / Shadow DOM 처리 (R2)
  → **답**: `Target.setAutoAttach(flatten:true)` + DOM `pierce:true`. cross-origin iframe은 별도 CDP session. Shadow DOM: pierce mode. MVP는 same-origin만 지원.

- [x] **OQ5**: Chrome supervise 정책 (자동 재시작 vs 수동) (R2)
  → **답**: daemon-owned 단독 launch. `--remote-debugging-port=0 --user-data-dir=<isolated>`. DevToolsActivePort 파일 poll로 port 발견. 1차 즉시 재시작, 2차+ exponential backoff. failure cap(초기값 3회) 초과 시 Lead alert.

- [x] **OQ6**: 차용 가능한 OSS UI/코드 모듈 목록 (R1, R3)
  → **답**: ai-chrome-pilot (Chrome launcher), Zendriver-MCP (DOM walker 개념), svelte-grab (overlay + SPA nav 패턴), Playwright MCP (a11y tree 개념), BrowserTools MCP (CDP session 패턴). R5 Section 3 표 참조.

- [x] **OQ7**: agent prompt template 최종안 (R4)
  → **답**: Candidate 2 (Checklist-Driven with anti-hallucination guards) 기본 권고. Gemini: compact variant. Claude: strict variant.

- [x] **OQ8**: clmux-inspect CLI 명령 surface area 확정 (R5)
  → **답**: subscribe / unsubscribe / query / snapshot / status + daemon start / stop.

- [x] **OQ9**: Playwright 통합 패턴 (공유 Chrome vs 별도) (R2)
  → **답**: daemon이 Chrome 단독 launch. Playwright는 `connectOverCDP` attach-only 모드 사용.

- [x] **OQ10**: brainstorming 12 결정 중 변경 항목 (R5)
  → **답**: Decision #5 amended (payload 확장). Decision #8 amended (SPA navigation 처리). R3의 Decision #9 WebSocket 제안 rejected. R5 Section 1 테이블 참조.

## 9. Implementation Phases (post-spec)

(spec 확정 후 별도 plan 문서로 분리)

- P1: browser-service daemon skeleton + CDP 연결
- P2: overlay 주입 + click capture
- P3: source remapping (R4 권고 기반)
- P4: reality fingerprint 수집
- P5: clmux-inspect CLI
- P6: clmux.zsh 통합 (-b flag)
- P7: 5-stage flow E2E 검증
- P8: 문서화

---

## 11. Risks (R5 research-discovered)

R1~R4 연구에서 새로 발견된 구현 위험 항목. 모두 spec에 반영됐거나 구현 시 결정 항목으로 flag됨.

| Risk ID | 설명 | 심각도 | 대응 | Status |
|---|---|---|---|---|
| NEW-1 | 공통 컴포넌트 잘못된 파일 수정: 사용자가 Page A의 Button을 클릭 → 에이전트가 공유 Button.tsx 전체 수정 → Page B, C, D 망가짐 | High | payload에 `caller_chain` 추가 + agent prompt에 "공통 컴포넌트 수정 전 import 횟수 확인" 규칙 추가 | flag-for-user (구현 시 결정) |
| NEW-2 | SPA navigation overlay 소멸: Inspect mode 중 client-side routing 발생 → overlay 소멸, 구독 상태 stale | Medium | History API hook + Page.frameNavigated → overlay 재주입 | accepted — Decision #8 amendment |
| NEW-3 | reality_fingerprint 토큰 초과: 전체 DOM ~400k 토큰, LLM context 초과 | High | accessibility tree 기반 + viewport clipping + CSS 변경된 것만. <5,000 토큰 budget 제약 | accepted — Section 6 budget 추가 |
| NEW-4 | Chrome 2025 보안 mandate: infostealer가 `--remote-debugging-port`를 기본 profile에서 악용 | High | `--remote-debugging-port=0 --user-data-dir=<isolated>` 필수. DevToolsActivePort poll | accepted — C6 추가 |
| NEW-5 | React 19 `_debugSource` 제거 (PR #28265): Tier 1 source remapping 불가 | Medium | React 19 감지 시 Tier 2 (Vite plugin) 자동 fallback. `sourceMappingConfidence` 필드로 신뢰도 표기 | accepted — multi-tier fallback + confidence 필드 |

---

## 12. Bibliography (R1~R4 주요 출처)

R1~R4 연구에서 참조한 주요 OSS 프로젝트 및 문서:

| 출처 | URL / 참조 | 관련 결정 |
|---|---|---|
| BrowserTools MCP | https://github.com/AgentDeskAI/browser-tools-mcp | Decision #2, #8, CDP session 패턴 |
| ai-chrome-pilot | https://github.com/nicholasgasior/ai-chrome-pilot | OQ5, OQ6, Chrome launcher |
| Zendriver-MCP | https://github.com/buger/zendriver-mcp | NEW-3, OQ2, DOM walker 개념 |
| svelte-grab | https://github.com/PuruVJ/svelte-grab | NEW-2, OQ3, overlay + SPA nav 패턴 |
| Playwright MCP | https://github.com/microsoft/playwright-mcp | OQ2, OQ6, a11y tree 개념 |
| React DevTools `_debugSource` removal (PR #28265) | https://github.com/facebook/react/pull/28265 | NEW-5, OQ1 |
| @solid-devtools/locator | https://github.com/thetarnav/solid-devtools | OQ1, Solid source remapping |
| Chrome DevTools Protocol — CSS.getMatchedStylesForNode | https://chromedevtools.github.io/devtools-protocol/tot/CSS/#method-getMatchedStylesForNode | OQ2, cascade_winner |
| Chrome DevTools Protocol — Target.setAutoAttach | https://chromedevtools.github.io/devtools-protocol/tot/Target/#method-setAutoAttach | OQ4, iframe 처리 |
| Chrome 2025 security: `--user-data-dir` mandate | Chrome blog / security team announcement | NEW-4, C6 |

---

## Appendix A: Brainstorming 발췌

(전체 대화는 git history 참조)

핵심 통찰:
- LLM은 시각 약함 / 수치·코드 강함 → tool은 분석기 아닌 브리지
- Inspect 도구는 "agent의 GPS" — 어디를 봐야 할지 알려주는 것
- 클라우드패턴 일관성 — Copilot MCP 서버처럼 background 프로세스로 운영
