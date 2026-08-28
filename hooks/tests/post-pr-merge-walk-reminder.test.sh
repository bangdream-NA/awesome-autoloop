#!/usr/bin/env bash
# Fixtures for post-pr-merge-walk-reminder.sh — R-destructive-hooks-infer-instead-of-verify.
# Precondition (a real merge) is now VERIFIED via a stubbed `gh pr view --json state,mergedAt`,
# never inferred from tool_response text. Isolation (AC16): fake `gh` (zero network), a scratch
# AAL_HOOK_STATE_DIR (throttle sentinel) and AAL_WALKS_DIR (the .pending-pr sentinel that the LIVE
# check-unwalked-merges.sh Stop hook HARD-BLOCKS on — must never be armed by a fixture run), and
# a scratch PROJ_TMP (never assumes Z:/repo exists on the running machine).
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/post-pr-merge-walk-reminder.sh

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
AAL_PROJ=/tmp/aal-fx-post-pr-merge-walk-reminder
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


fake_gh_start
STATE_TMP=$(mktemp -d)
WALKS_TMP=$(mktemp -d)
PROJ_TMP=$(mktemp -d)
export AAL_HOOK_STATE_DIR="$STATE_TMP"
export AAL_WALKS_DIR="$WALKS_TMP"

mkpayload() { # $1=command  $2=session_id  $3=tool_response (default: a merged one)
  # 🔴 The response is part of the payload because THIS kit's gate reads the merge outcome from the
  # PostToolUse response (`merged|merging|squash|already merged`) rather than calling `gh`. The
  # source fixture stubbed a `gh` binary; against a gate that never shells out, every fire-arm goes
  # silent — and silence is also what a correctly-skipped gate produces, so the arms would pass
  # while measuring nothing.
  # ⚠️ tool_response is an OBJECT here, not a string: this gate reads `stdout|output|stderr` off it,
  # while its sibling post-merge-cleanup-reminder greps the response as a plain string. Two gates in
  # the same kit, two shapes — a fixture that guesses gets silence, which reads like a skipped gate.
  printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"%s"},"tool_response":{"stdout":"%s"}}' \
    "$2" "$1" "${3-Merged pull request successfully (squash)}"
}

# (a) true-positive: a real merge — fires, arms BOTH sentinels
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T07:17:38Z"}' FAKE_GH_EXIT=0
assert_fires "real merge fires" "$(mkpayload "cd $PROJ_TMP && gh pr merge 865 --squash --delete-branch" s1)" "PR #865"
[ -f "$STATE_TMP/walk-reminded-s1-pr865.flag" ] || { FAIL=$((FAIL+1)); FAILURES+=("(a) throttle sentinel not written on real merge"); }
[ -f "$WALKS_TMP/.pending-pr865" ] || { FAIL=$((FAIL+1)); FAILURES+=("(a) .pending-pr sentinel not written on real merge"); }

# (b) THE core of this wave: gh's own advisory-failure text contains "merged" — must NOT fire,
# must NOT touch either sentinel (Incident 1, PR #865 root cause, reproduced live by planrev r1).
export FAKE_GH_RESPONSE='{"state":"OPEN","mergedAt":null}' FAKE_GH_EXIT=0
assert_silent "a merge that did not land stays silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge 999 --squash --delete-branch" s2 "failed to merge: not mergeable")"
[ -f "$STATE_TMP/walk-reminded-s2-pr999.flag" ] && { FAIL=$((FAIL+1)); FAILURES+=("(b) throttle sentinel WRONGLY written on failed merge"); }
[ -f "$WALKS_TMP/.pending-pr999" ] && { FAIL=$((FAIL+1)); FAILURES+=("(b) .pending-pr sentinel WRONGLY armed on failed merge"); }

# (c) incidental "merged" text in a non-merge command → silent (§8 target-identification, unchanged)
assert_silent "incidental merged text, not a merge command" "$(mkpayload "echo already merged manually" s3)"

# AC15 fail-then-success-retry: attempt 1 fails (poisons nothing) → attempt 2, same PR, same
# session, real merge → still fires normally.
export FAKE_GH_RESPONSE='{"state":"OPEN","mergedAt":null}' FAKE_GH_EXIT=0
assert_silent "retry setup: attempt 1 fails" "$(mkpayload "cd $PROJ_TMP && gh pr merge 700 --squash" s4 "failed to merge: not mergeable")"
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T08:00:00Z"}' FAKE_GH_EXIT=0
assert_fires "retry: attempt 2 (real merge, same session/PR) fires" "$(mkpayload "cd $PROJ_TMP && gh pr merge 700 --squash" s4)" "PR #700"

# AC11: verification call itself fails (gh errors / unauthenticated / network) → silent, never
# falls back to "assume success".
export FAKE_GH_RESPONSE='' FAKE_GH_EXIT=1
assert_silent "the merge command itself failed -> silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge 701 --squash" s5 "error: could not resolve to a PullRequest")"

# Edge case: bare `gh pr merge` with no PR number — nothing to verify, stay silent.
assert_silent "no resolvable PR number → silent" "$(mkpayload "gh pr merge --squash --delete-branch" s6)"

# Edge case: no `cd` prefix at all — require-oplog-row-for-this-merge.sh already denies this
# pre-execution (§0.4), so staying silent here is not a functional regression.
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T08:00:00Z"}' FAKE_GH_EXIT=0
# NOT PORTED: an arm asserting silence when the merge command has no leading `cd`. This kit's
# gate takes the PR number from the command and the outcome from the response; it has no `cd`
# requirement, and the source fixture's own note says the shape is unreachable anyway because
# a different gate refuses it first.

# --- the event-name arms: a hook mounted on two events must echo the one it received -------───
# 🔴 WHY THESE ARMS ASSERT THE EXIT STATUS AND THE ONES ABOVE DO NOT.
# `assert_silent` runs the hook as `$(... || true)` and inspects ONLY the output. A hook that
# ABORTS with rc=1 and prints nothing is therefore byte-identical, to this fixture, to a hook
# that decided cleanly to stay quiet. Arm (f) above — "no resolvable PR number → silent" — was
# GREEN the whole time the hook was in fact crashing on every payload of that exact shape; the
# harness surfaced it as a bare `PostToolUse:Bash hook error / No stderr output`.
# Two independent defects made that possible, and each needs its own arm:
#   (1) target identification grepped the RAW command, so the phrase as DATA counted as a merge;
#   (2) the PR-number pipeline ran unguarded under `set -euo pipefail`, so a non-matching grep
#       exited 1 and took the script down BEFORE the guard written for that very case.
assert_clean_exit() { # $1=desc  $2=payload — silent AND rc=0, because either alone is not proof
  local out rc
  out=$(printf '%s' "$2" | bash "$HOOK" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-rc0-GOT-rc$rc: $1 (out: $(printf '%s' "$out" | head -c 120))")
  elif [ -n "$out" ]; then
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-SILENT-BUT-FIRED: $1 (got: $(printf '%s' "$out" | head -c 120))")
  else
    PASS=$((PASS+1))
  fi
}

# (h) THE PRODUCTION PAYLOAD — the exact command that produced the hook error on 2026-08-20.
# The phrase is the grep PATTERN, i.e. data. Verbatim except that the fixture builds its JSON
# with printf, so the payload carries no double quotes.
PROD_CMD=$'grep -rho \'gh pr merge [^`|;]*\' Z:/repo/.claude/autoloop-log-*.md Z:/repo/docs/runbooks/*.md 2>/dev/null | sort -u | head -6'
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-08-20T13:00:00Z"}' FAKE_GH_EXIT=0
assert_clean_exit "(h) production payload: the phrase is a grep PATTERN, not an invocation" "$(mkpayload "$PROD_CMD" s8)"

# (i) same shape, the phrase inside a quoted string — this is precisely what lib/merge-intent.sh
# was created to answer on 2026-08-09, and what this hook was still answering on its own.
assert_clean_exit "(i) phrase inside a quoted echo argument" "$(mkpayload 'echo \"gh pr merge --squash\"' s9)"

# (j) arm (f) again, this time reading the exit status — this is the one that was falsely green.
assert_clean_exit "(j) bare gh pr merge, no PR number → silent AND rc=0" "$(mkpayload "gh pr merge --squash --delete-branch" s10)"

# (k) MUST-GREEN CONTROL: the repair must not buy silence by making the hook inert. A real merge
# still fires, still arms both sentinels, and still exits 0.
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-08-20T13:05:00Z"}' FAKE_GH_EXIT=0
assert_fires "(k) control: a real merge still fires after the repair" "$(mkpayload "cd $PROJ_TMP && gh pr merge 1472 --squash --delete-branch" s11)" "PR #1472"
[ -f "$WALKS_TMP/.pending-pr1472" ] || { FAIL=$((FAIL+1)); FAILURES+=("(k) .pending-pr sentinel not written on real merge"); }

fake_gh_stop
rm -rf "$STATE_TMP" "$WALKS_TMP" "$PROJ_TMP" 2>/dev/null
unset AAL_HOOK_STATE_DIR AAL_WALKS_DIR FAKE_GH_RESPONSE FAKE_GH_EXIT
summary
