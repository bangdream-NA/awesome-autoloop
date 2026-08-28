#!/usr/bin/env bash
# require-locked-decision-check-on-permission-option — an option that offers to widen a permission is
# usually offering to undo somebody's deliberate limit, and the person being asked cannot tell the
# difference. The gate denies such an option unless it cites the decision that was checked, and says
# what has changed since.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-locked-decision-check-on-permission-option.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs" "$AAL_PROJ/docs/runbooks"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
aal_pin_project "$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# A real file for the citation to point at: the gate checks that the cited path EXISTS, because a
# citation nobody can follow is indistinguishable from not having looked.
printf '# hardening\n\nthe deploy user gets no root\n' > "$AAL_PROJ/docs/runbooks/service-user-hardening.md"
# -----------------------------------------------------------------------------------------------

q() { # $1 = option description
  node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",tool_input:{questions:[{question:"How should we proceed?",header:"decision",options:[{label:"A",description:process.argv[1]},{label:"B",description:"leave it as it is"}]}]}}))' -- "$1"
}

# --- DENY: an option that widens a limit, with nothing checked ---------------------------------------
assert_deny "grant the agent sudo" \
  "$(q "Grant the agent sudo for the wrapper so it can install the build itself")" 'RELAXING A LIMIT'
assert_deny "add it back to the allowlist" \
  "$(q "Add it back to the allowlist so the deploy user can run it")" 'RELAXING A LIMIT'
# 🔴 The near miss, pinned rather than smoothed over: the verb and the word "back" have to be
# adjacent. Put a noun between them — "add the command back to the allowlist", which is how the
# sentence is most naturally written — and nothing matches, so the option reaches the user with no
# citation behind it. Same request, same consequence, opposite verdict.
assert_allow "…the same request with a noun in between" \
  "$(q "Add the command back to the allowlist so the deploy user can run it")"
assert_deny "restore the route" \
  "$(q "Restore the route that used to let the worker reach the admin API")" 'RELAXING A LIMIT'
assert_deny "give me the private key" \
  "$(q "Give me the private key so I can run the step directly")" 'RELAXING A LIMIT'

# --- DENY: a citation that cannot be followed ----------------------------------------------------------
# Worse than no citation, because it reads as though the search happened.
assert_deny "a cited file that does not exist" \
  "$(q "Grant the agent sudo. LOCKED-DECISION-CHECKED: docs/runbooks/no-such-file.md:12")" 'does not exist in the repo'

# --- DENY: a real citation, but nothing has changed since it --------------------------------------------
# A lock that still holds is a reason to carry it out, not a reason to ask again.
assert_deny "cited, with no change named" \
  "$(q "Grant the agent sudo. LOCKED-DECISION-CHECKED: docs/runbooks/service-user-hardening.md:3")" 'what has changed since'

# --- ALLOW: the citation plus the change ------------------------------------------------------------------
assert_allow "cited and superseded" \
  "$(q "Grant the agent sudo. LOCKED-DECISION-CHECKED: docs/runbooks/service-user-hardening.md:3 SINCE-LOCK-CHANGED: the wrapper moved under the deploy user's own directory, so the lock's premise no longer covers it")"
# A bare filename is accepted too — the gate looks under the spec and runbook directories — because a
# person citing a document they just read should not have to reconstruct its path.
assert_allow "a bare filename" \
  "$(q "Grant the agent sudo. LOCKED-DECISION-CHECKED: service-user-hardening.md SINCE-LOCK-CHANGED: the wrapper moved and the lock names the old path")"
# And the honest answer when the search really came back empty.
assert_allow "an explicit none" \
  "$(q "Grant the agent sudo. LOCKED-DECISION-CHECKED: none — searched the specs and the runbooks for sudoers and the wrapper name, nothing")"

# --- ALLOW: questions that propose no widening ----------------------------------------------------------------
assert_allow "a copy choice" \
  "$(q "Should the empty state say 'no venues yet' or 'nothing here yet'?")"
assert_allow "a scheduling choice" \
  "$(q "Do the detail page first, or the search box?")"
# The nouns on their own are not a proposal: describing a permission is not asking for one.
assert_allow "describing a permission" \
  "$(q "The deploy user has no root, which is why the install step is yours")"

# --- ALLOW: anything that is not a question ------------------------------------------------------------------------
assert_allow "no options"      "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",tool_input:{questions:[{question:"x"}]}}))')"
assert_allow "no questions"    "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"AskUserQuestion",tool_input:{}}))')"
assert_allow "a Bash command"  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo grant the agent sudo"}}))')"

summary
