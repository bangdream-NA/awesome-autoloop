#!/usr/bin/env bash
# The helper that every ported fixture calls, tested against gate STUBS.
#
# `assert_allow` used to be satisfied by ABSENCE: `out=$(... || true)` and then "the output does
# not contain deny". A crashed gate, a gate that never ran, and a gate that printed nothing all
# scored PASS. `assert_deny` needs a POSITIVE match and so reddens correctly on a crash — the
# asymmetry is the defect, and it shipped to adopters in a shared library.
#
# Direction: this change makes the helper say PASS LESS often, so per gate-authoring §1 the
# load-bearing arm is the must-GREEN — G1, a well-behaved gate emitting `{}`. Without it, a fix
# that broke every allow arm in the suite would look like a success here.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# The library under test is a PARAMETER, so the RED-on-revert can point this fixture at an
# old-shaped copy without editing the shipped file. Editing the shipped file in place and
# splicing it by index is how a revert harness corrupts what it is measuring: a first attempt
# did exactly that and manufactured a U1 result that contradicted how the old predicate works.
LIB_UNDER_TEST="${AAL_LIB_UNDER_TEST:-$HERE/_lib.sh}"
STUBS="$(mktemp -d)"
trap 'rm -rf "$STUBS"' EXIT

mk() { printf '%s\n' "$2" > "$STUBS/$1"; chmod +x "$STUBS/$1"; }
mk crash.sh       '#!/usr/bin/env bash'$'\n''echo "TypeError: cannot read properties of undefined" >&2'$'\n''exit 1'
mk silent-ok.sh   '#!/usr/bin/env bash'$'\n''exit 0'
mk garbage.sh     '#!/usr/bin/env bash'$'\n''printf "not json at all"'
mk array.sh       '#!/usr/bin/env bash'$'\n''printf "[]"'
mk wellformed.sh  '#!/usr/bin/env bash'$'\n''printf "{}"'
mk verbose.sh     '#!/usr/bin/env bash'$'\n''echo "debug: reading board" >&2'$'\n''printf "{}"'
# The deny payload is written with a SINGLE-quoted printf so nothing needs escaping. The first
# version used a double-quoted printf with backslash-escaped quotes; through `mk`'s own quoting
# those became DOUBLE backslashes, the stub emitted `{\` and died, and U1 then passed for the
# wrong reason — rejected as not-JSON rather than detected as a deny. A stub whose output nobody
# checked is a fixture asserting something other than what its label says.
mk denies.sh      '#!/usr/bin/env bash'$'\n''printf "%s" '"'"'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub"}}'"'"''

# The same two verdicts, as ES MODULES. `bash` on one of these dies at `import:` with no deny
# token — indistinguishable from a gate that chose not to fire — so these arms are what keep the
# extension dispatch honest.
mk denies.mjs     '#!/usr/bin/env node'$'\n''process.stdout.write('"'"'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"stub mjs"}}'"'"')'
mk allows.mjs     '#!/usr/bin/env node'$'\n''process.stdout.write("{}")'
# The same denial, PRETTY-printed. Five shipped gates emit this shape, and the helper's matcher
# used to be pinned to the compact spelling, so those five read as ALLOW inside every fixture.
mk denies-pretty.sh '#!/usr/bin/env bash'$'\n''printf "%s" '"'"'{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "stub pretty" } }'"'"''

RESULT_PASS=0; RESULT_FAIL=0; NOTES=()

# Each arm runs assert_allow in a SUBSHELL against one stub and reads the helper's own verdict out
# of its PASS/FAIL counters, so the thing under test is the helper, not a re-implementation of it.
verdict() { # $1 = stub file -> prints PASS or FAIL
  (
    # shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
    HOOK="$STUBS/$1"
    # shellcheck source=/dev/null
    source "$LIB_UNDER_TEST"
    assert_allow "probe" '{"tool_name":"Bash","tool_input":{"command":"true"}}' >/dev/null 2>&1
    if [ "$FAIL" -gt 0 ]; then echo FAIL; else echo PASS; fi
  )
}

# assert_deny is the matcher's other consumer, and it is the one that risks a false GREEN: the
# helper says "deny seen" MORE often after the widening, so an arm proving it still WITHDRAWS on an
# allowing gate is what carries the change. verdict() above reads assert_allow; this reads assert_deny.
verdict_deny() { # $1 = stub file, $2 = reason substring -> prints PASS or FAIL
  (
    # shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
    HOOK="$STUBS/$1"
    # shellcheck source=/dev/null
    source "$LIB_UNDER_TEST"
    assert_deny "probe" '{"tool_name":"Bash","tool_input":{"command":"true"}}' "$2" >/dev/null 2>&1
    if [ "$FAIL" -gt 0 ]; then echo FAIL; else echo PASS; fi
  )
}

arm_deny() { # $1=label $2=stub $3=reason substring $4=expected verdict
  local got; got="$(verdict_deny "$2" "$3")"
  if [ "$got" = "$4" ]; then RESULT_PASS=$((RESULT_PASS+1)); printf '  ok    %-58s want=%s got=%s\n' "$1" "$4" "$got"
  else RESULT_FAIL=$((RESULT_FAIL+1)); printf '  FAIL  %-58s want=%s got=%s\n' "$1" "$4" "$got"; NOTES+=("$1"); fi
}

arm() { # $1=label $2=stub $3=expected verdict
  local got; got="$(verdict "$2")"
  if [ "$got" = "$3" ]; then RESULT_PASS=$((RESULT_PASS+1)); printf '  ok    %-58s want=%s got=%s\n' "$1" "$3" "$got"
  else RESULT_FAIL=$((RESULT_FAIL+1)); printf '  FAIL  %-58s want=%s got=%s\n' "$1" "$3" "$got"; NOTES+=("$1"); fi
}

echo "== must-RED: these all scored PASS before the fix =="
arm "R1 gate exits non-zero with a stack trace"      crash.sh      FAIL
arm "R3 gate prints something that is not JSON"      garbage.sh    FAIL
arm "R4 gate prints valid JSON that is not an OBJECT" array.sh     FAIL

echo "== must-GREEN: the arms that keep the fix from breaking the suite =="
arm "G1 well-behaved gate emitting {}"               wellformed.sh PASS
arm "G2 gate that logs to stderr but emits {}"       verbose.sh    PASS
# G3 is the arm that caught this helper being written too strictly. A shell gate allows by
# exiting 0 and printing NOTHING; a first version rejected that and reddened three CORRECT allow
# arms in block-autoloop-on-board-drift.test.sh. rc is what separates a silent allow from a
# crash, not the presence of output.
arm "G3 shell gate that allows by exiting 0 in silence" silent-ok.sh PASS

echo "== unchanged behaviour =="
arm "U1 a real deny is still a failed allow"         denies.sh     FAIL
# S1 checks the STUB, not the helper: U1 is only meaningful if the payload it feeds actually
# carries the deny token and actually parses. Without this, a broken stub gives U1 the right
# verdict for the wrong reason, which is how it read before.
if bash "$STUBS/denies.sh" | grep -q '"permissionDecision":"deny"' \
   && bash "$STUBS/denies.sh" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{JSON.parse(s);process.exit(0)}catch{process.exit(1)}})'; then
  RESULT_PASS=$((RESULT_PASS+1)); printf '  ok    %-58s\n' "S1 the deny stub really emits parseable JSON with the token"
else
  RESULT_FAIL=$((RESULT_FAIL+1)); printf '  FAIL  %-58s\n' "S1 the deny stub is malformed — U1 above is uninformative"; NOTES+=("S1")
fi

echo "== pretty-printed JSON: must-RED before the whitespace-tolerant matcher =="
arm      "W1 assert_allow sees the deny in pretty JSON"     denies-pretty.sh FAIL
arm_deny "W2 assert_deny accepts a pretty-printed denial"   denies-pretty.sh "stub pretty" PASS

echo "== and the arms that keep the widening honest =="
# W3 is the load-bearing one. A matcher that says "deny" for everything would turn W1/W2 green and
# every deny arm in the suite green with them; only an ALLOWING gate can show the matcher still
# discriminates. W4 keeps the compact spelling — the shape most gates emit — from being traded away.
arm_deny "W3 an allowing gate is still not a denial"        wellformed.sh    ""            FAIL
arm_deny "W4 the compact spelling is still recognised"      denies.sh        "stub"        PASS
# W5: the reason check must survive too, or a gate could deny for an unrelated cause and pass.
arm_deny "W5 a denial for the wrong reason still fails"     denies-pretty.sh "some-other-reason" FAIL

# S2 checks the STUB the way S1 does: W1/W2 only mean something if that payload really parses AND
# really carries the SPACED spelling. Had `mk` collapsed it to the compact form, both arms would
# have passed while proving nothing about the widening.
if bash "$STUBS/denies-pretty.sh" | grep -q '"permissionDecision": "deny"' \
   && ! bash "$STUBS/denies-pretty.sh" | grep -q '"permissionDecision":"deny"' \
   && bash "$STUBS/denies-pretty.sh" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{JSON.parse(s);process.exit(0)}catch{process.exit(1)}})'; then
  RESULT_PASS=$((RESULT_PASS+1)); printf '  ok    %-58s\n' "S2 the pretty stub is parseable and NOT compact-spelled"
else
  RESULT_FAIL=$((RESULT_FAIL+1)); printf '  FAIL  %-58s\n' "S2 the pretty stub is not the shape W1/W2 claim — both are uninformative"; NOTES+=("S2")
fi


echo "== interpreter dispatch: must-RED before aal_run_hook =="
arm      "M1 assert_allow runs an .mjs gate that allows"       allows.mjs       PASS
arm_deny "M2 assert_deny runs an .mjs gate that denies"        denies.mjs       "stub mjs"    PASS
# M3 is the load-bearing one: dispatching by extension must not make .mjs mean "allow". An
# `import` typo inside a real gate has to stay visible as a crash rather than becoming a pass.
arm      "M3 an .mjs gate that DENIES is still not an allow"   denies.mjs       FAIL

# S3 is S1's lesson applied to the .mjs stubs, and it is not hypothetical here: the first
# version of denies.mjs was a SyntaxError whose stack trace ECHOED the offending source line.
# That line held the deny JSON, assert_deny reads stderr too, and so M2 passed off a crash dump
# while M3 failed for the wrong reason. Both arms read green. rc is what tells them apart.
if node "$STUBS/denies.mjs" >/dev/null 2>&1 && node "$STUBS/allows.mjs" >/dev/null 2>&1 \
   && node "$STUBS/denies.mjs" 2>/dev/null | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.exit(j.hookSpecificOutput.permissionDecision==="deny"?0:1)}catch{process.exit(1)}})'; then
  RESULT_PASS=$((RESULT_PASS+1)); printf '  ok    %-58s\n' "S3 both .mjs stubs execute cleanly and emit real JSON"
else
  RESULT_FAIL=$((RESULT_FAIL+1)); printf '  FAIL  %-58s\n' "S3 an .mjs stub crashes — M1..M3 above are uninformative"; NOTES+=("S3")
fi

TOTAL=$((RESULT_PASS+RESULT_FAIL))
name="$(basename "$0")"
if [ "$RESULT_FAIL" -eq 0 ]; then
  echo "  $name: PASS ($RESULT_PASS/$RESULT_PASS) (arms run: $TOTAL)"
  exit 0
else
  echo "  $name: FAIL ($RESULT_PASS pass, $RESULT_FAIL fail) (arms run: $TOTAL)"
  for f in "${NOTES[@]}"; do echo "    - $f"; done
  exit 1
fi
