#!/usr/bin/env bash
# ACCEPT_PATTERNS in bin/sanitize-check.sh — the acceptance ledger for the pattern class.
#
# This mechanism makes findings DISAPPEAR, so it is the most dangerous kind of change to the
# instrument the reviewer runs. Three properties have to hold, and each has an arm:
#   1. an accepted coordinate is not reported, and IS published in the accepted-lines line
#   2. any OTHER line still fails — acceptance is per-coordinate, never per-file or per-pattern
#   3. an accepted coordinate that matches nothing is reported as `stale-accepted`
# Arm 3 is the one that keeps this from becoming a silencer: an acceptance that can rot quietly
# is indistinguishable from a deleted check.
#
# The tree and the vocabulary are both synthesized here, so this runs in CI with no external
# wordlist and cannot be affected by whatever the real one contains.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RULER="$(cd "$HERE/../.." && pwd)/bin/sanitize-check.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/hooks" "$T/bin" "$T/.claude-plugin"
cp "$RULER" "$T/bin/sanitize-check.sh"
# The ruler refuses fail-closed unless the scan root IS this repository, so the fixture tree has
# to carry the manifest that identifies it. That guard is deliberate; satisfying it is part of
# building a legitimate tree, not a way around it.
printf '{ "name": "awesome-autoloop" }\n' > "$T/.claude-plugin/plugin.json"
printf '{"patterns":["zqxidentity0[0-9]"],"deny":[]}\n' > "$T/wl.json"

# Two files, one identity-shaped hit each, at known coordinates.
printf 'line one\nline two\nzqxidentity07 lives here\n' > "$T/hooks/accepted.mjs"
printf 'line one\nzqxidentity07 lives here too\n'       > "$T/hooks/other.mjs"

PASS=0; FAIL=0; NOTES=()
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); NOTES+=("$1"); printf '  FAIL  %s — %s\n' "$1" "$2"; }

run() { # $1 = ACCEPT_PATTERNS value ; prints the report to stdout
  # NOTE: the ruler reads AAL_ACCEPT_PATTERNS with `${VAR-default}`, not `${VAR:-default}`, so an
  # explicitly EMPTY value means "accept nothing" rather than "fall back to the built-in list".
  # With `:-` the baseline arm silently ran against this repo's own identity coordinates.
  #
  # CI=1 is what the ruler itself keys the local-username pattern off, and this fixture is about
  # the acceptance ledger, not about OS-user detection — so the vocabulary here stays exactly the
  # one line the fixture wrote.
  ( cd "$T" && CI=1 AAL_SANITIZE_WORDLIST="$T/wl.json" AAL_ACCEPT_PATTERNS="$1" \
      AAL_SANITIZE_SCAN="hooks" bash "$T/bin/sanitize-check.sh" 2>&1 )
}
field() { printf '%s' "$1" | sed -n 's/^Findings by class: patterns \([0-9]*\) · cjk \([0-9]*\) · denylist \([0-9]*\) · stale-accepted \([0-9]*\)$/\1 \4/p'; }
accepted() { printf '%s' "$1" | sed -n 's/^Accepted lines:.*patterns \([0-9]*\) .*$/\1/p'; }

echo "== baseline: nothing accepted, both hits reported =="
O="$(run '')"
read -r P S <<<"$(field "$O")"
[ "${P:-x}" = "2" ] && ok "B1 both hits reported (patterns=2)" || bad "B1 both hits reported" "patterns=${P:-?}"
[ "${S:-x}" = "0" ] && ok "B2 nothing stale when nothing is accepted" || bad "B2 nothing stale" "stale=${S:-?}"

echo "== accepting ONE coordinate =="
O="$(run 'hooks/accepted.mjs:3')"
read -r P S <<<"$(field "$O")"
# A1 is the must-GREEN: the accepted line stops being a finding.
[ "${P:-x}" = "1" ] && ok "A1 accepted coordinate is no longer a finding (patterns=1)" || bad "A1 accepted drops out" "patterns=${P:-?}"
# A2 is the must-RED that keeps acceptance per-COORDINATE: the other file still fails. The report
# never echoes a matched line (CI logs are public), so the FILE list is the channel that carries
# it — and the accepted file must be absent from that same list.
printf '%s' "$O" | grep -qF 'hooks/other.mjs' && ! printf '%s' "$O" | grep -qF 'hooks/accepted.mjs' \
  && ok "A2 the OTHER hit still fails and the accepted file is gone from the list" \
  || bad "A2 other still fails" "files-with-findings did not read [other, not accepted]"
[ "$(accepted "$O")" = "1" ] && ok "A3 the acceptance is PUBLISHED, not silent" || bad "A3 published" "accepted=$(accepted "$O")"
[ "${S:-x}" = "0" ] && ok "A4 a matching acceptance is not stale" || bad "A4 not stale" "stale=${S:-?}"

echo "== an acceptance that matches nothing =="
O="$(run 'hooks/accepted.mjs:1')"
read -r P S <<<"$(field "$O")"
[ "${S:-x}" = "1" ] && ok "S1 a coordinate that matches nothing is stale-accepted" || bad "S1 stale detected" "stale=${S:-?}"
[ "${P:-x}" = "2" ] && ok "S2 and both real hits are still reported" || bad "S2 hits still reported" "patterns=${P:-?}"

# 🔴 S3 is the boundary of the stale rule, and it points the other way on purpose. A coordinate
# whose FILE is absent is UNJUDGEABLE, not rotten: every synthesized fixture tree lacks the files
# the built-in ledger names, and flagging them made each such tree report the whole ledger as
# stale — 4 phantom findings that made two unrelated fixtures red. Rot that matters (the line moved
# inside a file that IS scanned) is S1's job, and S1 stays red without this one.
echo "== an acceptance pointing at a file that does not exist =="
O="$(run 'hooks/no-such-file.mjs:3')"
read -r P S <<<"$(field "$O")"
[ "${S:-x}" = "0" ] && ok "S3 an absent file is unjudgeable, not stale" || bad "S3 absent file" "stale=${S:-?}"

# 🔴 The scan must be able to say "I failed" out loud. Before this guard existed, a pattern grep
# that died reported `patterns 0`, which is byte-identical to a clean tree — measured on this
# machine, where GNU grep 3.0 aborts on a multi-LITERAL case-insensitive -f set. The arm feeds an
# uncompilable pattern, which every grep rejects, and demands rc=2 plus the FATAL line.
# 🔴 The staleness question is only ASKED of a run whose vocabulary loaded. Without a wordlist the
# pattern arm carries one fallback term, so every identity coordinate misses for a reason that has
# nothing to do with the ledger. N1 is the must-GREEN for that suppression; S1 above is its
# control — the same non-matching coordinate IS stale the moment a vocabulary is present, so this
# cannot degrade into "never report stale".
echo "== staleness is not asked of an arm that did not run =="
O="$( cd "$T" && CI=1 AAL_ACCEPT_PATTERNS="hooks/accepted.mjs:3" \
        AAL_SANITIZE_SCAN="hooks" bash "$T/bin/sanitize-check.sh" 2>&1 )"
read -r P S <<<"$(field "$O")"
[ "${S:-x}" = "0" ] && ok "N1 no wordlist ⇒ no stale verdict on the pattern ledger" || bad "N1 no stale without vocabulary" "stale=${S:-?}"
printf '%s' "$O" | grep -qE 'arms? not configured' \
  && ok "N2 and the run still refuses to read as clean" \
  || bad "N2 unconfigured run is flagged" "no 'not configured' caveat in the report"

echo "== the pattern scan cannot fail silently =="
printf '{"patterns":["zqx[","zqxidentity0[0-9]"],"deny":[]}\n' > "$T/wl-bad.json"
O="$( cd "$T" && CI=1 AAL_SANITIZE_WORDLIST="$T/wl-bad.json" AAL_ACCEPT_PATTERNS="" \
        AAL_SANITIZE_SCAN="hooks" bash "$T/bin/sanitize-check.sh" 2>&1 )"
RC=$?
[ "$RC" = "2" ] && ok "F1 a failed scan exits 2, not 0/1" || bad "F1 failed scan exits 2" "rc=$RC"
printf '%s' "$O" | grep -q 'FATAL — the pattern scan FAILED' \
  && ok "F2 and says so, instead of printing a zero" \
  || bad "F2 FATAL line present" "no FATAL line in the report"
printf '%s' "$O" | grep -q '^Findings by class' \
  && bad "F3 no findings line is printed for a scan that did not run" "findings line present" \
  || ok "F3 no findings line is printed for a scan that did not run"

# 🔴 UNSCANNED_OK_LEDGER is the THIRD ledger in this ruler and the only one no fixture reached.
# It is also the most dangerous of the three: adding one filename to it turns `rc=2 FATAL` into
# `rc=0 PASS` over a tree where the file is still unread. Reaching the leg needs a DEFAULT scan
# inside a real git worktree — every arm above narrows the scan with AAL_SANITIZE_SCAN, and under a
# narrowed scan the leg skips itself by design.
echo "== the unscanned-tracked-file leg, and its exemption ledger =="
G="$(mktemp -d)"
trap 'rm -rf "$T" "$G"' EXIT
mkdir -p "$G/hooks" "$G/bin" "$G/.claude-plugin"
cp "$RULER" "$G/bin/sanitize-check.sh"
printf '{ "name": "awesome-autoloop" }\n' > "$G/.claude-plugin/plugin.json"
# BOTH vocabulary arms are populated here, unlike the narrowed-scan tree above: with an empty deny
# list the ruler correctly reports `PARTIAL PASS … authenticated nothing`, and U3c's whole point is
# that this run DOES authenticate the tree. Neither term occurs anywhere under $G.
printf '{"patterns":["zqxidentity0[0-9]"],"deny":["zqxdeny.invalid"]}\n' > "$G/wl.json"
printf 'benign\n' > "$G/hooks/x.mjs"
# The three files the built-in ledger names are tracked here too, so the staleness arm below counts
# only the entry IT adds. Without them the baseline already reads stale-accepted 3, and U4's number
# would not distinguish the audit working from the audit judging the wrong tree.
printf '* text=auto\n'              > "$G/.gitattributes"
printf 'sanitization-report.txt\n'  > "$G/.gitignore"
printf 'disable=SC1091\n'           > "$G/.shellcheckrc"
printf 'a tracked note at the root, outside every scan path\n' > "$G/stray-note.md"
git -C "$G" init -q -b main
git -C "$G" config user.email fixture@example.invalid
git -C "$G" config user.name fixture
git -C "$G" add .claude-plugin/plugin.json hooks/x.mjs stray-note.md .gitattributes .gitignore .shellcheckrc
git -C "$G" -c commit.gpgsign=false commit -qm seed
grun() { ( cd "$G" && CI=1 AAL_SANITIZE_WORDLIST="$G/wl.json" AAL_ACCEPT_PATTERNS="" \
             bash "$G/bin/sanitize-check.sh" 2>&1 ); }
# Every mutation prints its own receipt. An edit that silently misses produces a ruler that behaves
# exactly like the control, and that reads as "this ledger does nothing" — a false conclusion about
# the test, reached with a correct method. awk rather than `sed -i`, which is not portable to BSD.
add_entry() { # $1 = "<path>|<reason>" inserted into the ledger in $G's COPY of the ruler
  awk -v e="$1" '/^UNSCANNED_OK_LEDGER="/ { print; print e; next } { print }' \
    "$G/bin/sanitize-check.sh" > "$G/bin/mutated.sh"
  mv "$G/bin/mutated.sh" "$G/bin/sanitize-check.sh"
  grep -cxF "$1" "$G/bin/sanitize-check.sh"
}

O="$(grun)"; RC=$?
[ "$RC" = "2" ] && ok "U1 a tracked file outside every scan path is FATAL, not a silent zero" || bad "U1 unscanned file is fatal" "rc=$RC"
printf '%s' "$O" | grep -qF 'stray-note.md' && ok "U2 and the FATAL names the file" || bad "U2 FATAL names the file" "the path is absent from the output"

echo "== the exemption, which is what makes this ledger a silencer =="
E1="stray-note.md|a fixture note, deliberately outside every scan path"
[ "$(add_entry "$E1")" = "1" ] && ok "U3a the ledger mutation applied (1 entry added)" || bad "U3a mutation applied" "the entry is not in the copied ruler"
O="$(grun)"; RC=$?
[ "$RC" = "0" ] && ok "U3b one ledger entry turns the FATAL into a pass" || bad "U3b exemption passes" "rc=$RC"
printf '%s' "$O" | grep -q 'RESULT: PASS (0 findings)' && ok "U3c and the run reports a clean tree" || bad "U3c clean result" "no PASS line"
read -r P S <<<"$(field "$O")"
[ "${S:-x}" = "0" ] && ok "U3d a tracked exemption is not stale" || bad "U3d not stale" "stale=${S:-?}"

# 🔴 U4 is the audit this ledger did not have. Its two siblings both report `stale-accepted` when an
# entry stops matching; an UNSCANNED_OK entry whose file stopped being tracked exempts a file that
# is not there, and said nothing at all. The reading has to be exactly 1: the three real entries are
# tracked in this tree, so a 4 would mean the audit is judging a tree the ledger does not describe.
echo "== an exemption whose file is not tracked =="
E2="never-tracked.md|an entry left behind after the file it exempted was deleted"
[ "$(add_entry "$E2")" = "1" ] && ok "U4a the second mutation applied" || bad "U4a mutation applied" "the entry is not in the copied ruler"
O="$(grun)"; RC=$?
read -r P S <<<"$(field "$O")"
[ "${S:-x}" = "1" ] && ok "U4b a dead exemption is reported stale-accepted (exactly 1)" || bad "U4b dead exemption is stale" "stale=${S:-?} (a 4 would mean the three real entries were judged too)"
[ "$RC" = "1" ] && ok "U4c and the run fails rather than passing quietly" || bad "U4c run fails" "rc=$RC"

name="$(basename "$0")"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS) (arms run: $TOTAL)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail) (arms run: $TOTAL)"
  for f in "${NOTES[@]}"; do echo "    - $f"; done
  exit 1
fi
