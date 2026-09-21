# Claude Code Harness 운영 가이드

이 하네스는 모든 작업을 무겁게 만드는 프레임워크가 아닙니다. 작은 일은 Claude Code 메인이 바로 처리하고, 판단과 검증을 분리할 가치가 있는 일에만 전문 에이전트를 사용합니다.

## 어떤 흐름을 고를까요?

오탈자, 작은 설정 수정, 설명 요청은 메인이 직접 처리합니다. 여러 파일을 바꾸거나 인수 기준이 필요하거나 실패 비용이 큰 작업은 아래 흐름으로 진행합니다.

```text
요구사항 → /plan → /work → /review → /release
```

전체 조율이 필요하면 `/orchestrator`를 호출합니다. orchestrator는 필요한 단계만 선택하며, 모든 에이전트를 의무적으로 호출하지 않습니다.

---

## 단계별 역할

### `/plan`

planner가 코드와 요구사항을 읽고 `Plans.md`에 작은 Phase와 검증 가능한 인수 기준을 작성합니다. 요구사항이 이미 명확한 사소한 변경에는 생략할 수 있습니다.

### `/work`

coder가 승인된 Phase 하나만 구현하고 관련 테스트를 실행합니다. 로그가 길거나 별도의 검증 관점이 필요한 경우에만 tester를 호출합니다. coder와 tester는 커밋이나 푸시를 하지 않습니다.

### `/review`

reviewer가 다음 네 관점을 한 번에 확인합니다.

- 스펙 정합성
- 보안
- 정확성·유지보수성
- 성능·운영성

직접 `/review`를 호출하면 한 번만 검토하고 결과를 반환합니다. 자동 수정 반복은 `/orchestrator`의 책임입니다.

### `/release`

사용자가 명시적으로 요청한 경우에만 documenter, 커밋, 푸시, PR 준비를 수행합니다. 리뷰를 우회하거나 자동으로 머지하지 않습니다.

---

## 수정·재리뷰 규칙

orchestrator는 최초 리뷰를 포함해 최대 3회의 리뷰를 조율합니다. 문제가 있으면 같은 coder가 수정하고 같은 reviewer가 다시 확인해 문맥 손실을 줄입니다.

다음 조건에서는 즉시 멈춥니다.

- reviewer가 승인했습니다.
- 같은 지적이 실질적 변화 없이 반복됐습니다.
- reviewer 결과가 없거나 판정이 불명확합니다.
- 세 번째 리뷰에서도 승인되지 않았습니다.
- 사용자 선택이나 외부 권한이 필요합니다.

Stop 훅으로 정상 종료를 막거나 오케스트레이터를 다시 실행하지 않습니다. 이 규칙은 대화 안의 명시적인 작업 흐름이며, 상태 파일이나 외부 runner에 의존하지 않습니다.

---

## 에이전트 설정

| 에이전트 | 모델 | 추론 강도 | 주 역할 |
|---|---|---|---|
| 메인(새 세션 기본값) | Sonnet | high | 사용자와 작업 조율, 작은 작업 직접 처리 |
| planner | Opus | high | 요구사항·위험·인수 기준 판단 |
| reviewer | Opus | high | 독립 4관점 리뷰 |
| coder | Sonnet | high | 승인된 Phase 구현 |
| tester | Sonnet | high | 선택적 독립 검증 |
| explorer | Sonnet | medium | 읽기 전용 코드 탐색 |
| documenter | Sonnet | low | 검증된 동작의 문서 동기화 |

에이전트 프롬프트에는 역할과 금지사항만 둡니다. 프로젝트 규칙과 인수 기준은 호출할 때 필요한 부분만 전달해 반복 토큰을 줄입니다.

---

## 안전 훅

기본 설정에는 두 개의 `PreToolUse` 훅만 있습니다.

- `block-destructive.sh`: 광범위한 삭제와 강제 Git 작업을 차단합니다.
- `protect-secrets.sh`: `.env`, 개인키, credentials 같은 비밀 파일 쓰기를 차단합니다.

안전 훅은 보조 가드입니다. Claude Code의 권한 설정과 저장소 규칙을 대신하지 않습니다. 여러 설정 계층의 훅은 함께 실행될 수 있으므로 프로젝트 설정이 전역 훅을 자동 대체한다고 가정하지 마세요.

---

## 설치와 업데이트

정본 저장소에서 설치기를 실행합니다.

```bash
python3 scripts/install.py --workspace /Users/jangheejeong/Projects/heum
```

설치기는 전역 에이전트·스킬·안전 훅을 이 저장소의 심볼릭 링크로 맞춥니다. 해시가 확인된 과거 복제본과 루프 상태만 백업 후 제거하고, 사용자 파일이나 프로젝트 전용 스킬은 건드리지 않습니다. workspace 로컬 설정에서는 퇴역한 하네스 훅과 공유 설정의 완전 중복 훅만 제거하고 권한·MCP·사용자 훅은 보존합니다.

과거 하네스가 켠 실험적 Agent Teams 값은 제거합니다. 실행 중인 세션과 `~/.claude/projects`의 기록은 건드리지 않으므로, 새 기본 모델과 플러그인 변경은 새 세션에서 확인하세요.

실행 전에 변경 범위를 보려면 다음 명령을 사용합니다.

```bash
python3 scripts/install.py --workspace /Users/jangheejeong/Projects/heum --dry-run
```

백업은 설치기가 출력한 디렉터리에 남으므로 문제가 있으면 원본을 확인해 복구할 수 있습니다.

---

## 검증과 문제 해결

저장소 자체 검증은 아래 두 명령이면 충분합니다.

```bash
python3 -m unittest discover -s tests -v
bash .claude/hooks/tests/run-tests.sh
```

스킬이 보이지 않으면 새 Claude Code 세션에서 `/skills`를 확인하세요. 훅 오류가 나면 `~/.claude/settings.json`과 프로젝트의 `.claude/settings.json`을 함께 확인해야 합니다. 두 위치의 훅이 합쳐져 실행되기 때문입니다.

모델이나 에이전트 역할을 바꾸면 `.claude/agents/*.md`, `README.md`, 이 문서의 표를 함께 수정하고 계약 테스트를 실행하세요.
