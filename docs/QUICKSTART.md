# Quickstart — your first wave, end to end

This walks one unit of work (a "wave") from an empty idea to a merged PR, through the gates. It
assumes the plugin is installed (see the [README](../README.md#install)). Read the prerequisites
first — they are the two things that, if missing, make the whole pipeline silently dead-end.

## Prerequisites (do these BEFORE step 1)

1. **Agent Teams must be enabled.** The 5-agent pipeline runs on Claude Code's Agent Teams feature.
   The installer sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in your `settings.json` env on
   `--apply` (`skills/install/install.mjs`). If you skipped the installer, set it by hand — without
   it teammate dispatch fails and the `block-bare-agent` gate dead-ends every dispatch. You pass any
   `team_name` string in the `Agent()` call — there is no separate `TeamCreate` step (TeamCreate was
   removed in Claude Code v2.1.178).

2. **Auto / autonomous mode posture.** The pipeline dispatches teammates that run tool calls
   (commit, push, dispatch) on their own. Run it in a permission posture where those proceed, or you
   will hand-approve every step. This is the same "two halves" the README describes
   ([activation model](../README.md#when-the-gates-enforce-activation-model)): the plugin mounts its
   hooks globally, but the gates ENFORCE only inside an autoloop-marked project.

3. **The gates fire only in an autoloop project.** A project is autoloop-managed when its `.claude/`
   carries the `.autoloop` marker (the installer drops it on `--apply`) — or a `BACKLOG.md` /
   `code-reviews.md` / the managed `CLAUDE.md` block. Outside such a project every gate self-skips.
   So run this in the repo where you installed (or run `/awesome-autoloop:install` there first).

> **Which gates are active — `AAL_GATES`.** The installer writes a colon-joined `AAL_GATES` list
> into your `settings.json` env (the five groups: `commit-hygiene`, `pipeline-roles`, `merge-gates`,
> `ledger-hygiene`, `dod-walk`). Each mounted hook self-skips unless its group is in `AAL_GATES`, so
> if you narrowed `--gates` at install, only those gates fire below. The `merge-gates` group needs
> `gh` + a GitHub-PR workflow — deselect it if you don't use GitHub PRs.
>
> **`AAL_STALLCHECK`.** For an autonomous run, the first pipeline dispatch is blocked until you
> create a recurring stall-check cron (`CronCreate(STALL-CHECK)`) — it covers the idle waits that
> turn-end Stop hooks can't see. For INTERACTIVE use, set `AAL_STALLCHECK=off` in your
> `settings.json` env to skip that one gate (it does not disable the rest of `pipeline-roles`).

## The wave, step by step

A wave moves through six roles. Each is a real agent under `agents/`: `planner`, `plan-reviewer`,
`uiux-designer` (UI waves only), `architect`, `developer`, `code-reviewer`. You drive them as a team
lead — the [`spawn-team`](../skills/spawn-team/SKILL.md) skill is the protocol for spinning up the
team, dispatching via SendMessage briefs, and shutting down done agents.

### 1. Adapt the framework to your project

The copied templates (`CLAUDE.md` framework, `rules/common/*`, the `BACKLOG.md` template) are
parameterized to a generic project. Before your first wave, tune them to your stack — the
[`adapt-config`](../skills/adapt-config/SKILL.md) skill reads your project's conventions first, then
matches commands/regexes/permissions to your actual stack (it deliberately does NOT bring in another
project's patterns).

### 2. Write the first plan spec

Create `docs/product-specs/R-<wave>-plan.md` describing WHAT and WHY (acceptance criteria, scope,
edge cases, open questions). This is the planner's input. `enforce-planner-first` will deny a
`developer` dispatch when no spec exists under `docs/product-specs/` — the spec comes first by
design.

### 3. Dispatch the planner → plan-reviewer (Mode A)

Spin up the team (`spawn-team`) and dispatch the `planner` to expand your spec into a full plan. Then
dispatch the `plan-reviewer` for a **Mode-A** plan-doc review. Its verdict lands as an APPROVED block
in `.claude/plan-reviews.md` (the seed `templates/plan-reviews.md` documents the block format). The
architect dispatch gate (`backlog-sop-validate`, pre-dispatch) reads that file — it requires an
APPROVED Mode-A verdict whose heading wave-token matches your wave BEFORE it lets an architect run. A
self-written `PLAN_APPROVED` line on the board does NOT satisfy it.

### 4. Dispatch the architect

With the plan APPROVED, dispatch the `architect` to lock the implementation spec
(`docs/product-specs/R-<wave>-architecture.md`): verbatim locks, a file map, edge-case coverage, and
any premise inversions where the planner guessed wrong. This is the developer's contract.

### 5. Developer — iteration contract, then code

Dispatch the `developer`. It sends an **Iteration Contract** FIRST (what it will build, done-when
criteria, files it will touch, expected deviations), then implements the locks file-by-file, runs the
stack gates incrementally, writes edge tests, and self-evaluates before reporting. It commits in
conventional format with no `Co-Authored-By` trailer (`block-coauthor-commit` +
`enforce-conventional-commit` enforce both), and never stages `.claude/`
(`block-claude-dir-commit`).

### 6. Code review — Mode B

When the PR is open with CI green, dispatch a FRESH `code-reviewer` for a **Mode-B** PR review. Its
APPROVED verdict (with a `Reviewer-type: code-reviewer` attestation) lands in
`.claude/code-reviews.md` + `.claude/reviews/index.jsonl`. The merge gates require it:
`require-review-before-ship` + `require-codereviewer-verdict-before-merge` block a merge without a
fresh code-reviewer's APPROVED verdict bound to the current HEAD SHA.

### 7. Merge through the gates

`gh pr merge <N> --delete-branch` is gated: the PR must be open/non-draft, mergeable, CI green, the
review APPROVED at HEAD, the base not stale (`block-pr-merge-stale-base`), and `--delete-branch`
present (`enforce-delete-branch-on-merge` — squash-merges hide branches, so they pile up without it).

### 8. Definition of Done — the post-merge walk

A wave is NOT done at merge. The `dod-walk` group blocks turn-end until a merged PR has a
`.claude/walks/*.md` artifact naming it. Verify the LIVE artifact first-hand — a real-browser walk
for a web page, a built-binary run for a CLI, an API exercise for a library — and record it. For a
non-UI PR, an explicit `PR #<N>: non-UI (<reason>), walk N/A — DoD = <proof>` line satisfies the
gate. The seed `templates/walks/TEMPLATE.md` shows both forms.

## Optional helpers

- [`backlog-reconcile`](../skills/backlog-reconcile/SKILL.md) — read-only drift report cross-checking
  your `BACKLOG.md` against `gh pr list`, so "the last session said it was all done" can be VERIFIED.
  Run it at session start or before a merge batch.
- [`rotate`](../skills/rotate/SKILL.md) — hand a long lead session to a fresh one via a durable
  handoff, when context grows or the session degrades.
- **Runbooks** — for a server / deploy / data-pipeline operation, copy `templates/runbooks/TEMPLATE.md`
  to `docs/runbooks/<op>.md` and document the procedure + its known footguns. (It pairs with the
  `require-runbook-before-server-op` example gate if you mount it.)

## When a gate blocks you

The gates fail-closed on the dangerous paths by design. The "when you see THIS deny → do THIS"
decoder lives in [docs/OPERATING.md](OPERATING.md); the README's
[Known footguns](../README.md#known-footguns--living-with-the-gates) covers the three that come up
most (whole-command-deny, dispatch-before-spec, fail-open-vs-closed asymmetry).
