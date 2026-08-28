#!/usr/bin/env bash
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
WARN=""
command -v node >/dev/null 2>&1 || WARN="${WARN} node NOT on PATH — every node-dependent DENY gate now fail-CLOSED-denies EVERY matched call (commit/spawn/merge/board-write). Fix PATH before doing anything gated.;"
command -v git  >/dev/null 2>&1 || WARN="${WARN} git NOT on PATH — staging/branch/worktree gates inert.;"
[ -n "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" ] || WARN="${WARN} Agent Teams NOT enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS unset) — the 6-agent pipeline won't work; teammate dispatch fails and block-bare-agent dead-ends dispatch. Set it in settings.json env.;"
CWD=$(cat 2>/dev/null | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{process.stdout.write(String(JSON.parse(s).cwd||""))}catch{}})' 2>/dev/null || echo "")
# The same predicate as the guard on line 5, applied to the session's cwd rather than the resolved
# project dir: the reminder below is only meaningful inside a project that runs the convention.
# This used to be a literal match on one author's home directory and one project name.
IN_SCOPE=1
if [ -n "$CWD" ]; then
  if aal_is_autoloop_project "$CWD"; then IN_SCOPE=1; else IN_SCOPE=0; fi
fi
. "$(dirname "$0")/lib/is-autoloop-lead.sh" 2>/dev/null || true
_SP_REPO=$(aal_resolve_repo "" 2>/dev/null || echo "")
LASTRUN_FILE=""
[ -n "$_SP_REPO" ] && LASTRUN_FILE="$_SP_REPO/.claude/.aal-state/self-improve-last-run"
if [ "$IN_SCOPE" = 1 ] && [ -f "$LASTRUN_FILE" ]; then
  LAST=$(cat "$LASTRUN_FILE" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
  NOW=$(date +%s)
  if [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -ge 86400 ]; then
    WARN="${WARN} self-improve has not run in over 24h — run /self-improve (it reads .gate-denials and the struggle log and PROPOSES changes; it never applies them).;"
  fi
fi
if [ -n "$WARN" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"session preflight:%s"}}' "$(printf '%s' "$WARN" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0
