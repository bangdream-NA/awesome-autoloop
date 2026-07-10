#!/usr/bin/env bash
# statusdrift-anchor-exclusion.test.sh — §Y-8 (2nd kit-behind fold). Proves the (B) archive DoD-gate
# in block-backlog-status-drift.mjs EXCLUDES a positioning-anchor header (one that appears
# byte-identically in old_string) from the DoD check. An Edit that INSERTS a new archived card uses a
# neighbour's header as an old/new_string anchor; if that anchor is TRUNCATED (missing its
# DoD-VERIFIED tail) the gate must NOT misread it as a brand-new DoD-less card and deny the whole
# write. A genuinely-new card (never in old_string) is still gated — the teeth are unchanged.
# Runs the REAL .mjs directly (feeds a PreToolUse Edit payload; judges from file_path + old/new_string).
# Toolchain: bash + node. Run: bash hooks/tests/statusdrift-anchor-exclusion.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/block-backlog-status-drift.mjs"
ARCH="/proj/.claude/BACKLOG-archive.md"     # archive-ledger path (isArchive branch); .mjs never reads it

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }

# run_edit <file_path> <old_string> <new_string> -> gate stdout (deny JSON or empty=allow)
run_edit() {
  local fp="$1" old="$2" nu="$3" payload
  payload=$(FP="$fp" OLD="$old" NU="$nu" node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:process.env.FP,old_string:process.env.OLD,new_string:process.env.NU}}))')
  printf '%s' "$payload" | node "$GATE" 2>/dev/null
}

echo "== archive DoD-gate anchor-exclusion (Y-8) =="

# RED: INSERT a DoD-VERIFIED new card, anchored on a TRUNCATED neighbour header (present byte-identically
# in old_string + new_string, missing its DoD tail). Post-fix the anchor is excluded -> only the
# DoD-VERIFIED new card is checked -> ALLOW. Pre-fix (no exclusion) the truncated anchor is misread as a
# DoD-less new card -> DENY (naming the WRONG card). Asserting ALLOW here FAILS if the exclusion is absent.
OUT=$(run_edit "$ARCH" \
  "### [DONE] R-anchor-neighbour" \
  "### [DONE] R-new-card · ARCHIVED DoD-VERIFIED @abc1234
- log: 2026-07-10 · shipped
### [DONE] R-anchor-neighbour")
assert_empty "RED truncated anchor + DoD-VERIFIED new card → ALLOW (anchor excluded)" "$OUT"

# GREEN-teeth: INSERT a genuinely-new DoD-LESS card, anchored on a FULL DoD-VERIFIED neighbour. The new
# card is NOT in old_string, so it is still gated -> DENY, and the reason names the NEW card, NOT the
# excluded anchor (proves exclusion targets only the anchor, teeth intact).
OUT=$(run_edit "$ARCH" \
  "### [DONE] R-anchor-neighbour · ARCHIVED DoD-VERIFIED @abc1234" \
  "### [DONE] R-teeth-new (MERGED #9)
- log: 2026-07-10 · x
### [DONE] R-anchor-neighbour · ARCHIVED DoD-VERIFIED @abc1234")
assert_contains     "GREEN-teeth DoD-less new card still → DENY (teeth intact)"      "$OUT" '"permissionDecision":"deny"'
assert_contains     "GREEN-teeth deny names the NEW card"                            "$OUT" "R-teeth-new"
assert_not_contains "GREEN-teeth deny does NOT name the excluded anchor"             "$OUT" "R-anchor-neighbour"

# GREEN-baseline: a DoD-less new card with NO anchor (old_string is a non-header line) → DENY. Confirms
# the archive gate's baseline is unchanged by the exclusion (passes with or without the fix).
OUT=$(run_edit "$ARCH" \
  "## ARCHIVE (fixture)" \
  "### [DONE] R-solo-dodless (MERGED #9)
- log: 2026-07-10 · x")
assert_contains "GREEN-baseline DoD-less card, no anchor → DENY" "$OUT" '"permissionDecision":"deny"'

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
