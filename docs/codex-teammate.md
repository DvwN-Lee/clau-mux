← [README](../README.md)

# Codex Teammate 상세

OpenAI Codex CLI를 Claude Code의 teammate로 연결하여 하나의 tmux 세션에서 Claude Code(lead)와 Codex(worker)가 협업할 수 있습니다.

## 아키텍처

- Lead → Codex: `clmux-bridge.zsh`가 inbox를 2초 간격으로 폴링하여 tmux paste-buffer로 Codex pane에 전달 (send-keys 대신 paste-buffer 사용)
- Codex → Lead: Codex가 `write_to_lead` MCP 도구를 호출하면 `bridge-mcp-server.js` (`npx clau-mux-bridge`)가 outbox에 직접 기록

> Codex는 `env_clear` 정책으로 환경변수가 차단될 수 있어 `.bridge-<agent>.env` fallback을 통해 필요한 환경변수를 주입합니다.

## 사전 준비

Codex CLI가 설치 및 인증되어 있어야 합니다 (`codex` 명령 사용 가능).

`scripts/setup.sh` 실행 시 `~/.codex/config.toml`에 MCP 서버가 자동 등록됩니다.

수동 등록이 필요한 경우:

```toml
[mcp_servers.clau_mux_bridge]
command = "npx"
args = ["-y", "clau-mux-bridge"]
```

## AGENTS.md

Codex는 프로젝트 루트의 `AGENTS.md` 파일을 자동으로 읽어 지시사항을 참조합니다. `scripts/setup.sh` 실행 시 기본 `AGENTS.md`가 생성됩니다.

현재 `AGENTS.md`는 `write_to_lead` MCP 호출 프로토콜과 규칙을 정의합니다. 정확한 내용은 프로젝트 루트의 `AGENTS.md` 파일을 참고하세요.

## 사용법

```bash
# Codex teammate 시작 (팀이 이미 존재해야 함)
clmux-codex -t <team_name>

# 메시지 전송 (Claude Code 내부에서)
# 에이전트 이름은 <team_name>-codex-worker 형식을 사용합니다.
SendMessage(to: "<team_name>-codex-worker", message: "...")

# Codex teammate 종료
clmux-codex-stop -t <team_name>
```

## 옵션

| 옵션 | 설명 |
|------|------|
| `-t <team_name>` | 팀 이름 (필수) |
| `-n <agent_name>` | 에이전트 이름 (기본: <team_name>-codex-worker) |
| `-x <timeout>` | idle 대기 타임아웃 초 (기본: 30) |

## idle 패턴

Codex의 idle 상태 감지에는 `›` (U+203A) 프롬프트 문자를 사용합니다. Gemini의 `Type your message` 패턴과 다르므로 혼용 시 주의하세요.

## 종료 동작

`clmux-codex-stop -t <team_name>`:
bridge 프로세스 kill → Codex pane kill → env 파일/pid 파일 삭제 → config.json `isActive` 갱신.

> Codex TUI는 `/exit` 명령의 paste-buffer 입력을 autocomplete로 가로채기 때문에 `SendMessage "/exit"`은 안정적이지 않습니다. `clmux-codex-stop`을 사용하세요.
