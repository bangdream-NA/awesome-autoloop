#!/usr/bin/env bash
# The `# doctor-dispatched:` line in hooks/stop-dispatcher.sh is NOT a comment — it is a REGISTRY.
# skills/claude-doctor/doctor.sh reads it with grep+sed to tell a hook that is DISPATCHED from the
# dispatcher apart from one that is genuinely UNMOUNTED. Two ways it goes wrong, and neither of them
# makes anything else fail:
#   1. a comment sweep deletes it     => claude-doctor reports every Stop check as unmounted
#   2. CHECKS gains or loses an entry => claude-doctor reports that one check as unmounted
# Both are silent. This fixture is the thing that turns them red.
#
# It exists because a LABEL is a sentence somebody has to remember to read, and the two sets were
# previously reconciled by hand. A hand check does not survive the next edit.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
DISP="$HOOKS_SRC/stop-dispatcher.sh"
DOCTOR="$(cd "$HOOKS_SRC/.." && pwd)/skills/claude-doctor/doctor.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

[ -f "$DISP" ] || { echo "  [FAIL] dispatcher not found: $DISP"; exit 1; }

# The two sets, each extracted the way its OWN consumer extracts it.
#  - marker: exactly the grep+sed doctor.sh:71 runs, so this arm tests the real read path.
#  - checks: the CHECKS=( ... ) array the dispatcher iterates.
marker_set() { grep -m1 '^# doctor-dispatched:' "$DISP" | sed 's@^# doctor-dispatched:@@' | tr ' ' '\n' | grep . | sort -u; }
checks_set()  { sed -n '/^CHECKS=(/,/^)/p' "$DISP" | sed '1d;$d' | tr -d ' \t' | grep . | sort -u; }

echo "== the dispatcher's registry and its CHECKS are the same set =="

M=$(marker_set); C=$(checks_set)
MN=$(printf '%s\n' "$M" | grep -c .); CN=$(printf '%s\n' "$C" | grep -c .)

[ "$MN" -gt 0 ] && ok "the '# doctor-dispatched:' registry line EXISTS and is non-empty ($MN entries)" \
  || bad "the registry line is missing or empty — claude-doctor will report every Stop check as unmounted"

[ "$CN" -gt 0 ] && ok "CHECKS=( ) parses and is non-empty ($CN entries)" \
  || bad "CHECKS=( ) did not parse — this fixture cannot judge anything (halt-worthy)"

if [ "$M" = "$C" ]; then
  ok "registry == CHECKS, same set ($MN == $CN)"
else
  bad "registry and CHECKS DIVERGE — only-in-registry: [$(comm -23 <(printf '%s\n' "$M") <(printf '%s\n' "$C") | tr '\n' ' ')] only-in-CHECKS: [$(comm -13 <(printf '%s\n' "$M") <(printf '%s\n' "$C") | tr '\n' ' ')]"
fi

# The consumer must actually be able to read it — an arm on the two sets alone would still pass if
# doctor.sh's own grep no longer matched the line's shape.
if [ -f "$DOCTOR" ]; then
  if grep -q "grep -m1 '\^# doctor-dispatched:'" "$DOCTOR"; then
    ok "claude-doctor still reads the registry with the shape this line is written in"
  else
    bad "claude-doctor's read of '# doctor-dispatched:' changed shape — the registry and its reader have drifted apart"
  fi
else
  bad "claude-doctor not found at $DOCTOR — the consumer half of this contract is unverifiable"
fi

echo ""
echo "-- must-RED: drop ONE entry from the registry and this fixture must go red --"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cp "$DISP" "$TMP/d.sh"
FIRST=$(printf '%s\n' "$C" | head -1)
# In-place `sed -i` has NO portable spelling: GNU wants no argument, BSD requires a backup suffix,
# and each rejects the other's form (`sed: 1: "…": invalid command code f` on macOS). Reading to a
# sibling and moving it back is portable and is the same conclusion sanitize-accept-patterns.test.sh
# already reached. The must-RED setup check below is what proves the substitution really applied.
sed "s@^\(# doctor-dispatched:.*\) $FIRST@\1@; s@^\(# doctor-dispatched:\) $FIRST @\1 @" "$TMP/d.sh" > "$TMP/d.sh.tmp" \
  && mv "$TMP/d.sh.tmp" "$TMP/d.sh"
RM=$(grep -m1 '^# doctor-dispatched:' "$TMP/d.sh" | sed 's@^# doctor-dispatched:@@' | tr ' ' '\n' | grep . | sort -u)
if [ "$RM" != "$C" ]; then
  ok "must-RED setup: '$FIRST' really was removed from the registry copy"
  if [ "$RM" = "$C" ]; then bad "must-RED: divergence NOT detected"; else ok "must-RED: the comparison DETECTS the dropped entry"; fi
else
  bad "must-RED setup: the removal did not apply — this arm proves nothing"
fi

echo ""
echo "-- must-RED: delete the registry line entirely (the comment-sweep case) --"
grep -v '^# doctor-dispatched:' "$DISP" > "$TMP/d2.sh"
GONE=$(grep -c '^# doctor-dispatched:' "$TMP/d2.sh" || true)
[ "$GONE" = "0" ] && ok "must-RED setup: the registry line is gone from the copy" || bad "must-RED setup: line still present"
EMPTY=$(grep -m1 '^# doctor-dispatched:' "$TMP/d2.sh" | sed 's@^# doctor-dispatched:@@' | tr ' ' '\n' | grep -c . || true)
[ "${EMPTY:-0}" = "0" ] && ok "must-RED: a deleted registry yields ZERO entries, which this fixture fails on" \
  || bad "must-RED: a deleted registry still yielded entries"

echo ""
echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]
