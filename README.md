<div align="center">

# 🔁 Awesome Autoloop

**An opinionated 5-agent pipeline + enforcement-hook framework for [Claude Code](https://docs.claude.com/en/docs/claude-code).**

It blocks some of your actions *on purpose* — and documents every single one.

[![CI](https://github.com/suhang56/awesome-autoloop/actions/workflows/ci.yml/badge.svg)](https://github.com/suhang56/awesome-autoloop/actions/workflows/ci.yml)
&nbsp;·&nbsp; [![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
&nbsp;·&nbsp; version 1.0.0
&nbsp;·&nbsp; for Claude Code (Agent Teams)

</div>

---

Awesome Autoloop turns Claude Code into a disciplined software team. Work flows through a fixed **5-agent pipeline**, and a layer of **enforcement hooks** holds the line — blocking a `Co-Authored-By` commit, an unreviewed merge, a developer dispatched before a spec exists, and ~30 other footguns. The gates are honest: every action a hook can block is in the [trust table](#-the-trust-model), and **every gate no-ops in any repo that isn't an autoloop project** — your unrelated work is never touched.

**What you get**

- 🤖 **A 5-agent pipeline** — `planner → plan-reviewer → architect → developer → code-reviewer` — wired as Claude Code Agent Teams, with role gates that keep the order honest.
- 🛡️ **~30 enforcement hooks in 5 toggleable groups** — commit hygiene, pipeline roles, merge gates, ledger hygiene, and post-merge "definition of done" walks. Deny-gates fail **closed**; nag-gates fail **open**.
- 🧩 **Yours to adapt** — the hooks + agents mount read-only from the plugin; an interactive installer copies an *editable* CLAUDE.md framework + rules + a task-board template into your own `.claude/`.

```text
   you ─▶ planner ─▶ plan-reviewer ─▶ architect ─▶ developer ─▶ code-reviewer ─▶ merge
            │            (Mode A)         │            │            (Mode B)        │
            └──────────────────── enforcement hooks gate every step ───────────────┘
              commit-hygiene · pipeline-roles · merge-gates · ledger-hygiene · dod-walk
```

## 🚀 Install

```text
/plugin marketplace add suhang56/awesome-autoloop
/plugin install awesome-autoloop@awesome-autoloop
/awesome-autoloop:install
```

1. registers this repo as a marketplace · 2. installs the plugin (hooks + agents + skills mount automatically) · 3. runs the interactive installer that copies the editable framework templates into your `.claude/` and lets you choose which gate groups to enable. The third command is **idempotent** — re-run it any time.

> **Prerequisite — Agent Teams.** The 5-agent pipeline needs Claude Code Agent Teams. The installer sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in your `settings.json` env on `--apply` (set it by hand if you skip the installer). You pass any `team_name` string in the `Agent()` call — there is **no separate `TeamCreate` step** (TeamCreate was removed in Claude Code v2.1.178). Without the env var, teammate dispatch fails and the `block-bare-agent` gate dead-ends every spawn.

> **Two halves to turn it on.** The installer wires the **gate** half (hooks + the activation marker). You turn on the **drive** half: the Agent-Teams env var above *plus* an autonomous/auto driving posture (a standing goal + non-per-action permission) so the pipeline actually loops. Agent Teams alone leaves the team idle — see [docs/QUICKSTART.md](docs/QUICKSTART.md).

<details>
<summary><b>🪟 Windows — install Git for Windows first (one-time)</b></summary>

Every enforcement hook is a `.sh` script, so it needs bash. Install [Git for Windows](https://gitforwindows.org/) before anything else — without git-bash, bash itself is absent and **every hook is silently inactive**, and no hook can warn you (bash can't run to detect its own absence). This is the one degradation the plugin can't surface at runtime. On macOS/Linux bash is native — skip this.
</details>

**▶️ Run your first wave.** The installer drops an empty `.autoloop` marker in your `.claude/` (the activation anchor) and copies the editable templates. For a spec-to-merge walkthrough of one wave through the gates, read **[docs/QUICKSTART.md](docs/QUICKSTART.md)**.

## 🛡️ The trust model

This framework can block your tool calls. That power is the point — and so is the honesty about it. Three things make it safe to install:

1. **Every blockable action is documented.** The full per-hook table is below. **deny** = the hook blocks the call (fail-closed); **warn** = it only emits a message, never blocks (fail-open).
2. **It no-ops outside your autoloop projects.** Hooks mount *globally*, but a node-free guard runs first in every gate and `exit 0`s unless the repo is autoloop-managed (see [activation model](#-activation--how-it-works)). A `git commit` in an unrelated repo is never touched.
3. **You choose what's on.** The 5 gate groups are toggled at install (and via the `AAL_GATES` env var after). Don't use GitHub PRs? Deselect `merge-gates`.

> **⚠️ Two hooks delete directories.** `roster-tripwire` and `block-spawn-over-roster-cap` prune *harness team dirs* under `~/.claude/teams/` that are untouched for >2 days (to clear stale-roster false-positives) — only dirs that look like a dead harness team (a `config.json` + mtime >2d), and only inside an autoloop project. They never touch your files.

<details>
<summary><b>📋 The full per-hook trust table (all ~30 hooks, by group)</b></summary>

> **Stop tier runs through one mount.** Every `Stop` row is invoked by the single `stop-dispatcher` mount, which runs them in one process, merges all block reasons + all warns into ONE turn-end **block** message, and fails OPEN if node is absent. The per-check behaviors are unchanged — only the delivery is consolidated.

### commit-hygiene · needs: bash, node, git · ON by default · fail-closed (these BLOCK a bad commit)

| Hook | Event / matcher | Fail mode | Denies / warns | Deps |
|---|---|---|---|---|
| `block-coauthor-commit` | PreToolUse / Bash | **deny** | Blocks a `git commit` whose message contains a `Co-Authored-By` trailer. Parses the full command via node so a quoted/heredoc message can't smuggle the line past a naive grep. | bash, node |
| `enforce-conventional-commit` | PreToolUse / Bash | **deny** | Blocks a `git commit` whose message isn't `type(scope)!: description` (feat\|fix\|refactor\|docs\|test\|chore\|perf\|ci\|build\|style). Parses the command via node (sources `lib/parse-json.sh`); skips messages built via `$(...)`/heredoc it can't introspect. | bash, node |
| `block-claude-dir-commit` | PreToolUse / Bash | **deny** | Blocks a `git commit`/`push` while `.claude/` is staged — keeps your private config out of git. Parses the full command via node and honors the **last** `cd <dir>` anywhere in the command (resolves the right repo for compound/worktree forms). | bash, node, git |
| `block-compound-commit-push` | PreToolUse / Bash | **deny** (fail-OPEN) | Blocks one Bash call that compounds `git add`/`git commit` with `git push`/`gh pr merge` (via `&&`/`;`/`\|`). If the gated push/merge is later denied, the WHOLE compound fails and the earlier commit silently doesn't run — so split them. A footgun-preventer, not a security gate: node-absent → no-op (allow). | bash, node |
| `block-pnpm-install-in-main` | PreToolUse / Bash | **deny** | Blocks a `pnpm install/i/add/up/update` targeting the shared main checkout (an aborted install there wipes `node_modules/.pnpm` + bins). No-ops unless `AAL_MAIN_REPO` is set; a worktree install (`AAL_WORKTREE_ROOT`) is allowed; append `# ALLOW_MAIN_INSTALL` for a deliberate lead recovery. | bash, node |
| `block-cleaned-data-commit` | PreToolUse / Bash | **deny** | Blocks a `git commit`/`push` whose changed files include cleaned/canonical data (DB dumps, published snapshots, `*.parquet`/`*.ndjson`/`*.sql.gz`). The default pattern set is stack-agnostic; add project-specific data paths via `AAL_DATA_GLOBS`. | bash, node, git |

### pipeline-roles · needs: bash, node, git · ON by default · mixed (deny for role gates, warn for reminders)

| Hook | Event / matcher | Fail mode | Denies / warns | Deps |
|---|---|---|---|---|
| `stop-dispatcher` | Stop | **warn** | The single Stop mount. Runs every consolidated Stop check (the 9 `Stop` rows across the groups) in one process: drains stdin once + feeds each, isolates a crashing check, normalizes both block wire-forms, and merges all reasons + warns into ONE `decision:block` Stop JSON (warns folded into the reason). Always emits + exit 0; node-absent → every child no-ops (fails OPEN). Edit its one-line `CHECKS=( … )` registry to add/remove a check. | bash, node |
| `block-bare-agent` | PreToolUse / Agent | **deny** | Blocks a bare Agent spawn without a `team_name`, and a pipeline-role spawn missing a `name` or set `run_in_background:true` (a mailbox-less one-shot). | bash, node |
| `validate-agent-type` | PreToolUse / Agent | **deny** | Blocks a `subagent_type` outside the allowed set (the 5 pipeline roles + Explore/general-purpose). | bash, node |
| `block-non-codereviewer-mode-b` | PreToolUse / Agent | **deny** (default-allow) | Blocks a Mode-B / PR code-review dispatched to anything other than `code-reviewer`. Narrow trigger; default allow. | bash, node |
| `block-spawn-over-roster-cap` | PreToolUse / Agent | **deny** | Blocks a new teammate spawn once the live roster hits the cap (`AAL_ROSTER_CAP`, default 16) — forces shutdown-of-done before spawn. | bash, node |
| `enforce-planner-first` | PreToolUse / Agent | **deny** | Blocks a `developer` spawn for feature work when no recent spec exists in `docs/product-specs/`. Bug-fix team names (`fix`/`bug`) skip it. | bash, git |
| `block-backlog-status-drift` | PreToolUse / Write\|Edit\|MultiEdit | **deny** | Blocks writing a non-whitelisted `### [STATUS]` (or a bare ✅/DONE/MERGED badge) onto an active `.claude/BACKLOG.md`; a done card belongs in `BACKLOG-archive.md`. Fail-OPEN on a parse error. | bash, node |
| `block-malformed-new-backlog-card` | PreToolUse / Write\|Edit\|MultiEdit | **deny** | Blocks a NEW board card missing the skeleton (whitelisted status + `aliases:`/`problem:`/`fix:`). Editing an existing card is never blocked (migration-tolerant). | bash, node |
| `backlog-sop-validate` (pre-dispatch) | PreToolUse / Agent | **deny** | Blocks an `architect` dispatch with no APPROVED plan-review verdict, or a `developer` with no ARCH_APPROVED proof, for the target board card. | bash, node |
| `backlog-sop-validate` (pre-review) | PreToolUse / Agent | **deny** | Blocks a `code-reviewer` (Mode B) dispatch with no real PR# + pinned HEAD SHA (or card DEV_DELIVERED + PR_OPENED). | bash, node |
| `block-codereviewer-for-plan-review` | PreToolUse / Agent | **deny** (default-allow) | Blocks a `code-reviewer` dispatch carrying a strong Mode-A plan-review signal — Mode-A plan review is the `plan-reviewer`'s job. Narrow trigger; default allow. | bash, node |
| `require-stallcheck-cron-before-dispatch` | PreToolUse / Agent | **deny** | Blocks the FIRST pipeline-role dispatch of a session until a `CronCreate(STALL-CHECK)` tool_use appears — an autonomous run needs a recurring stall-check cron. **Set `AAL_STALLCHECK=off` to skip it for interactive use.** | bash, node |
| `block-lead-plan-approval-response` | PreToolUse / SendMessage | **deny** | Blocks the team-lead from sending a plan-approval-response directly — plan approval is `plan-reviewer` Mode A's job. | bash, node |
| `block-lead-editing-source` | PreToolUse / Write\|Edit\|MultiEdit | **deny** | Blocks the team-lead from editing app source directly (a developer's job); harness files (`.claude/`, `docs/`, `CLAUDE.md`, hooks, …) are always allowed. Overridable via `AAL_APP_SRC_GLOBS`. | bash |
| `require-premise-verified-before-dev` | PreToolUse / Agent | **deny** | Blocks a `developer` dispatch for a wave with no logged plan-review verdict (jsonl-first: `.claude/reviews/index.jsonl`, `plan-reviews.md` legacy). Append `# PREMISE-VERIFIED: <evidence>` to override a trivial change. | bash, node |
| `block-non-lead-git-push-merge` | PreToolUse / Bash | **deny** | Blocks `git push` / `gh pr` mutations from a worktree cwd — agents commit locally + hand off to the lead. Matches `*-wt/*`, `*/.worktrees/*`; set `AAL_WORKTREE_ROOT` for a project token. | bash, node |
| `block-multi-worktree-per-wave` | PreToolUse / Bash | **deny** | Blocks a 2nd `git worktree add` for a wave that already has one. No-ops unless `AAL_WORKTREE_ROOT` is set; `--detach` reviewer worktrees are allowed. | bash, node |
| `backlog-drift-check` | Stop | **warn** (exit 2) | At turn-end (throttled 30min), flags an active card whose PRIMARY alias matches a MERGED PR but isn't marked done. Fail-OPEN. | bash, node, git, gh |
| `backlog-drift-guard` | Stop | **warn** | At turn-end, warns on a non-whitelisted status header, a lingering `[DONE]` card, or a legacy dual-track line. Pure bash. | bash |
| `check-stale-agents` | Stop | **warn** | At turn-end, flags alive teammates whose inbox is >30min stale. Throttled per session. | bash, node |
| `session-learnings` | Stop | **warn** | At turn-end, a quiet reflect/record nudge. Default SKIP; fires once per ~15min. | bash, node |
| `oplog-turn-reminder` | Stop | **warn** | At turn-end, a quiet nudge to log a ledger-worthy between-merge action to the active project's `.claude/autoloop-log-*.md`. Default SKIP; no-ops unless that file exists; ~20min throttle. | bash, node |
| `prune-team-inboxes` | Stop + PostToolUse / SendMessage | **warn** | When a team inbox exceeds 250KB, archives old read messages, keeps ALL unread. | bash, node |
| `remind-shutdown-done-agent` | PostToolUse / Bash | **warn** | After a `gh pr merge`, reminds you to shut down that PR's reviewer. | bash, node |
| `remind-dispatch-reviewer-after-dev` | PostToolUse / SendMessage | **warn** | After a `shutdown_request` to a `dev-*` agent, reminds you to dispatch a fresh code-reviewer if its PR is un-reviewed. | bash, node |
| `post-merge-cleanup-reminder` | PostToolUse / Bash | **warn** | After a `gh pr merge`, emits the post-merge checklist (board, worktree, branch, doc-sync). | bash, node |
| `loop-detection` | PostToolUse / Bash | **warn** (exit 2) | Warns when an identical tool call is made 3+ times consecutively. Log to `${CLAUDE_PLUGIN_DATA}` (cross-platform). | bash |
| `pipeline-reminder` | UserPromptSubmit | inject | Re-injects the 7 mandatory pipeline rules each message (static text). | bash |
| `roster-tripwire` | Stop | **warn** | Warns when a team's member count exceeds the cap (`AAL_ROSTER_TRIPWIRE`, default 11). | bash, node |

### merge-gates · needs: bash, node, git, gh · ON by default · fail-closed

These assume a `gh` + GitHub-PR + reviewer-ledger workflow — deselect them at install if that's not your setup. The board/ship gates resolve **which project** a merge belongs to from the **last `cd <dir>`** in the command, and **deny (fail-closed)** when no `cd <project-dir>` resolves (never defaulting to another project's board). Run a merge as `cd <project> && gh pr merge <N>`.

| Hook | Event / matcher | Fail mode | Denies / warns | Deps |
|---|---|---|---|---|
| `require-review-before-ship` | PreToolUse / Bash | **deny** | Blocks `git push`/`gh pr merge` unless `.claude/reviews/index.jsonl` (jsonl-first) or the per-verdict `reviews/pr<N>-r<round>.md` has an APPROVED verdict bound to the current HEAD SHA for this PR (`code-reviews.md` legacy fallback). An update-push (new commits) is allowed. | bash, node, git, gh |
| `require-tests-before-ship` | PreToolUse / Bash | **deny** | Blocks `git push` on a feature branch with source changes but no test changes (Kotlin/TS/SQL-aware; unknown stacks degrade to no-block), and on failing/pending CI at HEAD. | bash, node, git, gh |
| `require-pr-green-before-merge` | PreToolUse / Bash | **deny** | Blocks `gh pr merge` unless the PR is OPEN/not-draft, mergeable, CI green, and review APPROVED at the current HEAD SHA. | bash, node, git, gh |
| `require-codereviewer-verdict-before-merge` | PreToolUse / Bash | **deny** | Blocks `gh pr merge` unless the review block carries a `Reviewer-type: code-reviewer` attestation (proves a fresh code-reviewer wrote it). | bash, node, git, gh |
| `enforce-delete-branch-on-merge` | PreToolUse / Bash | **deny** | Blocks `gh pr merge` without `--delete-branch` (squash-merged branches pile up otherwise). | bash, node |
| `block-pr-merge-stale-base` | PreToolUse / Bash | **deny** | Blocks `gh pr merge <N>` when the PR's base is stale (branched before later merges to `origin/main`) — a squash-merge could silently revert in-between work. Fail-OPEN on uncertainty. | bash, node, git, gh |
| `require-backlog-reconciled-before-merge` | PreToolUse / Bash | **deny** | Blocks `gh pr merge` when the active board still lists a card whose PRIMARY alias matches an ALREADY-MERGED PR. Resolves the project from the last `cd <dir>`; fail-CLOSED on unresolvable repo/gh failure. | bash, node, git, gh |
| `require-oplog-row-for-this-merge` | PreToolUse / Bash | **deny** | Blocks `gh pr merge <N>` unless any `.claude/autoloop-log-*.md` (searched across ALL of them, grep-ALL — the row may be in any session's per-session ledger) carries a row citing `#<N>`. Self-contained (reads `<N>` from the command, no `gh` call). **No-ops unless an `autoloop-log-*.md` exists.** `AAL_OPLOG_DIR` overrides the dir. | bash, node |

### ledger-hygiene · needs: bash, node, git · ON by default · fail-open (warn only)

| Hook | Event / matcher | Fail mode | Denies / warns | Deps |
|---|---|---|---|---|
| `ledger-size-guard` | Stop | **warn** | At turn-end (~15min), warns when a session ledger nears the 256KB Read-tool ceiling, with a directive to split it. | bash, node |
| `worktree-count-guard` | Stop | **warn** | When `AAL_WORKTREE_ROOT` is set, warns if worktrees under it exceed the cap (`AAL_WORKTREE_CAP`, default 12). No-ops for single-tree users. | bash, git |
| `block-truncate-existing-ledger` | PreToolUse / Bash | **deny** (fail-OPEN) | Blocks a TRUNCATING write (`>`, `Out-File`, `Set-Content`) onto an EXISTING archive/ledger (`*-archive*.md`, `BACKLOG`, `plan-reviews`, `code-reviews`, `struggle-log`, `autoloop-log` `.md`, or `reviews/index.jsonl`) — `>` clears the file first. Append (`>>`) or use Edit/Write. Node-absent → no-op. | bash, node |

### dod-walk · needs: bash, node, git · ON by default · mixed (one Stop gate blocks an unwalked merge; the rest warn)

A post-merge "definition of done": after you merge a PR, verify the live/final artifact (a browser walk for a web app, a built-binary run for a CLI, an API exercise for a library) and record it as a `.claude/walks/*.md` file naming the PR. The gate checks THAT a verification artifact exists, not HOW you produced it.

| Hook | Event / matcher | Fail mode | Denies / warns | Deps |
|---|---|---|---|---|
| `check-unwalked-merges` | Stop | **warn** | At turn-end, blocks once if a merged PR has no `.claude/walks/*.md` artifact naming it. Fail-OPEN on node-absent. Clear it with a walk file or `PR #N: non-UI, walk N/A — <reason>`. | bash, node, git |
| `post-pr-merge-walk-reminder` | PostToolUse / Bash | **warn** | After a `gh pr merge`, drops a sentinel + reminds you to walk that PR's live surface. | bash, node, git |
| `render-finding-playwright-guard` | Stop | **warn** | At turn-end, a quiet nudge: if you triaged a user-visible/render finding as confirmed without verifying it on the LIVE artifact (a screenshot read visually, a curl of the live endpoint). Default SKIP; ~30min throttle. | bash, node |
| `remind-walk-before-next-merge` | PreToolUse / Bash | **warn** | Before the NEXT `gh pr merge`, reminds you if a prior merged PR is still unwalked. Advisory; always allows. | bash, node, git |

</details>

## ⚙️ Activation & how it works

<details open>
<summary><b>When the gates enforce</b></summary>

The gates enforce ONLY in autoloop-managed projects; they no-op everywhere else. A project is autoloop-managed if its `.claude/` has any of these markers:

- `.autoloop` — the installer drops this empty anchor on `--apply` (zero-false-negative marker).
- `BACKLOG.md` — the pipeline task board · `code-reviews.md` — the review ledger.
- the `<!-- BEGIN awesome-autoloop -->` managed block in `CLAUDE.md`.

The plugin mounts its hooks **globally**, but each hook self-skips outside an autoloop project: a node-free activation guard runs FIRST, resolves the project dir (`CLAUDE_PROJECT_DIR` → `git --git-common-dir` → toplevel → cwd), and `exit 0`s when none of the markers is present. If a gate fires somewhere unexpected, that repo carries a marker — opt out with `AAL_GATES=` (empty) in its `settings.json`, or delete the marker.
</details>

<details>
<summary><b>What gets MOUNTED vs what gets COPIED</b> (the most trust-relevant distinction)</summary>

- **MOUNTED** — the hooks, the 6 pipeline agents, and the skills run **from the plugin** (read-only cache). They can act on your tool calls and auto-update with the plugin. You don't edit them; override an agent by dropping a same-named file in your own `~/.claude/agents/`.
- **COPIED** — the installer copies **editable templates** (the CLAUDE.md framework, `rules/common/*`, a BACKLOG template) into your own `.claude/`, parameterized to your project. Yours to edit; the installer never clobbers an existing CLAUDE.md (it manages a delimited block).

Mounted files carry ZERO install-time variables — they parameterize at runtime via `${CLAUDE_PROJECT_DIR}`, `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, and the `${AAL_GATES}` env flag the installer writes. Copied templates parameterize at install time via `{{VAR}}` substitution.
</details>

<details>
<summary><b>The 5 gate groups</b></summary>

The installer's gate-group question controls which groups mount, via an `AAL_GATES` env flag in your `settings.json`:

- **commit-hygiene** (ON) — commit message + staging hygiene. Needs bash/node/git. Can't surprise you.
- **pipeline-roles** (ON) — the 5-agent role gates + lifecycle reminders. Needs bash/node/git.
- **merge-gates** (ON) — PR-green + reviewer-verdict gates. Need `gh` + a GitHub-PR + reviewer-ledger workflow; deselect if you don't use GitHub PRs.
- **ledger-hygiene** (ON) — warn-only Stop nags about ledger size + worktree pile-up.
- **dod-walk** (ON) — post-merge walk discipline; blocks turn-end if a merged PR has no walk artifact. Fail-OPEN on node-absent.

All five are ON by default. To change groups after install, edit `AAL_GATES` (colon-joined, e.g. `commit-hygiene:pipeline-roles`) in your `settings.json` `env` block and re-run the installer.
</details>

<details>
<summary><b>The 6 agents & 2 skills</b></summary>

**Agents.** The 6 pipeline agents (`planner`, `plan-reviewer`, `uiux-designer`, `architect`, `developer`, `code-reviewer`) ship with `model` + `thinking` frontmatter OMITTED, so they inherit YOUR default model — they work on every plan, tier-independent. Run a richer tier by dropping a same-named agent file into your own `~/.claude/agents/`.

**Skills** (besides `/awesome-autoloop:install`):
- **`/awesome-autoloop:project-profiler`** — scans this project (manifests, CI, test runner, deploy surface) and PROPOSES a tailored setup (gate-group selection, what dod-walk means here, which `templates/rules/<stack>/` scaffold to adopt). Proposes only — nothing is written without an explicit approval step. The installer drops a `.pending-profile` marker on `--apply` and the SessionStart preflight nudges you to run it.
- **`/awesome-autoloop:self-improve`** — mines `.claude/.gate-denials` (the structured deny-event log) + your struggle-log for recurring footguns and PROPOSES durable rules/hooks/memories. Never auto-applies. The preflight nudges a re-run when its last run was >24h ago.
</details>

<details>
<summary><b>Cross-platform prerequisites</b></summary>

- **bash** — for the `.sh` hooks. Windows: Git for Windows (git-bash); macOS/Linux: native.
- **node (≥18)** — for the JSON-parsing `.sh` hooks (via `lib/parse-json.sh`). Without it, the node-dependent **deny** gates fail CLOSED (a security gate that can't parse its payload must not silently allow); **warn** hooks degrade to a clean no-op. The only hooks that run with node absent are `enforce-planner-first`, `loop-detection`, `pipeline-reminder`, `worktree-count-guard`. A SessionStart preflight (`hooks/preflight.sh`) warns when node is missing.
- **git / gh** — `git` for staging/branch hooks; `gh` (authenticated GitHub CLI) for the merge-gates group.
- Local state lives under your project `.claude/` and is gitignored: the deny-event log (`.claude/.gate-denials`, rotated past 240KB) and the self-improve cadence marker (`.claude/.aal-state/self-improve-last-run`, a single un-keyed epoch-seconds int so the >24h nudge survives a session rotation). `loop-detection` logs to `${CLAUDE_PLUGIN_DATA}` (falling back to `${XDG_STATE_HOME:-$HOME/.local/state}`).
</details>

## 🔧 Adapting & living with the gates

**Write your own gate.** The project-specific gates the framework uses (board-as-truth validators, prod-topology gates, server-op runbook gates) are NOT mounted — they hardcode a board format, prod host, or worktree layout that isn't generic. Representative ones ship as documented examples under [`examples/`](examples/) with project literals replaced by placeholders, plus a README on how to adapt one. Copy an example into your own `~/.claude/hooks/`, fill the placeholders, and wire it in `settings.json`.

<details>
<summary><b>Three footguns once the gates are active</b> (full decoder in <a href="docs/OPERATING.md">docs/OPERATING.md</a>)</summary>

1. **Whole-command-deny.** PreToolUse/Bash gates grep the WHOLE command string. A command that merely *mentions* `gh pr merge` or `git push` as literal text (a doc heredoc, a test payload, an `echo`) is matched and denied. Write docs via your editor, not a Bash heredoc; pipe test payloads from a file.
2. **Dispatch gates fire before you've written a spec.** `enforce-planner-first` denies a `developer` spawn when no recent spec exists under `docs/product-specs/`. Write the spec first, or use a `fix`/`bug` team name (those skip it for genuine bug-fixes).
3. **Fail-open vs fail-closed is asymmetric, on purpose.** The commit/merge deny gates fail-CLOSED on a missing dependency (no node → DENY): an unreviewed merge is the worse failure. The DoD-walk Stop gate fails-OPEN (no node → allow): blocking every turn-end on a node-less box is worse than skipping a nudge.
</details>

## 📦 Uninstall

- Remove the managed CLAUDE.md block: delete everything between `<!-- BEGIN awesome-autoloop … -->` and `<!-- END awesome-autoloop -->` in your `.claude/CLAUDE.md`.
- `/plugin uninstall awesome-autoloop` unmounts the hooks/agents/skills.
- The installer-copied templates (`rules/common/*`, `BACKLOG.md`) stay — they're yours; delete by hand if unwanted.

## 🏷️ Versioning

`plugin.json` pins a `version`; releases are git-tagged. Update by re-pulling the tagged release (`/plugin marketplace update awesome-autoloop`, then `/plugin install`). The version is the single source of truth — there is no SHA-fallback.

> **Breaking (unreleased, pre-1.0):** the board-enforcement hooks' config env vars were renamed from the `BF_*` prefix to the project's `AAL_*` prefix (`BF_BACKLOG`→`AAL_BACKLOG`, `BF_REPO`→`AAL_REPO`, `BF_PLAN_REVIEWS`/`BF_PLANREVIEWS`→`AAL_PLAN_REVIEWS`, `BF_OPLOG`→`AAL_OPLOG`, `BF_OPLOG_DIR`→`AAL_OPLOG_DIR`, `BF_ARCHIVE`→`AAL_ARCHIVE`, `BF_NO_GH`→`AAL_NO_GH`, `BF_DEBT_VERBOSE`→`AAL_DEBT_VERBOSE`). No alias — if you set any `BF_*` override, switch it to `AAL_*`.

## 📄 License

MIT — see [LICENSE](LICENSE).
