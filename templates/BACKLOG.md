# Task Backlog (SINGLE SOURCE OF TRUTH)

> Absolute path: `{{BACKLOG_PATH}}`. This board is the ONLY task tracker — the harness
> task store is BANNED. Dispatch + status + hand-off all flow through SendMessage; the
> board records the durable state.
>
> Card format: `### [STATUS] {wave-name} · {priority}` with four bare-prefix fields
> `- aliases:` / `- problem:` / `- fix:` / `- log:` (timestamped log).
> `[STATUS]` ∈ QUEUED / IN-DEV / REVIEW / BLOCKED / USER-GATED. Move a completed card to
> `BACKLOG-archive.md`. Keep `.claude/` gitignored.

## ACTIVE

<!-- Add wave cards here. Example:

### [QUEUED] R-example-wave · P2 · one-line summary of what this wave does
- aliases: R-example, example-wave
- problem: what's wrong / what's missing (verify the premise LIVE before dispatching)
- fix: the planned fix + acceptance criteria
- log:
  - YYYY-MM-DD · REGISTERED · team-lead · proof=<first-hand evidence> · next=<next action>

-->

## QUEUED

<!-- Pending waves with no agent spawned yet. -->
