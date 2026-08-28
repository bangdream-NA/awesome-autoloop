#!/usr/bin/env bash
# bash-gh-pr-merge-preflight — the one mount in front of `gh pr merge`. Before it fans out to the
# merge gates it checks something none of them can: whether git itself is usable in the checkouts
# this session knows about. A poisoned `worktree =` line makes every git command there fail at
# config load, so a merge gate would report "cannot tell" and be read as "nothing wrong".
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/bash-gh-pr-merge-preflight.sh

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"

# 🔴 The config check runs over the project REGISTRY, which by default is the operator's own. Left
# alone, this fixture would read their checkouts and report on their machine's state — and on a
# machine with a genuinely poisoned config every arm below would flip. Both files are the library's
# documented seams.
export AAL_LEAD_MARKER_FILE="$AAL_TMP/lead-marker"
export AAL_PROJECT_REGISTRY="$AAL_TMP/known-projects"
: > "$AAL_TMP/lead-marker"
: > "$AAL_TMP/known-projects"
export CLAUDE_PROJECT_DIR="$REPO_N"
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]},cwd:process.argv[2]}))' -- "$1" "$REPO_N"; }

# --- ALLOW: the merge-intent filter, which is why this mount is cheap -----------------------------
# Everything that is not a merge leaves before a single sub-gate is spawned. The quoted arm is the
# one that matters: the words inside a string are data, and a filter reading them as intent would
# deny every message that mentions merging.
assert_allow "git status"              "$(p "git status --porcelain")"
assert_allow "gh pr view"              "$(p "gh pr view 12 --json state")"
assert_allow "the phrase inside quotes" "$(p "echo 'gh pr merge 12 --squash'")"
assert_allow "a grep for the phrase"   "$(p "grep -rn \"gh pr merge\" docs/")"

# --- DENY: a checkout whose git config points somewhere else ---------------------------------------
# A WSL mount path is the shape that was actually measured in the wild; the second is the quieter
# one — a directory that exists but is a DIFFERENT tree, where git succeeds while operating on the
# wrong files. Both are written into the sandbox's own config, never anywhere else.
printf '\tworktree = /mnt/z/elsewhere\n' >> "$REPO/.git/config"
assert_deny "a WSL mount path in the config" "$(p "gh pr merge 12 --squash")" 'GIT CONFIG POISONED'
git -C "$REPO" config --local --unset core.worktree 2>/dev/null || true
node -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p, fs.readFileSync(p,"utf8").replace(/\n\tworktree = [^\n]*\n/,"\n"));' -- "$REPO/.git/config"

OTHER="$AAL_TMP/other-tree"; mkdir -p "$OTHER"
printf '\tworktree = %s\n' "$(aal_native "$OTHER")" >> "$REPO/.git/config"
assert_deny "a real directory that is a DIFFERENT tree" "$(p "gh pr merge 12 --squash")" 'NOT this checkout'
node -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p, fs.readFileSync(p,"utf8").replace(/\n\tworktree = [^\n]*\n/,"\n"));' -- "$REPO/.git/config"

# --- ALLOW: a config with no worktree line at all -----------------------------------------------------
# Which is what a normal checkout looks like. Without this arm, a check that denied on the mere
# PRESENCE of the key — or on any value — would be indistinguishable from the correct one here.
out="$(p "gh pr merge 12 --squash" | bash "$HOOK" 2>/dev/null)"
if printf '%s' "$out" | grep -q 'GIT CONFIG POISONED'; then
  FAIL=$((FAIL+1)); FAILURES+=("CLEAN-CONFIG: a checkout with no worktree line was reported as poisoned")
else
  PASS=$((PASS+1))
fi

# --- ALLOW: a worktree line that points at THIS checkout ------------------------------------------------
# A linked worktree legitimately carries one. Denying it would break the very layout the pipeline
# runs on, and this is the arm that tells the two cases apart.
printf '\tworktree = %s\n' "$REPO_N" >> "$REPO/.git/config"
out="$(p "gh pr merge 12 --squash" | bash "$HOOK" 2>/dev/null)"
if printf '%s' "$out" | grep -q 'GIT CONFIG POISONED'; then
  FAIL=$((FAIL+1)); FAILURES+=("SELF-POINTING: a worktree line pointing at this checkout was reported as poisoned")
else
  PASS=$((PASS+1))
fi
node -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p, fs.readFileSync(p,"utf8").replace(/\n\tworktree = [^\n]*\n/,"\n"));' -- "$REPO/.git/config"

# --- the denial is forwarded, not paraphrased --------------------------------------------------------------
# 🔴 The remaining sub-gates need a real PR, a real remote and gh credentials, so this fixture cannot
# drive them: what it covers is the filter, the config check that only this mount performs, and the
# fan-out contract. The sub-gates each own their own fixture; naming that here rather than leaving a
# reader to infer it from the arm count.
printf '\tworktree = /mnt/z/elsewhere\n' >> "$REPO/.git/config"
via="$(p "gh pr merge 12 --squash" | bash "$HOOK" 2>/dev/null)"
if printf '%s' "$via" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const j=JSON.parse(s);process.exit(j.hookSpecificOutput&&j.hookSpecificOutput.permissionDecision==="deny"&&/worktree = \/mnt\/z\/elsewhere/.test(j.hookSpecificOutput.permissionDecisionReason)?0:1)}catch{process.exit(1)}})'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  FAILURES+=("FORWARDING: the denial is not parseable JSON carrying the offending line (got: $(printf '%s' "$via" | head -c 120))")
fi

summary
