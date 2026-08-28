#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-archive-gated-done-card.mjs
# 🔴 Scratch lives in a temp dir the fixture creates and removes — NEVER under the operator's
# config root. Every path below is handed to the tool explicitly, so nothing requires it to sit
# there; with CLAUDE_CONFIG_DIR unset (the default for an adopter) the old form dropped files
# into a real ~/.claude, and on a machine where that directory is read-only source it is worse
# than untidy.
T="$(mktemp -d)/board.md"
PASS=0; FAIL=0; FAILURES=()
run(){ AAL_BACKLOG="$T" node "$HOOK" < /dev/null 2>&1; }
blocked(){ if printf '%s' "$2" | grep -qF '"decision":"block"'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("$1: expected BLOCK, got: $(printf '%s' "$2" | head -c150)"); fi; }
silent(){ if printf '%s' "$2" | grep -qF '"decision":"block"'; then FAIL=$((FAIL+1)); FAILURES+=("$1: expected SILENT, got: $(printf '%s' "$2" | head -c150)"); else PASS=$((PASS+1)); fi; }

printf '### [BLOCKED] R-provisioning-like · P1 · [gate = SEQUENCE prerequisite #864 MERGED but this card still awaits dev] · provisioning wave\n- aliases: r-provisioning-like\n- problem: placeholder\n- fix: placeholder\n' > "$T"
O=$(run)
silent "AC2 gate-bracket #N MERGED must NOT self-flag" "$O"

printf '### [USER-GATED] R-invite-like · P2 · invite lifecycle\n- aliases: r-invite-like\n- problem: placeholder\n- log:\n  - 2026-07-05 · code #645 MERGED, oauth-cancel verified\n' > "$T"
O=$(run)
blocked "AC3 own merged-work ack (no escape) must still flag" "$O"

printf '### [BLOCKED] R-seq-escape · P3 · [blocked-by=pr#864] · SEQUENCE-AFTER prerequisite card\n- aliases: r-seq-escape\n- problem: MERGED #900 here is a reference to something else\n' > "$T"
O=$(run)
silent "AC4 blocked-by= gate-blocker token escapes" "$O"

printf '### [BLOCKED] R-seq-escape2 · P3 · SEQUENCE-AFTER card, #864 to be confirmed\n- aliases: r-seq-escape2\n- problem: MERGED #900\n' > "$T"
O=$(run)
silent "AC4 SEQUENCE-AFTER token (no bracket form) escapes" "$O"

printf '### [BLOCKED] R-mixed-signal · P2 · [gate = SEQUENCE prerequisite #864 MERGED] · mixed signal\n- aliases: r-mixed-signal\n- log:\n  - 2026-07-10 · this card\u2019s OWN code #950 MERGED, verified\n' > "$T"
O=$(run)
blocked "mixed signal: real self-ack elsewhere still flags despite gate bracket" "$O"

rm -f "$T"
O=$(run)
silent "unreadable board file → fail-open silent" "$O"

name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then echo "  $name: PASS ($PASS/$PASS)"; exit 0
else echo "  $name: FAIL ($PASS pass, $FAIL fail)"; for f in "${FAILURES[@]}"; do echo "    - $f"; done; exit 1
fi
