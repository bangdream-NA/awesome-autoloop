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
run_hook_sid(){ ( printf '{"session_id":"%s","stop_hook_active":false}' "$3" | env AAL_GATES="pipeline-roles:" CLAUDE_PROJECT_DIR="$2" \
                   CLAUDE_PLUGIN_DATA="$1/state" bash "$1/oplog-turn-reminder.sh" >/dev/null 2>&1 || true ); }
# shellcheck disable=SC2012
count_sid_logs(){ ls "$1"/.claude/autoloop-log-*-"$2".md 2>/dev/null | wc -l | tr -d ' '; }

echo "== op-log rotation-churn matrix =="

# ---- Build the single-class-REVERTED RED hook: swap the WHOLE two-class resolver+rotation span
#      (from the `SID_RE=` line through the `[ -n "$OWN" ] || [ -n "$LEG" ] || exit 0` guard) back to
#      a single `ls -t | head -1` resolver + inline size-check that mints an un-suffixed stub. Under it
#      a foreign-sid8 >250KB file is WRONGLY picked+rotated (matrix inverts vs the two-class GREEN skip)
#      AND the churn older-but-fresher-mtime file is wrongly picked (the digit-key GREEN avoids both). ----
REVERTED=$(mktemp)
awk '
  /^SID_RE=/ {
    print "OPLOG=$(ls -t \"$PROJ\"/.claude/autoloop-log-*.md 2>/dev/null | head -1 || true)"
    print "if [ -n \"$OPLOG\" ] && [ -f \"$OPLOG\" ]; then"
    print "  RB=$(wc -c < \"$OPLOG\" 2>/dev/null | tr -d \" \"); case \"$RB\" in (*[!0-9]*|\"\") RB=0 ;; esac"
    print "  if [ \"$RB\" -gt 250000 ]; then"
    print "    RNEW=\"$PROJ/.claude/autoloop-log-$(date +%Y-%m-%d-%H%M%S).md\""
    print "    [ -e \"$RNEW\" ] || printf \"# rotated\\n\" > \"$RNEW\" 2>/dev/null || true"
    print "  fi"
    print "fi"
    skip=1; next }
  skip && /^\[ -n "\$OWN" \] \|\| \[ -n "\$LEG" \] \|\| exit 0$/ { skip=0; next }
  !skip { print }
' "$HOOK_SRC" > "$REVERTED"
# FAIL-LOUD GUARD 1: the swap must have taken (single-class ls -t restored, two-class OWN_KEY gone).
if grep -q 'ls -t' "$REVERTED" && ! grep -q 'OWN_KEY' "$REVERTED"; then
  ok "SETUP: single-class-reverted RED hook built"; else bad "SETUP: single-class-revert swap did NOT take (halt)"; halt; fi

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

# ===== TWO-CLASS (per-session sid8) (AC-F1) =====
echo ""
echo "== TWO-CLASS (per-session sid8) =="
SID8="a1b2c3d4"; SIDJSON="a1b2c3d4efgh"    # first-8-alnum(SIDJSON) == SID8

# A) own-sid8 >250KB → mints a SAME-sid8 dated successor (exactly one new sid8 file); re-run mints 0.
DO=$(mktemp -d); build_hookdir "$DO"; PO="$DO/proj"; make_proj "$PO"
big_file "$PO/.claude/autoloop-log-2026-07-10-$SID8.md"
C0=$(count_sid_logs "$PO" "$SID8"); run_hook_sid "$DO" "$PO" "$SIDJSON"; C1=$(count_sid_logs "$PO" "$SID8")
[ "$((C1-C0))" = "1" ] && ok "TWO-CLASS own: sid8 >250KB mints exactly ONE same-sid8 successor" || bad "TWO-CLASS own: minted $((C1-C0)) sid8 (want 1)"
NEWF=$(ls -t "$PO"/.claude/autoloop-log-*.md 2>/dev/null | head -1)
case "$(basename "$NEWF")" in *-"$SID8".md) ok "TWO-CLASS own: successor is sid8-suffixed ($(basename "$NEWF"))" ;; *) bad "TWO-CLASS own: successor NOT sid8-suffixed ($(basename "$NEWF"))" ;; esac
run_hook_sid "$DO" "$PO" "$SIDJSON"; C2=$(count_sid_logs "$PO" "$SID8")
[ "$C2" = "$C1" ] && ok "TWO-CLASS own: re-run mints ZERO more (converged)" || bad "TWO-CLASS own: re-run minted $((C2-C1)) (want 0)"
rm -rf "$DO"

# B) a FOREIGN-session sid8 >250KB is NEVER rotated by MY session (GREEN skip); the single-class RED
#    variant WRONGLY mints (matrix inverts).
DF=$(mktemp -d); build_hookdir "$DF"; PF="$DF/proj"; make_proj "$PF"
big_file "$PF/.claude/autoloop-log-2026-07-10-99999999.md"     # foreign sid (!= a1b2c3d4)
F0=$(count_logs "$PF"); run_hook_sid "$DF" "$PF" "$SIDJSON"; F1=$(count_logs "$PF")
[ "$F0" = "$F1" ] && ok "TWO-CLASS foreign GREEN: other session's sid8 ledger NOT rotated (delta 0)" || bad "TWO-CLASS foreign GREEN: minted $((F1-F0)) (want 0)"
DFR=$(mktemp -d); build_hookdir "$DFR" "$REVERTED"; PFR="$DFR/proj"; make_proj "$PFR"
big_file "$PFR/.claude/autoloop-log-2026-07-10-99999999.md"
FR0=$(count_logs "$PFR"); run_hook_sid "$DFR" "$PFR" "$SIDJSON"; FR1=$(count_logs "$PFR")
[ "$FR1" -gt "$FR0" ] && ok "TWO-CLASS foreign RED: single-class reverted hook WRONGLY mints (delta $((FR1-FR0)) ≥1 — matrix inverts)" \
                      || bad "TWO-CLASS foreign RED: reverted minted 0 — fixture does NOT reproduce the bug"
rm -rf "$DF" "$DFR"

# C) empty/<8 session_id → class-1 DISABLED (AC-O4). A sid8-suffixed >250KB file is skipped (no own
#    class to claim it); a LEGACY un-suffixed >250KB file still rotates via class-2. No crash.
DE=$(mktemp -d); build_hookdir "$DE"; PE="$DE/proj"; make_proj "$PE"
big_file "$PE/.claude/autoloop-log-2026-07-10-$SID8.md"        # sid8 file (must be SKIPPED, class-1 off)
big_file "$PE/.claude/autoloop-log-2026-07-10.md"              # legacy un-suffixed (class-2 rotates it)
E0=$(count_logs "$PE"); run_hook_sid "$DE" "$PE" "shortid"; E1=$(count_logs "$PE")   # first-8-alnum(shortid)=7<8 → class-1 off
[ "$((E1-E0))" = "1" ] && ok "TWO-CLASS empty-sid: class-1 off → legacy rotates, sid8 skipped (exactly 1 mint)" || bad "TWO-CLASS empty-sid: minted $((E1-E0)) (want 1: legacy only)"
ESUF=$(count_sid_logs "$PE" "$SID8")
[ "$ESUF" = "1" ] && ok "TWO-CLASS empty-sid: the sid8 file was NOT rotated (still exactly 1 sid8 file)" || bad "TWO-CLASS empty-sid: sid8 count changed to $ESUF (want 1 — untouched)"
rm -rf "$DE"

rm -f "$REVERTED"
echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
