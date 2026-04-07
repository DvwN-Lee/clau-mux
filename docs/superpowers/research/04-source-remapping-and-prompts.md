# R4 — Source 역매핑 기법 + Agent Prompt 템플릿

**담당**: Claude teammate (Sonnet, architecture-research)
**상태**: pending
**입력**: 00-INDEX.md
**산출 위치**: 이 파일

## Scope

브라우저 런타임의 DOM element를 소스 코드 위치(file:line:component)로 정확하게 역매핑하는 기법을 평가하고, 그 정보를 받은 agent가 "소스 먼저 Read 후 drift 비교"를 강제하도록 만드는 프롬프트 템플릿을 설계.

이것이 우리 설계의 **기술적 단일 실패점(SPOF)** 이다 — 역매핑이 부정확하면 agent가 잘못된 파일을 수정하고, drift 검증이 무의미해진다.

## Part A — Source 역매핑 기법 평가

### A.1 조사 대상 기법

각 기법별로 다음을 답할 것:

| 기법 | 작동 원리 | 대상 프레임워크 | 정확도 | 제약 | 의존성 |
|---|---|---|---|---|---|
| React DevTools Hook (`__REACT_DEVTOOLS_GLOBAL_HOOK__`) | fiber → owner → debugSource | React 16+ | ? | dev mode only? | React |
| Vue `__vue__` / `__vue_app__` | component instance | Vue 2/3 | ? | ? | Vue |
| Svelte source map | source map traversal | Svelte | ? | ? | source-map lib |
| Solid `_$owner` | owner chain | Solid | ? | ? | Solid |
| Build-time `data-source-file` 주입 | Babel/SWC/Vite plugin | framework-agnostic | ? | build 변경 필요 | plugin |
| `@vitejs/plugin-react` debugSource | Vite + React 시 자동 | React + Vite | ? | Vite | Vite |
| Chrome DevTools "Inspect Source" 기능 | 어떻게 동작? | 모두 | ? | ? | ? |
| source map만으로 역추적 | js stacktrace → original | 모두 | ? | source map 필요 | source-map lib |

### A.2 각 기법별 심층 조사

```markdown
## React DevTools Hook 기법

### 작동 원리
React fiber tree의 각 node에 `_debugSource` 속성이 있고, 이는 dev build에서 `{fileName, lineNumber, columnNumber}`를 포함한다.
DOM element → fiber node 매핑은 `__reactFiber$<random>` 키로 가능 (React 17+).

### 사용 예시
```js
const fiber = element[Object.keys(element).find(k => k.startsWith('__reactFiber$'))];
const source = fiber._debugSource;
// → { fileName: "src/components/Card.tsx", lineNumber: 42, columnNumber: 12 }
```

### 정확도
- ...

### 제약
- production build에서는 `_debugSource`가 stripped → ❌ 작동 안함
- ...

### 우리 use case 적합도
- ...
```

위 형식으로 모든 기법 평가.

### A.3 권고

```markdown
## Source 역매핑 권고

### 기본 전략 (multi-tier fallback)
1. Tier 1: framework-specific hook (React DevTools, Vue, Svelte)
2. Tier 2: build-time injected `data-source-file` attribute
3. Tier 3: source map 기반 stacktrace 역추적
4. Tier 4: failure → "source unknown" 명시 (agent에 honest 전달)

### 각 tier의 구현 부담
- Tier 1: ...
- Tier 2: ...

### 권고: clau-mux 사용자 환경에서 가장 현실적 default
- ...
```

## Part B — Agent Prompt 템플릿

### B.1 목표

inspect payload를 받은 agent(Gemini, Claude teammate, Codex 등)가 **반드시** 다음 순서로 작업하도록 강제:

1. payload의 `source_location`에 명시된 파일을 **Read**
2. 소스에서 의도된 값(intent) 추출
3. payload의 `reality_fingerprint`와 비교
4. drift 식별
5. 사용자의 `user_intent`를 반영해 수정 방향 결정
6. 코드 수정 제안

### B.2 위험 (LLM이 흔히 빠지는 함정)

- 소스를 안 읽고 fingerprint만 보고 추측 → 잘못된 수정
- screenshot이 없는데도 "이미지 보고 판단"하는 환각
- payload의 selector를 grep해서 비슷한 코드 찾으려 함 (역매핑 무시)
- 부모/sibling 컨텍스트 없이 단일 element만 보고 결론

### B.3 system prompt 후보들

여러 후보 작성 → 비교 → 권고:

```markdown
## Candidate 1: Strict Read-First

[전체 system prompt 문안]

평가:
- 강점:
- 약점:
```

```markdown
## Candidate 2: Checklist-driven

...
```

```markdown
## Candidate 3: Tool-call enforced (function calling 강제)

...
```

### B.4 권고

- **권고 템플릿 1개 + 변형 2개**
- 각 teammate(Gemini CLI, Codex CLI, Claude Code teammate)별 차이점 명시
- few-shot example 포함

### B.5 관측·검증 방법

agent가 실제로 read-first 패턴을 따랐는지 어떻게 검증할 것인가?

- log 분석
- tool call sequence 검사
- 출력에서 file path 인용 여부

## Output 형식

위 Part A + Part B를 이 파일에 작성.

## 검색 키워드 힌트

- "react devtools hook fiber debug source"
- "vue component source mapping runtime"
- "svelte source map runtime lookup"
- "vite react jsx debug source"
- "babel jsx source plugin"
- "agent prompt code reading first pattern"
- "LLM hallucination prevention source code"

## 완료 조건

- Part A: 8개 기법 평가 + 권고
- Part B: 3개 prompt 후보 + 권고 + few-shot example
- 모든 주장 URL 인용
- 산출: 이 파일 갱신 + Lead에게 SendMessage로 완료 보고

## 주의

- 이 영역은 우리 설계의 SPOF — 정밀하게 다룰 것
- WebSearch / WebFetch / Grep on local clau-mux repo 모두 사용 가능
- 권고는 "현실적으로 동작 가능한" 수준이어야 함 (이론적 가능성만으로는 부족)
- Claude Code teammate는 자기 subagent를 spawn해서 병렬 조사해도 됨 (saga-agents §2-Tier 위임 규칙 준수)
