#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
INPUT=$(cat)
if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this merge-reconcile gate, and node was not found. Install node >=18, or disable the plugin / remove the merge-gates group from AAL_GATES. (Fail-closed: a gate that can't evaluate must not silently allow an unreconciled merge.)"}}
JSON
  exit 0
fi

TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Bash" ] || exit 0
CMD=$(json_get "$INPUT" command)
printf '%s' "$CMD" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || exit 0

PROJ_DIR=$(aal_extract_cd_target "$CMD")
if [ -z "$PROJ_DIR" ] || [ ! -d "$PROJ_DIR" ]; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED merge (fail-closed): cannot resolve WHICH project this merge belongs to — no `cd <project-dir>` found in the command. Run it as `cd <project-dir> && gh pr merge <N> ...` so the gate reconciles THAT project's BACKLOG. The gate never guesses or defaults to another project's board."}}
JSON
  exit 0
fi
BACKLOG="$PROJ_DIR/.claude/BACKLOG.md"
[ -f "$BACKLOG" ] || exit 0
REPO=$(git -C "$PROJ_DIR" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#^(https://[^/]+/|git@[^:]+:)##' || true)
if [ -z "$REPO" ]; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED merge (fail-closed): the project has a .claude/BACKLOG.md but its git origin remote could not be resolved, so the merged-PR cross-ref cannot run. Fix the origin remote (or correct the cd prefix) and re-run."}}
JSON
  exit 0
fi

if MERGED_RAW=$(gh pr list --repo "$REPO" --state merged --limit 15 --json headRefName --jq '.[].headRefName' 2>/dev/null); then
  MERGED_SLUGS=$(printf '%s' "$MERGED_RAW" | sed 's#^feat/##' | grep -v '^$' || true)
  [ -z "$MERGED_SLUGS" ] && MERGED_SLUGS="__NONE__"
else
  MERGED_SLUGS=""
fi

node "$(dirname "$0")/require-backlog-reconciled-before-merge.cjs" "$BACKLOG" "$MERGED_SLUGS"
exit 0
