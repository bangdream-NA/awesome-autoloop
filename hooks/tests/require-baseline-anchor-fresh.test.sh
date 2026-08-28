#!/usr/bin/env bash
# require-baseline-anchor-fresh — a baseline that pins `path:line:hash` goes stale the moment lines
# move above it, and a stale anchor keeps passing while pointing at the wrong code. The gate
# recomputes every anchor before a commit or a merge and denies when one no longer matches.
#
# 🔴 The gate needs TWO files from the PROJECT: the baseline itself and a library providing
# `compute_content_anchor`. This kit ships NEITHER, and nothing in docs/ describes them, so on every
# adopter's machine the gate exits at its existence check and can never fire. That is a real gap,
# reported rather than papered over — and it is why the first arm below (no baseline ⇒ allow) is the
# one that describes today's behaviour for everybody, while the rest describe the contract the gate
# expects a project to satisfy. The library this fixture writes is the MINIMUM that satisfies that
# contract; it is not a copy of anything the kit provides, because there is nothing to copy.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/require-baseline-anchor-fresh.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude" "$REPO/scripts/__tests__/lib" "$REPO/src"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$REPO_N"
# The gate falls back to the shell's own directory when the payload carries no cwd, so the process
# CWD is pinned too — otherwise these arms would be answered by whichever checkout the suite ran in.
cd "$REPO" || exit 1

printf 'alpha\nbeta\ngamma\n' > "$REPO/src/widget.ts"

LIBFILE="$REPO/scripts/__tests__/lib/pipefail-sigpipe-baseline-lib.sh"
cat > "$LIBFILE" <<'LIB'
compute_content_anchor() {
  local file="$1" line="$2"
  local n; n=$(wc -l < "$file")
  [ "$line" -le "$n" ] || return 1
  sed -n "${line}p" "$file" | sha1sum | cut -d' ' -f1
}
LIB
BASELINE="$REPO/scripts/__tests__/pipefail-sigpipe-baseline.txt"
anchor_of() { # $1 = repo-relative path, $2 = line
  sed -n "${2}p" "$REPO/$1" | sha1sum | cut -d' ' -f1
}
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "$REPO_N"; }

# --- ALLOW: no baseline in the project — every adopter's state today -------------------------------
assert_allow "no baseline file" "$(p "git commit -m 'feat(kit): x'")"

# --- ALLOW: an anchor that still points at the same line -------------------------------------------
printf 'src/widget.ts:2:%s beta\n' "$(anchor_of src/widget.ts 2)" > "$BASELINE"
assert_allow "a fresh anchor"   "$(p "git commit -m 'feat(kit): x'")"
assert_allow "…and on a merge"  "$(p "git merge origin/main")"

# --- DENY: the line moved, so the stored hash describes different code ------------------------------
printf 'inserted\nalpha\nbeta\ngamma\n' > "$REPO/src/widget.ts"
assert_deny "the line drifted"  "$(p "git commit -m 'feat(kit): x'")" 'BASELINE ANCHOR DRIFT'

# --- DENY: the file shrank above the anchor, so the line is past the end ------------------------------
# A different failure from the one above and it deserves its own arm: a recompute that simply
# returned an empty string here would compare "empty vs stored", deny for the wrong reason, and print
# a message that sends the reader looking for a content change that never happened.
printf 'only-one-line\n' > "$REPO/src/widget.ts"
assert_deny "the line is past EOF" "$(p "git commit -m 'feat(kit): x'")" 'PAST EOF'

# --- ALLOW: commands the gate does not judge -----------------------------------------------------------
printf 'inserted\nalpha\nbeta\ngamma\n' > "$REPO/src/widget.ts"   # still drifted, so these arms are meaningful
assert_allow "a push"           "$(p "git push origin main")"
assert_allow "a status"         "$(p "git status --porcelain")"
assert_allow "a log read"       "$(p "git log --oneline -3")"
assert_allow "the word commit inside a quoted string" "$(p "echo 'git commit -m x'")"

# --- ALLOW: comments and blank rows in the baseline ------------------------------------------------------
# A baseline is a file people edit by hand, so it carries comments; a parser that treated a `#` row as
# an anchor would deny with an unreadable message about a path that does not exist.
printf 'alpha\nbeta\ngamma\n' > "$REPO/src/widget.ts"
{ printf '# anchors for the sigpipe baseline\n\n'; printf 'src/widget.ts:2:%s beta\n' "$(anchor_of src/widget.ts 2)"; } > "$BASELINE"
assert_allow "comments and blanks are skipped" "$(p "git commit -m 'feat(kit): x'")"

summary
