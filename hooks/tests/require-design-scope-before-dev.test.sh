#!/usr/bin/env bash
# require-design-scope-before-dev — whether a wave touches the visible layer is a decision somebody
# has to make ON PURPOSE. Left undeclared it defaults to "no" by omission, and the first person to
# notice is whoever sees the shipped page. The gate denies dispatching a developer or an architect
# for a card that declares nothing, and denies it again when the answer is yes and no designer has
# run.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-design-scope-before-dev.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude" "$REPO/docs/product-specs"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"

# Board lines are assembled from arguments — an installed autoloop reads the literals as somebody
# editing a real board — and the board is written for each arm, because the answer the gate gives
# depends on what the CARD says, not on the dispatch alone.
SCOPE_KEY=design-scope
card() { # $1 = wave, $2 = the scope declaration or empty
  if [ -n "$2" ]; then printf '%s [%s] %s · %s: %s\n' '###' 'IN-DEV' "$1" "$SCOPE_KEY" "$2"
  else printf '%s [%s] %s\n' '###' 'IN-DEV' "$1"; fi
}
board() { printf '%s\n' "$1" > "$REPO/.claude/BACKLOG.md"; }
# -----------------------------------------------------------------------------------------------

a() { # $1 = prompt, $2 = subagent_type, $3 = name
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",cwd:process.argv[4],tool_input:{subagent_type:process.argv[2],name:process.argv[3],prompt:process.argv[1]}}))' \
    -- "$1" "${2:-developer}" "${3:-dev-widget}" "$REPO_N"
}
BRIEF='# CARD: R-widget
Implement the venue rendering.'

# --- DENY: the card declares nothing ----------------------------------------------------------------
board "$(card R-widget '')"
assert_deny "a developer for an undeclared card" "$(a "$BRIEF")" 'no design-scope declaration'
assert_deny "an architect for the same card"     "$(a "$BRIEF" architect arch-widget)" 'no design-scope declaration'

# --- DENY: the card says yes and no designer has delivered --------------------------------------------
board "$(card R-widget yes)"
assert_deny "design-scope yes, no artifact" "$(a "$BRIEF")" 'no designer artifact exists yet'

# --- ALLOW: the two ways the answer can be settled -------------------------------------------------------
board "$(card R-widget 'no — data pipeline only, nothing visible changes')"
assert_allow "an explicit no on the card" "$(a "$BRIEF")"
# 🔴 The artifact is looked for in the BOARD and the BRIEF, never on disk — measured: with
# docs/product-specs/R-widget-design.md present and nothing on the card, the dispatch is still
# denied, and the denial says "no R-widget-design document", which reads as a file check. So the
# arms below drive the two channels the gate actually reads, and this one pins the gap: writing the
# design document is not what clears the gate; SAYING SO is.
board "$(card R-widget yes)"
printf '# R-widget design\n' > "$REPO/docs/product-specs/R-widget-design.md"
assert_deny "a design document on disk alone" "$(a "$BRIEF")" 'no designer artifact exists yet'
rm -f "$REPO/docs/product-specs/R-widget-design.md"
board "$(card R-widget yes)
$(printf '%s %s\n' '-' 'log: the design landed at docs/product-specs/R-widget-design.md')"
assert_allow "the design document NAMED on the card" "$(a "$BRIEF")"
# The token on the card is the other route, for a wave whose design was settled without a document.
board "$(card R-widget yes)
$(printf '%s %s\n' '-' 'log: DESIGN DELIVERED, the empty state copy is locked')"
assert_allow "yes, with the delivery token on the card" "$(a "$BRIEF")"

# --- DENY: the PLAN overrides what the card claims about itself -------------------------------------------
# A card can say nothing while its own plan is full of visible-layer work. The test is what the plan
# DELIVERS, and this arm is what stops a wave from routing around the designer by staying quiet.
board "$(card R-widget '')"
printf '# R-widget plan\n\nThe empty state needs new copy and a CTA button.\n' > "$REPO/docs/product-specs/R-widget-plan.md"
assert_deny "the plan describes visible work" "$(a "$BRIEF")" 'the test is WHAT THE PLAN SAYS'
# …and the exemption still wins over the plan, because somebody has then made the call on purpose.
board "$(card R-widget 'no — the copy was locked by the user, this wave only wires it')"
assert_allow "an explicit no beats the plan's wording" "$(a "$BRIEF")"
rm -f "$REPO/docs/product-specs/R-widget-plan.md"

# --- ALLOW: dispatches this gate is not about --------------------------------------------------------------
board "$(card R-widget '')"
assert_allow "a planner"        "$(a "$BRIEF" planner planner-widget)"
assert_allow "a code-reviewer"  "$(a "$BRIEF" code-reviewer cr-widget)"
# No card named in the brief and no wave in the agent name: nothing to look up, so the gate cannot
# form the question. Denying here would block every dispatch that is not about a card.
assert_allow "a dispatch naming no wave" "$(a "Have a look at the venue helper." developer dev)"
# A wave with no card on the board is the same: there is no declaration to be missing.
assert_allow "a wave that is not on the board" "$(a "# CARD: R-other
Implement it." developer dev-other)"
assert_allow "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls docs"}}))')"

summary
