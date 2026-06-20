# Principles

These are the few rules a capable model won't naturally follow. Everything else: use your judgment. Adapt the project-specific parts to your stack.

## Immutability
Create new objects, never mutate. Return a new copy with the changes.

## Pipeline
A 5-agent team via the Agent Teams feature — pass any `team_name` string in the `Agent()` call (there is no separate `TeamCreate` step; it was removed in Claude Code v2.1.178, which creates one implicit team per session). Planner → Designer → Architect → Developer → Reviewer. The Developer writes code; the Reviewer verifies it. An Iteration Contract precedes coding. Dispatch each wave via `Agent({team_name, …})` + a full SendMessage brief; track waves on `{{BACKLOG_PATH}}`. NEVER use the harness TaskCreate/TaskList/TaskUpdate store — it is banned (ID collisions; the session dir and team dir never sync). SendMessage is the only dispatch + status + hand-off channel.

The full pipeline is REQUIRED for any fix that is site-wide (≥3 surfaces share the affected code), introduces a new component/token, changes a11y semantics or foundational structure, or needs cross-browser verification — even if the diff is tiny. Direct-dev (no pipeline) is allowed ONLY for a truly mechanical single-file one-line change with no new component/token/a11y. When in doubt, use the pipeline.

## Commit
Conventional format (`feat`/`fix`/`refactor`/`docs`/`test`/`chore`: description). No `Co-Authored-By`. No `.claude/` in git.

## Quality
TDD — write the test first. Edge tests are mandatory. If the project has an explicit coverage gate, respect it; otherwise ship with edge tests and don't chase an arbitrary %. A code-reviewer APPROVED verdict is required before shipping.

## Verification (cross-audit; trust no one)
Trust no verdict on its face — not a prior session's, not the user's premise, not your OWN pipeline/audit/reviewer agents. Independently re-verify every consequential claim against the LIVE artifact + logs, using tools (curl the live data, drive the live page / read its computed output, `git`/`gh`, read the source), BEFORE acting. A verdict never adversarially checked is UNVERIFIED; one that contradicts live data or user intent is REFUTED. Every pipeline agent must do this too — cite the live evidence, never an upstream assertion.

- **Web-verify external facts:** for any EXTERNAL fact or third-party datum (release dates, API status codes, library/tool behavior, an unfamiliar error), prefer a web search against the OFFICIAL source over trusting internal data or training memory. Cross-check even your own data against the official source when the check is cheap.

## Simplicity & surgical scope
Write the minimum code that solves THE problem; touch only what the request needs.
- No speculative features / abstractions / config / "flexibility" that wasn't asked for; no error-handling for impossible states. If 200 lines could be 50, rewrite. Self-check: "would a senior engineer call this overcomplicated?"
- Surgical edits: do NOT "improve"/refactor/reformat adjacent code that isn't broken; match the surrounding style even if you'd do it differently. Remove ONLY the imports/vars/functions YOUR change orphaned; pre-existing dead code → flag it for a follow-up, do NOT delete it in this PR. Every changed line should trace to the wave's stated scope.
- CAVEAT: "simplicity" applies to the CODE a wave ships — NOT to the process. The pipeline, the gates, premise-verify, RED→GREEN, and post-deploy DoD are heavyweight by design; do not "simplify" them away.

## Engineering
- **Fix bugs at the SOURCE layer:** trace to where the wrong value originates and fix it THERE — never ship an output-layer clamp/filter that masks wrong upstream data.
- **Hardcoded constants:** when fixing a hardcoded constant (colors/enums/canonical lists/regex), grep the WHOLE repo for parallel copies and fix/consolidate ALL of them before declaring done — an un-grepped duplicate is a regression timer.
- **Background-loop timers:** call `.unref?.()` on every `setTimeout`/`setInterval` handle in long-lived modules so they don't block test exit / clean shutdown.
