#!/usr/bin/env bash
# Fixtures for backlog-sop-validate.mjs — the 12 cases from the SOP prompt. Each writes a ONE-entry
# temp board/archive/oplog, runs `--mode report` (AAL_NO_GH=1 → deterministic, no network), and
# asserts the finding lands in the right bucket. Proves: HARD blocks, DEBT is advisory-only,
# MERGED-marker → INFO, merged-without-marker → DRIFT, PR# is the identity key (not slug).
source "$(dirname "$0")/_lib.sh"

# --- portable activation + repo context ------------------------------------------
# Two things every mounted gate needs before it will judge anything, and both are absent in a
# bare temp dir:
#   1. an AUTOLOOP-MANAGED project — lib/activation.sh accepts `.claude/.autoloop` |
#      `.claude/BACKLOG.md` | `.claude/code-reviews.md` | a marked `.claude/CLAUDE.md`. Without it
#      the gate exits 0 in silence and every deny arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY
#      output — the fixture then measures the guard instead of the gate.
#   2. a resolvable GIT REPOSITORY — the commit/merge gates refuse fail-closed otherwise, and that
#      refusal lands on the ALLOW arms as "the git repository cannot be resolved".
# The path is a literal so single-quoted JSON payloads below can name it; it is created fresh and
# removed on EXIT, and the resolution order prefers a payload `cd` hint that actually exists.
# ⚠️ Being a literal, it is also NOT unique per run: two copies of THIS fixture running at the
# same time share the directory and the first one's EXIT trap removes it under the second.
# run-all.sh is sequential and each CI job runs one OS, so that does not arise there — but do
# not parallelise a single fixture against itself.
AAL_PROJ=/tmp/aal-fx-backlog-sop-validate
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------

VAL="$(cd "$(dirname "$0")/.." && pwd)"/backlog-sop-validate.mjs
TMP=$(mktemp -d); EMPTY="$TMP/empty.md"; : > "$EMPTY"

rc() { printf '%s\n' "$1" > "$TMP/bl.md"; AAL_NO_GH=1 AAL_BACKLOG="$TMP/bl.md" AAL_ARCHIVE="$EMPTY" AAL_OPLOG="$EMPTY" node "$VAL" --mode report 2>&1; }
ra() { printf '%s\n' "$1" > "$TMP/ar.md"; AAL_NO_GH=1 AAL_BACKLOG="$EMPTY" AAL_ARCHIVE="$TMP/ar.md" AAL_OPLOG="$EMPTY" node "$VAL" --mode report 2>&1; }
ro() { printf '%s\n' "$1" > "$TMP/op.md"; AAL_NO_GH=1 AAL_BACKLOG="$EMPTY" AAL_ARCHIVE="$EMPTY" AAL_OPLOG="$TMP/op.md" node "$VAL" --mode report 2>&1; }
want()   { if echo "$2" | grep -qE "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("$1: expected /$3/"); fi; }
absent() { if echo "$2" | grep -qE "$3"; then FAIL=$((FAIL+1)); FAILURES+=("$1: did NOT expect /$3/"); else PASS=$((PASS+1)); fi; }

# 1. Valid QUEUED card passes (no HARD / no DRIFT / no DEBT)
O=$(rc '### [QUEUED] R-valid-wave · P3
- aliases: r-valid-wave
- problem: something is broken
- fix: fix the thing
- log:
  - 2026-06-04T10:00Z · REGISTERED · lead · created from audit · proof=live /x 404 · next=plan')
want   "1 valid card → 0 active HARD"  "$O" '⛔ 0 ACTIVE-CARD HARD'
want   "1 valid card → 0 debt gaps"    "$O" '0 active-card field/marker gaps'
absent "1 valid card → no DRIFT line" "$O" '\[DRIFT\]'

# 2. Missing alias fails (HARD)
O=$(rc '### [QUEUED] R-no-alias · P3
- problem: x
- fix: y')
want "2 missing alias → HARD" "$O" '\[HARD\].*no aliases'

# 3. DONE in active BACKLOG fails (HARD)
O=$(rc '### [DONE] R-done-on-active · P3
- aliases: r-done-on-active')
want "3 [DONE] active → HARD" "$O" '\[HARD\].*status \[DONE\] not in'

# 4. references merged PR #466 but lacks the canonical MERGED marker → DRIFT
O=$(rc '### [REVIEW] R-audit-orphan-band-news-filter · P3
- aliases: r-audit-orphan-band-news-filter
- problem: orphan band news
- fix: render guard
- log:
  - merged #466 but no proper header marker')
want "4 merged ack, no DoD-pending → DRIFT" "$O" '\[DRIFT\].*MERGED #466.*NO DoD-pending'

# 5. canonical (MERGED #N @sha · DoD pending: …) marker → INFO (allowed), no DRIFT
O=$(rc '### [REVIEW] R-audit-orphan-band-news-filter · P3 (MERGED #466 @b131eb0 · DoD pending: Playwright walk)
- aliases: r-audit-orphan-band-news-filter
- problem: orphan band news
- fix: render guard
- log:
  - 2026-06-04T10:00Z · MERGED · lead · squash · proof=#466 @b131eb0 CI green branch-deleted yes · next=DoD walk')
want   "5 canonical marker → INFO" "$O" '\[INFO\].*MERGED #466 · DoD-pending'
absent "5 canonical marker → no DRIFT" "$O" '\[DRIFT\]'

# 6. PR# is the identity key, NOT slug: short branch feat/r-orphan-band-news vs full card name —
#    classified via marker #466, not by slug-matching the card name.
O=$(rc '### [REVIEW] R-audit-orphan-band-news-filter · P3 (MERGED #466 @b131eb0 · DoD pending: walk)
- aliases: r-audit-orphan-band-news-filter, orphan-band-news-viewall
- problem: x
- fix: y
- log:
  - 2026-06-04T10:00Z · MERGED · lead · m · proof=#466 @b131eb0 CI green branch-deleted yes · next=DoD')
want "6 matched by PR# #466 (not slug)" "$O" '\[INFO\].*R-audit-orphan-band-news-filter.*MERGED #466'

# 7. DEV_DELIVERED without tests evidence → HARD
O=$(rc '### [IN-DEV] R-devnotest · P3
- aliases: r-devnotest
- problem: x
- fix: y
- log:
  - 2026-06-04T10:00Z · DEV_DELIVERED · dev-x · shipped code @abc1234 · proof=builds · next=PR')
want "7 DEV_DELIVERED no tests → HARD" "$O" '\[HARD\].*DEV_DELIVERED missing tests'

# 8. PR_OPENED without PR number → HARD
O=$(rc '### [REVIEW] R-propenod · P3
- aliases: r-propenod
- problem: x
- fix: y
- log:
  - 2026-06-04T10:00Z · PR_OPENED · lead · pushed @abc1234 · proof=pushed head · next=reviewer')
want "8 PR_OPENED no PR# → HARD" "$O" '\[HARD\].*PR_OPENED missing PR number'

# 9. REVIEW_APPROVED without HEAD SHA → HARD
O=$(rc '### [REVIEW] R-revnosha · P3
- aliases: r-revnosha
- problem: x
- fix: y
- log:
  - 2026-06-04T10:00Z · REVIEW_APPROVED · reviewer-x · verdict APPROVED PR #5 · proof=looks good · next=merge')
want "9 REVIEW_APPROVED no HEAD SHA → HARD" "$O" '\[HARD\].*REVIEW_APPROVED missing HEAD SHA'

# 10. ARCHIVED entry missing DoD proof → HARD
O=$(ra '- **R-archived-no-dod** · DONE #100 @abc1234 — fixed the thing. [aliases: r-archived-no-dod]')
want "10 archive missing DoD → HARD" "$O" '\[HARD\].*archive.*missing DoD proof'

# 11. autoloop-log entry missing proof → HARD
O=$(ro '## 2026-06-04T10:00Z · R-x · MERGED
- wave: R-x
- pr: #5
- status: MERGED
- next: deploy')
want "11 oplog missing proof → HARD" "$O" '\[HARD\].*oplog.*missing proof'

# 12. autoloop-log entry missing next (status not DONE/ARCHIVED) → HARD; control: DONE w/o next OK
O=$(ro '## 2026-06-04T10:00Z · R-y · MERGED
- wave: R-y
- pr: #6
- status: MERGED
- proof: squashed @abc1234 CI green')
want "12 oplog missing next (MERGED) → HARD" "$O" '\[HARD\].*oplog.*missing next'
O=$(ro '## 2026-06-04T11:00Z · R-z · ARCHIVED
- wave: R-z
- status: ARCHIVED
- proof: moved to archive, DoD curl 404')
absent "12b oplog DONE/ARCHIVED w/o next → OK" "$O" 'missing next'

# ── FIXTURE UPDATE 2026-08-09 (the user approved red-test repair): EVERY pre-dispatch fixture card
# ── header below gained a `stage=` field. That single missing field is the whole cause of all 19
# ── reds in this file.
#
# WHY: the validator gained a STAGE precondition — a card must record which baton it is with
# BEFORE that baton is dispatched (planner, then plan-review, and so on down the pipeline), and
# `stage=` lives on the card HEADER. A card with no `stage=` is DENIED outright, and that denial
# BEFORE the alias / plan-review / ARCH_APPROVED checks these arms are actually about — so arms
# expecting a specific denial (pd3/pd4/pd5b/pd5d/pd5e/pd5f/pd6/pd16) were getting the stage denial
# instead, and arms expecting ALLOW were simply denied.
#
# WHICH STAGE: from `STAGE_FOR_ROLE` in lib/backlog-gate.mjs:524 — planner ['new','planning'],
# architect ['plan-ok','arch'], developer ['arch-ok','dev']. Each card below carries the FIRST
# legal stage for the role its arm dispatches, so no arm's subject is changed; the stage gate just
# stops standing in front of it.
#
# 📌 NOT touched: `stageLagsLastDispatch` (same file, :580) is inert here — it reads a role out of
# a `- log:` line via the pattern `· <name>-r?<digit>`, and none of these fixtures' log lines
# carry a `·`, so `prev` is '' and the predicate returns null. Verified by these arms passing.
# ============ pre-dispatch mode (PreToolUse Agent gate — validates ONLY the target card) ============
pd() { printf '%s\n' "$1" > "$TMP/bl.md"; printf '%s\n' "${3:-}" > "$TMP/plan-reviews.md"; echo "$2" | AAL_BACKLOG="$TMP/bl.md" AAL_PLAN_REVIEWS="$TMP/plan-reviews.md" node "$VAL" --mode pre-dispatch 2>&1; }
QCARD='### [QUEUED] R-foo · stage=new · P3
- aliases: r-foo
- problem: x
- fix: y'

# pd1. registered QUEUED card → planner ALLOW
O=$(pd "$QCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-foo","prompt":"plan R-foo, worktree feat/r-foo"}}')
absent "pd1 planner+registered → allow" "$O" 'permissionDecision'

# pd2. missing card → DENY
O=$(pd "$QCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-bar","prompt":"plan R-nonexistent-wave-zzz"}}')
want "pd2 missing card → deny" "$O" 'no active BACKLOG card matches'

# pd3. malformed card (no alias) → DENY
O=$(pd '### [QUEUED] R-foo · stage=new · P3
- problem: x' '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-foo","prompt":"plan R-foo"}}')
want "pd3 no alias → deny" "$O" 'no aliases'

# pd4. architect with NO plan-review verdict in plan-reviews.md → DENY
O=$(pd '### [QUEUED] R-foo · stage=plan-ok · P3
- aliases: r-foo
- problem: x
- fix: y' '{"tool_name":"Agent","tool_input":{"subagent_type":"architect","name":"arch-foo","prompt":"spec R-foo"}}')
want "pd4 arch no plan-review verdict → deny" "$O" 'NO APPROVED plan-review'

# pd5. architect WITH an APPROVED plan-review verdict in plan-reviews.md → ALLOW
O=$(pd '### [IN-DEV] R-foo · stage=plan-ok · P3
- aliases: r-foo
- problem: x
- fix: y' '{"tool_name":"Agent","tool_input":{"subagent_type":"architect","name":"arch-foo","prompt":"spec R-foo"}}' '## Plan review: R-foo @4a85fda — 2026-06-07
- **Verdict**: **APPROVED**')
absent "pd5 arch + plan-reviews APPROVED → allow" "$O" 'permissionDecision'

# pd5b. GAMING the gate: a SELF-WRITTEN "plan APPROVED @sha" BACKLOG line but NO plan-reviews verdict → DENY.
#       This is THE SOP-bypass fix (USER 2026-06-07): the marker the lead types no longer passes the gate.
O=$(pd '### [IN-DEV] R-foo · stage=plan-ok · P3
- aliases: r-foo
- problem: x
- fix: y
- log: plan APPROVED @4a85fda (typed by lead, no real plan-review ran)' '{"tool_name":"Agent","tool_input":{"subagent_type":"architect","name":"arch-foo","prompt":"spec R-foo"}}')
want "pd5b backfilled PLAN_APPROVED, no real verdict → deny" "$O" 'plan-review verdict'

# pd6. dev WITHOUT ARCH_APPROVED → DENY
O=$(pd '### [IN-DEV] R-foo · stage=arch-ok · P3
- aliases: r-foo
- problem: x
- fix: y
- log: plan APPROVED @4a85fda' '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","name":"dev-foo","prompt":"build R-foo"}}')
want "pd6 dev no ARCH_APPROVED → deny" "$O" 'NO ARCH_APPROVED'

# pd7. dev WITH ARCH_APPROVED → ALLOW
O=$(pd '### [IN-DEV] R-foo · stage=arch-ok · P3
- aliases: r-foo
- problem: x
- fix: y
- log: arch spec @c76ec66 accepted (architecture locked)' '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","name":"dev-foo","prompt":"build R-foo"}}')
absent "pd7 dev+ARCH_APPROVED → allow" "$O" 'permissionDecision'

# pd8. another project's (NO BACKLOG file = no board convention) → NO-OP allow
# (2026-07-10 semantics split: "no board convention" = MISSING file → allow; a READABLE but
# EMPTY board is the register-before-dispatch case and must DENY — see pd8b. The old fixture
# modeled "no board" as an empty FILE, which conflated the two — exactly the hole that let a
# planner dispatch card-less right after the board was archived to zero, the user-caught.)
O=$(echo '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-foo","prompt":"plan R-foo"}}' | AAL_BACKLOG="$TMP/no-such-dir/BACKLOG.md" node "$VAL" --mode pre-dispatch 2>&1)
absent "pd8 no board convention → no-op allow" "$O" 'permissionDecision'

# pd8b. board READABLE but ZERO active cards → DENY (register the card first)
O=$(echo '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-foo","prompt":"plan R-foo"}}' | AAL_BACKLOG="$EMPTY" node "$VAL" --mode pre-dispatch 2>&1)
want "pd8b empty active board → deny" "$O" 'ZERO active cards'

# pd9. migration debt on a DIFFERENT card must NOT deny the target wave
O=$(pd "$QCARD
### [REVIEW] R-other-debt · P3
- (no alias / no fields = debt on a different card)" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-foo","prompt":"plan R-foo"}}')
absent "pd9 debt on other card → target allow" "$O" 'permissionDecision'

# pd10. unrelated merged·DoD-pending card must NOT deny the target wave
O=$(pd "$QCARD
### [REVIEW] R-other-merged · P3 (✅ MERGED #466 @b131eb0 — DoD pending walk)
- aliases: r-other-merged" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-foo","prompt":"plan R-foo"}}')
absent "pd10 unrelated merged card → target allow" "$O" 'permissionDecision'

# ---- pre-dispatch stem/suffix compatibility (≥ require-wave-registered leniency, no sibling false-pos) ----
SCARD='### [QUEUED] R-foo-bar-baz · stage=new · P3
- aliases: r-foo-bar-baz
- problem: x
- fix: y'
# pd11. card R-foo-bar-baz, dispatch R-foo-bar-baz-r2 → ALLOW (suffix variant)
O=$(pd "$SCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-x","prompt":"plan R-foo-bar-baz-r2"}}')
absent "pd11 -r2 suffix variant → allow" "$O" 'permissionDecision'
# pd12. dispatch R-foo-bar-baz-phase2 → ALLOW
O=$(pd "$SCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-x","prompt":"plan R-foo-bar-baz-phase2"}}')
absent "pd12 -phase2 suffix variant → allow" "$O" 'permissionDecision'
# pd13. dispatch R-foo-bar-baz-dev → ALLOW
O=$(pd "$SCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-x","prompt":"plan R-foo-bar-baz-dev"}}')
absent "pd13 -dev suffix variant → allow" "$O" 'permissionDecision'
# pd14. unrelated SIBLING R-foo-bar-qux (diverges at last segment) → DENY
O=$(pd "$SCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-x","prompt":"plan R-foo-bar-qux"}}')
want "pd14 sibling R-foo-bar-qux → deny" "$O" 'no active BACKLOG card matches'

# --- multi-candidate priority: a SIBLING wave EARLIER on the board must NOT hijack the match
#     when the dispatch's TARGET (named first / via anchor) is a LATER card (the dev-adminmobile bug) ---
SIBBOARD='### [REVIEW] R-sib-ux-clarity · stage=arch-ok · P3 (✅ MERGED #468 @aa07bd8 · DoD pending: walk)
- aliases: r-sib-ux-clarity
- problem: x
- fix: y
### [IN-DEV] R-sib-mobile-resp · stage=arch-ok · P3
- aliases: r-sib-mobile-resp
- problem: x
- fix: y
- log: arch spec accepted/locked @deb7490'
# pd15. dev target named via `for wave **X**` anchor; sibling cited later → resolve TARGET → ALLOW
O=$(pd "$SIBBOARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","name":"dev-sibmobile","prompt":"You are the developer for wave **R-sib-mobile-resp**. Q5 note: R-sib-ux-clarity sequences after. Implement."}}')
absent "pd15 target(anchor)+earlier-sibling → allow (no board-order hijack)" "$O" 'permissionDecision'
# pd16. dev genuinely for the earlier sibling (which lacks arch) → still correctly DENY (no over-allow)
O=$(pd "$SIBBOARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","name":"dev-sibux","prompt":"You are the developer for wave **R-sib-ux-clarity**. Implement."}}')
want "pd16 dev for arch-less sibling → deny (right target, no over-allow)" "$O" 'NO ARCH_APPROVED'
# pd17. no anchor — TARGET is the FIRST prompt slug, sibling later → resolve TARGET → ALLOW
O=$(pd "$SIBBOARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"developer","name":"dev-x","prompt":"Develop R-sib-mobile-resp per spec. Related: R-sib-ux-clarity (sequences later)."}}')
absent "pd17 target(first-slug)+later-sibling → allow" "$O" 'permissionDecision'

# ============ pre-review mode (plan-reviewer Mode A + code-reviewer Mode B) ============
pr() { printf '%s\n' "$1" > "$TMP/bl.md"; echo "$2" | AAL_BACKLOG="$TMP/bl.md" node "$VAL" --mode pre-review 2>&1; }
PRDISP='{"tool_name":"Agent","tool_input":{"subagent_type":"plan-reviewer","name":"plan-reviewer-rev1","prompt":"Mode A plan review of wave R-rev1"}}'
CRDISP='{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"codereview-rev1","prompt":"Mode B PR code review of wave R-rev1"}}'

# --- plan-reviewer Mode A (reviews a COMMITTED PLAN; no PR needed) ---
# pr1. Mode A + plan FILE PATH → ALLOW
O=$(pr '### [IN-DEV] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: planner delivered, plan docs/product-specs/R-rev1-plan.md' "$PRDISP")
absent "pr1 Mode A + plan file → allow" "$O" 'permissionDecision'

# pr2. Mode A + plan @sha → ALLOW
O=$(pr '### [IN-DEV] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: plan @abc1234 (planner delivered)' "$PRDISP")
absent "pr2 Mode A + plan @sha → allow" "$O" 'permissionDecision'

# pr3. Mode A missing card → DENY
O=$(pr '### [QUEUED] R-other · P3
- aliases: r-other' '{"tool_name":"Agent","tool_input":{"subagent_type":"plan-reviewer","name":"pr-x","prompt":"Mode A plan review of R-nonexistent-zzz"}}')
want "pr3 Mode A missing card → deny" "$O" 'no active BACKLOG card matches the reviewer'

# pr4. Mode A missing plan artifact → DENY
O=$(pr '### [QUEUED] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y' "$PRDISP")
want "pr4 Mode A no plan artifact → deny" "$O" 'NO committed plan artifact'

# pr5. code-reviewer used for PLAN review → DENY (wrong type)
O=$(pr '### [IN-DEV] R-rev1 · P3
- aliases: r-rev1
- log: plan @abc1234' '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"cr","prompt":"Mode A plan review of R-rev1"}}')
want "pr5 code-reviewer for plan review → deny" "$O" 'use a plan-reviewer'

# pr6. plan-reviewer re-dispatch when card already says plan APPROVED @sha → ALLOW/no-op
O=$(pr '### [IN-DEV] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: plan APPROVED @4a85fda (plan-reviewer R2 Mode A)' "$PRDISP")
absent "pr6 Mode A re-dispatch (plan APPROVED) → allow" "$O" 'permissionDecision'

# --- code-reviewer Mode B (reviews an OPEN PR) ---
# pr7. Mode B + DEV_DELIVERED + PR #123 + head sha → ALLOW
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: DELIVERED @abc1234 (2 files, tests run); pushed → PR #123 @def5678' "$CRDISP")
absent "pr7 Mode B delivered+PR → allow" "$O" 'permissionDecision'

# pr8. Mode B delivered local but no PR → DENY
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: DELIVERED local @abc1234, PENDING push→PR' "$CRDISP")
want "pr8 Mode B local no PR → deny" "$O" 'no OPEN PR'

# pr9. Mode B, the card records an OPEN PR but no DEV_DELIVERED -> DENY.
# The card line carries the arrow form (`PR_OPENED -> PR #123`) because that is what this
# kit's gate counts as PR_OPENED; a bare `PR #123` is not matched, and with it the gate
# denies for a DIFFERENT reason ("no OPEN PR found"), which would make this arm pass while
# testing something else.
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: PR_OPENED → PR #123 @def5678 (review please)' "$CRDISP")
want "pr9 Mode B PR no DEV_DELIVERED → deny" "$O" 'lacks delivery proof'

# pr10. Mode B PR TBD → DENY
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: DELIVERED @abc1234; ## PR #TBD-rev1, push and PR still pending' "$CRDISP")
want "pr10 Mode B PR TBD (card) → deny" "$O" 'no OPEN PR'

# pr11. plan-reviewer used for CODE review → DENY (wrong type)
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- log: DELIVERED @abc1234; PR #123' '{"tool_name":"Agent","tool_input":{"subagent_type":"plan-reviewer","name":"pr","prompt":"Mode B PR code review of PR #123 R-rev1"}}')
want "pr11 plan-reviewer for code review → deny" "$O" 'use a code-reviewer'

# pr12. migration DELIVERED local @sha PENDING push→PR → DENY
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: dev-x DELIVERED local @abc1234 (2 files); PENDING push→PR→reviewer' "$CRDISP")
want "pr12 migration local pending push → deny" "$O" 'no OPEN PR'

# pr13. migration pushed feat/x → PR #123 @sha → ALLOW
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: pushed feat/r-rev1 → PR #123 @abc1234' "$CRDISP")
absent "pr13 migration pushed+PR → allow" "$O" 'permissionDecision'

# pr14. unrelated debt elsewhere must NOT deny the target
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: DELIVERED @abc1234; pushed → PR #123 @def5678
### [QUEUED] R-other-debt · P3
- (no alias, no fields = debt on a different card)' "$CRDISP")
absent "pr14 debt elsewhere → target allow" "$O" 'permissionDecision'

# pr15. non-reviewer agent in pre-review → NO-OP allow
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1' '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-x","prompt":"plan R-rev1"}}')
absent "pr15 non-reviewer → no-op allow" "$O" 'permissionDecision'

# pr16. all deny payloads JSON.parse (Mode-B missing-card deny)
O=$(pr '### [REVIEW] R-other · P3
- aliases: r-other' '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"cr","prompt":"Mode B PR code review of R-nonexistent-zzz"}}')
if echo "$O" | node -e "const d=require('fs').readFileSync(0,'utf8');JSON.parse(d)" 2>/dev/null; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("pr16 deny payload not valid JSON: $(echo "$O"|head -c 80)"); fi

# --- Mode B Path 2: dispatch-prompt proof (real PR#/PR-URL + pinned SHA), card NOT migrated ---
# Migration-debt card (alias only, NO DEV_DELIVERED) — proof lives in the dispatch prompt.
DEBTCARD='### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y'

# prB1. live-style PR #470 (PR URL + SHA in prompt), debt card → ALLOW
O=$(pr "$DEBTCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1-470","prompt":"FRESH code-reviewer (Mode B) for PR #470 of wave R-rev1. PR: https://github.com/example-org/example-project/pull/470 branch docs/x @cf2c99c. Review the diff."}}')
absent "prB1 Mode B PR-URL+SHA in prompt (debt card) → allow" "$O" 'permissionDecision'

# prB2. live-style PR #471 + pinned SHA 4e82f21 → ALLOW
O=$(pr "$DEBTCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1-471","prompt":"FRESH code-reviewer (Mode B) for PR #471 (R-rev1). PR: https://github.com/example-org/example-project/pull/471 pinned SHA 4e82f21. Review against origin/main."}}')
absent "prB2 Mode B PR #471 + pinned SHA → allow" "$O" 'permissionDecision'

# prB3. live-style PR #472 + pinned SHA c601a8d → ALLOW
O=$(pr "$DEBTCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1-472","prompt":"FRESH code-reviewer (Mode B) for PR #472 (R-rev1). https://github.com/example-org/example-project/pull/472 pinned SHA c601a8d. Review."}}')
absent "prB3 Mode B PR #472 + pinned SHA → allow" "$O" 'permissionDecision'

# prB4. PR# in prompt but NO pinned SHA → DENY
O=$(pr "$DEBTCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1","prompt":"Mode B code review of PR #123 for wave R-rev1. Review the diff please."}}')
want "prB4 Mode B PR# no SHA → deny" "$O" 'NO pinned HEAD SHA'

# prB5. #TBD + SHA in prompt → DENY (TBD never a real PR)
O=$(pr "$DEBTCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1","prompt":"Mode B review of PR #TBD for R-rev1, branch @abc1234def, will pin once opened."}}')
want "prB5 Mode B #TBD + SHA → deny" "$O" 'local-only / PR-TBD'

# prB6. local commit, no PR# in prompt → DENY (SHA alone is not an OPEN PR)
O=$(pr "$DEBTCARD" '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1","prompt":"Mode B review for wave R-rev1: committed locally @abc1234, pushing branch then opening the PR shortly."}}')
want "prB6 Mode B local SHA no PR# → deny" "$O" 'no OPEN PR'

# prB7. consistency: prompt PR# registered on a DIFFERENT card than the wave named → DENY
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
### [REVIEW] R-other-wave · P3
- aliases: r-other-wave
- log: pushed → PR #999 @def5678' '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"reviewer-rev1","prompt":"Mode B review of PR #999 @c0ffee1 for wave R-rev1."}}')
want "prB7 Mode B prompt PR# maps to other card → deny" "$O" 'inconsistent'

# pr17. FIX 2026-07-21 (§8 incidental-text): plan-reviewer Mode A brief that mentions
#       "Mode B" ONLY as a NEGATION ("you do NOT review code — that is code-reviewer,
#       Mode B") while citing its own plan-doc path -> ALLOW. The live false-DENY this
#       arm pins came from matching the mode token without reading the negation.
#       plan-doc path → ALLOW. Live false-DENY on the R-seo-gsc-hygiene planrev dispatch.
O=$(pr '### [IN-DEV] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: planner delivered, plan docs/product-specs/R-rev1-plan.md' '{"tool_name":"Agent","tool_input":{"subagent_type":"plan-reviewer","name":"planrev-neg","prompt":"Mode A plan review of wave R-rev1. Review docs/product-specs/R-rev1-plan.md @abc1234. You do NOT run F-gates and you do NOT review code (that is code-reviewer, Mode B). Scope: hollow ACs + scope leakage."}}')
absent "pr17 planrev negated Mode-B mention + plan doc → allow" "$O" 'permissionDecision'

# pr18. symmetric: code-reviewer Mode B brief mentioning "Mode A" ONLY as a negation → ALLOW
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- problem: x
- fix: y
- log: DELIVERED @abc1234 (2 files, tests run); pushed → PR #123 @def5678' '{"tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","name":"codereview-neg","prompt":"Mode B review of PR #123 @def5678 for wave R-rev1. This is NOT Mode A (the plan-doc review was already done by the plan-reviewer). Review the diff vs origin/main."}}')
absent "pr18 coderev negated Mode-A mention → allow" "$O" 'permissionDecision'

# pr19. affirmative "Mode B" for plan-reviewer STILL denies even with a plan-doc path cited
#       (anchor exemption must not become a silencer)
O=$(pr '### [REVIEW] R-rev1 · P3
- aliases: r-rev1
- log: DELIVERED @abc1234; PR #123' '{"tool_name":"Agent","tool_input":{"subagent_type":"plan-reviewer","name":"pr-aff","prompt":"Mode B code review of PR #123 for wave R-rev1; context plan docs/product-specs/R-rev1-plan.md. Review the diff."}}')
want "pr19 planrev affirmative Mode-B + plan doc → still deny" "$O" 'use a code-reviewer'

# --- pd5c-e. JSONL-FIRST plan-verdict via SHARED lib/plan-verdict.mjs (back-ported from kit 2026-07-10).
#     The jsonl lives at CLAUDE_DIR/reviews/index.jsonl where CLAUDE_DIR = dirname(AAL_BACKLOG) = $TMP.
JLARCH='{"tool_name":"Agent","tool_input":{"subagent_type":"architect","name":"arch-foo","prompt":"spec R-foo"}}'
JLCARD='### [IN-DEV] R-foo · stage=plan-ok · P3
- aliases: r-foo
- problem: x
- fix: y'
mkdir -p "$TMP/reviews"

# pd5c. a jsonl APPROVED row alone (empty monolith) → ALLOW (jsonl is machine-authoritative)
printf '%s\n' '{"plan":"R-foo","verdict":"APPROVED","mode":"A","round":1}' > "$TMP/reviews/index.jsonl"
O=$(pd "$JLCARD" "$JLARCH")
absent "pd5c jsonl APPROVED alone → allow" "$O" 'permissionDecision'

# pd5d. APPROVED r1 superseded by NEEDS_REVISION r2 → DENY (LAST matching row wins).
#       RED-proof for the shared-resolver refactor: the pre-refactor approved-only inline scan
#       false-ALLOWED this exact sequence (it matched the stale r1 APPROVED and never saw r2).
printf '%s\n' '{"plan":"R-foo","verdict":"NEEDS_REVISION","mode":"A","round":2}' >> "$TMP/reviews/index.jsonl"
O=$(pd "$JLCARD" "$JLARCH")
want "pd5d jsonl APPROVED then NEEDS_REVISION → deny (last wins)" "$O" 'NO APPROVED plan-review'

# pd5e. jsonl rejection beats a STALE monolith APPROVED (fallback is stricter-or-equal, never looser)
O=$(pd "$JLCARD" "$JLARCH" '## Plan review: R-foo @4a85fda — 2026-06-07
- **Verdict**: **APPROVED**')
want "pd5e jsonl rejected beats monolith APPROVED → deny" "$O" 'NO APPROVED plan-review'
rm -f "$TMP/reviews/index.jsonl"

# pd5f. a "wave"-keyed row with NO "plan" field is INVISIBLE to the resolver (plan-verdict.mjs
#       skips rows lacking r.plan) → DENY even though the verdict text says APPROVED. Contract
#       fixture for the 2026-07-16 drift: a bad dispatch-brief template made reviewers write
#       wave-keyed rows twice (mygo9th, ci-storerace) and the architect gate silently denied real
#       approvals. The write side is now gated at spawn (block-bare-agent.sh); this pins the READ
#       side's contract so a schema change that starts honoring "wave" fails loudly here.
printf '%s\n' '{"wave":"R-foo","verdict":"APPROVED","mode":"A","round":1}' > "$TMP/reviews/index.jsonl"
O=$(pd "$JLCARD" "$JLARCH")
want "pd5f wave-keyed (no plan field) APPROVED row → still deny (invisible to resolver)" "$O" 'NO APPROVED plan-review'
rm -f "$TMP/reviews/index.jsonl"

rm -rf "$TMP" 2>/dev/null
summary
