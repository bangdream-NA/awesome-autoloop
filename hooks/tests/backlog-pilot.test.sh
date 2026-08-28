#!/usr/bin/env bash
# backlog-pilot — the end-of-turn reading of the board: what is owed, what could be opened, and what
# nothing may touch. It runs as a Stop hook and, on demand, as a command. The two arms that matter
# most are the quiet ones: a board with nothing actionable has to end the turn in silence, and a
# reading it cannot complete has to say so rather than report an empty board.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HOOKS_DIR/backlog-pilot.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude/reviews" "$AAL_TMP/home/.claude/hooks/.state"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
aal_pin_project "$REPO_N"
# HOME holds the state directory this reads and writes; pointed at the sandbox so the run neither
# inherits the operator's caches nor leaves entries in them.
export HOME="$AAL_TMP_N/home"
export USERPROFILE="$AAL_TMP_N/home"
trap 'rm -rf "$AAL_TMP"' EXIT

BOARD_NAME="$(printf '%s%s' 'BACK' 'LOG.md')"
BOARD="$REPO/.claude/$BOARD_NAME"
BOARD_N="$REPO_N/.claude/$BOARD_NAME"
export AAL_BACKLOG="$BOARD_N"

H='###'
card() { printf '%s [%s] %s · P%s\n' "$H" "$1" "$2" "${3:-1}"; }
board() { printf '%s\n\n%s\n' '# board' "$1" > "$BOARD"; }
p() { node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))'; }
# Every arm skips the merge scan: it shells out to git and gh over a real remote, which a fixture has
# neither of — and asking anyway would make the result depend on the network.
# stderr is kept OUT of the capture: the verdict is JSON on stdout, and folding the two together
# turns any diagnostic the tool writes into malformed output — a fixture defect that reads exactly
# like a broken tool. The error arms below capture stderr deliberately, and only there.
cli() { node "$TOOL" --board "$BOARD_N" --no-merge-scan "$@" 2>/dev/null; }
# -----------------------------------------------------------------------------------------------

# --- the command form: a board it can read, rendered ---------------------------------------------------
board "$(card QUEUED R-widget)"
out="$(cli)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI: rc=$rc out='$(printf '%s' "$out" | head -c 140)'")
fi
# …and as a machine-readable verdict, which is what anything downstream would consume.
out="$(cli --json)"
if printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.exit(Array.isArray(j.owed)&&Array.isArray(j.candidates)?0:1)}catch{process.exit(1)}})'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-JSON: the verdict is not an object carrying owed and candidates")
fi
# A queued card with nobody on it is a candidate to open — the reading that makes the pilot useful.
out="$(cli --json)"
if printf '%s' "$out" | grep -q 'R-widget'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CANDIDATE: the queued card is not in the verdict (got: $(printf '%s' "$out" | head -c 160))")
fi

# --- a board it cannot read is an ERROR, not an empty board ----------------------------------------------
# The two are indistinguishable in the answer and mean opposite things: one says there is nothing to
# do, the other says nobody knows.
out="$(node "$TOOL" --board "$REPO_N/.claude/no-such-board.md" --no-merge-scan 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'cannot read'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-MISSING: rc=$rc out='$(printf '%s' "$out" | head -c 140)'")
fi
out="$(node "$TOOL" --board 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'usage'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("CLI-NO-ARG: rc=$rc out='$(printf '%s' "$out" | head -c 140)'")
fi

# --- the Stop form: an empty board it COULD NOT fully read is not an empty board ----------------------------
# 🔴 A fixture has no remote, so the merge scan cannot run — and the pilot's contract is that a
# reading it could not complete is never reported as "nothing is owed". It speaks, and what it says
# has to name the gap. Asserting silence here would have pinned the opposite of the contract:
# the quiet answer and the "I could not look" answer mean opposite things.
board ''
out="$(p | node "$TOOL" 2>&1)"
if printf '%s' "$out" | grep -q 'UNAVAILABLE' && printf '%s' "$out" | grep -q 'NOT evidence'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("STOP-UNAVAILABLE: an unreadable merge scan was not declared (got: $(printf '%s' "$out" | head -c 200))")
fi

# --- and outside a project it can resolve, it does nothing -----------------------------------------------------
out="$(p | AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' AAL_BACKLOG='' CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" node "$TOOL" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE: it spoke with no project resolved (got: $(printf '%s' "$out" | head -c 160))")
fi

# --- a card that is gated is not a candidate ----------------------------------------------------------------------
# The pilot's whole job is naming what may be TOUCHED; a gated card is the clearest case of something
# that may not, and offering it would send somebody to work nothing can accept.
offers() { # $1 = card slug -> rc 0 when the verdict lists it as openable
  printf '%s' "$(cli --json)" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.exit((j.candidates||[]).some((c)=>String(c).includes(process.argv[1]))?0:1)}catch{process.exit(2)}})' -- "$1"
}
gate_arm() { # $1 = description, $2 = header suffix, $3 = expect (hold|offer)
  board "$(printf '%s [%s] %s · P1%s\n' "$H" 'QUEUED' 'R-gated' "$2")"
  if offers R-gated; then got=offer; else got=hold; fi
  if [ "$got" = "$3" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("GATED[$1]: expected $3, got $got"); fi
}
gate_arm 'waiting on the user'  ' · blocked-by=user · asked-at=2026-08-01T00:00:00Z' hold
gate_arm 'waiting on a date'    ' · DoD-GATED: the rebuild has to finish · observe-until 2099-01-01 · gate-observed-at=2026-08-01T00:00:00Z' hold
# 🔴 The control that keeps the two above from being satisfied by a pilot that offers nothing: an
# ungated card at the same tier must come back.
gate_arm 'nothing holding it'   '' offer
# A merge-order gate names ANOTHER PR, and a fixture cannot reach GitHub to ask whether that PR is
# still open. The pilot deliberately does NOT hold on a gate whose target it cannot resolve — a
# blocker that outlives the thing it was waiting for is how a card sits untouched forever.
gate_arm 'a merge-order gate whose target is unresolvable' ' · blocked-by=merge-order:pr#99' offer

summary
