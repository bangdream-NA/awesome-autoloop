#!/usr/bin/env bash
# bash-commit-push-preflight — the checks that have to happen while the commit is still local: no
# private board directory staged, no cleaned or exported data in the diff, no co-author trailer, and
# a message a changelog generator can read. Once pushed, every one of those costs a force-push.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/bash-commit-push-preflight.sh

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$REPO_N"
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "$REPO_N"; }
stage() { # $1 = path, $2 = content
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "$2" > "$REPO/$1"
  git -C "$REPO" add -f "$1"
}
unstage_all() { git -C "$REPO" reset -q HEAD -- . 2>/dev/null || true; }

# --- DENY: a commit message that no tool downstream can parse -------------------------------------
assert_deny "no conventional prefix"  "$(p "git commit -m \"fixed the thing\"")"           'conventional format'
assert_deny "single quotes too"       "$(p "git commit -m 'fixed the thing'")"             'conventional format'
assert_deny "a type nobody defined"   "$(p "git commit -m \"wip: half of it\"")"           'conventional format'
assert_deny "a co-author trailer"     "$(p "git commit -m \"feat(kit): add the gate

Co-Authored-By: somebody <x@example.invalid>\"")" 'Co-Authored-By'

# --- ALLOW: the shapes the denial asks for ----------------------------------------------------------
assert_allow "feat with a scope"      "$(p "git commit -m \"feat(kit): add the gate\"")"
assert_allow "fix with no scope"      "$(p "git commit -m \"fix: stop denying the allow arm\"")"
assert_allow "a breaking marker"      "$(p "git commit -m \"feat(kit)!: rename the seam\"")"
assert_allow "chore"                  "$(p "git commit -m \"chore(ci): pin the runner\"")"
# A message the gate cannot READ is not a message it should judge: a heredoc or a substitution is
# resolved by the shell, so guessing at it would deny commits whose text the gate never saw.
assert_allow "a message built by the shell" "$(p "git commit -m \"\$(cat /tmp/msg.txt)\"")"
assert_allow "no -m at all"           "$(p "git commit --amend --no-edit")"

# --- DENY: the private board directory staged ---------------------------------------------------------
stage ".claude/BACKLOG.md" "board"
assert_deny "the config directory is staged" "$(p "git commit -m \"feat(kit): add the gate\"")" '.claude/ directory is staged'
unstage_all

# --- DENY: exported or cleaned data in the staged set ---------------------------------------------------
stage "data/canonical-venues.json" '{"a":1}'
assert_deny "a canonical json"        "$(p "git commit -m \"feat(data): refresh\"")" 'cleaned/canonical data'
unstage_all
stage "exports/dump.sql.gz" "x"
assert_deny "a compressed dump"       "$(p "git commit -m \"feat(data): refresh\"")" 'cleaned/canonical data'
unstage_all
stage "cleaned/rows.ndjson" "x"
assert_deny "an ndjson under cleaned/" "$(p "git commit -m \"feat(data): refresh\"")" 'cleaned/canonical data'
unstage_all

# --- ALLOW: ordinary source in the staged set -----------------------------------------------------------
stage "src/widget.ts" "export const widget = 1"
assert_allow "source files"           "$(p "git commit -m \"feat(kit): add the gate\"")"
# A name that merely CONTAINS one of the words is not an exported partition; the predicate is
# anchored on the path shape, and without this arm loosening it would look green.
stage "src/canonicalise.ts" "export const f = 1"
assert_allow "a source file named after the concept" "$(p "git commit -m \"feat(kit): canonicalise\"")"
unstage_all

# --- ALLOW: commands this gate is not about ---------------------------------------------------------------
assert_allow "git status"             "$(p "git status --porcelain")"
assert_allow "git add on its own"     "$(p "git add -A")"
assert_allow "a push with nothing new" "$(p "git push origin main")"

# --- DENY: the repository cannot be resolved --------------------------------------------------------------
# Fail-closed on purpose: the staged-file checks below it are unanswerable without a work tree, and
# an unanswerable check that stays quiet is the failure mode this whole file exists to prevent.
assert_deny "a cwd that is not a work tree" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"git commit -m \"feat(kit): x\""},cwd:process.argv[1]}))' -- "$AAL_TMP")" \
  'cannot be resolved'

summary
