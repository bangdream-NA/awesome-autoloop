#!/usr/bin/env bash
# The GAP confession patterns in hooks/block-dod-verified-with-self-declared-gap.mjs.
#
# Direction: the source-language patterns were SUBTRACTED and three senses English did not have
# were ADDED — "is not the same as first-hand", "needs credentials this session does not have",
# and "to close that gap". A must-red only answers whether the subtraction broke the gate; a new
# confession pattern fails by OVER-firing on ordinary card prose, so each addition is a PAIR.
#
# Every payload carries `DoD-VERIFIED`, because the gate does nothing without it. That is what
# makes the GREEN arms informative: they are cards that DO claim VERIFIED and are still honest.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/block-dod-verified-with-self-declared-gap.mjs"
export AAL_GATE_DENIALS_OFF=1

PASS=0; FAIL=0; FAILURES=()

run() {
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:"/p/.claude/BACKLOG.md",content:process.argv[1]}}))' \
    "$1" | node "$HOOK" 2>&1
}
blocks() {
  local desc="$1"; local out; out="$(run "$2")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY: $desc (got: $(printf '%s' "$out" | head -c 140))"); fi
}
silent() {
  local desc="$1"; local out; out="$(run "$2")"
  if [ "$out" = "{}" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-SILENT: $desc (got: $(printf '%s' "$out" | head -c 220))"); fi
}

# --- D: each confession pattern is live on English card prose ---------------
blocks "D1 is-not-the-same-as-first-hand" \
  '### [DONE] R-c · DoD-VERIFIED — reading the published partition is not the same as actually walking the page'
blocks "D2 never actually observed" \
  '### [DONE] R-c · DoD-VERIFIED — I could not first-hand observe the redirect on the live host'
blocks "D3 credentials this session lacks" \
  '### [DONE] R-c · DoD-VERIFIED — the admin walk needs credentials this session has no access to'
blocks "D4 to close that gap" \
  '### [DONE] R-c · DoD-VERIFIED — to close that gap someone would have to run the ingest by hand'
blocks "D5 never really triggered" \
  '### [DONE] R-c · DoD-VERIFIED — the retry path was never really executed, only read'

# --- G: honest cards that still say VERIFIED --------------------------------
# G1 is the arm that fails if D1 is ever loosened to a bare "not the same as": comparing two
# artifacts is ordinary card prose and admits no gap at all.
silent "G1 comparing two artifacts, no gap admitted" \
  '### [DONE] R-c · DoD-VERIFIED — the published partition is not the same as the staging one, and both were walked first-hand'
# G2 is the arm for D3, and it is written to sit on the LEAD half of that pattern rather than
# beside it: it says `needs … credentials` and then says they were present. Drop the "does not
# have" tail from D3 and this arm goes red; a sentence that merely mentions credentials would not.
silent "G2 needs credentials, and they were present" \
  '### [DONE] R-c · DoD-VERIFIED — the admin walk needs credentials, and the elevated session already had them'
# G3 is the arm for D4: "gap" is ordinary vocabulary when the gap is CLOSED.
silent "G3 a gap that was closed, in the past tense" \
  '### [DONE] R-c · DoD-VERIFIED — the lastmod gap was closed and re-measured on the live index'

# --- controls ---------------------------------------------------------------
# C1: without DoD-VERIFIED the gate must not fire at all, even on the D1 sentence.
silent "C1 the D1 sentence with no VERIFIED token" \
  '### [REVIEW] R-c · reading the published partition is not the same as actually walking the page'
# C2 must-RED harness control: if this ever goes green, every D arm above is uninformative.
blocks "C2 harness control: a scope-narrowed token denies" \
  '### [DONE] R-c · DoD-VERIFIED (scope = only the delivered half; the rest is handed to another card)'

name="$(basename "$0")"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS) (arms run: $TOTAL)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail) (arms run: $TOTAL)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
