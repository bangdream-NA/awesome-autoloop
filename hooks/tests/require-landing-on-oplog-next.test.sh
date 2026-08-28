#!/usr/bin/env bash
# require-landing-on-oplog-next — a ledger row that promises a next step without naming where it
# lands reads, to every later reader, as work already accounted for. The gate denies such a row and
# asks for a card, a PR, a date or a batch number inside the window the trigger word opened.
source "$(dirname "$0")/_lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HERE/../require-landing-on-oplog-next.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-require-landing-on-oplog-next
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT

# Rows are ASSEMBLED at run time from a stamp taken off the clock. Two reasons, both load-bearing:
# the row shape is anchored on a real date, so a hardcoded one ages out of the pattern; and a file
# that spells out a complete unlanded row is itself a ledger row as far as this gate is concerned,
# which makes such a fixture unwritable inside an installation.
STAMP="$(date -u +'%Y-%m-%d %H:%M')Z"
row() { printf -- '- %s · **%s**: %s\n' "$STAMP" "$1" "$2"; }
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:"/tmp/aal-fx/autoloop-log-2026-08.md",content:process.argv[1]}}))' -- "$1"; }
e() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:"/tmp/aal-fx/autoloop-log-2026-08.md",old_string:"x",new_string:process.argv[1]}}))' -- "$1"; }

ARROW='⇒'

# --- DENY: a promise with nowhere to land ---------------------------------------------------------
assert_deny "an arrow trigger with a bare promise" \
  "$(w "$(row 'gate false positive' "checked the predicate. $ARROW next step I fix it and re-run the suite")")" 'NEXT STEP with no landing'
assert_deny "the word next: as the trigger" \
  "$(w "$(row 'sentinel mounted' 'it reports on recovery. next: build the other two gates')")" 'NEXT STEP with no landing'
assert_deny "an -once … I will- promise" \
  "$(w "$(row 'config kept' 'dropped the label. once the API is back I will re-run those four workflows')")" 'NEXT STEP with no landing'
assert_deny "an Edit, not only a Write" \
  "$(e "$(row 'sentinel mounted' "reports on recovery. $ARROW next step, build the other two gates")")" 'NEXT STEP with no landing'

# --- ALLOW: the same promise, landed --------------------------------------------------------------
assert_allow "the window names a card" \
  "$(w "$(row 'gate false positive' "checked. $ARROW next step, fix it in R-widget-detail-gate")")"
assert_allow "the window names a PR" \
  "$(w "$(row 'config kept' "withdrawn. $ARROW once it is back I will merge #1229")")"
assert_allow "the window names a date" \
  "$(w "$(row 'observing' "set. $ARROW next step 2026-09-10, re-check the cron")")"
assert_allow "the window names a batch" \
  "$(w "$(row 'sweep started' "first pass done. $ARROW next step batch 7")")"

# --- ALLOW: the false-positive tax the gate deliberately does not charge ---------------------------
# An arrow is far more often a CONCLUSION than a promise. A predicate that fired on every arrow
# would make the ledger's own house style unwritable, so a clause with no future verb passes.
assert_allow "an arrow introducing a conclusion" \
  "$(w "$(row 'hypothesis refuted' "the control fired as well. $ARROW the cause is outside this repo")")"
assert_allow "an explicit non-action" \
  "$(w "$(row 'decided not to' "left alone without authorisation. $ARROW not doing this card; the reason is written down")")"
assert_allow "a past-tense row with no trigger" \
  "$(w "$(row 'variable withdrawn' 'the discriminator covers two machines')")"

# --- ALLOW: not a ledger row, and not a write ------------------------------------------------------
# The row shape is the entry condition: ordinary prose containing the same words is not a ledger
# entry, and holding it to a ledger's rules would deny half the documentation in the repo.
assert_allow "prose with a trigger but no row" \
  "$(w "Next round I do three things, and no card number anywhere.")"
assert_allow "the same text through Bash" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo next step, fix it"}}))')"

# --- the gate ships its own predicate self-test; run it and read its own counters ------------------
# The count is DERIVED from the output rather than hardcoded, so adding an arm there cannot silently
# shrink what this checks, while a failing arm or an empty run reddens here.
selftest_out="$(node "$HOOK" --self-test 2>&1)"; selftest_rc=$?
armtotal="$(printf '%s\n' "$selftest_out" | grep -cE '^(ok  |FAIL) ')"
armfail="$(printf '%s\n' "$selftest_out" | grep -cE '^FAIL ')"
if [ "$selftest_rc" -eq 0 ] && [ "$armtotal" -ge 1 ] && [ "$armfail" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("SELF-TEST: rc=$selftest_rc arms=$armtotal failing=$armfail (tail: $(printf '%s' "$selftest_out" | tail -c 120))")
fi

summary
