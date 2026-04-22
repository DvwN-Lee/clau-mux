---
name: clmux-tools
description: "clmux 단일 진입점 진단 도구 모음 (6 wrappers) + 사용 패턴 (Recipes) + Anti-Pattern + Decision Tree. tmux/cat/json 직접 호출 대신 본 skill 의 명령을 사용한다. 사용자가 pane / session / team 상태 조회 / 메시지 송부 / 활성 세션 목록 / teammate liveness / 디버깅을 언급하거나 /clmux:clmux-tools를 호출할 때 본 skill 사용."
---

# clmux Tools — 진단 + 송수신 단일 진입점

> **금지**: raw `tmux list-panes`, `tmux capture-pane`, `tmux display-message`, `tmux list-sessions`, `tmux send-keys`, `cat ~/.claude/teams/.../config.json`, `ls ~/.claude/teams/`, json 직접 파싱. 모든 진단/송수신은 clmux-* 명령으로 단일 진입.

## 1. 명령 inventory (6 wrappers)

| 의도 | 명령 |
|---|---|
| 활성 tmux 세션 목록 (cross-session overview) | `zsh -ic "clmux-sessions [--filter <pattern>]"` |
| 모든 team 멤버 listing | `zsh -ic "clmux-teammates"` |
| 특정 pane 상세 (process + agent + team + recent output) | `zsh -ic "clmux-pane-info <pane_id> [-n <lines>]"` |
| 특정 team 상세 (config + members table + inboxes table) | `zsh -ic "clmux-team-inspect [<team>]"` (default = 가장 최근 team) |
| Teammate liveness ping (응답 여부) | `zsh -ic "clmux-teammate-check --team <team> --to <agent>"` |
| structured prompt를 pane에 송부 (raw `send-keys` 대체) — **PRIMARY** | `zsh -ic "clmux-send <target> '<text>'"` |
| 위와 동일, 옵션 사용 시 (verbose form) | `zsh -ic "clmux-send --to <target> --prompt '<text>' [--clear --no-enter --wait-idle --timeout <sec> --force]"` |

## 2. 사용 패턴 (Recipes)

agent는 사용자 자연어 발화를 아래 recipe 매핑으로 정확한 명령으로 변환한다. 첫 시도 정확도 ↑ + 탐색 비효율 ↓.

### Recipe 1: 자연어로 pane 지칭 + 메시지 전달
- 사용자: "X pane에 Y 보내줘" / "X에 ... 전달"
- agent: `zsh -ic "clmux-send '<X>' '<Y>'"` (positional, 1턴 1-tool)
- `<X>`가 어느 형태든 (pane id / session / team:agent / agent name) 자동 resolve. fail-closed.

### Recipe 2: "활성 세션 확인" / "tmux 상태"
- agent: `zsh -ic "clmux-sessions"`
- **금지**: `tmux list-sessions`

### Recipe 3: 특정 pane 디버그
- 사용자: "X pane 뭐하고 있어?" / "X 출력 확인"
- pane id 알 때: `clmux-pane-info %X [-n 30]`
- pane id 모를 때: `clmux-teammates` 또는 `clmux-sessions` → 식별 후 `clmux-pane-info`

### Recipe 4: Team 상태 종합
- 사용자: "우리 팀 상태" / "어떤 inbox 쌓여있나"
- agent: `zsh -ic "clmux-team-inspect"` (default = 가장 최근 team)

### Recipe 5: Teammate 응답 안 올 때 (진단 → 복구)
1. `clmux-teammates` (전체 alive/dead)
2. `clmux-pane-info <suspect>` (process + 최근 출력)
3. `clmux-teammate-check --team <t> --to <a>` (ping)
4. 이상 시 → clmux-teams skill 의 §"에러 대응" 절차 (teardown + respawn)

## 3. Anti-Pattern (Don't → Do)

매 명령 호출 직전 아래 표 확인. raw 명령 시도 전에 wrapper 우선.

| ❌ Raw (금지) | ✅ Clmux 단일 진입점 |
|---|---|
| `tmux list-sessions [-F ...]` | `clmux-sessions [--filter <p>]` |
| `tmux list-panes -a -F ...` | `clmux-teammates` |
| `tmux capture-pane -t %X -p -S -N` | `clmux-pane-info %X -n N` |
| `tmux display-message -t %X -p '#{...}'` | `clmux-pane-info %X` |
| `tmux send-keys -t %X 'text' Enter` | `clmux-send %X 'text'` |
| `cat ~/.claude/teams/<t>/config.json` + json 파싱 | `clmux-team-inspect <t>` |
| `ls ~/.claude/teams/` + json 검색 | `clmux-team-inspect` |
| `pgrep -f bridge` / `kill -0 <pid>` | `clmux-teammate-check --team <t> --to <a>` |

신규 use case가 위 매핑에 없으면 **wrapper 신설**을 우선 검토 (raw 추가 X).

## 4. Decision Tree — `clmux-send <target>` 형태 결정

사용자가 자연어로 target을 줄 때 어느 형태인지 추론:

```
target 패턴별:
  "%" 로 시작 (e.g., %4)              → pane id, 그대로 사용
  "/" 포함 (e.g., clau-mux/test)      → tmux session_name (그 세션의 active pane으로 resolve)
  ":" 포함 (e.g., chain-ux:codex)     → team:agent (team config에서 lookup)
  단일 단어 (e.g., codex-worker)      → bare agent_name (활성 team들에서 1건 매치)
  애매 / 알 수 없음                    → 그대로 clmux-send에 넘기고 fail-closed 결과 (error + tried + suggestions) 로 다음 시도 결정
```

resolve 우선순위 (clmux-send 내부):
1. `%X` literal pane id
2. session_name
3. `team:agent`
4. bare agent_name (정확 1건 매치 시)

다중 매치 / no match → exit 1 + 후보 목록.

## 5. 통합 워크플로 (사용 예)

### 시나리오 A: "clau-mux/test에 메시지 보내줘"
```
zsh -ic "clmux-send 'clau-mux/test' '메시지 본문'"
```
→ session active pane으로 resolve, paste-buffer + Enter, 1턴 1-tool.

### 시나리오 B: "어떤 세션 떠있고 누가 살아있는지 한번에"
```
zsh -ic "clmux-sessions"        # 세션 inventory
zsh -ic "clmux-teammates"       # team 멤버 status
```
→ raw tmux 0건.

### 시나리오 C: security-codex가 응답 없음
```
zsh -ic "clmux-teammates"                                          # alive 확인
zsh -ic "clmux-pane-info security-codex -n 30"                     # 최근 출력
zsh -ic "clmux-teammate-check --team chain-ux --to security-codex" # ping
# 이상 시 → clmux-teams §"에러 대응" 으로 teardown + respawn
```

> teammate name 형식은 `<task>-<provider>` (clmux-teams §Naming Convention). `codex-worker` 같은 generic name은 standalone fallback 한정.

## 참조 자료

- [clmux-teams](../clmux-teams/SKILL.md) — bridge teammate spawn/stop + provider 배치 (송수신 발생 후 운영 측면)
- [clmux-phase](../clmux-phase/SKILL.md) — Phase 워크플로 + 라우팅
- [clmux-veto](../clmux-veto/SKILL.md) — VETO 합의 프로토콜
