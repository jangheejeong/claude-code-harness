# Plan: claude-code-harness — 루프 정지 조건을 코드로 강제

Created: 2026-09-05 · Owner: jangheejeong · Branch: `feat/loop-enforcement`

## Goal

하네스 문서 세 곳에 산문으로만 적힌 "auto-fix loop max 3" 을 **실행되는 규칙으로 승격**한다. 지금은 리뷰어가 `BLOCK` 을 내도 `run_phase.py` 가 `status=OK` 로 보고하고, 반복 횟수를 세는 주체가 없어 루프 예산이 지켜졌는지 아무도 검증할 수 없다.

## 배경 — 확인된 사실

- `.claude/skills/work/SKILL.md:34`, `.claude/skills/review/SKILL.md:22`, `.claude/skills/orchestrator/SKILL.md:35` — "max 3" 이 전부 자연어 지시. 카운터 없음.
- `scripts/harness/run_phase.py:143-146` — `proc.returncode` 만 판정 근거로 쓴다. `claude` CLI 는 리뷰어가 BLOCK 을 내도 exit 0 이므로 **BLOCK 이 성공으로 보고된다.**
- `.claude/agents/reviewer.md` 의 `### 결론` 줄은 사람이 읽는 산문이라 기계가 정지 조건을 평가할 수 없다.
- `.claude/settings.json` 에 `SubagentStart` / `SubagentStop` 이 **이미 등록돼 있다.** 붙어 있는 `.claude/hooks/announce-agent.sh:6` 이 `Cosmetic only: always exit 0, never block` 이라 아무것도 제어하지 않을 뿐이다.
- `.claude/hooks/tests/run-tests.sh` — 합성 JSON 을 파이프해 exit code 를 단언하는 테스트 스위트가 이미 있다. 신규 훅의 인수 기준을 여기에 그대로 얹는다.

## 설계 결정

**D1. 강제 지점은 `SubagentStop` 이 아니라 `Stop` 이다.**
공식 문서상 `SubagentStop` 의 exit 2 는 *"Prevents the subagent from stopping"* — 즉 **리뷰어 자신이 계속 돈다.** 리뷰어는 read-only 라 수정할 수 없으므로 의미가 틀렸다. 반면 `Stop` 의 exit 2 는 *"Prevents Claude from stopping, continues the conversation"* 로 **메인 세션이 coder 를 재투입**하게 만든다.
→ `SubagentStop` = **기록 전담(항상 exit 0)**, `Stop` = **판정·강제**.

**D2. 기존 `announce-agent.sh` 는 수정하지 않는다.**
코스메틱 책임을 지키고, 훅을 배열에 append 한다. 동일 이벤트의 훅들은 병렬 실행되고 완료 순서가 비결정적이므로 서로 의존하지 않게 작성한다.

**D3. 상태는 `.claude/notes/loop-state.json` 에.**
카운터가 컨텍스트에 있으면 압축 한 번에 사라진다. `.claude/notes/` 는 `.gitignore:20` 으로 이미 제외돼 있어 커밋 사고가 없다.

**D4. 테스트는 bash 단독.**
pytest 를 새로 들이지 않는다. 하네스는 설치 단계 없이 어디서나 돌아야 하므로 검증 진입점을 `bash .claude/hooks/tests/run-tests.sh` 하나로 유지한다. 이를 위해 `run_phase.py` 에 순수 함수 형태의 `--parse-verdict <logfile>` 진입점을 추가해 bash 에서 exit code 를 단언한다.

**D5. exit code 배분** — 기존 `0` ok / `1` bad args / `2` CLI missing / `3` agent run failed 를 보존하고 `4` = CHANGES, `5` = BLOCK 을 추가한다.

## Non-goals

- 토큰·비용 예산 실링 (무인 실행을 아직 안 하므로 이른 최적화)
- `TaskCompleted` 게이트 (Layer 3. 본 계획이 도는 걸 확인한 뒤 별도 티켓)
- `google` 브랜치(Gemini) 포팅 — 별도 작업. 단 D1 덕분에 `Stop` ↔ `AfterAgent` 가 1:1 대응이라 기능 다운그레이드는 없다.
- `announce-agent.sh` 동작 변경
- 자동 머지 / 사람 게이트 제거 — 세 개의 사람 게이트(plan 승인, 루프 소진, PR 머지)는 그대로 유지한다.

---

## Phases (vertical slices)

> **실행 순서 변경 (2026-09-06)** — **1 → 2 → 4 → (후속) 3.** 번호는 그대로 두고 순서만 바꾼다 (이미 여러 커밋·노트가 "Phase 3 = 무진전 감지", "Phase 4 = 문서" 로 참조하고 있어 renumber 하면 그 참조가 전부 거짓이 된다).
>
> 이유: Phase 2 를 머지해도 **하네스를 쓰는 다른 프로젝트에서는 아무 일도 일어나지 않는다.** `update.sh:84`·`:194` 가 복사하는 훅이 `block-destructive protect-secrets announce-agent post-edit-lint` 하드코딩 4개라 신규 훅 두 개가 전파되지 않고, `:89` 는 `settings.json` 을 *"installed only when the project has none"* 으로 다뤄 기존 프로젝트에 새 훅이 등록될 일이 없다. 거기에 `HARNESS.md:173` 은 이제 거짓이고, 세 스킬 파일의 "max 3" 은 여전히 모델이 센다는 뜻으로 읽힌다.
>
> 즉 지금 상태로 머지하면 **"루프 강제를 만들었다" 가 사실이 아니다** — 이 레포에서만 참이고, 문서는 반대를 말하고, 리뷰어 이름 하나 잘못 지으면 조용히 꺼진다. Phase 4 는 그 셋을 닫아 "만들었다" 를 사실로 만드는 작업이고, Phase 3(무진전 감지)은 그게 사실이 된 뒤에 얹는 개선이다. 무한 루프는 이미 예산 상한 3회가 막고 있으므로 Phase 3 부재가 위험을 남기지 않는다.

### Phase 1 — verdict 가 기계 판독 가능해진다

리뷰어 출력 → 파싱 → exit code 까지 한 줄로 관통하는 슬라이스. 이것만 머지해도 "BLOCK 이 OK 로 보고되는" 문제가 사라진다.

- **Scope**: 리뷰어 출력 템플릿에 파싱 전용 태그 추가 + `run_phase.py` 파싱/exit code 매핑 + 테스트
- **Touched files (expected)**:
  - `.claude/agents/reviewer.md` — Output format 템플릿 말미에 `<verdict>` 한 줄 추가
  - `scripts/harness/run_phase.py` — `--parse-verdict` 진입점, exit code 매핑
  - `.claude/hooks/tests/run-tests.sh` — 케이스 추가
- **Out of scope**: 훅, 카운터, 상태 파일 (Phase 2)
- **Acceptance** (TDD-ready):
  - [ ] `.claude/agents/reviewer.md` Output format 템플릿이 `<verdict>APPROVE|REQUEST CHANGES|BLOCK</verdict>` 를 **마지막 줄로** 포함한다 (기존 `### 결론`·판정 표·Findings 는 그대로 유지)
  - [ ] `run_phase.py --parse-verdict <file>` — 파일에 `<verdict>APPROVE</verdict>` 포함 → stdout `APPROVE`, exit `0`
  - [ ] 같은 진입점, `<verdict>REQUEST CHANGES</verdict>` → stdout `CHANGES`, exit `4`
  - [ ] 같은 진입점, `<verdict>BLOCK</verdict>` → stdout `BLOCK`, exit `5`
  - [ ] ~~태그가 **여러 번** 등장하는 파일(리뷰어가 findings 안에서 예시로 인용한 경우) → **마지막 것**을 채택~~ → **2026-09-05 배치 규칙으로 대체됨**: 태그는 **파일의 마지막 비어있지 않은 줄**에 있을 때만 채택. 그 외 위치의 태그는 `UNKNOWN` + stderr 경고. 사유는 아래 이월 사항 참조
  - [ ] 태그가 없는 파일 → stdout `UNKNOWN`, exit `0` (하위 호환: 기존 에이전트는 태그를 안 냄)
  - [ ] 존재하지 않는 파일 경로 → exit `1`
  - [ ] `--parse-verdict` 는 `claude` CLI 를 호출하지 않는다 (CLI 미설치 환경에서도 exit `2` 가 나지 않음)
  - [ ] 에이전트 실행 경로: `--agent reviewer` 실행 후 로그의 verdict 가 BLOCK 이면 `[run_phase] status=BLOCK` 을 출력하고 exit `5` (기존 `status=OK` 회귀 금지)
- **Risk**: 리뷰어가 태그를 빠뜨릴 수 있다 → `UNKNOWN`+exit 0 으로 안전하게 열어두고, Phase 2 의 훅이 `UNKNOWN` 을 "루프 비활성" 으로 취급한다. 침묵 실패가 아니라 기존 동작으로 되돌아가는 쪽.

**Review: APPROVE — 2026-09-05.** 인수 기준 9/9 충족, 109/109 통과, 수정 루프 0/3 사용. 파싱 경로는 리뷰어의 실제 출력에 대고 실전 검증 완료 (`--parse-verdict` → `APPROVE`, rc 0). 이월 사항은 아래 참조.

#### Phase 1 리뷰 이월 사항

- ✅ **해결 (2026-09-05)** — **[NEW][NIT] `run_phase.py:137`** — 에이전트 실행 경로의 `read_text` 만 `OSError` 무방비. 같은 파일 `report_verdict:70-73` 은 잡는데 여기만 비대칭이라, 터지면 traceback + exit `1` 이 나가고 D5 의 "1 = bad args" 와 구분이 안 된다. **Phase 2 착수 전에 처리** — Phase 2 훅이 `case $?` 로 분기하므로 exit code 의미가 겹치면 안 된다.
- ✅ **해결 (2026-09-05)** — **[EXISTING] `run_phase.py:123`** — argparse 에러가 exit `2` 로 나가 D5 의 "2 = CLI missing" 과 충돌한다. base 커밋 `7573899` 에서도 재현되므로 본 diff 가 만든 게 아니다. 다만 위와 같은 이유로 **Phase 2 훅이 exit code 로 분기하기 전에 정리하는 편이 안전**하다. `argparse.ArgumentParser.error()` 를 오버라이드해 `1` 로 내린다.
- **[NEW][NIT] `HARNESS.md:173`** — `메인엔 status=OK 한 줄만` 문구가 이제 거짓. 리뷰어 경로는 `status=CHANGES` / `status=BLOCK` 도 낸다. **Phase 4 에서 처리** (Q2 의 단일 PR 결정 때문에 그 전에는 main 에 닿지 않음).
- ✅ **해결 (2026-09-05)** — **결정: 조인다** — 태그를 인용만 하고 자기 판정 태그를 빠뜨린 로그는 `UNKNOWN` 이 아니라 **인용된 값으로 파싱된다.** Phase 1 에서는 `UNKNOWN` 도 exit 0 이라 무해했지만, Phase 2 는 `APPROVE` 가 `attempt` 를 0 으로 리셋하고 `UNKNOWN` 은 리셋 없이 통과하므로 **루프 카운터가 조용히 리셋될 수 있다.** → **Phase 2 착수 전에 "태그가 파일의 마지막 비어있지 않은 줄에 있을 때만 채택" 으로 조인다.**

  **단, 조이면 실패 방향이 바뀐다.** 느슨하면 인용된 태그가 가짜 `APPROVE` 로 읽히고(카운터 리셋), 조이면 CLI 가 로그 끝에 뭔가를 덧붙이는 순간 **모든 판정이 `UNKNOWN` 이 되어 루프 강제가 통째로 꺼진다.** 둘 다 "조용히 관대해지는" 쪽으로 깨지므로, 조이는 대신 **침묵을 없앤다**: 파일에 `<verdict>` 태그가 있는데 마지막 줄이 아니면 `UNKNOWN` 을 반환하되 stderr 에 경고를 낸다. "태그 없음" 과 "태그가 제자리에 없음" 은 다른 사건이고, 후자는 사람이 알아야 한다.
- **Question → 별도 결정 필요** — `CLAUDE.md` 의 "기존 코드 전체를 포맷팅하지 않는다" 와 레포 자신의 `.claude/hooks/post-edit-lint.sh` (Edit/Write 마다 `ruff format`) 가 실제로 충돌한다. 이번 diff 의 재포맷은 코더의 선택이 아니라 훅의 결과였다. 어느 쪽을 조정할지는 본 계획 범위 밖.

### Phase 2 — 루프 예산이 실제로 강제된다

`SubagentStop` 기록 + `Stop` 강제. 머지 시 "max 3" 이 처음으로 실행되는 규칙이 된다.

> **Phase 1 실행 중 관찰 (2026-09-05)** — coder·tester·reviewer 세 서브에이전트가 **전부** 보고 없이 턴을 끝냈다. 작업물 자체는 정상이었지만 결과를 git·테스트로 우회 검증해야 했고, 리뷰 결과는 리뷰어에게 재요청해서야 받았다. `/work` 의 "Wait for the diff summary" 와 `/review` 의 "Render the reviewer's verdict" 는 **서브에이전트가 알아서 보고한다는 가정** 위에 서 있는데 3/3 으로 깨졌다. `record-verdict.sh` 가 `SubagentStop` 에서 결과를 디스크에 남기면 보고가 에이전트의 선의가 아니라 훅의 책임이 된다 — 본 Phase 의 가치가 계획 수립 시점보다 커졌다.

- **Scope**: 기록 훅 + 강제 훅 + settings 등록 + 테스트
- **Touched files (expected)**:
  - `.claude/hooks/record-verdict.sh` (신규) — `SubagentStop`, 항상 exit 0
  - `.claude/hooks/enforce-loop.sh` (신규) — `Stop`, 판정
  - `.claude/settings.json` — `SubagentStop` 배열에 append, `Stop` 신규 등록
  - `.claude/hooks/tests/run-tests.sh` — 케이스 추가
- **Out of scope**: 무진전 감지 (Phase 3), 문서 (Phase 4)
- **Acceptance** (TDD-ready):

  `record-verdict.sh` (입력: SubagentStop 페이로드)
  - [ ] `agent_type` 이 `reviewer` 가 아닌 페이로드 → `loop-state.json` 을 만들지도 수정하지도 않고 exit `0`
  - [ ] `agent_type=reviewer` + 트랜스크립트에 `<verdict>BLOCK</verdict>` → `loop-state.json` 에 `last_verdict=BLOCK`, `attempt` 가 1 증가한 상태로 기록, exit `0`
  - [ ] `agent_type=reviewer` + `<verdict>APPROVE</verdict>` → `last_verdict=APPROVE` 기록, `attempt` 를 `0` 으로 리셋, exit `0`
  - [ ] 잘못된 JSON 을 stdin 으로 받아도 exit `0` (announce-agent.sh 와 동일한 headless-safe 계약)
  - [ ] `jq` / `python3` 둘 다 없는 환경에서 stderr 경고 후 exit `0`
  - [ ] **어떤 입력으로도 exit 2 를 내지 않는다** (D1: 서브에이전트를 되돌리면 안 됨)

  `enforce-loop.sh` (입력: Stop 페이로드)
  - [ ] `loop-state.json` 이 없으면 → exit `0` (평범한 대화 턴을 가로채지 않음)
  - [ ] `last_verdict=APPROVE` → exit `0`
  - [ ] `last_verdict=UNKNOWN` → exit `0`
  - [ ] `last_verdict=BLOCK`, `attempt=1` → exit `2`, stderr 에 재투입 사유 + `attempt 1/3` 포함
  - [ ] `last_verdict=REQUEST CHANGES`, `attempt=2` → exit `2`, stderr 에 `attempt 2/3` 포함
  - [ ] `last_verdict=BLOCK`, `attempt=3` → exit `0`, stdout 에 사람 개입 요청 문구. **성공으로 위장하지 않는다**
  - [ ] `last_verdict=BLOCK`, `attempt=4` (경계 초과) → exit `0`
  - [ ] 입력 `stop_hook_active=true` → exit `0` (훅이 유발한 연속 차단을 재차 차단하지 않음)
  - [ ] 잘못된 JSON / 손상된 `loop-state.json` → exit `0` + stderr 경고 (세션을 가두지 않음)

  통합
  - [ ] `.claude/settings.json` 의 `SubagentStop` 배열이 `announce-agent.sh` 와 `record-verdict.sh` 를 **둘 다** 포함하고, `announce-agent.sh` 파일은 무변경
  - [ ] `bash .claude/hooks/tests/run-tests.sh` 전체 통과, 기존 케이스 회귀 0
- **Risk**:
  - `Stop` 훅은 모든 메인 턴 끝에 발화한다. `loop-state.json` 부재 시 즉시 exit 0 하는 가드가 첫 번째 인수 기준인 이유.
  - Claude Code 는 `Stop` 훅의 연속 차단을 8회로 제한한다. 우리 상한 3 이 먼저 걸리므로 이중 안전망.
  - 동일 이벤트 훅은 병렬·비결정 순서로 실행된다 → `record-verdict.sh` 는 `announce-agent.sh` 의 결과에 의존하지 않는다.

**Review: APPROVE — 2026-09-05** (3라운드 소요, 리뷰 예산 3/3 사용). 인수 기준 17/17, 247/247 통과.

라운드별로 실제 결함이 나왔고, **두 번째·세 번째 결함은 앞 라운드의 수정이 만든 것**이다 — 재리뷰 없이 머지했으면 그대로 나갔다:

1. **라운드 1 (BLOCK)** — ① 64비트를 넘는 `attempt` 가 `[ -ge ]` 를 죽이고, 죽은 test 는 false 라 턴을 붙잡았다. ② `loop-state.json` 을 지우는 주체가 없어 버려진 BLOCK 이 이후 **모든 세션의 모든 턴**을 차단했다. + reviewer 게이트 완전일치 / 개행이 필드 경계를 미는 문제 / 트랜스크립트 폴백이 메인 세션 파일을 읽는 문제.
2. **라운드 2 (REQUEST CHANGES)** — ①의 처방(consume-once)이 `enforce-loop.sh` 를 **두 번째 쓰기 주체**로 만들면서, 리뷰어의 `SubagentStop` 이 `Stop` 과 겹치면 **갓 기록된 판정이 아무도 반응하지 않은 채 소비된 상태로 태어나는** 60ms 창이 생겼다. → compare-and-set 으로 닫음.
3. **라운드 3 (APPROVE)** — CAS 를 뮤테이션으로 검증(제거 시 246/247). 남은 NIT 1건은 아래.

#### Phase 2 리뷰 이월 사항

- **[NEW][NIT] `run-tests.sh:1729-1740`** — 진리값 테스트의 **python3 쪽 절반이 공허하다.** 고른 값(`0`,`""`,`[]`,`{}`)이 python 에서 원래 falsy 라, `enforce-loop.sh:84` 의 `is True` 를 맨 truthiness 로 되돌려도 247/247 그대로 통과한다 (직접 뮤테이션 확인). 두 리더가 갈리는 값은 **truthy 이지만 `true` 는 아닌** 쪽 — `1`, `"true"`, `[1]` — 으로 옮겨갔는데 표에 없다. 코드는 맞고 테스트만 못 잡는다. `stop_hook_active` 짝도 같은 상태. **Phase 3 착수 시 함께 처리** — Phase 3 이 같은 파일에 키를 얹으므로 그때 안전망이 필요하다.
- **Question → Phase 3** — 레이스 테스트의 이음새(`run-tests.sh:1136`)는 `mark_enforced` 가 훅의 유일한 `python3 -` 호출이라는 데 의존한다. 깨지는 방향은 안전하지만(가짜가 읽기 시점에 발화하면 `attempt` 불일치로 시끄럽게 죽는다), 그 제약이 **테스트 파일에만** 적혀 있어 훅을 고치는 사람은 못 본다. Phase 3 이 같은 이음새를 재사용한다면 헬퍼로 뽑으면서 `enforce-loop.sh` 쪽에도 주석을 남길 것.

> **알려진 공백 (2026-09-06, Phase 4 작업 중 발견)** — **`/work` 의 tester → coder 루프는 여전히 강제되지 않는다.** `record-verdict.sh:90-93` 이 `reviewer | reviewer-*` 일 때만 기록하므로 그 사이클은 `attempt` 에 잡히지 않고 `enforce-loop.sh` 도 세지 않는다. 실측: `agent_type=tester` / `coder` 는 `NOT RECORDED`. 즉 `work/SKILL.md:34` 의 "max 3" 은 **오늘 고친 세 곳 중 유일하게 산문으로 남은 상한**이고, 문서도 그렇게 쓰여 있다 (모델이 지켜야 하는 상한이며 강제되는 예산은 `/review` 에서 시작한다). 위험도는 낮다 — 그 루프는 `/work` 안에서 메인 세션이 직접 돌리므로 사용자가 진행을 보고 있고, 리뷰 게이트가 뒤에 있다. 그래도 "루프 예산을 코드로 강제했다" 는 문장은 **리뷰어 판정 루프에 한해서만** 참이다. 별도 티켓으로 다룰 것.

### Phase 3 — 같은 자리를 맴돌면 즉시 멈춘다 (착수 2026-09-06, 브랜치 `feat/loop-no-progress`)

> Phase 1·2·4 는 `1a9933c` 로 `main` 에 머지·푸시 완료. 본 Phase 는 그 후속 작업이며 이월 NIT 2건을 함께 처리한다.
>
> **결정 (2026-09-06): 기록 실패의 침묵은 무진전 감지가 아니라 별도 장치로 덮는다.** 무진전 감지는 `last_diff_sha` 를 **사이클 간** 비교하는 장치인데, 기록 자체가 실패하면 비교할 새 사이클이 애초에 없다. 두 고장은 다르다 — 하나는 "돌긴 도는데 안 움직인다", 다른 하나는 "돌았는지조차 모른다". consume-once 를 고르면서 **알면서 만든 유일한 침묵**이므로 이번에 닫는다: `record-verdict.sh` 가 리뷰어 판정을 기록하지 못하면 그 사실을 상태 파일에 남기고, `enforce-loop.sh` 가 한 번 알린 뒤 소비한다 (배너와 동일한 "판정 하나가 반응 하나" 규칙).

무진전 감지(no-progress detection). 예산을 다 쓰기 전에 헛도는 루프를 끊는다.

> **Phase 2 리뷰에서 이월 (2026-09-05)** — consume-once 를 도입하면서 **기록 실패의 방향이 뒤집혔다.** 예전에는 파서가 죽으면 옛 BLOCK 이 계속 차단해 시끄러웠는데, 지금은 옛 판정이 이미 소비돼 턴이 조용히 끝난다. 남는 신호는 `SubagentStop` stderr 한 줄뿐이고 그건 transcript 모드에서만 보인다. 선택지 A 를 고른 이상 불가피한 대가지만, **본 Phase 가 이 침묵을 드러낼 자리인지 결정할 것** — 무진전 감지가 "판정이 아예 기록되지 않은 사이클" 도 무진전으로 셀 수 있다면 같은 장치로 덮인다.

- **Scope**: `loop-state.json` 에 diff 지문 추가 + `enforce-loop.sh` 분기 + 테스트
- **Touched files (expected)**: `.claude/hooks/record-verdict.sh`, `.claude/hooks/enforce-loop.sh`, `.claude/hooks/tests/run-tests.sh`
- **Out of scope**: 문서 (Phase 4)
- **Acceptance** (TDD-ready):
  - [ ] `record-verdict.sh` 가 기록 시 `git rev-parse HEAD` 와 `git diff` 해시를 `last_diff_sha` 로 저장한다
  - [ ] git 저장소가 아닌 cwd 에서 실행 → `last_diff_sha` 를 생략하고 exit `0` (크래시 금지)
  - [ ] `enforce-loop.sh`: `last_verdict=BLOCK`, `attempt=1`, `last_diff_sha` 가 **직전 값과 동일** → exit `0` + stderr 에 무진전 중단 사유. (예산이 남아 있어도 멈춤)
  - [ ] 같은 조건에서 `last_diff_sha` 가 **다르면** → exit `2` (정상 재투입)
  - [ ] `last_diff_sha` 가 없는 상태(첫 사이클) → 무진전으로 판정하지 않는다

  기록 실패를 드러낸다 (위 결정)
  - [ ] `record-verdict.sh` 가 `reviewer|reviewer-*` 의 판정을 **기록하지 못하면** 그 사실을 상태 파일에 남긴다. 기존 `last_verdict`·`attempt` 는 건드리지 않는다 (`Phase 1 리뷰 이월 사항` 의 "판정을 못 읽으면 성공으로 위장하지 않는다" 유지)
  - [ ] `enforce-loop.sh` 가 다음 턴에 그 사실을 **한 번** 알리고 소비한다. 두 번째 턴부터는 조용하다 (배너와 동일한 "판정 하나가 반응 하나" 규칙)
  - [ ] 알림은 턴을 붙잡지 않는다 (exit 0) — 기록 실패는 코더가 고칠 대상이 아니라 사람이 볼 사실이다
  - [ ] 기록에 성공하면 그 표시가 사라진다 (낡은 실패가 계속 알리지 않는다)

  이월 NIT 2건 (Phase 2·4 리뷰)
  - [ ] `run-tests.sh` 진리값 표에 **truthy 이지만 `true` 는 아닌** 값(`1`, `"true"`)을 넣어 python 쪽 절반이 실제로 무는지 고정한다. 현재는 `enforce-loop.sh` 의 `is True` 를 맨 truthiness 로 되돌려도 전부 통과한다 (실측)
  - [ ] `drifting_lists` 가 `export VAR=` / `VAR+=` 형태의 두 번째 목록도 잡고, `for` 분기에 픽스처가 생긴다
  - [ ] `run-tests.sh:1846` 주석이 `[ -f ]` 가드의 실제 역할을 정확히 말한다 (`.claude/hooks/*.sh` 글로브는 `tests/` 를 애초에 안 잡는다)
  - [ ] 레이스 이음새가 의존하는 "`mark_enforced` 가 훅의 유일한 `python3 -` 호출" 제약이 `enforce-loop.sh` 쪽 주석에도 남는다 (지금은 테스트 파일에만 있어 훅을 고치는 사람은 못 본다)
- **Risk**: coder 가 테스트만 추가하고 프로덕션 코드를 안 고친 경우도 diff 는 바뀐다 → 무진전 감지는 **완전한 그물이 아니라 하한선**이다. 진짜 판정은 리뷰어가 한다.

**Review: APPROVE — 2026-09-06** (3라운드, 리뷰 예산 3/3 사용). 인수 기준 13/13, 380/380 통과 (착수 시 262).

세 라운드가 낸 결함이 전부 **앞 라운드의 수정이 만든 것**이었다:

1. **라운드 1 (REQUEST CHANGES)** — 훅은 견고했으나 이 Phase 가 문서·스킬 **5곳을 거짓으로 만들고 고치지 않았다.** 그중 `review/SKILL.md` 와 `orchestrator/SKILL.md` 는 사람이 아니라 **오케스트레이팅 모델이 읽는 지시문**이라, "예산 남으면 exit 2" 를 믿는 모델이 무진전 exit 0 을 통과로 읽고 4번째 사이클을 돌리거나 성공 보고를 하게 된다. + jq-only 마크 / writer 타입 규칙 / untracked 내용 누락.
2. **라운드 2 (REQUEST CHANGES)** — untracked 내용을 넣은 수정이 **거짓 무진전 정지를 다른 문으로 되살렸다**: `git hash-object` 가 열 수 없는 경로에서 `die()` 하고 배치의 나머지를 버려, 정렬상 앞선 dangling symlink 하나가 지문을 동결시킨다. + 문서 3문장이 커밋 순서 때문에 옛 지문 범위를 말함.
3. **라운드 3 (APPROVE)** — 읽기 필터가 건너뛰는 파일을 6형태로, 두 엔진 렌더링을 17형태 × 2엔진으로 실측. 새 결함 없음.

#### Phase 3 리뷰 이월 사항

- **[EXISTING] `enforce-loop.sh:74-75` vs `:136-137`** — `last_verdict` / `attempt` 는 공유 렌더링 규칙 밖이라 `"BLOCK\n"` · `[]` · `{}` 에서 두 엔진이 **다른 exit code** 를 낸다. `1a9933c` 이전부터 있던 문제라 본 Phase 가 만든 게 아니지만, **예산을 결정하는 바로 그 두 키**에 구멍이 있다. 별도 티켓 — 이 Phase 가 세 키에 씌운 규칙을 두 키에 확장하면 된다.
- **APPROVE 이후 처리한 `[NIT]` 2건 (리뷰 라운드 없이)** — 둘 다 "주석·문장이 사실보다 강하게 말한다" 는 같은 종류이고 동작 변경이 0 이라, 알면서 거짓을 머지하는 것보다 낫다고 판단했다. ① `enforce-loop.sh:40` 주석이 "every string-valued key" 라고 했으나 `last_verdict` 는 그 규칙을 안 탄다 → 세 키를 명시하고 위 `[EXISTING]` 구멍을 주석에 적었다. ② 문서 3곳의 "어떤 파일이든 움직이면" 이 과장 — `.claude/notes` 와 gitignore 트리는 제외된다 → **이건 내가 라운드 1 의 거짓을 고치면서 심은 새 거짓이었고, 리뷰어가 잡았다.**

### Phase 4 — 만든 것이 실제로 전파되고, 문서가 그것과 일치한다

**실행 순서상 Phase 2 다음.** 산문 "max 3" 이 훅을 가리키게 만들고, 신규 훅이 다른 프로젝트에도 실제로 설치되게 한다.

- **Scope**: `update.sh` 전파 + 스킬 3종 + HARNESS.md + README 2종 동기화
- **Touched files (expected)**:
  - `update.sh` — 훅 목록 2곳(`:84`, `:194`) + `settings.json` 취급(`:89`) + 안내 문구(`:16`, `:146`)
  - `.claude/skills/work/SKILL.md:34`, `.claude/skills/review/SKILL.md:22`, `.claude/skills/orchestrator/SKILL.md:35`
  - `HARNESS.md`, `README.md`, `README.en.md`
- **Out of scope**: `google` 브랜치 포팅 (별도 작업), Phase 3 의 무진전 감지
- **Acceptance** (TDD-ready):

  전파 — `[EXISTING][CHANGES]`, 본 diff 가 만든 건 아니지만 신규 훅이 생겨서 드러났다
  - [ ] `update.sh:84` 과 `:194` 의 하드코딩 훅 목록에 `record-verdict.sh` 와 `enforce-loop.sh` 가 포함된다. **두 곳 다** — 한쪽만 고치면 diff 보고와 실제 복사가 어긋난다
  - [ ] 목록이 한 곳에 정의되고 두 루프가 그것을 참조한다 (같은 목록을 두 번 적는 구조가 이 누락을 만들었다)
  - [ ] `settings.json` 이 이미 있는 프로젝트에서 `update.sh` 를 돌리면, 새 훅 두 개가 **등록되지 않았다는 사실이 출력에 명시된다.** 조용히 파일만 복사하고 끝내지 않는다 (파일만 있고 등록이 없으면 기능이 죽은 채로 설치된 것과 같다)
  - [ ] 그 경우 사용자가 붙여넣을 수 있는 `settings.json` 스니펫(`Stop` + `SubagentStop` 항목)이 출력되거나, 문서의 해당 절을 가리킨다
  - [ ] `update.sh --help` / 상단 주석의 "all 4" 류 문구가 실제 개수와 일치한다

  문서
  - [ ] 세 스킬 파일의 "max 3" 문구가 `.claude/hooks/enforce-loop.sh` 가 강제한다는 사실을 명시한다 (모델이 자율적으로 세는 게 아님)
  - [ ] **리뷰어 이름 규약을 문서화한다** — `record-verdict.sh` 의 `reviewer | reviewer-*` 게이트가 이제 **루프 강제 전체의 on/off 를 결정하는 계약**인데 어디에도 적혀 있지 않다. 관찰된 이름 3종(`reviewer`, `reviewer-phase1`, `reviewer-phase2`)은 다 걸리지만, 리뷰어를 `phase3-reviewer` 나 `review-gate` 로 띄우면 Phase 2 가 통째로, 조용히 꺼진다. `work/SKILL.md` 와 `HARNESS.md` 에 "리뷰어 서브에이전트 이름은 `reviewer` 로 시작해야 한다" 를 명시할 것. (코드가 아니라 규약이 안 적힌 문제라 리뷰에서 차단 사유는 아니었다)
  - [ ] `work/SKILL.md` 에 **에이전트 수명 규칙**을 추가한다: 다음 서브에이전트를 띄우기 전에 이전 서브에이전트를 명시적으로 종료한다. **idle 은 종료가 아니다.** (2026-09-05 실제 발생: 완료된 `coder` 를 닫지 않은 채 다음 `coder` 를 띄워 두 에이전트가 같은 두 파일의 쓰기 권한을 동시에 보유. 앞 에이전트가 스스로 충돌을 감지하고 멈춰서 손상은 없었으나, 그 감지는 어디에도 규칙으로 없다. `work/SKILL.md:51` 의 worktree 격리는 사용자가 `--parallel` 을 명시한 경우만 다루므로 이 사각지대를 못 덮는다)
  - [ ] `HARNESS.md` 훅 목록에 `record-verdict.sh` / `enforce-loop.sh` 와 담당 이벤트가 등재된다
  - [ ] `README.md` 의 "BLOCK verdict" 절(현 `:276`)이 소진 시 실제 동작(exit 0 + 사람 개입 요청)을 기술한다
  - [ ] `README.en.md` 가 `README.md` 와 내용 동등 (`docs/harness/DOC_SYNC_POLICY.md` 준수)
  - [ ] 문서에 적힌 exit code 표가 `run_phase.py` 실제 값과 일치한다
- **Risk**: 문서 표류. Phase 1~3 각각도 자기가 바꾼 동작에 해당하는 문서를 함께 손대고, Phase 4 는 교차 문서 정리만 담당한다.

**Review: APPROVE — 2026-09-06** (2라운드, 리뷰 예산 2/3 사용). 262/262 통과.

라운드 1 의 `[CHANGES]` 가 날카로웠다 — **전파를 지키는 회귀 테스트가 훅 목록을 디스크가 아니라 손으로 적은 리터럴과 대조**하고 있었다. `update.sh` 의 두 리터럴 목록을 하나로 합쳐놓고, 그 하나가 완전한지 지키는 그물을 다시 리터럴로 짠 셈이다. 실측: 디스크에 7번째 훅을 놓고 `MANAGED_HOOKS` 에서 빼도 259/259 통과 → 오라클을 `.claude/hooks/*.sh` 로 옮긴 뒤에는 261/262 로 이름까지 대며 실패.

#### Phase 4 리뷰 이월 사항 (전부 테스트 파일 내부 `[NIT]`, 후속 티켓)

- **`run-tests.sh:1876`** — `drifting_lists` 가 `export VAR=` / `VAR+=` 형태의 두 번째 목록을 놓친다. `for` 분기는 픽스처가 없어 회귀해도 조용하다.
- **`run-tests.sh:1846`** — 주석이 `[ -f ]` 가드가 `tests/` 를 거른다고 말하지만, `.claude/hooks/*.sh` 글로브는 애초에 `tests`(디렉토리, `.sh` 아님)를 안 잡는다. 가드 자체는 `foo.sh` 라는 디렉토리에 대한 보험으로 유효하나 주석이 사실을 과장한다. (실측 확인)

---

### Phase 5 — 재리뷰가 이미 본 것을 다시 읽지 않는다 (착수 2026-09-14)

**측정이 먼저다.** `.claude/notes/*.diff` 합계 617KB(≈176k 토큰), verdict 로그 143KB(≈41k 토큰), 서브에이전트 58회. Phase 3 한 개가 `76KB → 114KB → 123KB`(r1/r2/r3) = 313KB ≈ 90k 토큰인데, r3 diff 123KB 중 대부분은 r1·r2 에서 이미 읽은 내용이다.

원인은 `review/SKILL.md:12` 의 `git diff $(git merge-base <base> HEAD)...HEAD` 가 **브랜치 누적 diff** 라는 점이다. fix 커밋이 쌓일수록 커지고, 재리뷰는 "이번 수정분"이 아니라 "Phase 전체"를 매번 처음부터 다시 읽는다. 비용이 라운드 수에 선형이 아니라 **누적 × 라운드** 로 붙는다.

> **Non-goals:36 과의 관계** — "토큰·비용 예산 실링" 은 **여전히 non-goal** 이다. 여기서 하는 건 상한을 거는 게 아니라, 같은 리뷰를 같은 품질로 하면서 **중복 입력을 제거**하는 것이다. 리뷰 범위는 줄지 않는다 (D8).

- **Scope**: 리뷰 시점의 HEAD 를 상태 파일에 기록 + `/review` 가 2회차부터 증분 diff 를 뜨도록 분기
- **설계 결정**
  - **D6. diff base 는 커밋 sha 이며 무진전 지문과 별개다.** `last_diff_sha` 는 `record-verdict.sh:258` 의 `git hash-object` 기반 **워킹트리 내용 해시**라 `git diff` 의 base 로 쓸 수 없다. 새 키 `last_reviewed_head` 를 추가한다.
  - **D7. 새 키는 `record-verdict.sh` 만 쓰고 `enforce-loop.sh` 는 읽지 않는다.** 읽는 쪽을 안 건드리면 `enforce-loop.sh:68` 의 jq/python3 이중 엔진 렌더링 규칙(`STATE_STRING_JQ`)과 그 아래 예산 판정 경로가 그대로 남는다. 블라스트 반경을 writer 한쪽으로 가둔다.
  - **D8. 증분은 리뷰어가 보는 1차 표면이지 리뷰 범위가 아니다.** Spec correctness 렌즈는 계속 Phase 전체를 판정한다. 리뷰어에게 증분 diff(인라인) + **직전 전체 diff 파일 경로** + 직전 라운드 findings 를 함께 준다. 리뷰어는 `Read/Grep/Bash` 를 갖고 있으므로 필요하면 실제 파일을 본다.
  - **D9. base 가 닿지 않으면 전체로 폴백한다.** coder 가 amend/rebase 하면 기록된 sha 가 unreachable 이 된다. 조용히 빈 diff 로 리뷰를 통과시키는 게 최악이므로, 존재 확인에 실패하면 merge-base 전체 diff 로 되돌아가고 그 사실을 리뷰어에게 명시한다.
  - **D10. 증분은 `<sha>..HEAD` 가 아니라 `git diff <sha>`.** 후자는 워킹트리까지 포함한다. coder 가 커밋을 안 한 경우 전자는 빈 diff 가 되는데, 그건 "수정 없음"이 아니라 "커밋 안 함"이고 기존 3단계가 이미 `[NEW][CHANGES]` 로 잡는 사안이다.
- **Touched files (expected)**:
  - `.claude/hooks/record-verdict.sh` — `record_state()` 에 `last_reviewed_head` 쓰기 (읽기 추가 없음)
  - `.claude/skills/review/SKILL.md` — 2단계 diff 캡처 분기
  - `.claude/agents/reviewer.md:25` — Process 3 을 증분 분기에 맞춤
  - `.claude/hooks/tests/run-tests.sh` — 케이스 추가
  - `HARNESS.md`, `README.md`, `README.en.md` — 동기화
- **Out of scope**: `enforce-loop.sh` 수정, 무진전 감지 로직 변경, `/orchestrator` 자동화, verdict 로그 크기(별건)
- **Acceptance** (TDD-ready):

  기록 — `record-verdict.sh`
  - [ ] BLOCK / CHANGES 기록 시 `last_reviewed_head` 에 그 시점 `git rev-parse HEAD` 가 **JSON 문자열로** 들어간다
  - [ ] APPROVE → 키를 **삭제**한다. `forget_progress()` 와 같은 이유 — Phase 가 끝났으므로 다음 Phase 는 전체 리뷰로 시작해야 한다
  - [ ] UNKNOWN → 키를 **그대로 둔다**. 판정이 없었으면 사이클도 없었고, 다음 판정은 마지막으로 판정된 리뷰 기준으로 비교돼야 한다
  - [ ] git 저장소가 아니거나 HEAD 가 없는(커밋 0개) 경우 → **키를 쓰지 않는다.** 빈 문자열이나 에러 문자열을 넣지 않는다 (`last_diff_sha` 의 string-or-nothing 규칙과 동일)
  - [ ] 기존 키(`last_verdict`, `attempt`, `enforced`, `last_diff_sha`, `prev_diff_sha`, 훅이 모르는 키)가 전부 보존된다
  - [ ] **`enforce-loop.sh` 의 판정이 이 키와 무관하다** — `last_reviewed_head` 에 숫자·리스트·불린·누락 어느 것을 넣어도 예산 강제 exit code 가 불변 (D7 을 테스트로 고정)

  소비 — `review/SKILL.md`
  - [ ] 2단계가 두 분기로 갈라진다: `last_reviewed_head` 없음 → merge-base 전체 diff / 있음 → `git diff <last_reviewed_head>`
  - [ ] base sha 가 unreachable (`git cat-file -e <sha>^{commit}` 실패) → 전체 diff 폴백 + 리뷰어에게 폴백 사실 명시 (D9)
  - [ ] 증분 리뷰 시 리뷰어에게 넘기는 3종이 명시된다: 증분 diff / 직전 전체 diff 파일 경로 / 직전 라운드 findings (D8)
  - [ ] Spec correctness 렌즈는 Phase 전체 기준임이 스킬과 `reviewer.md` 양쪽에 적힌다 — **증분만 보고 인수 기준을 판정하지 않는다**
  - [ ] 증분 diff 가 비어 있으면 "리뷰 스킵"이 아니라 무진전이다. `enforce-loop.sh` 의 `무진전 중단` 과 같은 결론(에스컬레이션)으로 간다

  문서
  - [ ] `HARNESS.md` 의 loop-state.json 키 목록에 `last_reviewed_head` 와 "writer 전용" 이 등재된다
  - [ ] `README.md` / `README.en.md` 내용 동등 (`docs/harness/DOC_SYNC_POLICY.md` 준수)
- **Risk**: 증분 리뷰가 회귀를 놓친다 — 라운드 2 의 fix 가 라운드 1 에서 통과시킨 코드를 깨뜨리는 경우. 완화는 D8(전체 diff 파일 포인터 + 전체 기준 spec 렌즈)이고, 이건 **완화지 제거가 아니다.** 실측으로 확인할 것: Phase 5 자신의 리뷰가 2라운드 이상 가면 그 라운드가 곧 이 리스크의 첫 시험대다.
- **기대 효과**: Phase 3 실측 기준 90k → ~30k 토큰. 라운드가 늘수록 격차가 커진다.

### Phase 6 — 워커를 다시 만들지 말고 이어 쓰고, 보고는 디스크에 둔다 (착수 2026-09-15)

> **프로세스 누락 기록.** 이 Phase 의 코드(`f733a90`)가 **계획 항목보다 먼저 커밋됐다.** 하네스 자기 규칙(`코드 전에 합의된 Plans.md`) 위반이고, 리뷰어가 spec correctness 를 판정할 근거가 없는 상태였다. 본 항목은 리뷰 직전에 사후 작성한 것이며, 그 사실을 숨기지 않기 위해 여기 적는다.

Phase 5 가 **재리뷰가 다시 읽는 diff** 를 줄였다면, 여기는 같은 비용의 나머지 두 갈래 — **fix 라운드가 다시 쌓는 컨텍스트**와 **모델 경계를 넘는 보고 크기** — 를 줄인다.

- **측정 근거**: 2026-09-05~06 세션에서 서브에이전트 29회 스폰. 그중 fix 라운드 8회 대부분을 **기존 워커 재개가 아니라 신규 스폰**으로 처리했고, 각 신규 코더가 `Plans.md`·훅 2개·리뷰 로그를 처음부터 다시 읽었다.
- **설계 결정**
  - **D11. 같은 일이 이어지면 재개, 역할이 바뀌면 닫는다.** 기존 규칙 "다음을 띄우기 전에 이전 것을 닫아라" 는 *두 워커가 같은 파일을 동시에 들지 않게* 하려던 것인데, 모든 인수인계에 적용되어 이어서 할 일까지 닫았다. 공식 문서는 invocation 이 항상 새 인스턴스를 만들고 재개는 의도적 행위임을 명시한다. 프롬프트 캐시도 같은 방향 — 2회 이하에서는 손해, 3회 근처에서 손익분기이고 fix 루프가 정확히 3회다.
  - **D12. 보고는 파일이 먼저, 답장은 나중.** 모델 경계를 넘는 토큰은 두 번 청구되고 그 세션이 끝날 때까지 컨텍스트에 남는다. 오케스트레이터에게 필요한 건 verdict 와 "누구에게 넘길지" 뿐이다. 부수 효과로 크래시 내성이 생긴다 — 2026-09-06 리뷰어 하나가 세션 한도로 죽었는데 파일에 먼저 썼기 때문에 리뷰가 살아남았다.
  - **D13. 조용함을 멈춤으로 읽지 않는다.** 2026-09-06 감사를 마치고 테스트를 쓰던 tester 를 "5분간 파일 안 씀" 을 근거로 죽여 미커밋 작업을 잃었다. 90초 스위트를 반복 실행 중이었다. 판단 근거는 시간이 아니라 산출물(커밋·파일·프로세스)이다.
- **Touched files**: `.claude/skills/work/SKILL.md`, `.claude/skills/review/SKILL.md`, `.claude/agents/reviewer.md`
- **Out of scope**: 훅 수정, `run_phase.py`, Phase 5 의 증분 diff 로직, `/orchestrator` 자동화
- **Acceptance**
  - [ ] `work/SKILL.md` 수명 규칙이 "역할 전환 시 닫기 / 연속 시 재개" 로 갈라지고, 닫아야 하는 이유(파일 동시 보유)가 남는다
  - [ ] `review/SKILL.md` 의 fix 라운드가 신규 스폰이 아니라 **기존 코더·리뷰어 재개**를 기본으로 지시한다. 문서 전용 findings 는 documenter 로 간다고 명시한다 (`enforce-loop.sh:379` 의 재투입 문구와 일치)
  - [ ] `reviewer.md` 가 전문을 `.claude/notes/` 에 **먼저** 쓰고 답장에는 verdict + 판정 표 + 경로만 담도록 지시한다
  - [ ] `review/SKILL.md` 6단계가 그 파일을 `--parse-verdict` 로 기계 판독하고, 전문을 대화에 붙여넣지 말라고 명시한다
  - [ ] "조용함 ≠ 멈춤" 이 근거 사례와 함께 `work/SKILL.md` 에 남는다
  - [ ] 기존 401 케이스 회귀 0 (본 Phase 는 훅을 안 건드리므로 스위트는 카나리아)
**Review: APPROVE — 2026-09-15** (2라운드, 예산 2/3). Phase 5·6 공통. 407/407 통과 (착수 시 401).

라운드 1 은 **BLOCK** 이었고 그 결함은 내가 만든 것이다 — `reviewer.md` 에서 `<verdict>` 태그를 "파일에 쓸 전문의 형식" 안으로 밀어넣어, **답장에는 태그를 요구하지 않게** 됐다. `record-verdict.sh` 는 답장만 읽으므로 판정이 `UNKNOWN` 으로 기록되고 그 라운드가 세어지지 않는다. 파일 쪽 판정은 멀쩡히 읽히므로 경고도 안 뜬다. **토큰을 아끼려던 최적화가 루프 강제를 끄는 경로였다.** 이번에 안 터진 건 스폰 프롬프트에 태그를 직접 요구해서였고, 그 임시 지시가 결함을 가렸다.

라운드 2 는 **Phase 5·6 을 자기 자신에게 적용한 첫 사례**다 — 리뷰어를 재스폰이 아니라 재개했고, diff 는 444줄 전체가 아니라 229줄 증분이었다. 둘 다 리뷰 품질을 떨어뜨리지 않았다(리뷰어 판정).

#### Phase 5·6 리뷰 이월 사항

- **[NEW][NIT] `run-tests.sh:231-235`** — 태그 규칙 검사가 두 줄을 합쳐 보므로, 규칙을 "파일만"으로 약화시켜도 초록이다. 그물이 성긴 것이지 동작 결함은 아니다.
- **[NEW][NIT] `review/SKILL.md:31`** — 복구 지시가 태그의 **존재**만 조건으로 삼아, 템플릿의 플레이스홀더를 그대로 복사한 답장을 못 잡는다.
- **Question → 별도 티켓** — **탈출구가 코더 쪽에만 있다.** D11 은 "같은 finding 이 두 번 돌아오면 워커를 닫고 새로"인데, 재개된 **리뷰어**가 같은 지점을 두 라운드 연속 잘못 판정하거나 재검증을 생략하면 대응물이 없다. Plans.md 의 완화가 "리뷰어는 매 라운드 독립적으로 판정한다" 인데, **리뷰어 자신이 재개되면 그 독립성이 자동으로 주어지지 않는다.** 이번 라운드엔 사고가 없었지만 라운드 3 을 겪지 않아서일 수도 있다.
- **Question → 별도 티켓** — `run-tests.sh:236-240` 의 `grep -qF 'record-verdict.sh'` 가 파일 어디든 그 문자열이 있으면 통과한다. 의도가 "훅 이름이 언급된다" 인지 "답장의 태그를 읽는 주체로 언급된다" 인지에 따라 조여야 한다.

- **Risk**: 재개가 **오염된 컨텍스트를 물려준다.** 잘못된 가정 위에서 수정한 코더를 재개하면 그 가정이 그대로 남는다 — 신규 스폰의 유일한 장점이 백지에서 시작하는 것이었다. 완화는 리뷰어가 매 라운드 독립적으로 판정한다는 것이고, **이건 완화지 제거가 아니다.** 재개한 워커가 같은 실수를 반복하면 그때는 닫고 새로 띄울 것.

---

### Phase 7 — 포매터는 그 레포가 고른 것을 쓴다 (착수 2026-09-15)

**측정이 먼저다.** `~/Projects/heum` 하위 파이썬 프로젝트 23개 중 포매터 설정이 있는 게 11개, 없는 게 12개다. 설정이 있는 11개 중 **8개가 black** 이고, 그 8개의 `line-length` 는 전부 **119~120** 이다. `ruff format` 의 기본값은 **88** 이고 ruff 는 `[tool.black]` 을 읽지 않는다.

`post-edit-lint.sh:57-62` 은 포매터를 **설치 여부로** 고른다:

```bash
if command -v ruff >/dev/null 2>&1; then ruff format "$FILE"
elif command -v black >/dev/null 2>&1; then black --quiet "$FILE"
fi
```

ruff 가 깔려 있으면 무조건 ruff 다. 그래서 120자로 맞춰둔 8개 레포에서 파이썬 파일을 편집하면 **88자로 접힌다.** `CLAUDE.md` 의 "기존 코드 전체를 포맷팅하지 않는다 — 손댄 줄만 바뀌어야 리뷰가 가능하다" 와 충돌하고, 이 충돌은 Phase 1 리뷰가 이미 지적해 미결로 남겨둔 것이다.

> **전역 설치와의 관계** — 이 Phase 는 전역화의 전제다. 지금 고치지 않고 `~/.claude/` 로 올리면 같은 어긋남이 heum 밖 레포까지 간다. 다만 **전역화 자체가 이 문제를 만든 건 아니다** — heum 안에서 이미 8개 프로젝트가 대상이다.

- **Scope**: `post-edit-lint.sh` 의 포매터 선택을 프로젝트 선언 기준으로 바꾼다
- **설계 결정**
  - **D14. 선택 기준은 설치 여부가 아니라 프로젝트 설정이다.** 편집된 파일에서 위로 올라가며 `ruff.toml` / `.ruff.toml` / `pyproject.toml` 의 `[tool.ruff]` 를 찾으면 ruff, `[tool.black]` 을 찾으면 black 을 쓴다. 레포 경계(`.git`)에서 멈춘다.
  - **D15. 둘 다 없으면 포맷하지 않는다.** 설정이 없다는 건 그 레포가 스타일을 선언한 적이 없다는 뜻이고, 거기에 ruff 기본값을 씌우는 것이 바로 이 Phase 가 고치는 결함이다. **이건 동작 변경이다** — 현재 12개 프로젝트가 ruff 기본값으로 포맷되고 있고, 그것이 멈춘다. 리뷰어의 low-nit 정책은 그만큼 사람이 받쳐야 한다.
  - **D16. 둘 다 선언한 레포는 ruff 우선.** ruff 가 black 호환 포맷터이고, 둘을 번갈아 돌리면 서로 되돌리는 상태가 된다. 한쪽을 골라야 한다면 프로젝트가 나중에 도입했을 가능성이 높은 쪽이다.
- **Touched files**: `.claude/hooks/post-edit-lint.sh`, `.claude/hooks/tests/run-tests.sh`
- **Out of scope**: 전역 설치 자체(`~/.claude/` 배치, `record-verdict.sh` 의 파서 경로), 다른 훅, 문서
- **Acceptance** (TDD-ready)
  - [ ] `[tool.black]` 만 있는 프로젝트의 `.py` 편집 → **black 이 실행**되고 그 `line-length` 가 적용된다 (120자 줄이 안 접힌다)
  - [ ] `[tool.ruff]` 만 있는 프로젝트 → ruff 실행
  - [ ] `ruff.toml` / `.ruff.toml` 파일만 있어도 ruff 로 인식한다
  - [ ] 둘 다 선언 → ruff (D16)
  - [ ] **둘 다 없음 → 아무 포매터도 실행하지 않고 exit 0**, 파일 무변경 (D15)
  - [ ] 설정 탐색이 편집된 파일의 디렉토리에서 위로 올라가되 **`.git` 이 있는 디렉토리에서 멈춘다** (상위 레포의 설정을 빌려오지 않는다)
  - [ ] 선언된 포매터가 설치돼 있지 않으면 → 조용히 건너뛴다 (exit 0). 다른 포매터로 대체하지 않는다
  - [ ] `.py` 가 아닌 파일 / 존재하지 않는 파일 / 잘못된 JSON → 기존대로 exit 0
  - [ ] **항상 exit 0** — 이 훅은 코더를 막지 않는다 (기존 계약)
  - [ ] 407 케이스 회귀 0
- **Risk**: D15 가 12개 프로젝트의 자동 포맷을 끈다. 그 레포들은 스타일이 흐트러지기 시작하고, 리뷰어가 `[NIT]` 으로 지적할 여지가 늘어난다 — low-nit 정책이 자동화에 기대던 부분이다. **완화는 각 레포에 포매터 설정을 넣는 것**이고, 그건 이 훅이 아니라 그 레포의 결정이다.

### Phase 8 — 하네스를 모든 폴더에서 쓴다 (착수 2026-09-15)

지금 하네스는 `~/Projects/heum` 아래에서만 돈다. 그 폴더 루트의 `.claude/` 가 하위 레포 전부에 적용되는 구조이고, 그 밖 폴더에서는 아무 훅도 걸리지 않는다. 훅을 `~/.claude/` 로 올리면 전역이 된다 — user 레벨 훅은 이미 작동 중이다 (`~/.claude/settings.json` 에 `PreToolUse` 항목 1개).

- **Scope**: `record-verdict.sh` 의 파서 경로 + `~/.claude/` 배치·등록
- **측정 근거**
  - 전역화에서 깨지는 코드는 **한 곳뿐**이다. 훅 6개 중 `record-verdict.sh:44` 만 `$0` 기준 상대경로로 `../../scripts/harness/run_phase.py` 를 찾는다. `~/.claude/hooks/` 에 두면 `~/scripts/harness/run_phase.py` 가 되어 존재하지 않는다. 나머지는 `$CLAUDE_PROJECT_DIR` 만 쓰거나(상태 파일 — 프로젝트별로 갈리는 게 맞다) 경로 의존이 없다.
  - **user 와 project 양쪽에 같은 훅이 등록되면 둘 다 발동한다.** 실측: 리뷰어 한 번에 `record-verdict.sh` 가 두 번 돌면 `attempt` 가 **1이 아니라 2** 증가한다. 예산 3회가 실질 1.5회가 되고 두 번째 BLOCK 에서 소진된다.
- **설계 결정**
  - **D17. 파서 경로는 환경변수로 덮을 수 있게 한다.** `RUN_PHASE="${HARNESS_RUN_PHASE:-$(self_dir)/../../scripts/harness/run_phase.py}"`. 레포 안에서는 지금과 동일하게 동작하고, 전역 설치는 `~/.claude/settings.json` 의 `env` 에 절대경로를 넣어 해결한다. `~/scripts/` 를 만들거나 심링크를 거는 것보다 의도가 드러난다.
  - **D18. 등록은 한 곳에만.** 전역 설치 후 `~/Projects/heum/.claude/settings.json` 의 훅 등록을 **뺀다.** 양쪽에 두면 카운터가 두 배로 오르고, 그건 이 하네스가 존재하는 이유인 예산을 조용히 반토막 낸다. 훅 *파일* 은 남겨도 무해하지만 등록은 하나여야 한다.
  - **D19. `post-edit-lint.sh` 는 Phase 7 이 끝난 뒤에만 전역으로 간다.** 설치 여부로 포매터를 고르는 동안 전역화하면 그 어긋남이 heum 밖 레포까지 간다. Phase 7 이 전제다.
- **Touched files**: `.claude/hooks/record-verdict.sh` (한 줄), `.claude/hooks/tests/run-tests.sh`, 그리고 레포 밖 설치 작업(`~/.claude/`, `~/Projects/heum/.claude/settings.json`)
- **Out of scope**: 다른 훅의 동작 변경, `update.sh` 의 전역 설치 지원(별건), 스킬·에이전트의 전역화(이미 `~/.claude/skills` 20개가 돌고 있으므로 별개 사안)
- **Acceptance** (TDD-ready)
  - [ ] `HARNESS_RUN_PHASE` 가 설정돼 있으면 그 경로를 쓴다
  - [ ] 설정돼 있지 않으면 기존 `$0` 기준 경로를 그대로 쓴다 (레포 안 동작 무변경)
  - [ ] 그 변수가 가리키는 파일이 없으면 → 기존 "파서를 실행할 수 없음" 경로로 떨어진다. `record_failed` 를 남기고 exit 0, 카운터 무변경
  - [ ] 빈 문자열이면 기본값으로 떨어진다 (`${VAR:-...}` 의 동작을 테스트로 고정)
  - [ ] 407 케이스 회귀 0
  - 설치 검증 (수동, 레포 밖)
  - [ ] 하네스가 없는 폴더에서 평범한 대화 → `enforce-loop.sh` 가 exit 0, 상태 파일 생성 안 함
  - [ ] `~/Projects/heum` 에서 리뷰어 1회 → `attempt` 가 **1만** 증가 (D18 이 지켜졌는지)
- **Risk**: D18 을 빠뜨리면 예산이 조용히 반토막 난다. 실측으로 확인했고, 증상은 "두 번째 BLOCK 에서 3/3 소진" 이라 원인을 찾기 어렵다. 설치 후 `attempt` 증가폭을 반드시 확인할 것.

## Open questions (해결됨 — 2026-09-05)

- [x] **Q1 — verdict 어휘.** `<verdict>` 태그 안에는 `REQUEST CHANGES` (reviewer.md 의 기존 `### 결론` 표기와 동일), `run_phase.py` 의 파싱 결과 문자열은 `CHANGES` 로 정규화. Phase 1 인수 기준이 이미 이 형태다.
- [x] **Q2 — PR 단위.** (2026-09-06 갱신: Phase 3 이 후속 티켓으로 빠져 **PR 범위는 Phase 1 + 2 + 4**.) `feat/loop-enforcement` 한 브랜치에 누적하고 **PR 1개**. 훅·스크립트·문서가 서로 맞물려서, 부분 머지된 중간 상태(예: verdict 태그는 있는데 훅이 없는)가 더 헷갈리기 때문. `/release` 는 Phase 4 이후에 한 번만 호출한다.

## Approval

- [x] Owner approved scope — 2026-09-05, `/work` 호출로 승인
- [x] All open questions resolved
