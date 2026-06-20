---
name: backlog-reconcile
description: Read-only drift report that cross-checks your .claude/BACKLOG.md against the machine truth (`gh pr list` merged/open). Surfaces cards that are MERGED-but-still-active, stale MERGED-#N acks, and internal queue-vs-card status drift — so "the last session said it was all done" can be VERIFIED, not trusted. Run at session start / before a merge batch / when reconciling board state. NEVER edits the board (report-only).
---

# backlog-reconcile

Cross-references the hand-maintained `.claude/BACKLOG.md` against `gh pr list` so card status can't
silently drift from what actually merged. **READ-ONLY** — it never edits the board or moves cards
to archive.

## Run

```bash
node skills/backlog-reconcile/backlog-reconcile.mjs
```

By default it reads the board at `${CLAUDE_PROJECT_DIR}/.claude/BACKLOG.md` (falling back to
`<cwd>/.claude/BACKLOG.md`) and resolves the repo from `git remote get-url origin`. To point it at
another board / repo:

```bash
AAL_BACKLOG=<path/to/BACKLOG.md> AAL_REPO=<owner/repo> node skills/backlog-reconcile/backlog-reconcile.mjs
```

The `--hook` flag (or a `CLAUDE_HOOK` env) is for a SessionStart wiring — it emits `systemMessage`
JSON ONLY on drift; the plain run prints the full report. `gh` must be authenticated for the
vs-machine check; see the gh-absent note below.

## Read the output

Three classes (the script tags each line):
- **⚠️ DRIFT (actionable)** — fix these. `[B unacked-merge]` = a card is still `[IN-DEV]`/`[REVIEW]`
  but its PR is MERGED and the card has no `MERGED #N` ack → annotate the card with the ack and
  (after live-DoD) archive it. `[B bad-ack]` = the card claims `MERGED #N` but #N is neither merged
  nor open (wrong/stale PR#). `[A internal]` = a wave appears in BOTH the numbered queue and as a
  `### [STATUS]` card with DIFFERENT statuses. `[bare-badge]` = a `### ✅/DONE/MERGED` done-marker on
  the active board with NO `[STATUS]` bracket — done cards belong in `BACKLOG-archive.md`; move it.
- **🔍 to verify (naming-limited)** — a merged PR whose branch name diverges from the card slug
  MIGHT be this wave; verify first-hand, then add a `MERGED #N` ack so the next run associates it
  cleanly.
- **ℹ️ merged·DoD-pending (FYI, not drift)** — card acks a merged PR but stays active because its
  live-DoD is genuinely pending; confirm the DoD is real, else archive.

## When `gh` is unavailable (graceful degrade)

If `gh` isn't installed / authenticated, or the repo can't be resolved from `git remote`, Check B is
skipped: the report prints `gh=UNAVAILABLE`, Check A (the pure-local internal-consistency check)
still runs, and the script exits 0 — it never crashes and never invents false drift from missing
machine data.

## Association caveat (read before trusting Check B)

Association vs `gh` is by the card's **explicit `MERGED #N` ack, NOT branch-slug**: branches are
often short while card slugs are full, so slug/title matching alone is blind. A merged wave whose
card has neither a `MERGED #N` ack nor a slug/alias hit to its divergently-named branch can't be
auto-associated — that relies on you writing the `MERGED #N` ack at merge (the script surfaces a
soft "verify" when a fuzzy core hit exists). The script also only parses **numbered** (`1.`) queue
rows, so a wave left only in a `-` bullet speed-view is not cross-checked — verify those by hand.

## After the report

This is observability, not auto-fix. On a DRIFT line: verify the PR is genuinely merged + the
live-DoD done, then hand-annotate the card with the `MERGED #N` ack and move the whole card to
`BACKLOG-archive.md`. Re-run to confirm the drift clears.
