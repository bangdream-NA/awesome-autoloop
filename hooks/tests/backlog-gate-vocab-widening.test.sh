#!/usr/bin/env bash
# Must-GREEN arms for the ENGLISH-ISATION WIDENINGS in hooks/backlog-gate-vocab.mjs.
#
# Why this fixture exists, and why must-red arms alone would not catch what it catches:
# English-ising a vocabulary gate is two moves in one edit. The Chinese alternates are
# SUBTRACTED from the board-text regexes, and the English side is WIDENED where the Chinese
# carried a sense English lacked. A must-red payload ("this must still DENY") answers only
# "did the subtraction break the gate". A widened alternation fails by OVER-firing, and no
# must-red can see that: the gate denies more, so every red arm stays green while the gate
# starts crying wolf on ordinary board prose.
#
# So each widened alternation gets a PAIR:
#   R<n>  must-RED   - the new word in its real violating sense; proves the alternation is live.
#                      Without it a GREEN arm could pass on a dead alternation and say nothing.
#   G<n>  must-GREEN - the same new word in a LEGITIMATE sense, as close to the widened boundary
#                      as the sense allows; asserts the gate stays SILENT.
#
# GREEN arms assert stdout is EXACTLY `{}`. Asserting merely "no deny" would score a crashed
# gate (empty stdout) as a pass, which is the same blind spot one level down.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$(cd "$HERE/.." && pwd)/backlog-gate-vocab.mjs"
BOARD="/tmp/aal-vocab-widening/.claude/BACKLOG.md"

export AAL_GATE_DENIALS_OFF=1

PASS=0; FAIL=0; FAILURES=()

payload() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","new_string":"%s"}}' "$1" "$2"
}

run() { payload "${2:-$BOARD}" "$1" | node "$HOOK" 2>&1; }

# must-RED: the gate has to deny, AND for the bucket we claim, not some neighbouring one.
red() {
  local desc="$1"; local line="$2"; local want="$3"; local out
  out="$(run "$line")"
  if ! printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY-BUT-ALLOWED: $desc (got: $(printf '%s' "$out" | head -c 160))")
  elif ! printf '%s' "$out" | grep -qF "$want"; then
    FAIL=$((FAIL+1)); FAILURES+=("DENIED-BY-THE-WRONG-BUCKET: $desc (want '$want' - got: $(printf '%s' "$out" | head -c 200))")
  else
    PASS=$((PASS+1))
  fi
}

# must-GREEN: exactly `{}`. Not "no deny" - a crash also produces no deny.
green() {
  local desc="$1"; local line="$2"; local fp="${3:-$BOARD}"; local out
  out="$(run "$line" "$fp")"
  if [ "$out" = "{}" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-SILENT-ALLOW: $desc (got: $(printf '%s' "$out" | head -c 200))")
  fi
}

# ---------------------------------------------------------------------------
# 1. GRANT_NOUN gained `authorisation` and `sign-off`.
# ---------------------------------------------------------------------------
red   "R1 sign-off in a grant sense still denies" \
      "### [BLOCKED] R-cf-token-rotate · P1 · DoD-GATED: still awaiting sign-off from the platform owner · observe-until 2026-09-10" \
      "SOMETHING A PERSON MUST GIVE YOU"

# Both new words present, neither is a grant being waited on: the card's SUBJECT is
# authorisation, and the sign-off page is a thing that was built, not a thing owed.
green "G1 authorisation/sign-off as subject matter, nobody owes anything" \
      "### [BLOCKED] R-authz-header-cache · P2 · DoD-GATED: the authorisation-header cache purge and the sign-off checklist page are deployed and verified first-hand · only the 24h TTL rollover remains · observe-until 2026-09-05"

# ---------------------------------------------------------------------------
# 2. The waiting-verb half of HUMAN_GRANT_RE gained `only`, `still`, `needs`, `requires`.
#    Four words that appear in ordinary board prose constantly - the over-fire risk is the point.
# ---------------------------------------------------------------------------
red   "R2 still/needs beside a real grant noun still denies" \
      "### [BLOCKED] R-deploy-key-rotate · P1 · DoD-GATED: the deploy still needs the production API key from the account owner · observe-until 2026-09-02" \
      "SOMETHING A PERSON MUST GIVE YOU"

# The boundary: a grant noun IS present and one of the four new verbs IS present, but the grant
# was already given. Nobody owes anything, so a calendar really does clear this one.
green "G2 the four new verbs beside an ALREADY-GRANTED grant noun" \
      "### [BLOCKED] R-token-propagation · P2 · DoD-GATED: the token was granted and installed first-hand · only the 24h propagation window is left, and the passage of time alone clears it · observe-until 2026-09-08"

# ---------------------------------------------------------------------------
# 3. EXECUTOR_US_RE gained the English executor forms (`falls/belongs/down to lead|me`,
#    `by/for me|lead to <verb>`).
# ---------------------------------------------------------------------------
red   "R3 falls-to-lead still denies" \
      "### [BLOCKED] R-partition-walk · P2 · DoD-GATED: the remaining walk falls to lead · observe-until 2026-09-03" \
      "names YOU as the executor"

# Boundary: contains `falls to`, and a following `it`. Neither is an executor claim - the cost
# falls to a bill, and the verb is not one of ours.
green "G3 falls-to-a-bill is not an executor claim" \
      "### [BLOCKED] R-edge-cache-expiry · P3 · DoD-GATED: the partition rebuild ran first-hand, the retry cost falls to the CDN bill, and the walk file lands with it · observe-until 2026-09-04"

# ---------------------------------------------------------------------------
# 4. EXECUTOR_NOUN_RE gained `in person` and `the user`.
# ---------------------------------------------------------------------------
red   "R4 the-user-must-run-it still denies" \
      "### [BLOCKED] R-sudoers-tighten · P1 · DoD-GATED: the sudoers change still needs the user to run it in the console · observe-until 2026-09-06" \
      "AN ACTION A PERSON MUST TAKE"

# Boundary: both new nouns present, plus `console`, and the action is in the PAST. Silent
# because no outstanding-verb precedes any of them inside the same segment.
green "G4 in-person and the-user in the past tense" \
      "### [BLOCKED] R-banner-rollout · P2 · DoD-GATED: the console step was executed in person on 2026-08-24 and the user confirmed the banner · only the 30-day metric window is left · observe-until 2026-09-23"

# ---------------------------------------------------------------------------
# 5. OUTSTANDING_RE gained `lacks`, `missing`, `outstanding`, `remaining`, `left`,
#    plus an optional `only|still|just` prefix.
# ---------------------------------------------------------------------------
red   "R5 outstanding + console still denies" \
      "### [BLOCKED] R-root-install · P1 · DoD-GATED: the root install is outstanding, the console is the only place it can be typed · observe-until 2026-09-07" \
      "AN ACTION A PERSON MUST TAKE"

# Boundary: three of the five new words are present AND an executor noun is present, but in
# DIFFERENT segments. Segment isolation is the predicate's own semantics, so this arm is the one
# that fails first if someone widens the 60-char window or drops the segment split.
green "G5 new outstanding words and an executor noun in different segments" \
      "### [BLOCKED] R-lastmod-backfill · P2 · DoD-GATED: 3 partitions are still missing lastmod · the console step was already executed first-hand on 2026-08-25 · only the weekly window is left · observe-until 2026-09-09"

# ---------------------------------------------------------------------------
# 6. TRIGGERABLE_RE gained `scheduled` and `rerun`.
# ---------------------------------------------------------------------------
red   "R6 a rerun with no manual-trigger-checked still denies" \
      "### [BLOCKED] R-nightly-fix · P2 · DoD-GATED: waiting for the nightly rerun to pick the fix up · observe-until 2026-09-11" \
      "has a trigger command"

green "G6 rerun with manual-trigger-checked= is silent" \
      "### [BLOCKED] R-partition-republish · P2 · DoD-GATED: the rerun was triggered first-hand at 2026-08-26T01:10Z and takes 6 days · manual-trigger-checked=2026-08-26T01:10Z, 6-day window · observe-until 2026-09-01"

# B6 records a boundary this widening does NOT draw precisely, instead of hiding it.
# `scheduled` fires on ANY occurrence inside a gate declaration, including a window owned by a
# third party that we could not trigger even if we wanted to. The only thing bounding that
# surface is the manual-trigger-checked= escape hatch. Asserting the CURRENT behaviour here
# means a future narrowing of TRIGGERABLE_RE fails this arm loudly instead of silently.
red   "B6 documented over-fire: a third-party scheduled window also denies (bounded only by the escape hatch)" \
      "### [BLOCKED] R-provider-maintenance · P3 · DoD-GATED: the upstream provider scheduled its own maintenance window and it closes on 2026-09-02 · observe-until 2026-09-03" \
      "has a trigger command"

# ---------------------------------------------------------------------------
# 7. The `I'll <verb> it` executor form. Both directions in one edit:
#    ADDED    the ASCII-apostrophe spelling, which an English board actually writes;
#    REMOVED  a bare `ll` alternative, which made `still run it` an executor claim.
#    R7 guards the addition, G7 guards the removal.
# ---------------------------------------------------------------------------
red   "R7 an ASCII-apostrophe I'll-run-it is an executor claim" \
      "### [BLOCKED] R-partition-job-wait · P2 · DoD-GATED: I'll run it myself once the partition job frees up · observe-until 2026-09-12" \
      "names YOU as the executor"

green "G7 still-handle-it is ordinary prose, not an executor claim" \
      "### [BLOCKED] R-retry-loop · P3 · DoD-GATED: the retry loop and the queue drain still handle it without anyone here · observe-until 2026-09-13"

# ---------------------------------------------------------------------------
# Controls for this fixture itself.
# ---------------------------------------------------------------------------
# C1 - the payload really reaches the gate: R1's own violating line, on a NON-board path, is
# allowed. Paired with R1 on the identical string, so a payload that never parsed cannot make
# both pass.
green "C1 the R1 line on a non-board path is allowed (path filter, not a dead payload)" \
      "### [BLOCKED] R-cf-token-rotate · P1 · DoD-GATED: still awaiting sign-off from the platform owner · observe-until 2026-09-10" \
      "/tmp/aal-vocab-widening/docs/NOTES.md"

# C2 - must-red control for the harness itself. If C2 ever goes green, red() is reading the
# wrong channel and every R arm above is uninformative.
red   "C2 harness control: an illegal gate token denies" \
      "### [BLOCKED] R-control-card · P3 · blocked-by=someday · stub" \
      "illegal gate token"

name="$(basename "$0")"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS) (arms run: $TOTAL)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail) (arms run: $TOTAL)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
