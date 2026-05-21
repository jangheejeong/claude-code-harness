---
name: plan
description: Turn a fuzzy request into a phased Plans.md with vertical slicing and TDD-ready acceptance criteria. Use when the user says "let's plan", "/plan", or before any non-trivial work. Spawns the planner subagent and persists the output to <subproject>/Plans.md.
---

# /plan — Requirements to Phased Plan

This skill is the entry point of the harness. Code never starts here; only after the user approves the produced `Plans.md`.

## Steps

1. **Identify the subproject**. Ask which subproject if not stated. Show the Project map from top-level `CLAUDE.md` if the user is unsure.
2. **Locate inputs**. Read in this order, if present:
   - `<subproject>/REQUIREMENTS.md`
   - `<subproject>/HAND_OFF*.md`
   - `<subproject>/CLAUDE.md`
   - any linked Jira ticket via the `jira` MCP
3. **Spawn `@agent-explorer`** for a touchpoint map. Do this in parallel with reading docs.
4. **Spawn `@agent-planner`** with: the explorer report, the user's request, the docs from step 2. Remind the planner of the two hard constraints:
   - **Vertical slicing**: each phase = one feature end-to-end across all layers, not one layer at a time
   - **TDD-ready acceptance**: every acceptance bullet must be directly convertible into a failing test (specific status codes, response shapes, observable side effects)

   The planner's output must end with `PLAN READY — save to <path>/Plans.md`.
5. **Save the plan**. Use Write to persist to `<subproject>/Plans.md` (overwrite is OK; git tracks it). If file exists, append a new section dated today; do not delete history.
6. **Approval gate**. Print the path and ask the user to review and check off the Approval section. Do NOT proceed to `/work` until they confirm.

## Inputs from the user (ask if missing)

- target subproject
- user-facing summary of the goal
- explicit non-goals (if any)
- deadline / urgency (affects phase granularity)

## Outputs

- `<subproject>/Plans.md` (or appended section)
- one-paragraph chat summary with the path

## On user revision request

User likely revises the plan via natural language ("Phase 2 가 너무 크다, 둘로 쪼개줘"). Re-spawn `@agent-planner` with the original Plans.md + the user's feedback. Discourage direct manual edits of `Plans.md` since the planner won't be aware of changes it didn't write.
