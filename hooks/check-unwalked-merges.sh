#!/usr/bin/env bash

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":dod-walk:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"

aal_have_node || exit 0

INPUT=$(cat 2>/dev/null || echo '{}')

STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
[ -n "$STOP_ACTIVE" ] && exit 0

WALKS_DIR="$(aal_resolve_project_dir)/.claude/walks"
[ -d "$WALKS_DIR" ] || exit 0

shopt -s nullglob 2>/dev/null || true
PENDING=("$WALKS_DIR"/.pending-pr*)
[ ${#PENDING[@]} -eq 0 ] && exit 0

BLOCKED=""
for sentinel in "${PENDING[@]}"; do
  [ -e "$sentinel" ] || continue
  PR=$(basename "$sentinel" | sed -E 's/^\.pending-pr//')
  [ -z "$PR" ] && continue
  if grep -rqE "#${PR}\b|PR[[:space:]]*${PR}\b|pr${PR}\b" "$WALKS_DIR"/*.md 2>/dev/null; then
    rm -f "$sentinel" 2>/dev/null || true
  else
    BLOCKED="${BLOCKED} #${PR}"
  fi
done

[ -z "$BLOCKED" ] && exit 0

REASON="POST-MERGE WALK REQUIRED before ending. These merged PRs have no walk artifact in ${WALKS_DIR}/:${BLOCKED}. Either (a) verify the live/final artifact per your project's nature (for a web app a real-browser Playwright walk or a curl of the deployed page; for a CLI run the built binary; for a library exercise the public API) and write/append a .claude/walks/*.md artifact mentioning each PR#, OR (b) for non-UI/infra PRs, add a line 'PR #N: non-UI, walk N/A — <reason>' to a walks .md. Re-stopping after that auto-clears the gate."

printf '{"decision":"block","reason":"%s"}\n' "$REASON"
exit 0
