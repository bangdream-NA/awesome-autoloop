# Pipeline discipline

The few pipeline/process rules a capable model won't naturally follow, distilled from real failures. Stack-agnostic. Everything else: judgment. Adapt the project-specific hooks (deploy channels, server-ops) to your own setup.

## 1. A dispatched wave is NOT progressing until proven
A backgrounded agent can die or stall leaving ZERO trace (empty branch, uncommitted work, no PR, no notification). Never assume a dispatched wave is advancing.
- A dev that doesn't send an Iteration Contract within a few minutes of dispatch is presumed dead → re-dispatch.
- Before you rely on / report on any backgrounded wave, VERIFY the deliverable exists: `git log origin/main..<branch>` has commits, OR a PR exists, OR the live artifact changed. No artifact = the wave never happened.
- A periodic stall-check covers long IDLE waits (sitting waiting on an agent with no turns happening) that a turn-end Stop hook does NOT catch.

## 2. Definition of Done = the live, user-facing artifact verified
"Done" requires verifying the FINAL artifact, never an intermediate. `merged`, `CI green`, `deployed` are necessary, NOT sufficient.
- UI/feature → a real-browser walk of the live page (not curl, not "the code looks right").
- Data-pipeline / deploy changes → a post-deploy REAL run + verify the downstream artifact actually changed, because CI can't exercise live creds/services.
- If the make-or-break path needs live creds/services CI lacks, plan the post-deploy real-run BEFORE declaring done.

## 3. Backlog / audit triage = re-verify the premise LIVE first
Task boards and audit findings are full of items whose premise is fake, stale, or already self-resolved. Before treating any item as work: reproduce its premise on the LIVE site/data (not from code reads or the item's own description). Classify FAKE / STALE / REAL-pending / DONE. Archive DONE & FAKE (record the verdict first). A "done"/"pending" status on the board is equally untrustworthy — verify against the live artifact.

## 4. One task board; clean worktrees at merge
- **Canonical backlog = `{{BACKLOG_PATH}}`.** It is the SINGLE source of truth, authoritative over the harness task store (which the harness splits + which collides on IDs). NEVER use TaskCreate / TaskList / TaskUpdate. Every dispatch points the agent at the board's path; the full spec still travels in the SendMessage.
- The team-lead owns the Status field; agents append-only to their own `— log:` line. Reconcile the board after every merge/audit.
- **At EVERY merge, immediately clean the wave:** `git worktree remove --force <its worktree>` + `git branch -D <its branch>` (+ remote delete). This is a HARD step of the merge, not a deferred chore. Squash-merged branches look UNMERGED to `git merge-base --is-ancestor` — judge done-ness by PR merge history (`gh pr list --state merged --json headRefName`), not ancestry.
<!-- aal:if WORKTREE_ROOT -->
- **Worktree tripwire:** if the count of worktrees under `{{WORKTREE_ROOT}}` exceeds ~12, STOP and bulk-prune — remove every non-active worktree dir, then `git branch -D` each branch whose name is in the merged-PR set.
- **Remote-branch tripwire + CRLF-safe bulk-prune:** merged PR-head branches pile up on the REMOTE too — a `--delete-branch` on merge catches only CLI merges (not UI merges) and never cleans pre-existing ones. When `git branch -r` exceeds ~15, bulk-prune with a loop that survives CRLF suffixes + leading whitespace — NOT a `comm`/process-substitution form (that silently false-cleans on CRLF line-endings, `git branch -r`'s indent, and a flaky-empty process-subst): `git fetch origin --prune`, then `git branch -r --format='%(refname:short)' | sed 's#^origin/##' | grep -v '^HEAD' | tr -d '\r' | sort -u | while read -r b; do [ "$b" = main ] && continue; [ -n "$(gh pr list --head "$b" --state merged --limit 1 --json number -q '.[].number')" ] && git push origin --delete "$b"; done`. (`--format` drops the indent, `tr -d '\r'` drops CRLF, the per-branch `gh pr list --head` loop replaces `comm`.) Assumes a `gh` PR-merge workflow — skip it if you don't merge via `gh`.
<!-- aal:endif -->

## 5. A green test ≠ the bug is fixed (false-green is the #1 recurring failure)
A passing regression test only proves what it actually exercises. Before declaring a fix done:
- Reproduce the EXACT observed failure, not a plausible-adjacent one.
- For runtime-specific bugs, the authoritative RED→GREEN gate MUST run in the TARGET runtime — a test in the wrong env can be green both before AND after.
- For deployed-artifact fixes, verify the EXECUTED artifact, not the repo copy — resolve what the service actually runs (some bins are installed copies a `git pull` doesn't touch).
- An architect spec that asserts a runtime behavior it never RAN on the target runtime is a liability; back the locked claim with an actual run.
- **Green is authoritative ONLY from the layer PROD actually uses.** A render/contrast fix asserts the element's COMPUTED style on the live page (a base-rule test misses an injected higher-specificity override); a UI-mutation fix tests the CALLER's emitted request body, not just the API endpoint (an API-direct green hides a request the UI builds wrong); a bug-CLASS fix enumerates and verifies the WHOLE affected set, never one clean sample; a data-DoD first confirms the queried table exists in the PROD store (a staging/local copy is not prod).

## 6. A rebase is a re-validation event, not just a git operation
After any rebase that crosses a sibling-merged commit, run the full project gates (typecheck minimum, ideally the test suite) on the rebased tree BEFORE `git push --force-with-lease`. `git status` clean ≠ type-clean: a sibling-merged PR can introduce a new file using a type your PR mutates — git merges it at text level but the type interface is a third collision axis beyond file-set and key overlap.

## 7. Enforcement gates must fail CLOSED + be self-contained
A ship/merge gate that depends on a network call fails OPEN on any hiccup (empty result → allow → it silently lets unverified work through). So: (a) derive the check from the COMMAND ITSELF (parse the PR# out of `gh pr merge <N>`), never from an external call that can empty-out; (b) fail CLOSED; (c) a ledger/obligation gate that checks "the PRIOR action" leaves a permanent tail-gap — gate the action being RUN. ENFORCED > DETECTED > DECORATIVE: a gate that can fail-open is DECORATIVE.
- **Gate classification reads STRUCTURED anchors, never whole-text substrings.** A gate judges intent/target from a DECLARED identity field (a mandatory first-line brief anchor, a specific tool_input field, a `meta` literal), NEVER a whole-command / whole-script / whole-prompt keyword grep — incidental DATA text (a filename, a quoted card title, a doc that merely DISCUSSES the policed op) false-matches. Three duties per gate: (a) anchor-first extraction; (b) the deny message prints the EXACT accepted token/format (self-documenting at the friction moment); (c) the fixture suite includes ≥1 incidental-text case (the trigger word present as data → must ALLOW). A deny may also append one structured line to `.claude/.gate-denials` (via `lib/log-denial.sh`) so the self-improve loop mines a recurring false-positive as a COUNT, not an anecdote.

## 8. Session-maintained ledgers MUST stay Read-able (rotate, never balloon)
The Read tool hard-errors above ~256KB and Edit requires a prior Read, so any ledger that balloons past that becomes un-Read-able AND un-appendable — work then stalls or gets logged blind. Keep each session-maintained GROWING ledger (`BACKLOG.md`, `struggle-log.md`, and the per-project machine store `reviews/index.jsonl`) under ~240KB. (The `code-reviews.md` / `plan-reviews.md` monoliths are frozen legacy — they no longer grow, since reviewers now write per-verdict files under `reviews/`.) When one crosses ~240KB, SPLIT it at line boundaries into `<name>-archive-NN.md` parts — or `reviews/index-archive-NN.jsonl` for the jsonl — (each <240KB, ALL content preserved) and replace the active file with a short header listing the parts; new entries append to the fresh active file. The gates grep the ACTIVE `index.jsonl`, so recent verdicts stay found after a split. NEVER truncate or discard content — archive it.

## 9. Server / deploy operations: document a runbook; never reverse-engineer the box ad-hoc
If your project has production/server operations, write a runbook for each (the env-injection, sudo, file paths, AND known footguns) and READ it before running the op — don't reconstruct how an op works from a string of exploratory SSH probes. A blind re-run on a misdiagnosis burns a prod run and yields a wrong conclusion. (This framework ships project-topology gates like a runbook-required gate as documented examples in `examples/` — adopt them for your own server-ops if you have any.)

## 10. Verify cheap facts FIRST-HAND with the right tool; a layout-pass is NOT a correctness-pass
Acting on a SECONDHAND or ASSUMED claim instead of running the cheap check yourself is a top recurring failure.
- Never relay an agent's "source-verified" fact downstream without reading it yourself when it is cheap (a few lines, a path, a field). One self-grep/curl beats a multi-message whiplash.
- For a render/color/layout claim, read the COMPUTED value on the LIVE element — NOT a base-rule grep; a broad ancestor selector can win the cascade and flip the conclusion.
- A DUPLICATION / COUNT claim about what the USER SEES is proven by a SCREENSHOT read visually (or by counting post-hydration, painted, de-duplicated elements) — NEVER by a raw `querySelectorAll(...).length`, which over-counts hydration-transient + broad-selector + secondary nodes.
- Distinguish a DATA bug from a USER-VISIBLE RENDER bug — they carry different severities AND fix layers. Verify BOTH: check the data AND screenshot the render.
- **Absence / dup / security probes need the right criterion.** An ABSENCE claim never comes from a head-truncated grep (use `grep -c` or the full output — a `head -N` cut fakes a confident "X doesn't exist"); a DUP claim uses the SEMANTIC twin key (the partition/identity key, not byte-identity); a security sweep greps the SINK pattern enumerating ALL occurrences, never field names. And a DERIVED/generalized doc's `diff source template` `>`-lines are NOT template-only content — a generalized REWORDING of an existing source line ALSO diffs as a `>` addition, so judge "the template lacks content" by whole-SECTION absence, not by diff lines (else a de-specification reads as an addition and seeds a phantom back-port).
- **Cross-platform tooling/parser footguns silently return FAKE facts.** A file parser must `split(/\r?\n/)` — a CRLF residue defeats a `$`-anchored regex and fakes a "0/clean" result; run `command -v <tool>` BEFORE piping an unconfirmed external tool to `2>/dev/null` (a missing tool masked as empty stdout is fake data, not a real zero); set an explicit output encoding for non-ASCII stdout (e.g. `PYTHONIOENCODING=utf-8`) — and a crash AFTER the write step is a print-only failure, the op already succeeded.

## 11. Agent-lifecycle hygiene
- ONE agent = ONE wave-role: NEVER reuse/re-task a teammate across waves or roles. Spawn FRESH per wave+role; shut it down the moment its deliverable is accepted. Reviewers especially: a FRESH code-reviewer per PR.
- SHUT DOWN each teammate the moment its deliverable is accepted (merged / APPROVED) — AT the merge, not deferred. A long session can let a team reach a stuck-member catch-22 clearable only by restart. Pair with a roster tripwire.
- Read-only audit/probe agents must write scratch files to a temp path OUTSIDE the repo — a stray probe file makes `git status` dirty and can DENY every clean-tree-gated op.
- In-process teammates share the scheduler: the lead doing constant turns can slot-starve in-flight agents. Going quiet (fewer turns, shut down done agents) is what lets them progress. A >30-min-quiet agent is DEAD only if it has ZERO on-disk artifact; growing WIP = alive → leave it.
- **Presume-dead checklist — ALL FOUR before any re-dispatch or shutdown:** (1) artifact check in the RIGHT place — the agent's WORKTREE/branch (`git log origin/main..<branch>`) or its review ledger, never the main checkout; (2) real elapsed >30 min from the team config's join time vs a fresh clock, never inferred from a cron rhythm; (3) one unanswered ping; (4) no pending/late-registering CI lane it could legitimately be waiting on (a reviewer waiting on CI looks identical to a dead one).
- **Scope-adds to an in-flight agent = ONE consolidated message.** The inbox is FIFO and the agent delivers after processing the first message — later scope-adds silently drop. If unavoidably multiple, each carries "N of M — do not deliver until M/M". Before claiming an agent missed a scope-add, `git log` its worktree HEAD first (inbox delivery lags behind commits).
- **After ANY compaction, reconcile the roster FIRST.** The compaction summary omits the agent roster, so early-session teammates become invisible zombies. Enumerate running teammates BEFORE spawning anything new.

## 12. Before parallelizing, diff the FILE SETS
Before dispatching 2+ waves as parallel/orthogonal, diff the FILE SETS each wave's file-map touches — different feature ≠ different file; any shared path ⇒ SEQUENCE (merge first, rebase + resolve the second), never parallel-merge.
