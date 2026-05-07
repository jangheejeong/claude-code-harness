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
한 Phase = 한 번에 리뷰할 수 있는 작은 단위 (대략 400줄 변경 이하). 큰 기능 한 번에 다 짜지 말고 잘게 쪼갬. 1000줄짜리 PR 은 사람도 제대로 못 봐서 버그가 새어나감.

### 3. 4-lens 리뷰 — "리뷰는 4개 안경 끼고"
머지 전에 reviewer 가 4가지 관점에서 봅니다 — **spec / security / correctness / performance**. 여기에 본인 스택 특유의 함정도 추가로 검사. 예: Django 의 N+1 쿼리, Spring JPA 의 lazy loading 폭발.

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

# 베이스 폴더에서 시작 (이게 컨트롤 타워)
cd ~/Projects/heum
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
│   ├── settings.local.json            기존 권한 + 신규 hook 통합
│   ├── settings.local.json.bak.*      자동 백업
│   ├── worktrees/                     git worktree 격리 작업용
│   ├── notes/                         subagent 출력 로그 저장소
│   │
│   ├── agents/                        ── Subagent 6개 ──
│   │   ├── explorer.md                 sonnet · read-only · 코드베이스 인덱싱
│   │   ├── planner.md                  opus   · read-only · Plans.md 분해
│   │   ├── coder.md                    sonnet · edit OK  · 한 Phase 구현
│   │   ├── tester.md                   sonnet · tests/만 · 테스트 작성/실행
│   │   ├── reviewer.md                 opus   · read-only · 4-lens 게이트
│   │   └── documenter.md               sonnet · doc edit · 문서 동기화
│   │
│   ├── skills/                        ── Skill 6개 (verb) ──
│   │   ├── plan/SKILL.md               /plan       — 요구사항 → Plans.md
│   │   ├── work/SKILL.md               /work N     — Phase N 구현
│   │   ├── review/SKILL.md             /review     — 4관점 게이트
│   │   ├── release/SKILL.md            /release    — 🔒 PR 생성 (자동호출 차단)
│   │   ├── setup/SKILL.md              /setup      — 신규 프로젝트 부트스트랩
│   │   └── orchestrator/SKILL.md       /orchestrator — 풀 루프 조율
│   │
│   └── hooks/                         ── 안전 가드 2개 ──
│       ├── block-destructive.sh        rm -rf 시스템경로, push --force, reset --hard origin
│       └── protect-secrets.sh          .env, .pem, credentials, .mcp.json 쓰기 차단
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
- 작업 규칙 6개 (Plan-first, 비밀키 금지, force push 금지 등)
- 24개 서브프로젝트 지도 (어떤 폴더에 뭐가 있는지)
- 핵심 인-플라이트 문서 위치
- 6 subagent 일람 + 모델
- MCP 설정 (Jira)
- 안전장치 요약

**왜 필요한가**: if your workspace contains multiple independent git repos. Claude 가 어떤 서브프로젝트 컨텍스트인지 매번 헷갈림. 이 지도가 있어야 verb 가 "어느 폴더야?" 물을 수 있음.

### Layer 2 — Subagent 6개

각 subagent 는 **자기만의 컨텍스트 윈도우**. verbose 출력이 메인 세션에 흘러들지 않음. 메인엔 **요약만** 돌아옴.

| Subagent | 모델 | 권한 | 역할 |
|---|---|---|---|
| **explorer** | sonnet | Read, Grep, Glob, Bash (read-only) | 코드 인덱싱. 작업 시작 전 한 페이지 매핑 |
| **planner** | **opus** | Read, Grep, Glob | Phase 분해. Plans.md 초안 |
| **coder** | sonnet | Read, Edit, Write, Grep, Glob, Bash | 한 Phase 만 minimal-diff 구현 |
| **tester** | sonnet | Read, Edit, Write, Grep, Glob, Bash | tests/ 만 edit. 프로덕션 버그 발견 시 coder 로 escalate |
| **reviewer** | **opus** | Read, Grep, Glob, Bash | 4관점 검토. **Python/Django/FastAPI/Airflow 도메인 지식** 포함 |
| **documenter** | sonnet | Read, Edit, Write, Grep, Glob, Bash | README/CHANGELOG/ADR 동기화 |

**모델 분배 철학**: 결정이 비싼 단계 = opus (planner, reviewer). 실행 = sonnet. 토큰 vs 품질 절충.

### Layer 3 — Skill 6개 (verb)

슬래시로 호출되는 **재사용 플레이북**. 본문이 메인 컨텍스트에 한 번 주입돼서 끝까지 남음.

| Skill | 트리거 | 호출하는 Subagent | 자동 호출 |
|---|---|---|---|
| `/plan` | "기능 추가하자" | explorer + planner | ✓ |
| `/work N` | Plans.md 승인 후 | coder + tester (루프) | ✓ |
| `/review` | work 완료 후 | reviewer | ✓ |
| `/release` | 사용자 직접 입력 only | documenter | ✗ 잠금 |
| `/setup` | 신규 프로젝트 온보딩 | (없음) | ✓ |
| `/orchestrator` | 풀 루프 자동화 | 4 verb 체이닝 | ✓ |

**`/release` 만 잠근 이유**: commit / push / PR 같은 사이드 이펙트. Claude 자동 발동 위험. `disable-model-invocation: true` 로 잠가서 사용자가 직접 타이핑해야만 작동.

### Layer 4 — Hook 2개

Claude 가 어떤 도구(Bash, Edit, Write)를 호출하기 **직전에** 셸 스크립트가 끼어들어 검사. 모델 판단이 아니라 코드로 강제.

#### `block-destructive.sh` (Bash 가드)

| 차단 | 통과 |
|---|---|
| `rm -rf /`, `~`, `$HOME`, `/usr/*`, `/etc/*` 등 | `rm -rf node_modules`, `/tmp/foo` |
| `git push --force`, `--force-with-lease`, `-f` | `git push -u origin feat/x` |
| `git reset --hard origin/<branch>` | `git reset --hard HEAD~1` |
| `dd of=/dev/sd*` | 일반 dd |

18 케이스 테스트 통과, false positive 0.

#### `protect-secrets.sh` (Edit/Write 가드)

| 차단 | 통과 |
|---|---|
| `.env*`, `*.pem`, `*.key`, `credentials.json`, `.mcp.json` | 모든 일반 코드/문서 |
| `tokens.yaml`, `secret.yml` | `credentials.md` (문서) |

11 케이스 테스트 통과.

### Layer 5 — 부속 자산

- **`scripts/harness/run_phase.py`** — `claude --agent <name> -p` 로 phase 작업을 별도 셸에 띄움. 출력은 `.claude/notes/phase-N-agent-*.log` 로. 메인엔 `[run_phase] status=OK log=...` 한 줄만.
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

### 4.2. 기능 시작 — 표준 5 STEP

```
1. > <your-subproject> 에 채널 webhook HMAC 검증. /plan 으로 가자
   → explorer + planner 구동, <your-subproject>/Plans.md 작성
   ⛔ STOP — Plans.md 검토 + Approval ✓

2. > Plans.md 승인했어. /work 1
   → coder Phase 1 구현 → tester 검증
   ⛔ STOP — diff 요약 확인

3. > /review
   → reviewer(opus) 4관점 + 스택 특화 검토
   ⛔ STOP — verdict 확인 (APPROVE / CHANGES / BLOCK)

4. > /release    ← 직접 타이핑 (자동호출 잠겨있음)
   → documenter → CHANGELOG → 커밋 → push → gh pr create
   ⛔ STOP — PR URL 확인

5. [GitHub 에서 PR 머지]    ← 사람이 직접

6. > /work 2
   → 다음 Phase 반복
```

### 4.3. 5 STOP 게이트 — 사용자 개입 강제 지점

| # | 시점 | 사용자 결정 |
|---|---|---|
| 1 | `/plan` 직후 | Plans.md 검토 + Approval ✓ |
| 2 | `/work N` 직후 (선택) | diff 한 번 보기 |
| 3 | `/review` BLOCK / CHANGES 시 | 자동 루프(최대 3회) 못 풀면 직접 수정 |
| 4 | `/release` 호출 자체 | 자동 발동 안 됨, 직접 타이핑 |
| 5 | PR 머지 | GitHub 에서 직접 |

**1, 4, 5는 절대 생략 불가.** 2, 3은 신뢰 쌓이면 가벼워질 수 있음.

### 4.4. 짧은 작업은 하네스 우회

| 상황 | 권장 |
|---|---|
| 한 파일 한두 줄 수정 | 그냥 채팅 |
| 빠른 디버깅 / 탐색 / 스파이크 | 그냥 채팅 |
| README 오타 | 그냥 채팅 |
| 3 phase 이상 들어가는 작업 | 하네스 풀 사용 |
| 타 프로젝트와 인터페이스 변경 | 하네스 풀 사용 + 더 잘게 쪼갠 Plan |

---

## 5. Reviewer 의 스택 특화 지식

`/review` 가 호출하는 reviewer subagent 는 4 lens × 4 stack 매트릭스로 검토합니다.

| Lens | 일반 | Django | FastAPI | Airflow |
|---|---|---|---|---|
| **Spec** | Acceptance bullet ↔ 코드 라인 매핑 | — | — | — |
| **Security** | secrets, PII 로깅 | raw SQL f-string, mark_safe XSS, csrf_exempt | Depends 인증, response_model 누설 | BashOperator 인젝션, Connection 평문 |
| **Correctness** | 컴프리헨션, mutable default, EAFP, with, `is None` | save() override, signals, migration reversibility, DoesNotExist | async-sync 혼합 (이벤트 루프 블록), Pydantic v1↔v2, dict body | 멱등성, DAG 최상위 무거운 import, `start_date=now()` 함정, xcom 페이로드, Jinja 템플릿 |
| **Performance** | generator, 메모리 accumulator | **N+1 (`select_related`/`prefetch_related`)**, `bulk_*`, `.exists()` vs `len()` | 전체 테이블 메모리 적재, sync logging in async | dynamic task mapping, sensor reschedule 모드, pool/priority |

**출력 형식**:

```markdown
#### [BLOCK] router.py:88 — N+1 in webhook fan-out
**심각도**: 🔴
**기존/신규**: 신규

**현재 코드**:
   ```python
   for sub in qs:
       notify(sub.user.email)
   ```

**문제**: `sub.user` 가 매 iteration 마다 새 쿼리.

**개선안**:
   ```python
   for sub in qs.select_related('user'):
       notify(sub.user.email)
   ```
```

**Tag 4개**:
- `[BLOCK]` — 머지 차단
- `[CHANGES]` — 머지 전 수정 권장
- `[NIT]` — 선택적
- `[EXISTING]` — 기존 코드 이슈, 이 PR 차단 안 함 (별도 티켓)

---

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
| `/review` (opus) | 2x |
| `/release` (documenter + 명령) | 1x |
| `/orchestrator` 한 Phase 풀로 | 5-6x |

**Phase 를 잘게 쪼개야 비용이 안 폭주합니다.** Plans.md 의 한 Phase diff 가 400 LoC 넘어가면 더 쪼개세요.

---

## 8. 트러블슈팅

| 증상 | 원인 / 해결 |
|---|---|
| `/plan` 쳐도 그냥 응답 | `.claude/skills/plan/SKILL.md` 누락 또는 frontmatter 깨짐. claude 재시작 |
| Project agents 가 `/agents` 에 안 보임 | `cd <your-workspace>` 안에서 `claude` 띄웠는지 확인 |
| Coder 가 production 코드 마음대로 고침 | Plans.md 의 Phase 정의가 모호. Acceptance bullet 더 구체화 |
| Reviewer 가 칭찬만 함 | reviewer.md frontmatter `model: opus` 인지 확인. 강화된 reviewer 적용 위해 세션 재시작 |
| Hook 이 안 막음 | `chmod +x .claude/hooks/*.sh`, `settings.local.json` 의 `hooks.PreToolUse` 확인 |
| `git push --force` 가 차단됨 | 의도된 동작. fresh 브랜치로 push 또는 사용자가 직접 명령 실행 |
| `.env` 쓰기 차단됨 | 의도된 동작. 직접 편집 |
| `/orchestrator` 가 너무 비쌈 | 그냥 `/plan → /work → /review` 수동으로. orchestrator 는 잘게 쪼개진 작업 전용 |
| 자연어로 "리뷰" 했더니 다른 reviewer 가 골라짐 | inside your workspace에선 project `reviewer` 우선, 다른 프로젝트선 user `code-reviewer` 우선. `@agent-reviewer` 로 명시 호출 가능 |

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
# settings.local.json 의 PreToolUse 항목은 수동으로 제거 또는 .bak 으로 복원
```

기존 권한(`permissions.allow`)과 clair frontend hook 은 그대로 보존됨.

---

## 10. 확장하는 법

### 새 subagent 추가
`.claude/agents/<name>.md` 파일 생성. frontmatter:
```yaml
---
name: <name>
description: 언제 호출되는지. PROACTIVELY 키워드 권장
tools: Read, Grep, Glob, Bash    # 콤마 구분 (subagent)
model: sonnet | opus | haiku
---
```
세션 재시작 후 `/agents` 에 노출.

### 새 skill (verb) 추가
`.claude/skills/<verb>/SKILL.md` 파일 생성. frontmatter:
```yaml
---
name: <verb>
description: 자동 호출 트리거
allowed-tools: Read Edit Write   # 공백 구분 (skill, 콤마 X)
disable-model-invocation: true   # 사이드이펙트 있으면
---
```

### 새 hook 추가
`.claude/hooks/<name>.sh` 작성 (실행권한 + jq 로 stdin JSON 파싱) 후 `settings.local.json` 의 `hooks.PreToolUse` 에 등록.

### Plans.md 의 phase 분리 정도 조정
한 phase = 한 reviewable unit (≤400 LoC diff 권장). 더 작게 쪼갤수록 토큰 비용은 늘지만 회귀 위험 감소.

---

## 11. 솔직한 한계

- **"개발자 0명" 은 거짓말.** Plan 검토 + Review 게이트 통과 결정은 사람.
- Subagent 끼리 의견 어긋남 발생 가능. 그래서 모든 단계에 STOP 게이트.
- **Plan 이 부실하면 모든 게 부실.** Planner(opus) 에 시간 더 쓰는 게 항상 이득.
- 멀티-서브프로젝트 동시 변경은 하네스가 잘 못 다룸. 한 번에 한 저장소.
- 토스 R&D PM-only 케이스는 가능한 워크플로우의 **상한**, 평균이 아님. 평균은 70% Coder 가 채우고 30% 사람이 패치.

---

## 12. 더 깊이

- 본 하네스 디자인 레퍼런스: 민세홍님 6-agent 구조 + 2026 best practice (Chachamaru 5-verb harness).
- 만족스러우면 [`Chachamaru127/claude-code-harness`](https://github.com/Chachamaru127/claude-code-harness) 같은 플러그인으로 이전 가능. 이 폴더의 6 verb 가 5 verb 로 합쳐지고 TypeScript 가드레일 엔진이 추가됨.
- ADR / REQUIREMENTS / DOC_SYNC_POLICY 템플릿은 `docs/harness/` 참고.

---

## 부록 A — 30초 치트시트

```
첫 프로젝트:    /setup
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
| heum 밖에서 `claude` 띄움 | project agent 안 보임 |
| reviewer.md 직접 수정 후 같은 세션 | 재시작 필요 (project agent 변경 반영) |

---

## 부록 C — 산출물

See the directory tree in §2 of this document, or run `find .claude scripts docs -type f` from the workspace root.

---

## 부록 D — Java / Spring Boot 적응 가이드

이 하네스는 Python/Django/FastAPI/Airflow 에 맞춰 튜닝됐지만, **나머지는 거의 다 generic** 입니다. Java/Spring Boot 프로젝트에 적용하려면 사실상 **reviewer.md 한 파일 + 도구명 줄 한두 개** 만 수정.

### 🔴 거의 다 갈아야 함 (1곳)

**`.claude/agents/reviewer.md`** — 4 lens × 4 stack 매트릭스에서 Python 부분을 Java/Spring 으로 교체.

전체 예시는 [`examples/reviewer-java-spring.md`](examples/reviewer-java-spring.md). 그 파일을 그대로 `.claude/agents/reviewer.md` 로 복사해서 쓰면 됩니다.

요점만 보면:

| Lens | Java/Spring 룰 |
|---|---|
| **Security** | `@PreAuthorize` 누락, `@RequestParam` 검증 없음, native query 의 string concatenation 인젝션, `@Value` 평문 비밀, JPA `@EntityListeners` 부작용 |
| **Correctness** | Lombok `@Data` 를 JPA 엔티티에 (equals/hashCode 무한루프), `Optional` 을 필드/매개변수에, `Stream` 두 번 소비, `@Transactional` private 메서드 (안 먹음), checked exception 무시 |
| **Performance** | **JPA N+1** (`@OneToMany(fetch=LAZY)` + loop → `JOIN FETCH` 또는 `@EntityGraph`), `findAll()` 페이징 없이, virtual thread 안 쓰고 ExecutorService 무한 생성 |
| **Operability** | Flyway 마이그레이션 reversible 안 됨, `@Async` 기본 ThreadPoolTaskExecutor 무한큐, log INFO 에 PII 박힘 |

### 🟡 살짝 손봐야 함 (3곳)

| 파일 | 바꿀 것 |
|---|---|
| **`.claude/agents/coder.md`** | `uv` / `pip` / `poetry` → `mvn` / `gradle`. `ruff` / `mypy` → `checkstyle` / `spotbugs` / `errorprone` / `spotless` |
| **`.claude/agents/tester.md`** | `pytest` / `pytest-asyncio` / `freezegun` / `fakeredis` / `respx` / `xfail` → `JUnit 5` / `Mockito` / `Testcontainers` / `AssertJ` / `@Disabled`. `tests/` → `src/test/java/` |
| **`.claude/agents/explorer.md`** | Skip 경로에 `node_modules`, `.venv` 외 `target/`, `build/`, `.gradle/` 추가 |

### 🟢 그대로 OK (나머지 전부)

- 6 verb skill (`/plan` 등) — 언어 무관
- `planner`, `documenter` — 동일
- 2 hooks — 셸 명령 가드라 언어 무관
- `run_phase.py` — Claude CLI 호출 스크립트, Java 프로젝트에서도 그대로
- REQUIREMENTS / ADR / DOC_SYNC_POLICY 템플릿 — 언어 무관

### 30분 안에 Java 화 체크리스트

1. `cp examples/reviewer-java-spring.md .claude/agents/reviewer.md`
2. `.claude/agents/coder.md` — Python 도구명 grep + 교체
3. `.claude/agents/tester.md` — `pytest` → `JUnit 5`, `tests/` → `src/test/java/`
4. `.claude/agents/explorer.md` — skip 경로에 `target/ build/ .gradle/` 추가
5. `CLAUDE.md` — 본인 Java 프로젝트로 채우기
6. `claude` 재시작 → `/plan` 으로 첫 작업

### Kotlin / Scala / Go / Rust

같은 패턴. reviewer 의 스택 룰만 갈아끼우면 됩니다. 새 스택 가이드 추가 PR 환영.
