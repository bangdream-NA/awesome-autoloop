#!/usr/bin/env bash
# require-dispatch-brief-anchors — a planner brief that names no origin, no constraint owner and no
# ship action sends somebody to plan a wave whose reason, limits and delivery route nobody stated.
# All three answers exist already when the brief is written; the gate denies the dispatch until they
# are in it.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-dispatch-brief-anchors.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# Both citations are checked against the FILESYSTEM, not just matched as text: an op-log entry that
# does not exist and a spec that does not exist are exactly the two ways a brief can look complete
# and answer nothing. So the fixture puts real files where a real project would have them.
printf 'a line\nanother line\n' > "$AAL_PROJ/.claude/autoloop-log-2026-08.md"
printf '# R-other-thing plan\n'  > "$AAL_PROJ/docs/product-specs/R-other-thing-plan.md"

ORIGIN='# ORIGIN: autoloop-log-2026-08.md:2 · the sweep found the venue field empty on every page'
SHIP='# SHIP: republish the dataset · owner=lead'
CARD='# CARD: R-widget-detail'
# -----------------------------------------------------------------------------------------------

a() { # $1 = prompt, $2 = subagent_type (default planner)
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.argv[2]||"planner",name:"planner-x",prompt:process.argv[1]}}))' -- "$1" "${2:-planner}"
}

# --- DENY: each anchor missing on its own ----------------------------------------------------------
assert_deny "no origin" \
  "$(a "$CARD
$SHIP
Plan the venue rendering.")" 'ORIGIN'
assert_deny "no ship" \
  "$(a "$CARD
$ORIGIN
Plan the venue rendering.")" 'SHIP'
# An origin that points at a file nobody has is worse than none: it reads as a citation, so the next
# reader stops looking. The path is checked, not just the shape.
assert_deny "an origin citing a file that does not exist" \
  "$(a "$CARD
# ORIGIN: autoloop-log-1999-01.md:5 · something
$SHIP
Plan the venue rendering.")" 'ORIGIN'

# --- DENY: a constraint asserted with no owner named --------------------------------------------------
# "It cannot be done" is a claim about somebody else's decision. Without the wave that made it, the
# planner inherits the limit as a premise and plans around something that may have moved.
assert_deny "a by-design claim with no owner" \
  "$(a "$CARD
$ORIGIN
$SHIP
The allowlist cannot be widened — that is by design.")" 'CONSTRAINT-OWNER'
assert_deny "an owner citing a spec that does not exist" \
  "$(a "$CARD
$ORIGIN
$SHIP
# CONSTRAINT-OWNER: R-no-such-wave
The allowlist cannot be widened — that is by design.")" 'CONSTRAINT-OWNER'
# The owner has to be a DIFFERENT wave: a card citing itself as the owner of its own constraint is
# the shape this check exists to catch, and it is the one that reads most like a real answer.
assert_deny "an owner citing the card's own family" \
  "$(a "$CARD
$ORIGIN
$SHIP
# CONSTRAINT-OWNER: R-widget-detail
The allowlist cannot be widened — that is by design.")" 'CONSTRAINT-OWNER'

# --- ALLOW: all three anchors present ------------------------------------------------------------------
assert_allow "origin and ship, no constraint claimed" \
  "$(a "$CARD
$ORIGIN
$SHIP
Plan the venue rendering.")"
assert_allow "a constraint with a real owning wave" \
  "$(a "$CARD
$ORIGIN
$SHIP
# CONSTRAINT-OWNER: R-other-thing locked it
The allowlist cannot be widened — that is by design.")"
assert_allow "an explicit no-owner answer" \
  "$(a "$CARD
$ORIGIN
$SHIP
# CONSTRAINT-OWNER: none — nobody has ruled on this, which is why the wave exists
The allowlist cannot be widened — that is by design.")"
assert_allow "an explicit no-origin answer" \
  "$(a "$CARD
# NO-ORIGIN: asked for directly, there is no ledger entry to cite
$SHIP
Plan the venue rendering.")"

# --- ALLOW: dispatches this gate is not about -----------------------------------------------------------
# It guards the START of a wave. An architect or a developer brief is downstream of a plan that has
# already answered these, and holding them to it again would deny every later baton.
assert_allow "an architect brief"  "$(a "Write the architecture for R-widget-detail." architect)"
assert_allow "a developer brief"   "$(a "Implement R-widget-detail." developer)"
# No card line means no wave to anchor: a general planning question is not a dispatch this gate can
# judge, and denying it would make the tool unusable for anything but a card.
assert_allow "a planner brief with no card line" "$(a "Draft a plan for the thing we discussed.")"
assert_allow "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls docs/product-specs"}}))')"

summary
