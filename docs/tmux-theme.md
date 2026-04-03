← [README](../README.md)

# tmux 테마

## 팔레트

| 역할 | Hex | 적용 위치 |
|------|-----|-----------|
| Dark | `#141413` | 전체 배경 |
| Mid Dark | `#2a2928` | 폴더명 배경, 판 경계, 명령 프롬프트 배경 |
| Orange | `#d97757` | 세션명 배지, 활성 판 경계 |
| Mid Gray | `#b0aea5` | 시각, 보조 텍스트 |
| Muted | `#4a4845` | 날짜 |
| Light | `#faf9f5` | 폴더명 텍스트 |
| Branch Gray | `#6e6c68` | 브랜치명 텍스트 |

## 상태바 미리보기

```
 PO  clau-mux  main                              03/01  14:23
├──────┤├──────────┤├──────┤
orange  dark gray  background
```

> Powerline 구분자(``, `\ue0b0`)를 사용합니다. [Nerd Font](https://www.nerdfonts.com/) 설치 후
> iTerm2에서 **Profiles → Text → Font** 를 Nerd Font로 변경해야 합니다.

## 마우스 토글

`ctrl+g`로 마우스 모드를 즉시 켜고 끌 수 있습니다. 상태바에 현재 상태가 표시됩니다.

```
Mouse: ON   ← ctrl+g →   Mouse: OFF
```

터미널에서 텍스트를 복사할 때 마우스 모드를 잠깐 끄거나, 스크롤 동작을 전환할 때 유용합니다.

## 텍스트 복사

tmux mouse mode가 켜져 있으면 일반 터미널의 Shift+클릭 선택 확장이 동작하지 않습니다.
상황별로 가장 빠른 방법을 사용합니다.

**화면에 보이는 짧은 텍스트 복사**

```
마우스로 드래그 → 손 떼기 → 클립보드 자동 복사 → ⌘+V로 붙여넣기
```

**시작점과 끝점이 멀리 떨어진 텍스트 복사**

```
Option+드래그로 시작점 선택 → Option+Shift+클릭으로 끝점 확장 → 클립보드 자동 복사
```

**스크롤이 필요한 긴 텍스트 복사**

```
ctrl+b → [         copy mode 진입
k/j                스크롤 이동
v                  선택 시작
k/j                선택 범위 확장
y                  복사 (클립보드) + copy mode 종료
```

> copy mode에서 빠져나오기만 하려면 `q`를 누릅니다.

## 적용 방법

파일을 수정할 때 서버가 이미 실행 중이라면 다음 중 하나를 실행합니다.

```bash
# 현재 서버에 즉시 적용 (모든 세션에 반영됨)
tmux source ~/.tmux.conf

# 서버를 완전히 재시작 (주의: 모든 세션 종료됨)
tmux kill-server
```
