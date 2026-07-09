#!/usr/bin/env bash
# oplog-rotation.test.sh — op-log rotation-churn regression (arch §A-2 / AC-2/AC-3).
#
# Proves the active-op-log resolution in oplog-turn-reminder.sh is by FILENAME DATE-DIGITS, not mtime.
# Make-or-break: the churn scenario (an OLDER-dated >250KB ledger given a FRESHER mtime than a
# NEWER-dated <250KB ledger) mints ZERO stubs under the fix (GREEN) and mints a stub under a
# deliberately mtime-reverted resolution (RED). Plus idempotent rotation, *archive* exclusion,
# non-dated lone-file no-op, non-autoloop no-op. Toolchain: bash + node. Self-contained temp dirs.
# Run:  bash hooks/tests/oplog-rotation.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
HOOK_SRC="$HOOKS_SRC/oplog-turn-reminder.sh"
ACTIVATION_SRC="$HOOKS_SRC/lib/activation.sh"
PARSEJSON_SRC="$HOOKS_SRC/lib/parse-json.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

PAYLOAD='{"session_id":"S-oplog","stop_hook_active":false}'

build_hookdir() {  # <dir> [hook_override]
  local d="$1"; local hook="${2:-$HOOK_SRC}"
  mkdir -p "$d/lib"
  cp "$ACTIVATION_SRC" "$d/lib/activation.sh"
  cp "$PARSEJSON_SRC"  "$d/lib/parse-json.sh"
  cp "$hook" "$d/oplog-turn-reminder.sh"; chmod +x "$d/oplog-turn-reminder.sh"
}
make_proj()   { mkdir -p "$1/.claude"; : > "$1/.claude/.autoloop"; }
big_file()    { awk 'BEGIN{c="";for(i=0;i<1000;i++)c=c"x";for(j=0;j<260;j++)printf "%s",c}' > "$1"; }  # 260000 bytes
small_file()  { printf '# small ledger\n' > "$1"; }
count_logs()  { ls "$1"/.claude/autoloop-log-*.md 2>/dev/null | wc -l | tr -d ' '; }
run_hook()    { ( printf '%s' "$PAYLOAD" | env AAL_GATES="pipeline-roles:" CLAUDE_PROJECT_DIR="$2" \
                   CLAUDE_PLUGIN_DATA="$1/state" bash "$1/oplog-turn-reminder.sh" >/dev/null 2>&1 || true ); }

echo "== op-log rotation-churn matrix =="

# ---- Build the mtime-REVERTED RED hook: swap the digit-key resolution back to `ls -t | head -1`,
#      anchored on the two lines the fix keeps verbatim. The `!skip` guard on the pass-through print
#      rule DELETES the digit-key for-loop between the anchors (else the loop survives and overrides
#      the mtime pick — see PR §Deviation flags). ----
REVERTED=$(mktemp)
awk '
  /^OPLOG=""; OPLOG_KEY=""$/ {
    print "OPLOG=$(ls -t \"$PROJ\"/.claude/autoloop-log-*.md 2>/dev/null | head -1 || true)"
    print "[ -n \"$OPLOG\" ] || exit 0"; skip=1; next }
  skip && /^\[ -n "\$OPLOG" \] \|\| exit 0$/ { skip=0; next }
  !skip { print }
' "$HOOK_SRC" > "$REVERTED"
# FAIL-LOUD GUARD 1: the swap must have taken (ls -t restored, digit-key gone).
if grep -q 'ls -t' "$REVERTED" && ! grep -q 'OPLOG_KEY' "$REVERTED"; then
  ok "SETUP: mtime-reverted RED hook built"; else bad "SETUP: mtime-revert swap did NOT take (halt)"; halt; fi

# ===== CHURN (make-or-break) =====
seed_churn() {  # older >250KB w/ fresher mtime + newer <250KB
  big_file   "$1/.claude/autoloop-log-2026-07-08.md"
  small_file "$1/.claude/autoloop-log-2026-07-09.md"
  touch "$1/.claude/autoloop-log-2026-07-08.md"
}
# GREEN (real hook): digit-key picks the newer <250KB → NO mint.
DG=$(mktemp -d); build_hookdir "$DG"; PG="$DG/proj"; make_proj "$PG"; seed_churn "$PG"
# FAIL-LOUD GUARD 2: the big file is actually >250000 bytes.
SZ=$(wc -c < "$PG/.claude/autoloop-log-2026-07-08.md" | tr -d ' ')
[ "$SZ" -gt 250000 ] && ok "SETUP: older ledger is >250KB ($SZ)" || { bad "SETUP: older ledger not >250KB ($SZ) (halt)"; halt; }
# FAIL-LOUD GUARD 3: the touch actually made the older file mtime-newest on THIS runtime.
case "$(ls -t "$PG"/.claude/autoloop-log-*.md 2>/dev/null | head -1)" in
  *autoloop-log-2026-07-08.md) ok "SETUP: touch made OLDER file mtime-newest (churn reproducible)" ;;
  *) bad "SETUP: touch did NOT make older file mtime-newest — churn RED cannot be exercised (halt)"; halt ;;
esac
B0=$(count_logs "$PG"); run_hook "$DG" "$PG"; B1=$(count_logs "$PG")
[ "$B0" = "$B1" ] && ok "CHURN GREEN: real hook mints NO stub (delta 0)" || bad "CHURN GREEN: minted $((B1-B0)) (want 0)"
# RED (mtime-reverted hook, SAME fixture): `ls -t` picks the older >250KB → mints a stub.
DR=$(mktemp -d); build_hookdir "$DR" "$REVERTED"; PR="$DR/proj"; make_proj "$PR"; seed_churn "$PR"
B0=$(count_logs "$PR"); run_hook "$DR" "$PR"; B1=$(count_logs "$PR")
[ "$B1" -gt "$B0" ] && ok "CHURN RED: reverted hook mints a stub (delta $((B1-B0)) ≥1 — matrix inverts)" \
                    || bad "CHURN RED: reverted hook minted 0 — fixture does NOT reproduce the bug (halt)"
rm -rf "$DG" "$DR"

# ===== IDEMPOTENT ROTATION (AC-3): newest-by-filename is >250KB → one successor; re-run zero =====
DI=$(mktemp -d); build_hookdir "$DI"; PI="$DI/proj"; make_proj "$PI"
big_file "$PI/.claude/autoloop-log-2026-07-09.md"
A0=$(count_logs "$PI"); run_hook "$DI" "$PI"; A1=$(count_logs "$PI"); run_hook "$DI" "$PI"; A2=$(count_logs "$PI")
[ "$((A1-A0))" = "1" ] && ok "IDEMPOTENT: first run mints exactly ONE successor" || bad "IDEMPOTENT: first run minted $((A1-A0)) (want 1)"
[ "$A2" = "$A1" ]      && ok "IDEMPOTENT: second run mints ZERO more (converged)" || bad "IDEMPOTENT: second run minted $((A2-A1)) (want 0)"
rm -rf "$DI"

# ===== ARCHIVE EXCLUSION: a larger-key >250KB *archive* file is NEVER selected =====
DA=$(mktemp -d); build_hookdir "$DA"; PA="$DA/proj"; make_proj "$PA"
small_file "$PA/.claude/autoloop-log-2026-07-09.md"             # active, <250KB, key 20260709
big_file   "$PA/.claude/autoloop-log-2026-07-10-archive-01.md"  # archive, >250KB, LARGER key 2026071001
A0=$(count_logs "$PA"); run_hook "$DA" "$PA"; A1=$(count_logs "$PA")
[ "$A0" = "$A1" ] && ok "ARCHIVE: larger-key >250KB *archive* excluded → active <250KB → no mint" || bad "ARCHIVE: minted $((A1-A0)) — archive wrongly selected"
rm -rf "$DA"

# ===== NON-DATED / -TEMPLATE (reviewer LOW#2) =====
# 5a: template >250KB (key "") + dated <250KB (key 20260709) → dated wins → no mint (empty key sorts below).
DT=$(mktemp -d); build_hookdir "$DT"; PT="$DT/proj"; make_proj "$PT"
big_file "$PT/.claude/autoloop-log-TEMPLATE.md"; small_file "$PT/.claude/autoloop-log-2026-07-09.md"
A0=$(count_logs "$PT"); run_hook "$DT" "$PT"; A1=$(count_logs "$PT")
[ "$A0" = "$A1" ] && ok "NON-DATED 5a: empty-key TEMPLATE sorts below dated → no mint" || bad "NON-DATED 5a: minted $((A1-A0)) — empty-key wrongly selected"
rm -rf "$DT"
# 5b: lone TEMPLATE <250KB → selected but <250KB → no-op, no crash.
DL=$(mktemp -d); build_hookdir "$DL"; PL="$DL/proj"; make_proj "$PL"
small_file "$PL/.claude/autoloop-log-TEMPLATE.md"
A0=$(count_logs "$PL"); run_hook "$DL" "$PL"; A1=$(count_logs "$PL")
[ "$A0" = "$A1" ] && ok "NON-DATED 5b: lone <250KB non-dated no-ops (no crash)" || bad "NON-DATED 5b: minted $((A1-A0)) (want 0)"
rm -rf "$DL"

# ===== NON-AUTOLOOP no-op: no marker → hook exits before rotation =====
DN=$(mktemp -d); build_hookdir "$DN"; PN="$DN/proj"; mkdir -p "$PN/.claude"   # NO marker
big_file "$PN/.claude/autoloop-log-2026-07-09.md"
A0=$(count_logs "$PN"); run_hook "$DN" "$PN"; A1=$(count_logs "$PN")
[ "$A0" = "$A1" ] && ok "NON-AUTOLOOP: no marker → no-op even with a >250KB ledger" || bad "NON-AUTOLOOP: minted $((A1-A0)) — should no-op"
rm -rf "$DN"

rm -f "$REVERTED"
echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
