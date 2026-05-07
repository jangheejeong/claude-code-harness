<div align="center">

# claude-code-harness

**Claude Code v2.1+ 용 워크플로우 하네스**

`/orchestrator` 한 번으로 계획 → 구현 → 리뷰 → PR 자동화

`6 subagent` · `6 verb skill` · `2 PreToolUse hook` · `phase runner`

[![Claude Code](https://img.shields.io/badge/Claude_Code-v2.1+-purple)](https://code.claude.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**한국어** · [English](README.en.md)

</div>

---

## What This Is

> Claude Code 가 기본 상태에서 흔히 보이는 두 문제 — **계획 없이 바로 코드부터 시작** + **위험 명령 무방비 실행** — 를 막는 절차 묶음.
>
> 프로젝트 루트에 `.claude/` 트리를 복사하면 활성화.

### Components

| 구성 | 위치 | 역할 |
|---|---|---|
| **Subagents** (6) | `.claude/agents/*.md` | 격리된 context 의 worker — `explorer` / `planner` / `coder` / `tester` / `reviewer` / `documenter` |
| **Verb skills** (6) | `.claude/skills/*/SKILL.md` | 슬래시 명령어 — `/orchestrator` 외 5개 옵션 |
| **PreToolUse hooks** (2) | `.claude/hooks/*.sh` | `block-destructive.sh`, `protect-secrets.sh` |
| **Phase runner** | `scripts/harness/run_phase.py` | 긴 phase 작업 분리 |
| **Doc templates** | `docs/harness/*.md` | `REQUIREMENTS` / `ADR` / `DOC_SYNC_POLICY` |

<details>
<summary><strong>각 컴포넌트 상세</strong></summary>

<br>

**Subagents**
각자 격리된 context window 에서 동작 → verbose 한 tool 출력은 하위 세션에 머물고 메인엔 요약만 반환. 의사결정 비싼 단계 (`planner`, `reviewer`) 만 Opus, 나머지는 Sonnet 으로 모델 비용 분리.

**Verb skills**
`/orchestrator` (메인) + `/plan`, `/work`, `/review`, `/release`, `/setup` (옵션). description 매칭으로 자연어 invocation 가능. `/release` 만 `disable-model-invocation: true` 로 잠가둠 — 커밋/푸시/PR 같은 side effect 가 있어서 사용자 직접 타이핑.

**PreToolUse hooks**
모델 prompt 에 의존하지 않고 stdin JSON → exit code 로 결정.

| Hook | matcher | 차단 대상 | 테스트 |
|---|---|---|---|
| `block-destructive.sh` | `Bash` | `rm -rf` 시스템 경로, `git push --force`, `git reset --hard origin/*`, `dd of=/dev/sd*` | 18 / 18, 오탐 0 |
| `protect-secrets.sh` | `Edit\|Write` | `.env*`, `*.pem`, `credentials*`, `.mcp.json` | 11 / 11 |

**Phase runner**
`claude --agent <name> -p` 래퍼. 긴 phase 작업을 별도 process 로 spawn → `.claude/notes/phase-N-<agent>-<ts>.log` 에 stdout 캡처. 메인 세션 컨텍스트 보호.

**Doc templates**
`REQUIREMENTS.template.md`, `ADR.template.md`, `DOC_SYNC_POLICY.md`.

</details>

---

## Why a Harness

> Claude Code 의 기본 동작은 절차 강제력이 약함. 이 하네스가 강제하는 **5가지 원칙**.

| # | 원칙 | 메타포 |
|:---:|---|---|
| 1 | **Plan-first** | "설계도 없이 못 박지 마" |
| 2 | **Phase 경계** | "한 입씩 먹어" |
| 3 | **4-lens review** | "리뷰는 4개 안경 끼고" |
| 4 | **Hooks over hopes** | "막아야 할 건 코드로" |
| 5 | **Human gates** | "AI 에게 다 맡기고 자버린다 = NO" |

<details>
<summary><strong>각 원칙 자세히</strong></summary>

<br>

### 1. Plan-first
자연어 요청 → 즉시 코드 변경이 아니라, `planner` (Opus) 가 phase 분해 + acceptance criteria 가 담긴 `Plans.md` 를 먼저 생성. 사용자가 approval 박스 ✓ 친 뒤에야 구현 시작.

> Plan 이 부실하면 그 위에 쌓이는 모든 게 부실해짐 — 그래서 Opus 토큰을 이 단계에 투자.

> Claude Code 자체에도 [plan mode](https://code.claude.com/docs/en/permission-modes#analyze-before-you-edit-with-plan-mode) (read-only 탐색 + Plan agent) 가 있음. 본 하네스의 `/plan` 은 그 위에 **phase 분해 + acceptance criteria + 영속화 (Plans.md 파일)** 를 더한 것.

### 2. Phase 경계
1 phase = 1 reviewable 단위 (~400 LoC diff 권장). 4-7 phase 로 분해, 각 phase 가 독립 머지 가능.

> 1000줄 PR 은 사람도 제대로 못 봐서 형식적 리뷰가 됨.

### 3. 4-lens review + 스택별 룰
머지 전 `reviewer` (Opus) 가 4 lens 적용:

| Lens | 무엇을 보나 |
|---|---|
| **Spec** | Plan 에 적힌 성공 조건이 실제 코드에서 충족됐는지 |
| **Security** | 시크릿 노출, 인젝션 (SQL/명령/템플릿), AuthZ, PII 로깅 |
| **Correctness** | 엣지 케이스, 에러 처리, 네이밍, dead code, 테스트 커버리지 |
| **Performance** | 메모리 폭주, async 경로의 blocking I/O, 관측성 결함 |

여기에 스택별 룰 추가. 예: Django ORM N+1, Spring `@Transactional` on private method, FastAPI `async def` 안의 sync DB 호출.

### 4. Hooks over hopes
"`rm -rf` 하지 마세요" 같은 instruction 은 모델이 깜빡할 수 있음. PreToolUse hook 으로 셸 레벨 차단 — 모델이 깜빡해도 hook 은 안 깜빡함. exit code 2 + JSON deny → Claude 에게 차단 사유 표시.

### 5. Human gates
다음 3개는 사람이 직접:

1. **Plan 승인**
2. **BLOCK verdict** 시 결정
3. **PR 머지**

그 외엔 자동.

</details>

> **Net effect**: AI 가 비싼 부분 (분해, 구현, 테스트 매핑, 4관점 리뷰, 자동 fix 루프) 을 처리, 사람은 게이트만 통과.

---

## Install

### 기존 프로젝트에 추가

```bash
cd ~/your-project

git clone https://github.com/jangheejeong/claude-code-harness.git .harness-tmp
cp -r .harness-tmp/.claude ./
cp -r .harness-tmp/scripts ./
cp -r .harness-tmp/docs ./
cp .harness-tmp/CLAUDE.md.example ./CLAUDE.md   # 본인 프로젝트에 맞게 수정
cp .harness-tmp/HARNESS.md ./
rm -rf .harness-tmp

chmod +x .claude/hooks/*.sh

cat > .claude/settings.json <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-destructive.sh" }]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [{ "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/protect-secrets.sh" }]
      }
    ]
  }
}
JSON
```

확인:

```text
> claude
> /agents              # 6 subagent 보여야 함
> /                    # 6 verb skill 보여야 함
```

### 멀티-프로젝트 워크스페이스

여러 독립 git repo 가 한 폴더 아래 모인 환경 (모노레포 X) 이라면, 그 폴더 루트에 `.claude/` 등을 떨어뜨리고 `CLAUDE.md` 의 프로젝트 지도를 본인 서브프로젝트로 채움. 거기서 `claude` 띄우면 모든 서브프로젝트에 하네스 적용.

---

## Usage

### Flow

```mermaid
flowchart TD
    Start[사용자: /orchestrator 자연어 작업] --> Plan[planner Opus 가 Plans.md 작성]
    Plan --> Gate1{사용자 검토}
    Gate1 -->|Approval| Phase[Phase 시작]
    Gate1 -->|수정 요청| Plan

    Phase --> Coder[coder]
    Coder --> Tester[tester]
    Tester --> R[reviewer Opus 검토 시작]

    R --> C1{1. Plan 의 성공 조건<br/>모두 충족?}
    C1 -->|No| BLOCK[BLOCK]
    C1 -->|Yes| C2{2. 보안 / 정확성<br/>이슈 있나?}
    C2 -->|Yes| BLOCK
    C2 -->|No| C3{3. 테스트 모두 통과?}
    C3 -->|No| BLOCK
    C3 -->|Yes| APPROVE[APPROVE]

    BLOCK --> Fix[자동 fix 루프 max 3]
    Fix -->|fail| Gate2[STOP: 사용자 결정]
    Fix -->|success| R
    Gate2 -.수정 후.-> Phase

    APPROVE --> Next{다음 phase?}
    Next -->|Yes| Phase
    Next -->|No| PR[PR 생성]
    PR --> Gate3[STOP: GitHub 머지]

    classDef gate fill:#f59e0b,stroke:#92400e,stroke-width:2.5px,color:#000
    class Gate1,Gate2,Gate3 gate
    classDef block fill:#ef4444,stroke:#7f1d1d,stroke-width:2px,color:#fff
    class BLOCK block
    classDef approve fill:#22c55e,stroke:#14532d,stroke-width:2px,color:#fff
    class APPROVE approve
```

> **Reviewer 의 3단계 판단**: 1번 (Plan 성공 조건) → 2번 (보안/정확성) → 3번 (테스트) 순서로 검사. 셋 다 통과해야 APPROVE, 하나라도 실패하면 BLOCK 후 자동 fix 루프 진입.

### The 1-verb flow

```bash
$ cd ~/your-project && claude

> /orchestrator api-server 의 webhook 에 HMAC 검증 추가
```

| Step | What happens | Time |
|---|---|---|
| **1.** Plan | `planner` 가 phase 분해 + acceptance criteria 작성 → `Plans.md` 저장 | 1-3분 |
| **⛔ Gate** | 사용자가 `Plans.md` 검토 + Approval ✓ | 사람 |
| **2.** Loop | Phase 별 `coder` → `tester` → `reviewer`. BLOCK 이면 자동 fix 루프 (최대 3회) | phase × 5-10분 |
| **3.** Release | `documenter` 가 README/CHANGELOG 갱신 → commit → push → `gh pr create` | 1-2분 |
| **⛔ Gate** | 사용자가 GitHub 에서 PR 머지 | 사람 |

> **외울 verb**: `/orchestrator` 1개. 끝.

### Gates — 사용자 개입 지점

| # | Gate | Why | What you do |
|:---:|---|---|---|
| 1 | **Plan 승인** | 잘못된 청사진 = 전체 망함 | `Plans.md` 검토 + Approval ✓ |
| 2 | **BLOCK verdict** (3회 fix 실패) | 보안/correctness 사람 결정 | 직접 수정 후 `/orchestrator` 재실행 |
| 3 | **PR 머지** | `main` 보호 | GitHub 에서 직접 |

이 3개 외엔 자동.

---

## When to Use Other Verbs

`/orchestrator` 가 평소 흐름. 나머지 5 verb 는 특수 상황용.

| Verb | 언제 쓰나 |
|---|---|
| `/plan` | Plans.md 의 phase 분해를 **다시 짜고 싶을 때** (시공은 안 함) |
| `/work N` | Plans.md 가 있는 상태에서 **N 번째 phase 만 따로** (디버깅) |
| `/review` | 마지막 작업 diff **리뷰만 다시** |
| `/release` | 본인 commit/PR 스타일 따로 있어서 자동 PR 안 쓰고 싶을 때 — 사실 안 써도 됨. `disable-model-invocation: true` 로 잠가둠. <sup>[1]</sup> |
| `/setup` | **신규 서브프로젝트** 첫 부트스트랩 (한 번만) |

<sup>[1]</sup> Claude Code v2.1.74+ 에서 검증. 이전 버전은 슬래시 호출도 막힐 수 있음 ([issue #26251](https://github.com/anthropics/claude-code/issues/26251)). `claude --version` 으로 확인.

---

## When NOT to Use

다음 작업은 `/orchestrator` 거치지 말고 그냥 채팅:

```text
> apps/server.py 의 logger 레벨 INFO 로 바꿔줘
> 이 함수에 docstring 추가해줘
> README 오타 고쳐줘
```

| 상황 | 권장 |
|---|---|
| 한 파일 한두 줄 수정 | 그냥 채팅 |
| 빠른 디버깅 / 탐색 / 스파이크 | 그냥 채팅 |
| README / 문서 단순 수정 | 그냥 채팅 |
| 3 phase 이상 새 기능 / 리팩토링 | `/orchestrator` |
| 보안/정확성 중요한 변경 | `/orchestrator` |
| 멀티-프로젝트 인터페이스 변경 | repo 단위로 `/orchestrator` |

> 하네스는 3 phase 이상 본격 작업에서 본전. 그 외엔 우회.

---

## Side Commands

```text
> /compact
```
컨텍스트 정리. 작업 사이마다 권장.

```text
> @agent-explorer api-server 의 webhook 라우팅 보여줘
> @agent-reviewer 이 PR 다시 봐줘
```
특정 agent 직접 호출 — `@` 입력하면 typeahead.

```text
> 이번엔 하네스 빼고 그냥 고쳐줘
```
일시적 우회.

---

## Cheatsheet

```text
1. cd ~/your-project && claude
2. > /orchestrator <자연어 작업 설명>
3. ⛔ Plans.md 검토 + Approval ✓
4. (자동 진행)
5. ⛔ BLOCK 났으면 직접 수정 → /orchestrator 재실행
6. ⛔ GitHub 에서 PR 머지
7. 다음 작업 → /orchestrator <다음 작업>
```

> 외울 verb: `/orchestrator` 1개.

---

## Project Structure

```text
.
├── CLAUDE.md.example              # 작업 규칙 + 프로젝트 지도 (CLAUDE.md 로 복사)
├── HARNESS.md                     # 종합 사용 가이드
│
├── .claude/
│   ├── agents/                    # 6 subagent
│   │   ├── explorer.md            #   read-only · 코드 탐색
│   │   ├── planner.md             #   Opus · phase 분해
│   │   ├── coder.md               #   1 phase 구현
│   │   ├── tester.md              #   테스트 작성/실행
│   │   ├── reviewer.md            #   Opus · 4 lens + 스택 룰
│   │   └── documenter.md          #   문서 동기화
│   ├── skills/                    # 6 verb skill
│   │   ├── orchestrator/          #   /orchestrator (메인)
│   │   ├── plan/                  #   /plan
│   │   ├── work/                  #   /work N
│   │   ├── review/                #   /review
│   │   ├── release/               #   /release (locked)
│   │   └── setup/                 #   /setup
│   └── hooks/
│       ├── block-destructive.sh   # 위험 셸 명령 차단
│       └── protect-secrets.sh     # 시크릿 파일 쓰기 거부
│
├── scripts/harness/
│   └── run_phase.py               # phase 작업 분리 도구
│
├── docs/harness/
│   ├── REQUIREMENTS.template.md   # 요구사항 양식
│   ├── ADR.template.md            # 결정 기록 양식
│   └── DOC_SYNC_POLICY.md         # 문서 동기화 정책
│
└── examples/
    ├── reviewer-python.md         # Python (Django/FastAPI/Airflow)
    └── reviewer-java-spring.md    # Java (Spring/JPA/WebFlux)
```

> **빌트인과의 이름**: Claude Code 빌트인 subagent (`Explore`, `Plan`, `general-purpose`) 와 본 하네스 커스텀 (`explorer`, `planner`) 은 대소문자가 달라 충돌 안 함. 빌트인은 read-only quick-research 용, 본 커스텀은 Plans.md 연동 워크플로우 전용.

자세한 사용법 / 트러블슈팅 / 비용 가이드는 [HARNESS.md](HARNESS.md) 참고.

---

## Reviewer — Stack-Agnostic by Default

`reviewer` (Opus) 가 PR 직전 4 lens 적용. **Universal lens 는 항상 포함**, **stack-specific 룰은 placeholder 로 비워둠** — 본인 스택에 맞게 채우는 게 다음 섹션.

| Lens | Universal checks |
|---|---|
| **Spec** | Plan 에 적힌 성공 조건이 실제 코드에서 충족됐는지 |
| **Security** | 시크릿 노출, 인젝션 (SQL/명령/템플릿), SSRF, path traversal, AuthZ, PII 로깅 |
| **Correctness** | 엣지 케이스, 에러 처리, 네이밍, dead code, 테스트 커버리지 |
| **Performance** | 메모리 폭주, async 경로의 blocking I/O, 관측성 결함 |

### Verdict tags

| Tag | 의미 |
|---|---|
| `[BLOCK]` | 보안 / correctness / spec 미달. 머지 차단. |
| `[CHANGES]` | 머지 전 수정 권장. |
| `[NIT]` | 선택적 개선. |
| `[EXISTING]` | 기존 코드 이슈. 이번 PR 차단 안 함, 별도 티켓 권장. |

---

## Safety Hooks — What They Block

PreToolUse hooks. stdin JSON 으로 tool input 수신 → exit code `0` (allow) / `2` (deny + reason) 로 결정. `.claude/settings.local.json` 의 `hooks.PreToolUse` 에 wired.

> **권한 모드 우회 불가**: hook 의 `deny` 는 사용자가 `--dangerously-skip-permissions` 또는 `bypassPermissions` 모드로 띄워도 작동. 즉 사용자가 권한 검사 끄고 띄워도 hook 차단은 그대로. 팀 정책 / 보안 가드용으로 신뢰 가능.

### `block-destructive.sh` · matcher: `Bash`

```text
deny:  rm -rf {/, ~, $HOME, /usr/*, /etc/*, /Library/*, ...}
deny:  git push {--force, --force-with-lease, -f}
deny:  git reset --hard origin/<branch>
deny:  dd of=/dev/{sd,nvme,hd,disk}*

allow: rm -rf {node_modules, /tmp/foo, .venv, build}
allow: git push -u origin <branch>
allow: git reset --hard HEAD~1
```

> 18 / 18 케이스 통과, 오탐 0.

### `protect-secrets.sh` · matcher: `Edit|Write`

```text
deny:  .env*, *.pem, *.key, *.p12, *credentials*.{json,yaml}, *token*.{json,yaml}, .mcp.json
allow: README.md, main.py, credentials.md, *.txt   (문서 파일은 OK)
```

> 11 / 11 케이스 통과.

---

## Honest Limitations

- **"개발자 0명" 은 마케팅.** Plan 승인, BLOCK verdict 결정, PR 머지는 사람.
- **Plan 의 품질이 모든 것을 결정.** 부실한 Plan = 부실한 코드 + 부실한 리뷰. Planner 에 Opus 토큰 쓰는 게 항상 이득.
- **`/orchestrator` 비용은 manual 흐름과 비슷.** 단순 채팅 대비 phase 당 약 3-5x.
- **멀티 repo 동시 변경은 약점.** 한 번에 한 저장소.
- **단일 세션 subagent 패턴 채택.** Claude Code 의 [Agent Teams](https://code.claude.com/docs/en/agent-teams) (teammates 간 직접 통신 + 공유 task list) 는 의도적으로 안 씀 — 일반 phase 흐름엔 단일 세션 + 격리 컨텍스트가 더 단순. 10+ 병렬 worker 가 자율 토론하며 일하는 시나리오는 Agent Teams 가 적합 (3-5x 더 저렴).

---

## Customize for Your Stack

> 의도적으로 **언어/프레임워크 비종속** 으로 출발. 본인 스택에 맞춰 다음 표대로 채움.

### What to edit, where

| 커스터마이즈 대상 | 수정할 파일 | How |
|---|---|---|
| **스택별 reviewer 룰** (ORM N+1, async/sync 혼합, 마이그레이션 안전성, 프레임워크 함정) | `.claude/agents/reviewer.md` 의 "Stack-specific" 서브섹션 | `examples/reviewer-python.md` / `examples/reviewer-java-spring.md` 참고하여 작성 |
| **의존성 매니저 / 린트 / 테스트 러너** | `.claude/agents/coder.md`, `tester.md` | 자동 추론 — 강제 시 한 줄 추가 |
| **빌드 산출물 skip 폴더** | `.claude/agents/explorer.md` | 표준 폴더 (`node_modules`, `.venv`, `target`, `build`, `dist`) 이미 포함 |
| **테스트 디렉토리** | `.claude/agents/tester.md` | 자동 추론 — 명시 원하면 한 줄 추가 |
| **프로젝트 지도 / 작업 규칙** | `CLAUDE.md` | `CLAUDE.md.example` 복사 후 채움 |
| **요구사항 / 인수 기준** | `<subproject>/REQUIREMENTS.md` | `docs/harness/REQUIREMENTS.template.md` 복사 후 채움 (또는 `/setup` 자동화) |

### Reference reviewers

| 스택 | 파일 |
|---|---|
| Python (Django / FastAPI / Airflow) | [`examples/reviewer-python.md`](examples/reviewer-python.md) |
| Java (Spring Boot / JPA / WebFlux) | [`examples/reviewer-java-spring.md`](examples/reviewer-java-spring.md) |
| Kotlin / Scala / Go / Rust / Ruby / ... | _PR 환영_ |

복사 명령:

```bash
cp examples/reviewer-<your-stack>.md .claude/agents/reviewer.md
```

### 30분 안에 본인 스택 화

1. `examples/` 에서 본인 스택 reviewer 복사 (없으면 4 lens × stack 서브섹션 직접 채움).
2. `CLAUDE.md.example` → `CLAUDE.md` 로 복사 후 본인 프로젝트 지도/규칙 채움.
3. (필요시) 신규 서브프로젝트 `REQUIREMENTS.md` 채움 — `/setup` 스킬이 자동화.
4. `claude` 재시작 → `/orchestrator <첫 작업>`.

> 다른 agent (`planner`, `coder`, `tester`, `explorer`, `documenter`) 는 모두 stack-agnostic. 건드릴 필요 없음.

---

## License

[MIT](LICENSE)

---

## Contributing & Acknowledgments

- 워크플로우 구조: 민세홍님의 6-agent 디자인에서 시작.
- Best-practice 참고: [Chachamaru127/claude-code-harness](https://github.com/Chachamaru127/claude-code-harness), [Anthropic Claude Code 공식 문서](https://code.claude.com/docs).
- 새 스택 reviewer 추가 PR 환영.
