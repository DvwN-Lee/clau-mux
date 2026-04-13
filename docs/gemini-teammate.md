← [README](../README.md)

# Gemini Teammate 상세

Gemini CLI를 Claude Code의 teammate로 연결하여 하나의 tmux 세션에서 Claude Code(lead)와 Gemini(worker)가 협업할 수 있습니다.

## 아키텍처

- Lead → Gemini: `clmux-bridge.zsh`가 inbox를 2초 간격으로 폴링하여 tmux send-keys로 Gemini pane에 전달. pane split은 `$TMUX_PANE`(lead)을 기준으로 우측에 생성
- Gemini → Lead: Gemini가 `write_to_lead` MCP 도구를 호출하면 `bridge-mcp-server.js` (`npx clau-mux-bridge`)가 outbox에 직접 기록

## 사전 준비

Gemini CLI가 설치 및 인증되어 있어야 합니다 (`gemini` 명령 사용 가능).

`scripts/setup.sh` 실행 시 `~/.gemini/settings.json`에 MCP 서버가 자동 등록됩니다.

수동 등록이 필요한 경우:

```json
{
  "mcpServers": {
    "clau_mux_bridge": {
      "command": "npx",
      "args": ["-y", "clau-mux-bridge"],
      "trust": true
    }
  }
}
```

## 사용법

```bash
# Gemini teammate 시작 (팀이 이미 존재해야 함)
clmux-gemini -t <team_name>

# 메시지 전송 (Claude Code 내부에서)
# 에이전트 이름은 <team_name>-gemini-worker 형식을 사용합니다.
SendMessage(to: "<team_name>-gemini-worker", message: "...")

# Gemini teammate 종료 (graceful)
SendMessage(to: "<team_name>-gemini-worker", message: "/exit")

# 수동 종료
clmux-gemini-stop -t <team_name>
```

## 옵션

| 옵션 | 설명 |
|------|------|
| `-t <team_name>` | 팀 이름 (필수) |
| `-n <agent_name>` | 에이전트 이름 (기본: <team_name>-gemini-worker) |
| `-x <timeout>` | idle 대기 타임아웃 초 (기본: 30) |

## 종료 동작

`/exit` 전송 시: Gemini CLI 종료 → pane 닫힘 → bridge가 pane 소멸 감지 → outbox에 "gemini-worker has shut down." 기록 → bridge 종료. lead 세션에서 종료 알림을 수신할 수 있습니다.
