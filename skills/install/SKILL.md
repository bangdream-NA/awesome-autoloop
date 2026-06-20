---
name: install
description: Interactive installer for the Awesome Autoloop framework templates. Asks a few questions (install scope, board path, worktree topology, gate groups, notification), then copies the editable templates (CLAUDE.md framework, rules/common/*, BACKLOG template) into your .claude/ — parameterized, never clobbering an existing CLAUDE.md, idempotent on re-run. Run it after installing the plugin.
---

# Awesome Autoloop installer

The plugin's hooks, agents, and skills mount automatically when the plugin is enabled — they run from the plugin and are NOT copied. This installer copies the **editable, user-owned templates** (the CLAUDE.md framework, `rules/common/principles.md` + `pipeline-discipline.md`, and a BACKLOG template) into your own `.claude/`, parameterized to your project. It never clobbers an existing CLAUDE.md, and it is idempotent and non-destructive — re-run it any time: it updates the CLAUDE.md managed block in place, writes a `<rule>.new` sidecar for any changed rule (your edited copy is kept), and never touches your existing BACKLOG.md.

## How to run it

Ask the user the questions below (accept the [default] on enter), then invoke the helper. Show the dry-run plan FIRST, get a confirm, then apply.

### Questions (ask in this order; skip a conditional question when its gate makes it irrelevant)

1. **Install scope** — user-global (`~/.claude/`) or this project (`<cwd>/.claude/`)?  [default: user-global]
   → sets `--target` and `--project-dir`.
2. **Board (BACKLOG) path** — where your task board lives.  [default: `<scope>/.claude/BACKLOG.md`]
   → `--backlog-path`.
3. **Multi-worktree?** — do you run parallel work in sibling worktree dirs?  [default: no]
   - 3b (only if yes) **Worktree root** — the slug your worktrees live under → `--worktree-root`.
4. **Gate groups** — which to enable? Show all five with a one-line description, ALL defaulted ON; the user presses Enter to accept all, or deselects any they don't want.
   - `commit-hygiene` — commit message + staging hygiene (needs bash/node/git; can't surprise you).
   - `pipeline-roles` — the 5-agent role gates + lifecycle reminders (needs bash/node/git).
   - `merge-gates` — PR-green + reviewer-verdict gates (needs `gh` + a GitHub-PR workflow). Suggest deselecting if the user doesn't use GitHub PRs.
   - `ledger-hygiene` — warn-only Stop nags about ledger size + worktree pile-up.
   - `dod-walk` — post-merge walk discipline (one Stop gate blocks an unwalked merge; the rest warn). Needs bash/node/git.
   [default: all five ON]
   → `--gates` (colon-joined) reflects the user's final selection.
5. **Notification?** — get pinged on a documented trigger?  [default: none]
   - 5b (only if yes) **Notify target** — a webhook URL (`--notify-webhook`) OR a shell-command template (`--notify-cmd`).

### Invoke the helper

```bash
# 1. Dry-run (DEFAULT — show the plan, write nothing):
node "${CLAUDE_PLUGIN_ROOT}/skills/install/install.mjs" \
  --plugin-root "${CLAUDE_PLUGIN_ROOT}" \
  --target "<resolved .claude dir>" \
  --backlog-path "<board path>" \
  --gates "commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk" \
  --dry-run

# 2. After the user confirms the plan, apply:
node "${CLAUDE_PLUGIN_ROOT}/skills/install/install.mjs" \
  --plugin-root "${CLAUDE_PLUGIN_ROOT}" \
  --target "<resolved .claude dir>" \
  --backlog-path "<board path>" \
  --gates "commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk" \
  --apply
```

Add `--worktree-root <slug>`, `--notify-webhook <url>`, or `--notify-cmd '<cmd>'` only when the user opted in.

## What the helper guarantees

- **Staged-atomic + fail-loud.** All `{{VAR}}` substitutions are staged in memory; if ANY `{{...}}` placeholder remains unsubstituted, it ABORTS and writes NOTHING (a leaked placeholder is a template bug, never the user's fault).
- **Never clobbers CLAUDE.md.** No file → creates it with the managed block only. Existing file, no managed block → APPENDS the block after your content. Existing managed block → replaces ONLY the bytes between `<!-- BEGIN awesome-autoloop … -->` and `<!-- END awesome-autoloop -->`.
- **Idempotent + non-destructive on re-run.** Re-running replaces the CLAUDE.md managed block in place (no duplication), writes a `<rule>.new` sidecar when a rule template changed (your edited copy is preserved, the update is surfaced beside it), and never touches your existing BACKLOG.md or struggle-log.md.

### Files written

The installer copies these editable templates into your `.claude/` (parameterized to your project):
- `CLAUDE.md` — the framework managed block (created or appended; never clobbers your content)
- `rules/common/principles.md` + `rules/common/pipeline-discipline.md` — the discipline rules (sidecar `.new` on update)
- `BACKLOG.md` — your task board (skip-if-exists; never overwritten)
- `struggle-log.md` — the execution struggle log: a running record of mistakes / harness friction that the `self-improve` skill mines for recurring patterns (skip-if-exists; never overwritten)

## After applying

On `--apply` the helper WRITES the env block into your `settings.json` automatically (a single parse→merge→write that preserves your other env keys): `AAL_GATES` (your selected gate groups) plus `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (the Agent Teams prerequisite — see below), and `AAL_WORKTREE_ROOT` / `AAL_NOTIFY_*` when you opted into them. No manual merge step. The mounted hooks read `AAL_GATES` at runtime to know which gate groups are on; if it's unset, the default `commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk` set (all five groups) applies. After applying, offer to tailor the setup to the project by chaining into `/project-profiler` (the tailoring tail below).

> **Prerequisite — Agent Teams.** The 5-agent pipeline requires Claude Code Agent Teams. The installer sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in your `settings.json` env on `--apply`. If a user runs the helper but never applies (dry-run only), tell them to set it by hand — without it teammate dispatch fails and the `block-bare-agent` gate dead-ends every dispatch. You pass any `team_name` string in the `Agent()` call — there is no separate `TeamCreate` step (TeamCreate was removed in Claude Code v2.1.178).

Notification (if you enabled it) is opt-in and never blocks: see `bin/notify` — it no-ops when unconfigured and never fail-closes on an unreachable target.

## Offer to tailor the templates to the project (chain into the profiler)

After the install applies, the helper dropped a `.pending-profile` marker and printed a profiler
invite. Offer to chain straight into the tailoring now:

1. Tell the user: the generic setup is installed; you can now tailor it to this project.
2. **Invoke `/awesome-autoloop:project-profiler`** — it scans the checkout (manifests, CI, test runner,
   deploy surface), then PROPOSES a tailored AAL_GATES selection, the project-specific meaning of the
   dod-walk live-verify, which `templates/rules/<stack>/` scaffold to adopt, and example stack rules.
3. The profiler proposes; it writes nothing without an explicit approval step. On approval it removes
   `.pending-profile`. If the user declines, the marker stays and the SessionStart nudge will remind
   them next session (they can dismiss permanently by deleting `.claude/.pending-profile`).
