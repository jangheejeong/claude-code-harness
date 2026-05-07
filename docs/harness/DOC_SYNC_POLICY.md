# Doc Sync Policy

Goal: docs never lie. If code says X and docs say Y, the next reader (or agent) must not be misled.

## Triggers for doc updates

| Change | Required doc update |
|---|---|
| Public API added / removed / renamed | README + ADR |
| New env var | README "Run" section |
| New CLI subcommand | README + `--help` snippet in README |
| New external dependency | README + ADR + CHANGELOG |
| Routing / endpoint changes | routing-map.md (if exists) |
| Architectural pattern shift | ADR + top-level CLAUDE.md if cross-project |

## Cadence

- Docs sync runs as part of `/release` (documenter subagent), per Phase.
- Standalone doc sync without code changes: out of harness scope; just edit directly.

## Hands-off zones (no automated rewrite)

- HAND_OFF*.md older than 30 days — let the original author archive.
- Whitepapers / pitch decks under `docs/`.
- Anything explicitly marked `<!-- preserve -->`.
