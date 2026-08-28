#!/usr/bin/env bash
# Tests for block-malformed-new-backlog-card.mjs. Fixture board at a node-resolvable C:/ path whose
# dir name contains "example-project" + file == BACKLOG.md (the hook's two path guards). Emphasis: a write-gate
# on the task board must NOT wedge it — most cases assert ALLOW (migration-tolerant + fail-open).
set -u
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/"block-malformed-new-backlog-card.mjs"

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
AAL_PROJ=/tmp/aal-fx-block-malformed-new-backlog-card
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------

# 🔴 Scratch lives in a temp dir the fixture creates and removes — NEVER under the operator's
# config root. Every path below is handed to the tool explicitly, so nothing requires it to sit
# there; with CLAUDE_CONFIG_DIR unset (the default for an adopter) the old form dropped files
# into a real ~/.claude, and on a machine where that directory is read-only source it is worse
# than untidy.
T="$(mktemp -d)/cardgate"
BL="$T/BACKLOG.md"
PASS=0; FAIL=0
rm -rf "$T"; mkdir -p "$T"

mkw() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' "$1" "$2"; }
mke() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.argv[1],old_string:process.argv[2],new_string:process.argv[3]}}))' "$1" "$2" "$3"; }
v()   { printf '%s' "$1" | node "$HOOK" 2>&1; }
deny(){ if printf '%s' "$2" | grep -qF 'permissionDecision":"deny'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: expected DENY, got: $(printf '%s' "$2"|head -c100)"; fi; }
allow(){ if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: expected ALLOW, got: $(printf '%s' "$2"|head -c160)"; fi; }
denyhas(){ if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: deny should mention '$3'"; fi; }

# baseline current board with ONE pre-SOP debt card (no problem/fix) — exercises migration-tolerance
base() { printf '# Backlog\n\n### [REVIEW] R-old · P3\n- aliases: r-old\n- log: old note @abc1234\n' > "$BL"; }

# t1: new card WITH full skeleton → ALLOW
# The four expectations below were updated when the gate's card contract grew, and the gate's
# own judgment was NOT touched — only the fixture payloads. Recording which half moved matters:
# a fixture that goes red because the RULE changed is a stale expectation, not a regression.
# The contract that moved: `- fix:` must carry the two bare tokens SAME-WAVE-N-A and
# LIVE-DELTA-N-A on EVERY new card, not only on remedy cards. The gate followed that rule and
# the fixture did not, so t1/t4/t9/t12 flipped from ALLOW to DENY. The judgment never changed.
base
C1='# Backlog

### [REVIEW] R-old · P3
- aliases: r-old
- log: old note @abc1234
### [QUEUED] R-new · P3
- aliases: r-new
- problem: x
- fix: y SAME-WAVE-N-A: fixture board has no wave in flight; all three predicates (worktree / roster / File Map) are empty LIVE-DELTA-N-A: a fixture is not deployed, so no live artifact changes'
allow "t1 new card w/ skeleton" "$(v "$(mkw "$BL" "$C1")")"

# t2: new card missing problem → DENY
base
C2='# Backlog

### [REVIEW] R-old · P3
- aliases: r-old
- log: old note @abc1234
### [QUEUED] R-new · P3
- aliases: r-new
- fix: y'
O=$(v "$(mkw "$BL" "$C2")")
deny    "t2 new card missing problem" "$O"
denyhas "t2 names problem"             "$O" 'problem:'

# t3: new card missing aliases → DENY
base
C3='# Backlog

### [REVIEW] R-old · P3
- aliases: r-old
- log: old note @abc1234
### [QUEUED] R-new · P3
- problem: x
- fix: y'
deny "t3 new card missing aliases" "$(v "$(mkw "$BL" "$C3")")"

# t4: new card non-whitelist status [DONE] → DENY
base
C4='# Backlog

### [DONE] R-new · P3
- aliases: r-new
- problem: x
- fix: y SAME-WAVE-N-A: fixture board has no wave in flight; all three predicates (worktree / roster / File Map) are empty LIVE-DELTA-N-A: a fixture is not deployed, so no live artifact changes'
O=$(v "$(mkw "$BL" "$C4")")
deny    "t4 new card bad status" "$O"
denyhas "t4 names status"        "$O" 'status'

# t5: edit EXISTING debt card's log (name unchanged, card lacks problem/fix) → ALLOW (migration-tolerant)
base
allow "t5 edit existing card log" "$(v "$(mke "$BL" '- log: old note @abc1234' '- log: new note @def5678 reviewed')")"

# t6: status change on existing card → ALLOW
base
allow "t6 status change existing" "$(v "$(mke "$BL" '### [REVIEW] R-old · P3' '### [QUEUED] R-old · P3')")"

# t7: non-BACKLOG file → no-op ALLOW
base
allow "t7 non-BACKLOG file" "$(v "$(mkw "$T/notes.md" 'whatever')")"

# t8: Write full board, existing malformed cards, NO new name → ALLOW (no new card to gate)
base
C8='# Backlog reordered

### [REVIEW] R-old · P3
- aliases: r-old
- log: old note @abc1234 (edited)'
allow "t8 rewrite w/ old debt, no new card" "$(v "$(mkw "$BL" "$C8")")"

# t9: new card with <TODO: fill this in> placeholders (skeleton present) -> ALLOW
base
C9='# Backlog

### [REVIEW] R-old · P3
- aliases: r-old
- log: old note @abc1234
### [QUEUED] R-new · P3
- aliases: r-new
- problem: <TODO: fill this in>
- fix: <TODO: fill this in> SAME-WAVE-N-A: fixture board has no wave in flight; all three predicates (worktree / roster / File Map) are empty LIVE-DELTA-N-A: a fixture is not deployed, so no live artifact changes'
allow "t9 new card w/ TODO placeholders" "$(v "$(mkw "$BL" "$C9")")"

# t10: fail-OPEN — Edit old_string not present in current → ALLOW
base
allow "t10 fail-open (old_string absent)" "$(v "$(mke "$BL" 'STRING NOT IN FILE' 'x')")"

# t11: new card missing fix → DENY
base
C11='# Backlog

### [REVIEW] R-old · P3
- aliases: r-old
- log: old note @abc1234
### [IN-DEV] R-new · P2
- aliases: r-new
- problem: x'
O=$(v "$(mkw "$BL" "$C11")")
deny    "t11 new card missing fix" "$O"
denyhas "t11 names fix"            "$O" 'fix:'

# t12: Edit that APPENDS a new good card (target board file via Edit) → ALLOW
base
allow "t12 edit appends good new card" "$(v "$(mke "$BL" '- log: old note @abc1234' '- log: old note @abc1234
### [QUEUED] R-fresh · P3
- aliases: r-fresh
- problem: x
- fix: y SAME-WAVE-N-A: fixture board has no wave in flight; all three predicates (worktree / roster / File Map) are empty LIVE-DELTA-N-A: a fixture is not deployed, so no live artifact changes')")"

# t13: Edit that APPENDS a new MALFORMED card → DENY
base
deny "t13 edit appends malformed new card" "$(v "$(mke "$BL" '- log: old note @abc1234' '- log: old note @abc1234
### [QUEUED] R-fresh · P3
- aliases: r-fresh')")"

rm -rf "$T"
echo "──────────────────────────────────────────"
echo "block-malformed-new-backlog-card: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
