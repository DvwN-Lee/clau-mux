# clau-mux

iTerm2 + zsh 환경에서 Claude Code를 여러 세션으로 독립적으로 실행하기 위한 tmux 래퍼입니다.

## 문제

Claude Code는 동일 디렉토리에서 새 인스턴스를 실행하면 기존 인스턴스와 충돌합니다. 또한 `~/.claude.json` 등 공유 설정 파일에 대한 동시 쓰기 보호가 없어 파일 손상이 발생할 수 있습니다.

## 해결

각 Claude Code 세션을 독립된 tmux 세션으로 격리합니다. tmux는 세션마다 별도의 pseudo-terminal(pty)을 제공하므로 Claude Code의 인스턴스 감지 범위가 분리되어 충돌이 발생하지 않습니다.

동일 이름의 세션이 이미 실행 중이면 새 접근을 차단하여 멀티 인스턴스 충돌을 방지합니다.

## 설치

**1. 저장소 클론**

```bash
git clone https://github.com/your-username/clau-mux.git ~/Desktop/Git/clau-mux
```

**2. zshrc에 추가**

```bash
echo '\nsource ~/Desktop/Git/clau-mux/clmux.zsh' >> ~/.zshrc
source ~/.zshrc
```

**3. tmux 테마 적용 (선택)**

`~/.tmux.conf`에 [tmux 테마 설정](#tmux-테마) 내용을 추가합니다.

## 사용법

### 기본

```bash
# 세션 이름 없이 실행 — 현재 디렉토리 해시(6자)로 자동 지정
$ clmux

# 세션 이름 직접 지정
$ clmux -n PO

# tmux 세션 안에서 실행 — 세션 관리 없이 바로 실행
$ clmux --resume
```

### Claude Code 옵션 전달

`-n` 이외의 모든 옵션은 Claude Code에 그대로 전달됩니다.

```bash
$ clmux -n BE --resume
$ clmux -n FE --continue
$ clmux --resume          # tmux 내부에서 실행 시
```

### 세션 목록 확인

```bash
$ clmux-ls
PO: 1 windows (created Sat Mar  1 14:23:00 2025)
BE: 1 windows (created Sat Mar  1 15:10:00 2025)
```

## 동작 방식

```
tmux 외부
    ├── 세션 없음      →  새 tmux 세션 생성 + Claude Code 실행 + attach
    ├── 좀비 세션      →  자동 정리 후 새 세션 생성
    └── 라이브 세션    →  오류 출력 + 차단 (멀티 인스턴스 충돌 방지)

tmux 내부
    └── 세션 관리 없이 command claude 바로 실행
```

**세션 생명주기**

Claude Code에서 `exit`하면:
1. Claude Code 프로세스 종료
2. tmux 윈도우 닫힘
3. tmux 세션 자동 소멸
4. 원래 터미널로 복귀

다음에 `clmux`를 실행하면 새 독립 세션으로 시작됩니다.

**라이브 세션 차단**

이미 실행 중인 세션에 같은 이름으로 접근하면:

```bash
$ clmux -n PO
error: [PO] session is already running.
  kill with: tmux kill-session -t PO
```

Claude Code는 공유 파일(`~/.claude.json` 등)에 대한 동시 쓰기 보호가 없으므로, 동일 세션 이름으로 중복 실행하면 설정 파일 손상이 발생할 수 있습니다. 이를 방지하기 위해 기존 라이브 세션을 차단합니다.

**브랜치 이름 자동 업데이트**

`clmux.zsh`는 zsh `precmd` 훅을 통해 명령 실행 후 현재 git 브랜치를 감지하고 tmux 윈도우 이름을 자동으로 갱신합니다. 폴링 방식이 아니므로 overhead가 없습니다.

## 옵션

| 옵션 | 설명 |
|------|------|
| `clmux -n <name>` | tmux 세션 이름 직접 지정 |
| `-n` 없이 실행 | 현재 디렉토리 경로의 md5 해시 앞 6자를 세션 이름으로 자동 지정 |
| 그 외 모든 옵션 | Claude Code에 그대로 전달 (`--resume`, `--continue` 등) |

## tmux 테마

Claude Code 브랜드 컬러 기반의 tmux 상태바 테마입니다.

**팔레트**

| 역할 | Hex | 적용 위치 |
|------|-----|-----------|
| Dark | `#141413` | 전체 배경 |
| Orange | `#d97757` | 세션명 배지 |
| Mid Gray | `#b0aea5` | 시각, 보조 텍스트 |
| Muted | `#4a4845` | 날짜 |
| Light | `#faf9f5` | 폴더명 |

**상태바 미리보기**

```
 PO  clau-mux  main                              03/01  14:23
├──────┤├──────────┤├──────┤
orange  dark gray  background
```

> Powerline 구분자(``)를 사용합니다. [Nerd Font](https://www.nerdfonts.com/) 설치 필요.

**`~/.tmux.conf`**

```bash
# ─── 기본 설정 ───────────────────────────────────────────
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",xterm-256color:RGB"
set -g base-index 1
setw -g pane-base-index 1
setw -g automatic-rename off
setw -g allow-rename off
set -g escape-time 0
set -g mouse on

# ─── Status bar ──────────────────────────────────────────
set -g status-position bottom
set -g status-style "fg=#b0aea5,bg=#141413"

# session  folder  branch
# branch (#W) is updated via zsh precmd hook in clmux.zsh — no polling needed
set -g status-left-length 80
set -g status-left "#[fg=#141413,bg=#d97757,bold] #S #[fg=#d97757,bg=#2a2928,nobold]#[fg=#faf9f5,bg=#2a2928] #{b:pane_current_path} #[fg=#2a2928,bg=#141413]#[fg=#6e6c68] #W  "

set -g status-right-length 30
set -g status-right "#[fg=#4a4845] %m/%d  #[fg=#b0aea5,bold]%H:%M "

# ─── Window tabs ─────────────────────────────────────────
# clmux enforces 1 window per session, but tmux shows tabs by default.
# explicitly clear formats to suppress the window index from appearing.
set -g window-status-format ""
set -g window-status-current-format ""
set -g window-status-separator ""

# ─── Pane border ─────────────────────────────────────────
set -g pane-border-style "fg=#2a2928"
set -g pane-active-border-style "fg=#d97757"

# ─── Message / Command prompt ────────────────────────────
set -g message-style "fg=#141413,bg=#d97757,bold"
set -g message-command-style "fg=#faf9f5,bg=#2a2928"
```

**적용**

`~/.tmux.conf`는 tmux 서버 시작 시 자동으로 로드됩니다. 파일을 수정할 때 서버가 이미 실행 중이라면 다음 중 하나를 실행합니다.

```bash
# 현재 서버에 즉시 적용 (모든 세션에 반영됨)
tmux source ~/.tmux.conf

# 서버를 완전히 재시작 (주의: 모든 세션 종료됨)
tmux kill-server
```

## 트러블슈팅

### 진단 명령어

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

### 증상별 해결책

#### 세션이 이미 실행 중이라는 오류

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

#### exit 후에도 세션이 사라지지 않음

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

#### tmux 색상/테마가 적용되지 않음

`~/.tmux.conf`를 생성하거나 수정할 때 tmux 서버가 이미 실행 중이면 새 설정이 자동으로 로드되지 않습니다.

```bash
tmux source ~/.tmux.conf
```

---

#### 브랜치 이름이 갱신되지 않음

`precmd` 훅은 tmux 내부의 zsh 프롬프트가 표시될 때 동작합니다. Claude Code 실행 중에는 zsh 프롬프트가 없으므로 Claude Code 종료 후 프롬프트로 돌아왔을 때 갱신됩니다.

훅이 동작하지 않는 경우 `clmux.zsh`가 정상적으로 로드됐는지 확인하세요.

```bash
type _clmux_precmd
```

---

#### `claude: command not found` 또는 함수가 동작하지 않음

`.zshrc`에 source 라인이 있는지 확인하고, 반드시 파일의 **끝부분**에 위치해야 합니다.

```bash
# source 라인 확인
grep "clau-mux" ~/.zshrc

# 현재 shell에 즉시 적용
source ~/Desktop/Git/clau-mux/clmux.zsh
```

---

### 완전 초기화

```bash
# 1. 모든 tmux 세션 종료
tmux kill-server

# 2. clmux 함수 재로드
source ~/Desktop/Git/clau-mux/clmux.zsh

# 3. 정상 동작 확인
clmux -n test
```

---

## 요구사항

- zsh
- tmux
- Claude Code CLI (`claude`)
- [Nerd Font](https://www.nerdfonts.com/) (tmux 테마 사용 시)
- iTerm2 (다른 터미널도 동작하나 iTerm2 기준으로 검증)

## 주의사항

- iTerm2 Profiles에 `tmux -CC` 자동연결 설정이 있으면 Claude Code TUI와 충돌합니다. 해당 설정은 제거를 권장합니다.
- `~/.tmux.conf`에 `remain-on-exit on` 설정이 있으면 exit 후에도 세션이 유지됩니다.
- Claude Code는 `~/.claude.json` 등 공유 파일에 대한 동시 쓰기 보호가 없습니다. 동일 디렉토리에서 여러 인스턴스를 실행하면 설정 파일이 손상될 수 있습니다. clmux는 이를 방지하기 위해 라이브 세션 중복 접근을 차단합니다.
