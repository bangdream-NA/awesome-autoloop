#!/usr/bin/env bash
# block-spec-branch-push — one wave is one branch. The `-plan` / `-arch` / `-design` branch pattern
# splits a wave's spec away from the code that implements it, so the two land as separate PRs and a
# reviewer sees neither half whole. The gate denies a push of such a branch.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-spec-branch-push.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-spec-branch-push
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

p() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# --- DENY: the retired spec-branch shapes, named explicitly in the push --------------------------
assert_deny "push feat/r-x-plan"       "$(p "git push -u origin feat/r-widget-plan")"       'branch'
assert_deny "push feat/r-x-arch"       "$(p "git push origin feat/r-widget-arch")"          'branch'
assert_deny "push feat/r-x-design"     "$(p "git push origin feat/r-widget-design")"        'branch'
assert_deny "push feat/r-x-planreview" "$(p "git push origin feat/r-widget-planreview")"    'branch'
assert_deny "the infix form"           "$(p "git push origin feat/r-plan-widget-thing")"    'branch'

# --- ALLOW: the one-branch-per-wave shape this gate exists to leave alone ------------------------
assert_allow "the wave's single branch" "$(p "git push -u origin feat/r-widget")"
assert_allow "a dev branch"             "$(p "git push origin feat/r-widget-dev")"
assert_allow "fix/"                     "$(p "git push origin fix/typo")"
assert_allow "chore/"                   "$(p "git push origin chore/deps")"
assert_allow "main"                     "$(p "git push origin main")"

# --- ALLOW: deleting such a branch is the CLEANUP, not the split ---------------------------------
assert_allow "deleting a spec branch"   "$(p "git push origin --delete feat/r-widget-plan")"

# --- ALLOW: not a push at all --------------------------------------------------------------------
assert_allow "fetch"                    "$(p "git fetch origin")"
assert_allow "the phrase as data"       "$(p "grep -rn 'feat/r-widget-plan' docs/")"

summary
