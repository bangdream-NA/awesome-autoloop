#!/usr/bin/env bash
# anomaly-recording-check — a prompt at the end of a turn: did anything you saw first-hand today look
# wrong, and did it get written down? It defaults to SKIP, and it throttles per session, because a
# question that arrives every turn stops being answered.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
trap 'rm -rf "$AAL_TMP"' EXIT

# 🔴 The throttle receipt is written NEXT TO THE HOOK ITSELF, under its own directory. Run in place,
# this fixture would leave state files inside the repository — one per session id, on every run — so
# the hook and the library it needs are copied into a sandbox and exercised there. That also makes
# the throttle arms possible at all: they need a receipt directory nobody else is writing to.
mkdir -p "$AAL_TMP/hooks/lib"
cp "$HOOKS_DIR/anomaly-recording-check.sh" "$AAL_TMP/hooks/"
cp "$HOOKS_DIR/lib/parse-json.sh" "$HOOKS_DIR/lib/activation.sh" "$AAL_TMP/hooks/lib/"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$AAL_TMP/hooks/anomaly-recording-check.sh"

p() { # $1 = session id, $2 = stop_hook_active (true/false)
  node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],stop_hook_active:process.argv[2]==="true"}))' -- "$1" "${2:-false}"
}
untick() { rm -rf "$AAL_TMP/hooks/.state"; }
# -----------------------------------------------------------------------------------------------

# --- FIRES: the first stop of a session ---------------------------------------------------------------
untick
assert_fires "the first turn"  "$(p 11111111-2222-3333-4444-555555555555)" 'Anomaly check'
# …and it says what to do with the answer, rather than only asking.
assert_fires "…with a default"  "$(p 22222222-2222-3333-4444-555555555555)" 'SKIP'

# --- QUIET: the throttle ------------------------------------------------------------------------------------
# The same session again, straight away. Without this the prompt would arrive on every single turn,
# and the honest answer to a question asked that often is whatever gets it out of the way fastest.
assert_quiet "the same session, inside the window" "$(p 11111111-2222-3333-4444-555555555555)"
# A DIFFERENT session is a different conversation and gets its own first ask — the receipt is keyed by
# session for that reason, and a global one would silence everybody for half an hour.
assert_fires "a different session"   "$(p 33333333-2222-3333-4444-555555555555)" 'Anomaly check'

# --- QUIET: the stop it is already handling ------------------------------------------------------------------
# Firing while a stop hook is already active is how a turn gets stuck in a loop with itself.
untick
assert_quiet "a stop that is already active" "$(p 44444444-2222-3333-4444-555555555555 true)"

# --- QUIET: the window is configurable, and a zero-length one means ask every time ------------------------------
untick
ANOMALY_GUARD_THROTTLE_SECS=0 bash "$HOOK" >/dev/null 2>&1 <<<"$(p 55555555-2222-3333-4444-555555555555)"
out="$(ANOMALY_GUARD_THROTTLE_SECS=0 bash "$HOOK" 2>&1 <<<"$(p 55555555-2222-3333-4444-555555555555)")"
if printf '%s' "$out" | grep -q 'Anomaly check'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("THROTTLE-SEAM: with the window at zero the second ask did not arrive (got: $(printf '%s' "$out" | head -c 120))")
fi

# --- QUIET: outside a project that runs this convention ------------------------------------------------------------
# The scope guard is the activation check every hook here shares. Pinned because the source this was
# ported from tested for one author's checkout by absolute path, and a sanitised literal would leave
# the hook silent everywhere — which is indistinguishable from a working throttle.
untick
out="$(CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" bash "$HOOK" 2>&1 <<<"$(p 66666666-2222-3333-4444-555555555555)")"
if [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE: the hook fired outside an autoloop project (got: $(printf '%s' "$out" | head -c 120))")
fi
# …and the control for that arm: inside one, the same call speaks.
untick
out="$(bash "$HOOK" 2>&1 <<<"$(p 77777777-2222-3333-4444-555555555555)")"
if printf '%s' "$out" | grep -q 'Anomaly check'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE-CONTROL: inside a project the hook said nothing — the arm above proves nothing")
fi

summary
