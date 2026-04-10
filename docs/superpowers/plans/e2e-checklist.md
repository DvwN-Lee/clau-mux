# Browser Inspect Tool — E2E Manual Validation Checklist

## 환경 준비

- [ ] macOS 13+ / Chrome 130+ / Node.js 20+
- [ ] `cd ~/clau-mux && bash scripts/setup.sh`
- [ ] `source ~/.zshrc`
- [ ] `which clmux-inspect` → 경로 출력
- [ ] `cd examples/react-test-app && npm install && npm run dev &`
- [ ] `curl http://localhost:3000` → HTML 반환

## 세션 시작 (FR-101, FR-102, FR-103)

- [ ] `clmux -n bit-test -gb -T bit-test-team`
- [ ] Chrome 창이 새로 열림
- [ ] `ls ~/.claude/teams/bit-test-team/` → `.browser-service.pid`, `.browser-service.port`, `.chrome.pid` 존재
- [ ] `clmux-inspect status` → `{"status":"running", ...}`

## Chrome 격리 (C6, NFR-301)

- [ ] `ps aux | grep Chrome | grep user-data-dir` → `chrome-profile-bit-test-team` 포함
- [ ] 사용자 일반 Chrome과 PID 다름

## Inspect mode + click (FR-201, FR-202, FR-203)

- [ ] `http://localhost:3000`에서 우상단 라벨 보임
- [ ] `clmux-inspect subscribe team-lead` → 라벨 업데이트
- [ ] 카드 위 hover → 하이라이트
- [ ] 클릭 → 팝업 등장
- [ ] "padding 이상" 입력 + Enter

## Payload 검증 (FR-401, FR-402, FR-405)

- [ ] `cat ~/.claude/teams/bit-test-team/inboxes/team-lead.json | tail -1`
- [ ] `"user_intent": "padding 이상"` 포함
- [ ] `"source_location.file": "src/components/Card.tsx"` 또는 유사
- [ ] `"sourceMappingConfidence": "high"` + `"mapping_tier_used": 1`
- [ ] `"reality_fingerprint"`에 computed_style_subset, cascade_winner 존재
- [ ] `"screenshot"`, `"data:image"`, `"base64"` 키 없음
- [ ] 전체 payload < 20,000자 (< 5000 tokens)

## CLI (FR-601, FR-602)

- [ ] `clmux-inspect query ".card--highlighted" padding color` → JSON
- [ ] 응답 < 500ms (`time clmux-inspect query ...`)
- [ ] `clmux-inspect snapshot ".card--highlighted"` → full payload

## SPA navigation (FR-204)

- [ ] 브라우저 콘솔에서 `history.pushState({}, '', '/new')`
- [ ] 500ms 이내 overlay 복구
- [ ] 새 요소 클릭 → 새 payload 생성

## 구독 전환 (FR-501, FR-502)

- [ ] `clmux-inspect subscribe gemini-worker`
- [ ] `cat ~/.claude/teams/bit-test-team/.inspect-subscriber` → `gemini-worker`
- [ ] 다음 click은 `inboxes/gemini-worker.json`에 기록

## Agent prompt (FR-604, FR-605)

- [ ] Lead에 payload 전달
- [ ] agent가 "source_location.file을 Read한다"로 시작
- [ ] agent가 import count grep 실행
- [ ] 응답에 6개 `- [x]` 체크리스트

## 종료 (FR-104)

- [ ] `tmux kill-session -t bit-test`
- [ ] `ps aux | grep -E 'browser-service|Chrome.*bit-test'` → 없음
- [ ] PID 파일 없음

## 롤백 (NFR-504)

- [ ] `-b` 없이 `clmux -n nobit -g -T nobit-team`
- [ ] Chrome 창 열리지 않음
- [ ] `clmux-inspect status` → `{"status":"stopped"}`
- [ ] gemini teammate 정상 동작

## Pass 조건

모든 체크박스 통과 시 MVP 완료.
