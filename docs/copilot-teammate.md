← [README](../README.md)

# Copilot Teammate 상세

GitHub Copilot CLI를 Claude Code의 teammate로 연결하여 하나의 tmux 세션에서 Claude Code(lead)와 Copilot(worker)가 협업할 수 있습니다.

## 아키텍처

- Lead → Copilot: `clmux-bridge.zsh`가 inbox를 2초 간격으로 폴링하여 tmux paste-buffer로 Copilot pane에 전달 (send-keys 대신 paste-buffer 사용)
- Copilot → Lead: Copilot이 `write_to_lead` MCP 도구를 호출하면 `bridge-mcp-server.js`가 HTTP/SSE 모드로 outbox에 직접 기록

> Copilot CLI는 stdio MCP 서버를 지원하지 않습니다. `clmux-copilot` 실행 시 `bridge-mcp-server.js`를 HTTP 모드로 자동 시작하고, 할당된 포트를 `~/.copilot/mcp-config.json`에 동적으로 등록합니다.

## 사전 준비

Copilot CLI가 설치 및 인증되어 있어야 합니다 (`copilot` 명령 사용 가능).

`scripts/setup.sh` 실행 시 `~/.copilot/mcp-config.json`에 MCP 서버가 자동 등록됩니다.

수동 등록이 필요한 경우:

```json
{
  "mcpServers": {
    "clau_mux_bridge": {
      "url": "http://127.0.0.1:<port>/sse"
    }
  }
}
```

> 포트는 `clmux-copilot` 실행 시 동적으로 할당됩니다. 스크립트가 자동으로 config를 업데이트하므로 수동 편집은 필요하지 않습니다.

## COPILOT.md

Copilot은 프로젝트 루트의 `COPILOT.md` 파일을 자동으로 읽어 지시사항을 참조합니다. `scripts/setup.sh` 실행 시 기본 `COPILOT.md`가 생성됩니다.

현재 `COPILOT.md`는 `write_to_lead` MCP 호출 프로토콜과 규칙을 정의합니다. 정확한 내용은 프로젝트 루트의 `COPILOT.md` 파일을 참고하세요.

## 사용법

```bash
# Copilot teammate 시작 (팀이 이미 존재해야 함)
clmux-copilot -t <team_name>

# 메시지 전송 (Claude Code 내부에서)
# 에이전트 이름은 <team_name>-copilot-worker 형식을 사용합니다.
SendMessage(to: "<team_name>-copilot-worker", message: "...")

# Copilot teammate 종료
clmux-copilot-stop -t <team_name>
```

## 옵션

| 옵션 | 설명 |
|------|------|
| `-t <team_name>` | 팀 이름 (필수) |
| `-n <agent_name>` | 에이전트 이름 (기본: <team_name>-copilot-worker) |
| `-x <timeout>` | idle 대기 타임아웃 초 (기본: 30) |

## idle 패턴

Copilot의 idle 상태 감지에는 `/ commands` 문자열을 사용합니다. Gemini의 `Type your message`, Codex의 `›` 패턴과 다릅니다.

## 종료 동작

`clmux-copilot-stop -t <team_name>`:
bridge 프로세스 kill → HTTP MCP 서버 kill → Copilot pane kill → env 파일/pid 파일 삭제 → config.json `isActive` 갱신.

> Copilot TUI는 paste-buffer 입력 방식을 사용합니다. `/exit` 등 종료 명령이 불안정할 수 있으므로 `clmux-copilot-stop`을 사용하세요.
