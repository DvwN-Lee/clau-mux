---
name: tdd-implementation
description: 구현·버그픽스 작업 시 반드시 사용. 프로덕션 코드에 로직을 추가/수정하거나 버그를 고칠 때 Red-Green-Refactor + scope discipline + Kent Beck warning signs 적용. 트리거 표현 "구현해줘", "implement", "버그 수정", "fix bug", "기능 추가", "refactor", "add feature", "테스트 먼저"를 포함하거나, 프로덕션 소스 파일(.py, .ts, .js, .go, .rs, .java 등)에 로직 변경을 개시하려 할 때 자동 발화. 요구사항 분석·아키텍처 논의·문서 수정·config 편집·exploratory spike·research 작업에서는 사용 금지.
---

# tdd-implementation: 구현 규율

## 발화 조건 (Activation)

**다음 중 하나라도 해당하면 즉시 invoke:**
- 사용자 요청에 구현 의도 표현: "구현", "implement", "feature 추가", "버그 수정", "fix bug", "refactor", "리팩토링"
- 프로덕션 소스 파일에 **로직 있는** 코드 변경 개시 (Edit/Write 실행 직전)
  - 대상 확장자: `.py`, `.ts`, `.tsx`, `.js`, `.jsx`, `.go`, `.rs`, `.java`, `.rb`, `.cpp`, `.c`, `.zsh`, `.sh` 등
- 버그 재현 테스트 필요한 경우

**발화하지 않는 경우 (SKIP):**
- 요구사항 분석·의도 확인 단계 (pre-code)
- 아키텍처/설계 브레인스토밍 (코드 전)
- 문서 수정 (`.md`), config 편집 (`.json`, `.yaml`, `.toml`)
- Type-only 선언, schema 정의
- Migration 스크립트, 일회성 스크립트
- Exploratory spike, prototype
- Research / 조사 작업
- 단순 오타/주석 수정
- 코드 리뷰·검증 작업 (구현이 아닌 판정)

## 핵심 규율 (Mandatory Discipline)

### 1. Red-Green-Refactor 순서 강제

**Red Phase** (실패 테스트):
- 구현 코드 한 줄 쓰기 전에 실패하는 테스트를 먼저 작성
- 테스트를 실행하여 **실패를 눈으로 확인** (올바른 이유로 실패하는지 검증)
- 버그픽스의 경우: 버그를 재현하는 regression test 필수

**Green Phase** (최소 구현):
- 실패 테스트를 통과시키기 위한 **최소한의 코드**만 작성
- 테스트가 green이 되는 순간 다음 phase로 이동
- 현재 테스트가 요구하지 않은 **어떤 기능·엔드포인트·추상화도 추가 금지**

**Refactor Phase** (구조 정리):
- 테스트 green 상태 유지하면서 코드 구조 개선
- **구조적 변경(refactor)과 행동적 변경(기능 추가)은 같은 커밋에 섞지 말 것**
- 둘 다 필요한 경우: 구조 먼저. 모든 테스트가 변경 전후에 green이어야 함

### 2. Test 보존 원칙 (절대 금지 사항)

다음은 **어떤 이유에서도 금지**:
- 테스트 삭제
- 테스트 비활성화 (`.skip()`, `@pytest.mark.skip`, `xit`, `describe.skip`)
- 테스트 약화 (assertion 완화, 예상치 수정으로 현실 맞추기)
- 실패 테스트 주석 처리

위 행위는 **cheating** — Kent Beck이 명시적으로 경고한 LLM agent의 실패 모드. "테스트를 통과시키기 위해 테스트를 수정"하는 순간 TDD 사이클 자체가 무너진다.

테스트가 **진짜로** 틀린 경우 (e.g., 잘못된 assertion 값):
- 수정 **전에** 왜 틀렸는지 명시적으로 설명
- 수정 내용을 사용자에게 투명하게 보고
- 그럼에도 가능하면 test를 고치기보다 코드를 고치는 경로를 먼저 탐색

### 3. Scope Discipline

**out_of_scope 명시 원칙**: 구현 작업 시작 시 작업 범위를 스스로 선언.

- 현재 실패 테스트가 요구하는 것 외의 기능 **추가 금지**
- "다음 단계에 유용할 것 같다"는 이유로 헬퍼·유틸리티 **선제 추가 금지**
- 단순 버그픽스 요청에 대규모 리팩토링 **포함 금지**
- 요청된 파일 외의 파일 수정 시 반드시 이유 설명

### 4. Red-Phase 단독 커밋 허용·권장

실패 테스트만 있는 커밋은 **허용 + 권장**:
- intent reviewable: 리뷰어가 구현 전에 "맞는 테스트를 쓰고 있는가" 검증 가능
- PreToolUse hook이 "테스트 없이 구현" 차단하지 않는 이유: Red phase를 허용하기 위함

### 5. Verification Gap 차단

작업 완료 보고 시:
- 각 acceptance criterion에 대해 **실행 증거** 제시 (출력, exit code, test 결과)
- "구현 완료" 같은 단정 표현 사용 전 [`superpowers:verification-before-completion`] 흐름 따르기
- 검증 책임 주체 명시 (self-verify vs lead-verify)

### 6. 선행 skill 연동

- `superpowers:test-driven-development` — 상세 TDD 프로토콜
- `superpowers:systematic-debugging` — 버그픽스 전용 디버깅 구조
- `superpowers:verification-before-completion` — 완료 전 증거 검증

tdd-implementation은 위 skills의 **필터이자 진입점**이다. 구현 작업 감지 → 해당 skill들의 필요성 판단 → 연쇄 invoke.

## 실패 모드 감시 (Kent Beck Warning Signs)

다음 행위가 감지되면 **즉시 중단 + 사용자 보고**:

1. ⚠️ 요청하지 않은 기능·엔드포인트·클래스 추가 시도
2. ⚠️ 실패 테스트를 skip/delete/weaken 시도
3. ⚠️ 구조적 변경과 행동적 변경을 같은 커밋에 혼합
4. ⚠️ 예상하지 못한 대량 파일 수정 (scope creep)
5. ⚠️ 완료 보고에 acceptance criterion 중 일부만 검증 증거 포함

## 예외 처리

### 예외 범주 명시 (TDD 불필요)
다음 작업에는 TDD 강제 안 됨:
- config 파일 (`.json`, `.yaml`, `.toml`, `.env.example`)
- schema/type 선언 (TypeScript `.d.ts`, OpenAPI schema)
- DB migration (일방향, 테스트 난해)
- 일회성 스크립트 (throwaway)
- 문서·주석·README
- Exploratory spike (후속 PR로 정식화 시 TDD 적용)
- Throwaway prototype

**애매할 때: 테스트를 쓰라.** 모호한 경계에서 쓸지 말지 고민하는 시간이 테스트 작성 시간보다 길다.

## agent-failures 연동

구현 중 새 실패 패턴 발견 시 `~/.claude/agent-failures/` 기록:
- Kent Beck warning sign 해당 → taxonomy: `scope-creep` 또는 `test-tampering`
- Verification gap → taxonomy: `verification-gap`
- 파일 schema: `~/.claude/agent-failures/schema/delegate-outcome-schema.yaml`

## 최소 동작 체크리스트

구현 작업 시작 시 self-check:

- [ ] 이 작업이 발화 조건에 해당하는가? (위 Activation 섹션)
- [ ] 예외 범주에 해당하지 않는가?
- [ ] Red phase 테스트 작성 계획이 있는가?
- [ ] out_of_scope (건드리지 않을 것)를 스스로 선언했는가?
- [ ] 완료 시 verification 방법이 정해져 있는가?

5개 중 하나라도 NO면 **작업 시작 전 보완**.

## 참조

- `~/.claude/agent-failures/schema/intent-v2.yaml` (delegate envelope 기준)
- `~/.claude/agent-failures/guide-delegate.md` (실무 예시 3건)
- Kent Beck "Augmented Coding: Beyond the Vibes" (tidyfirst.substack.com)
- Property-Generated Solver (arXiv:2506.18315) — cycle of self-deception
