# REQUIREMENTS — <subproject>

> 이 파일은 `/setup` 스킬이 신규 서브프로젝트에 떨어뜨리는 시작점입니다.
> 한 번 채워두면 이후 모든 `/plan`, `/work`, `/review` 가 이 파일을 입력으로 사용합니다.

## 1. Identity

- **Name**: 
- **Owner**: 
- **Purpose (1줄)**: 
- **Status**: planning | active | maintenance | sunset

## 2. Stack

- **Language / runtime**: e.g. Python 3.11
- **Framework**: e.g. FastAPI, Airflow 2.x
- **Dependency manager**: `uv` | `pip` | `poetry` | `pnpm` | `npm`
- **Lockfile**: `uv.lock` | `poetry.lock` | …
- **Lint / type**: `ruff`, `mypy --strict?`, `tsc`
- **Test runner**: `pytest`, `vitest`, …
- **Build / deploy**: 

## 3. Run / Test commands (canonical)

```bash
# Local dev
<run command>

# Tests
<test command>

# Lint
<lint command>
```

## 4. External dependencies

- Required env vars: …
- 3rd-party APIs: …
- Internal services: …

## 5. Conventions to enforce in this project

- Logger: …
- Error class: …
- Test layout: mirror `apps/` / `core/` under `tests/`
- Commit message format: …
- PR title format: …

## 6. Non-goals

- 

## 7. Quality bar

- Min coverage on changed lines: 
- Required reviewers: 
- Definition of done: tests green, ruff clean, ADR if architectural change

## 8. Known landmines

- 
