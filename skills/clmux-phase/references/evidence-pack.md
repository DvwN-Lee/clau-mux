# Evidence Pack 기반 판정 프로세스

> **적용 범위**: Agent Teams 모드에서의 Cross-Provider 팀 판정
> **근거**: 4-Provider 교차 분석 + 3-Provider 검증 (Claude/Codex/Copilot 합의)

---

## Evidence Pack Schema

```json
{
  "proposal": {
    "solution_id": "S-001",
    "author_hidden_id": "agent-A",
    "claim": "one-line 핵심 주장",
    "scope": "변경 범위"
  },
  "evidence": {
    "files_touched": [],
    "tests_run": 0,
    "tests_passed": 0,
    "benchmark_or_trace_refs": [],
    "citations_logs_diffs": [],
    "provenance_refs": [],
    "environment_hash": ""
  },
  "risk": {
    "security_risk": 0.0,
    "correctness_risk": 0.0,
    "performance_risk": 0.0,
    "maintainability_risk": 0.0,
    "rollback_difficulty": 0.0
  },
  "counterevidence": {
    "strongest_objection": "",
    "unresolved_assumptions": [],
    "conditions_where_solution_fails": []
  },
  "judgment": {
    "task_fit_score": 0.0,
    "evidence_strength_score": 0.0,
    "implementation_cost_score": 0.0,
    "confidence_level": {
      "self_reported": 0.0,
      "evidence_completeness": 0.0,
      "external_validation": 0.0
    }
  },
  "meta": {
    "submission_order": 1,
    "provider_family": "anthropic|google|openai|github",
    "independence_declared": true,
    "methodology": "static_analysis|tdd|research|review",
    "agents_involved": [],
    "ai_usage": "codegen|review|research",
    "reviewer_type": "implementation|critic|security|performance|architecture",
    "decision_status": "adopt|conditional_adopt|reject|escalate",
    "risk_owner": ""
  },
  "github_native": {
    "ci_runs": [],
    "codeql_alerts": 0,
    "coverage": {"line": 0, "branch": 0, "diff": 0},
    "related_issues": [],
    "blast_radius": {"files": 0, "modules": 0, "critical_paths": 0},
    "reviews": {"human_approvals": 0, "copilot_summary_id": ""}
  }
}
```

### 주요 필드 설명

| 필드 | 설명 | 비고 |
|------|------|------|
| `provenance_refs` | 각 evidence가 추출된 artifact 출처 | Codex 제안, 추적성 |
| `environment_hash` | commit SHA / container / test harness | 재현 가능성 보장 |
| `reviewer_type` | 검토자 역할 분류 | 역할별 가중치 적용 |
| `decision_status` | 판정 결과 | `conditional_adopt` = 조건부 채택 |
| `risk_owner` | 채택 후 잔여 리스크 감시 담당 | 후속 추적 |
| `confidence_level` | 3축 분해 (자기평가 + 증거완결성 + 외부검증) | 단일 숫자보다 정밀 |

---

## 판정 프로세스

```
[1] Lead: 문제 정의 + rubric 설정
    - 해법 초안 금지 (Rule 1)
    - 리스크 레벨 판정 (§리스크 레벨별 프로토콜)

[2] Teammates: 독립 초안 제출
    - 상호 참조 없이 작성
    - 스타일 중립화: 정규화 단계에서 출력 형식 통일

[3] 정규화 (2-pass, 구현 담당과 분리)
    Pass 1: 모델 출력 → Evidence Pack 변환 (순환 배정)
    Pass 2: 교차 검토 (다른 Provider가 누락/왜곡 확인)
    GitHub 필드: Copilot 항시 담당

[4] Lead: Evidence Pack 필드값 기반 판정
    - 1차 판정: 정규화된 필드만 사용 (Rule 5)
    - 이의 제기/동률/고위험: raw diff, logs, tests 감사용 제한 검토 허용

[5] Disagreement 처리
    ├── confidence 평균 < 0.5 AND 2라운드 미합의 → Human 에스컬레이션
    ├── security_risk > 0.8 → 즉시 Human 에스컬레이션
    └── 소수 의견 미해결 → 쟁점 카드 승격 (Rule 7)

[6] 채택 조건 (Rule 3 강화)
    - 비-Claude 1개+ provider_family 독립 지지
    - 교차 검증 증거 1개 이상 (구현 Provider ≠ 검증/테스트 Provider인 실행 결과)
    - 기각 사유 + 잔여 리스크 명시 (Rule 6)
```

---

## 리스크 레벨별 프로토콜 차등

| 리스크 | 프로토콜 | 적용 기준 |
|--------|---------|----------|
| **High** | 풀 프로토콜: 독립 초안 + Evidence Pack + 3-way vote + 교차 검증 증거 필수 | 보안, 데이터 유실, 아키텍처 변경, 법적 컴플라이언스 |
| **Medium** | Evidence Pack + 비-Claude 1개 확인 | 기능 구현, API 변경, 성능 최적화 |
| **Low** | CI Green + Copilot PR 리뷰로 자동 승인 | 문서 수정, 포맷팅, 오타 (설정 변경은 Medium 이상) |

Lead가 작업 수신 시 리스크 레벨을 먼저 판정한다. 판정 기준:
- `security_risk > 0.5` OR 인증/인가 관련 → High
- 공개 API 변경 OR DB 스키마 변경 → High
- 내부 로직 변경 + 테스트 존재 → Medium
- 문서/포맷/오타 → Low (설정 변경은 Medium 이상)

---

## provider_family 집계 규칙

| provider_family | 소속 모델 | 독립 Provider 수 |
|---|---|---|
| `anthropic` | Claude Opus, Claude Sonnet, Claude Haiku | 1 |
| `google` | Gemini 3.1 Pro, Gemini 3.0 Flash | 1 |
| `openai` | Codex GPT-5.4 | 1 |
| `github` | Copilot | 1 |

- 같은 provider_family 내 복수 모델의 동의 = **1개 Provider 지지** (2개가 아님)
- Rule 3: anthropic 외 최소 1개 provider_family 독립 지지 + 교차 검증 증거 필수

---

## 2-pass 정규화 프로세스

### 원칙

Evidence Pack 정규화는 **구현 담당과 분리**한다. 자기 산출물을 유리하게 정규화하는 편향을 방지.

### 순환 배정 (Rule 8)

| 라운드 | Pass 1 (정규화) | Pass 2 (교차 검토) |
|---|---|---|
| 1 | Codex | Gemini |
| 2 | Gemini | Copilot |
| 3 | Copilot | Codex |
| 4+ | 순환 반복 | — |

### 고정 배정

| 필드 | 담당 | 근거 |
|------|------|------|
| `github_native.*` | Copilot (항시) | GitHub 네이티브 통합 |
| `evidence.provenance_refs` | Pass 1 담당 | artifact 추적 |
| `meta.environment_hash` | Pass 1 담당 | 재현 환경 기록 |

### 순환 카운터 영속화

현재 라운드 번호는 Lead가 세션 내에서 추적한다.
세션 비정상 종료 대비로 mid-phase checkpoint에 라운드 번호를 포함한다:

```
## 진행 상태
- EP 정규화 라운드: N (현재 Pass 1: {Provider})
```

별도 파일 불필요 — 기존 `.claude/saga/checkpoints/` checkpoint 필드 1개 추가.

### 정규화 완료 기준

- 모든 필수 필드 채움
- `provenance_refs`에 원본 artifact 경로 기록
- Pass 2 교차 검토 완료 (누락/왜곡 0건)
- 스타일 중립화 적용 (프로즈 → 구조화 데이터)

---

## 판정 로그 포맷 (Rule 6)

```markdown
## 판정: [task/안건 ID]
**일시**: YYYY-MM-DD HH:mm
**리스크 레벨**: High | Medium | Low

### 채택안
- solution_id: S-NNN
- provider_family: [채택 제안 출처]
- decision_status: adopt | conditional_adopt
- 채택 근거: [Evidence Pack 필드 기반]
- 교차 검증 증거: [구현 Provider ≠ 검증 Provider인 실행 결과 — 구체 항목]

### 기각안
| solution_id | provider_family | 기각 사유 |
|---|---|---|

### 잔여 리스크
- risk_owner: [담당]
- 미해소 불확실성: [목록]

### 비-Claude 지지 확인
- [지지한 provider_family 목록]
- [교차 검증 증거 유형 + 결과]

### 이의 제기 (있는 경우)
- 이의 Provider: [provider_family]
- raw artifact 검토 여부: [Y/N]
- 결과: [유지/변경]
```

### 판정 로그 감사 (Phase 종료 시)

Phase 종료 시 Copilot이 판정 로그를 파싱하여 편향 드리프트 통계를 자동 생성한다:
- Lead가 각 provider_family 의견을 몇 회 채택/기각했는지
- 특정 Provider 의견이 체계적으로 무시되는 패턴 유무
- 편향 의심 시 Lead에게 피드백

---

## 확증 편향 방지 메커니즘

> "편향을 프롬프트로 억제하려 하지 말고, 편향이 개입할 수 없는 구조를 설계하라"
> — 4-Provider 합의

| 메커니즘 | 대응 편향 | 근거 |
|---|---|---|
| 독립 초안 + 스타일 중립화 | 앵커링, 동조 | 상호 참조 차단 + 정규화 시 형식 통일 |
| 비-Claude 필수 동의 (Rule 3) | Self-preference | LLM judge가 자기 스타일 선호 |
| 교차 검증 증거 필수 (Rule 3 강화) | 공유 환각 + 자기 검증 | 구현 Provider ≠ 검증 Provider 분리 |
| 2-pass 정규화 (Rule 8) | Superficial quality | verbosity/fluency를 correctness로 오인 방지 |
| 구현↔정규화 분리 | 이해충돌 | 자기 산출물 유리 정규화 방지 |
| provider_family 단위 집계 | 독립성 과대평가 | 동일 Provider 복수 모델 ≠ 독립 검증 |
| 반박 역할 고정 (Rule 4) | 확증 편향 | 매 라운드 Codex/Gemini 중 1명 반박자 |
| 판정 로그 + 감사 (Rule 6) | 사후 합리화 | Copilot Phase 종료 시 편향 통계 자동 생성 |
| 소수 의견 보존 (Rule 7) | 다수 동조 압력 | 기각된 의견도 쟁점 카드로 보존 |
| Appeal path | 판정 오류 | 이의 제기 시 raw artifact 제한 재검토 |

### 실증 근거

| 연구 | 핵심 발견 |
|------|---------|
| 보안 코드 리뷰 (2026) | "버그 없음" 프레이밍 시 탐지율 16~93%p 하락 |
| Self-Preference Bias | LLM judge가 자기 스타일(낮은 perplexity) 선호 |
| Superficial Quality Bias | verbosity/fluency를 correctness보다 높이 평가 |
| RAVEN (ICLR 2026) | cross-model disagreement = 이상 탐지 신호 |
| LLM Ensemble | 응답 다양성 평균화만으로 편향 감소 |

---

## 운영 한계

> "Cross-provider validation이 단일 provider 대비 x% 좋다는 정량 연구는 2026년 4월 기준 아직 부족하다."
> — Codex, Claude, Copilot 3자 합의

현재 위치: "완전 입증된 정설"이 아니라 "현재 가장 방어력 높은 운영 설계"
