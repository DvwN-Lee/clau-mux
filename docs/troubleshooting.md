← [README](../README.md)

# 트러블슈팅

## 진단 명령어

```bash
# 1. clmux 함수가 올바르게 로드됐는지 확인
type clmux

# 2. 현재 tmux 세션 내부인지 확인 ($TMUX가 비어있으면 외부)
echo $TMUX

# 3. 활성 tmux 세션 목록 확인
tmux ls

# 4. claude 바이너리 위치 확인
type -a claude
```

---

## 증상별 해결책

### 고아 세션 자동 정리

attached 클라이언트가 없는 세션(비정상 종료, agent teams 잔류 등)이 있으면 자동으로 정리하고 새 세션을 생성합니다.

```bash
$ clmux -n PO
[PO] restarting orphaned session.
# → 자동으로 세션 삭제 후 새 세션 생성
```

---

### 세션이 이미 실행 중이라는 오류

```
error: [PO] session is already running.
  kill with: tmux kill-session -t PO
```

다른 터미널에서 동일한 이름의 세션이 실행 중입니다. 해당 세션을 종료한 후 다시 실행하거나, 다른 이름(`-n`)을 사용하세요.

```bash
tmux kill-session -t PO
clmux -n PO
```

---

### exit 후에도 세션이 사라지지 않음

**원인 A**: `~/.tmux.conf`에 `remain-on-exit on` 설정이 있는 경우.

**원인 B**: tmux 내부에서 `clmux` 없이 직접 `claude`를 실행한 경우 (세션 자동 소멸 미적용).

**해결**:
```bash
# remain-on-exit 확인
grep "remain-on-exit" ~/.tmux.conf

# 잔류 세션 일괄 제거
tmux kill-server
```

---

### tmux 색상/테마가 적용되지 않음

```bash
tmux source ~/.tmux.conf
```

---

### 브랜치 이름이 갱신되지 않음

`precmd` 훅은 tmux 내부의 zsh 프롬프트가 표시될 때 동작합니다. Claude Code 실행 중에는 zsh 프롬프트가 없으므로 Claude Code 종료 후 프롬프트로 돌아왔을 때 갱신됩니다.

훅이 동작하지 않는 경우 `clmux.zsh`가 정상적으로 로드됐는지 확인하세요.

```bash
type _clmux_precmd
```

---

### `claude: command not found` 또는 함수가 동작하지 않음

`.zshrc`에 source 라인이 있는지 확인하세요. 파일의 **끝부분**에 위치해야 합니다.

```bash
# source 라인 확인
grep "clau-mux" ~/.zshrc

# 현재 shell에 즉시 적용
source ~/clau-mux/clmux.zsh
```

---

## 완전 초기화

```bash
# 1. 모든 tmux 세션 종료
tmux kill-server

# 2. clmux 함수 재로드
source ~/clau-mux/clmux.zsh

# 3. 정상 동작 확인
clmux -n test
```

---

### Teammate 관련

#### Gemini/Codex teammate 응답 없음

브리지 로그를 확인합니다:

```bash
tail -50 /tmp/clmux-bridge-gemini-worker.log
tail -50 /tmp/clmux-bridge-codex-worker.log
```

일반적인 원인:

- MCP 서버 미등록: `scripts/setup.sh` 재실행
- Codex MCP Tools: (none): npx 패키지 캐시 미확보로 MCP 서버 초기화 timeout — `clmux-codex`는 spawn 전에 npx 캐시를 pre-warm하여 이를 방지
- Gemini MCP 초기화 실패: `~/.gemini/settings.json` 확인
- bridge idle 패턴 불일치: Codex는 `›` (U+203A), Gemini는 `Type your message`

---

#### SendMessage가 inbox에 쓰이지 않음

현재 세션에서 `TeamCreate`가 호출되지 않으면 Claude Code가 file-based inbox 라우팅을 활성화하지 않습니다.

```
TeamCreate(team_name: "<team_name>")
```
