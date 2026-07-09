#!/usr/bin/env bash
# oplog-grepall.test.sh — AC-F2. Proves require-oplog-row-for-this-merge.sh finds the #<N> row via
# grep-ALL across EVERY autoloop-log-*.md, not a single `ls -t | head -1` mtime-latest file. The
# make-or-break: the row lives in a NON-mtime-latest session ledger (another file touched newer);
# GREEN (real gate) FINDS it → allow (empty stdout / exit 0); RED (`ls -t|head -1`-reverted) MISSES
# it → deny JSON. Fail-loud guards confirm (1) the RED swap took, (2) the row is in the non-latest
# file, (3) the touch made the other file mtime-newest on THIS runtime.
# Toolchain: bash + node. Self-contained temp dirs. Run: bash hooks/tests/oplog-grepall.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE_SRC="$HOOKS_SRC/require-oplog-row-for-this-merge.sh"
ACTIVATION_SRC="$HOOKS_SRC/lib/activation.sh"
PARSEJSON_SRC="$HOOKS_SRC/lib/parse-json.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected EMPTY | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

build_hookdir() {  # <dir> [gate_override]
  local d="$1"; local gate="${2:-$GATE_SRC}"
  mkdir -p "$d/lib"
  cp "$ACTIVATION_SRC" "$d/lib/activation.sh"
  cp "$PARSEJSON_SRC"  "$d/lib/parse-json.sh"
  cp "$gate" "$d/require-oplog-row-for-this-merge.sh"; chmod +x "$d/require-oplog-row-for-this-merge.sh"
}
make_proj() { mkdir -p "$1/.claude"; : > "$1/.claude/.autoloop"; }
# run the gate: payload {command:"cd <proj> && gh pr merge <N> ..."}; AAL_OPLOG_DIR pins the dir,
# CLAUDE_PROJECT_DIR makes aal_is_autoloop_project pass. Capture stdout (deny JSON or empty=allow).
run_gate() {  # <hookdir> <projdir> <pr-num>
  local d="$1" p="$2" n="$3" payload
  payload=$(CMD="cd $p && gh pr merge $n --squash --delete-branch" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",command:process.env.CMD}))')
  printf '%s' "$payload" | env AAL_GATES="merge-gates:" AAL_OPLOG_DIR="$p/.claude" CLAUDE_PROJECT_DIR="$p" \
    bash "$d/require-oplog-row-for-this-merge.sh" 2>/dev/null
}

echo "== op-log grep-ALL merge-gate matrix =="

# ---- Build the single-file-REVERTED RED gate: swap the grep-ALL back to `ls -t | head -1` + a
#      single-file grep. index()-anchored (exact substring, no regex-escaping of the gate lines). ----
REVERTED=$(mktemp)
awk '
  index($0, "ls \"$OPLOG_DIR\"/autoloop-log-*.md >/dev/null 2>&1 || exit 0") {
    print "OPLOG=$(ls -t \"$OPLOG_DIR\"/autoloop-log-*.md 2>/dev/null | head -1 || true)"
    print "{ [ -n \"$OPLOG\" ] && [ -f \"$OPLOG\" ]; } || exit 0"
    next }
  index($0, "grep -lE") {
    print "grep -qE \"#${NUM}([^0-9]|\\$)\" \"$OPLOG\" 2>/dev/null && exit 0"
    next }
  { print }
' "$GATE_SRC" > "$REVERTED"
# FAIL-LOUD GUARD 1: the swap took (single-file ls -t restored, grep-ALL grep -lE gone).
if grep -q 'ls -t' "$REVERTED" && ! grep -q 'grep -lE' "$REVERTED"; then
  ok "SETUP: single-file-reverted RED gate built"; else bad "SETUP: RED swap did NOT take (halt)"; halt; fi

# ---- Fixture: TWO session ledgers. The #5 row is in the OLDER-dated 07-09 ledger; the 07-10 ledger
#      is touched mtime-newest and does NOT carry #5. grep-ALL must still find it; ls -t misses it. ----
seed() {  # <projdir>
  local c="$1/.claude"
  printf '## 2026-07-09 · wave-a · MERGE\n- proof: merged PR #5\n- next: DoD\n' > "$c/autoloop-log-2026-07-09-aaaaaaaa.md"
  printf '## 2026-07-10 · wave-b · DISPATCH\n- proof: dispatched PR #7\n- next: review\n' > "$c/autoloop-log-2026-07-10-bbbbbbbb.md"
  touch "$c/autoloop-log-2026-07-10-bbbbbbbb.md"   # make the NON-#5 file mtime-newest
}

DG=$(mktemp -d); build_hookdir "$DG"; PG="$DG/proj"; make_proj "$PG"; seed "$PG"
# FAIL-LOUD GUARD 2: the #5 row IS in the 07-09 (non-latest) file, NOT the 07-10 file.
grep -q '#5' "$PG/.claude/autoloop-log-2026-07-09-aaaaaaaa.md" && ! grep -q '#5' "$PG/.claude/autoloop-log-2026-07-10-bbbbbbbb.md" \
  && ok "SETUP: #5 row is in the 07-09 ledger only" || { bad "SETUP: #5 row placement wrong (halt)"; halt; }
# FAIL-LOUD GUARD 3: the touch made the 07-10 (non-#5) file mtime-newest on THIS runtime.
case "$(ls -t "$PG"/.claude/autoloop-log-*.md 2>/dev/null | head -1)" in
  *autoloop-log-2026-07-10-bbbbbbbb.md) ok "SETUP: touch made the NON-#5 file mtime-newest (ls -t would miss)" ;;
  *) bad "SETUP: touch did NOT make the NON-#5 file mtime-newest — RED cannot be exercised (halt)"; halt ;;
esac

# GREEN (real gate): grep-ALL finds #5 in the non-latest ledger → allow (empty stdout).
OUT=$(run_gate "$DG" "$PG" 5)
assert_empty "GREEN: grep-ALL finds #5 in the non-mtime-latest ledger → allow (empty stdout)" "$OUT"

# RED (single-file ls -t|head -1): picks the mtime-newest 07-10 ledger (no #5) → deny.
DR=$(mktemp -d); build_hookdir "$DR" "$REVERTED"; PR="$DR/proj"; make_proj "$PR"; seed "$PR"
OUT=$(run_gate "$DR" "$PR" 5)
assert_contains "RED: single-file ls -t misses #5 in the non-latest ledger → deny (matrix inverts)" "$OUT" '"permissionDecision":"deny"'

# Control: a PR whose row is ABSENT everywhere → real gate also denies (grep-ALL still fail-closed).
OUT=$(run_gate "$DG" "$PG" 999)
assert_contains "CONTROL: real gate denies a PR with NO row in any ledger (fail-closed)" "$OUT" '"permissionDecision":"deny"'

rm -rf "$DG" "$DR"; rm -f "$REVERTED"
echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
