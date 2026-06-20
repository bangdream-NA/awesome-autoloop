---
name: spawn-team
description: Spawn and run a 5-agent pipeline team (planner → plan-reviewer → architect → [designer] → developer → code-reviewer) via the Agent Teams feature. Tracks waves on BACKLOG.md (the harness task store is BANNED), dispatches via SendMessage briefs, and shuts down done agents. Includes the gate-driven autoloop + anti-stall protocol.
---

# Spawn Agent Team
Use the Agent Teams feature to spawn agents — pass any `team_name` string in the `Agent()` call (there is no separate `TeamCreate` step; TeamCreate was removed in Claude Code v2.1.178, which creates one implicit team per session).
DO NOT use sub-agents or Task agents.

1. Register each wave as a row in the project `BACKLOG.md` (NOT the harness task store — it is BANNED)
2. Dispatch via `Agent({team_name, name, subagent_type})` with the full spec in the SendMessage brief; each agent works in its own worktree
3. Before cleanup, verify all branches are merged to main

## 5-agent pipeline roles

- `planner` — writes the plan doc, enters plan mode + ExitPlanMode
- `plan-reviewer` — Mode A only: reviews the plan doc post-Planner, pre-Architect
- `architect` — locks the file map + verbatim code blocks
- `uiux-designer` — locks JSX / Composable templates if there's a UI surface
- `developer` — implements per the architect spec
- `code-reviewer` — Mode B only: post-Dev, pre-merge PR review (F-gates, re-probe, severity-tag)

Pipeline sequence: planner → plan-reviewer → architect → [designer if UI] → developer → code-reviewer.

## Dispatch = Agent + SendMessage brief; track on BACKLOG.md (NO harness task store)

**The harness TaskCreate / TaskList / TaskUpdate store is BANNED.** It is unusable: the session dir vs team dir never sync, IDs collide → it silently desyncs the lead from teammates, and the "complete all open tasks" coordinator poller auto-routes queued tasks to idle agents = pure churn. Use NONE of it.

Rules:
- **Dispatch = `Agent({team_name, name, subagent_type, prompt})`** with the FULL spec in the prompt/SendMessage. There is no separate bookkeeping call — the Agent spawn IS the start of work.
- **Track every wave as a row in the project `BACKLOG.md`** (`<project>/.claude/BACKLOG.md`). The lead owns the Status field; agents append-only to their own `— log:` line via Edit. Reconcile after every merge/audit.
- **Status + hand-off = SendMessage**, never a task-status field. A teammate's "done" = its SendMessage delivery to team-lead.
- **End-of-turn status report** lists each in-flight wave → its teammate/session + its BACKLOG row, read from your own roster — NOT a TaskList.
- **FUTURE/QUEUED work** = a pending row in BACKLOG.md (no agent spawned yet). With no task store there is no poller to auto-route it — just shut idle done-agents and keep the queue visible in the wind-down summary.

## Shut down done agents (DEFAULT)

The moment a teammate's deliverable is ACCEPTED, the lead shuts it down. Do NOT leave done agents idle.
- "Accepted" = PR merged · review APPROVED + merged · the agent's assigned task is complete with no follow-up assigned.
- Shutdown call: `SendMessage({ to: <agent>, type: "shutdown_request" })`.
- Cadence: per-wave as each agent finishes; full sweep at session wind-down.
- Do NOT `TeamDelete` just to shut agents down — use per-agent `shutdown_request`.
- Exception: keep alive only if the agent has a queued next task (e.g. dev → its own reviewer round) or the user says keep it.

## Post-wave cleanup (DEFAULT)

The moment a wave's PR merges, the lead does TWO cleanup steps (don't let them pile up):

1. **Branch cleanup — local + remote + worktree.**
   - Merge with `gh pr merge --squash --delete-branch` (deletes remote AND local tracking branch). The `enforce-delete-branch-on-merge.sh` PreToolUse hook DENIES `gh pr merge` without `--delete-branch`.
   - Also `git branch -D <branch>` if a local copy lingers, and `git worktree remove` + verify the dir is gone (on Windows, long-path node_modules can resist deletion).
   - **Why even with --delete-branch:** squash-merge gives a NEW sha, so `git branch --merged main` can't detect squash-merged branches → they never auto-clean and pile up. Periodic sweep when the pile is large: `gh pr list --state merged --json headRefName` → delete any local/remote branch in that set EXCEPT a protect list (main + in-flight wave branches + worktree-checked-out branches + open-PR headRefNames). `git remote prune origin` after.

2. **Doc sync — explicit decision EVERY wave.** When a wave's PR merges, the lead MUST make AND record a doc-sync decision — never silently skip it:
   - Changed any documented behavior / architecture / API surface / data contract / runbook step → update the affected living docs in `docs/` and push. A bugfix counts if it changes what a doc *says is true*.
   - Purely-internal (CSS-only / test-only / refactor with no behavior or contract change) → may skip, but the lead MUST state it in the wave wind-down: `doc-sync: SKIP — purely-internal (<one-line reason>)`.
   - Either way the decision is VISIBLE in the end-of-wave report.

**Never ask for permission — act autonomously** once the ship gates pass, including PR merge and (if your project has one) production deploy. Default to autoloop: drive the sequence without pausing to ask "continue or stop?"; surface only the hard-stop conditions below.

## What "act autonomously" means (gate-driven autoloop, not blind)

Autonomous actions include: create/update branches · commit and push · open PR · respond to reviewer feedback · rebase on main · merge approved PRs · deploy to production · run post-deploy verification.

## Definition of Done = the live, user-facing artifact verified

"Done" requires verifying the FINAL artifact, never an intermediate. `merged` / `CI green` / `deployed` are necessary, NOT sufficient.
- UI/web wave → a real-browser walk of the LIVE page (navigate the user's path, click the changed controls, read each landing page — URL + heading + status + layout). Not curl-only: curl can't measure layout, follow client-side navigation, or dodge an anti-bot UA false-404.
- Data-pipeline / deploy wave → a post-deploy REAL run + verify the downstream artifact actually changed (CI can't exercise live creds/services).
- Document your project's exact deploy channels + post-deploy verify path in your project's `.claude/` (this skill is stack-agnostic; the concrete deploy commands are yours to fill in).

## Hard stop — surface to the user, do NOT proceed

A blind autoloop will, given enough runs, ship a bad merge or bad deploy. Stop and surface to the user if:
- CI required checks are failing or missing
- the code-reviewer verdict is NEEDS FIXES (dispatch dev R2; do not merge)
- the working tree contains unrelated user changes
- a command would expose / print secrets
- a command would delete production data
- an action would expand scope beyond the locked plan
- the deploy target is ambiguous
- legal / license / data-publication policy changes

When none of those apply, default to acting — do not ask for permission. Layer your project's own hard gates on top of this contract.

## TEAM_ANTI_STALL protocol

Agent Teams is experimental. Common stall causes: a teammate stopping silently on error, the lead messaging dead handles after /resume, Stop/Idle hooks blocking, permission prompts bubbling to the lead, oversized teams/tasks. Apply these constraints:

**Team + task size**
- At most 3-5 active teammates working in parallel
- Each teammate gets a named role + owned files/dirs + a single clear deliverable
- Tasks small enough that progress is reportable within ~15 minutes

**Teammate contract (include in the dispatch prompt)**
> If blocked after 2 attempts, send a BLOCKED report with: the last command/tool invoked, the exact error, files touched so far, and the next recommended action. Then stop and wait for the lead. Do NOT silently retry.

**Lead discipline**
- The lead does NOT implement code while teammates are running (unless explicitly instructed)
- The lead checks teammate progress periodically
- A stale teammate (silent 20+ minutes) → the lead nudges ONCE with SendMessage
- Still stale after the nudge → spawn a replacement carrying the stale teammate's task + worktree + known context; shut down the old teammate when feasible

**Resume / context-reset hygiene**
- After `/resume` or `/rewind`, do NOT trust old teammate handles (in-process teammates don't survive resume)
- Spawn fresh teammates with new `Agent({team_name, …})` calls (there is no separate `TeamCreate` step — TeamCreate was removed in Claude Code v2.1.178); do not SendMessage to teammates from a previous session

## Stop / SubagentStop / Idle hook discipline

- Stop hooks MUST check `stop_hook_active` and exit clean when true (Claude Code force-stops after 8 consecutive blocks)
- Idle hooks should LOG, not block (a long block on Idle deadlocks team coordination)
- Hook timeouts must be set (≤5000ms typical) so a hung hook can't stall the whole loop
- Command hooks run with the user's system permissions — limit + test before adding
