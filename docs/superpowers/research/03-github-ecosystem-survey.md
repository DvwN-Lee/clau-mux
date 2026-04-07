# R3 — GitHub 생태계 + recent 2025-2026 프로젝트 + Issue Tracker Pain Point

**담당**: copilot-worker
**상태**: pending
**입력**: 00-INDEX.md
**산출 위치**: 이 파일

## Scope

GitHub을 source of truth로 사용해 다음을 조사한다.

### 1. 최근 (2025-2026) 등장한 관련 프로젝트

검색 키워드 (gh search code / gh search repos):

- `agent inspect element click`
- `frontend debug AI bridge`
- `devtools protocol AI agent`
- `claude code browser tool`
- `cursor inspect element`
- `stagewise alternative`
- `non-mcp browser tool`
- `frontend AI debugging bridge`
- `react component to source mapping AI`
- `chrome cdp daemon node`

### 2. 검색 → 정렬 → top 20

- 최근 12개월 활동 (2025-04 ~ 2026-04)
- star 50+ OR 최근 30일 내 commit
- 우리 use case와 관련성

### 3. 각 프로젝트 카드

```markdown
## <repo full name>

- **URL**: https://github.com/owner/repo
- **Description**: (1줄)
- **Last commit**: <date>
- **Stars**: <n>
- **License**: <license>
- **Mechanism**: extension / CDP / MCP / standalone / chrome app
- **Captured payload**: <field list>
- **Languages**: <stack>
- **Active maintainer**: yes/no
- **Reusability rating**: high / medium / low
- **Notable code modules**:
  - `path/to/file.ts`: ...
- **License compatibility with our project**: ...
```

### 4. Issue tracker pain point 마이닝

가장 활발한 top 5 프로젝트의 issue tracker에서 다음 라벨/키워드 검색:

- "user feedback"
- "pain point"
- "doesn't work"
- "frustrating"
- "missing feature"
- 최근 6개월 most reacted issues (👍 정렬)

조사 형식:

```markdown
## <project> — Top Pain Points

| # | Issue | URL | 👍 | 우리에게 시사점 |
|---|---|---|---|---|
| 1 | "Click capture loses context on SPA navigation" | <url> | 47 | overlay 재주입 필요 |
| ... | ... | ... | ... | ... |
```

### 5. 사용자 요청 패턴 (Top Requests)

```markdown
## Top User Requests Across Ecosystem

1. **<요청 패턴 1>** — 언급 빈도: N개 issue across M projects
   - 예시 issue URL:
   - 우리 설계에 어떻게 반영해야 하는가:

2. ...
```

### 6. brainstorming 결정사항 review

GitHub 생태계 관점에서 12개 결정 검토. 특히:
- #2 (Lead-hosted background daemon) — 비슷한 패턴이 다른 프로젝트에 있는가?
- #3 (NOT MCP) — non-MCP 패턴 사례 존재?
- #5 (4-section payload) — 다른 프로젝트의 payload 비교

## Output 형식

위 1~6 섹션을 모두 포함해서 이 파일에 작성.

## 완료 조건

- top 20 프로젝트 카드
- top 5 프로젝트 issue tracker 분석
- top user requests 5개
- 12 결정 review 표
- 모든 주장 URL 인용
- 산출: 이 파일 갱신 + Lead에게 SendMessage로 완료 보고

## 주의

- Copilot CLI는 GitHub 검색·issue 마이닝에 강점. 이 강점을 최대한 활용.
- WebSearch도 보조로 사용 가능
- 우리 제약: NOT MCP, NO screenshot in payload, source code-based analysis
