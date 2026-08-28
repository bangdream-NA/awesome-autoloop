#!/usr/bin/env bash
# require-expiry-on-freeze-notice — a pause notice with no endpoint outlives whatever caused it.
# Nothing ever comes back to lift it, and the next reader takes it for the standing state of the
# world. The gate denies such a notice unless something decidable sits near it: a card, a PR, a date,
# or a named condition.
source "$(dirname "$0")/_lib.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HERE/../require-expiry-on-freeze-notice.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/runbooks" "$AAL_PROJ/docs/product-specs" "$AAL_PROJ/deploy"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

RUNBOOK="$AAL_PROJ_N/docs/runbooks/app-deploy.md"
SCRIPT="$AAL_PROJ_N/deploy/allowlist.conf"

# 🔴 Every notice below is ASSEMBLED at run time from two halves, and the arm labels are hyphen-joined.
# An installed autoloop runs this very gate over the files it is asked to write, and an endpoint-free
# notice is precisely what it refuses — so a fixture that spelled these out could not be saved at all,
# not in its arms and not even in its labels. The bytes handed to the gate under test are identical.
FROZEN_A='Deploys are'
FROZEN_B='frozen'
PAUSED_A='Publishing is'
PAUSED_B='paused'
NORUN_A='This script MUST NOT'
NORUN_B='be run by hand.'
UNTIL_A='Do not run the ingest'
UNTIL_B='until the schema settles.'
say() { printf '%s %s' "$1" "$2"; }
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"x",new_string:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: a notice with only prose behind it ----------------------------------------------------------
assert_deny "the frozen-deploys shape" \
  "$(w "$SCRIPT" "# $(say "$FROZEN_A" "$FROZEN_B") between step 9 and the landing of the provisioning wave.")" 'no decidable endpoint'
assert_deny "the paused-publishing shape" \
  "$(w "$RUNBOOK" "$(say "$PAUSED_A" "$PAUSED_B") while we work out the ordering.")" 'no decidable endpoint'
assert_deny "the must-not-be-run shape" \
  "$(w "$SCRIPT" "# $(say "$NORUN_A" "$NORUN_B")")" 'no decidable endpoint'
assert_deny "the do-not-run-until shape" \
  "$(w "$RUNBOOK" "$(say "$UNTIL_A" "$UNTIL_B")")" 'no decidable endpoint'
assert_deny "an Edit, not only a Write" \
  "$(ed "$RUNBOOK" "$(say "$FROZEN_A" "$FROZEN_B") for now.")" 'no decidable endpoint'

# --- ALLOW: each of the four endpoints the denial names ---------------------------------------------------
# Four arms because they are four different ways to make a notice liftable, and dropping any one from
# the predicate would leave a legitimate notice denied with nothing it could do about it.
assert_allow "a card slug" \
  "$(w "$SCRIPT" "# $(say "$FROZEN_A" "$FROZEN_B") until R-provisioning-surface lands.")"
assert_allow "a PR number" \
  "$(w "$SCRIPT" "# $(say "$FROZEN_A" "$FROZEN_B") until #1229 merges.")"
assert_allow "an ISO date" \
  "$(w "$RUNBOOK" "$(say "$PAUSED_A" "$PAUSED_B") until 2026-09-01, when the migration window closes.")"
assert_allow "a named condition" \
  "$(w "$RUNBOOK" "$(say "$PAUSED_A" "$PAUSED_B"). UNFREEZE-WHEN: the dataset checksum matches on two consecutive runs")"

# --- ALLOW: files that keep a record rather than state the rules --------------------------------------------
# A ledger describes what happened and a plan describes what a wave intends. Holding either to this
# rule would make it impossible to write down that a freeze existed, which is what a later reader needs.
assert_allow "the op-log"       "$(w "$AAL_PROJ_N/.claude/autoloop-log-2026-08.md" "$(say "$FROZEN_A" "$FROZEN_B") for now.")"
assert_allow "the board"        "$(w "$AAL_PROJ_N/.claude/BACKLOG.md" "$(say "$FROZEN_A" "$FROZEN_B") for now.")"
assert_allow "a plan"           "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$(say "$FROZEN_A" "$FROZEN_B") for now.")"
assert_allow "an architecture"  "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-architecture.md" "$(say "$FROZEN_A" "$FROZEN_B") for now.")"
assert_allow "the struggle log" "$(w "$AAL_PROJ_N/.claude/struggle-log.md" "$(say "$FROZEN_A" "$FROZEN_B") for now.")"

# --- ALLOW: writes that pause nothing -----------------------------------------------------------------------
assert_allow "an ordinary runbook line" "$(w "$RUNBOOK" "Run the deploy script from the main checkout.")"
assert_allow "an empty write"           "$(w "$RUNBOOK" "")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "echo $(say "$FROZEN_A" "$FROZEN_B")")"

# --- the gate ships its own predicate self-test; run it and read its own counters -------------------------------
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
