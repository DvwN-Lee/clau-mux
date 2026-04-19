# clau-mux

Claude Code의 tmux 세션 관리와 Gemini / Codex / Copilot AI teammate 통합을 지원하는 도구입니다.

> **macOS 전용** — macOS + iTerm2 + zsh 환경을 기준으로 개발 및 검증되었습니다.

## 스크린샷

![메인 화면](docs/screenshots/Ready.png)

![종료 흐름](docs/screenshots/Shutdown.png)

## 아키텍처

```mermaid
flowchart LR
  subgraph Lead
    CC[Claude Code]
  end

  subgraph Bridge
    inbox["{agent}.json"]
    bridge[clmux-bridge.zsh]
    mcp[bridge-mcp-server.js]
    outbox[team-lead.json]
  end

  subgraph Teammates["Teammates (선택적)"]
    G[Gemini CLI]
    X[Codex CLI]
    P[Copilot CLI]
  end

  CC -- "SendMessage" --> inbox
  inbox -- "polling 2s" --> bridge
  bridge -. "paste-buffer" .-> G
  bridge -. "paste-buffer" .-> X
  bridge -. "paste-buffer" .-> P
  G -. "write_to_lead (MCP)" .-> mcp
  X -. "write_to_lead (MCP)" .-> mcp
  P -. "write_to_lead (MCP/HTTP)" .-> mcp
  mcp --> outbox
  outbox -- "teammate-message" --> CC
```

> 실제 파일: 에이전트별 inbox (`<agent-name>.json`)와 공용 outbox (`team-lead.json`)가 `~/.claude/teams/<team>/inboxes/`에 생성됩니다.

## 기능

- **세션 격리**: 각 Claude Code 인스턴스를 독립 tmux 세션으로 분리
- **충돌 방지**: 동일 세션 중복 실행 차단, orphaned 세션 자동 정리
- **Gemini Teammate**: Gemini CLI를 Claude Code teammate로 연결 (MCP bridge)
- **Codex Teammate**: OpenAI Codex CLI를 Claude Code teammate로 연결 (MCP bridge)
- **Copilot Teammate**: GitHub Copilot CLI를 Claude Code teammate로 연결 (MCP bridge / HTTP)
- **tmux 테마**: 커스텀 상태바, 마우스 토글, copy mode
- **플러그인 자동 로드**: `CLMUX_PLUGIN_DIR` 환경변수 설정 시, 해당 디렉토리의 유효한 플러그인을 자동으로 `--plugin-dir` 인자로 전달

## 설치

**1. 저장소 클론**

```bash
git clone https://github.com/DvwN-Lee/clau-mux.git ~/clau-mux
```

**2. 설치 스크립트 실행**

```bash
~/clau-mux/scripts/setup.sh
```

스크립트가 자동으로 처리하는 항목:

- `~/.zshrc`에 `clmux.zsh` source 라인 추가 (중복 방지)
- tmux 테마 적용 (선택, 대화형)
- 각 AI teammate 등록 — **개별 선택 가능** (Y/n 프롬프트)
  - Gemini CLI → `~/.gemini/settings.json` MCP 등록
  - Codex CLI → `~/.codex/config.toml` MCP 등록
  - Copilot CLI → `~/.copilot/mcp-config.json` MCP 등록
- `GEMINI.md`, `AGENTS.md`, `COPILOT.md` 지시 파일 생성 (활성화된 teammate만)

> 설치 시 원하지 않는 teammate는 `n`을 입력해 건너뛸 수 있습니다.
> Gemini만 설치하거나 Copilot만 설치하는 등 조합을 자유롭게 선택할 수 있습니다.

**3. 셸 재로드**

```bash
source ~/.zshrc
```

### Prompt 업데이트

`prompt/AGENTS.md`, `GEMINI.md`, `COPILOT.md` 가 변경된 후 `git pull` 했다면, 설치된 사본을 갱신해야 합니다:

```bash
~/clau-mux/scripts/install-prompts.sh
```

`setup.sh` 와 달리 비대화형이며 prompt 영역만 갱신합니다 (tmux/MCP 설정은 건드리지 않음). 실행 중인 bridge teammate는 재시작해야 새 prompt가 반영됩니다.

### 특정 teammate 제거

특정 teammate만 비활성화하거나 전체를 제거할 수 있습니다:

```bash
# Gemini만 제거
bash ~/clau-mux/scripts/remove.sh gemini

# Codex만 제거
bash ~/clau-mux/scripts/remove.sh codex

# Copilot만 제거
bash ~/clau-mux/scripts/remove.sh copilot

# 전체 제거 (clau-mux 완전 삭제)
bash ~/clau-mux/scripts/remove.sh all
```

## 사용법

### 세션 관리

```bash
# 세션 이름 없이 실행 — 현재 디렉토리 해시(6자)로 자동 지정
$ clmux

# 세션 이름 직접 지정 (실제 세션명: <현재_디렉토리>/PO, 예: clau-mux/PO)
$ clmux -n PO

# Claude Code 옵션 전달
$ clmux -n BE --resume
$ clmux -n FE --continue

# Gemini teammate와 함께 세션 시작 (-g 플래그)
$ clmux -g

# Codex teammate와 함께 세션 시작 (-x 플래그)
$ clmux -x

# Copilot teammate와 함께 세션 시작 (-c 플래그)
$ clmux -c

# 여러 teammate 동시 스폰
$ clmux -gcx

# teammate + 팀 이름 지정 (-T 플래그)
$ clmux -g -T my-team
$ clmux -gx -T my-team

# 세션 이름 + teammate + 팀 이름 조합
$ clmux -n PO -gcx -T po-team

# 세션 목록 확인
$ clmux-ls

# orphaned 세션 일괄 제거
$ clmux-cleanup

# 현재 세션의 teammates 확인 (Claude 내부에서 실행 가능)
$ clmux-teammates
# 출력 예시:
# llm-migration
#   ├ %2  gemini-worker (gemini) [alive]
#   ├ %3  codex-worker (codex) [dead]
#   └ %5  impl-worker (claude/sonnet) [alive]
```

> **tmux 내부에서 실행하는 경우**: `$TMUX` 환경변수가 설정되어 있으면 세션 관리 없이
> `command claude [옵션]`을 직접 실행합니다. `-g`/`-x`/`-c` 플래그는 tmux 내부에서도 동작합니다.

### Gemini Teammate

Gemini CLI를 Claude Code의 teammate로 연결합니다. `clmux-bridge.zsh`가 중계 역할을 하며, Gemini는 MCP 도구(`clau_mux_bridge`)를 통해 lead에 응답합니다.

```bash
# 터미널에서 Gemini teammate 시작
clmux-gemini -t <team_name>

# 특정 모델로 시작
clmux-gemini -t <team_name> -m gemini-3.1-pro-preview

# Claude Code Bash tool에서 실행 시 (non-interactive shell이므로 zsh -ic 필요)
zsh -ic "clmux-gemini -t <team_name> -m gemini-3-flash-preview"

# Claude Code 내부에서 메시지 전송
SendMessage(to: "gemini-worker", message: "...")

# 종료
clmux-gemini-stop -t <team_name>
```

자세한 내용은 [Gemini Teammate 상세](docs/gemini-teammate.md)를 참고하세요.

### Codex Teammate

OpenAI Codex CLI를 Claude Code의 teammate로 연결합니다. Codex는 MCP 도구(`clau_mux_bridge`)를 통해 lead에 응답합니다.

```bash
# 터미널에서 Codex teammate 시작
clmux-codex -t <team_name>

# Claude Code Bash tool에서 실행 시
zsh -ic "clmux-codex -t <team_name>"

# 특정 모델로 시작
clmux-codex -t <team_name> -m gpt-5.4

# Claude Code 내부에서 메시지 전송
SendMessage(to: "codex-worker", message: "...")

# 종료
clmux-codex-stop -t <team_name>
```

자세한 내용은 [Codex Teammate 상세](docs/codex-teammate.md)를 참고하세요.

> **Bridge 내부 동작**: Codex는 instruction-following 특성상 일부 conversational 메시지(예: identity 질문, 짧은 greeting)에 대해 `write_to_lead` 호출을 skip 하는 경향이 있어, bridge 가 codex 전용으로 paste 직전 `[Bridge message — reply via write_to_lead]` prefix 를 자동 추가합니다. Gemini/Copilot 는 이 wrapping 적용되지 않습니다 (해당 모델은 wrapping 없이도 일관 호출).

### Copilot Teammate

GitHub Copilot CLI를 Claude Code의 teammate로 연결합니다. Copilot은 HTTP/SSE 기반 MCP 서버를 통해 lead에 응답합니다.

```bash
# 터미널에서 Copilot teammate 시작
clmux-copilot -t <team_name>

# Claude Code Bash tool에서 실행 시
zsh -ic "clmux-copilot -t <team_name>"

# 특정 모델로 시작
clmux-copilot -t <team_name> -m claude-sonnet-4

# Claude Code 내부에서 메시지 전송
SendMessage(to: "copilot-worker", message: "...")

# 종료
clmux-copilot-stop -t <team_name>
```

자세한 내용은 [Copilot Teammate 상세](docs/copilot-teammate.md)를 참고하세요.

> **참고**: `clmux -c`로 스폰 시 `copilot --yolo` 플래그, `clmux-copilot`으로 스폰 시 `copilot --allow-all-tools` 플래그가 사용됩니다.

> **모델 호환성 (2026-04 기준)**: GitHub이 `gpt-5.1` 계열을 deprecate(2026-04-01)했고, `claude-sonnet-4.5` 도 백엔드 400 에러로 사용 불가 ([copilot-cli#2597](https://github.com/github/copilot-cli/issues/2597)). Copilot 시작 시 `model_not_supported` 에러가 발생하면 `~/.copilot/config.json` 의 `model` 을 `claude-sonnet-4.6`, `gpt-5.3-codex`, 또는 `gemini-3-pro` 등 [지원 모델](https://docs.github.com/en/copilot/reference/ai-models/supported-models) 로 변경하세요.

#### 전체 워크플로우 예시

```bash
# 1. lead 세션 시작 (Gemini + Codex + Copilot teammate 함께 스폰)
clmux -n my-project -gcx -T my-team

# 또는 일부 teammate만 선택
clmux -n my-project -g -T my-team   # Gemini만
clmux -n my-project -x -T my-team   # Codex만

# 2. 필요 시 추가 teammate 스폰
clmux-copilot -t my-team

# 3. Claude Code 내부에서 메시지 전송
TeamCreate(team_name: "my-team")
SendMessage(to: "gemini-worker", message: "...")
SendMessage(to: "codex-worker", message: "...")
SendMessage(to: "copilot-worker", message: "...")

```

### Family (Pattern B v2)

기존 **Team** (Pattern A — Lead 1개 + 가상 multi-pane teammates) 과 별도로, **여러 Claude Code 세션이 별도 tmux pane에서 hierarchical 관계로 협업**하는 패턴.

**핵심 차이:**
- **Team**: Lead 1개 + N teammates (모두 Lead와 직접 통신, flat)
- **Family**: Lead 1개 + N Teammates (각자 독립 세션) + Teammates가 자체 Worker subagents fan-out (3-tier)

**MVP scope (v2)**: 1 Lead + 1 Teammate + 2 Workers — fan-out + consolidate 검증.

**핵심 특성:**
- 모든 통신은 native teammate-message UX (사용자 polling 불필요)
- Worker는 subagent로 ephemeral (Tier 3) — Teammate에게만 sync 결과 반환, Lead에 직접 통신 불가 (정보 격리 자동)
- Lead가 직접 `Agent()` SDK tool 호출로 Teammate spawn (zsh wrapper 별도 없음 — 패턴이 곧 구현)

**사용 (요약):**

```
1. TeamCreate({team_name: "<my-team>"})
2. Agent({
     team_name: "<my-team>",
     name: "<teammate-name>",
     subagent_type: "general-purpose",
     model: "sonnet",
     run_in_background: true,
     prompt: "<role + scope + Worker 지침 인라인>"
   })
3. (Teammate가 자율적으로 Worker fanout + consolidate)
4. Lead가 native teammate-message로 결과 자동 수신
```

**상세 가이드 + 재사용 가능한 spawn prompt template + smoke test 절차**: [`docs/family-smoke-test.md`](docs/family-smoke-test.md)

**설계 근거**: [`docs/superpowers/specs/2026-04-19-family-teammate-ux-requirements.md`](docs/superpowers/specs/2026-04-19-family-teammate-ux-requirements.md), [`docs/superpowers/specs/2026-04-19-family-mvp-design.md`](docs/superpowers/specs/2026-04-19-family-mvp-design.md)

## 명령어 요약

| 옵션 | 설명 |
|------|------|
| `clmux -n <name>` | tmux 세션 이름 직접 지정 (실제 생성 이름: `<현재_디렉토리>/<name>`) |
| `-n` 없이 실행 | 현재 디렉토리 경로의 md5 해시 앞 6자를 세션 이름으로 자동 지정 |
| `clmux -g` | 세션 시작 시 Gemini teammate 자동 스폰 |
| `clmux -x` | 세션 시작 시 Codex teammate 자동 스폰 |
| `clmux -c` | 세션 시작 시 Copilot teammate 자동 스폰 |
| `clmux -T <team>` | `-g`/`-x`/`-c` 와 함께 사용 — teammate에 사용할 팀 이름 지정 |
| 그 외 모든 옵션 | Claude Code에 그대로 전달 (`--resume`, `--continue` 등) |
| `clmux-teammates` | 현재 세션의 teammate 목록 (팀별 트리, pane ID, CLI 타입, alive/dead 상태) |
| `clmux-ls` | 활성 세션 목록 + orphaned 세션 경고 표시 |
| `clmux-cleanup` | attached 클라이언트 없는 orphaned 세션 일괄 제거 |
| `clmux-gemini -t <team> [-n <name>] [-x <sec>] [-m <model>]` | Gemini CLI를 teammate로 연결 (예: `-m gemini-3.1-pro-preview`) |
| `clmux-gemini-stop -t <team> [-n <name>]` | Gemini teammate 종료 |
| `clmux-codex -t <team> [-n <name>] [-x <sec>] [-m <model>]` | Codex CLI를 teammate로 연결 (예: `-m gpt-5.4`) |
| `clmux-codex-stop -t <team> [-n <name>]` | Codex teammate 종료 |
| `clmux-copilot -t <team> [-n <name>] [-x <sec>] [-m <model>]` | Copilot CLI를 teammate로 연결 (예: `-m claude-sonnet-4`) |
| `clmux-copilot-stop -t <team> [-n <name>]` | Copilot teammate 종료 |

## 요구사항

- macOS
- zsh
- tmux
- Claude Code CLI (`claude`)
- [Nerd Font](https://www.nerdfonts.com/) (tmux 테마 사용 시)
- iTerm2 (다른 터미널도 동작하나 iTerm2 기준으로 검증)
- Gemini CLI (`gemini`) — Gemini teammate 사용 시
- Codex CLI (`codex`) — Codex teammate 사용 시
- Copilot CLI (`copilot`) — Copilot teammate 사용 시
- Node.js / npm — MCP 서버 (`npx clau-mux-bridge`) 실행 시
- `curl` — Copilot MCP 서버 헬스체크 시
- Python 3 — bridge 헬퍼 스크립트 실행 시

## 주의사항

- iTerm2 Profiles에 `tmux -CC` 자동연결 설정이 있으면 Claude Code TUI와 충돌합니다. 해당 설정은 제거를 권장합니다.
- `~/.tmux.conf`에 `remain-on-exit on` 설정이 있으면 exit 후에도 세션이 유지됩니다.
- Claude Code는 `~/.claude.json` 등 공유 파일에 대한 동시 쓰기 보호가 없습니다. 동일 디렉토리에서 여러 인스턴스를 실행하면 설정 파일이 손상될 수 있습니다. clmux는 이를 방지하기 위해 라이브 세션 중복 접근을 차단합니다.
- `ctrl+b d`로 세션을 detach한 후 같은 이름으로 `clmux`를 재실행하면 기존 세션이 orphaned로 판단되어 종료됩니다. agent teams가 아직 실행 중이라면 함께 종료되므로 주의하세요.
- `clmux-bridge.zsh`는 큰 메시지(>300자)를 300자 단위 청크로 분할하여 paste-buffer로 전달합니다. macOS PTY 버퍼 한계(~1024 bytes)로 인해 단일 paste 이벤트는 잘릴 수 있으며, 청크 분할 방식으로 이를 우회합니다.
- **함수 업데이트 시 shell 재-source 필요**: `clmux.zsh` (및 `lib/*.zsh`)를 pull/수정한 후, 이미 열려있던 tmux pane의 zsh 세션은 이전 함수 정의를 캐시한 상태를 유지합니다. Claude Code Bash tool 역시 장기 지속 shell을 재사용하므로 새 정의를 보지 못합니다. 처치: 영향받은 pane에서 `exec zsh` 실행(해당 shell 재기동) 또는 새 tmux session 시작.

## 세부 문서

- [세션 관리 상세](docs/session-management.md)
- [Gemini Teammate 상세](docs/gemini-teammate.md)
- [Codex Teammate 상세](docs/codex-teammate.md)
- [Copilot Teammate 상세](docs/copilot-teammate.md)
- [tmux 테마](docs/tmux-theme.md)
- [트러블슈팅](docs/troubleshooting.md)
- [Hooks 설계 회고](docs/hooks-retrospective.md)
- [Hooks 트러블슈팅](docs/hooks-troubleshooting.md)
