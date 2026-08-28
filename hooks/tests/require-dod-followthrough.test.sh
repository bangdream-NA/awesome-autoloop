#!/usr/bin/env bash
# require-dod-followthrough — a merge whose Definition of Done was deferred rather than done leaves a
# sentence in the ledger and nothing else. Rounds pass, the sentence scrolls away, and the wave is
# remembered as finished. The gate reads the ledger back and blocks the stop while a deferral from a
# few rounds ago has never been cleared.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-dod-followthrough.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
# 🔴 A real git repository, not a bare directory. Once a payload carries a transcript path the gate
# first asks whether this session belongs to an autoloop PROJECT, and that question is answered by
# resolving a repository — a plain temp directory resolves to nothing, so the gate exits early and
# every arm passes without reaching the logic it is about. Measured: the ownership arm and its
# control both went quiet, and only the control revealed why.
REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$REPO_N"
# The ledger directory is a seam. The session id in the op-log FILENAME is what marks the project as
# this session's own — that is how the gate avoids speaking about somebody else's ledger — so the
# fixture names its file accordingly.
export DOD_FT_DIR="$REPO_N/.claude"
SID=abcdef12-2222-3333-4444-555555555555
LEDGER="$REPO/.claude/autoloop-log-2026-08-abcdef12.md"
# Asking GitHub whether each PR really merged needs the network and a real repository; the seam the
# gate provides for exactly this says "assume they did", which is what makes the arms deterministic.
export DOD_FT_ASSUME_MERGED=1
trap 'rm -rf "$AAL_TMP"' EXIT

row() { printf -- '- 2026-08-01 10:00Z · **%s**: %s\n' "$1" "$2"; }
filler() { for i in $(seq 1 6); do printf -- '- 2026-08-01 10:0%sZ · **step**: ordinary progress\n' "$i"; done; }
ledger() { printf '%s\n' "$@" > "$LEDGER"; }
p() { node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1]}))' -- "$SID"; }
# -----------------------------------------------------------------------------------------------

# --- FIRES: a merge whose DoD was deferred, several rounds ago -------------------------------------
ledger "$(row 'merged #1229' 'MERGED, DoD pending deploy')" "$(filler)"
assert_fires "a deferral nobody came back to" "$(p)" '1229'

# --- QUIET: the same deferral, then cleared ----------------------------------------------------------
ledger "$(row 'merged #1229' 'MERGED, DoD pending deploy')" "$(filler)" "$(row 'walked #1229' 'DoD-VERIFIED: curled the dataset, 17 venues')"
assert_quiet "the DoD was verified afterwards" "$(p)"
# A failure that is anchored and has a remedy track is not an open deferral either: it has a stamp and
# a successor, which is the other honest ending.
ledger "$(row 'merged #1229' 'MERGED, DoD pending deploy')" "$(filler)" \
  "$(row 'failed #1229' 'DoD-FAILED · dod-failed-at=2026-08-02T09:00:00Z · dod-remedy-tracks=R-widget-fix')"
assert_quiet "the DoD failed, anchored and tracked" "$(p)"

# --- QUIET: nothing was deferred in the first place -----------------------------------------------------
ledger "$(row 'merged #1229' 'MERGED, DoD-VERIFIED in the same round')" "$(filler)"
assert_quiet "merged and verified together" "$(p)"
ledger "$(row 'planned' 'wrote the plan and dispatched the reviewer')" "$(filler)"
assert_quiet "no merge at all" "$(p)"

# --- QUIET: the deferral is still recent ------------------------------------------------------------------
# Two rounds of grace, because the deploy usually happens in the next round or two. Blocking instantly
# would fire on every merge and teach its reader to skip the message.
ledger "$(row 'merged #1229' 'MERGED, DoD pending deploy')"
assert_quiet "deferred in this very round" "$(p)"

# --- QUIET: nothing to read --------------------------------------------------------------------------------
rm -f "$LEDGER"
assert_quiet "no ledger at all" "$(p)"
ledger ''
assert_quiet "an empty ledger" "$(p)"

# --- whose rows are these: ownership, and the fallback when it cannot be decided --------------------------------
# Two independent ways a row counts as this session's: the session id in the newest ledger filename,
# or the row's text appearing among this turn's own write-tool calls. With NEITHER available — no
# transcript to read — the gate assumes the rows are ours and speaks. That is the safe direction (a
# nag costs a sentence; silence costs a Definition of Done), and it is worth pinning because it is the
# state a fixture meets first.
ledger "$(row 'merged #1229' 'MERGED, DoD pending deploy')" "$(filler)"
out="$(node -e 'process.stdout.write(JSON.stringify({session_id:"99999999-2222-3333-4444-555555555555"}))' | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -q '1229'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-TRANSCRIPT: with nothing to attribute the rows to, the gate stayed silent")
fi
# With a transcript that shows this turn wrote something ELSE, a foreign session is correctly quiet:
# the rows are neither in its filename nor in its own writes.
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1], JSON.stringify({type:"tool_use",name:"Bash",input:{command:"git status --porcelain"}})+"\n");' \
  -- "$AAL_TMP/foreign.jsonl"
out="$(node -e 'process.stdout.write(JSON.stringify({session_id:"99999999-2222-3333-4444-555555555555",transcript_path:process.argv[1]}))' -- "$AAL_TMP_N/foreign.jsonl" | node "$HOOK" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("OWNERSHIP: it spoke about rows belonging to neither its filename nor its own writes (got: $(printf '%s' "$out" | head -c 120))")
fi
# …and the control: the SAME transcript with the owning session id still speaks, so it was ownership
# that silenced the arm above rather than the transcript.
out="$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],transcript_path:process.argv[2]}))' -- "$SID" "$AAL_TMP_N/foreign.jsonl" | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -q '1229'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("OWNERSHIP-CONTROL: the owning session was silent too — the arm above proves nothing")
fi

summary
