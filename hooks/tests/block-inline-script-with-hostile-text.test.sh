#!/usr/bin/env bash
# block-inline-script-with-hostile-text — `node -e` / `python -c` payloads pass through the shell
# and, on MSYS, through a path rewriter as well. A backtick, a `$` or a backslash inside one is
# rewritten before the interpreter ever sees it, so the script that runs is not the script that was
# written. The gate denies those payloads and asks for a file on disk instead.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-inline-script-with-hostile-text.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-inline-script-with-hostile-text
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

# Payloads are built by node rather than by printf. Every arm here is ABOUT backslashes, quotes and
# `$`, so hand-escaping them into a printf format string is the one place where a fixture would
# quietly test different bytes than it displays.
p() {
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1"
}

# --- DENY: a double-quoted payload carrying a character the shell will act on --------------------
assert_deny 'node -e "…" with a backtick'   "$(p 'node -e "console.log(`hi`)"')"           'INLINE-HOSTILE-CHAR'
assert_deny 'node -e "…" with a $'          "$(p 'node -e "console.log(process.env.X + \"$HOME\")"')" 'INLINE-HOSTILE-CHAR'
assert_deny 'python3 -c "…" with a $'       "$(p 'python3 -c "print(\"$PATH\")"')"          'INLINE-HOSTILE-CHAR'
assert_deny 'python -c "…" with a backslash' "$(p 'python -c "print(\"a\\nb\")"')"          'INLINE-HOSTILE-CHAR'

# --- DENY: a single-quoted payload carrying a backslash, which MSYS rewrites as a path -----------
assert_deny "node -e '…' with a backslash"  "$(p "node -e 'console.log(\"a\\nb\")'")"       'INLINE-HOSTILE-CHAR'
assert_deny "--eval spelled out"            "$(p "node --eval 'process.stdout.write(\"x\\ty\")'")" 'INLINE-HOSTILE-CHAR'

# --- ALLOW: an inline payload with nothing the shell will touch ----------------------------------
assert_allow 'double-quoted, plain'         "$(p 'node -e "console.log(1 + 1)"')"
assert_allow "single-quoted, plain"         "$(p "node -e 'process.exit(0)'")"
assert_allow "python3 -c, plain"            "$(p "python3 -c 'print(42)'")"

# --- ALLOW: a script on disk is the shape the denial asks for ------------------------------------
assert_allow "node running a file"          "$(p "node scripts/report.mjs --json")"
assert_allow "bash running a file"          "$(p "bash hooks/tests/run-all.sh")"
assert_allow "no -e anywhere"               "$(p "git status")"

# --- ALLOW: the documented escape ------------------------------------------------------------------
assert_allow "the INLINE-OK escape"         "$(p 'node -e "console.log(`x`)"   # INLINE-OK: single literal, verified by hand')"

summary
