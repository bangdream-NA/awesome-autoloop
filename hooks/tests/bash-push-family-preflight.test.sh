#!/usr/bin/env bash
# bash-push-family-preflight — the fan-out in front of everything that publishes: push, commit, add,
# merge. It dispatches to both shell and ES-module gates, which is the detail worth pinning: an .mjs
# gate run with bash dies at `import:` and prints no denial, and a dispatcher that treated that as
# "the gate had nothing to say" would silently drop one arm of the family.
source "$(dirname "$0")/_lib.sh"
# Resolved BEFORE the working directory moves below: $0 is relative, so a later `cd` turns every
# `dirname "$0"` into a path that does not exist — silently, since the arm that used it simply
# measured an empty string.
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/bash-push-family-preflight.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
# The config check ahead of the fan-out walks the project registry; pinned at an empty one so this
# fixture reports on its own sandbox rather than on the operator's checkouts.
export AAL_LEAD_MARKER_FILE="$AAL_TMP/lead-marker"
export AAL_PROJECT_REGISTRY="$AAL_TMP/known-projects"
: > "$AAL_TMP/lead-marker"
: > "$AAL_TMP/known-projects"
export CLAUDE_PROJECT_DIR="$REPO_N"

# 🔴 The process CWD is pinned, not only the payload's. One gate in this family decides "is this a
# worktree" from `$PWD` — the shell's own directory — rather than from the payload, so the verdict
# depends on where the suite was launched. Measured: run from a directory whose path contains `-wt/`
# every push payload came back denied by that guard, which both stole the arms below and made the
# forwarding comparison read a different gate's text. An adopter running the suite from an ordinary
# checkout would have seen all of them pass. Same class as the payload-side pinning above: a corpus
# supplied by the environment rather than by the fixture.
cd "$REPO" || exit 1
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "$REPO_N"; }

# --- DENY: routed to a SHELL gate ------------------------------------------------------------------
assert_deny "a retired spec-branch push" \
  "$(p "git push -u origin feat/r-widget-plan")" 'branch'

# --- DENY: routed to an ES-MODULE gate ----------------------------------------------------------------
# The dispatcher picks the interpreter from the extension. Both arms are needed: with one alone, a
# dispatcher that ran everything through bash would still look green on the shell gates while the
# .mjs limb silently stopped judging anything.
assert_deny "a compound commit-and-push" \
  "$(p "git add -A && git commit -m 'feat(kit): x' && git push")" 'whole-command-deny'

# --- ALLOW: the family filter --------------------------------------------------------------------------
assert_allow "git status"        "$(p "git status --porcelain")"
assert_allow "git fetch"         "$(p "git fetch origin")"
assert_allow "a log read"        "$(p "git log --oneline -5")"

# --- ALLOW: family commands that no sub-gate objects to --------------------------------------------------
assert_allow "a push to the wave's own branch" "$(p "git push -u origin feat/r-widget")"
assert_allow "a commit on its own"             "$(p "git commit -m 'feat(kit): add the gate'")"
assert_allow "an add on its own"               "$(p "git add -A")"

# --- DENY: the push guard, driven through the command's own cd rather than through $PWD ---------
# The limb above is pinned OUT by the fixture's working directory, so this arm drives it the other
# way: an explicit `cd` into a worktree-shaped path inside the command, which is the form the guard
# reads first. Without it, that whole gate would be unexercised while the file still looked complete.
assert_deny "a push from a worktree-shaped directory" \
  "$(p "cd /somewhere-wt/r-widget && git push -u origin feat/r-widget")" 'BLOCKED'

# --- the config check runs here too, ahead of the fan-out ------------------------------------------------
printf '\tworktree = /mnt/z/elsewhere\n' >> "$REPO/.git/config"
assert_deny "a poisoned config stops the family too" \
  "$(p "git push -u origin feat/r-widget")" 'GIT CONFIG POISONED'
node -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p, fs.readFileSync(p,"utf8").replace(/\n\tworktree = [^\n]*\n/,"\n"));' -- "$REPO/.git/config"

# --- the denial is forwarded verbatim ----------------------------------------------------------------------
direct="$(p "git push -u origin feat/r-widget-plan" | bash "$HOOKS_DIR/block-spec-branch-push.sh" 2>/dev/null)"
via="$(p "git push -u origin feat/r-widget-plan" | bash "$HOOK" 2>/dev/null)"
if [ -n "$direct" ] && [ "$direct" = "$via" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("FORWARDING: the dispatcher's output differs from the gate's own (direct=${#direct}B via=${#via}B)")
fi

# --- first denial wins, and the ones after it are not run ----------------------------------------------------
# A payload that offends TWO gates must come back with the FIRST one's text. Without this, a
# dispatcher that concatenated every verdict would produce a message where the reader cannot tell
# which instruction to follow, and every arm above would still pass.
both="$(p "git add -A && git commit -m 'feat(kit): x' && git push origin feat/r-widget-plan" | bash "$HOOK" 2>/dev/null)"
if printf '%s' "$both" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{JSON.parse(s);process.exit(0)}catch{process.exit(1)}})'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("FIRST-WINS: two offences produced output that is not a single JSON object (got: $(printf '%s' "$both" | head -c 140))")
fi

summary
