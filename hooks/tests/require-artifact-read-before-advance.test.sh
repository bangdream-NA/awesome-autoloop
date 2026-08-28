#!/usr/bin/env bash
# require-artifact-read-before-advance — advancing on an agent's MESSAGE instead of on its ARTIFACT
# is how a step gets taken that the artifact itself forbids. The gate denies merging a PR whose last
# verdict was never opened, and denies delivering an architecture whose upstream documents were never
# opened. Only the Read tool counts: a grep proves a word was searched for, not that a document was
# read.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-artifact-read-before-advance.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude/reviews" "$REPO/docs/product-specs"
REPO_N="$(aal_native "$REPO")"
: > "$REPO/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$REPO_N"
# The repository and the ledger are named through the gate's own seams, so nothing here depends on
# where the suite runs or on which project the session belongs to.
export AAL_REPO_ROOT="$REPO_N"
export AAL_REVIEWS_DIR="$REPO_N/.claude/reviews"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
# 🔴 HOME is pointed at the sandbox as well. When the payload names a transcript that cannot be
# opened, the library FALLS BACK to scanning the operator's own transcript directory and answers
# from the newest session it finds there — so a fixture that skipped this would be asking about the
# operator's day. Measured: the fail-closed arm below came back with an ordinary verdict-not-read
# denial instead of the unreadable-transcript one, because the fallback had found a real transcript.
export HOME="$AAL_TMP_N"
export USERPROFILE="$AAL_TMP_N"

printf 'verdict r1\n' > "$REPO/.claude/reviews/pr12-r1.md"
printf 'verdict r2\n' > "$REPO/.claude/reviews/pr12-r2.md"
printf '# plan\n'          > "$REPO/docs/product-specs/R-widget-detail-plan.md"
printf '# architecture\n'  > "$REPO/docs/product-specs/R-widget-detail-architecture.md"

# A transcript line is what "was it read" is decided from, so the fixture writes them. The tool NAME
# in the line is the discriminator the gate cares about — the same path under a Bash entry is a grep,
# not a read — so both spellings are generated here.
mkreads() { # $1 = out path, then pairs of: tool path
  node -e '
const fs = require("fs");
// With `node -e <script> -- a b c`, the arguments start at argv[1]: there is no script path to skip.
// Reading them from argv[2] silently shifts every pair by one, the output path becomes undefined,
// and no transcript is written at all — which the gate then reports as "nothing was read", the same
// answer a correct fixture gets for a genuinely unread document.
const out = process.argv[1];
const rows = [];
for (let i = 2; i < process.argv.length; i += 2) {
  rows.push(JSON.stringify({ timestamp: new Date().toISOString(), message: { content: [ { type: "tool_use", name: process.argv[i], input: { file_path: process.argv[i + 1] } } ] } }));
}
fs.writeFileSync(out, rows.join("\n") + "\n");' -- "$@"
}
T_NONE="$AAL_TMP_N/none.jsonl"; printf '%s\n' '{"message":{"content":[]}}' > "$T_NONE"
T_VERDICT="$AAL_TMP_N/verdict.jsonl"; mkreads "$T_VERDICT" Read "$REPO_N/.claude/reviews/pr12-r2.md"
T_OLDVERDICT="$AAL_TMP_N/oldverdict.jsonl"; mkreads "$T_OLDVERDICT" Read "$REPO_N/.claude/reviews/pr12-r1.md"
T_GREP="$AAL_TMP_N/grep.jsonl"; mkreads "$T_GREP" Bash "$REPO_N/.claude/reviews/pr12-r2.md"
# -----------------------------------------------------------------------------------------------

b() { # $1 = command, $2 = transcript
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",transcript_path:process.argv[2],cwd:process.argv[3],tool_input:{command:process.argv[1]}}))' -- "$1" "$2" "$REPO_N"
}

# --- DENY: merging a PR whose verdict was never opened ---------------------------------------------
assert_deny "no read of the verdict"  "$(b "gh pr merge 12 --squash --delete-branch" "$T_NONE")" 'last round'
# The LAST round is the one that counts: r1 was read, r2 is the one that decided.
assert_deny "an earlier round was read" "$(b "gh pr merge 12 --squash --delete-branch" "$T_OLDVERDICT")" 'last round'
# A grep hit proves a word was searched for. The two transcript lines differ only in the tool name,
# which is exactly the distinction this gate is built on.
assert_deny "a grep of the same path"  "$(b "gh pr merge 12 --squash --delete-branch" "$T_GREP")" 'last round'

# --- ALLOW: the latest round was read ----------------------------------------------------------------
assert_allow "the last round was read"  "$(b "gh pr merge 12 --squash --delete-branch" "$T_VERDICT")"

# --- ALLOW / DENY around the edges of the merge limb --------------------------------------------------
# A PR with no verdict on disk is a different gate's business; this one only enforces reading what
# exists.
assert_allow "a PR with no verdict file" "$(b "gh pr merge 99 --squash" "$T_NONE")"
assert_allow "not a merge"               "$(b "gh pr view 12 --json state" "$T_NONE")"
assert_allow "the phrase as data"        "$(b "grep -rn 'gh pr merge 12' docs/" "$T_NONE")"

# --- the architecture limb: an artifact delivered without reading its inputs ----------------------------
arch() { # $1 = transcript
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",transcript_path:process.argv[1],cwd:process.argv[3],tool_input:{file_path:process.argv[2],content:"## §A Locked decisions"}}))' \
    -- "$1" "$REPO_N/docs/product-specs/R-widget-detail-architecture.md" "$REPO_N"
}
assert_deny "an architecture with nothing read" "$(arch "$T_NONE")" 'has to Read the upstream documents'
T_PLAN="$AAL_TMP_N/plan.jsonl"; mkreads "$T_PLAN" Read "$REPO_N/docs/product-specs/R-widget-detail-plan.md"
assert_deny "…the plan read, the verdict not"   "$(arch "$T_PLAN")" 'has to Read the upstream documents'

printf 'planrev\n' > "$REPO/.claude/reviews/R-widget-detail-planrev-r1.md"
T_BOTH="$AAL_TMP_N/both.jsonl"
mkreads "$T_BOTH" Read "$REPO_N/docs/product-specs/R-widget-detail-plan.md" Read "$REPO_N/.claude/reviews/R-widget-detail-planrev-r1.md"
assert_allow "both upstream documents read"     "$(arch "$T_BOTH")"

# The design is required by whether the FILE EXISTS, not by what the card claims — so creating one
# has to change the verdict for a transcript that has not read it.
printf '# design\n' > "$REPO/docs/product-specs/R-widget-detail-design.md"
assert_deny "a design exists and was not read"  "$(arch "$T_BOTH")" 'design'
T_ALL="$AAL_TMP_N/all.jsonl"
mkreads "$T_ALL" Read "$REPO_N/docs/product-specs/R-widget-detail-plan.md" Read "$REPO_N/.claude/reviews/R-widget-detail-planrev-r1.md" Read "$REPO_N/docs/product-specs/R-widget-detail-design.md"
assert_allow "…and the same with it read"       "$(arch "$T_ALL")"

# --- fail-closed: an unreadable transcript is not an absence of evidence ---------------------------------
# The two states are byte-identical from here, and only one of them is safe to allow.
assert_deny "no transcript at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",transcript_path:process.argv[1],cwd:process.argv[2],tool_input:{command:"gh pr merge 12 --squash"}}))' -- "$AAL_TMP_N/missing.jsonl" "$REPO_N")" \
  'transcript cannot be read'

summary
