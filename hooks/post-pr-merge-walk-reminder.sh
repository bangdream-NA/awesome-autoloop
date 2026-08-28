#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":dod-walk:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

aal_have_node || exit 0

INPUT=$(cat)

TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(json_get "$INPUT" command)

# The merge test goes through lib/merge-intent.sh, the ONE owner of "is this an actual merge
# invocation". Grepping the whole command here instead fires on any command that merely QUOTES
# the phrase — `grep -rho 'gh pr merge 1472 --squash' notes.md` produced a full post-merge
# checklist for a PR nobody merged. Two files ask this question; a second private predicate is how
# they drift apart.
# shellcheck source=lib/merge-intent.sh
. "$(dirname "$0")/lib/merge-intent.sh" 2>/dev/null || true
if command -v is_merge_invocation >/dev/null 2>&1; then
  is_merge_invocation "$CMD" || exit 0
else
  echo "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0
fi

RESPONSE=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{try{const j=JSON.parse(s);const r=j.tool_response||{};process.stdout.write([r.stdout,r.output,r.stderr].filter(Boolean).join("\n"))}catch{}})' 2>/dev/null || echo "")
echo "$RESPONSE" | grep -qiE 'merged|merging|squash|already merged|✓' || exit 0

# `|| true` on THIS assignment only: grep exiting 1 means "no PR number in the command", which the
# guard on the next line handles explicitly. Without it `set -e` aborts the whole gate with rc=1
# before that guard runs, and the harness sees a hook that failed rather than one that had nothing
# to say. (The sibling reminder already spells it this way.)
PR_NUM=$(echo "$CMD" | grep -oE 'gh pr merge[[:space:]]+[0-9]+' | grep -oE '[0-9]+' | head -1 || true)
# A merge command with no resolvable PR number yields an empty PR_NUM, and the reminder then
# names no pull request at all. Silence is the correct output when the gate cannot say WHICH
# PR it is talking about.
[ -z "$PR_NUM" ] && exit 0
PR_LABEL="${PR_NUM:-?}"

SESSION_ID=$(json_get "$INPUT" session_id)
# Both state locations take an env override, defaulting to today's behaviour. Without a seam
# this gate writes its throttle flag into the plugin's own directory, so a fixture cannot
# isolate it: every test run leaves flags in the installed tree and the throttle then makes
# later runs silent — a fixture that passes once and reads "silent" forever after. The sibling
# reminder already parameterises its sentinel through TMPDIR.
STATE_DIR="${AAL_HOOK_STATE_DIR:-$(dirname "$0")/.state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
# This hook is mounted on TWO events, so the event name it ECHOES has to be the one it RECEIVED.
# Hard-coding "PostToolUse" makes the harness reject the response outright ("Hook returned incorrect
# event name") on the other mount — and the failing path is the one that runs when a command
# FAILED, i.e. exactly when the reminder matters.
EVENT=$(printf '%s' "$PAYLOAD" | node -e "let s=''; process.stdin.on('data',c=>s+=c); process.stdin.on('end',()=>{try{const o=JSON.parse(s);process.stdout.write(o.hook_event_name||'')}catch{}});" 2>/dev/null || echo "")
[ -z "$EVENT" ] && EVENT="PostToolUse"
SENTINEL="$STATE_DIR/walk-reminded-${SESSION_ID}-pr${PR_LABEL}.flag"
[ -f "$SENTINEL" ] && exit 0
touch "$SENTINEL" 2>/dev/null || true
find "$STATE_DIR" -name 'walk-reminded-*.flag' -mtime +2 -delete 2>/dev/null || true

if [ -n "$PR_NUM" ]; then
  REPO_DIR=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$REPO_DIR" ]; then
    GIT_COMMON=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")
    MAIN_REPO=$(dirname "$GIT_COMMON" 2>/dev/null || echo "$REPO_DIR")
    WALKS_DIR="${AAL_WALKS_DIR:-$MAIN_REPO/.claude/walks}"
    [ -d "$WALKS_DIR" ] && touch "$WALKS_DIR/.pending-pr${PR_NUM}" 2>/dev/null || true
  fi
fi

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"$EVENT","additionalContext":"PR #${PR_LABEL} merge succeeded. A wave is NOT ship-complete at merge — verify the live/final artifact per your project's nature before considering it done. For a web app, a real-browser walk (Playwright) or a curl of the deployed page; for a CLI, run the built binary; for a library, exercise the public API. Your project's CLAUDE.md/rules define what 'the walk' means. Pre-merge static + CI checks are necessary but not sufficient — the live walk catches deploy/cache/build-pipeline issues invisible to static checks. Record a .claude/walks/*.md artifact mentioning this PR# (or 'PR #N: non-UI, walk N/A — <reason>')."}}
EOF
exit 0
