# claude-code-harness

> **Claude Code v2.1+** 용 Plan → Work → Review → Release 하네스. **언어/프레임워크 무관 generic 기본 + 본인 스택 룰 채우기** 구조.

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

## Usage — Step by Step

처음 굴리면 30초가 아니라 30분 걸려요. 흐름 익히면 그때부터 빨라집니다. 아래는 **"`api-server` 의 webhook 에 HMAC 검증 추가"** 라는 가상의 작업으로 처음부터 끝까지 따라가는 가이드.

### Step 0 · Claude Code 켜기

새 터미널에서:

```bash
cd ~/your-project       # 본인 프로젝트 루트
claude                  # Claude Code 실행
```

확인:
```
> /agents
```
→ Project agents 섹션에 `coder`, `documenter`, `explorer`, `planner`, `reviewer`, `tester` 6개 보이면 OK.

```
> /
```
→ 슬래시 메뉴에 `/plan`, `/work`, `/review`, `/release`, `/setup`, `/orchestrator` 6개 보이면 OK.

---

### Step 1 · 작업 의도 던지고 `/plan`

원하는 걸 자연어로 한 문장 + `/plan`:

```
> api-server 의 webhook 에 HMAC 검증 붙이고 싶어. /plan 으로 가자
```

**Claude 가 자동으로 하는 일** (1-2분 소요):
1. `explorer` agent 가 `api-server/` 코드를 탐색
2. `planner` agent (Opus) 가 작업을 **Phase 단위로 분해**
3. `api-server/Plans.md` 파일에 Plan 저장
4. 채팅창에 "Plans.md 저장 완료, 검토하세요" 메시지

**⛔ 여기서 자동으로 멈춤.** 다음 사용자 액션 필요.

> 💡 **Phase 가 뭔가요?**
> 한 번에 머지할 수 있는 작은 변경 단위 (대략 400줄 이하). 큰 기능을 3-7개 Phase 로 잘게 쪼갬. Phase 1, 2, 3 순서대로 한 개씩 진행.

---

### Step 2 · ⛔ 사용자 액션: Plans.md 검토 + 승인

별도 에디터에서 파일 열기:

```bash
# 새 터미널에서 (Claude 채팅은 그대로 두고)
cursor api-server/Plans.md
# 또는 vim, vscode, etc.
```

Plans.md 안에서 **확인할 것 4가지**:

- [ ] 각 Phase 의 **Acceptance criteria** 가 측정 가능한가?
   - 좋은 예: `pytest tests/api/test_webhook.py::test_valid_signature passes`
   - 나쁜 예: `webhook 이 잘 작동함`
- [ ] **Out of scope** (이번에 안 할 것) 가 명확히 적혀있는가?
- [ ] **Open questions** (열린 질문) 이 다 답변됐는가?
- [ ] 최하단 **Approval** 섹션 두 박스에 ✓ 체크

이상하면 Claude 채팅으로 돌아가서:
```
> Phase 2 가 너무 크다. webhook 등록과 secret 로테이션 둘로 쪼개서 다시 짜줘
```
→ Planner 가 다시 돔. Plans.md 갱신됨.

OK 면 다음 단계로.

---

### Step 3 · Phase 1 구현 — `/work 1`

Claude 채팅창에서:

```
> Plans.md 승인했어. /work 1
```

**Claude 가 자동으로 하는 일** (몇 분 소요):
1. `coder` agent 가 Phase 1 의 Acceptance criteria 만 보면서 **최소한의 코드 변경** 으로 구현
2. `tester` agent 가 Phase 1 의 Acceptance bullet 마다 **테스트 매핑 + 실행**
3. 통과하면 채팅창에 diff 요약 + 테스트 결과 출력

**⛔ 여기서 또 멈춤.**

---

### Step 4 · ⛔ 사용자 액션: diff 한 번 보기 (선택)

```bash
# 새 터미널
cd ~/your-project
git diff
```

이상하면 Claude 한테 자연어로:
```
> router.py 의 변수명 payload 를 request_body 로 바꿔줘
```
→ Coder 가 다시 돔.

OK 면 다음 단계로.

---

### Step 5 · 리뷰 게이트 — `/review`

Claude 채팅창에서:

```
> /review
```

**Claude 가 자동으로 하는 일** (1-2분 소요):
1. `reviewer` agent (Opus) 가 git diff 를 읽고
2. **4 lens** (spec / security / correctness / performance) + 본인 스택 룰로 검토
3. **Verdict 출력**: `APPROVE` / `REQUEST CHANGES` / `BLOCK`
4. 발견사항이 있으면 자동으로 Coder 에게 다시 핑 (최대 3회 자동 루프)

**⛔ 여기서 또 멈춤.**

| Verdict | 다음 행동 |
|---|---|
| **APPROVE** ✅ | Step 6 으로 |
| **REQUEST CHANGES** 🟡 | 자동 루프 안 풀렸으면 직접 수정 후 다시 `/review` |
| **BLOCK** 🔴 | 보안/정확성 이슈. 무조건 직접 수정하고 다시 `/review` |

---

### Step 6 · 배포 — `/release` (반드시 직접 타이핑)

```
> /release
```

> ⚠️ **이건 자동 차단 걸려있음.** Claude 가 알아서 발동 안 하니까 사용자가 직접 타이핑해야 함. 커밋/푸시/PR 같은 사이드 이펙트 보호용.

**Claude 가 자동으로 하는 일**:
1. `documenter` agent 가 README / CHANGELOG / ADR 문서 동기화
2. Plans.md 의 Phase 1 체크박스 마킹
3. `git commit` (Phase 1 파일 + 문서 + CHANGELOG 만)
4. `git push -u origin <branch>`
5. `gh pr create` → PR URL 출력

**⛔ 여기서 또 멈춤.**

---

### Step 7 · ⛔ 사용자 액션: GitHub 에서 PR 머지

```bash
gh pr view <num> --web
```
브라우저에서 직접 머지 클릭. 또는 동료 리뷰 받고.

> ⚠️ **자동 머지 절대 안 함.** main 브랜치 보호.

---

### Step 8 · 다음 Phase

Claude 채팅창으로 돌아와서:
```
> /work 2
```

→ Step 3 ~ 7 반복. 모든 Phase 끝나면 작업 완료.

---

## Usage — 짧은 작업은 하네스 우회

3 phase 안 들어가는 작업이면 그냥 평범하게 채팅:

```
> apps/server.py 의 logger 레벨 INFO 로 바꿔줘
```

→ Claude 가 그냥 평범하게 처리. 하네스 verb 안 거쳐도 됨.

| 상황 | 권장 |
|---|---|
| 한 파일 한두 줄 수정 | 그냥 채팅 |
| 빠른 디버깅 / 탐색 | 그냥 채팅 |
| README 오타 수정 | 그냥 채팅 |
| 3 phase 이상 들어가는 작업 | 하네스 풀 사용 |
| 보안/정확성 중요한 변경 | 하네스 풀 사용 |

---

## Usage — 자주 쓰는 부가 명령

```
> /compact
```
컨텍스트 정리. **Phase 사이마다 권장** (안 하면 토큰이 95% 차면 자동 정리되긴 함).

```
> @agent-explorer api-server 의 webhook 라우팅 보여줘
> @agent-reviewer 이 PR 다시 봐줘
> @agent-documenter README 갱신해줘
```
특정 agent 직접 호출 (자동 라우팅 우회). `@` 입력하면 후보 typeahead.

```
> 이번엔 하네스 빼고 그냥 고쳐줘
```
일시적으로 하네스 우회.

---

## 30-Second Cheatsheet

이미 흐름 익혔다면 이것만 보면 됨:

```
1. cd ~/your-project && claude
2. > <뭐> 추가하고 싶어. /plan 가자
3. ⛔ Plans.md 검토 + Approval ✓
4. > /work 1
5. ⛔ git diff 확인
6. > /review
7. ⛔ verdict 확인 (APPROVE 면 다음, 아니면 수정)
8. > /release        ← 직접 타이핑
9. ⛔ GitHub 에서 PR 머지
10. > /work 2 ... 반복
```


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

- **"개발자 0명" 은 마케팅.** Plan 승인, BLOCK verdict, PR 머지는 사람 결정.
- **Plan 의 품질이 모든 것을 결정.** 부실한 Plan = 부실한 코드 + 부실한 테스트 + 부실한 리뷰. Planner 에 Opus 토큰 쓰는 게 항상 이득.
- **비용 감각.** 풀 `/orchestrator` 한 사이클은 단순 채팅 대비 ~5-6배. Phase 잘게 쪼개거나 사소한 작업은 하네스 우회.
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
