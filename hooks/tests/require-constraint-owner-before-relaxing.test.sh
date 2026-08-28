#!/usr/bin/env bash
# require-constraint-owner-before-relaxing — "just remove the sticky bit" is a proposal to undo a
# decision somebody made on purpose, and a control set deliberately looks exactly like one set by
# accident. The gate denies a sentence that proposes loosening a named constraint unless it cites
# the line where that constraint is defined.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-constraint-owner-before-relaxing.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

BOARD="$AAL_PROJ_N/.claude/BACKLOG.md"
SPEC="$AAL_PROJ_N/docs/product-specs/R-widget-plan.md"
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"x",new_string:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: a proposal to loosen something, with nothing behind it -----------------------------------
assert_deny "remove the sticky bit" \
  "$(w "$BOARD" "Option A: remove the sticky bit from the shared directory so the worker can clean up.")" 'without citing THE LINE'
assert_deny "relax the allowlist" \
  "$(w "$SPEC" "We could relax the allowlist to let the deploy user run the wrapper.")" 'without citing THE LINE'
assert_deny "disable a locked decision" \
  "$(w "$SPEC" "Simplest path: disable the locked decision about worker memory.")" 'without citing THE LINE'
assert_deny "drop the sudoers entry" \
  "$(w "$BOARD" "Dropping the sudoers entry would make this one command work.")" 'without citing THE LINE'
assert_deny "an Edit, not only a Write" \
  "$(ed "$BOARD" "Remove the ACL and the copy step stops failing.")" 'without citing THE LINE'

# --- ALLOW: the same proposal, with the line it comes from ---------------------------------------------
# The citation is what turns "let us undo this" into "I read why it is there". A path and a line
# number is the whole requirement — the gate does not ask anyone to agree with the constraint.
assert_allow "a file:line citation" \
  "$(w "$BOARD" "Option A: remove the sticky bit — it is set at docs/runbooks/service-user-hardening.md:88 and that paragraph gives the reason.")"
assert_allow "a citation to source" \
  "$(w "$SPEC" "We could relax the allowlist defined at hooks/lib/activation.sh:15 if the wrapper moves.")"

# --- ALLOW: sentences that propose nothing of the kind ---------------------------------------------------
assert_allow "a description with no proposal" \
  "$(w "$BOARD" "The sticky bit is set on that directory, which is why the copy runs as the owner.")"
assert_allow "loosening something that is not a constraint" \
  "$(w "$BOARD" "We can drop the extra logging once the sweep is done.")"
assert_allow "an ordinary card" \
  "$(w "$BOARD" "$(printf '%s [%s] %s\n' '###' 'IN-DEV' 'R-widget')")"
assert_allow "an empty write" "$(w "$BOARD" "")"

# --- ALLOW: files this gate does not read -----------------------------------------------------------------
# It guards the artifacts a later baton reads as settled: the board and the specs. A note to oneself
# is not one of those, and holding every file to it would make it impossible to think out loud.
assert_allow "a scratch note" \
  "$(w "$AAL_PROJ_N/notes.md" "Option A: remove the sticky bit from the shared directory.")"
assert_allow "a runbook" \
  "$(w "$AAL_PROJ_N/docs/runbooks/OPS.md" "Option A: remove the sticky bit from the shared directory.")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo remove the sticky bit"}}))')"

summary
