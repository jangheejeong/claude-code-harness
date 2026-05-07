# claude-code-harness

> **Claude Code v2.1+** 용 Plan → Work → Review → Release 하네스. Python / Django / FastAPI / Airflow 프로젝트에 맞춰 튜닝됨.

[![Claude Code](https://img.shields.io/badge/Claude_Code-v2.1+-purple)](https://code.claude.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

[English](README.md) | **한국어**

---

## 이게 뭔가요

Claude Code 를 "절차에 따라 일하는 개발 파트너" 로 만들어주는 drop-in `.claude/` 설정 모음:

- **Subagent 6개** (explorer, planner, coder, tester, reviewer, documenter) — 각자 격리된 컨텍스트 윈도우에서 동작. verbose 출력이 메인 세션에 흘러들어오지 않음.
- **Verb 스킬 6개** (`/plan`, `/work`, `/review`, `/release`, `/setup`, `/orchestrator`) — 명시적인 워크플로우 단계 + 필수 게이트.
- **안전 hook 2개** — 위험한 셸 명령(`rm -rf /`, `git push --force`, `git reset --hard origin/*`) 차단 + 시크릿 파일(`.env`, `*.pem`, `credentials.json`, `.mcp.json`) 쓰기 거부. 모델 판단이 아니라 코드로 강제.
- **Phase 러너 스크립트** — `scripts/harness/run_phase.py` 로 긴 phase 작업을 메인 컨텍스트 밖으로 격리.
- **문서 템플릿** — `REQUIREMENTS.md`, `ADR-NNN.md`, `DOC_SYNC_POLICY.md`.

## 왜 하네스가 필요한가

Claude Code 는 강력하지만 기본 상태로는 절제가 부족합니다. 이 하네스가 강제하는 것:

1. **Plan-first** — Phase 단위로 분해된 `Plans.md` + 측정 가능한 acceptance 기준 없이는 코드 변경 금지.
2. **Phase 경계** — 한 번에 하나의 reviewable 단위 (≤400 LoC diff 권장).
3. **4-lens 리뷰** — spec correctness / security / correctness & maintainability / performance — 거기에 Django ORM N+1, FastAPI async-sync 혼합, Airflow idempotency 같은 **스택 특화 체크** 포함.
4. **Hooks over hopes** — 위험 명령은 모델이 "참아주는 게" 아니라 결정론적 셸 스크립트로 차단.
5. **사람 게이트** — 사용자가 plan 을 승인하고, verdict 를 검토하고, PR 을 머지함. 하네스는 사람 일을 **줄여주는** 거지 **없애지** 않습니다.

"AI 가 알아서 다 한다" 가 아니라, "AI 가 비싼 부분을 처리하고 사람은 게이트만 통과시킨다" 입니다.

## 설치

### 빠르게 (기존 프로젝트에 추가)

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

### 멀티프로젝트 워크스페이스 (모노레포 또는 다중 repo)

`~/projects/foo/` 안에 여러 독립 git repo 가 있고 그 전체를 하나의 하네스로 다루고 싶다면:

1. 워크스페이스 루트에 `.claude/`, `scripts/`, `docs/`, `CLAUDE.md`, `HARNESS.md` 떨어뜨림.
2. `CLAUDE.md` 의 프로젝트 지도 표를 본인 서브프로젝트들로 채움.
3. 워크스페이스 루트에서 `claude` 실행 — Claude Code 가 그 안의 모든 서브프로젝트에 대해 하네스 적용.

## 사용법 (30초 흐름)

```
$ cd ~/your-project && claude

> api-server 의 webhook 에 HMAC 검증 붙여줘. /plan 가자
   ⛔ STOP — 생성된 Plans.md 검토 + Approval ✓

> /work 1
   ⛔ STOP — diff 한 번 보기

> /review
   ⛔ STOP — verdict 확인

> /release   # ← 직접 타이핑 필요. 자동 호출 잠겨있음
   ⛔ STOP — GitHub 에서 PR 머지

> /work 2 ... 반복
```

짧은 작업은 하네스 우회:
```
> apps/server.py 의 logger 레벨 INFO 로 바꿔줘
```

## 폴더 구조

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

## Reviewer 의 스택 특화 체크리스트

`reviewer` agent (Opus) 가 4 lens × 4 stack 매트릭스로 검토:

| Lens | 일반 | Django | FastAPI | Airflow |
|---|---|---|---|---|
| **Security** | secrets, PII 로깅 | raw SQL f-string, mark_safe XSS | `Depends` 인증, `response_model` 누설 | BashOperator 인젝션, Connection 평문 |
| **Correctness** | comprehension, mutable default, EAFP, `with` | `save()` override, signals, migration reversibility | async-sync 혼합, Pydantic v1↔v2 | 멱등성, 최상위 import, `xcom` 페이로드 크기, Jinja 템플릿 |
| **Performance** | generator | **N+1** (`select_related`/`prefetch_related`), `bulk_*`, `.exists()` vs `len()` | unbounded query, sync logging in async | dynamic task mapping, sensor reschedule mode, pool/priority |

발견 사항 태그:
- `[BLOCK]` — 머지 차단
- `[CHANGES]` — 머지 전 수정 권장
- `[NIT]` — 선택적 개선
- `[EXISTING]` — 기존 코드 이슈 (이번 PR 차단 안 함, 별도 티켓 권장)

## 안전 hook — 무엇을 막나

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

## 솔직한 한계

- **"개발자 0명" 은 마케팅.** Plan 승인, BLOCK verdict, PR 머지는 사람 결정.
- **Plan 의 품질이 모든 것을 결정.** 부실한 Plan = 부실한 코드 + 부실한 테스트 + 부실한 리뷰. Planner 에 Opus 토큰 쓰는 게 항상 이득.
- **비용 감각.** 풀 `/orchestrator` 한 사이클은 단순 채팅 대비 ~5-6배. Phase 잘게 쪼개거나 사소한 작업은 하네스 우회.
- **멀티 repo 동시 변경**은 하네스가 잘 못 다룸. 한 번에 한 저장소.

## 라이선스

MIT. [LICENSE](LICENSE) 참고.

## 기여 / 영감

- 워크플로우 구조: 민세홍님의 6-agent 디자인 (heum 모노레포용) 에서 시작.
- Best-practice 참고: [Chachamaru127/claude-code-harness](https://github.com/Chachamaru127/claude-code-harness), [Anthropic Claude Code 공식 문서](https://code.claude.com/docs).
