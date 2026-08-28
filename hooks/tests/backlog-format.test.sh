#!/usr/bin/env bash
set -u
# backlog-format reports which active cards are missing a canonical field. It must READ and never
# WRITE, and it must never invent a field the card did not carry.
#
# 🔴 W1 is the arm that matters most. The tool previously inserted `- problem: <TODO>` /
# `- fix: <TODO>` and wrote the board back, and that shape fails GREEN in the worst way: a card
# that was missing a field comes out carrying a well-formed one, so every reader downstream sees an
# answered field where there was none. W1 fails if a single byte of the board changes.
#
# 🔴 W3 is the other half. The board path used to fall back to a DISCOVERED project when neither an
# argument nor the env var was given — which is how a run aimed at a fixture board reaches a live
# one. The tool must refuse instead, so this arm asserts the refusal rather than a default.
#
# Self-locating: this exercises the copy that SHIPS, not whatever happens to be installed in the
# running user's home. Reading $HOME here is how a fixture reports on somebody else's file.
FMT="$(cd "$(dirname "$0")/.." && pwd)/backlog-format.mjs"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
run() { AAL_BACKLOG="$1" node "$FMT" "${@:2}" 2>&1; }
has()  { if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: want '$3' in: $(printf '%s' "$2" | head -c 200)"; fi; }
absent(){ if printf '%s' "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); echo "FAIL [$1]: must NOT have '$3'"; else PASS=$((PASS+1)); fi; }
rc_is() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: want rc=$3 got rc=$2"; fi; }

# --- W1  a card missing a field comes back UNCHANGED, byte for byte ----------------------------
printf '### [REVIEW] R-foo · P3\n- aliases: r-foo\n- log: pushed -> PR #1 @abc1234\n' > "$T/bl.md"
BEFORE=$(cat "$T/bl.md")
O=$(run "$T/bl.md"); RC=$?
AFTER=$(cat "$T/bl.md")
if [ "$BEFORE" = "$AFTER" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [W1 board unchanged]: the tool wrote to the board"; fi
absent "W1 no problem line invented" "$AFTER" '- problem:'
absent "W1 no fix line invented"     "$AFTER" '- fix:'
absent "W1 no placeholder invented"  "$AFTER" 'TODO'
has    "W1 reports the missing problem" "$O" 'missing: - problem:'
has    "W1 reports the missing fix"     "$O" 'missing: - fix:'
rc_is  "W1 rc says findings" "$RC" 1

# --- W2  a complete card is clean, rc=0 --------------------------------------------------------
printf '### [QUEUED] R-bar · P2\n- aliases: r-bar\n- problem: x\n- fix: y\n' > "$T/bl2.md"
O=$(run "$T/bl2.md"); RC=$?
has   "W2 reports clean" "$O" 'every one carries problem + fix'
rc_is "W2 rc clean" "$RC" 0

# --- W3  no board given => refuse; never fall back to a discovered one --------------------------
O=$(cd "$T" && node "$FMT" 2>&1); RC=$?
has   "W3 refusal names the fix" "$O" 'Pass the path explicitly'
rc_is "W3 refusal rc" "$RC" 2

# --- W4  --apply is refused rather than silently ignored ---------------------------------------
printf '### [REVIEW] R-qux · P3\n- aliases: r-qux\n- log: PR #9 @def5678 important prose here\n' > "$T/bl4.md"
B4=$(cat "$T/bl4.md")
O=$(run "$T/bl4.md" --apply); RC=$?
has   "W4 --apply refused" "$O" 'not supported'
rc_is "W4 --apply rc" "$RC" 2
if [ "$B4" = "$(cat "$T/bl4.md")" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [W4 --apply wrote anyway]"; fi

# --- W5  read-side aliases: a card expressing the concept under another name is COMPLETE --------
printf '### [IN-DEV] R-alias · P1\n- aliases: r-alias\n- issue: the symptom\n- remedy: the plan\n' > "$T/bl5.md"
O=$(run "$T/bl5.md"); RC=$?
has    "W5 alias counts as present" "$O" 'every one carries problem + fix'
rc_is  "W5 alias rc clean" "$RC" 0
absent "W5 alias card untouched" "$(cat "$T/bl5.md")" '- problem:'

# --- W6  only whitelisted statuses are examined ------------------------------------------------
printf '# preamble\n## archive\n- **R-old** · DONE #1 no fields\n### [DONE] R-bad · P3\n- aliases: r-bad\n### [BLOCKED] R-blk · P3\n- aliases: r-blk\n' > "$T/bl6.md"
O=$(run "$T/bl6.md")
has    "W6 BLOCKED (whitelisted) is examined" "$O" 'R-blk'
absent "W6 [DONE] non-whitelist skipped"      "$O" 'R-bad'
absent "W6 archive bullet skipped"            "$O" 'R-old'

# --- W7  a CRLF board is read without complaint and still not written --------------------------
printf '### [REVIEW] R-crlf · P3\r\n- aliases: r-crlf\r\n' > "$T/bl7.md"
B7=$(cat "$T/bl7.md")
run "$T/bl7.md" >/dev/null
if [ "$B7" = "$(cat "$T/bl7.md")" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [W7 CRLF board was written]"; fi

echo "──────────────────────────────────────────"
echo "backlog-format: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
