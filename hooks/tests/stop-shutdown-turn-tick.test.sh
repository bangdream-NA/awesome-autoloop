#!/usr/bin/env bash
# stop-shutdown-turn-tick — the clock the shutdown ledger runs on. It counts TURNS rather than
# seconds, because "has that agent had a chance to leave yet" is a question about turns; a wall clock
# would answer it differently on a fast session than on a slow one. Its whole effect is a number on
# disk, so that is what the arms read.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/stop-shutdown-turn-tick.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude" "$AAL_TMP/state"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
# 🔴 The counter lives in a state directory that defaults to the operator's configuration. Pointed at
# a sandbox: otherwise this fixture would advance the turn counter of whatever session is running,
# and the ledger that reads it decides whether an agent has had time to shut down.
export SHUTDOWN_LEDGER_STATE_DIR="$AAL_TMP_N/state"
trap 'rm -rf "$AAL_TMP"' EXIT

SID=11111111-2222-3333-4444-555555555555
OTHER=99999999-2222-3333-4444-555555555555
tick_of() { # $1 = session id
  node -e 'const {readFileSync}=require("fs");try{process.stdout.write(String(JSON.parse(readFileSync(process.argv[1],"utf8")).n));}catch{process.stdout.write("0");}' \
    -- "$AAL_TMP/state/shutdown-turn-tick-$1.json" 2>/dev/null || echo 0
}
p() { node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1]}))' -- "$1"; }
run() { p "$1" | bash "$HOOK" >/dev/null 2>&1; }
# -----------------------------------------------------------------------------------------------

# --- the counter starts at nothing and advances by one ---------------------------------------------
before="$(tick_of "$SID")"
run "$SID"
after="$(tick_of "$SID")"
if [ "$before" = "0" ] && [ "$after" = "1" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("FIRST-TICK: went from '$before' to '$after', expected 0 -> 1")
fi

run "$SID"; run "$SID"
after3="$(tick_of "$SID")"
if [ "$after3" = "3" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("THIRD-TICK: counter reads '$after3' after three turns")
fi

# --- each session counts its own turns ------------------------------------------------------------------
# A shared counter would let a busy session age out another session's pending shutdowns, which is
# exactly the judgement this number is used for.
run "$OTHER"
mine="$(tick_of "$SID")"; theirs="$(tick_of "$OTHER")"
if [ "$mine" = "3" ] && [ "$theirs" = "1" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("PER-SESSION: this session reads '$mine' and the other '$theirs', expected 3 and 1")
fi

# --- a payload with no session id does not crash, and does not touch anyone's count -----------------------
out="$(node -e 'process.stdout.write(JSON.stringify({}))' | bash "$HOOK" 2>&1)"; rc=$?
still="$(tick_of "$SID")"
if [ "$rc" -eq 0 ] && [ "$still" = "3" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-SID: rc=$rc and this session's counter now reads '$still' (out: $(printf '%s' "$out" | head -c 80))")
fi

# --- it is a counter, not a gate: it never speaks ----------------------------------------------------------
out="$(p "$SID" | bash "$HOOK" 2>&1)"
if [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SILENT: the tick printed something (got: $(printf '%s' "$out" | head -c 120))")
fi

# --- outside a project that runs the convention it does nothing at all ---------------------------------------
before="$(tick_of "$OTHER")"
CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" run "$OTHER"
after="$(tick_of "$OTHER")"
if [ "$before" = "$after" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE: the counter advanced ('$before' -> '$after') outside an autoloop project")
fi

summary
