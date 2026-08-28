#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCANNER="$REPO_ROOT/bin/sanitize-check.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

SENTINEL="zqxdevname"

TREE="$(mktemp -d "$HOME/.aal-sanci-XXXXXX")"; mkdir -p "$TREE/templates" "$TREE/.claude-plugin" "$TREE/.payloads"
printf '{ "name": "awesome-autoloop" }\n' > "$TREE/.claude-plugin/plugin.json"
printf 'this is a test runner for the suite\n' > "$TREE/templates/note.txt"
printf 'hello %s world\n' "$SENTINEL"          > "$TREE/templates/id.txt"
printf 'abab short check\n'                     > "$TREE/templates/short.txt"
printf 'near miss xqz token\n'                  > "$TREE/templates/escape.txt"
printf '{ "patterns": ["zqxleak[0-9]"], "deny": ["zqxdeny01","zqxdeny02"] }\n' > "$TREE/.payloads/wl.json"
WL_SYNTH="$TREE/.payloads/wl.json"
cleanup(){ rm -rf "$TREE"; }
trap cleanup EXIT

SCAN_WL=""
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
expect_pass() { local l="$1"; shift; scan "$@"
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree (MED-2 broke)"; halt; }
  if [ "$SCAN_RC" = 0 ]; then ok "$l"; else bad "$l — expected PASS(rc0), got rc=$SCAN_RC"; fi; }
expect_fail() { local l="$1"; shift; scan "$@"
  [ "$SCAN_ISO" = YES ] || { bad "$l — ISOLATION LEAK: scanner escaped the temp tree (MED-2 broke)"; halt; }
  if [ "$SCAN_RC" = 1 ]; then ok "$l"; else bad "$l — expected FAIL(rc1), got rc=$SCAN_RC"; fi; }

wl_control() {
  scan USER= USERNAME=
  if [ "$SCAN_WLHDR" = "$1" ]; then ok "[$LEG] CONTROL the wordlist state is the intended one [wordlist: $SCAN_WLHDR]"
  else bad "[$LEG] CONTROL expected header [$1], got [$SCAN_WLHDR] — the leg did not run the state it claims"; halt; fi
}

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
wl_control "$WL_SYNTH (patterns 1, deny 2, address-scoped 0)"
arms

echo ""
echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]
