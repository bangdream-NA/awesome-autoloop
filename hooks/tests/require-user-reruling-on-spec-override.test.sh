#!/usr/bin/env bash
# require-user-reruling-on-spec-override — one wave's spec overturning another's settled choice is a
# decision only the person who made the first one can take back. Written into a document it reads as
# established fact to every later baton. The gate denies the override unless the same write carries an
# anchor showing the ruling was actually revisited.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-user-reruling-on-spec-override.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
mkdir -p "$AAL_PROJ/.claude" "$AAL_PROJ/docs/product-specs"
: > "$AAL_PROJ/.claude/.autoloop"
AAL_PROJ_N="$(aal_native "$AAL_PROJ")"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

PLAN="$AAL_PROJ_N/docs/product-specs/R-widget-plan.md"
BULLET='-'
anchor_line() { printf '%s %s: %s\n' "$BULLET" 'user-reruling' '2026-08-26T09:00:00Z, re-ruled via AskUserQuestion; the previous copy lock is void'; }
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }
ed() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:"x",new_string:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: the override vocabulary, with nothing behind it -------------------------------------------
assert_deny "overriding"  "$(w "$PLAN" "This wave is overriding the empty-state copy the designer locked.")" 'OVERTURNS'
assert_deny "reversing"   "$(w "$PLAN" "We are reversing the decision made in the parent wave.")"           'OVERTURNS'
assert_deny "overturns"   "$(w "$PLAN" "This overturns the locked heading level.")"                          'OVERTURNS'
assert_deny "revokes"     "$(w "$PLAN" "This revokes the earlier ruling on the venue slug.")"                'OVERTURNS'
assert_deny "an Edit, not only a Write" "$(ed "$PLAN" "We are overriding the previous ruling.")"             'OVERTURNS'
# SUPERSEDES on its own is ordinary revision language; it only counts as an override when the sentence
# also points at ANOTHER wave. Both halves are needed, which is why each appears alone below.
assert_deny "supersedes plus a cross-wave hint" \
  "$(w "$PLAN" "R-widget-2 SUPERSEDES the mother wave's decision about the dataset layout.")" 'OVERTURNS'

# --- ALLOW: the anchor the denial asks for ---------------------------------------------------------------
assert_allow "the reruling line" \
  "$(w "$PLAN" "This wave is overriding the empty-state copy the designer locked.
$(anchor_line)")"
# The prose form is accepted too, as long as it carries all three: who ruled, when, and how.
assert_allow "prose naming the user, a date and the route" \
  "$(w "$PLAN" "The user re-ruled this on 2026-08-26 via AskUserQuestion, so the earlier copy lock no longer applies.")"

# --- ALLOW: revision inside one wave, which overturns nobody ------------------------------------------------
assert_allow "a wave superseding its own earlier round" \
  "$(w "$PLAN" "R-widget-r2 SUPERSEDES R-widget-r1 — the same wave, second round.")"
assert_allow "supersedes with no cross-wave hint" \
  "$(w "$PLAN" "Section 3 SUPERSEDES section 2 within this wave.")"

# --- ALLOW: the words used for something other than a ruling ---------------------------------------------------
# "void" and "overridden" are ordinary technical English. A gate that fired on every use of them would
# make the vocabulary unusable in the documents it guards, and the way out its own text names is to
# rephrase — which only works if ordinary phrasing is not already denied.
assert_allow "an ordinary sentence"  "$(w "$PLAN" "The wave ships a helper, a route and two fixtures.")"
assert_allow "an empty write"        "$(w "$PLAN" "")"

# --- ALLOW: files this gate does not read --------------------------------------------------------------------------
assert_allow "the board"       "$(w "$AAL_PROJ_N/.claude/BACKLOG.md" "This wave is overriding the parent wave's decision.")"
assert_allow "a scratch note"  "$(w "$AAL_PROJ_N/notes.md" "This wave is overriding the parent wave's decision.")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo overriding the parent wave"}}))')"

summary
