#!/usr/bin/env bash
# backlog-dod-anchor-required — a card that says its Definition of Done failed, with no machine-readable
# stamp saying WHEN, cannot be aged by anything: every timer that would chase it reads the card as
# having no failure at all. The gate denies the write until the anchor is there.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/backlog-dod-anchor-required.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
STAMP="$(aal_date_rel '-2 hours' +%Y-%m-%dT%H:%M:%SZ)"
CLEARED="$(aal_date_rel '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
# Assembled from arguments so this source does not read as a board to an installation.
card()    { printf '%s [%s] %s%s\n' '###' 'BLOCKED' 'R-widget' "$1"; }
FAIL_KEY=dod-failed-at
CLEAR_KEY=dod-failed-cleared-at
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: the claim with no stamp -------------------------------------------------------------------
assert_deny "DoD-FAILED on its own" \
  "$(w "$BOARD" "# Backlog

$(card ' · DoD-FAILED: the sitemap still holds nothing')")" 'no machine anchor'
# 🔴 The claim is only recognised when a COLON follows it (or one of three keywords). Write the same
# sentence with a comma — the natural way to put it — and the card asserts a failure that nothing
# downstream can see, which is the exact state this gate exists to prevent. Pinned rather than
# smoothed over: the near miss is more likely than the shape the gate catches.
assert_allow "…the same claim written with a comma" \
  "$(w "$BOARD" "# Backlog

$(card ' · DoD-FAILED, the sitemap still holds nothing')")"

# --- ALLOW: the claim with its stamp ------------------------------------------------------------------
assert_allow "the anchor present" \
  "$(w "$BOARD" "# Backlog

$(card " · DoD-FAILED · $FAIL_KEY=$STAMP")")"
# A cleared failure is a resolved one: the pair of stamps is what says so, and the prose word alone
# is exactly what this gate refuses to accept as a record.
assert_allow "a cleared failure" \
  "$(w "$BOARD" "# Backlog

$(card " · DoD-FAILED · $FAIL_KEY=$STAMP · $CLEAR_KEY=$CLEARED")")"

# --- ALLOW: cards that assert no failure ----------------------------------------------------------------
assert_allow "an ordinary card"   "$(w "$BOARD" "# Backlog

$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')")"
assert_allow "a verified card"    "$(w "$BOARD" "# Backlog

$(printf '%s [%s] %s · DoD-VERIFIED\n' '###' 'REVIEW' 'R-widget')")"
assert_allow "an empty write"     "$(w "$BOARD" "")"

# --- ALLOW: files this gate does not judge ----------------------------------------------------------------
assert_allow "a plan document" \
  "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$(card ' · DoD-FAILED, the sitemap still holds nothing')")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n DoD-FAILED board.md"}}))')"

summary
