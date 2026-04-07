# R1 — Agent 기반 Frontend 생성/디버깅 OSS 서베이 + 사용자 만족도 패턴

**담당**: gemini-worker
**상태**: pending
**입력**: 00-INDEX.md
**산출 위치**: 이 파일

## Scope

### Must-cover 도구 (최소 12개)

다음 카테고리를 모두 다룰 것:

**A. "AI가 페이지를 생성"하는 도구**
1. v0.dev (Vercel)
2. bolt.new (StackBlitz)
3. lovable.dev
4. gptengineer / Lovable
5. Claude Artifacts
6. (그 외 2025-2026 최신)

**B. "AI agent + 브라우저 inspect 통합" 도구**
7. stagewise (https://github.com/stagewise-io/stagewise)
8. browser-tools-mcp
9. BrowserMCP
10. Playwright MCP
11. Cursor inspect element / Windsurf inspect
12. Aider browser integration (있다면)

**C. "기존 chrome extension + AI" 도구**
13. (Chrome Web Store + GitHub에서 검색)

### 각 도구별 조사 항목

| 항목 | 설명 |
|---|---|
| 동작 방식 | overlay/extension/CDP/MCP 중 어느 메커니즘? |
| Click → Agent 경로 | 사용자 클릭 → AI까지의 데이터 흐름 |
| 캡처되는 데이터 | selector? outerHTML? computed style? screenshot? source map? component path? |
| Agent 통합 모델 | MCP / API / paste / file? |
| 라이선스 | MIT/Apache/proprietary |
| 활성도 | 마지막 커밋, star 수, contributor |
| Claude Code 통합 | 가능? 어떻게? |
| Non-MCP fork 가능성 | 우리 제약(NOT MCP)과 호환? |
| 사용자 후기/만족도 | issue tracker, Twitter, HN, Reddit 인용 |

### 사용자 만족도 패턴 (핵심)

다음을 답할 것:

1. **어떤 inspect payload가 사용자 만족도가 가장 높았는가?** 도구별·연도별·use case별로.
2. **사용자가 가장 자주 요청한 개선 사항은?** (issue tracker top 5)
3. **사용자가 가장 자주 불평한 부분은?** (실패 패턴 5개)
4. **"클릭 + 코멘트" UX vs "selector 복사" UX vs "screenshot annotation" UX** 중 어느 것이 가장 평가가 좋은가? evidence 인용.

## Output 형식

### 1. 도구별 카드 (각 도구 1-2 페이지 분량)

```markdown
## <도구 이름>

- **URL**: <repo / homepage>
- **License**: <license>
- **Last commit**: <date>
- **Stars / users**: <metric>
- **Mechanism**: <짧은 설명>
- **Click→Agent path**: <data flow>
- **Captured payload**: <field list>
- **Agent integration**: <model>
- **Reusability for our project**: <high/medium/low + 이유>
- **Reusable code/UI**: <구체 모듈/파일 언급, 가능하면 URL>
- **User satisfaction signals**: <인용 + 출처 URL>

### 우리 설계와의 비교
- 우리가 차용할 수 있는 것:
- 우리가 피해야 할 함정:
```

### 2. 종합 발견 (Findings)

```markdown
## Findings

### F1. 사용자 만족도가 가장 높은 payload 형태
- 발견: ...
- 근거: <인용 + URL>
- 우리 설계에 반영해야 할 점:

### F2. 가장 흔한 실패 패턴
- ...

### F3. NOT MCP 제약 하에서 재사용 가능한 패턴
- ...
```

### 3. brainstorming 결정사항에 대한 review

```markdown
## 기존 결정 12개에 대한 검토

| # | 결정 | 검토 의견 | 근거 |
|---|---|---|---|
| 4 | Tool = 분석기 아닌 브리지 | 동의/이의 | ... |
| 5 | 스크린샷 없음 | 동의/이의 | ... |
| ... | ... | ... | ... |
```

## 검색 키워드 힌트

- "agent based frontend debugging 2026"
- "AI inspect element click context"
- "stagewise toolbar github"
- "browser tools MCP claude"
- "v0 bolt lovable comparison user satisfaction"
- "chrome devtools protocol AI agent"
- "frontend bug AI fix workflow user study"

## 주의

- WebSearch / WebFetch 모두 사용 가능
- 모든 주장에 URL 인용 필수
- 우리 제약: **NOT MCP**, **NO screenshot in payload**, **소스 코드 기반 분석**
- 이 제약을 위반하는 도구라도 일부 기능·UI는 차용 가능 — 무엇을 차용할지 명확히 분리

## 완료 조건

- 최소 12개 도구 카드
- Findings 섹션 ≥ 5개
- 12개 결정 review 표 작성
- 모든 주장 URL 인용
- 산출: 이 파일 갱신 + Lead에게 SendMessage로 완료 보고
