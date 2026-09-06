# Claude Code Harness — 종합 가이드

your project / workspace root 에 설치된 Claude Code 하네스의 사용설명서 + 동작 원리 문서.

---

## 0. 한 줄 요약

> 하네스는 "AI가 알아서 다 해줘요" 마법이 아닙니다. **요구사항 → Plan → Code → Review → Doc** 다섯 단계를 명시적으로 분리하고, 각 단계를 **격리된 컨텍스트**의 subagent 에게 넘기는 **워크플로우 강제 장치**입니다. 잘 쓰면 성공/실패 분산을 줄이고 토큰 비용을 격리할 수 있습니다. 못 쓰면 그냥 비싼 매크로입니다. 개발자 개입은 0이 되지 않고, 개입의 **종류**가 "코드 작성"에서 "요구사항 정규화 + 게이트 검토"로 바뀝니다.

---

## 왜 하네스인가 — 쉬운 5가지 설명

Claude Code 는 강력하지만 기본 상태로는 절제가 부족합니다. 이 하네스가 강제하는 것:

### 1. Plan-first — "설계도 없이 못 박지 마"
"기능 추가해줘" 하면 Claude 가 바로 코드를 치는 게 아니라, **먼저 `Plans.md` 라는 설계 문서**를 만듭니다. 단계별로 "Phase 1 은 뭘 하고, 다 됐는지 확인하는 기준은 뭐고" 가 적혀있음. 사람이 그거 보고 ✓ 한 다음에야 진짜 코딩 시작. AI 가 알아서 코딩하다가 산으로 가는 사고 방지.

### 2. Phase 경계 — "한 입씩 먹어"
한 Phase = 한 번에 리뷰할 수 있는 작은 단위 (보통 300-500 줄 변경). 큰 기능 한 번에 다 짜지 말고 잘게 쪼갬. 1000줄짜리 PR 은 사람도 제대로 못 봐서 버그가 새어나감.

### 3. 4-lens 리뷰 — "리뷰는 4개 안경 끼고"
머지 전에 reviewer 가 4가지 관점에서 봅니다 — **spec / security / correctness / performance**. 여기에 본인 스택 특유의 함정도 추가로 검사. 예: Django 의 N+1 쿼리, FastAPI `async def` 안의 sync DB 호출.

### 4. Hooks over hopes — "막아야 할 건 코드로 막아"
"`rm -rf /` 하지 마세요" 같은 걸 모델에게 부탁하는 게 아니라, 셸 스크립트가 명령 실행 직전에 검사해서 위험하면 차단. 모델은 깜빡할 수 있지만 스크립트는 안 깜빡함.

### 5. 사람 게이트 — "AI 가 다 해주지 않음"
Plan 승인, BLOCK 판정 시 결정, PR 머지 — 이 3개는 사람이 직접. "AI 한테 다 맡기고 자버린다" 가 안 되게 강제.

> 한 마디로: AI 가 비싼 부분 (코드 작성, 테스트 매핑, 4관점 리뷰) 을 처리하고, 사람은 게이트만 통과시킨다.

---

## 1. 사전 준비

```bash
# 요구사항: Claude Code v2.1+
claude --version

# 하네스가 설치된 프로젝트 / 워크스페이스 루트에서 시작
cd ~/your-project
claude

# 잘 깔렸는지 확인
> /agents     # explorer, planner, coder, tester, reviewer, documenter 6개 보여야 함
> /           # plan, work, review, release, setup, orchestrator 6개 보여야 함
```

---

## 2. 설치된 자산 — 전체 파일 트리

```
~/Projects/<workspace>/
│
├── CLAUDE.md                          ★ 세션마다 자동 로드되는 프로젝트 헌법
├── HARNESS.md                         이 문서
│
├── .claude/
│   ├── settings.json                  hook 6개 등록 (팀 공유용, 체크인)
│   ├── settings.local.json            개인 설정 (gitignore — 직접 생성)
│   ├── worktrees/                     git worktree 격리 작업용
│   ├── notes/                         subagent 출력 로그 저장소
│   │
│   ├── agents/                        ── Subagent 6개 ──
│   │   ├── explorer.md                 opus   · 탐색 전용 (Write 는 notes/ 한정) · 코드베이스 인덱싱
│   │   ├── planner.md                  fable  · read-only · Plans.md 분해
│   │   ├── coder.md                    opus   · edit OK  · 한 Phase TDD 구현 + red/green 커밋
│   │   ├── tester.md                   opus   · tests/만 · TDD 이력 검증 + 엣지 확장
│   │   ├── reviewer.md                 fable  · read-only · 4-lens 게이트
│   │   └── documenter.md               opus   · doc edit · 문서 동기화
│   │
│   ├── skills/                        ── Skill 6개 (verb) ──
│   │   ├── orchestrator/SKILL.md       /orchestrator — 풀 루프 (기본 진입점)
│   │   ├── plan/SKILL.md               /plan       — 요구사항 → Plans.md
│   │   ├── work/SKILL.md               /work N     — Phase N 구현
│   │   ├── review/SKILL.md             /review     — 4관점 게이트
│   │   ├── release/SKILL.md            /release    — 🔒 PR 생성 (자동호출 차단)
│   │   └── setup/SKILL.md              /setup      — 신규 프로젝트 부트스트랩
│   │
│   └── hooks/                         ── 안전 + 편의 + 루프 가드 6개 ──
│       ├── block-destructive.sh        Pre  · rm -rf 시스템경로, push --force, reset --hard origin
│       ├── protect-secrets.sh          Pre  · .env, .pem, credentials, .mcp.json 쓰기 차단
│       ├── post-edit-lint.sh           Post · .py 자동 ruff format (low-nit 자동화)
│       ├── announce-agent.sh           SubagentStart/Stop · agent 실행 알림 + 로그
│       ├── record-verdict.sh           SubagentStop · reviewer verdict 를 loop-state.json 에 기록
│       ├── enforce-loop.sh             Stop · 기록된 verdict 로 자동 수정 루프 예산 판정
│       └── tests/run-tests.sh          hook 회귀 테스트 suite
│
├── scripts/harness/
│   └── run_phase.py                    phase 작업을 별도 셸로 분리 (메인 컨텍스트 절약)
│
└── docs/harness/
    ├── REQUIREMENTS.template.md        /setup 이 신규 프로젝트에 떨어뜨림
    ├── ADR.template.md                 결정 사항 기록 양식
    └── DOC_SYNC_POLICY.md              코드 변경 → 문서 갱신 매핑
```

---

## 3. 5 레이어 동작 원리

### Layer 1 — `CLAUDE.md` (Always-on 컨텍스트)

세션 시작 시 자동 로드. Claude 가 항상 인지하는 사실:
- 작업 규칙 (Plan-first, 비밀키 금지, force push 금지 등)
- 프로젝트 지도 (어떤 폴더에 뭐가 있는지 — 멀티-repo 워크스페이스라면 특히)
- 6 subagent 일람 + 모델
- 안전장치 요약

**왜 필요한가**: 워크스페이스에 독립 git repo 가 여러 개면 Claude 가 어떤 서브프로젝트 컨텍스트인지 매번 헷갈림. 이 지도가 있어야 verb 가 "어느 폴더야?" 물을 수 있음.

### Layer 2 — Subagent 6개

각 subagent 는 **자기만의 컨텍스트 윈도우**. verbose 출력이 메인 세션에 흘러들지 않음. 메인엔 **요약만** 돌아옴.

| Subagent | 모델 | 권한 | 역할 |
|---|---|---|---|
| **explorer** | opus | Read, Write, Grep, Glob, Bash (프로젝트 파일 수정 금지 — Write 는 `.claude/notes/` 한정) | 코드 인덱싱. 작업 시작 전 한 페이지 매핑 |
| **planner** | **fable** | Read, Grep, Glob | Phase 분해. Plans.md 초안 |
| **coder** | opus | Read, Edit, Write, Grep, Glob, Bash | 한 Phase 만 strict TDD 구현 — red/green 마다 work 브랜치에 커밋 |
| **tester** | opus | Read, Edit, Write, Grep, Glob, Bash | tests/ 만 edit. git 이력으로 TDD 준수 검증 + 엣지 케이스 확장. 프로덕션 버그 발견 시 coder 로 escalate |
| **reviewer** | **fable** | Read, Grep, Glob, Bash | 4관점 검토. 스택 특화 룰은 placeholder — 본인 스택으로 채움 (부록 D) |
| **documenter** | opus | Read, Edit, Write, Grep, Glob, Bash | README/CHANGELOG/ADR 동기화 |

**모델 분배 철학 (advisor + worker)**: 조언·결정이 비싼 단계 = **fable** (planner, reviewer — 상위 티어 모델). 실제 실행 = **opus** (explorer, coder, tester, documenter). 더 똑똑한 advisor 가 계획·리뷰 품질을 올리면 worker 의 재작업이 줄어 전체 토큰이 오히려 감소한다.

### Layer 3 — Skill 6개 (verb)

슬래시로 호출되는 **재사용 플레이북**. 본문이 메인 컨텍스트에 한 번 주입돼서 끝까지 남음.

| Skill | 트리거 | 호출하는 Subagent | 자동 호출 |
|---|---|---|---|
| `/orchestrator` | **기본 진입점** — 3 phase 이상 작업 | `/plan` → `/work` → `/review` 체이닝 + release 절차는 inline 수행 | ✓ |
| `/plan` | Plans.md 만 다시 짜고 싶을 때 | explorer + planner | ✓ |
| `/work N` | Plans.md 승인 후 Phase 하나만 | coder + tester (루프) | ✓ |
| `/review` | work 완료 후 리뷰만 | reviewer | ✓ |
| `/release` | 사용자 직접 입력 only | documenter | ✗ 잠금 |
| `/setup` | 신규 프로젝트 온보딩 | (없음) | ✓ |

**`/release` 만 잠근 이유**: commit / push / PR 같은 사이드 이펙트. Claude 자동 발동 위험. `disable-model-invocation: true` 로 잠가서 사용자가 직접 타이핑해야만 작동 (`/orchestrator` 는 skill 을 호출하는 대신 같은 절차를 inline 으로 수행).

### Layer 4 — Hook 6개

Claude 의 도구 호출 직전/직후, 그리고 agent · 턴이 끝나는 시점에 셸 스크립트가 끼어들어 검사. 모델 판단이 아니라 코드로 강제. 차단은 stderr 사유 + exit 2, 통과는 조용히 exit 0. 6개 모두 `.claude/settings.json` 에 등록되어 있고, `.claude/hooks/tests/run-tests.sh` 가 합성 JSON 으로 회귀 검증.

#### `block-destructive.sh` (PreToolUse · Bash 가드)

| 차단 | 통과 |
|---|---|
| `rm -rf /`, `~`, `$HOME`, `/usr/*`, `/etc/*` 등 — compound 명령의 모든 segment 검사 | `rm -rf node_modules`, `/tmp/foo`, `rm -rf build > /dev/null` |
| `git push --force`, `--force-with-lease`, `-f`, `+refspec` (`git -C <path> push` 포함) | `git push -u origin feat/x` |
| `git reset --hard origin/<branch>` | `git reset --hard HEAD~1` |
| `dd of=/dev/{sd,nvme,hd,disk,rdisk}*` | 일반 dd |

#### `protect-secrets.sh` (PreToolUse · Edit/Write 가드)

| 차단 | 통과 |
|---|---|
| `.env*`, `*.pem`, `*.key`, `*.p12`, `*.p8`, `*.keystore`, `id_rsa*`, `id_ed25519*` | 모든 일반 코드/문서 |
| `.npmrc`, `.pypirc`, `.htpasswd`, credential 형태 이름 (`*token*.json`, `secret.yml` 등), `.mcp.json` | `token_service.py`, `design-tokens.css` (소스), `.env.example`, `credentials.md` (문서/템플릿) |

#### `post-edit-lint.sh` (PostToolUse · Edit/Write)

`.py` 변경 직후 `ruff format` (없으면 `black`) 자동 실행. 항상 exit 0 — 차단하지 않음. reviewer 의 low-nit policy 자동화: 포맷/공백 NIT 를 formatter 가 흡수.

#### `announce-agent.sh` (SubagentStart / SubagentStop)

어느 agent 가 실행/종료 중인지 터미널 (`/dev/tty`) 에 한 줄 출력 + `.claude/notes/agent-activity.log` 에 기록. 사후에 어떤 agent 가 진짜 spawn 됐는지 검증 가능.

#### `record-verdict.sh` (SubagentStop)

리뷰어가 끝날 때 그 판정을 디스크에 적어두는 훅. 서브에이전트 트랜스크립트에서 마지막 답변을 꺼내 `run_phase.py --parse-verdict` 로 파싱하고, 결과를 `.claude/notes/loop-state.json` 에 `last_verdict` / `attempt` / `enforced` 세 필드로 기록한다. `APPROVE` 면 `attempt` 를 0 으로 되돌리고, `BLOCK` 이나 `REQUEST CHANGES` 면 1 올리고, 판정을 못 읽었으면(`UNKNOWN`) 그대로 둔다. 카운터를 컨텍스트가 아니라 파일에 두는 이유는 압축 한 번이면 컨텍스트 안의 숫자는 사라지기 때문이다.

**어떤 입력에도 exit 0.** `SubagentStop` 의 exit 2 는 "서브에이전트를 멈추지 못하게 한다" 는 뜻이라, read-only 인 리뷰어를 계속 돌리는 것 외엔 아무 효과가 없다. 판정은 아래 `enforce-loop.sh` 가 한다.

> ⚠️ **리뷰어 서브에이전트 이름은 `reviewer` 로 시작해야 한다.** 이 훅은 `agent_type` 이 `reviewer` 이거나 `reviewer-` 로 시작할 때만 기록한다 (`reviewer-phase2` 처럼 팀메이트 이름이 붙는 경우까지 걸리게 한 것). `phase3-reviewer` 나 `review-gate` 로 띄우면 기록이 없고, 기록이 없으면 아래 루프 강제가 **조용히 통째로 꺼진다.** 세션 안 어디에도 꺼졌다는 표시가 없으므로 이름 규칙을 지키는 쪽이 유일한 방어다.

#### `enforce-loop.sh` (Stop)

메인 턴이 끝날 때마다 발화해서 `loop-state.json` 을 읽고 자동 수정 루프 예산(3회) 을 판정한다. 파일이 없으면 — 즉 리뷰 루프가 안 돌고 있으면 — 아무것도 안 하고 바로 통과시킨다. 평범한 대화 턴을 가로채면 안 되기 때문이다.

| 상태 | 훅의 반응 |
|---|---|
| 마지막 판정이 `BLOCK` / `REQUEST CHANGES`, 예산 남음 | **exit 2** — 턴을 끝내지 못하게 막고, stderr 로 "findings 들고 coder 재투입 후 리뷰어 재실행" 을 지시. 새 BLOCK 이 기록된 뒤 오는 턴은 그 위에서 그냥 끝날 수 없다 |
| 같은 판정, `attempt` 가 3 도달 | **exit 0** — 턴을 끝내되 "성공이 아닙니다. 사람 개입이 필요합니다" 를 출력. 세 번 더 돌려도 못 찾을 것을 기계에 맡기지 않는다 |
| `APPROVE` / `UNKNOWN` / 이미 반응한 판정 | exit 0, 조용히 통과 |
| 상태 파일 손상, 페이로드 불량, `jq`·`python3` 부재 | exit 0 + stderr 경고 — 세션을 훅 안에 가두지 않는다 |

판정 하나는 반응 한 번만 산다 (`enforced` 플래그). 사용자가 루프를 놔두고 떠나도 남은 BLOCK 이 이후 모든 턴을 붙잡지 않는다.

**하는 일의 범위**: 리뷰어 판정을 기록하고 재시도 상한을 강제할 뿐이다. tester 가 찾은 결함으로 도는 `/work` 안쪽 루프는 여기서 세지 않고, 코더가 4번째로 도는 것을 물리적으로 막지도 않는다 — 예산이 남았는데 멈추는 것을 막고, 예산이 다 되면 사람에게 넘긴다.

### Layer 5 — 부속 자산

- **`scripts/harness/run_phase.py`** — `claude --agent <name> -p` 로 phase 작업을 별도 셸에 띄움. 출력은 `.claude/notes/phase-N-agent-*.log` 로. 메인엔 `[run_phase] status=... log=...` 한 줄만 — reviewer 를 돌린 경우 로그의 verdict 를 읽어 `status=BLOCK` / `status=CHANGES` 도 낸다 (`claude` CLI 는 리뷰어가 BLOCK 을 내도 exit 0 이라, 로그를 안 읽으면 BLOCK 이 성공으로 보고된다). `--parse-verdict <logfile>` 로 로그 하나의 판정만 따로 뽑을 수도 있다 (`claude` 미설치 환경에서도 동작).

  | exit | 뜻 |
  |---|---|
  | `0` | 정상 종료 (verdict 가 `APPROVE` 이거나 태그 없음 = `UNKNOWN`) |
  | `1` | 인자 오류 (argparse usage 에러 포함), 읽을 수 없는 verdict 로그 |
  | `2` | `claude` CLI 가 PATH 에 없음 |
  | `3` | agent 실행 실패 (non-zero 종료, 타임아웃, 로그를 읽을 수 없음) |
  | `4` | reviewer verdict `REQUEST CHANGES` |
  | `5` | reviewer verdict `BLOCK` |

  verdict 태그는 **로그의 마지막 비어있지 않은 줄**에 있을 때만 채택한다. 리뷰어가 findings 안에서 태그를 인용만 하고 자기 판정을 빠뜨린 로그가 그 인용을 진짜 판정으로 읽히는 것을 막기 위해서다. 다른 자리에 있는 태그는 `UNKNOWN` 으로 읽고 stderr 에 경고를 낸다.
- **`docs/harness/REQUIREMENTS.template.md`** — `/setup` 이 신규 서브프로젝트에 떨어뜨리는 시작점. 정체성/stack/run/test/컨벤션/non-goals/quality bar 8 섹션.
- **`docs/harness/ADR.template.md`** — 비자명 결정(새 의존성, 새 패턴, 스코프 변경) 기록 양식.
- **`docs/harness/DOC_SYNC_POLICY.md`** — 코드 변경 → 어떤 문서를 갱신할지 매핑 표.

---

## 4. 표준 워크플로우

### 4.1. 신규 서브프로젝트 한 번 — `/setup`

```
> /setup
```

→ 어느 폴더인지 물음 → `REQUIREMENTS.md` + 빈 `Plans.md` 생성 → stack 자동 추론.
**할 일**: 떨어진 `REQUIREMENTS.md` 열어서 run/test 명령 검토.

### 4.2. 기능 시작 — 기본은 `/orchestrator`

```
> /orchestrator <자연어 작업 설명>
```

`/orchestrator` 가 **기본 진입점** — plan → work (TDD) → review → release 를 끝까지 조율하고, 사람은 게이트 (Plan 승인 / review verdict / PR 머지) 만 통과시킨다. 3 phase 이상 본격 작업에서 본전. 그 이하 자잘한 수정은 하네스 우회 (§4.4).

단계를 하나씩 직접 밟고 싶을 때 (디버깅, 재리뷰 등) 는 아래 수동 5 STEP:

```
1. > <your-subproject> 에 채널 webhook HMAC 검증. /plan 으로 가자
   → explorer + planner 구동, <your-subproject>/Plans.md 작성
   ⛔ STOP — Plans.md 검토 + Approval ✓

2. > Plans.md 승인했어. /work 1
   → work 브랜치 생성 (main 위에서는 작업 금지) → coder 가 TDD 사이클마다
     red 커밋 → green 커밋 → tester 가 git 이력으로 TDD 검증 + 엣지 확장
   ⛔ STOP — diff 요약 확인

3. > /review
   → reviewer(fable) 가 merge-base 기준 누적 diff 를 4관점 + 스택 특화 검토
   ⛔ STOP — verdict 확인 (APPROVE / REQUEST CHANGES / BLOCK)
     APPROVE 면 Plans.md 에 `Review: APPROVE — <date>` 기록됨

4. > /release    ← 직접 타이핑 (자동호출 잠겨있음)
   → Plans.md 의 `Review: APPROVE` 확인 → documenter → CHANGELOG
     → docs 커밋 → push → gh pr create
   ⛔ STOP — PR URL 확인

5. [GitHub 에서 PR 머지]    ← 사람이 직접

6. > /work 2
   → 다음 Phase 반복
```

### 4.3. STOP 게이트 — 사용자 개입 강제 지점

수동 5 STEP 기준:

| # | 시점 | 사용자 결정 |
|---|---|---|
| 1 | `/plan` 직후 | Plans.md 검토 + Approval ✓ |
| 2 | `/work N` 직후 (선택) | diff 한 번 보기 |
| 3 | `/review` BLOCK / REQUEST CHANGES 시 | 자동 루프(3회, `enforce-loop.sh` 가 강제) 가 못 풀면 자연어로 방향 재지시 |
| 4 | `/release` 호출 자체 | 자동 발동 안 됨, 직접 타이핑 |
| 5 | PR 머지 | GitHub 에서 직접 |

**1, 4, 5는 절대 생략 불가.** 2, 3은 신뢰 쌓이면 가벼워질 수 있음. `/orchestrator` 는 이걸 하드 게이트 3개 (Plan 승인 / fix 루프 소진 / PR 머지) + verdict 직후의 선택적 per-phase stop 으로 압축한다.

### 4.4. 짧은 작업은 하네스 우회

| 상황 | 권장 |
|---|---|
| 한 파일 한두 줄 수정 | 그냥 채팅 |
| 빠른 디버깅 / 탐색 / 스파이크 | 그냥 채팅 |
| README 오타 | 그냥 채팅 |
| 3 phase 이상 들어가는 작업 | `/orchestrator` |
| 타 프로젝트와 인터페이스 변경 | repo 단위로 `/orchestrator` + 더 잘게 쪼갠 Plan |

---

## 5. Reviewer 의 4-lens (스택 무관 기본)

`/review` 가 호출하는 reviewer subagent 는 4 lens 로 검토:

| Lens | universal 검사 |
|---|---|
| **Spec** | Acceptance bullet ↔ 코드 라인 매핑 |
| **Security** | secrets, PII 로깅, injection, SSRF, path traversal, AuthZ |
| **Correctness** | 엣지 케이스, 에러 핸들링, 네이밍, 테스트 커버리지 |
| **Performance** | 메모리, 블로킹 I/O, 로깅/트레이싱 |

**스택 특화 룰은 본문에 비워둠.** `examples/reviewer-python.md` 참고해서 본인 스택 버전 작성 → `.claude/agents/reviewer.md` 자리에 덮어쓰기.

**출력 형식** — 필수 4섹션 + 선택 3섹션 순서 고정: `결론` (verdict + 한 줄 사유) → `Spec correctness` → `판정 표` → `Findings` → (`Praise` → `Questions` → `결정 필요`). verdict 는 APPROVE / REQUEST CHANGES / BLOCK. finding 예시:

```markdown
### 판정 표
| # | 항목 | 위치 | 태그 |
|---|---|---|---|
| 1 | <한 줄 요약> | `file:line` | `[NEW][BLOCK]` |

### Findings (severity 순)

#### [NEW][BLOCK] file.ext:88 — <one-line summary>
**심각도**: 🔴

**현재 코드**:
   ```<lang>
   ...
   ```

**문제**: ...

**개선안**:
   ```<lang>
   ...
   ```
```

**Tag — scope + severity 두 축** (`tester` 와 메인 세션 BLUF 보고도 같은 어휘):
- `[NEW]` (scope) — 본 Phase diff 가 만든 이슈. 기본값이라 단독 `[BLOCK]` 도 `[NEW]` 의미. 조합 예: `[NEW][BLOCK]`
- `[EXISTING]` (scope) — 기존 코드 이슈, 이 PR 차단 안 함. 별도 티켓 권장
- `[BLOCK]` (severity) — 머지 차단
- `[CHANGES]` (severity) — 머지 전 수정 권장
- `[NIT]` (severity) — 선택적. low-nit policy — formatter 가 잡을 건 코멘트 X

비-판정 어휘: **Praise** (강화하고 싶은 패턴), **Question** (차단 아닌 명확화 요청) 는 별도 섹션으로.

자세한 스택별 룰 채우기 가이드는 [부록 D — Customize for Your Stack](#부록-d--customize-for-your-stack) 참고.


## 6. 컨텍스트 관리 — `/compact`

### 자동 압축
Claude Code 가 컨텍스트 ~95% 차면 자동 압축. 메인 세션 / subagent 각자 독립.

### 수동 압축 — 사용자 몫

```
> /compact
```

권장 시점:

| 시점 | 왜 |
|---|---|
| Phase 끝나고 다음 Phase 가기 전 | 이전 diff/test 출력 정리 |
| `/review` 가 verbose diff 토해낸 직후 | raw diff 안 들고가도 됨 |
| 긴 디버깅 세션 후 본격 구현 직전 | 추적 로그 정리 |
| Plan 승인 직후 | Explorer/Planner 탐색 흔적 정리 |

### 자동 압축이 부담 적은 이유 (이미)

- Subagent 격리 → verbose 출력이 메인에 안 흘러옴
- `run_phase.py` → phase 전체를 메인 밖으로
- Skill 본문 절제 → invocation 비용 낮음

---

## 7. 비용 가이드

| 행동 | 대략 비용 (단순 채팅 = 1x) |
|---|---|
| 단순 채팅 | 1x |
| `/plan` (planner+explorer 한 번씩) | 2-3x |
| `/work` 1 Phase | 1.5-2x |
| `/review` (fable) | 2x |
| `/release` (documenter + 명령) | 1x |
| `/orchestrator` 풀 루프 | phase 수 × (work + review) 누적 — fix 루프 횟수에 따라 달라짐, 본인 환경에서 측정 |

**Phase 를 잘게 쪼개야 비용이 안 폭주합니다.** Plans.md 의 한 Phase diff 가 300-500 줄 범위를 넘어가면 더 쪼개세요.

---

## 8. 트러블슈팅

| 증상 | 원인 / 해결 |
|---|---|
| `/plan` 쳐도 그냥 응답 | `.claude/skills/plan/SKILL.md` 누락 또는 frontmatter 깨짐. claude 재시작 |
| Project agents 가 `/agents` 에 안 보임 | `cd <your-workspace>` 안에서 `claude` 띄웠는지 확인 |
| Coder 가 production 코드 마음대로 고침 | Plans.md 의 Phase 정의가 모호. Acceptance bullet 더 구체화 |
| Reviewer 가 칭찬만 함 | reviewer.md frontmatter `model: fable` 인지 확인. 강화된 reviewer 적용 위해 세션 재시작 |
| Hook 이 안 막음 | `chmod +x .claude/hooks/*.sh`, `.claude/settings.json` 의 `hooks` 등록 확인. 검증: `bash .claude/hooks/tests/run-tests.sh` |
| `git push --force` 가 차단됨 | 의도된 동작. fresh 브랜치로 push 또는 사용자가 직접 명령 실행 |
| `.env` 쓰기 차단됨 | 의도된 동작. 직접 편집 |
| `/orchestrator` 비용이 부담됨 | Phase 를 더 잘게 쪼개거나 (300-500 줄), 단계별로 `/plan → /work → /review` 수동 진행 |
| BLOCK 이 났는데 루프가 안 돌고 턴이 그냥 끝남 | 리뷰어 서브에이전트 이름이 `reviewer` 로 시작하는지 확인 (`record-verdict.sh` 가 그 이름만 기록). `.claude/notes/loop-state.json` 이 갱신되는지, `.claude/settings.json` 에 `Stop` / `SubagentStop` 이 등록돼 있는지도 확인 |
| 자연어로 "리뷰" 했더니 다른 reviewer agent 가 골라짐 | 같은 이름의 agent 정의가 여러 레벨 (project/user) 에 있으면 모호해짐. `@agent-reviewer` 로 명시 호출 |
| `/review` 등이 같은 이름의 번들 skill 과 충돌 | `settings.json` 의 `skillOverrides` 로 충돌하는 번들 skill 을 끌 수 있음 |

---

## 9. 활성 / 비활성 / 제거

### 일시 비활성 (한 번)
```
> 이번엔 하네스 빼고 그냥 고쳐줘
```

### 영구 비활성 (특정 서브프로젝트만)
해당 폴더 안에 자체 `.claude/` 만들고 빈 `settings.json`. 하위 우선.

### 완전 제거
```bash
rm -rf ~/Projects/<workspace>/.claude/agents
rm -rf ~/Projects/<workspace>/.claude/skills
rm -rf ~/Projects/<workspace>/.claude/hooks
rm -rf ~/Projects/<workspace>/scripts/harness
rm -rf ~/Projects/<workspace>/docs/harness
rm ~/Projects/<workspace>/CLAUDE.md ~/Projects/<workspace>/HARNESS.md
# .claude/settings.json 의 hooks 블록은 수동으로 제거
```

`settings.json` 에 본인이 추가한 다른 설정 (`permissions.allow`, 자체 hook 등) 이 있다면 hooks 블록만 골라서 제거.

---

## 10. 확장하는 법

### 새 subagent 추가
`.claude/agents/<name>.md` 파일 생성. frontmatter:
```yaml
---
name: <name>
description: 언제 호출되는지. PROACTIVELY 키워드 권장
tools: Read, Grep, Glob, Bash    # 콤마 구분 (subagent)
model: fable | opus | sonnet | haiku
---
```
세션 재시작 후 `/agents` 에 노출.

### 새 skill (verb) 추가
`.claude/skills/<verb>/SKILL.md` 파일 생성. frontmatter:
```yaml
---
name: <verb>
description: 자동 호출 트리거
allowed-tools: Read, Edit, Write   # 콤마/공백 모두 허용
disable-model-invocation: true     # 사이드이펙트 있으면
---
```

### 새 hook 추가
`.claude/hooks/<name>.sh` 작성 (실행권한 + jq 로 stdin JSON 파싱, 차단은 stderr 사유 + exit 2) 후 `.claude/settings.json` 의 `hooks` 에 해당 event (`PreToolUse` / `PostToolUse` / `SubagentStart` 등) 별로 등록. `.claude/hooks/tests/run-tests.sh` 에 deny/allow 케이스 추가 권장.

### Plans.md 의 phase 분리 정도 조정
한 phase = 한 reviewable unit (보통 300-500 줄 diff 권장). 더 작게 쪼갤수록 토큰 비용은 늘지만 회귀 위험 감소.

---

## 11. 솔직한 한계

- **"개발자 0명" 은 거짓말.** Plan 검토 + Review 게이트 통과 결정은 사람.
- Subagent 끼리 의견 어긋남 발생 가능. 그래서 모든 단계에 STOP 게이트.
- **Plan 이 부실하면 모든 게 부실.** Planner(fable) 에 시간 더 쓰는 게 항상 이득.
- 멀티-서브프로젝트 동시 변경은 하네스가 잘 못 다룸. 한 번에 한 저장소.
- "사람 개입 0" 사례들은 가능한 워크플로우의 **상한**, 평균이 아님. 평균은 70% Coder 가 채우고 30% 사람이 패치.

---

## 12. 더 깊이

- 본 하네스 디자인 레퍼런스: 민세홍님 6-agent 구조 + 2026 best practice (Chachamaru 5-verb harness).
- 만족스러우면 [`Chachamaru127/claude-code-harness`](https://github.com/Chachamaru127/claude-code-harness) 같은 플러그인으로 이전 가능. 이 폴더의 6 verb 가 5 verb 로 합쳐지고 TypeScript 가드레일 엔진이 추가됨.
- ADR / REQUIREMENTS / DOC_SYNC_POLICY 템플릿은 `docs/harness/` 참고.

---

## 부록 A — 30초 치트시트

```
첫 프로젝트:    /setup
기본:           /orchestrator <작업 설명>   ← 평소엔 이거 하나
                ⛔ Plans.md 승인 → (자동) → ⛔ verdict → ⛔ PR 머지

단계별 수동:
시작:           "X 추가해줘. /plan"
                ⛔ Plans.md 승인
구현:           /work 1
검증:           /review
                ⛔ verdict 확인
배포:           /release    ← 직접 타이핑
                ⛔ PR 머지
다음:           /work 2 → 반복

빠른 작업:      그냥 채팅 (하네스 우회)
컨텍스트 정리:  /compact (Phase 사이마다)
특정 agent:     @agent-explorer / @agent-reviewer 등
```

---

## 부록 B — 흔한 실수 매트릭스

| 실수 | 결과 |
|---|---|
| `/plan` 건너뛰고 `/work` | coder 거부 (Plans.md 없음) |
| Plans.md 승인 안 하고 `/work` | coder 거부 |
| `/work 1 2 3` 같이 여러 phase 한 번에 | 토큰 폭주, 리뷰 부채 |
| `/release` 가 자동 발동 안 한다고 다시 시도 | 의도된 잠금. 직접 타이핑이 정답 |
| `git push --force` 시도 | hook 차단 |
| `.env` 쓰기 시도 | hook 차단 |
| 워크스페이스 루트 밖에서 `claude` 띄움 | project agent 안 보임 |
| reviewer.md 직접 수정 후 같은 세션 | 재시작 필요 (project agent 변경 반영) |

---

## 부록 C — 산출물

See the directory tree in §2 of this document, or run `find .claude scripts docs -type f` from the workspace root.

---

---

## 부록 D — Customize for Your Stack

이 하네스는 의도적으로 **언어/프레임워크 비종속** 으로 출발합니다. agents 본문에는 universal 검사만, **스택 특화 룰은 placeholder** 로 남겨둠. 본인 프로젝트 스택에 맞게 채우세요.

### 어떤 파일을 무엇으로 채우나

| 커스터마이즈 대상 | 수정할 파일 | 어떻게 |
|---|---|---|
| **스택 특화 리뷰 룰** | `.claude/agents/reviewer.md` "Stack-specific" 서브섹션 | `examples/reviewer-<stack>.md` 복사하거나 직접 채움 |
| **의존성 매니저 / 린트 / 테스트 러너** | `.claude/agents/coder.md`, `tester.md` | generic. 자동 추론. 강제하고 싶으면 한 줄 추가 |
| **빌드 산출물 skip 폴더** | `.claude/agents/explorer.md` skip 경로 | 표준 폴더 (`node_modules`, `.venv`, `target`, `build`, `dist`...) 이미 포함. 특수 폴더만 추가 |
| **테스트 디렉토리** | `.claude/agents/tester.md` | 자동 추론. 명시 원하면 한 줄 추가 |
| **프로젝트 지도 / 규칙** | `CLAUDE.md` | `CLAUDE.md.example` 복사 후 채움 |
| **요구사항 / 인수 기준** | `<subproject>/REQUIREMENTS.md` | `docs/harness/REQUIREMENTS.template.md` 복사 후 채움 (또는 `/setup` 스킬 사용) |

### 풀 reference reviewers (복사 → 수정 시작점)

| 스택 | 파일 |
|---|---|
| Python (Django / FastAPI / Airflow) | `examples/reviewer-python.md` |
| _Java / Kotlin / Scala / Go / Rust / Ruby / ..._ | (PR 환영) |

```bash
cp examples/reviewer-<your-stack>.md .claude/agents/reviewer.md
```

### 30분 안에 본인 스택 화

1. `examples/` 에서 본인 스택 reviewer 복사 (없으면 4 lens × stack-specific 서브섹션 직접 채움)
2. `CLAUDE.md` 채움
3. (필요시) 신규 서브프로젝트 `REQUIREMENTS.md` 채움 — `/setup` 스킬이 자동화
4. `claude` 재시작 → `/plan`

다른 agent (planner, coder, tester, explorer, documenter) 는 모두 stack-agnostic 으로 작성됨. 건드릴 필요 없음.
