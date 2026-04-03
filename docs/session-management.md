← [README](../README.md)

# 세션 관리 상세

## 동작 방식

```
tmux 외부
    ├── 세션 없음      →  새 tmux 세션 생성 + Claude Code 실행 + attach
    ├── 고아 세션      →  자동 정리 후 새 세션 생성 ([PO] restarting orphaned session.)
    └── 라이브 세션    →  오류 출력 + 차단 (멀티 인스턴스 충돌 방지)

tmux 내부
    └── 세션 관리 없이 command claude 바로 실행
```

## 세션 생명주기

Claude Code에서 `exit`하면:
1. Claude Code 프로세스 종료
2. tmux 윈도우 닫힘
3. tmux 세션 자동 소멸
4. 원래 터미널로 복귀

## 라이브 세션 차단

이미 실행 중인 세션에 같은 이름으로 접근하면:

```bash
$ clmux -n PO
error: [PO] session is already running.
  kill with: tmux kill-session -t PO
```

Claude Code는 공유 파일(`~/.claude.json` 등)에 대한 동시 쓰기 보호가 없으므로, 동일 세션 이름으로 중복 실행하면 설정 파일 손상이 발생할 수 있습니다. 이를 방지하기 위해 기존 라이브 세션을 차단합니다.

## 브랜치 이름 자동 업데이트

`clmux.zsh`는 zsh `precmd` 훅을 통해 명령 실행 후 현재 git 브랜치를 감지하고 tmux 윈도우 이름을 자동으로 갱신합니다. 폴링 방식이 아니므로 overhead가 없습니다.

> **주의**: 브랜치명 자동 갱신이 동작하려면 tmux의 `automatic-rename`이 비활성화되어 있어야 합니다.
> 저장소의 `tmux.conf`에는 `setw -g automatic-rename off`가 설정되어 있습니다.
> 기존 tmux 설정에 `automatic-rename on`이 있으면 브랜치명이 즉시 덮어써집니다.

> **참고**: Git 저장소가 아닌 디렉토리로 이동하면 윈도우 이름은 갱신되지 않고
> 마지막으로 감지된 브랜치명을 유지합니다.
