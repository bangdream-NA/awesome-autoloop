#!/usr/bin/env bash
# Fixtures for session-learnings.sh — the Stop hook. It emits {"decision":"block"}
# at most once per WINDOW per session (after the stop_hook_active loop guard).
# Stop hooks use decision:block (not permissionDecision), so custom asserts here.

source "$(dirname "$0")/_lib.sh"   # PASS/FAIL/FAILURES/summary
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/session-learnings.sh

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
AAL_PROJ=/tmp/aal-fx-session-learnings
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------

SID="test-sl-$$-${RANDOM:-x}"
STATE_FILE="$(dirname "$0")/../.state/session-learnings-${SID}.last"
rm -f "$STATE_FILE" 2>/dev/null || true

run()   { echo "$1" | bash "$HOOK" 2>&1 || true; }
check() { local desc="$1" out="$2" mode="$3"   # mode = block | silent
  if echo "$out" | grep -q '"decision":"block"'; then
    if [ "$mode" = block ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-SILENT-GOT-BLOCK: $desc"); fi
  else
    if [ "$mode" = silent ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-BLOCK-GOT-SILENT: $desc"); fi
  fi; }

# 🔴 The payloads are BUILT HERE, in plain assignments, and never written as `\"` inside a
# `"$( … )"` substitution. That construct is what made this fixture fail on macOS and nowhere else
# for three rounds with no utility error to point at: the macOS lane is the only one forced to
# stock bash 3.2 (see ci.yml), whose parser splits a command substitution containing escaped double
# quotes differently, so `check` received its arguments SHIFTED. The signature of that -- and the
# reason it reads as a gate defect rather than a quoting one -- is that the reported failures are
# logically impossible for the modes written below: `EXPECTED-SILENT-GOT-BLOCK` cannot be produced
# by an arm whose mode is `block`. When an assertion reports an outcome its own arguments forbid,
# suspect argument PASSING before the subject.
# The `'…'"$VAR"'…'` form carries no backslash at all, so every bash parses it identically.
P_FALSE='{"session_id":"'"$SID"'","stop_hook_active":false}'
P_TRUE='{"session_id":"'"$SID"'","stop_hook_active":true}'

# A: first fire of a fresh session → block (writes throttle timestamp)
check "first fire blocks" \
  "$(run "$P_FALSE")" block

# B: immediate re-fire within window → silent (throttled — the fix)
check "throttled re-fire is silent" \
  "$(run "$P_FALSE")" silent

# C: loop guard (stop_hook_active=true) → silent regardless
check "loop guard is silent" \
  "$(run "$P_TRUE")" silent

# D: WINDOW=0 env override → fires again (tunable)
check "window=0 override fires" \
  "$(SESSION_LEARNINGS_THROTTLE_SECS=0 bash -c "echo '$P_FALSE' | bash '$HOOK' 2>&1 || true")" block

rm -f "$STATE_FILE" 2>/dev/null || true
summary
