#!/usr/bin/env bash
# remind-surface-usergated-when-user-present — a card waiting on a decision only moves while the person
# who makes it is here, and those are the minutes most easily spent on something else. This one
# reminds rather than blocks, and throttles itself so the reminder does not become wallpaper.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/remind-surface-usergated-when-user-present.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/repo/.claude" "$AAL_TMP/config"
: > "$AAL_TMP/repo/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
REPO_N="$AAL_TMP_N/repo"
aal_pin_project "$REPO_N"
# 🔴 The throttle receipt is a file inside the configuration directory, touched every time the
# reminder fires. Left at its default this fixture would write into the operator's own configuration
# and, worse, silence THEIR next reminder for half an hour.
export CLAUDE_CONFIG_DIR="$AAL_TMP_N/config"
trap 'rm -rf "$AAL_TMP"' EXIT

BOARD="$AAL_TMP/repo/.claude/BACKLOG.md"
GATE_KEY=blocked-by
gated_card() { printf '%s [%s] %s · %s=user\n' '###' 'USER-GATED' "$1" "$GATE_KEY"; }
plain_card() { printf '%s [%s] %s\n' '###' 'IN-DEV' "$1"; }
board() { printf '# Backlog\n\n%s\n' "$1" > "$BOARD"; }
p() { node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))'; }
untick() { rm -f "$AAL_TMP/config/.usergated-reminder-shown"; }
# -----------------------------------------------------------------------------------------------

# --- FIRES: a gated card on the board -----------------------------------------------------------------
board "$(gated_card R-widget)"
untick
assert_fires "one card waiting on a decision" "$(p)" 'R-widget'

# --- the throttle: the same board, straight away, says nothing -------------------------------------------
# Without it the reminder would print on every turn until the decision is made, and a message that
# always prints stops being read — which costs the card the attention the reminder exists to buy.
assert_quiet "the same board again, inside the window" "$(p)"

# --- SILENT: nothing is waiting -------------------------------------------------------------------------
board "$(plain_card R-widget)"
untick
assert_quiet "no gated card" "$(p)"
board ""
untick
assert_quiet "an empty board" "$(p)"

# --- what cancels a gate: the badge, not the prose ----------------------------------------------------------
# The BADGE is the signal, and prose cannot cancel it: a card still badged as waiting is still
# waiting, however its body reads. Measured — and it is the right way round, because the way to stop
# waiting is to change the badge, and a reminder that believed the prose would go quiet while the
# card still looked gated to every other reader.
board "$(printf '%s [%s] %s · %s=user · the gate was RESOLVED yesterday\n' '###' 'USER-GATED' 'R-widget' "$GATE_KEY")"
untick
assert_fires "prose does not cancel the badge" "$(p)" 'R-widget'
# A card back on the ordinary queue, whose body still mentions the old gate, is the case where the
# prose IS read — and there it correctly stays quiet.
board "$(printf '%s [%s] %s · the user-decision was already cleared\n' '###' 'QUEUED' 'R-widget')"
untick
assert_quiet "a requeued card whose gate was cleared" "$(p)"
board "$(printf '%s [%s] %s · %s=user · not yet released\n' '###' 'USER-GATED' 'R-widget' "$GATE_KEY")"
untick
assert_fires "…and one that is explicitly still waiting" "$(p)" 'R-widget'

# --- SILENT: no project to read ----------------------------------------------------------------------------
untick
out="$(AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' CLAUDE_PROJECT_DIR='' p | AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' CLAUDE_PROJECT_DIR='' node "$HOOK" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-PROJECT: the reminder fired with no project resolved (got: $(printf '%s' "$out" | head -c 120))")
fi

# --- it reminds, and it never denies -------------------------------------------------------------------------
board "$(gated_card R-widget)"
untick
out="$(p | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
  FAIL=$((FAIL+1)); FAILURES+=("SOFT: the reminder came back as a denial")
else
  PASS=$((PASS+1))
fi
# …and the receipt it writes lands in the sandbox rather than in the operator's configuration.
if [ -f "$AAL_TMP/config/.usergated-reminder-shown" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("RECEIPT: the throttle receipt was not written to the sandbox")
fi

summary
