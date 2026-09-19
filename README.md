# Claude Code Harness

Claude Code의 기본 동작을 덮어쓰지 않고, 계획·구현·리뷰·릴리스를 일관되게 돕는 가벼운 개인용 하네스입니다.

## 구성

- 에이전트 6개: `explorer`, `planner`, `coder`, `tester`, `reviewer`, `documenter`
- 스킬 6개: `/plan`, `/work`, `/review`, `/release`, `/setup`, `/orchestrator`
- 안전 훅 2개: 파괴적 명령 차단, 비밀 파일 쓰기 차단
- 설치기: 정본을 전역 Claude 설정에 심볼릭 링크하고, 확인된 과거 복제본만 백업 후 정리

수명주기 훅 루프, 디스크 재시도 카운터, 외부 phase runner, 에이전트 호출 알림, 편집 후 자동 lint는 사용하지 않습니다. 재시도가 필요하면 `/orchestrator`가 대화 안에서만 조율합니다.

## 권장 흐름

작은 수정은 메인 에이전트가 직접 처리합니다. 요구사항이나 위험이 있는 변경은 다음 흐름을 사용합니다.

```text
/plan → /work → /review → /release
```

- `/plan`: `Plans.md`에 범위와 인수 기준을 정리합니다.
- `/work`: 승인된 Phase 하나를 작게 구현합니다. tester는 필요할 때만 사용합니다.
- `/review`: 스펙, 보안, 정확성·유지보수성, 성능·운영성의 네 관점을 한 번 검토합니다.
- `/release`: 사용자가 요청했을 때만 문서·커밋·푸시·PR을 준비합니다.
- `/orchestrator`: 비단순 작업의 전체 흐름과 수정·재리뷰를 조율합니다. 최초 리뷰를 포함해 최대 3회만 수행합니다.

같은 지적이 반복되거나, 결과가 불명확하거나, 세 번째 리뷰에서도 승인되지 않으면 자동 진행을 멈추고 사용자에게 보고합니다.

## 모델과 추론 강도

| 역할 | 모델 | 추론 강도 |
|---|---|---|
| planner, reviewer | Opus | high |
| coder, tester | Sonnet | high |
| explorer | Sonnet | medium |
| documenter | Haiku | low |

판단 오류의 비용이 큰 역할에 Opus를 쓰고, 구현·검증에는 Sonnet을 사용합니다. 탐색과 문서화는 작업 성격에 맞춰 강도를 낮춰 토큰과 지연을 줄입니다.

## 설치

```bash
git clone https://github.com/jangheejeong/claude-code-harness.git
cd claude-code-harness
python3 scripts/install.py --workspace /Users/jangheejeong/Projects/heum
```

설치기는 다음 원칙을 지킵니다.

- `~/.claude/agents`, `~/.claude/skills`, `~/.claude/hooks`에 이 저장소를 가리키는 링크를 만듭니다.
- 기존 사용자 설정과 관리 대상이 아닌 파일은 보존합니다.
- 해시가 일치하는 과거 하네스 복제본만 타임스탬프 백업으로 옮깁니다.
- 오래된 하네스 훅 등록과 `HARNESS_RUN_PHASE`만 제거합니다.
- 실험적 agent teams 설정은 변경하지 않습니다.

변경 내용을 먼저 확인하려면 `--dry-run`을 사용하세요.

```bash
python3 scripts/install.py --workspace /Users/jangheejeong/Projects/heum --dry-run
```

## 검증

```bash
python3 -m unittest discover -s tests -v
bash .claude/hooks/tests/run-tests.sh
```

설치 후 새 Claude Code 세션에서 `/skills`로 스킬을 확인할 수 있습니다. 이미 존재하는 에이전트·스킬 디렉터리는 실행 중에도 다시 읽히지만, 설정 훅 변경은 새 세션에서 확인하는 편이 가장 확실합니다.

운영 원칙과 문제 해결 방법은 [HARNESS.md](HARNESS.md)를 참고하세요.

## 설계 근거

- [Claude Code skills](https://code.claude.com/docs/en/skills): 스킬 본문은 호출 후 컨텍스트에 남으므로 짧게 유지합니다.
- [Claude Code subagents](https://code.claude.com/docs/en/sub-agents): 격리 가치가 있는 독립 작업에만 subagent를 사용합니다.
- [Claude Code hooks](https://code.claude.com/docs/en/hooks): 훅은 여러 설정 계층에서 합쳐지므로 최소 안전 가드만 둡니다.
- [Claude Code model configuration](https://code.claude.com/docs/en/model-config): 역할별 모델 alias와 추론 강도를 명시합니다.
