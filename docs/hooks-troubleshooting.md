← [README](../README.md)

# Teammate Hooks 트러블슈팅

clau-mux로 Claude Code teammate(네이티브 subagent + clmux bridge)를 구성·운영하는 과정에서 발생한 버그와 해결 기록.

대상은 teammate 라우팅·라이프사이클을 관장하는 hook 두 개에 한정한다:

- `~/.claude/hooks/guard-team-shutdown.py` — SendMessage `shutdown_request` 게이팅
- `~/.claude/hooks/guard-task-bridge.py` — TaskCreate/TaskUpdate의 bridge teammate 라우팅 차단

---

## 1. `TaskUpdate(owner=bridge)`가 bridge teammate에 raw JSON envelope 전달

### 증상

clmux bridge(gemini-worker / codex-worker / copilot-worker)에 `TaskUpdate(owner="gemini-worker")`로 작업을 할당하면, bridge pane에 자연어 지시 대신 다음과 같은 raw JSON envelope이 그대로 출력됨:

```json
{"type":"task_assignment","task_id":"...","instructions":"..."}
```

bridge teammate는 이 envelope을 자연어로 인식하여 `{"type": ...}` 자체를 응답 컨텐츠로 처리하거나 대답하지 못하고 멈춤.

### 원인

Claude Code의 `TaskCreate` / `TaskUpdate(owner=...)`는 내부적으로 SendMessage를 호출하면서 raw JSON envelope을 자동으로 생성하여 assignee에게 전달한다. 네이티브 Claude Code subagent는 이 envelope을 자체 프로토콜로 파싱하지만, **clmux bridge teammate는 envelope 파싱 능력이 없다**. bridge는 자연어 SendMessage만 처리할 수 있다.

### 해결

`guard-task-bridge.py` 작성. PreToolUse hook으로 `TaskCreate|TaskUpdate` matcher에 등록.

```json
{
  "matcher": "TaskCreate|TaskUpdate",
  "hooks": [
    {
      "type": "command",
      "command": "python3 ~/.claude/hooks/guard-task-bridge.py",
      "timeout": 5
    }
  ]
}
```

hook 동작:

1. tool_input의 `assignee` 또는 `owner` 추출
2. 현재 세션 팀 config에서 `agentType == "bridge"` 멤버 이름 set 수집
3. assignee가 set에 포함되면 `deny` + `"<name>: bridge teammate (TaskUpdate 불가, SendMessage 사용)"` 안내

bridge teammate가 마커로 사용하는 `agentType: "bridge"`는 `scripts/update_pane.py`가 clmux bridge spawn 시 명시적으로 설정한다.

### 검증

```
Lead → TaskUpdate(owner="gemini-worker", ...)
→ deny: "gemini-worker: bridge teammate (TaskUpdate 불가, SendMessage 사용)"

Lead → SendMessage(to="gemini-worker", message="자연어 지시")
→ allow ✅
```

---

## 2. SendMessage 평문 `shutdown` 단어로 인한 false positive

### 증상

teammate 종료 보호를 위해 처음에 작성한 hook은 SendMessage의 message 본문에 substring `shutdown`이 포함되면 차단했음. 결과적으로 다음과 같은 일반 대화도 차단됨:

```
Lead → "방금 그 shutdown 버그 어떻게 고쳤어?"
→ ask 프롬프트 발생 (실제 종료 의도 없음)
```

teammate끼리의 일반 대화에서 false positive가 빈번해 hook이 대화 흐름을 방해함.

### 원인

teammate를 실제로 종료시키는 트리거는 SendMessage의 **structured payload**이다:

```json
{"type": "shutdown_request", "reason": "..."}
```

평문에 "shutdown"이 들어 있어도 아무 것도 종료되지 않는다. substring 매칭은 종료 트리거의 정확한 형식을 무시한 over-approximation이며 false positive만 양산한다.

### 해결

`guard-team-shutdown.py`의 매칭 함수를 structured payload 검사로 교체:

```python
def is_shutdown_message(message) -> bool:
    return isinstance(message, dict) and message.get("type") == "shutdown_request"


if __name__ == "__main__":
    data = json.load(sys.stdin)
    message = data.get("tool_input", {}).get("message")
    if not is_shutdown_message(message):
        sys.exit(0)  # 평문 SendMessage는 통과
    # ...
```

평문 SendMessage는 hook을 통과하고, dict + `type == "shutdown_request"`인 경우만 게이팅 로직(active 여부 확인 → ask)으로 진입.

### 검증

```
Lead → SendMessage(to="gemini-worker", message="shutdown 버그 얘기")
→ allow ✅ (평문은 통과)

Lead → SendMessage(to="gemini-worker", message={"type":"shutdown_request","reason":"..."})
→ ask ✅ (structured payload만 게이팅)
```

---

## 3. 동명 teammate가 다른 세션 팀에서 false positive 매치

### 증상

여러 Claude Code 세션이 동시에 활성이고 각각 자체 팀을 가질 때, `~/.claude/teams/` 디렉토리에는 여러 팀 config가 공존한다. 동명의 teammate(예: 두 팀 모두 `gemini-worker`)가 있을 경우 hook이 잘못된 팀의 멤버를 참조하여 다음과 같은 오판이 발생:

- 팀 A에서 active인 `gemini-worker`에 shutdown_request 발송
- hook이 팀 B의 inactive `gemini-worker`를 먼저 매치
- "이미 inactive" deny → 실제로는 active한 멤버 종료 실패

### 원인

`~/.claude/teams/*/config.json`을 단순 glob 스캔하여 첫 매치를 사용했음. 여러 세션의 팀 config가 평면 디렉토리에 공존한다는 사실을 고려하지 않은 lookup 로직.

### 해결

PreToolUse hook은 stdin payload에 `session_id`를 받는다. 이를 `cfg["leadSessionId"]`와 매칭하여 **현재 세션에서 spawn된 팀만 스캔**하는 헬퍼로 교체.

```python
def find_team_member(session_id: str, target_name: str):
    if not session_id or not target_name:
        return None
    pattern = os.path.expanduser("~/.claude/teams/*/config.json")
    for cfg_path in glob.glob(pattern):
        try:
            with open(cfg_path) as f:
                cfg = json.load(f)
            if cfg.get("leadSessionId") != session_id:
                continue  # ← 다른 세션의 팀은 무시
            for m in cfg.get("members", []):
                if m.get("name") == target_name:
                    return m
        except Exception:
            pass
    return None
```

`guard-team-shutdown.py`와 `guard-task-bridge.py` 양쪽에 동일한 패턴 적용. 각 hook의 모든 팀 lookup은 `leadSessionId == data["session_id"]` 필터를 우선 적용한다.

---

## 4. teammate hook reason 메시지 verbose로 인한 노이즈

### 증상

`guard-team-shutdown.py`의 ask 프롬프트가 매번 4–5줄짜리 안내를 출력:

```
[shutdown_request] 'gemini-worker' teammate 종료 요청 — <reason>
※ 승인 시 'gemini-worker' 프로세스가 종료됩니다.
※ 이 hook은 SendMessage 중 shutdown_request payload만 차단합니다 —
  일반 SendMessage 통신은 차단되지 않습니다.
```

`guard-task-bridge.py`의 deny도 유사하게 길었음. 일상 사용에서 매번 같은 안내가 반복 노출되어 본질 정보를 가림.

### 원인

초기 hook 작성 시 사용자 학습용 안내 + 메타 설명을 reason 필드에 함께 적었음. 학습 단계에서 1회 보면 충분한 내용이 매번 반복.

### 해결

teammate hook의 reason 메시지를 **한 줄, 핵심만**의 형식으로 통일:

`guard-team-shutdown.py` (before → after):

```python
# before
return (
    f"[shutdown_request] '{target_label}' teammate 종료 요청"
    f"{reason_line}\n"
    f"※ 승인 시 '{target_label}' 프로세스가 종료됩니다.\n"
    f"※ 이 hook은 SendMessage 중 shutdown_request payload만 차단합니다 — "
    f"일반 SendMessage 통신은 차단되지 않습니다."
)

# after
return f"shutdown_request: '{target_label}'{reason_line}"
```

deny reason도 동일한 원칙으로 축약:

```python
# before: 2–3 문장 (TeamCreate 후 spawn된..., 다시 사용하려면 respawn...)
# after:
emit("deny", f"'{target}': 현재 세션 팀에 존재하지 않음")
emit("deny", f"'{target}': 이미 inactive")
```

`guard-task-bridge.py`도 동일:

```python
# before
f"'{assignee}'는 bridge teammate입니다. "
"TaskUpdate는 raw JSON envelope을 전달하므로 bridge에 부적합합니다. "
"SendMessage로 자연어 지시하세요."

# after
f"'{assignee}': bridge teammate (TaskUpdate 불가, SendMessage 사용)"
```

### 회고

reason 메시지 형식은 hook 작성 시점에 컨벤션으로 못박았어야 했다. 사후에 통일하는 비용이 컨벤션 부재의 직접적 결과. 이후 새 teammate hook 작성 시 첫 메시지부터 이 포맷을 따른다.

---

## 5. `copilot-worker` spawn 성공 후 `isActive=false` 잔류 (미해결)

### 증상

clmux bridge spawn 절차로 copilot bridge를 띄우면 tmux pane은 정상 생성되고 paste-mode 진입까지 확인되지만, `~/.claude/teams/<team>/config.json`의 멤버 항목이 `isActive: false` 상태로 남음.

```json
{
  "name": "copilot-worker",
  "agentType": "bridge",
  "isActive": false,   // ← spawn 성공했음에도 false
  ...
}
```

### 영향

- Lead가 SendMessage 라우팅 시 멤버를 active로 인식하지 못해 outbox 전달 실패할 수 있음
- `guard-team-shutdown.py`가 "이미 inactive" 판단으로 정상 shutdown_request도 deny
- `guard-task-bridge.py`는 영향 없음 (agentType만 검사)

### 진단

- gemini-worker, codex-worker는 동일 절차에서 `isActive: true`로 정상 등록됨
- copilot-worker만 spawn 후 isActive 갱신 누락
- pane 자체는 정상 동작 (paste-mode 진입, 수동 입력 가능)

### 추정 원인

`scripts/update_pane.py`의 copilot 전용 paste-mode 초기화 경로에서 isActive 갱신 호출이 빠진 것으로 의심됨. gemini/codex 경로와 분기된 코드 경로가 별도 isActive write를 수행하지 않을 가능성.

### 현재 상태

미해결 — [#3](https://github.com/DvwN-Lee/clau-mux/issues/3)에서 트래킹. 임시 우회는 config.json 직접 수정(`isActive: true`).

---

## 진단 명령어

```bash
# teammate hook 단독 실행 (실제 PreToolUse 입력과 동일 형식)
echo '{"tool_input":{"to":"gemini-worker","message":{"type":"shutdown_request","reason":"test"}},"session_id":"<id>"}' \
  | python3 ~/.claude/hooks/guard-team-shutdown.py

echo '{"tool_input":{"assignee":"gemini-worker"},"session_id":"<id>"}' \
  | python3 ~/.claude/hooks/guard-task-bridge.py

# 현재 세션의 활성 팀 config만 추출 (session_id로 필터링)
SESSION_ID="<your session id>"
for f in ~/.claude/teams/*/config.json; do
  jq --arg sid "$SESSION_ID" 'select(.leadSessionId==$sid)' "$f"
done

# 특정 teammate의 isActive / agentType 확인
jq '.members[] | select(.name=="<teammate-name>") | {name, agentType, isActive}' \
  ~/.claude/teams/<team>/config.json
```
