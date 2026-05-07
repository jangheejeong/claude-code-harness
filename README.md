# claude-code-harness

> **Claude Code v2.1+** 용 하네스. 평소엔 **`/orchestrator` 한 번만** 타이핑하면 plan 부터 PR 까지 자동. 언어/프레임워크 무관 generic 기본 + 본인 스택 룰 채우기.

[![Claude Code](https://img.shields.io/badge/Claude_Code-v2.1+-purple)](https://code.claude.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

**한국어** | [English](README.en.md)

---

## What This Is

Claude Code 를 "절차에 따라 일하는 개발 파트너" 로 만들어주는 drop-in `.claude/` 설정 모음:

- **Subagent 6개** (explorer, planner, coder, tester, reviewer, documenter) — 각자 격리된 컨텍스트 윈도우에서 동작. verbose 출력이 메인 세션에 흘러들어오지 않음.
- **Verb 스킬 6개** (`/plan`, `/work`, `/review`, `/release`, `/setup`, `/orchestrator`) — 명시적인 워크플로우 단계 + 필수 게이트.
- **안전 hook 2개** — 위험한 셸 명령(`rm -rf /`, `git push --force`, `git reset --hard origin/*`) 차단 + 시크릿 파일(`.env`, `*.pem`, `credentials.json`, `.mcp.json`) 쓰기 거부. 모델 판단이 아니라 코드로 강제.
- **Phase 러너 스크립트** — `scripts/harness/run_phase.py` 로 긴 phase 작업을 메인 컨텍스트 밖으로 격리.
- **문서 템플릿** — `REQUIREMENTS.md`, `ADR-NNN.md`, `DOC_SYNC_POLICY.md`.

## Why a Harness — In Plain Words

Claude Code 는 강력하지만 기본 상태로는 절제가 부족합니다. 이 하네스가 강제하는 5가지:

### 1. Plan-first — "설계도 없이 못 박지 마"
"기능 추가해줘" 하면 Claude 가 바로 코드를 치는 게 아니라, **먼저 `Plans.md` 라는 설계 문서**를 만듭니다. 단계별로 "Phase 1 은 뭘 하고, 다 됐는지 확인하는 기준은 뭐고" 가 적혀있음. 사람이 그거 보고 ✓ 한 다음에야 진짜 코딩 시작. **AI 가 알아서 코딩하다가 산으로 가는 사고 방지.**

### 2. Phase 경계 — "한 입씩 먹어"
한 Phase = 한 번에 리뷰할 수 있는 작은 단위 (대략 400줄 변경 이하). 큰 기능 한 번에 다 짜지 말고 잘게 쪼갬. **이유: 1000줄짜리 PR 은 사람도 제대로 못 봐서 버그가 새어나감.**

### 3. 4-lens 리뷰 — "리뷰는 4개 안경 끼고"
머지 전에 reviewer 가 4가지 관점에서 봅니다:
- **spec**: Plan 에 적힌 거 진짜 됐냐
- **security**: 비밀번호 노출, 인증 누락, SQL 인젝션
- **correctness**: 엣지 케이스, 에러 처리, 네이밍
- **performance**: 느림, 메모리 폭주

여기에 본인 스택 특유의 함정도 추가로 봄. 예: Django 의 N+1 쿼리 (반복문 안에서 `.user.email` 접근하면 100번 DB 가는 그거).

### 4. Hooks over hopes — "막아야 할 건 코드로 막아"
"`rm -rf /` 하지 마세요" 같은 걸 모델에게 부탁하는 게 아니라, **셸 스크립트가 명령 실행 직전에 검사해서 위험하면 차단**. 모델은 깜빡할 수 있지만 스크립트는 안 깜빡함.

### 5. 사람 게이트 — "AI 가 다 해주지 않음"
Plan 승인, BLOCK 판정 시 결정, PR 머지 — 이 3개는 사람이 직접. **"AI 한테 다 맡기고 자버린다" 가 안 되게 강제.**

---

이걸 다 합치면: "AI 가 비싼 부분(코드 작성, 테스트 매핑, 4관점 리뷰)을 처리하고, 사람은 게이트만 통과시킨다" 가 되는 거예요.


## Install

### Quick — Add to an Existing Project

```bash
cd ~/your-project
git clone https://github.com/jangheejeong/claude-code-harness.git .claude-code-harness-tmp
cp -r .claude-code-harness-tmp/.claude ./
cp -r .claude-code-harness-tmp/scripts ./
cp -r .claude-code-harness-tmp/docs ./
cp .claude-code-harness-tmp/CLAUDE.md.example ./CLAUDE.md     # 그리고 본인 프로젝트에 맞게 수정
cp .claude-code-harness-tmp/HARNESS.md ./
rm -rf .claude-code-harness-tmp

# Hook 실행 권한 부여
chmod +x .claude/hooks/*.sh

# Hook 을 settings 에 등록 (또는 기존 settings.local.json 에 병합)
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

이후 `claude` 띄우고 `/agents` 로 6개 agent 로드 확인, `/` 로 6개 verb 스킬 확인.

### Multi-Project Workspace — Monorepo or Multi-Repo

`~/projects/foo/` 안에 여러 독립 git repo 가 있고 그 전체를 하나의 하네스로 다루고 싶다면:

1. 워크스페이스 루트에 `.claude/`, `scripts/`, `docs/`, `CLAUDE.md`, `HARNESS.md` 떨어뜨림.
2. `CLAUDE.md` 의 프로젝트 지도 표를 본인 서브프로젝트들로 채움.
3. 워크스페이스 루트에서 `claude` 실행 — Claude Code 가 그 안의 모든 서브프로젝트에 대해 하네스 적용.

## Usage — The 1-Verb Flow

**외울 verb: `/orchestrator` 1개.** 자연어 작업 설명과 함께 던지면 plan 부터 PR 까지 자동 진행.

```bash
$ cd ~/your-project && claude

> /orchestrator api-server 의 webhook 에 HMAC 검증 추가
   ↓
   [planner agent (opus) 가 자동으로 Phase 분해]
   ↓
   ⛔ Plans.md 검토 + Approval ✓
   ↓
   [Phase 1: coder → tester → reviewer]   APPROVE
   [Phase 2: coder → tester → reviewer]   BLOCK → 자동 fix → APPROVE
   [Phase 3: coder → tester → reviewer]   APPROVE
   ↓
   PR 생성
   ↓
   ⛔ GitHub 에서 직접 머지
```

**그게 다입니다.** 사용자가 타이핑하는 verb 는 `/orchestrator` 1번. 사용자 결정 게이트는 3개:

| Gate | 왜 멈추나 | 사용자가 할 일 |
|---|---|---|
| **Plan 승인** | 잘못된 청사진은 전체를 망침 | Plans.md 검토, Acceptance criteria 측정 가능한지 확인, ✓ |
| **BLOCK verdict** (3회 자동 fix 실패시) | 보안/정확성 이슈 사람 결정 | 직접 코드 수정 후 다시 `/orchestrator` |
| **PR 머지** | main 보호 | GitHub 에서 직접 |

이 3개 외엔 자동. AI 가 Phase 분해 + 구현 + 테스트 + 리뷰 + 자동 fix + PR 생성 다 처리.

### `/orchestrator` 안에서 실제로 일어나는 일

```
1. planner agent (opus, 격리 컨텍스트)
      ↓ 자연어 작업 설명을 분석
      ↓ 코드베이스 인덱싱 (explorer 호출)
      ↓ Phase 1, 2, 3... 분해 + acceptance criteria 작성
      ↓ Plans.md 저장
   ⛔ STOP — 사용자 검토 게이트

2. (Approval 후) for phase in Plans.md:
      coder agent (sonnet, 격리)
         ↓ 구현 + diff 요약 리턴
      tester agent (sonnet, 격리)
         ↓ 테스트 작성/실행 + 결과 리턴
      reviewer agent (opus, 격리)
         ↓ 4 lens 검토 + verdict 리턴
      
      verdict == APPROVE → 다음 phase
      verdict == BLOCK   → coder 다시 호출 (3회 자동 루프)
      3회 실패 → 사용자에게 escalate, ⛔ STOP

3. 모든 phase 완료
      documenter agent → README/CHANGELOG/ADR 갱신
      git commit + push + gh pr create
   ⛔ STOP — PR 머지 대기
```

### Claude 가 매 게이트 끝에 다음 안내

```
[Plan 작성 완료]
   👉 Plans.md 검토 후 ✓ → 작업 자동 진행

[Phase 2 BLOCK — 3회 fix 루프 실패]
   👉 finding 검토 후 직접 수정 → /orchestrator 재실행

[모든 Phase 완료, PR #142 생성]
   👉 GitHub 에서 머지 → 다음 작업이면 /orchestrator
```

외울 게 없어도 다음 행동이 채팅에 뜸.

---

## When to Use Other Verbs

`/orchestrator` 가 평소 흐름이고, 다음 4개는 특수 상황에만 사용.

| Verb | 언제 쓰나 |
|---|---|
| **`/plan`** | Plans.md 의 phase 분해를 **다시 짜고 싶을 때**. 시공은 안 함. (예: orchestrator 가 만든 plan 이 마음에 안 들어서 갈아엎기) |
| **`/work N`** | Plans.md 가 있는 상태에서 **N 번째 phase 만 따로** 돌리고 싶을 때. 디버깅용. |
| **`/review`** | 마지막 작업의 diff 만 **리뷰 다시** 받고 싶을 때 |
| **`/release`** | 자동 PR 생성 대신 **본인 commit/PR 스타일** 따로 있을 때 — 사실 안 써도 됨. 직접 `git commit + gh pr create` |
| **`/setup`** | **신규 서브프로젝트**에 처음 하네스 적용할 때 (한 번만) |

이 5개 verb 는 `/orchestrator` 가 잘 안 풀리거나 단계별로 직접 보고 싶을 때만. 평소엔 무시해도 됨.

---

## When NOT to Use the Harness

다음과 같은 짧은 작업은 `/orchestrator` 도 거치지 말고 그냥 평범하게 채팅:

```
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
| 보안/정확성 중요한 변경 | `/orchestrator` (또는 manual `/plan` + `/work` + `/review`) |
| 멀티-프로젝트 인터페이스 변경 | 한 repo 씩 `/orchestrator` |

**하네스는 3 phase 이상 본격 작업에서 본전.** 그 외엔 우회.

---

## Side Commands

```
> /compact
```
컨텍스트 정리. **작업 사이마다** 권장.

```
> @agent-explorer api-server 의 webhook 라우팅 보여줘
> @agent-reviewer 이 PR 다시 봐줘
> @agent-documenter README 갱신해줘
```
특정 agent 직접 호출 (자동 라우팅 우회). `@` 입력하면 typeahead.

```
> 이번엔 하네스 빼고 그냥 고쳐줘
```
일시적 우회.

---

## 30-Second Cheatsheet

```
1. cd ~/your-project && claude
2. > /orchestrator <자연어 작업 설명>
3. ⛔ Plans.md 검토 + Approval ✓
4. (자동 진행)
5. ⛔ BLOCK 났으면 직접 수정 → /orchestrator 재실행
6. ⛔ GitHub 에서 PR 머지
7. 다음 작업이면 → /orchestrator <다음 작업>
```

**외울 verb: `/orchestrator` 1개.** 끝.


## Project Structure

```
.
├── CLAUDE.md.example         # 템플릿 — CLAUDE.md 로 복사 후 본인 프로젝트에 맞게 수정
├── HARNESS.md                # 종합 사용 가이드 (한글, 12 섹션)
├── .claude/
│   ├── agents/               # 6 subagent 정의
│   ├── skills/               # 6 verb 스킬
│   └── hooks/                # 2 안전 hook
├── scripts/harness/
│   └── run_phase.py          # 컨텍스트 격리 phase 러너
└── docs/harness/
    ├── REQUIREMENTS.template.md
    ├── ADR.template.md
    └── DOC_SYNC_POLICY.md
```

자세한 사용법은 [HARNESS.md](HARNESS.md) 참고 (12 섹션 + 부록 + 트러블슈팅).

## Reviewer — Stack-Agnostic by Default

`reviewer` agent (Opus) 가 4 lens 로 검토:

| Lens | 무엇을 보나 (universal) |
|---|---|
| **Spec** | Acceptance bullet ↔ 코드 라인 매핑 |
| **Security** | secrets, PII 로깅, injection (SQL/command/template), SSRF, path traversal, AuthZ |
| **Correctness** | 엣지 케이스, 에러 핸들링, 네이밍, dead code, 테스트 커버리지 |
| **Performance** | 메모리 폭주, 블로킹 I/O, 로깅 / 트레이싱 / 메트릭 |

**스택 특화 룰은 비어있음** (`<placeholder>` 만 있음). 본인 프로젝트 스택에 맞게 채우는 게 다음 섹션.


## Safety Hooks — What They Block

```
# block-destructive.sh — 18 케이스 테스트 통과:
✓ block: rm -rf /, ~, $HOME, /usr/*, /etc/*, /Library/* ...
✓ block: git push --force, --force-with-lease, -f
✓ block: git reset --hard origin/<branch>
✓ block: dd of=/dev/sd*
✓ allow: rm -rf node_modules, /tmp/foo, .venv (false positive: 0)
✓ allow: git push -u origin feat/x

# protect-secrets.sh — 11 케이스 테스트 통과:
✓ block: .env*, *.pem, *.key, credentials.json, tokens.yaml, .mcp.json
✓ allow: README.md, main.py, credentials.md (문서)
```

## Honest Limitations

- **"개발자 0명" 은 마케팅.** Plan 승인, BLOCK verdict 결정, PR 머지는 사람.
- **Plan 의 품질이 모든 것을 결정.** 부실한 Plan = 부실한 코드 + 부실한 리뷰. Planner(Opus) 에 Opus 토큰 쓰는 게 항상 이득.
- **`/orchestrator` 의 비용은 manual 흐름과 비슷.** 단순 채팅 대비 phase 당 ~3-5x. 5-6배 더 비싸진 않음 (이전 문서가 잘못 표기했었음).
- **멀티 repo 동시 변경**은 하네스가 잘 못 다룸. 한 번에 한 저장소.

## Customize for Your Stack

이 하네스는 의도적으로 **언어/프레임워크 비종속** 으로 출발합니다. 본인 스택에 맞춰 다음 표대로 채우세요.

### 어떤 파일을 무엇으로 채우나

| 커스터마이즈 대상 | 수정할 파일 | 어떻게 채우나 / 참고 |
|---|---|---|
| **스택 특화 리뷰 룰** (ORM N+1, async/sync 혼합, 마이그레이션 안전성, 프레임워크 함정 등) | `.claude/agents/reviewer.md` 의 "Stack-specific" 서브섹션들 | `examples/reviewer-python.md` (Python+Django+FastAPI+Airflow) 또는 `examples/reviewer-java-spring.md` (Java+Spring+JPA+WebFlux) 참고해서 본인 스택 버전 작성 |
| **의존성 매니저 / 린트 / 타입체크 / 테스트 러너 이름** | `.claude/agents/coder.md`, `tester.md` | 이미 generic — Coder/Tester 가 본인 프로젝트의 `pyproject.toml`/`package.json`/`pom.xml` 등을 보고 자동 추론. 특정 도구를 강제하고 싶으면 그 줄에 명시 추가. |
| **빌드 산출물 폴더 (skip 대상)** | `.claude/agents/explorer.md` 의 skip 경로 | `target/`, `build/`, `dist/` 등 이미 포함. 본인 프로젝트 특수 폴더가 있으면 추가 |
| **테스트 폴더 위치** | `.claude/agents/tester.md` | 자동 추론 (`tests/`, `src/test/java/`, `__tests__/` 등). 명시하고 싶으면 한 줄 추가 |
| **프로젝트 지도 / 작업 규칙** | `CLAUDE.md` | `CLAUDE.md.example` 복사해서 본인 프로젝트로 채움 |
| **요구사항 / 인수 기준** | `<subproject>/REQUIREMENTS.md` | `docs/harness/REQUIREMENTS.template.md` 복사해서 채움 |

### 풀 예시 (그대로 복사 → 수정 시작점)

| 스택 | 파일 |
|---|---|
| Python (Django / FastAPI / Airflow) | [`examples/reviewer-python.md`](examples/reviewer-python.md) |
| Java (Spring Boot / JPA / WebFlux) | [`examples/reviewer-java-spring.md`](examples/reviewer-java-spring.md) |
| _Kotlin / Scala / Go / Rust / Ruby / ..._ | (PR 환영) |

복사 명령:
```bash
# 본인 스택 버전을 reviewer 자리에 덮어씌우기
cp examples/reviewer-<your-stack>.md .claude/agents/reviewer.md
```

### 30분 안에 본인 스택 화 체크리스트

1. **Reviewer**: `examples/` 의 본인 스택 버전을 `.claude/agents/reviewer.md` 로 복사. 없으면 본인이 4 lens 매트릭스 채워서 작성.
2. **CLAUDE.md**: `CLAUDE.md.example` 복사해서 본인 프로젝트 지도 / 규칙 채움.
3. **REQUIREMENTS**: 신규 서브프로젝트라면 `docs/harness/REQUIREMENTS.template.md` 복사 → `<subproject>/REQUIREMENTS.md`. `/setup` 스킬도 이 작업 자동화함.
4. **claude 재시작** → `/plan` 으로 첫 작업 시작.

다른 agent (planner, coder, tester, explorer, documenter) 는 모두 stack-agnostic 으로 작성됨. 건드릴 필요 없음.


## License

MIT. [LICENSE](LICENSE) 참고.

## Contributing & Acknowledgments

- 워크플로우 구조: 민세홍님의 6-agent 디자인 (heum 모노레포용) 에서 시작.
- Best-practice 참고: [Chachamaru127/claude-code-harness](https://github.com/Chachamaru127/claude-code-harness), [Anthropic Claude Code 공식 문서](https://code.claude.com/docs).
