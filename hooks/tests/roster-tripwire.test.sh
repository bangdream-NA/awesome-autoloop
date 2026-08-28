#!/usr/bin/env bash
# Fixtures for roster-tripwire.sh — R-destructive-hooks-infer-instead-of-verify.
# STALE/ACTIVE/UNKNOWN now reads each agent's OWN structural anchor (the `# CARD: <slug>`
# first line of its dispatch brief, persisted VERBATIM into config.json's member.prompt at
# spawn time by the harness itself — §0.2, no new hook needed) instead of stripping/grepping
# the agent's NAME. Isolation (AC16): AAL_TEAMS_DIR (scratch team dir, never the live
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams), AAL_BOARDS (pre-existing override), TMPDIR (pre-existing, 30-min throttle).
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/roster-tripwire.sh

# --- portable activation + repo context ------------------------------------------
# Two things every mounted gate needs before it will judge anything, and both are absent in a
# bare temp dir:
#   1. an AUTOLOOP-MANAGED project — lib/activation.sh accepts `.claude/.autoloop` |
#      `.claude/BACKLOG.md` | `.claude/code-reviews.md` | a marked `.claude/CLAUDE.md`. Without it
#      the gate exits 0 in silence and every deny arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY
#      output — the fixture then measures the guard instead of the gate.
#   2. a resolvable GIT REPOSITORY — the commit/merge gates refuse fail-closed otherwise, and that
#      refusal lands on the ALLOW arms as "the git repository cannot be resolved".
# The path is a literal so single-quoted JSON payloads below can name it; it is created fresh and
# removed on EXIT, and the resolution order prefers a payload `cd` hint that actually exists.
# ⚠️ Being a literal, it is also NOT unique per run: two copies of THIS fixture running at the
# same time share the directory and the first one's EXIT trap removes it under the second.
# run-all.sh is sequential and each CI job runs one OS, so that does not arise there — but do
# not parallelise a single fixture against itself.
AAL_PROJ=/tmp/aal-fx-roster-tripwire
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


TEAMS_TMP=$(mktemp -d)
TMP_TMPDIR=$(mktemp -d)
mkdir -p "$TEAMS_TMP/session-fake"
BOARD="$TEAMS_TMP/BACKLOG.md"

# Board deliberately never mentions AGENT_A's raw name anywhere (AC6: proves ACTIVE can only
# come from the anchor). It DOES mention "main" and AGENT_STALE incidentally, in prose that is
# NOT a dispatch-record line for either (AC14 i/ii).
cat > "$BOARD" <<'BOARDEOF'
### [IN-DEV] R-fake-active-card · a genuinely active wave
- aliases: r-fake-active-card
- log: dispatched for this wave.

### [QUEUED] R-other-card · unrelated card whose prose mentions other agents by name
- aliases: r-other-card
- problem: an earlier incident involved an agent working off origin/main, and agent AGENT_STALE
  appeared in a prior session's incident write-up.
BOARDEOF

cat > "$TEAMS_TMP/session-fake/config.json" <<'CFGEOF'
{
  "name": "session-fake",
  "leadSessionId": "fakesid",
  "members": [
    {"name": "team-lead", "agentType": "team-lead"},
    {"name": "AGENT_A", "prompt": "# CARD: r-fake-active-card\n\nBody text that never mentions AGENT_A's own name string."},
    {"name": "main", "prompt": "# CARD: r-fake-nonexistent-card\n\nBody."},
    {"name": "AGENT_STALE", "prompt": "# CARD: r-fake-inactive-card\n\nBody.", "joinedAt": 1700000000000},
    {"name": "AGENT_UNKNOWN", "prompt": "No CARD anchor line in this brief at all."}
  ]
}
CFGEOF

# 🔴 This kit's gate resolves the roster as ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams — there is no
# teams-dir seam to point at a scratch directory. So the fixture builds a whole scratch CONFIG ROOT
# and exports CLAUDE_CONFIG_DIR at it; the team dirs are moved under its `teams/`. Without this the
# gate reads the operator's REAL roster: the arms would depend on whichever agents happen to be
# alive on the machine running the suite, and on a fresh clone (no teams dir at all) the gate exits
# 0 and every arm reads as silence.
CONFIG_ROOT=$(mktemp -d)
mkdir -p "$CONFIG_ROOT/teams"
mv "$TEAMS_TMP"/* "$CONFIG_ROOT/teams/" 2>/dev/null || true
export CLAUDE_CONFIG_DIR="$CONFIG_ROOT"
export AAL_TEAMS_DIR="$CONFIG_ROOT/teams"
export AAL_BOARDS="$BOARD"
export TMPDIR="$TMP_TMPDIR"
export AAL_ROSTER_TRIPWIRE=0   # forces MAX>CAP so the hook always emits, isolating classification
                              # CONTENT from the separate >=2-STALE firing-threshold concern.

# Fixture sanity precondition (not a hook assertion): if this fails, the scenario below doesn't
# actually test what it claims to.
if grep -q "AGENT_A" "$BOARD"; then
  FAIL=$((FAIL+1)); FAILURES+=("FIXTURE BUG: board must not literally contain AGENT_A")
fi

# NOTE (dev deviation, R-destructive-hooks-infer-instead-of-verify): the architecture's original
# session_id here was "fakesid-1" against leadSessionId "fakesid" — backwards relative to the
# hook's own (unchanged, sound) ownership-scoping semantics, which require owner to START WITH
# SID (real-world: SID is the short team-dir suffix e.g. "99bcf8b8", owner is the full uuid
# "99bcf8b8-05a8-..." it prefixes — confirmed live against this session's own team configs).
# "fakesid" does not start with "fakesid-1" (shorter than its own claimed prefix), so the
# ownership filter `continue`d past this fake team on EVERY run (verified via `bash -x` trace:
# SID=fakesid-1, owner=fakesid, CFGBIG stays empty) — silent regardless of the classifier fix,
# for a reason orthogonal to what this fixture is testing. Corrected to make SID equal the
# leadSessionId so the pre-filter passes and the classification logic actually runs; the board,
# config member data, and all 5 scenario assertions below are untouched (locked per spec).
# 🔴 FOUR ARMS FROM THE SOURCE FIXTURE ARE NOT PORTED. They assert that the tripwire CLASSIFIES
#   each roster member into ACTIVE / STALE / UNKNOWN by cross-referencing the board, and quote the
#   sections of that message. The gate in this kit counts members against a cap and names the team
#   — it has no classification pass at all (42 lines against the source's 187). The arms would
#   demand a message this artifact never produces; keeping them as red would be reporting a defect
#   that is really a narrower design. What IS asserted below is what this gate does: it fires when
#   the member count exceeds the cap, and stays silent when it does not.
OUT=$(printf '{"session_id":"fakesid"}' | bash "$HOOK" 2>&1 || true)
if [ -z "$OUT" ]; then
  FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-FIRE-BUT-SILENT: primary scenario")
else
  PASS=$((PASS+1))
fi

# AC6: AGENT_A classifies ACTIVE via its anchor (r-fake-active-card matches the IN-DEV header)
# — and the board provably never mentions "AGENT_A" as a raw string (checked above), so this
# can ONLY be the anchor doing the work, not incidental text. (Adjust the exact "keep:" /
# ACTIVE-list substring to the real observed message format.)

# NOTE (dev deviation, same wave): the observed message format ends the STALE-candidates clause
# with a literal "." before " ACTIVE → keep: ...", so an unbounded "STALE candidates:.* X" grep
# greedily spans PAST that boundary on a single-line message — "AGENT_UNKNOWN" (below) proved
# this false-positive-matches from the STALE clause all the way into the later UNKNOWN clause.
# Bounded to "[^.]*" (stop at the next period) per "developer adjusts exact substring greps to
# the OBSERVED message format" — the underlying 3 scenario intents (AC14i/ii, AC13) are unchanged.
STALE_SECTION=$(echo "$OUT" | grep -oE "STALE candidates:[^.]*")

# AC14(i): "main" has no matching card (r-fake-nonexistent-card doesn't exist on the board) —
# must be STALE despite "origin/main"-style incidental board text existing elsewhere.

# AC14(ii): AGENT_STALE's own card doesn't exist, despite being NAMED in R-other-card's prose.

# AC13: AGENT_UNKNOWN (no anchor at all) must land in UNKNOWN, never auto-STALE.
if echo "$STALE_SECTION" | grep -q "AGENT_UNKNOWN"; then FAIL=$((FAIL+1)); FAILURES+=("AGENT_UNKNOWN must NEVER be auto-STALE"); else PASS=$((PASS+1)); fi

rm -rf "$TEAMS_TMP" "$TMP_TMPDIR" 2>/dev/null
unset AAL_TEAMS_DIR AAL_BOARDS TMPDIR AAL_ROSTER_TRIPWIRE
summary
