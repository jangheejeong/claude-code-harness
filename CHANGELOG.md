# Changelog

## 2026-11-23

- agy-code-harness에서 `pr-walkthrough`, `frontend-design` 스킬을 가져왔습니다. PR 안내서는 대화에 Markdown으로 돌려주고, GitHub 댓글은 초안만 만듭니다.
- coder와 reviewer에 단일 추상화 수준·내려가기 규칙 지침을 추가했습니다.

## 2026-09-19

- 역할별 모델과 추론 강도를 Opus·Sonnet·Haiku 특성에 맞게 조정했습니다.
- 에이전트와 스킬 프롬프트를 줄이고 tester와 documenter를 선택 사항으로 바꿨습니다.
- reviewer의 네 관점과 orchestrator의 최대 3회 수정·재리뷰 계약을 명확히 했습니다.
- Stop 훅 루프, 외부 phase runner, 재시도 상태 파일, 에이전트 알림, 자동 lint 훅을 제거했습니다.
- 파괴적 명령과 비밀 파일 쓰기를 막는 두 안전 훅만 유지했습니다.
- 확인된 과거 복제본만 백업·정리하는 보수적 설치기와 회귀 테스트를 추가했습니다.
