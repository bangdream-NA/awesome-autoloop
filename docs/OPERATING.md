# Operating the gates — a decoder for living with awesome-autoloop

The gates deny some of your tool calls on purpose. This is the field guide: per gate-group, what
it enforces, what a deny MEANS, and how to respond — so you fix the cause instead of fighting the
gate. The short version of the footguns is in the [README](../README.md#known-footguns--living-with-the-gates);
this is the "when you see THIS deny → do THIS" decoder.

First principle: **the gates only enforce inside an autoloop-managed project** (one whose `.claude/`
carries `.autoloop`, `BACKLOG.md`, `code-reviews.md`, or the `<!-- BEGIN awesome-autoloop -->`
block in `CLAUDE.md`). In any other repo every hook self-skips. If a gate fired somewhere you didn't
expect, that repo carries one of those markers — opt out with `AAL_GATES=` (empty) in its
`settings.json` env, or delete the marker.

> **Ledger model decoder (per-session / per-verdict / per-project).** The gates read a per-project,
> per-session, per-verdict ledger layout — not one shared monolith:
> - **Op-logs are per-session**: each session appends to its OWN `.claude/autoloop-log-<date>-<sid8>.md`
>   (`sid8` = first 8 alphanumeric chars of the session id). The merge gate greps ALL of them (grep-ALL)
>   for the `#<N>` row; `oplog-turn-reminder` rotates ONLY your own `sid8` ledger (two-class), never
>   another session's.
> - **Reviews are per-verdict files**: plan-review → `.claude/reviews/<wave>-planrev-r<N>.md`; code-review
>   → `.claude/reviews/pr<N>-r<round>.md`; plus one machine-authoritative line per verdict in the
>   per-project `.claude/reviews/index.jsonl`.
> - **jsonl-first for BOTH plan-verdict gates**: the architect gate AND the developer gate read
>   `reviews/index.jsonl` FIRST; the `plan-reviews.md` / `code-reviews.md` monoliths are frozen legacy
>   fallbacks only.
> - **Newline-terminate guard**: every `reviews/index.jsonl` append uses `printf '%s\n'` + a last-line
>   parse-check — a bare `cat file >>` can fuse two JSON objects onto one line and blind every gate.
> - **Project isolation**: an agent writes ONLY inside its OWN project's `.claude/` (MAIN resolved via
>   `git --git-common-dir` from a worktree), never a sibling's or the home `.claude/`.

---

## By gate group

### commit-hygiene — blocks a bad commit (fail-closed)

| When you see | It means | Do this |
|---|---|---|
| `git commit` denied: Co-Authored-By trailer | your commit message carries a `Co-Authored-By:` line | remove the trailer; the framework keeps authorship out of trailers |
| `git commit` denied: not conventional | the message isn't `type(scope): description` (feat/fix/refactor/docs/test/chore/perf/ci/build/style) | rewrite the subject line in conventional form |
| `git commit`/`push` denied: `.claude/` staged | you staged your private `.claude/` config | `git restore --staged .claude` (it belongs in `.gitignore`, not in the repo) |
| Bash denied: compound commit + push | you joined `git add`/`git commit` with `git push`/`gh pr merge` in ONE command (via `&&`/`;`/`\|`) — if the push/merge is denied, the whole command fails and the commit silently doesn't run | split it: run `git add`/`git commit` as their own Bash call, then `git push`/`gh pr merge` as a separate atomic call (this gate fails OPEN — a footgun-preventer, not a security gate) |
| Bash denied: pnpm install in main checkout | you ran `pnpm install/add/up` against the shared main checkout (an aborted install there breaks the whole session) | install inside an isolated worktree instead — OR append `# ALLOW_MAIN_INSTALL` for a deliberate lead recovery. This gate only fires when `AAL_MAIN_REPO` is set |
| Bash denied: cleaned/canonical data staged | your `git commit`/`push` includes private data-pipeline assets (DB dumps, snapshots, exported shards, `*.parquet`/`*.ndjson`/`*.sql.gz`) | unstage the data file (`git restore --staged <path>`), or for a push rewrite history to drop it. Extend the pattern set for your repo via `AAL_DATA_GLOBS` |

These fail CLOSED on a missing dependency (no node → they DENY): a commit slipping past a
broken gate is the worse outcome — EXCEPT `block-compound-commit-push`, which fails OPEN (a
footgun-preventer must not block a legitimate commit when node is absent).

### pipeline-roles — enforces the 5-agent pipeline order (deny for role gates, warn for reminders)

| When you see | It means | Do this |
|---|---|---|
| Agent spawn denied: bare Agent / no `team_name` | you spawned an Agent without a `team_name` | pass any `team_name` string in the `Agent()` call (there is no separate `TeamCreate` step — TeamCreate was removed in Claude Code v2.1.178) |
| `developer` spawn denied: no recent spec | you're dispatching a developer for feature work with no spec under `docs/product-specs/` | write the spec first (planner → architect), OR use a `fix`/`bug` team name for a genuine bug-fix (those skip the gate) |
| spawn denied: roster at cap | the live teammate count hit `AAL_ROSTER_CAP` (default 16) | shut down a done teammate before spawning a new one (the cap counts ONLY the spawn's target team — a full team in another live session never blocks you) |
| spawn denied: Mode-B not code-reviewer | a PR review was dispatched to a non-`code-reviewer` role | dispatch the review to a fresh `code-reviewer` |
| BACKLOG.md write denied: non-whitelisted `### [STATUS]` | you wrote a `[DONE]`/✅/MERGED card (or an ad-hoc status) onto the active board | move the done card to `BACKLOG-archive.md`; keep an unverified DoD at `[REVIEW]` or an external dep at `[BLOCKED]` — status must be one of QUEUED/IN-DEV/REVIEW/BLOCKED/USER-GATED |
| BACKLOG.md write denied: new card missing skeleton | a NEW card lacks a whitelisted status or an `aliases:`/`problem:`/`fix:` line | add the missing skeleton fields (content may be a `<TODO>` placeholder); editing an existing card is never blocked |
| dispatch denied: SOP pre-dispatch (no plan-review / no ARCH_APPROVED) | you dispatched an `architect` with no APPROVED plan-review verdict (the gate reads `.claude/reviews/index.jsonl` first, `plan-reviews.md` legacy fallback), or a `developer` with no `ARCH_APPROVED` proof on the card | run the prior stage first — plan-review (Mode A) before the architect, the architect before the developer — then record the verdict / `ARCH_APPROVED` line on the card |
| dispatch denied: SOP pre-review (no real PR# + SHA) | you dispatched a `code-reviewer` (Mode B) without a real PR number and a pinned HEAD SHA in the brief (or `DEV_DELIVERED` + `PR_OPENED` on the card) | push + open the PR, then pin the reviewed commit in the dispatch (`#<N>` + `@<sha>`, re-pin via `gh pr view <N> --json headRefOid`) |
| dispatch denied: code-reviewer for a plan review | you dispatched `code-reviewer` for a Mode-A plan-doc review (its prompt named the plan / Mode A / pre-architect) | re-dispatch with `subagent_type: plan-reviewer` — Mode-A plan review is the dedicated plan-reviewer's job; `code-reviewer` is Mode B (post-Dev PR) only. A genuine Mode-B review that mentions "the plan" → add an explicit `Mode B` marker to the prompt |
| dispatch denied: no stall-check cron | you dispatched your FIRST pipeline-role agent this session with no `CronCreate(STALL-CHECK)` in the transcript | an AUTONOMOUS-run gate: create the stall-check cron (the deny text carries the exact `CronCreate({cron:'7,37 * * * *', recurring:true, ...})`) then re-dispatch — OR if you're driving the pipeline interactively, set `AAL_STALLCHECK=off` in your settings.json env to skip it (does NOT disable the rest of pipeline-roles) |
| SendMessage denied: lead plan-approval | the team-lead tried to send a plan-approval-response message directly | dispatch `plan-reviewer` Mode A first, then forward ITS verdict (APPROVED / NEEDS-REVISION + quoted feedback) to the planner — don't approve a plan on your own judgment |
| edit denied: lead editing app source | the team-lead tried to Write/Edit a file under a source tree (`src/`, `app/`, `apps/`, `lib/`, `packages/`, …) directly | dispatch a developer agent to make the change. Harness files (`.claude/`, `docs/`, `CLAUDE.md`, hooks, rules) are always allowed; if the gate is over-matching your repo's layout, set `AAL_APP_SRC_GLOBS` to a tighter regex |
| dispatch denied: developer with no premise verdict | you dispatched a `developer` for a wave with no logged plan-review verdict (the dev gate reads `.claude/reviews/index.jsonl` first, `.claude/plan-reviews.md` legacy fallback) | dispatch the `plan-reviewer` (Mode A) for this wave first so its premise is LIVE-verified, then re-dispatch the developer — OR for a genuinely trivial no-premise change, append `# PREMISE-VERIFIED: <the live evidence you gathered>` to the dispatch prompt to override |
| Bash denied: push/merge from a worktree | you ran `git push` or a `gh pr` mutation from a worktree cwd (you = a pipeline agent, not the lead) | commit locally, then SendMessage the team-lead (branch, SHA, file list, F-gate results) and STOP — the lead rebases + pushes + opens the PR from the main checkout. If you ARE the lead, `cd` into the main checkout first |
| Bash denied: second worktree for a wave | you ran `git worktree add` for a wave that already has a worktree | reuse the wave's existing worktree (ONE per wave, all stages share it). A read-only reviewer needing isolation can use `--detach`. This gate only fires when `AAL_WORKTREE_ROOT` is set |
| Stop-time nags (stale agents, roster tripwire, prune-inboxes, backlog drift) | warn-only reminders — `backlog-drift-check` flags an active card whose alias matches a merged PR but isn't marked done; `backlog-drift-guard` warns on a non-whitelisted status header / lingering `[DONE]` / legacy `状态:` line; the roster tripwire warns when a team exceeds the cap — the roster warning now cautions that it scans ALL teams, so if the over-cap team isn't yours, do nothing | act on the nudge or ignore it; they never block. For a drift warn: verify the named card live, then mark it done + move it to `BACKLOG-archive.md` (or fix its status if a deploy/verify is still outstanding) |
| SessionStart nudge: "installed but not yet tailored" / "self-improve last ran >24h ago" | advisory `preflight` nudges (NEVER deny) — `.claude/.pending-profile` is present (the installer dropped it, you haven't profiled/dismissed), or the durable `self-improve-last-run` marker is >24h old | run `/project-profiler` to tailor the setup, or `/self-improve` to mine `.gate-denials` + struggle-log — both PROPOSE only. To stop the profiler nudge without profiling, delete `.claude/.pending-profile`; the cadence nudge resets each time `/self-improve` runs |

> **Stop tier = one `stop-dispatcher` mount.** All the Stop checks above (and the ledger-hygiene / dod-walk Stop checks) run in a single process that merges every block reason AND every warn into one turn-end **block** message (warns folded into the block reason; no separate `systemMessage` key) — the meanings in this decoder are unchanged; only the delivery is consolidated. A crashing check is isolated from the rest, and a node-less box fails OPEN (no turn-end block).

> **Known limitation — `backlog-sop-validate` (pre-review) PR-number matching.** The pre-review gate's
> PR↔card consistency check matches a bare `#<N>` against each card's text, so a card whose prose
> references an unrelated number (e.g. "rule #13") can be mistaken for a card carrying PR #13, denying a
> legitimate reviewer dispatch as "inconsistent". Remedy: keep the real PR-number line on the card the PR
> belongs to, and avoid bare `#<N>` prose on other cards. (Tracked for a future tightened-matcher follow-up.)

> Two pipeline-roles hooks (`roster-tripwire`, `block-spawn-over-roster-cap`) **delete** harness team
> dirs under `~/.claude/teams/` that are untouched for >2 days (a `config.json` + mtime >2d). If you
> keep long-lived team dirs there, be aware of the prune.

> **Learning-loop routing.** Two destinations, one test: 「伤到我的执行了?」→ struggle-log；「是要去修/建的东西?」→ BACKLOG card.
> The struggle-log is execution friction the agent hit; a discovered bug / improvement is a board work-item.
> `self-improve` applies this test when mining and PROPOSES re-routing any mis-filed work-item out of the log
> onto a card.

> **`.gate-denials` — the structured denial ledger.** Three deny gates (`block-bare-agent`,
> `enforce-planner-first`, `validate-agent-type`) append ONE pipe-delimited line per deny —
> `<ISO-timestamp> | <hook> | <pattern-id> | <short-reason>` — to `<project>/.claude/.gate-denials`
> (falls back to `~/.claude/.gate-denials`; rotates to `.gate-denials.1` at ~240KB). It is the
> machine-readable tail `/self-improve` mines to surface a footgun that recurs ≥3× as a COUNT, not an
> anecdote. Read it directly when a gate keeps biting and you want the pattern, not the story.

### merge-gates — gates `git push` / `gh pr merge` on a green, reviewed PR (fail-closed)

| When you see | It means | Do this |
|---|---|---|
| push/merge denied: no APPROVED review | no APPROVED verdict bound to the current HEAD for this PR in `.claude/reviews/index.jsonl` (or the per-verdict `reviews/pr<N>-r<round>.md`); the `code-reviews.md` monolith is legacy fallback | get a code-reviewer APPROVED verdict at the current SHA, then retry |
| merge denied: PR not green / not mergeable | CI isn't green, the PR is draft, or it has conflicts | wait for CI / un-draft / resolve conflicts |
| merge denied: no `Reviewer-type: code-reviewer` | the review block lacks the fresh-reviewer attestation | ensure the reviewer wrote the `Reviewer-type: code-reviewer` line |
| merge denied: missing `--delete-branch` | you merged without `--delete-branch` | add `--delete-branch` (squash-merges otherwise pile up un-pruned) |
| merge denied: stale base | the PR branched before later merges to `origin/main`; a squash now could revert in-between work | `git fetch && git rebase origin/main`, push, then merge |
| merge denied: board not reconciled | the active board still lists a card whose PRIMARY alias matches an ALREADY-MERGED PR (merged but never archived) | archive the merged-but-unarchived prior card (append a `### ✅ name · DONE #N @sha` block to `BACKLOG-archive.md`, delete the card from the active board), then re-merge. Repo unresolvable / `gh` failure also denies (fail-closed) — fix the origin remote / `gh` auth |
| merge denied (fail-closed): cannot resolve which project | the command has no `cd <project-dir>`, so the gate can't tell WHICH project's board to reconcile | re-run as `cd <project> && gh pr merge <N>`. The gate resolves the project from the **last `cd`** in the command and never defaults to another project's board (R-13 cross-wire fix) |
| merge denied: no op-log row for #N | NO `.claude/autoloop-log-*.md` (searched across ALL of them, grep-ALL) carries a row citing this PR | add a `feature·problem·proof` row citing `#N` to any `autoloop-log-*.md` (own or legacy) FIRST, then re-merge. Write the explicit PR number (`gh pr merge <N>` — a bare `gh pr merge` is denied). No-ops if your project has no `autoloop-log-*.md` (the op-log convention is opt-in) |

These need `gh` + a GitHub-PR + reviewer-ledger workflow. If that's not your setup, deselect
`merge-gates` in the installer. They fail CLOSED on a missing dependency — EXCEPT the stale-base
gate, which fails OPEN on uncertainty (no `gh`, no PR number, fetch failure) so it never blocks a
legitimate merge it can't evaluate.

### ledger-hygiene — warn-only Stop nags (fail-open)

| When you see | It means | Do this |
|---|---|---|
| ledger-size warning | a session ledger nears the 256KB Read-tool ceiling | split it at line boundaries into `<name>-archive-NN.md` parts |
| worktree-count warning | worktrees under `AAL_WORKTREE_ROOT` exceed the cap | prune merged worktrees |
| Bash denied: truncating write to a ledger/archive | you ran `>` / `Out-File` / `Set-Content` onto an EXISTING `*-archive*.md` / ledger (`BACKLOG`/`plan-reviews`/`code-reviews`/`struggle-log`/`autoloop-log`) — `>` clears the file, losing its content | APPEND with `>>` (or use the Edit/Write tool — allowed), or to split write a `.tmp` then `mv` it to the next FREE `-archive-NN` slot. This gate fails OPEN (a footgun-preventer): node-absent or any uncertainty → it allows |

The two ledger-hygiene Stop checks are warn-only; the `block-truncate-existing-ledger` PreToolUse gate above is the one deny in this group (and it fails OPEN).

### dod-walk — post-merge "definition of done" (one Stop gate blocks, the rest warn)

| When you see | It means | Do this |
|---|---|---|
| turn-end blocked: unwalked merge | you merged a PR but there's no `.claude/walks/*.md` naming it | verify the live/final artifact and write a walk file mentioning `#N`, OR record `PR #N: non-UI, walk N/A — <reason>` |
| post-merge reminder / pre-merge reminder | warn-only nudges to walk a merged PR | walk the surface, or proceed (they don't block) |

"The walk" is whatever verifying the FINAL artifact means for your project: a real-browser walk for
a web app, running the built binary for a CLI, exercising the public API for a library. Your
project's `CLAUDE.md`/rules define it. The gate checks THAT a verification artifact exists, not HOW
you produced it. It fails OPEN on a missing node (a discipline nudge, not a security gate — blocking
every turn-end on a node-less box is worse than skipping the check).

---

## Footguns (the "this surprised me" cases)

1. **Whole-command-deny.** The PreToolUse/Bash gates grep the WHOLE command string, so a command
   that merely *mentions* `gh pr merge` or `git push` as literal text — a doc heredoc, an `echo` of
   an example, a test payload — is matched and the ENTIRE command is denied, even though nothing is
   merging/pushing.
   → **Do this:** write docs with your editor, not a Bash heredoc; pipe a test payload in from a
   file instead of inlining the literal phrase; keep a real merge/push its own atomic command.

2. **A `developer` spawn is denied before you've written a spec.** `enforce-planner-first` is
   enforcing pipeline order: a developer for feature work needs a recent spec under
   `docs/product-specs/`.
   → **Do this:** run the planner/architect first and land the spec, OR (for a genuine bug-fix) use
   a `fix`/`bug` team name — those skip the gate.

3. **Fail-open vs fail-closed is asymmetric, on purpose.** With node absent, the commit/merge deny
   gates fail CLOSED (they DENY — an unreviewed merge slipping through is the worse failure), but
   the dod-walk Stop gate fails OPEN (it ALLOWS — blocking every single turn-end on a node-less box
   is worse than skipping a nudge). The same missing-node condition denies a merge but waves through
   a turn-end.
   → **Do this:** install node (≥18) so every gate runs as designed; until then, expect deny gates
   to block hard and warn/DoD gates to no-op.
