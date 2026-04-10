# Browser Inspect Tool (BIT)

clau-mux의 frontend 디버깅 도구. 사용자가 브라우저에서 요소를 클릭하면 소스 위치 + 실측 computed style이 자동으로 AI agent의 입력으로 주입된다.

## 사용법

### 1. BIT 활성화 세션 시작

```bash
clmux -n myproj -gb -T myproj-team
clmux -n myproj -gbx -T myproj-team
```

`-b` 플래그는 격리 Chrome 프로필을 생성하고 browser-service daemon을 background로 시작한다.

### 2. Frontend 작업 요청

Lead Claude Code에:

```
frontend 작업해줘. Dashboard 페이지의 카드 레이아웃 개선.
```

### 3. 브라우저에서 inspect

1. Chrome에서 dev server URL로 이동
2. inspect mode 활성화 (자동)
3. 마음에 안 드는 요소 클릭
4. 팝업에 코멘트 입력 (선택)
5. 제출 → payload 자동 주입

### 4. Lead 검증

```bash
clmux-inspect snapshot "#dashboard .card"
```

### 5. 사용자 최종 검증

```bash
clmux-inspect subscribe team-lead
```

## CLI 명령어

```
clmux-inspect subscribe <agent>   구독 agent 변경
clmux-inspect unsubscribe         구독 해제
clmux-inspect query <selector> [props...]   요소 computed style 측정
clmux-inspect snapshot <selector> 요소 full payload 조회
clmux-inspect status              daemon 상태 확인
```

## Payload 구조

```json
{
  "user_intent": "padding 이상",
  "pointing": { "selector": "...", "outerHTML": "...", "tag": "div", "attrs": {} },
  "source_location": {
    "framework": "react",
    "file": "src/components/Card.tsx",
    "line": 42,
    "sourceMappingConfidence": "high",
    "mapping_tier_used": 1
  },
  "reality_fingerprint": {
    "computed_style_subset": { "padding": "12px" },
    "cascade_winner": { "padding": "src/styles/card.css:23 (.card--highlighted)" },
    "_token_budget": "<5000"
  },
  "meta": { "timestamp": "...", "url": "..." }
}
```

**스크린샷은 절대 포함되지 않는다** (FR-405).

## 지원 프레임워크

| Framework | Tier 1 | Tier 2 |
|---|---|---|
| React 18 | `_debugSource` | `react-dev-inspector` |
| React 19 | ❌ (removed) | ✅ (자동 fallback) |
| Vue 3 | `__file` (파일만) | `vite-plugin-vue-inspector` |
| Svelte 4 | `__svelte_meta` | — |
| Svelte 5 | ❌ | `data-source-file` |
| Solid | `data-source-loc` | — |

## 보안

- Chrome 격리 프로필 필수 (`--user-data-dir`)
- `--remote-debugging-port=0` (random port)
- HTTP server는 127.0.0.1만
- 파일 권한 0600

## 문제 해결

### Chrome이 시작되지 않음

```bash
cat /tmp/clmux-chrome-<team>.log
```

### daemon 응답 없음

```bash
clmux-inspect status
cat /tmp/clmux-browser-service-<team>.log
```
