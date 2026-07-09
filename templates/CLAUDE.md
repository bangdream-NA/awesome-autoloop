<!-- This is an awesome-autoloop template. The PROJECT_DIR / BACKLOG_PATH placeholders below are filled in automatically by /awesome-autoloop:install. -->
## Autoloop framework (managed by awesome-autoloop)

Your pipeline rules live in `{{PROJECT_DIR}}/.claude/rules/common/`
(`principles.md` + `pipeline-discipline.md`). Your task board is `{{BACKLOG_PATH}}`
— the single source of truth; dispatch + status + hand-off go through it, never the
harness task store.

### Hard rules

1. Use the 5-agent pipeline (Planner → Designer → Architect → Developer → Reviewer)
   via the Agent Teams feature — pass any `team_name` string in the `Agent()` call
   (there is no separate `TeamCreate` step; it was removed in Claude Code v2.1.178),
   not bare Agent/Task sub-agents.
2. NEVER write app source code directly as the lead — dispatch a developer agent.
3. Push to GitHub only when the user asks; never push `.claude/` or `Co-Authored-By`
   lines.
4. Save reviews as a per-verdict file `.claude/reviews/pr<N>-r<round>.md` (code) or
   `.claude/reviews/<wave>-planrev-r<N>.md` (plan) + one machine-authoritative line in
   `.claude/reviews/index.jsonl` (the merge/dispatch gates read the jsonl FIRST; the old
   `code-reviews.md`/`plan-reviews.md` monoliths are frozen legacy fallbacks). Ledgers are
   never a shared cross-session append target — an agent writes only its OWN project's docs.
5. The harness TaskCreate / TaskList / TaskUpdate store is BANNED — track every wave
   as a row in `{{BACKLOG_PATH}}`; dispatch + status + hand-off are all SendMessage.
6. CROSS-AUDIT; TRUST NO ONE — re-verify every consequential claim against the LIVE
   artifact (curl the live data, drive the live page, read the source, `git`/`gh`)
   before acting on it. A verdict never adversarially checked is UNVERIFIED.
7. A wave is NOT done at merge / CI-green / deploy-complete — verify the FINAL live,
   user-facing artifact first-hand.
<!-- aal:if WORKTREE_ROOT -->

### Worktree topology

Your wave worktrees live under `{{WORKTREE_ROOT}}`. ONE worktree + ONE branch per
wave; all stages share it. At every merge, immediately remove the worktree + delete
the branch (local + remote) — don't let them pile up.
<!-- aal:endif -->

The full discipline auto-loads from `{{PROJECT_DIR}}/.claude/rules/common/`. Adapt
these rules to your project's stack, deploy channels, and conventions.
