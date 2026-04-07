# Browser Inspect Tool — Design Spec

**상태**: Draft (research-pending)
**작성일**: 2026-04-07
**브랜치**: feat/browser-inspect-research
**Worktree**: .worktrees/feat-browser-inspect

> 이 spec은 brainstorming 결과 + R1~R5 research 결과를 종합한 후 최종 확정됩니다.
> 현재는 brainstorming 결과만 박힌 골격입니다.

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

## 4. Decisions (brainstorming-confirmed)

| # | 결정 | 값 |
|---|---|---|
| 1 | 산출물 | 설계 spec 단일 |
| 2 | 구현 방식 | Lead-hosted background daemon + CLI tool |
| 3 | MCP 사용 | 금지 |
| 4 | Tool 역할 | Pointing + Source Remapping + Reality Fingerprint 브리지 |
| 5 | Payload | user_intent / pointing / source_location / reality_fingerprint |
| 6 | Agent 분석 방식 | 소스 코드 Read + drift 비교 |
| 7 | 활성화 | `clmux -b` 신규 플래그 (또는 `clmux-browser -t`) |
| 8 | 프로세스 모델 | background Node daemon (Copilot MCP 서버 패턴 복제) |
| 9 | 구독 모델 | `.inspect-subscriber` 파일 기반, `clmux-inspect subscribe`로 전환 |
| 10 | 5-stage flow | Implement → 1차검증(teammate) → 2차검증(Lead active) → 3차검증(user passive→Lead) → 재작업 |

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
    "attrs": { "class": "card card--highlighted" }
  },
  "source_location": {
    "framework": "react",
    "file": "src/components/Card.tsx",
    "line": 18,
    "component": "Card",
    "props": { "variant": "highlighted", "id": 42 },
    "mapping_confidence": "high",
    "mapping_via": "react-devtools-hook"
  },
  "reality_fingerprint": {
    "padding": { "top": "12px", "right": "16px", "bottom": "12px", "left": "16px" },
    "margin": { "top": "0", "right": "0", "bottom": "0", "left": "0" },
    "font": { "size": "14px", "weight": "400", "family": "Inter" },
    "color": { "fg": "rgb(30, 41, 59)", "bg": "rgba(0, 0, 0, 0)" },
    "rect": { "w": 320, "h": 180, "x": 120, "y": 340 },
    "cascade_winner": {
      "padding": "src/styles/card.css:23 (.card--highlighted)"
    }
  },
  "meta": {
    "timestamp": "2026-04-07T12:34:56Z",
    "url": "http://localhost:3000/dashboard",
    "viewport": { "w": 1440, "h": 900 }
  }
}
```

> **TBD (research-pending)**: reality_fingerprint의 정확한 필드 세트, source_location의 multi-tier fallback 구현, payload 크기 budget.

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

## 8. Open Questions (research-pending)

R1~R5 결과로 답해야 할 항목들:

- [ ] **OQ1**: source 역매핑 multi-tier fallback의 default 구성 (R4)
- [ ] **OQ2**: reality_fingerprint 필드 세트 확정 (R1, R2)
- [ ] **OQ3**: SPA route 변경 시 overlay 재주입 전략 (R2)
- [ ] **OQ4**: iframe / Shadow DOM 처리 (R2)
- [ ] **OQ5**: Chrome supervise 정책 (자동 재시작 vs 수동) (R2)
- [ ] **OQ6**: 차용 가능한 OSS UI/코드 모듈 목록 (R1, R3)
- [ ] **OQ7**: agent prompt template 최종안 (R4)
- [ ] **OQ8**: clmux-inspect CLI 명령 surface area 확정 (R5)
- [ ] **OQ9**: Playwright 통합 패턴 (공유 Chrome vs 별도) (R2)
- [ ] **OQ10**: brainstorming 12 결정 중 변경 항목 (R5)

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

## Appendix A: Brainstorming 발췌

(전체 대화는 git history 참조)

핵심 통찰:
- LLM은 시각 약함 / 수치·코드 강함 → tool은 분석기 아닌 브리지
- Inspect 도구는 "agent의 GPS" — 어디를 봐야 할지 알려주는 것
- 클라우드패턴 일관성 — Copilot MCP 서버처럼 background 프로세스로 운영
