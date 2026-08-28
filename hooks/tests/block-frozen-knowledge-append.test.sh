#!/usr/bin/env bash
# block-frozen-knowledge-append — the shared knowledge baselines are frozen: an agent appending to
# one edits what every other role reads, and the edit arrives with no wave and no reviewer behind
# it. The gate denies writes to those paths and points at the one-new-file route instead.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-frozen-knowledge-append.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-frozen-knowledge-append
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

# The predicate reads a PATH, so these are synthetic paths: nothing is opened and nothing needs to
# exist. `/home/someone` and the Windows spelling are both here because the gate normalises
# separators, and a fixture that only ever fed forward slashes would not notice if it stopped.
w() { # $1 = file_path, $2 = tool (default Write)
  node -e 'process.stdout.write(JSON.stringify({tool_name:process.argv[2]||"Write",tool_input:{file_path:process.argv[1],content:"x"}}))' -- "$1" "${2:-Write}"
}

# --- DENY: the frozen baselines -------------------------------------------------------------------
assert_deny "the data-pipeline baseline" "$(w "/home/someone/.claude/knowledge/common/data-pipeline.md")" 'FROZEN knowledge baseline'
assert_deny "the web-frontend baseline"  "$(w "/home/someone/.claude/knowledge/common/web-frontend.md")"  'FROZEN knowledge baseline'
assert_deny "a live verification recipe" "$(w "/home/someone/.claude/knowledge/common/verification-recipes-live-widget.md")" 'FROZEN knowledge baseline'
assert_deny "the same path with backslashes" \
  "$(w "C:\\Users\\someone\\.claude\\knowledge\\common\\web-frontend.md")" 'FROZEN knowledge baseline'
assert_deny "an Edit, not only a Write"  "$(w "/home/someone/.claude/knowledge/common/web-frontend.md" Edit)" 'FROZEN knowledge baseline'
assert_deny "a MultiEdit"                "$(w "/home/someone/.claude/knowledge/common/data-pipeline.md" MultiEdit)" 'FROZEN knowledge baseline'

# --- ALLOW: the route the denial prescribes ---------------------------------------------------------
assert_allow "one new role note"         "$(w "/home/someone/.claude/knowledge/developer/inline-payloads--20260827-widget.md")"
assert_allow "one new fragment"          "$(w "/home/someone/.claude/knowledge/fragments/venues--20260827-widget.md")"
assert_allow "a new file in common/"     "$(w "/home/someone/.claude/knowledge/common/inline-payloads.md")"

# --- ALLOW: a similar-looking path that is not one of them -------------------------------------------
# The predicate is anchored on the FULL path, not on the basename. Without these, narrowing it to
# "any file called web-frontend.md" would read exactly as green as the correct predicate does.
assert_allow "the same basename in a repo" "$(w "/work/project/docs/knowledge/common/web-frontend.md")"
assert_allow "a role dir of the same name" "$(w "/home/someone/.claude/knowledge/developer/web-frontend.md")"
assert_allow "a longer name that merely starts the same" \
  "$(w "/home/someone/.claude/knowledge/common/web-frontend-notes.md")"

# --- ALLOW: not a write at all ----------------------------------------------------------------------
assert_allow "reading one through Bash" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"cat /home/someone/.claude/knowledge/common/web-frontend.md"}}))')"

summary
