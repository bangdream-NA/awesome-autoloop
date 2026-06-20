#!/usr/bin/env bash
# preflight.sh — SessionStart hook. Advisory (exit 0 always; never denies).
# Probes node/git/bash resolvability + validates AAL_GATES tokens (C-06), so a
# missing dependency or a typo'd gate group surfaces a VISIBLE warning at session
# start instead of silently fail-closing (node-absent deny gates) or silently
# DISABLING gates (an AAL_GATES typo self-skips every gate in the bad group).
#
# Ceiling (honest): on Windows-without-git-bash, bash itself is absent so this
# hook never runs (it can't detect its own absence). README Install step-0 is the
# only surface that warns a no-bash user; this catches the node/git/AAL_GATES cases
# where bash DOES run.
set -uo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
WARN=""
command -v node >/dev/null 2>&1 || WARN="${WARN} node NOT on PATH — every node-dependent DENY gate now fail-CLOSED-denies EVERY matched call (commit/spawn/merge). Install node >=18.;"
command -v git  >/dev/null 2>&1 || WARN="${WARN} git NOT on PATH — staging/branch gates inert.;"
# AAL_GATES typo validation (C-06): every token must be a known group.
GATES="${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk}"
IFS=':,' read -r -a _toks <<< "$GATES"
for t in ${_toks[@]+"${_toks[@]}"}; do
  [ -z "$t" ] && continue
  case "$t" in commit-hygiene|pipeline-roles|merge-gates|ledger-hygiene|dod-walk) ;;
    *) WARN="${WARN} AAL_GATES has an unknown group '$t' — every gate self-skips unless its group is listed, so a typo SILENTLY DISABLES gates. Known: commit-hygiene pipeline-roles merge-gates ledger-hygiene dod-walk.;" ;;
  esac
done
# Agent Teams prereq: pipeline-roles needs CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (the harness exports
# settings.json env to this hook — verified). Scoped to pipeline-roles; advisory only.
case ":$GATES:" in *":pipeline-roles:"*)
  [ -n "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" ] || WARN="${WARN} Agent Teams NOT enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS unset) — the 5-agent pipeline won't work; teammate dispatch fails and block-bare-agent dead-ends dispatch. Set it in settings.json env.;"
  ;;
esac
# R-8: profiler-pending + self-improve cadence nudges (advisory; same group-gate + activation guard).
PROJECT_DIR=$(aal_resolve_project_dir 2>/dev/null || echo "")
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR/.claude" ]; then
  # (Gap B) pending-profile: the installer dropped .pending-profile and the user hasn't profiled/dismissed.
  if [ -f "$PROJECT_DIR/.claude/.pending-profile" ]; then
    WARN="${WARN} This project was installed but not yet tailored — run /project-profiler to scan the stack and propose a tailored AAL_GATES / live-verify walk / stack-rules setup (it PROPOSES; nothing is written without your approval). To stop this reminder without profiling, delete .claude/.pending-profile.;"
  fi
  # (Gap D) self-improve >24h cadence: durable, session-INDEPENDENT last-run marker (rotation-proof).
  LASTRUN_FILE="$PROJECT_DIR/.claude/.aal-state/self-improve-last-run"
  if [ -f "$LASTRUN_FILE" ]; then
    LAST=$(cat "$LASTRUN_FILE" 2>/dev/null || echo 0)
    case "$LAST" in (*[!0-9]*|'') LAST=0 ;; esac
    NOW=$(date +%s)
    if [ "$LAST" -gt 0 ] && [ $((NOW - LAST)) -ge 86400 ]; then
      WARN="${WARN} self-improve last ran >24h ago — run /self-improve to review accumulated .gate-denials + struggle-log and PROPOSE durable improvements (it never auto-applies).;"
    fi
  fi
fi
if [ -n "$WARN" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"awesome-autoloop preflight:%s"}}' "$(printf '%s' "$WARN" | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0
