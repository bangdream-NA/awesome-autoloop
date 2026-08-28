#!/usr/bin/env bash
# Fixtures for require-oplog-row-for-this-merge.sh — the self-contained op-log merge gate.
# Together with require-backlog-reconciled-before-merge.sh it SUPERSEDES the retired
# require-backlog-update-before-next-merge.sh (archived to hooks/_archived/ 2026-06-04:
# it failed-OPEN on a gh hiccup and only checked the PRIOR merge). This gate reads the PR#
# from the command itself (no gh call → cannot fail-open) and checks THE merge being run.
#
# 2026-06-11 contract (cross-wire fix): the project is resolved from the LAST `cd <dir>`
# in the command — a merge with NO cd is DENIED fail-closed (never defaults to example-project).
# AAL_OPLOG_DIR points the gate at a temp op-log so allow/deny are deterministic + portable.
# NOTE: this hook reads tool_input.command (NOT a top-level "command"), so payloads are wrapped.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-oplog-row-for-this-merge.sh

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
AAL_PROJ=/tmp/aal-fx-require-oplog-row-for-this-merge
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
# CLAUDE_PROJECT_DIR is exported so the gate ACTIVATES; the fail-closed arm below then unsets the
# op-log seam for its own invocation, which is the only variable its assertion is about.
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
# (historical note kept: the arm's subject is the cd-resolution, not activation.)
# 🔴 CLAUDE_PROJECT_DIR was briefly NOT exported here. This fixture's subject IS the
# resolution order: several arms assert that a merge command carrying NO `cd` fails CLOSED
# because no project can be resolved. Exporting the env var satisfies that resolution and
# turns those arms green for the wrong reason — the gate stops being asked the question.
# Every other arm here names "$AAL_PROJ" in its own payload `cd`, which the resolver
# accepts because the directory exists.
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


TMP=$(mktemp -d)
mkdir -p "$TMP/emptyproj"
printf '## wave foo\n- shipped X · proof #123\n' > "$TMP/autoloop-log-2026-06-04.md"

# assert_deny with one environment variable UNSET for that invocation only. Kept local rather than
# added to _lib.sh: that library is shared with the already-delivered fixtures, and widening a
# shared helper for one arm is how a fixture suite acquires a behaviour nobody reviewed.
assert_deny_env() {
  local desc="$1"; local unset_var="$2"; local input="$3"; local expect_sub="${4:-}"
  local out
  out=$(printf '%s' "$input" | env -u "$unset_var" bash "$HOOK" 2>&1 || true)
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    if [ -n "$expect_sub" ] && ! printf '%s' "$out" | grep -q "$expect_sub"; then
      FAIL=$((FAIL+1)); FAILURES+=("DENY-WRONG-REASON: $desc")
    else
      PASS=$((PASS+1))
    fi
  else
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY-BUT-ALLOWED: $desc (got: $(printf '%s' "$out" | head -c 120))")
  fi
}

export AAL_OPLOG_DIR="$TMP"

# routing: non-merge commands never gate
assert_allow "git status (not a merge)" '{"tool_input":{"command":"git status"}}'
assert_allow "gh pr view (not a merge)" '{"tool_input":{"command":"gh pr view 5 --json state"}}'

# 2026-06-11: a merge with NO `cd <project-dir>` anywhere → DENY fail-closed (no cross-wire default)
# `env -u AAL_OPLOG_DIR` is the whole point of this arm: the seam that makes the other arms
# deterministic is exactly what disables the branch under test here.
assert_deny_env "merge without any cd → fail-closed" "AAL_OPLOG_DIR" \
  '{"tool_input":{"command":"gh pr merge 123 --squash --delete-branch"}}' \
  "cannot resolve WHICH project"

# core op-log gate: logged PR# allow, unlogged deny (project resolved from the cd)
assert_allow "merge of LOGGED #123" \
  "{\"tool_input\":{\"command\":\"cd $TMP && gh pr merge 123 --squash --delete-branch\"}}"
assert_deny  "merge of UNLOGGED #999" \
  "{\"tool_input\":{\"command\":\"cd $TMP && gh pr merge 999 --squash --delete-branch\"}}" \
  "NO ledger row"

# item 5 (2026-06-04): implicit `gh pr merge` (no explicit PR#) must DENY — forbid the bypass
assert_deny  "implicit merge (no PR#)" \
  "{\"tool_input\":{\"command\":\"cd $TMP && gh pr merge --squash --delete-branch\"}}" \
  "write the PR number explicitly"

# portability: a repo with NO op-log convention → no-op (don't brick other repos), even implicit
export AAL_OPLOG_DIR="$TMP/empty"
assert_allow "no op-log convention → allow" \
  "{\"tool_input\":{\"command\":\"cd $TMP/emptyproj && gh pr merge 7 --squash\"}}"
assert_allow "no op-log + implicit merge → allow" \
  "{\"tool_input\":{\"command\":\"cd $TMP/emptyproj && gh pr merge\"}}"

rm -rf "$TMP" 2>/dev/null
summary
