# R5 — Synthesis: 기존 결정 보완 + 새로운 contested 영역 + spec 업데이트 권고

**상태**: completed
**작성일**: 2026-04-08
**입력**: R1 (Gemini), R2 (Codex), R3 (Copilot), R4 (Claude teammate)

---

## 1. 12 결정 종합 review 테이블

| # | Decision | R1 Opinion | R2 Opinion | R3 Opinion | R4 Opinion | Synthesis | Status |
|---|---|---|---|---|---|---|---|
| 1 | 산출물: 설계 spec 단일 | — | — | — | — | 모든 R에서 이의 없음 | confirmed |
| 2 | Lead-hosted background daemon + CLI | Confirms (BrowserTools MCP pattern과 일치) | Strongly confirms; daemon이 Chrome launch/kill 권한 독점 | Confirms | — | 확정 | confirmed |
| 3 | NOT MCP | — | — | Validates: 조사 20개 프로젝트 중 60%가 non-MCP | — | 확정 | confirmed |
| 4 | Tool 역할: pointing bridge (분석기 아님) | Strongly confirms; stagewise 경량 bridge 성공 모델 | — | — | — | 확정 | confirmed |
| 5 | Payload: user_intent/pointing/source_location/reality_fingerprint | Strongly confirms; call-site context 추가 권고 (F2 drift) | Amend: cascade_winner, a11y 필드(ax_role_name, scroll_offsets, viewport) 추가 | Amend: pointing에 shadowPath/iframeChain 추가, source_location에 sourceMappingConfidence 추가, reality_fingerprint 토큰 <5k budget | R4: mapping_confidence 이미 설계됨, cascade_winner → CDP CSS.getMatchedStylesForNode | **Amend**: 4개 신규 sub-field + 토큰 budget 제약 추가 | amended |
| 6 | 소스 기반 분석 (Read source + drift 비교) | Strongly confirms; F2 failure 방지에 필수 | — | — | Confirms; prompt template으로 강제 | 확정 | confirmed |
| 7 | clmux -b 신규 플래그 | Supplement: Vite/Webpack plugin 레이어 필요 가능성 | Supplement: -b는 "격리 Chrome 프로파일 launch"를 의미함을 문서화 필요 | — | — | Confirmed with supplement: -b는 isolated profile launch, plugin layer는 선택사항 | confirmed-with-note |
| 8 | Background Node daemon (Copilot MCP 패턴) | Confirms | Strongly confirms; SPA: dual mechanism 필요(injection + History API hook + Page.frameNavigated) | Amend: SPA navigation에 MutationObserver + history.pushState hook 추가 | — | **Amend**: SPA navigation 처리 추가; 구체적 mechanism = History API hook + Page.frameNavigated (MutationObserver는 R2가 비권고) | amended |
| 9 | .inspect-subscriber 파일 기반 구독 | — | — | **REJECT**: localhost:9222 WebSocket으로 교체 권고 | — | **REJECT R3 proposal**: file-based 유지. 이유: (1) clau-mux는 WebSocket 없는 파일 bridge 패턴 일관성, (2) 구독 빈도 낮음(handoff 간격 수분), 100ms latency 무관, (3) localhost:9222는 CDP 자체 예약 포트 — 충돌, (4) 양방향 필요 없음. WebSocket은 CDP Runtime.addBinding으로 별도 처리 | confirmed (R3 proposal rejected) |
| 10 | 5-stage flow | — | Confirms; cross-stage browser reuse policy, write-actor ownership rule 추가 필요 | — | — | Confirmed + supplements: (1) 같은 inspect session 내 browser reuse, (2) stage boundary마다 write actor 1명, (3) payload append-only | confirmed-with-note |
| 11 | Research focus 7개 영역 | — | — | — | — | 완료 | confirmed |
| 12 | Research 팀 구성 | — | — | — | — | 완료 | confirmed |

---

## 2. 새로 발견된 contested 영역

### NEW-1: Common-component wrong-file modification (R1, F2)

**문제**: 사용자가 Page A의 Button 인스턴스를 클릭하면 에이전트가 공유 Button.tsx 전체를 수정 → Page B, C, D가 망가짐.

**원인**: 현재 payload의 `source_location`은 component file만 알려주고, 어느 caller site에서 사용됐는지 알려주지 않는다.

**제안 A**: payload에 caller context 추가 (`source_location.caller_site`: 부모 컴포넌트 + 파일:라인).

**제안 B**: agent prompt에 "공통 컴포넌트 수정 전 반드시 사용 사이트 수 확인" 규칙 추가 (grep으로 import 횟수 확인).

**권고**: 제안 A + B 병행. `source_location`에 `caller_chain` 선택적 필드 추가 (React의 `_debugOwner` chain에서 추출).

**Status**: flag-for-user — spec에 위험 항목으로 기록, 구현 시 결정.

---

### NEW-2: SPA navigation overlay persistence (R2, R3)

**문제**: Inspect mode 진입 → client-side routing 발생 → overlay 소멸, 구독 상태 stale.

**해결**: History API hook (pushState/replaceState wrapping) + Page.frameNavigated 이벤트 → overlay 재주입 + URL 업데이트.

**R2 vs R3 차이**: R2는 MutationObserver 비권고(DOM change와 route change 혼동 우려); History API hook 권고. R3는 MutationObserver + history hooks 병행 권고.

**최종 결정**: History API hook + Page.frameNavigated (R2 우선, MutationObserver 선택적). Decision #8 amendment에 반영.

**Status**: accepted — Decision #8 amendment.

---

### NEW-3: Token budget for reality_fingerprint (R3 via Zendriver-MCP)

**문제**: 전체 DOM = ~400k 토큰, LLM context 초과.

**근거**: Zendriver-MCP: accessibility tree로 전환 시 96% 감소 (400k → 4k tokens).

**해결**: `reality_fingerprint`는 accessibility tree 기반 + viewport clipping + CSS computed styles (전체 300+ 속성이 아닌 변경된 것만).

**Target**: `reality_fingerprint` 전체 <5,000 토큰.

**Status**: accepted — spec Section 6에 추가.

---

### NEW-4: Chrome 2025 security mandate (R2)

**문제**: 2025년 Chrome 보안팀: infostealer가 `--remote-debugging-port`를 기본 profile에 대해 악용 → `--user-data-dir` 필수화.

**해결**: 반드시 `--remote-debugging-port=0 --user-data-dir=<isolated-dir>` 조합 사용. random port (0 = OS 할당).

**Port 발견 방법**: `DevToolsActivePort` 파일 poll.

**Status**: accepted — spec Constraints에 C6 추가.

---

### NEW-5: React 19 removes `_debugSource` (R4)

**문제**: React 19 (PR #28265)는 `_debugSource`를 제거함 → Tier 1 remapping 불가.

**해결**: React 19 프로젝트에서는 Tier 2 (Vite plugin / build-time injection) 자동 fallback.

**Status**: accepted — multi-tier fallback에 명시, `sourceMappingConfidence` 필드로 신뢰도 반영.

---

## 3. 재사용 가능한 OSS 모듈

| 모듈 | 출처 | 라이선스 | 통합 위치 | 통합 비용 | 비고 |
|---|---|---|---|---|---|
| Chrome launcher (`src/chrome.ts`) | ai-chrome-pilot | MIT | browser-service 시작 시 Chrome 탐지 + launch | 낮음 | cross-platform Chrome 탐지 |
| DOM walker (concept from `dom_walker.py`) | Zendriver-MCP | TBD | reality_fingerprint 수집 시 token 최적화 | 중간 (Python→TS 포팅) | 96% 토큰 절감 개념 |
| Overlay manager (`src/inspector.ts`) | svelte-grab | MIT | browser overlay 주입 + SPA nav 처리 패턴 | 중간 | SPA nav 해결 패턴 참조 |
| Accessibility tree model | Playwright MCP | MIT | reality_fingerprint의 ax_role_name, accessible name | 낮음 | 개념 차용, 직접 CDP로 구현 |
| CDP session manager pattern | BrowserTools MCP | MIT | browser-service의 CDP connection 관리 | 낮음 | MCP 레이어 제거 후 사용 |

---

## 4. Spec 업데이트 권고

### 4.1 Decision #5 — Payload 확장

**`pointing`에 추가:**
```typescript
shadowPath?: string[]      // Shadow DOM 경계 chain
iframeChain?: string[]     // iframe frame URLs (중첩 순)
```

**`source_location`에 추가:**
```typescript
sourceMappingConfidence: 'high' | 'medium' | 'low' | 'none'
fallbackReason?: string    // confidence < high 일 때 원인 기술
caller_chain?: Array<{     // 공통 컴포넌트 drift 방지 (NEW-1)
  component: string
  file: string
  line: number
}>
```

**`reality_fingerprint`에 추가:**
```typescript
ax_role_name: string             // accessibility role (CDP Accessibility.getFullAXTree)
scroll_offsets: { x: number; y: number }
viewport: { w: number; h: number }
device_pixel_ratio: number
fingerprint_token_budget: '<5000'  // 토큰 budget 제약 (NEW-3)
```

---

### 4.2 Decision #8 — SPA navigation 처리

daemon 책임에 다음 항목 추가:

1. **History API hook 주입**: `history.pushState` / `history.replaceState` wrapping → route 변경 감지
2. **Page.frameNavigated 수신**: CDP 이벤트 → overlay 재주입 + 구독 URL 업데이트
3. MutationObserver는 선택적 (R2 비권고, R3 권고): DOM 변화와 route 변화 혼동 위험으로 기본 비활성화

---

### 4.3 새로운 제약 C6 — Chrome 보안 (NEW-4)

```
C6: Chrome launch 시 반드시 --remote-debugging-port=0 --user-data-dir=<isolated-dir> 조합 사용.
    Port는 DevToolsActivePort 파일 poll로 발견.
    기본 Chrome profile 사용 금지 (2025 infostealer 취약점).
```

---

### 4.4 새로운 Section: Risks

NEW-1 ~ NEW-5를 구현 위험 항목으로 spec에 등록 (상세 내용은 섹션 2 참조).

| Risk | 심각도 | Status |
|---|---|---|
| NEW-1: 공통 컴포넌트 잘못된 파일 수정 | High | flag-for-user |
| NEW-2: SPA navigation overlay 소멸 | Medium | accepted, amendment |
| NEW-3: reality_fingerprint 토큰 초과 | High | accepted, budget 제약 |
| NEW-4: Chrome 보안 mandate | High | accepted, C6 추가 |
| NEW-5: React 19 `_debugSource` 제거 | Medium | accepted, Tier 2 fallback |

---

### 4.5 새로운 Section: Bibliography

모든 R1-R4 출처 URL 포함 (spec Section 12로 추가 — 상세는 섹션 5 OQ 답변 참조).

---

## 5. Open Questions — 연구로 답변 완료

**OQ1** — 소스 역매핑 default 전략

답: Multi-tier T1→T2→T4. React 18: `__reactFiber$*` / `_debugSource`. React 19: Tier 2 (Vite plugin, `_debugSource` 제거됨 — NEW-5). Vue: `__vue__` / `__file` (file-level only). Svelte 4: `__svelte_meta`. Svelte 5: Tier 2. Solid: `@solid-devtools/locator` `data-source-loc`. Default: 실행 시 런타임 감지 후 자동 선택. (출처: R4)

---

**OQ2** — `reality_fingerprint` 포함 필드

답: `computed_style_subset` (12개: display, position, width, height, color, background-color, font-size, font-weight, opacity, z-index, visibility, pointer-events), `matched_rules_subset` (cascade_winner via CDP `CSS.getMatchedStylesForNode`), `bounding_box`, `scroll_offsets`, `viewport`, `device_pixel_ratio`, `ax_role_name`. Target: <5,000 tokens. (출처: R2, R3)

---

**OQ3** — SPA route 변경 시 overlay 재주입

답: History API hook (pushState/replaceState wrap) + CDP `Page.frameNavigated` 이벤트 → overlay 재주입. MutationObserver는 선택적. (출처: R2, R3)

---

**OQ4** — iframe / Shadow DOM 처리

답: `Target.setAutoAttach(flatten:true)` + DOM `pierce:true`. cross-origin iframe은 별도 CDP session. Shadow DOM: pierce mode. (출처: R2)

---

**OQ5** — Chrome 프로세스 관리 + 재시작 정책

답: daemon-owned 단독 launch. `--remote-debugging-port=0 --user-data-dir=<isolated>`. DevToolsActivePort 파일 poll로 port 발견. 1차 즉시 재시작, 2차+ exponential backoff. failure cap 초과 시 Lead alert. (출처: R2)

---

**OQ6** — 재사용 OSS 모듈

답: 섹션 3 표 참조. 핵심: ai-chrome-pilot (Chrome launch), Zendriver-MCP (DOM walker 개념), svelte-grab (overlay + SPA nav 패턴), Playwright MCP (a11y tree 개념), BrowserTools MCP (CDP session 패턴). (출처: R1, R3)

---

**OQ7** — agent prompt template

답: Candidate 2 (Checklist-Driven with anti-hallucination guards) 기본 권고. Gemini: compact variant. Claude: strict variant. (출처: R4)

---

**OQ8** — CLI surface 확정

답: subscribe / unsubscribe / query / snapshot / status + daemon start / stop. (확정)

---

**OQ9** — Playwright 통합 방식

답: daemon이 Chrome 단독 launch. Playwright는 `connectOverCDP` attach-only 모드로 사용 (Playwright가 Chrome을 직접 launch하지 않음). (출처: R2)

---

**OQ10** — 최종 변경 결정 목록

답: Decision #5 amended (payload 확장 — shadowPath, iframeChain, sourceMappingConfidence, caller_chain, ax_role_name, scroll_offsets, viewport, device_pixel_ratio, fingerprint_token_budget). Decision #8 amended (SPA navigation 처리 — History API hook + Page.frameNavigated). R3의 Decision #9 WebSocket 제안 rejected (이유: 섹션 7 참조). (출처: R2, R3, R4)

---

## 6. 구현 단계로 미루는 항목

다음 항목은 연구 단계에서 결론을 내리지 않고 구현 시 결정하도록 플래그:

- [ ] **NEW-1 caller_chain 깊이**: `_debugOwner` chain을 몇 단계까지 따라갈 것인가 (성능 vs. 정보량). 권고: 최대 5단계.
- [ ] **MutationObserver 활성화 여부**: R2 비권고, R3 권고. SPA 프레임워크 종류에 따라 런타임 감지 후 선택.
- [ ] **Vite/Webpack plugin 레이어 (Decision #7 supplement)**: source remapping Tier 2의 구체적 plugin 구현. React 19 전환 프로젝트에서 우선 필요.
- [ ] **cascade_winner 표시 방식**: CSS `!important` 체인 전체 vs. 최종 승자만. 토큰 budget 제약 내에서 결정.
- [ ] **failure cap 임계값 (OQ5)**: Chrome 재시작 몇 회 실패 시 Lead에 alert할 것인가. 초기값 권고: 3회.
- [ ] **cross-origin iframe 지원 범위**: 별도 CDP session 관리 복잡도 vs. 지원 가치. MVP에서는 same-origin만 지원 권고.

---

## 7. R3 rejected proposals — 근거 기록

### R3 WebSocket Proposal (Decision #9)

**R3 제안**: `.inspect-subscriber` 파일 기반 구독을 `localhost:9222` WebSocket으로 교체.

**제안 근거**: 실시간 양방향 통신, latency 개선, 표준 프로토콜.

**거부 결정 및 근거**:

1. **clau-mux 아키텍처 일관성**: clau-mux 전체가 WebSocket 없는 파일 bridge 패턴을 채택하고 있음. 이 패턴 자체가 clau-mux의 핵심 설계 원칙임.

2. **구독 빈도 낮음**: subscriber 등록은 handoff 간격(수 분) 기준. 100ms 파일 polling latency는 무관함.

3. **포트 충돌**: `localhost:9222`는 Chrome DevTools Protocol이 이미 사용하는 예약 포트. 별도 WebSocket 서버를 같은 포트에 띄울 수 없음.

4. **단방향 충분**: `.inspect-subscriber`는 daemon에게 "나(에이전트)가 구독 중"임을 알리기만 하면 됨. 양방향 채널이 필요하지 않음. 클릭 이벤트는 CDP Runtime.addBinding으로 별도 처리.

5. **복잡도 증가**: WebSocket 서버 추가 = 별도 프로세스/스레드 관리, 연결 상태 관리, 재연결 로직. 현재 파일 방식 대비 복잡도 대폭 증가.

**결론**: R3의 WebSocket 제안은 거부하고 파일 기반 구독 유지. 브라우저↔daemon 간 click event 전달은 CDP Runtime.addBinding을 통한 별도 채널로 처리.
