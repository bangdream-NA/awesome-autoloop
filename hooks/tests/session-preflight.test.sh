#!/usr/bin/env bash
# session-preflight — the checks worth making before a session starts working, because each of them
# fails SILENTLY later. A missing node turns every node-backed gate into a denial of everything it
# matches; a missing git makes the staging gates inert; teams not being enabled makes a dispatch fail
# in a way that reads like the agent died.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/session-preflight.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude/.aal-state" "$AAL_TMP/emptybin"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
PROJ_N="$AAL_TMP_N/proj"
aal_pin_project "$PROJ_N"
trap 'rm -rf "$AAL_TMP"' EXIT

p() { node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1]}))' -- "$PROJ_N"; }
run() { p | bash "$HOOK" 2>&1; }
# -----------------------------------------------------------------------------------------------

# --- the teams warning, which is the one an adopter meets first ---------------------------------------
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='' run)"
if printf '%s' "$out" | grep -q 'Agent Teams NOT enabled'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("TEAMS: no warning with the flag unset (got: $(printf '%s' "$out" | head -c 140))")
fi
# …and with it set, that sentence goes away. Without this arm the warning could be unconditional and
# every arm above would still pass.
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run)"
if ! printf '%s' "$out" | grep -q 'Agent Teams NOT enabled'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("TEAMS-CONTROL: the warning persists with the flag set")
fi

# --- the self-improve reminder, driven by the timestamp it reads ----------------------------------------
aal_date_rel '-3 days' +%s > "$AAL_TMP/proj/.claude/.aal-state/self-improve-last-run"
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run)"
if printf '%s' "$out" | grep -q 'self-improve has not run'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SELF-IMPROVE: no reminder for a three-day-old run (got: $(printf '%s' "$out" | head -c 140))")
fi
date -u +%s > "$AAL_TMP/proj/.claude/.aal-state/self-improve-last-run"
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run)"
if ! printf '%s' "$out" | grep -q 'self-improve has not run'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SELF-IMPROVE-CONTROL: the reminder persists right after a run")
fi
# A project that has never run it has nothing to be reminded about — the file's absence is not the
# same as it being old, and treating it as old would greet every new adopter with a warning.
rm -f "$AAL_TMP/proj/.claude/.aal-state/self-improve-last-run"
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run)"
if ! printf '%s' "$out" | grep -q 'self-improve has not run'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SELF-IMPROVE-NEVER: a project that never ran it was reminded anyway")
fi

# --- with everything in place it says nothing at all ------------------------------------------------------
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 run)"
if [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("QUIET: a healthy session still produced output (got: $(printf '%s' "$out" | head -c 140))")
fi

# --- outside a project that runs the convention, nothing is checked ------------------------------------------
out="$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='' CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' \
  node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1]}))' -- "$AAL_TMP_N/not-a-project" \
  | CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS='' CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' bash "$HOOK" 2>&1)"
if [ -z "$out" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("SCOPE: it warned outside an autoloop project (got: $(printf '%s' "$out" | head -c 140))")
fi

summary
