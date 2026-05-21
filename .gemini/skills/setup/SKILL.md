---
name: setup
description: Bootstrap the harness for a subproject that doesn't have one yet — drops in REQUIREMENTS.md, Plans.md skeleton, optional .claude/CLAUDE.md, and adds a row to the top-level project map. Use once per new subproject.
---

# /setup — Onboard a subproject

## Steps

1. Ask which subproject directory to set up.
2. If `<subproject>/REQUIREMENTS.md` does not exist, copy `docs/harness/REQUIREMENTS.template.md` to it and fill in:
   - project name, owner, summary
   - core stack (auto-detect from `pyproject.toml` / `package.json` / `requirements.txt`)
   - test command
   - run command
3. If `<subproject>/Plans.md` does not exist, create an empty one with a header note: "Drafted by /plan; do not edit by hand without bumping a Phase".
4. If the subproject has its own conventions worth pinning, drop a tiny `<subproject>/CLAUDE.md` referencing them. Otherwise skip.
5. Update top-level `CLAUDE.md` Project map table — add or update the subproject row.
6. Print a 5-line summary of what was created.

## Don't

- Don't overwrite an existing REQUIREMENTS.md or Plans.md. Show the user a diff and ask.
