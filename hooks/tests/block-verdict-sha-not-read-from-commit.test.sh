#!/usr/bin/env bash
# block-verdict-sha-not-read-from-commit — a verdict pinned to a commit says "I read THIS". When the
# spec directory on disk no longer matches that commit, the approval is about bytes nobody is looking
# at any more, and nothing in the wording says so. The gate compares the two and denies the write.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-verdict-sha-not-read-from-commit.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude/reviews" "$REPO/docs/product-specs"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"
cd "$REPO" || exit 1

# A real commit that really touched the spec directory: the whole point is comparing a sha against
# the working tree, so a fixture with a synthetic sha would measure nothing.
aal_commit_file "$REPO" docs/product-specs/R-widget-plan.md '# R-widget plan

The venue helper returns a slug.'
SHA="$(git -C "$REPO" rev-parse HEAD)"
BOARD="$REPO_N/.claude/BACKLOG.md"

verdict_line() { printf '%s [%s] %s · %s @%s\n' '###' 'REVIEW' 'R-widget' "$1" "$2"; }
w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
# -----------------------------------------------------------------------------------------------

# --- ALLOW: the cited commit still describes what is on disk ---------------------------------------
assert_allow "a token pinned to the current state" "$(w "$BOARD" "$(verdict_line PLAN_APPROVED "$SHA")")"
assert_allow "…the architecture spelling too"      "$(w "$BOARD" "$(verdict_line ARCH_APPROVED "$SHA")")"
assert_allow "…and into a verdict file" \
  "$(w "$REPO_N/.claude/reviews/R-widget-planrev-r1.md" "$(verdict_line PLAN_APPROVED "$SHA")")"

# --- DENY: the spec directory has moved on since that commit ------------------------------------------
# This is the case the gate exists for, and it is invisible in the sentence: the token reads exactly
# the same before and after somebody edits the document it points at.
aal_commit_file "$REPO" docs/product-specs/R-widget-plan.md '# R-widget plan

The venue helper returns a slug AND a display name.'
assert_deny "the document changed after approval" \
  "$(w "$BOARD" "$(verdict_line PLAN_APPROVED "$SHA")")" 'matches no root on disk'
# The denial names the two line counts and then says NOT to trust them, which is the part worth
# pinning: a reader who checks with line counts alone gets a false match sooner or later.
assert_deny "…and it warns against checking by size" \
  "$(w "$BOARD" "$(verdict_line PLAN_APPROVED "$SHA")")" 'do not self-check with line counts'

# --- ALLOW: writes that pin nothing ----------------------------------------------------------------------
assert_allow "an ordinary card"  "$(w "$BOARD" "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')")"
assert_allow "an empty write"    "$(w "$BOARD" "")"
# A token with no sha after it is a claim about nothing in particular; there is no commit to compare.
assert_allow "a token with no sha" \
  "$(w "$BOARD" "$(printf '%s [%s] %s · PLAN_APPROVED\n' '###' 'REVIEW' 'R-widget')")"

# --- ALLOW: files this gate does not judge ------------------------------------------------------------------
assert_allow "a plan document" \
  "$(w "$REPO_N/docs/product-specs/R-widget-plan.md" "$(verdict_line PLAN_APPROVED "$SHA")")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"grep -n PLAN_APPROVED board.md"}}))')"

# --- fail-open where the gate cannot know ---------------------------------------------------------------------
# A sha no root has ever seen is unresolvable, not wrong. Denying there would block every card that
# cites a commit from a branch this checkout has not fetched.
assert_allow "a sha unknown to every root" \
  "$(w "$BOARD" "$(verdict_line PLAN_APPROVED 0123456789abcdef0123456789abcdef01234567)")"

summary
