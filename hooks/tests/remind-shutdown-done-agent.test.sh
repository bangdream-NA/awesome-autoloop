#!/usr/bin/env bash
# Fixtures for remind-shutdown-done-agent.sh — R-destructive-hooks-infer-instead-of-verify.
# Same mechanism + isolation shape as post-merge-cleanup-reminder.test.sh (§A-8).
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/remind-shutdown-done-agent.sh

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
AAL_PROJ=/tmp/aal-fx-remind-shutdown-done-agent
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

# 🔴 The payload carries a tool_response, because THIS kit's gate reads the merge outcome from the
# PostToolUse response rather than calling `gh`. The source fixture stubbed a `gh` binary
# (FAKE_GH_RESPONSE) for a gate that shelled out; a stub for a call this gate never makes leaves
# every fire-arm silent, and silence is what a correctly-skipped gate looks like too.
# $2 defaults to a merged-looking response; pass "" for the arms that must stay silent.
mkpayload() {
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"tool_response":"%s","session_id":"%s"}' \
    "$1" "${2-Merged pull request successfully (squash)}" "${CLAUDE_SESSION_ID:-s1}"
}

export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T07:17:38Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s1
assert_fires "real merge fires" "$(mkpayload "cd $PROJ_TMP && gh pr merge 865 --squash --delete-branch")" "PR #865"
[ -f "$TMP_TMPDIR/aal-shutdown-reviewer-s1-pr865.flag" ] || { FAIL=$((FAIL+1)); FAILURES+=("(a) sentinel not written on real merge"); }

export FAKE_GH_RESPONSE='{"state":"OPEN","mergedAt":null}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s2
assert_silent "advisory-failure (the PR did not merge) stays silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge 999 --squash --delete-branch" "failed to merge: not mergeable")"
[ -f "$TMP_TMPDIR/aal-shutdown-reviewer-s2-pr999.flag" ] && { FAIL=$((FAIL+1)); FAILURES+=("(b) sentinel WRONGLY written on failed merge"); }

assert_silent "incidental merged text, not a merge command" "$(mkpayload "echo already merged manually")"

export FAKE_GH_RESPONSE='{"state":"OPEN","mergedAt":null}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s4
assert_silent "retry setup: attempt 1 fails" "$(mkpayload "cd $PROJ_TMP && gh pr merge 700 --squash" "failed to merge: not mergeable")"
export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T08:00:00Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s4
assert_fires "retry: attempt 2 fires" "$(mkpayload "cd $PROJ_TMP && gh pr merge 700 --squash")" "PR #700"

export FAKE_GH_RESPONSE='' FAKE_GH_EXIT=1 CLAUDE_SESSION_ID=s5
assert_silent "the merge command itself failed → silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge 701 --squash" "error: could not resolve to a PullRequest")"

assert_silent "no resolvable PR number → silent" "$(mkpayload "cd $PROJ_TMP && gh pr merge --squash")"

export FAKE_GH_RESPONSE='{"state":"MERGED","mergedAt":"2026-07-17T08:00:00Z"}' FAKE_GH_EXIT=0 CLAUDE_SESSION_ID=s7
# NOT PORTED: an arm asserting silence when the merge command carries no leading `cd`. This
# kit's gate reads the PR number out of the command and the outcome out of the response; it
# has no `cd` requirement, and the source fixture's own note says the shape is unreachable
# anyway because a different gate refuses it first. Asserting it here would demand a rule
# this artifact does not have.

fake_gh_stop
rm -rf "$TMP_TMPDIR" "$PROJ_TMP" 2>/dev/null
unset TMPDIR FAKE_GH_RESPONSE FAKE_GH_EXIT CLAUDE_SESSION_ID
summary
