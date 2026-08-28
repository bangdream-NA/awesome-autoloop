#!/usr/bin/env bash
# require-box-gated-items-on-card-before-merge — a verdict that ends with a list of things still to
# test hands them to nobody. Nothing ever brings a reader back to that section, and the round reads as
# finished because a verdict was written. The gate denies the verdict file while such a section still
# has items in it.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-box-gated-items-on-card-before-merge.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude/reviews"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

VERDICT="$AAL_PROJ_N/.claude/reviews/pr12-r1.md"
BODY='# PR 12

Verdict: APPROVED
Reviewer-type: code-reviewer'
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: each of the three headings that mean "not verified" -------------------------------------
assert_deny "boundaries not crossed" \
  "$(w "$VERDICT" "$BODY

## Boundaries I did NOT cross

- the admin path needs an account I do not have")" 'NOT YET VERIFIED'
assert_deny "edge cases still to test" \
  "$(w "$VERDICT" "$BODY

## Edge cases still to test

- an empty venue list
- a venue with no address")" 'NOT YET VERIFIED'
assert_deny "box-gated items" \
  "$(w "$VERDICT" "$BODY

## Box-gated checks

- the unit only exists after the deploy")" 'NOT YET VERIFIED'
# The count is in the denial, so a reader knows whether this is one item or a page of them.
assert_deny "…and the denial counts the items" \
  "$(w "$VERDICT" "$BODY

## Edge cases still to test

- an empty venue list
- a venue with no address")" '2 line'

# --- ALLOW: the section exists and is empty, or explicitly says none ---------------------------------
# Writing the heading and then "none" is how a reviewer records that the question was asked. Denying
# that would push people to delete the section instead, which loses the fact that it was considered.
assert_allow "an explicit none" \
  "$(w "$VERDICT" "$BODY

## Boundaries I did NOT cross

none — every path in the diff was driven")"
assert_allow "an N-A"  \
  "$(w "$VERDICT" "$BODY

## Edge cases still to test

N-A")"
# 🔴 The accepted spelling is `N-A` or `NA`, never `N/A`. The slash is how almost everyone writes it,
# and a section marked that way is denied with a message about unfinished verification — which sends
# the reviewer looking for work that is already done rather than at the two characters that differ.
assert_deny "…the same answer written with a slash" \
  "$(w "$VERDICT" "$BODY

## Edge cases still to test

N/A")" 'NOT YET VERIFIED'
assert_allow "an empty section" \
  "$(w "$VERDICT" "$BODY

## Edge cases still to test

## Something else

- a note")"

# --- ALLOW: an ordinary verdict -------------------------------------------------------------------------
assert_allow "no such section at all" "$(w "$VERDICT" "$BODY")"
assert_allow "an empty write"         "$(w "$VERDICT" "")"

# --- ALLOW: files this gate does not judge ------------------------------------------------------------------
# It guards the per-round verdict, which is the artifact a merge is allowed against. The same words in
# a plan or on the board are a description, not a claim that a review round finished.
assert_allow "a plan document" \
  "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$BODY

## Edge cases still to test

- an empty venue list")"
assert_allow "the board" \
  "$(w "$AAL_PROJ_N/.claude/BACKLOG.md" "## Edge cases still to test

- an empty venue list")"
assert_allow "a plan-review verdict" \
  "$(w "$AAL_PROJ_N/.claude/reviews/R-widget-planrev-r1.md" "$BODY

## Edge cases still to test

- an empty venue list")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"cat .claude/reviews/pr12-r1.md"}}))')"

summary
