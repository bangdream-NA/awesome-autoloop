#!/usr/bin/env bash
# Fixtures for post-merge-cleanup-reminder.sh — R-destructive-hooks-infer-instead-of-verify.
# Same mechanism as post-pr-merge-walk-reminder.test.sh (§A-7); this hook's only extra state
# surface is its throttle sentinel, isolated via TMPDIR (was hardcoded /tmp — §0.1/§Y-3).
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/post-merge-cleanup-reminder.sh

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
AAL_PROJ=/tmp/aal-fx-post-merge-cleanup-reminder
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


fake_gh_start
TMP_TMPDIR=$(mktemp -d)
PROJ_TMP=$(mktemp -d)
export TMPDIR="$TMP_TMPDIR"

# 🔴 The payload carries a tool_response: this kit's gate reads the merge OUTCOME from the
# PostToolUse response (`merged|Merged|successfully`) instead of shelling out to `gh`. A fixture
# that stubs a `gh` the gate never calls leaves every fire-arm silent — and silence is exactly what
# a correctly-inert gate looks like, so the arms would pass for nothing.
# $2 defaults to a merged-looking response; pass a failure string for the silent arms.
mkpayload() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":"%s","session_id":"%s"}' \
    "$1" "${2-Merged pull request successfully (squash)}" "${CLAUDE_SESSION_ID:-s1}"
}

# FIXTURE UPDATE 2026-08-09 (the user approved red-test repair): the two `assert_fires` substrings were
# `PR #865` / `PR #700`, taken from the pre-slimming checklist text
# `POST-MERGE CHECKLIST for PR #${PR_NUM} in ${PROJ_DIR} ...` — the substring an arm quotes must
# `_retired/msg-archive-20260809/post-merge-cleanup-reminder.sh.orig:72`. The 2026-08-09 message
# come from the LIVE message; a later rewording of that line is a stale expectation in the
# dropping the literal `PR ` before the number. The hook FIRED correctly in both arms — `_lib.sh`'s
# `assert_fires` reported FIRED-WRONG-CONTENT, which is the fixture's expectation being stale, not
# a silence. Substrings are now `POST-MERGE #<N>`, quoted from the live line, and remain
# PR-number-specific so the retry arm still proves it is attempt 2 that fired, not attempt 1.
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T07:17:38Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s1
assert_fires "real merge fires" "$(mkpayload "cd $PROJ_TMP && gh pr merge 865 --squash --delete-branch")" "POST-MERGE CHECKLIST for PR #865"
[ -f "$TMP_TMPDIR/aal-post-merge-cleanup-s1-pr865.flag" ] || { FAIL=$((FAIL+1)); FAILURES+=("(a) sentinel not written on real merge"); }

export FAKE_GH_RESPONSE='{"state":"OPEN","mergedAt":null}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s2
assert_silent "a merge that did not land stays silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge 999 --squash --delete-branch" "failed to merge: not mergeable")"
[ -f "$TMP_TMPDIR/aal-post-merge-cleanup-s2-pr999.flag" ] && { FAIL=$((FAIL+1)); FAILURES+=("(b) sentinel WRONGLY written on failed merge"); }

assert_silent "incidental merged text, not a merge command" "$(mkpayload "echo already merged manually")"

export FAKE_GH_RESPONSE='{"state":"OPEN","mergedAt":null}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s4
assert_silent "retry setup: attempt 1 fails" "$(mkpayload "cd $PROJ_TMP && gh pr merge 700 --squash" "failed to merge: not mergeable")"
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T08:00:00Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s4
assert_fires "retry: attempt 2 fires" "$(mkpayload "cd $PROJ_TMP && gh pr merge 700 --squash")" "POST-MERGE CHECKLIST for PR #700"

export FAKE_GH_RESPONSE='' FAKE_GH_EXIT=1 CLAUDE_SESSION_ID=s5
assert_silent "the merge command itself failed -> silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge 701 --squash" "error: could not resolve to a PullRequest")"

assert_silent "no resolvable PR number → silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge --squash")"

export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T08:00:00Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s7
# NOT PORTED: an arm asserting silence when the merge command has no leading `cd`. This kit's
# gate takes the PR number from the command and the outcome from the response; it has no `cd`
# requirement, and the source fixture's own note says the shape is unreachable anyway because
# a different gate refuses it first.

# --- the event-name arms -------------------------------------------------------------------
# Production failure: `gh pr merge <N>` exited 1 because the branch was still checked out in a
# worktree (the merge itself had landed), so the PostToolUseFailure mount fired and the harness
# rejected the response: `Hook returned incorrect event name: expected 'PostToolUseFailure' but
# got 'PostToolUse'`. The hook is mounted on BOTH events and hard-coded one of them --
# and no arm's payload carried `hook_event_name` at all, so that dimension was absent from the
mkpayload_ev() { printf '{"tool_name":"Bash","hook_event_name":"%s","tool_input":{"command":"%s"},"tool_response":"Merged pull request successfully (squash)","session_id":"%s"}' "$1" "$2" "${CLAUDE_SESSION_ID:-s1}"; }

export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-08-20T14:00:00Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s8
assert_fires "E1 the event name follows the payload: PostToolUseFailure" \
  "$(mkpayload_ev PostToolUseFailure "cd $PROJ_TMP && gh pr merge 1472 --squash --delete-branch")" \
  '"hookEventName": "PostToolUseFailure"'

export CLAUDE_SESSION_ID=s9
assert_fires "E2 control: PostToolUse stays PostToolUse" \
  "$(mkpayload_ev PostToolUse "cd $PROJ_TMP && gh pr merge 1473 --squash --delete-branch")" \
  '"hookEventName": "PostToolUse"'

export CLAUDE_SESSION_ID=s10
assert_fires "E3 control: the field is absent, so it defaults to PostToolUse" \
  "$(mkpayload "cd $PROJ_TMP && gh pr merge 1474 --squash --delete-branch")" \
  '"hookEventName": "PostToolUse"'

# E4: the phrase as DATA. Same defect and same owner (lib/merge-intent.sh) as its sibling.
export CLAUDE_SESSION_ID=s11
assert_silent "E4 the phrase is only a grep pattern, not a merge" \
  "$(mkpayload "grep -rho 'gh pr merge 1472 --squash' Z:/x.md")"

fake_gh_stop
rm -rf "$TMP_TMPDIR" "$PROJ_TMP" 2>/dev/null
unset TMPDIR FAKE_GH_RESPONSE FAKE_GH_EXIT CLAUDE_SESSION_ID
summary
