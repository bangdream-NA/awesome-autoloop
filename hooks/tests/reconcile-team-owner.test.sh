#!/usr/bin/env bash
# reconcile-team-owner — a reopened window gets a new session id while the team roster still records
# the old one, so the lead's own team reads as somebody else's and messages pile up unread with no
# symptom. This diagnoses that split and, only when told to, rewrites the owner. Its refusals are the
# interesting part: handing the wrong team to the wrong session is worse than the split it fixes.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HOOKS_DIR/reconcile-team-owner.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/teams/session-aaaaaaaa" "$AAL_TMP/state"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
trap 'rm -rf "$AAL_TMP"' EXIT

# Both directories are seams. Left at their defaults this would read — and with --fix REWRITE — the
# rosters of whatever teams are running on the operator's machine.
export RTO_TEAMS_DIR="$AAL_TMP_N/teams"
export RTO_STATE_DIR="$AAL_TMP_N/state"

MY_SID=11111111-2222-3333-4444-555555555555
OTHER_SID=99999999-8888-7777-6666-555555555555
export CLAUDE_CODE_SESSION_ID="$MY_SID"

cfg() { # $1 = leadSessionId
  node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1], JSON.stringify({leadSessionId:process.argv[2],members:[{name:"team-lead"},{name:"dev-widget",agentType:"developer"}]},null,2));' \
    -- "$AAL_TMP/teams/session-aaaaaaaa/config.json" "$1"
}
# The sid log is what the fix checks against: it will not align a team to a session id nobody has
# ever seen end a turn, because a typo there hands the team to a session that does not exist.
seen() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$AAL_TMP/state/stop-stdin-sids.log"; }
lead_of() { node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).leadSessionId||""));' -- "$AAL_TMP/teams/session-aaaaaaaa/config.json"; }
# -----------------------------------------------------------------------------------------------

# --- diagnose: it reports, and changes nothing -----------------------------------------------------
cfg "$OTHER_SID"; seen "$MY_SID"
out="$(node "$TOOL" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'DIAGNOSE' && [ "$(lead_of)" = "$OTHER_SID" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("DIAGNOSE: rc=$rc owner-now=$(lead_of) out='$(printf '%s' "$out" | head -c 120)'")
fi
# …and it names the split it found, with the command that would fix it.
if printf '%s' "$out" | grep -q 'ID-SPLIT candidates'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("DIAGNOSE-SPLIT: the split was not reported (out: $(printf '%s' "$out" | tail -c 160))")
fi

# --- fix: the owner is rewritten, and the old one is kept ---------------------------------------------
out="$(node "$TOOL" --fix --team session-aaaaaaaa --to "$MY_SID" 2>&1)"; rc=$?
prev="$(node -e 'const fs=require("fs");process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).prevLeadSessionId||""));' -- "$AAL_TMP/teams/session-aaaaaaaa/config.json")"
if [ "$rc" -eq 0 ] && [ "$(lead_of)" = "$MY_SID" ] && [ "$prev" = "$OTHER_SID" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("FIX: rc=$rc owner=$(lead_of) prev=$prev")
fi
# Running it again is a no-op rather than an error: the state it wants already holds.
out="$(node "$TOOL" --fix --team session-aaaaaaaa --to "$MY_SID" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'no-op'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("IDEMPOTENT: rc=$rc out='$(printf '%s' "$out" | head -c 120)'")
fi

# --- the refusals ------------------------------------------------------------------------------------------
# A session id nobody has seen end a turn is most likely a typo, and acting on it hands the team to a
# session that will never read it — the same failure the tool exists to repair, in a new place.
cfg "$OTHER_SID"; seen "$MY_SID"
out="$(node "$TOOL" --fix --team session-aaaaaaaa --to 12345678-0000-0000-0000-000000000000 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'REFUSED' && [ "$(lead_of)" = "$OTHER_SID" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("UNSEEN-SID: rc=$rc owner=$(lead_of) out='$(printf '%s' "$out" | head -c 120)'")
fi
# A team directory that does not exist is refused rather than created.
out="$(node "$TOOL" --fix --team session-nope --to "$MY_SID" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'not found'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("UNKNOWN-TEAM: rc=$rc out='$(printf '%s' "$out" | head -c 120)'")
fi
# And with neither argument it says what it needs rather than guessing.
out="$(node "$TOOL" --fix 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'need --team'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-ARGS: rc=$rc out='$(printf '%s' "$out" | head -c 120)'")
fi

# --- auto: it aligns only when there is exactly one candidate ---------------------------------------------------
cfg "$OTHER_SID"; seen "$MY_SID"
out="$(node "$TOOL" --fix --auto 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(lead_of)" = "$MY_SID" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("AUTO-ONE: rc=$rc owner=$(lead_of) out='$(printf '%s' "$out" | head -c 120)'")
fi
# With a second candidate it REFUSES to guess. Aligning the wrong team is silent and hard to notice,
# so "I do not know which" has to end in doing nothing rather than in a coin flip.
mkdir -p "$AAL_TMP/teams/session-bbbbbbbb"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1], JSON.stringify({leadSessionId:process.argv[2],members:[{name:"team-lead"},{name:"dev-other",agentType:"developer"}]},null,2));' \
  -- "$AAL_TMP/teams/session-bbbbbbbb/config.json" "$OTHER_SID"
cfg "$OTHER_SID"
out="$(node "$TOOL" --fix --auto 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'REFUSING to guess' && [ "$(lead_of)" = "$OTHER_SID" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("AUTO-MANY: rc=$rc owner=$(lead_of) out='$(printf '%s' "$out" | head -c 140)'")
fi

summary
