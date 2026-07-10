#!/usr/bin/env bash
# sanitize-ci-username.test.sh — R-sanitize-ci-username-aware (arch §A-3).
#
# Locks the CI-aware guard on bin/sanitize-check.sh's dynamic-username augmentation (:50):
#   OUTSIDE CI -> augment runs  -> the runtime OS username STILL becomes a forbidden pattern
#                                  (protection-no-regress — AC2, the critical RED).
#   INSIDE  CI -> augment SKIPS -> the generic `runner`/`runneradmin` login is NOT flagged, so the
#                                  benign "runner" tokens across the tree do NOT FAIL (AC1).
#
# Two make-or-break pairs, each on an IDENTICAL isolated tree so the ONLY variable is the CI signal:
#   PAIR-FP (AC1): tree has a benign "runner" token. non-CI+USER=runner -> FAIL (reproduces the exact
#                  false-positive the wave fixes); CI=true+USER=runner -> PASS 0 (the guard). The delta
#                  is CI alone -> the guard is provably what flips FAIL->PASS. PAIR-FP.b is also the
#                  guard's RED->GREEN sentinel: it can pass ONLY if the CI guard is present.
#   PAIR-ID (AC2): tree has a planted sentinel username (a dev-identity-like string that NO static
#                  pattern matches). non-CI+USER=sentinel -> FAIL (protection preserved); CI=true+
#                  USER=sentinel -> PASS 0 (proves the sentinel is caught ONLY by the dynamic augment,
#                  never the static set -> the RED is NON-VACUOUS; also documents the accepted
#                  CI-skip-even-for-a-real-name boundary, plan Edge-Cases :118-120).
#
# MED-1 (fixture false-RED trap): run-all.sh executes on the GitHub CI leg where CI=true is AMBIENT.
#   This is the FIRST hooks/tests fixture that reads the CI env, so every case is hermetic: `scan`
#   ALWAYS starts `env -u CI -u USER -u USERNAME` and re-adds ONLY what the case needs. A non-CI case
#   that forgot to scrub the ambient CI would false-RED (guard skips -> plant doesn't FAIL) on hosted.
# MED-2 (RED isolation + non-colliding sentinel): the scanner does `git rev-parse --show-toplevel ||
#   pwd`. Each scan runs it from a temp tree under $HOME (NOT mktemp inside the worktree, else git
#   resolves the REAL repo root and scans the real tree). $HOME is not a git repo on any supported
#   runner, so rev-parse fails -> pwd = the temp tree. SC-ISO aborts LOUD if a run ever writes its
#   report OUTSIDE the temp tree. The sentinel matches NONE of the 21 static patterns, so PAIR-ID's
#   non-CI FAIL is attributable to the augment alone.
#
# Toolchain: bash only; bash-3.2-safe (portable constructs). Models the temp-dir idiom of
# deny-gate-crash-allow.test.sh / empty-board-and-comment-strip.test.sh. Each scanner run scans a
# ~4-file tree (sub-second); the whole fixture lands far under run-all.sh's 300s per-test budget.
# Run: bash hooks/tests/sanitize-ci-username.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCANNER="$REPO_ROOT/bin/sanitize-check.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

SENTINEL="zqxdevname"   # >=3 chars, no regex metachar, matches NONE of the 21 static PATTERNS.

# Build ONE isolated scan tree under $HOME (NOT inside the worktree — MED-2). Plants: a benign "runner"
# token (PAIR-FP), the sentinel (PAIR-ID), a 4-char "abab" (<3 boundary), a regex near-miss "xqz" (AC6
# escape). NONE of these strings match a static pattern (proven by SC-CLEAN below).
TREE="$(mktemp -d "$HOME/.aal-sanci-XXXXXX")"; mkdir -p "$TREE/templates"
printf 'this is a test runner for the suite\n' > "$TREE/templates/note.txt"
printf 'hello %s world\n' "$SENTINEL"          > "$TREE/templates/id.txt"
printf 'abab short check\n'                     > "$TREE/templates/short.txt"
printf 'near miss xqz token\n'                  > "$TREE/templates/escape.txt"
cleanup(){ rm -rf "$TREE"; }
trap cleanup EXIT

# scan <env assignments...> -> sets SCAN_RC + SCAN_ISO. ALWAYS scrubs CI/USER/USERNAME first (MED-1),
# runs the REAL scanner from inside $TREE, then checks the report landed in $TREE (SC-ISO / MED-2).
scan() {
  ( cd "$TREE" && env -u CI -u USER -u USERNAME "$@" bash "$SCANNER" >/dev/null 2>&1 ); SCAN_RC=$?
  if [ -f "$TREE/sanitization-report.txt" ]; then SCAN_ISO=YES; else SCAN_ISO=LEAK; fi
  rm -f "$TREE/sanitization-report.txt"
}
# expect_pass/expect_fail <label> [env...] — assert scanner PASS(rc0)/FAIL(rc1) AND stayed isolated.
expect_pass() { local l="$1"; shift; scan "$@"
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree (MED-2 broke)"; halt; }
  if [ "$SCAN_RC" = 0 ]; then ok "$l"; else bad "$l — expected PASS(rc0), got rc=$SCAN_RC"; fi; }
expect_fail() { local l="$1"; shift; scan "$@"
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree (MED-2 broke)"; halt; }
  if [ "$SCAN_RC" = 1 ]; then ok "$l"; else bad "$l — expected FAIL(rc1), got rc=$SCAN_RC"; fi; }

echo "== SC-CLEAN: the isolated tree has ZERO static-pattern hits (so any FAIL below is the augment alone) =="
expect_pass "SC-CLEAN non-CI, empty user -> PASS 0 (tree is static-clean; also proves SC-ISO isolation)" USER= USERNAME=

echo "== PAIR-FP (AC1): the false-positive the wave fixes — identical 'runner' tree, CI is the only variable =="
expect_fail "PAIR-FP.a non-CI + USER=runner -> FAIL (augment adds 'runner', matches the benign token — the FP)" USER=runner
expect_pass "PAIR-FP.b CI=true + USER=runner -> PASS 0 (guard skips augment — the fix + RED->GREEN sentinel)" CI=true USER=runner
expect_pass "PAIR-FP.c CI=true + USER=runneradmin (windows lane) -> PASS 0 (CI covers runneradmin, no whitelist)" CI=true USER=runneradmin

echo "== PAIR-ID (AC2): protection-no-regress — planted sentinel (non-static), CI is the only variable =="
expect_fail "PAIR-ID.a non-CI + USER=$SENTINEL -> FAIL (protection preserved OUTSIDE CI — the critical RED)" USER=$SENTINEL
expect_pass "PAIR-ID.b CI=true + USER=$SENTINEL -> PASS 0 (sentinel is augment-only => RED non-vacuous; CI-skip boundary)" CI=true USER=$SENTINEL

echo "== AC6: precedence, <3-char boundary, regex-escape all preserved by the guard =="
expect_fail "AC6 precedence: USERNAME wins over USER (USERNAME=$SENTINEL planted, USER=xyzzy absent) -> FAIL" USERNAME=$SENTINEL USER=xyzzy
expect_pass "AC6 <3-char: non-CI USER=ab (2 chars, 'abab' present) -> PASS 0 (no augment, boundary intact)" USER=ab
expect_fail "AC6 >=3-char: non-CI USER=abab (4 chars, 'abab' present) -> FAIL (augment runs at the boundary)" USER=abab
expect_pass "AC6 regex-escape: non-CI USER=x.z (metachar) vs near-miss 'xqz' -> PASS 0 (sed :51 escaped '.')" USER=x.z

echo "== guard reads NON-EMPTY CI: an empty CI value is treated as not-CI (matches GitHub's CI=true) =="
expect_fail "CI='' (empty) + USER=runner -> FAIL (empty CI = local; \${CI:-} guards on non-empty)" CI= USER=runner

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
