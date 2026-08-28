#!/usr/bin/env bash
# require-lead-debt-direct — a debt the lead owes has no agent to dispatch it to, so it either gets
# done in the turn it surfaces or it survives as a ledger row that nothing ever reads again. The gate
# blocks the stop while any row is open, stale, expired, or shaped so nothing can check it.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-lead-debt-direct.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/claude"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
trap 'rm -rf "$AAL_TMP"' EXIT

# Both the ledger directory and the board come from the gate's own seams, and the ownership check is
# forced: without it the gate only speaks for the session that owns the newest op-log, which is a
# property of the operator's machine rather than of anything a fixture can arrange.
export AAL_LEADDEBT_DIR="$AAL_TMP_N/claude"
export AAL_LEADDEBT_BOARD="$AAL_TMP_N/claude/BACKLOG.md"
export AAL_LEADDEBT_FORCE_OWN=1
export CLAUDE_PROJECT_DIR="$AAL_TMP_N"
printf '# Backlog\n' > "$AAL_TMP/claude/BACKLOG.md"

TODAY="$(date -u +%Y-%m-%d)"
YESTERDAY="$(aal_date_rel '-1 day' +%Y-%m-%d)"
LONG_AGO="$(aal_date_rel '-10 days' +%Y-%m-%d)"
NEXT_WEEK="$(aal_date_rel '+7 days' +%Y-%m-%d)"
NOW_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ledger() { printf '%s\n' "$@" > "$AAL_TMP/claude/LEAD-DEBTS.md"; }
row() { printf -- '- [%s] %s · %s' "$1" "$2" "$3"; }
p() { node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))'; }
# -----------------------------------------------------------------------------------------------

# --- FIRES: rows that name work nobody has done -------------------------------------------------------
ledger "$(row open R-widget 'install the wrapper on the box')"
assert_fires "an open row"        "$(p)" 'LEAD-DEBT'
ledger "$(row "working $LONG_AGO" R-widget 'still installing')"
assert_fires "working for ten days" "$(p)" 'LEAD-DEBT'
ledger "$(row "gated until:$LONG_AGO" R-widget "gate-observed-at=$NOW_TS")"
assert_fires "a gate that expired"  "$(p)" 'LEAD-DEBT'
# A gate with no machine-readable anchor cannot be aged at all, so it would sit there indefinitely
# looking like a decision somebody made on purpose.
ledger "$(row "gated until:$NEXT_WEEK" R-widget 'waiting for the window')"
assert_fires "a gate with no anchor"  "$(p)" 'LEAD-DEBT'
# "Done" with no evidence is a claim, and the ledger is where claims go to stop being checked.
ledger "$(row "done $TODAY" R-widget 'ok')"
assert_fires "done with no evidence" "$(p)" 'LEAD-DEBT'
# A line that is not a row at all is simply not a row — only `- [` lines are parsed, so free prose in
# the ledger is left alone. What the gate does catch is a row that LOOKS like one and carries a state
# nothing knows how to age.
ledger '- some prose about the wrapper'
assert_quiet "free prose in the ledger" "$(p)"
ledger "$(row nonsense R-widget 'a state nobody defined')"
assert_fires "a row with an unknown state" "$(p)" 'malformed'

# --- SILENT: every disposal the gate accepts -------------------------------------------------------------
ledger "$(row "done $TODAY" R-widget 'installed and read the version back from the box')"
assert_quiet "done with evidence"   "$(p)"
ledger "$(row "working $YESTERDAY" R-widget 'installing now')"
assert_quiet "working since yesterday" "$(p)"
ledger "$(row "gated until:$NEXT_WEEK" R-widget "gate-observed-at=$NOW_TS")"
assert_quiet "a live gate with an anchor" "$(p)"
ledger "$(row 'gated blocked-by=pr#1229' R-widget 'waiting on the merge')"
assert_quiet "gated on a PR"        "$(p)"
ledger "$(row 'gated user' R-widget 'waiting on a ruling')"
assert_quiet "gated on the user"    "$(p)"
ledger "$(row void R-widget 'the card was withdrawn, nothing to install')"
assert_quiet "a void row with a reason" "$(p)"
ledger '# Lead debts' ''
assert_quiet "an empty ledger"      "$(p)"

# --- FIRES: a card that declares a lead-owed DoD and never registered it -------------------------------------
# The ledger is the place those become visible; a card that gates itself on the lead without a row is
# invisible to every later turn.
ledger '# Lead debts'
printf '# Backlog\n\n%s [%s] %s · DoD-GATED: server-op, the lead runs it\n' '###' 'BLOCKED' 'R-widget-install' > "$AAL_TMP/claude/BACKLOG.md"
assert_fires "an unregistered lead-gated card" "$(p)" 'unregistered'
ledger "$(row open R-widget-install 'install the wrapper')"
assert_fires "…registering it turns it into an open debt" "$(p)" 'LEAD-DEBT'
printf '# Backlog\n' > "$AAL_TMP/claude/BACKLOG.md"

summary
