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

### Phase 3 — 같은 자리를 맴돌면 즉시 멈춘다 (후속 티켓으로 연기, 2026-09-06)

> **본 PR 에 포함하지 않는다.** 무한 루프는 이미 예산 상한 3회가 막고 있어 부재가 위험을 남기지 않는다. 무진전 감지는 루프를 *더 일찍* 멈추는 개선이다. 아래 이월 NIT 2건(진리값 테스트 안전망, 레이스 이음새 문서화)도 본 Phase 착수 시에만 의미가 있으므로 함께 간다.

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
- **Risk**: coder 가 테스트만 추가하고 프로덕션 코드를 안 고친 경우도 diff 는 바뀐다 → 무진전 감지는 **완전한 그물이 아니라 하한선**이다. 진짜 판정은 리뷰어가 한다.

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

---

## Open questions (해결됨 — 2026-09-05)

- [x] **Q1 — verdict 어휘.** `<verdict>` 태그 안에는 `REQUEST CHANGES` (reviewer.md 의 기존 `### 결론` 표기와 동일), `run_phase.py` 의 파싱 결과 문자열은 `CHANGES` 로 정규화. Phase 1 인수 기준이 이미 이 형태다.
- [x] **Q2 — PR 단위.** (2026-09-06 갱신: Phase 3 이 후속 티켓으로 빠져 **PR 범위는 Phase 1 + 2 + 4**.) `feat/loop-enforcement` 한 브랜치에 누적하고 **PR 1개**. 훅·스크립트·문서가 서로 맞물려서, 부분 머지된 중간 상태(예: verdict 태그는 있는데 훅이 없는)가 더 헷갈리기 때문. `/release` 는 Phase 4 이후에 한 번만 호출한다.

## Approval

- [x] Owner approved scope — 2026-09-05, `/work` 호출로 승인
- [x] All open questions resolved
