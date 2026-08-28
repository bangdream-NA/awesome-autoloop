#!/usr/bin/env bash
# block-wildcard-delete — a delete whose target is a GLOB deletes whatever the glob happens to
# match at that moment, which is not the set the author had in mind. The gate denies a wildcard
# delete outside the disposable paths, and yields to an explicit escape.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-wildcard-delete.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-wildcard-delete
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

p() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# --- DENY: a glob in the delete target ----------------------------------------------------------
assert_deny "rm with a star"          "$(p "rm -rf src/*.ts")"            'wildcard'
assert_deny "rm with a question mark" "$(p "rm -f logs/app-?.log")"       'wildcard'
assert_deny "rm with a bracket class" "$(p "rm -f build/out-[0-9].js")"   'wildcard'
# 🔴 NOT ASSERTED, and the reason is a measurement rather than an omission. The PowerShell arm
# only offends when the token straight after `Remove-Item` is not a flag: the gate takes that token
# as the target and skips it when it starts with `-`. So
#     powershell -Command "Remove-Item -Path Z:/repo/dist/* -Recurse"     => ALLOWED  (measured)
#     powershell.exe -NoProfile -Command "Remove-Item -LiteralPath Z:/x/* -Recurse -Force"  => DENIED
# Both delete by glob. This fixture asserts neither, because encoding the first line as "allow"
# would make a hole look intended and encoding it as "deny" would demand behaviour the artifact
# does not have. The kit's predicate here is byte-identical to the one it was ported from, so the
# boundary is pre-existing rather than something this port introduced — reported for the reviewer.
assert_deny "Remove-Item via powershell.exe with a star" \
  "$(p "powershell.exe -NoProfile -Command \\\"Remove-Item -LiteralPath Z:/x/* -Recurse -Force\\\"")" 'wildcard'
assert_deny "glob hidden behind a &&" "$(p "git status && rm -rf app/generated/*")" 'wildcard'

# --- ALLOW: a NAMED target is exactly the thing the author meant ---------------------------------
assert_allow "named directory"        "$(p "rm -rf build/output")"
assert_allow "named file"             "$(p "rm -f notes.txt")"

# --- ALLOW: the disposable paths, where a glob costs nothing -------------------------------------
assert_allow "node_modules"           "$(p "rm -rf node_modules/*")"
assert_allow "a temp dir"             "$(p "rm -rf /tmp/scratch-123/*")"

# --- ALLOW: the documented escape, so an intentional glob is possible in the open -----------------
assert_allow "the RM-GLOB-OK escape"  "$(p "rm -rf generated/*.tmp   # RM-GLOB-OK: regenerated on every build")"

# --- ALLOW: the words as data, not as a command ---------------------------------------------------
assert_allow "the phrase inside a grep" "$(p "grep -rn 'rm -rf *' docs/")"
assert_allow "unrelated command"        "$(p "git status")"

summary
