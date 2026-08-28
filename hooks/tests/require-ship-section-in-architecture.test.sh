#!/usr/bin/env bash
# require-ship-section-in-architecture — merging is not shipping. An architecture that never says
# which action carries the change to production leaves that question to whoever notices last, and
# the answer is usually "nobody did it". The gate denies an architecture with no §S section, and
# denies a §S that names an action but not the person who runs it.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-ship-section-in-architecture.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

ARCH="$AAL_PROJ_N/docs/product-specs/R-widget-architecture.md"
# The entry condition is "this looks like a real architecture", so every payload below carries the
# §A heading. Without it the gate stands aside — which is itself an arm further down.
LOCKS='## §A Locked decisions

The venue helper returns a slug.

## File Map

| path | change |
| --- | --- |
| src/widget.ts | new |'
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:process.argv[2],new_string:process.argv[3]}}))' -- "$1" "$2" "$3"; }

# --- DENY: no §S at all ----------------------------------------------------------------------------
assert_deny "an architecture with no ship section" "$(w "$ARCH" "$LOCKS")" 'no .*§S Ship action'

# --- DENY: a §S that names no owner -----------------------------------------------------------------
assert_deny "§S without owner=" \
  "$(w "$ARCH" "$LOCKS

## §S Ship action

Republish the dataset after the merge.")" 'does not say WHO EXECUTES IT'

# --- ALLOW: the two shapes the denial asks for --------------------------------------------------------
assert_allow "§S with an owner" \
  "$(w "$ARCH" "$LOCKS

## §S Ship action

Republish the dataset after the merge · owner=lead")"
assert_allow "an explicit SHIP-N-A" \
  "$(w "$ARCH" "$LOCKS

## §S Ship action

SHIP-N-A: the change is test-only and reaches nothing outside the repository")"
assert_allow "owner=auto"  "$(w "$ARCH" "$LOCKS

## §S Ship action

The deploy workflow runs on merge · owner=auto")"
assert_allow "owner=user"  "$(w "$ARCH" "$LOCKS

## §S Ship action

Paste the migration into the console · owner=user")"

# --- ALLOW: documents that are not an architecture ------------------------------------------------
# The gate reads the RESULT of the edit, not the file name alone, and it only judges a document that
# actually carries the architecture's own structure. Both halves need an arm: without the first, a
# plan would be held to the architecture's rules; without the second, an early skeleton could not be
# saved at all, and the section would have to be written before the locks it ships.
assert_allow "a plan document"      "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-plan.md" "$LOCKS")"
assert_allow "a design document"    "$(w "$AAL_PROJ_N/docs/product-specs/R-widget-design.md" "$LOCKS")"
assert_allow "an early skeleton with no locks yet" \
  "$(w "$ARCH" "# R-widget architecture

Notes to myself before the locks exist.")"
assert_allow "an empty write"       "$(w "$ARCH" "")"

# --- the Edit path: the gate reconstructs the file as it WILL be -----------------------------------
# An Edit sees only a fragment, so the predicate has to apply the change to the file on disk first.
# These two arms are the difference between judging the fragment and judging the document.
printf '%s\n\n## §S Ship action\n\nRepublish the dataset · owner=lead\n' "$LOCKS" > "$AAL_PROJ/docs/product-specs/R-widget-architecture.md"
assert_allow "an edit to a file that already has §S" \
  "$(ed "$ARCH" "The venue helper returns a slug." "The venue helper returns a slug and a name.")"
assert_deny "an edit that REMOVES the owner" \
  "$(ed "$ARCH" "Republish the dataset · owner=lead" "Republish the dataset")" 'does not say WHO EXECUTES IT'

summary
