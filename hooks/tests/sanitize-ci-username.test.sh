#!/usr/bin/env bash
# sanitize-ci-username.test.sh — R-sanitize-ci-username-aware (arch §A-3).
#
# Locks the CI-aware guard on bin/sanitize-check.sh's dynamic-username augmentation — the `if` line
# that `grep -n 'CI:-' bin/sanitize-check.sh` returns second. That coordinate is named BY CONTENT and
# not by number on purpose: this header read `(:50)` while the guard had already moved to `:145`
# across four frames of that file, which is the identical defect §0.19 records for ci.yml:71.
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
#   PAIR-ID (AC2): tree has a planted sentinel username (a dev-identity-like string that no LOADED
#                  pattern matches). non-CI+USER=sentinel -> FAIL (protection preserved); CI=true+
#                  USER=sentinel -> PASS 0 (proves the sentinel is caught ONLY by the dynamic augment,
#                  never by the loaded set -> the RED is NON-VACUOUS; also documents the accepted
#                  CI-skip-even-for-a-real-name boundary, plan Edge-Cases :118-120).
#
# 🔴 EVERY ARM RUNS TWICE — once wordlist-free, once with a wordlist resolved (§A-13, F-31). The
#   reason is at the arm block near the bottom of this file; in one line: after the vocabulary moved
#   out of the scanner these arms all run in the configuration the hosted lanes run, and an exit-code
#   regression there would turn every one of them green while it asserted nothing.
#
# MED-1 (fixture false-RED trap): run-all.sh executes on the GitHub CI leg where CI=true is AMBIENT.
#   This is the FIRST hooks/tests fixture that reads the CI env, so every case is hermetic: `scan`
#   ALWAYS starts `env -u CI -u USER -u USERNAME` and re-adds ONLY what the case needs. A non-CI case
#   that forgot to scrub the ambient CI would false-RED (guard skips -> plant doesn't FAIL) on hosted.
# MED-2 (RED isolation + non-colliding sentinel): the scanner does `git rev-parse --show-toplevel ||
#   pwd`. Each scan runs it from a temp tree under $HOME (NOT mktemp inside the worktree, else git
#   resolves the REAL repo root and scans the real tree). $HOME is not a git repo on any supported
#   runner, so rev-parse fails -> pwd = the temp tree. SC-ISO aborts LOUD if a run ever writes its
#   report OUTSIDE the temp tree. The sentinel matches nothing in EITHER leg's wordlist — leg 1 has
#   none at all, leg 2's is synthetic and disjoint from this tree — so PAIR-ID's non-CI FAIL is
#   attributable to the augment alone in both.
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

SENTINEL="zqxdevname"   # >=3 chars, no regex metachar, matches nothing in either leg's wordlist.

# Build ONE isolated scan tree under $HOME (NOT inside the worktree — MED-2). Plants: a benign "runner"
# token (PAIR-FP), the sentinel (PAIR-ID), a 4-char "abab" (<3 boundary), a regex near-miss "xqz" (AC6
# escape). NONE of these strings match a loaded pattern (proven by SC-CLEAN on both legs below).
TREE="$(mktemp -d "$HOME/.aal-sanci-XXXXXX")"; mkdir -p "$TREE/templates" "$TREE/.claude-plugin" "$TREE/.payloads"
# The scanner is fail-closed on its resolved scan root: it refuses any tree that does not carry this
# repository's plugin manifest, so that running it from a stray directory cannot silently scan that
# directory. A fixture that deliberately points it at a synthesized tree must therefore mark that
# tree as a legitimate target. Content is inert to every arm (the project's own name is explicitly
# NOT a forbidden pattern).
printf '{ "name": "awesome-autoloop" }\n' > "$TREE/.claude-plugin/plugin.json"
printf 'this is a test runner for the suite\n' > "$TREE/templates/note.txt"
printf 'hello %s world\n' "$SENTINEL"          > "$TREE/templates/id.txt"
printf 'abab short check\n'                     > "$TREE/templates/short.txt"
printf 'near miss xqz token\n'                  > "$TREE/templates/escape.txt"
# A SYNTHETIC wordlist for LEG 2, written where no SCAN_PATHS entry reaches it. Its vocabulary is
# chosen to match NOTHING in the tree above, so a FAIL on leg 2 is still attributable to the runtime
# username augment alone — which is the property that makes the two legs comparable at all.
printf '{ "patterns": ["zqxleak[0-9]"], "deny": ["zqxdeny01","zqxdeny02"] }\n' > "$TREE/.payloads/wl.json"
WL_SYNTH="$TREE/.payloads/wl.json"
cleanup(){ rm -rf "$TREE"; }
trap cleanup EXIT

# scan <env assignments...> -> sets SCAN_RC + SCAN_ISO + SCAN_WLHDR. ALWAYS scrubs CI/USER/USERNAME
# first (MED-1), runs the REAL scanner from inside $TREE, then checks the report landed in $TREE
# (SC-ISO / MED-2).
#
# AAL_SANITIZE_WORDLIST is never INHERITED, for exactly the MED-1 reason CI is not: the scanner
# LOADS its forbidden-pattern set from that path, so an ambient value would silently decide which
# vocabulary every arm below measures. `scan` sets it explicitly or unsets it — SCAN_WL selects.
SCAN_WL=""          # "" = unset (the wordlist-free configuration); a path = resolved
scan() {
  if [ -n "$SCAN_WL" ]; then
    ( cd "$TREE" && env -u CI -u USER -u USERNAME AAL_SANITIZE_WORDLIST="$SCAN_WL" \
        "$@" bash "$SCANNER" >/dev/null 2>&1 ); SCAN_RC=$?
  else
    ( cd "$TREE" && env -u CI -u USER -u USERNAME -u AAL_SANITIZE_WORDLIST \
        "$@" bash "$SCANNER" >/dev/null 2>&1 ); SCAN_RC=$?
  fi
  if [ -f "$TREE/sanitization-report.txt" ]; then
    SCAN_ISO=YES
    SCAN_WLHDR=$(sed -n 's/^wordlist: //p' "$TREE/sanitization-report.txt")
  else SCAN_ISO=LEAK; SCAN_WLHDR=""; fi
  rm -f "$TREE/sanitization-report.txt"
}
# expect_pass/expect_fail <label> [env...] — assert scanner PASS(rc0)/FAIL(rc1) AND stayed isolated.
expect_pass() { local l="$1"; shift; scan "$@"
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree (MED-2 broke)"; halt; }
  if [ "$SCAN_RC" = 0 ]; then ok "$l"; else bad "$l — expected PASS(rc0), got rc=$SCAN_RC"; fi; }
expect_fail() { local l="$1"; shift; scan "$@"
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree (MED-2 broke)"; halt; }
  if [ "$SCAN_RC" = 1 ]; then ok "$l"; else bad "$l — expected FAIL(rc1), got rc=$SCAN_RC"; fi; }

# wl_control <expected header literal> — the DISCRIMINATING control for the leg that follows, and it
# runs FIRST. Every arm below is a comparison between two legs; if leg 2's path were mistyped the
# scanner would fall through to the wordlist-free branch and the two legs would agree TRIVIALLY —
# eleven arms reporting a clean match while measuring one configuration twice. The report header is
# the only surface that distinguishes them, which is the same reason F-21 exists.
wl_control() {
  scan USER= USERNAME=
  if [ "$SCAN_WLHDR" = "$1" ]; then ok "[$LEG] CONTROL the wordlist state is the intended one [wordlist: $SCAN_WLHDR]"
  else bad "[$LEG] CONTROL expected header [$1], got [$SCAN_WLHDR] — the leg did not run the state it claims"; halt; fi
}

# ---- the arm block. Run ONCE PER WORDLIST STATE, and both readings printed. ----------------------
# 🔴 WHY TWICE (§A-13's corrected absent-state exit column, F-31's must-red). The five expect_fail
# arms below assert that the scanner FAILS on a planted identity. After the wordlist moved out of
# bin/sanitize-check.sh they all run wordlist-free — the configuration all three hosted lanes run —
# and if absence alone ever forced exit 0 they would report PASS while asserting NOTHING.
# ⚠️ This is the one case 「count the arms before you read rc」 cannot catch: the arm count does not
# change, the arms execute, and they go green. So the discriminating check is not a count but a
# MUST-RED — with the wordlist RESOLVED the same five must still fail on the same payloads — and
# both readings are printed rather than one being inferred from the other.
arms() {
  echo "== SC-CLEAN [$LEG]: the isolated tree has ZERO static-pattern hits (so any FAIL below is the augment alone) =="
  expect_pass "[$LEG] SC-CLEAN non-CI, empty user -> PASS 0 (tree is static-clean; also proves SC-ISO isolation)" USER= USERNAME=

  echo "== PAIR-FP [$LEG] (AC1): the false-positive the wave fixes — identical 'runner' tree, CI is the only variable =="
  expect_fail "[$LEG] PAIR-FP.a non-CI + USER=runner -> FAIL (augment adds 'runner', matches the benign token — the FP)" USER=runner
  expect_pass "[$LEG] PAIR-FP.b CI=true + USER=runner -> PASS 0 (guard skips augment — the fix + RED->GREEN sentinel)" CI=true USER=runner
  expect_pass "[$LEG] PAIR-FP.c CI=true + USER=runneradmin (windows lane) -> PASS 0 (CI covers runneradmin, no whitelist)" CI=true USER=runneradmin

  echo "== PAIR-ID [$LEG] (AC2): protection-no-regress — planted sentinel (non-static), CI is the only variable =="
  expect_fail "[$LEG] PAIR-ID.a non-CI + USER=$SENTINEL -> FAIL (protection preserved OUTSIDE CI — the critical RED)" USER=$SENTINEL
  expect_pass "[$LEG] PAIR-ID.b CI=true + USER=$SENTINEL -> PASS 0 (sentinel is augment-only => RED non-vacuous; CI-skip boundary)" CI=true USER=$SENTINEL

  echo "== AC6 [$LEG]: precedence, <3-char boundary, regex-escape all preserved by the guard =="
  expect_fail "[$LEG] AC6 precedence: USERNAME wins over USER (USERNAME=$SENTINEL planted, USER=xyzzy absent) -> FAIL" USERNAME=$SENTINEL USER=xyzzy
  expect_pass "[$LEG] AC6 <3-char: non-CI USER=ab (2 chars, 'abab' present) -> PASS 0 (no augment, boundary intact)" USER=ab
  expect_fail "[$LEG] AC6 >=3-char: non-CI USER=abab (4 chars, 'abab' present) -> FAIL (augment runs at the boundary)" USER=abab
  expect_pass "[$LEG] AC6 regex-escape: non-CI USER=x.z (metachar) vs near-miss 'xqz' -> PASS 0 (the sed escaped '.')" USER=x.z

  echo "== guard reads NON-EMPTY CI [$LEG]: an empty CI value is treated as not-CI (matches GitHub's CI=true) =="
  expect_fail "[$LEG] CI='' (empty) + USER=runner -> FAIL (empty CI = local; \${CI:-} guards on non-empty)" CI= USER=runner
}

echo "########## LEG 1 of 2 — WORDLIST-FREE. This is what all three hosted lanes run. ##########"
LEG="wl-free"; SCAN_WL=""
wl_control "not configured"
arms

echo ""
echo "########## LEG 2 of 2 — WORDLIST RESOLVED. F-31's must-red for the absent-state exit column. ##########"
LEG="wl-resolved"; SCAN_WL="$WL_SYNTH"
wl_control "$WL_SYNTH (patterns 1, deny 2)"
arms

echo ""
echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]
