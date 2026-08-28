#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":dod-walk:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

aal_have_node || exit 0

PAYLOAD=$(cat)

TOOL=$(json_get "$PAYLOAD" tool_name)
if [ "$TOOL" != "Bash" ]; then
  exit 0
fi

CMD=$(json_get "$PAYLOAD" command)

IS_MERGE=$(printf '%s' "$CMD" | grep -cE '\bgh[[:space:]]+pr[[:space:]]+merge\b' || true)
if [ "$IS_MERGE" = "0" ]; then
  exit 0
fi

WALKS_DIR="$(aal_resolve_project_dir)/.claude/walks"
if [ ! -d "$WALKS_DIR" ]; then
  exit 0
fi

CURRENT_PR=$(printf '%s' "$CMD" | grep -oE 'merge[[:space:]]+([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
if [ -z "$CURRENT_PR" ]; then
  exit 0
fi

WALK_HIT=$(grep -rl "#${CURRENT_PR}\b\|PR.*${CURRENT_PR}" "$WALKS_DIR"/ 2>/dev/null | head -1 || true)

if [ -z "$WALK_HIT" ]; then
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "PRE-MERGE WALK CHECK: PR #${CURRENT_PR} has no walk artifact in ${WALKS_DIR}/. If this is a UI PR, dispatch a walk agent BEFORE or IMMEDIATELY AFTER merge. If non-UI (docs/deps/infra), proceed — walk not required.\n\nEvery UI PR needs a post-deploy verification of the live/final artifact (for a web app a real-browser Playwright walk or a curl of the deployed page) with a durable artifact in .claude/walks/."
  }
}
EOF
fi

exit 0
