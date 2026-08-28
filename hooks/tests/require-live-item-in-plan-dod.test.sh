#!/usr/bin/env bash
# require-live-item-in-plan-dod — two failures with one home. A plan that splits itself across PRs
# hands the second half to nobody, and a Definition of Done with no item that LOOKS AT PRODUCTION can
# be satisfied entirely by a green CI run on something that never shipped.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-live-item-in-plan-dod.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

PLAN="$AAL_PROJ_N/docs/product-specs/R-widget-plan.md"
ARCH="$AAL_PROJ_N/docs/product-specs/R-widget-architecture.md"
LIVE_DOD='## DoD

- D-1 — the suite is green
- D-2 — after deploying, curl the published dataset and assert it holds 17 venues'
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: a plan that splits itself across PRs -------------------------------------------------------
assert_deny "a second PR" \
  "$(w "$PLAN" "The wrappers land in PR 2, once the first is merged.

$LIVE_DOD")" 'one wave = one card = one PR'
assert_deny "two PRs, spelled out" \
  "$(w "$PLAN" "This is split into two PRs to keep the review small.

$LIVE_DOD")" 'one wave = one card = one PR'
assert_deny "delivery in batches" \
  "$(w "$PLAN" "The rename happens in batches, one PR per batch.

$LIVE_DOD")" 'one wave = one card = one PR'
# The architecture is held to the same rule: a split invented there is a split all the same, and the
# plan gate alone would let it through one document later.
assert_deny "…in the architecture too" \
  "$(w "$ARCH" "## §A Locked decisions

Batch 2 carries the remaining wrappers.")" 'one wave = one card = one PR'

# --- ALLOW: a numbered reference is somebody else's PR, not a split ---------------------------------------
# This is the escape the denial names, and without it the gate would deny every plan that cites a
# neighbouring wave's work.
assert_allow "a numbered PR reference" \
  "$(w "$PLAN" "The wrappers landed in PR #1193, so this wave only wires them.

$LIVE_DOD")"

# --- DENY: a DoD that never looks at production ------------------------------------------------------------
assert_deny "a DoD with only local checks" \
  "$(w "$PLAN" "## DoD

- D-1 — the suite is green
- D-2 — the reviewer approved")" 'has no item that says IT HAS TO BE ALIVE'

# --- ALLOW: any shape of live item -----------------------------------------------------------------------------
# Four spellings, because the predicate is a vocabulary rather than a format, and a plan author will
# reach for whichever one fits the wave.
assert_allow "a curl after deploying"   "$(w "$PLAN" "$LIVE_DOD")"
assert_allow "a live walk"              "$(w "$PLAN" "## DoD

- D-1 — walk it live: search page to detail page, with a mobile screenshot")"
assert_allow "a command on the box"     "$(w "$PLAN" "## DoD

- D-1 — run systemctl status on the box and read the unit state")"
assert_allow "a post-merge check"       "$(w "$PLAN" "## DoD

- D-1 — post-merge, verify the deploy workflow reached every phase")"
# 🔴 A boundary worth seeing rather than smoothing over: the post-merge shape is recognised only when
# a verify / walk / check word lands within about twenty characters of it. The natural sentence
# "post-merge, trigger the deploy workflow and read its steps" describes a live check and is refused,
# and the denial then asks for the item that is already written. Asserted as a deny because that is
# today's behaviour, and named because a plan author meets it while doing the right thing.
assert_deny "…the same intent, phrased with trigger" \
  "$(w "$PLAN" "## DoD

- D-1 — post-merge, trigger the deploy workflow and read its steps")" 'has no item that says IT HAS TO BE ALIVE'
# And the exemption, for a wave that genuinely produces nothing observable.
assert_allow "an explicit not-applicable" \
  "$(w "$PLAN" "## DoD

- D-1 — the suite is green
- LIVE-N-A: this wave only deletes dead code behind an unused export")"

# --- ALLOW: documents and sections this gate does not judge -------------------------------------------------------
# The live-item requirement is the PLAN's: an architecture states how, not whether it was seen working.
assert_allow "an architecture with no DoD section" \
  "$(w "$ARCH" "## §A Locked decisions

The venue helper returns a slug.")"
assert_allow "a plan with no DoD section at all" \
  "$(w "$PLAN" "# R-widget

A first sketch, before the DoD is written.")"
assert_allow "a design document"  "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-design.md" "## DoD

- D-1 — the suite is green")"
assert_allow "an empty write"     "$(w "$PLAN" "")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n DoD plan.md"}}))')"

summary
