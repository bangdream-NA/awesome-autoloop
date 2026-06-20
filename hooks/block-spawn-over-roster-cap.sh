#!/usr/bin/env bash
# PreToolUse(Agent) — ENFORCE shutdown-done-agents as a HARD gate.
# A shell hook cannot SendMessage-shutdown an agent, so we enforce the INVERSE:
# DENY a NEW teammate spawn once the live roster is at/over the cap. To spawn, you must
# first shut down a done/idle teammate (config.json `members` PRUNES on shutdown → killing
# a done agent frees the slot). Reuse is NOT an escape hatch (block-non-codereviewer-mode-b
# forbids recycling an agent across waves/roles).
# Default ALLOW; DENY only when roster >= CAP.
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
# Node absent → can't parse the payload to evaluate the at/over-cap match.
# This gate is default-ALLOW (denies only at cap); a static deny would OVER-BLOCK
# every spawn, so noop instead; the SessionStart preflight warns node is missing.
aal_have_node || exit 0
INPUT=$(cat)
TOOL=$(json_get "$INPUT" tool_name)
[ "$TOOL" = "Agent" ] || exit 0

# CAP is a generous anti-wedge BACKSTOP (the spawn/TeamDelete catch-22), NOT a parallelism
# limiter: with shutdown-on-accept each in-flight wave occupies ~1 live agent (roles hand off
# + shut down), so 16 leaves headroom for ~12 concurrent waves. The PRIMARY mechanism is
# shutdown-on-deliverable-accept; this cap only bites on HOARDING. Tune via env.
CAP="${AAL_ROSTER_CAP:-16}"
TEAMS_DIR="$HOME/.claude/teams"
[ -d "$TEAMS_DIR" ] || exit 0

# C-16: count ONLY this spawn's target team (the Agent payload carries team_name) so a
# stale dead-session dir can't permanently deny every spawn. Defense-in-depth: prune team
# dirs untouched >2 days (= dead sessions) so they don't inflate any count, never the current.
TEAM_NAME=$(json_get "$INPUT" team_name)
find "$TEAMS_DIR" -maxdepth 1 -type d -mtime +2 2>/dev/null | while IFS= read -r d; do
  [ "$d" = "$TEAMS_DIR" ] && continue
  [ -n "$TEAM_NAME" ] && [ "$(basename "$d")" = "$TEAM_NAME" ] && continue
  rm -rf "$d" 2>/dev/null || true
done

# Scope the cap to the spawn's TARGET team ONLY — NOT a global max across all teams.
# FIX R-14 (cross-session-scope class; same disease as roster-tripwire): the old `else` global-max
# counted a CONCURRENT NEIGHBOR session's team and false-denied a spawn into THIS session's near-
# empty team. A lead can only shut down ITS OWN team's agents, so gating on another live session's
# roster is unactionable + wrong. No target team_name → allow (cannot over-fill a specific roster);
# the `else` was effectively unreachable anyway (block-bare-agent denies an Agent spawn missing
# team_name) — belt-and-suspenders. HOME ~/.claude/hooks/block-spawn-over-roster-cap.sh:28-37 referent.
[ -z "$TEAM_NAME" ] && exit 0   # no resolvable target team → cannot over-fill a specific roster → allow
N=0; BIG="$TEAM_NAME"
if [ -f "$TEAMS_DIR/$TEAM_NAME/config.json" ]; then
  N=$(node -e 'try{const j=require(process.argv[1]);console.log((j.members||[]).length)}catch(e){console.log(0)}' "$TEAMS_DIR/$TEAM_NAME/config.json" 2>/dev/null)
  case "$N" in (*[!0-9]*|'') N=0 ;; esac
fi
# team config not created yet → N stays 0 → first spawn → allowed below.

if [ "$N" -ge "$CAP" ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED spawn: team '${BIG}' live roster = ${N} (cap ${CAP}). shutdown-on-accept ENFORCED — before spawning a NEW teammate, shut down a done/idle one (SendMessage shutdown_request to any whose deliverable is accepted: merged PR / APPROVED review / handed-off spec). config.json members PRUNES on shutdown, so killing a done agent frees the slot. Do NOT reuse an existing agent instead — that mixes context. Then re-spawn."}}
EOF
  exit 0
fi
exit 0
