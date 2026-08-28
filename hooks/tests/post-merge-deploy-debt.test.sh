#!/usr/bin/env bash
# post-merge-deploy-debt — the moment a PR merges, a deploy and a full-journey walk are owed. This
# says so out loud and, deliberately, writes NOTHING: the debt is derived from the board every round,
# so there is no row to forget to close and no ledger entry that can drift out of step with reality.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/post-merge-deploy-debt.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/widgetry/.claude"
: > "$AAL_TMP/widgetry/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
PROJ_N="$AAL_TMP_N/widgetry"
aal_pin_project "$PROJ_N"
# The project NAME is what decides whether a merge belongs to this project, and the ledger directory
# is where the no-write property is checked. Both are seams.
export AAL_PROJECT_NAME=widgetry
export PMDD_DIR="$PROJ_N/.claude"
trap 'rm -rf "$AAL_TMP"' EXIT

LEDGER="$AAL_TMP/widgetry/.claude/LEAD-DEBTS.md"
printf '# Lead debts\n' > "$LEDGER"
LEDGER_BEFORE="$(node -e 'const{readFileSync}=require("fs");process.stdout.write(String(readFileSync(process.argv[1],"utf8").length));' -- "$LEDGER")"

p() { # $1 = command, $2 = cwd
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",cwd:process.argv[2],tool_input:{command:process.argv[1]}}))' -- "$1" "${2:-$PROJ_N}"
}
run() { printf '%s' "$1" | node "$HOOK" 2>&1; }
# -----------------------------------------------------------------------------------------------

# --- it speaks when a PR for this project is merged -------------------------------------------------
out="$(run "$(p "cd $PROJ_N && gh pr merge 12 --squash --delete-branch")")"
if printf '%s' "$out" | grep -q 'PR #12 merged'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("MERGE: nothing was said for a merge in this project (got: $(printf '%s' "$out" | head -c 140))")
fi
# The number can arrive as a URL rather than as an argument, which is how a merge typed from a browser
# tab looks.
out="$(run "$(p "cd $PROJ_N && gh pr merge https://github.com/owner/widgetry/pull/34 --squash")")"
if printf '%s' "$out" | grep -q 'PR #34 merged'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("URL-FORM: the number was not read out of a pull URL (got: $(printf '%s' "$out" | head -c 140))")
fi
# A merge with no number at all still says the debt exists — it just cannot name the card.
out="$(run "$(p "cd $PROJ_N && gh pr merge --squash")")"
if printf '%s' "$out" | grep -q 'no PR number'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-NUMBER: (got: $(printf '%s' "$out" | head -c 140))")
fi

# --- 🔴 and it writes nothing ---------------------------------------------------------------------------
# The whole design is that the debt is DERIVED. A ledger row here would be a second place where the
# same fact lives, and the two would disagree the first time a card was archived.
LEDGER_AFTER="$(node -e 'const{readFileSync}=require("fs");process.stdout.write(String(readFileSync(process.argv[1],"utf8").length));' -- "$LEDGER")"
if [ "$LEDGER_AFTER" = "$LEDGER_BEFORE" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-WRITE: the ledger changed from $LEDGER_BEFORE to $LEDGER_AFTER bytes")
fi

# --- quiet for everything else ----------------------------------------------------------------------------
for_quiet() { # $1 = label, $2 = payload
  local out; out="$(run "$2")"
  if [ -z "$out" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("$1: expected silence (got: $(printf '%s' "$out" | head -c 120))"); fi
}
for_quiet "a merge in another project" "$(p "cd $AAL_TMP_N/other && gh pr merge 12 --squash" "$AAL_TMP_N/other")"
for_quiet "gh pr view"                 "$(p "cd $PROJ_N && gh pr view 12 --json state")"
for_quiet "a push"                     "$(p "cd $PROJ_N && git push origin main")"
for_quiet "the phrase as data"         "$(p "grep -rn 'gh pr merge' docs/")"
for_quiet "not a Bash call" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:"/tmp/x.md",content:"gh pr merge 12"}}))')"

summary
