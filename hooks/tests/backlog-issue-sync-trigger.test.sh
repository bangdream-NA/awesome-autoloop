#!/usr/bin/env bash
# backlog-issue-sync-trigger — runs the issue mirror after a board write, so the tracker follows the
# card rather than the other way round. Everything it does is a decision about WHETHER to run: the
# file has to be a board, the project has to resolve, and the repository has to have a remote.
#
# 🔴 The run itself is `--apply`, which CREATES AND EDITS REAL ISSUES through the GitHub CLI. No arm
# here reaches it, and that is deliberate rather than an omission: a fixture that published issues
# would be doing the one thing no test may do. The sandbox repository has no remote, which is what
# makes the last guard the natural stopping point — and that guard is itself worth pinning, because
# it is what protects every adopter whose checkout has no origin yet.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/backlog-issue-sync-trigger.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"
export CLAUDE_CONFIG_DIR="$AAL_TMP/config"
mkdir -p "$AAL_TMP/config"
printf '# Backlog\n' > "$REPO/.claude/BACKLOG.md"

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",cwd:process.argv[2],tool_input:{file_path:process.argv[1],content:"x"}}))' -- "$1" "$REPO_N"; }
run() { printf '%s' "$1" | bash "$HOOK" 2>&1; }
quiet() { # $1 = label, $2 = payload
  local out; out="$(run "$2")"; local rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("$1: rc=$rc out='$(printf '%s' "$out" | head -c 120)'"); fi
}
# -----------------------------------------------------------------------------------------------

# --- the file filter ------------------------------------------------------------------------------
# A board write is the trigger; everything else has to leave immediately, because the alternative is
# running a GitHub sync after every edit in the repository.
quiet "a plan document"   "$(p "$REPO_N/docs/product-specs/R-widget-plan.md")"
quiet "a source file"     "$(p "$REPO_N/src/widget.ts")"
quiet "the op-log"        "$(p "$REPO_N/.claude/autoloop-log-2026-08.md")"
quiet "a detail ledger"   "$(p "$REPO_N/.claude/BACKLOG-detail-2026-08.md")"

# --- the remote guard, which is where a board write stops in a repository with no origin --------------
# This is the state a fresh clone or a local-only project is in, and it has to be silent rather than
# an error: an adopter with no remote is not doing anything wrong.
quiet "the board, with no remote configured"   "$(p "$REPO_N/.claude/BACKLOG.md")"
quiet "the archive, with no remote configured" "$(p "$REPO_N/.claude/BACKLOG-archive.md")"

# --- and nothing was written or published ----------------------------------------------------------------
# The sync writes its own log next to the configuration; the absence of that file is the evidence that
# the apply path was never entered.
if [ ! -e "$AAL_TMP/config/.backlog-issue-sync.log" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("APPLY-REACHED: the sync log exists, so the publishing path ran")
fi

# --- payloads with no file at all --------------------------------------------------------------------------
quiet "not a write"       "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"git status"}}))')"
quiet "an empty payload"  "$(node -e 'process.stdout.write(JSON.stringify({}))')"

summary
