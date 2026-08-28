#!/usr/bin/env bash
# require-owner-check-on-new-hook — two hooks judging one concept with no shared predicate produce
# opposite verdicts, and each reads correct on its own. The gate denies a NEW hook file unless the
# author states, in one line, which existing hook was checked first.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-owner-check-on-new-hook.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/.claude/hooks/lib" "$AAL_TMP/.claude/hooks/__tests__"
: > "$AAL_TMP/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N"
# The library that resolves "where the hooks live" reads CLAUDE_CONFIG_DIR, so the fixture points it
# at the sandbox instead of at the operator's real configuration.
export CLAUDE_CONFIG_DIR="$AAL_TMP_N/.claude"
trap 'rm -rf "$AAL_TMP"' EXIT

HOOKS="$AAL_TMP_N/.claude/hooks"
printf 'existing\n' > "$AAL_TMP/.claude/hooks/already-here.mjs"
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: a new hook that never says who else was considered ------------------------------------
assert_deny "a new .mjs hook"  "$(w "$HOOKS/block-something-new.mjs" "process.exit(0)")" 'prove this concept has no owner'
assert_deny "a new .sh hook"   "$(w "$HOOKS/block-something-new.sh" "exit 0")"           'prove this concept has no owner'
assert_deny "a new lib file"   "$(w "$HOOKS/lib/new-predicate.mjs" "export const x = 1")" 'prove this concept has no owner'

# --- ALLOW: the one-line answer, in either of its two shapes ---------------------------------------
assert_allow "OWNER-CHECK naming a neighbour" \
  "$(w "$HOOKS/block-something-new.mjs" "// OWNER-CHECK: block-wildcard-delete — it judges deletes, not this
process.exit(0)")"
assert_allow "OWNER-CHECK: none, with the grep" \
  "$(w "$HOOKS/block-something-new.mjs" "// OWNER-CHECK: none — grep -rl 'shutdown ledger' hooks/*.mjs returned 0
process.exit(0)")"

# --- ALLOW: not a new hook ---------------------------------------------------------------------------
# Editing a hook that already exists is not the failure this gate is about: the concept already has
# an owner, and that owner is the file being edited.
assert_allow "rewriting an existing hook" "$(w "$HOOKS/already-here.mjs" "process.exit(0)")"
assert_allow "a fixture under __tests__"  "$(w "$HOOKS/__tests__/block-something-new.test.mjs" "// no owner check here")"
assert_allow "a hook-shaped file outside the hooks dir" \
  "$(w "$AAL_TMP_N/src/block-something-new.mjs" "process.exit(0)")"
assert_allow "a markdown note in the hooks dir" \
  "$(w "$HOOKS/README.md" "how these are mounted")"
assert_allow "a JSON file in the hooks dir" \
  "$(w "$HOOKS/config.json" '{"a":1}')"

# --- ALLOW: tools the gate does not judge --------------------------------------------------------------
assert_allow "an Edit"  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"a",new_string:"b"}}))' -- "$HOOKS/block-something-new.mjs")"
assert_allow "a read"   "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Read",tool_input:{file_path:process.argv[1]}}))' -- "$HOOKS/block-something-new.mjs")"

# 🔴 NOT ASSERTED, and it is a portability gap rather than a fixture gap. The gate has a SECOND
# limb for hooks written by a script rather than by the Write tool, and its path pattern requires a
# DRIVE LETTER (`[A-Za-z]:[\\/]…`). On Linux and macOS — where an adopter of this kit is most likely
# to be — that limb matches nothing, so a script that creates a hook is not seen at all. An arm here
# would assert deny on one platform and allow on another, so instead the gap is named: the Write
# limb above is covered on every platform, the script limb is covered on none.

summary
