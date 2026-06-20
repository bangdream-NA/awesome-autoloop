#!/usr/bin/env bash
# deny-gate-crash-allow.test.sh — R-12 regression matrix (arch §A-5 / AC-5).
#
# Proves each of the 4 deny gates STILL emits its deny JSON when its struggle-log is UNWRITABLE
# (the `set -e` crash-allow fail-open: a failed `>>` redirect trips strict mode and aborts the
# hook BEFORE its `cat <<EOF` deny heredoc → the gate that must DENY silently ALLOWS).
# RED on HEAD (empty stdout) → GREEN after the ` 2>/dev/null || true` guard.
#
# The make-or-break (AC-1) keys on the deny JSON's PRESENCE on STDOUT, never on "no crash" and
# never on stderr — a PreToolUse hook's decision channel is its stdout JSON (README), and the
# locked guard deliberately still leaks the harmless redirect-open diagnostic on stderr (arch
# §0.4/§Y-1: `2>/dev/null` after `>>` cannot catch the OPEN-failure diagnostic; correctness rides
# on `|| true` alone). So we capture stdout SEPARATELY (stderr discarded) and assert the JSON.
#
# Toolchain: bash + node only (mirrors stop-dispatcher.test.sh — `set -uo pipefail` runner, NOT
# -e; mktemp temp dirs; ok/bad/assert_contains helpers; print RESULT; exit 1 on any fail).
# Run:  bash hooks/tests/deny-gate-crash-allow.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
# assert_contains <label> <haystack> <needle>
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: [$2]" ;; esac; }
# assert_not_contains <label> <haystack> <needle>
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: [$2]" ;; *) ok "$1" ;; esac; }
# assert_empty <label> <haystack>
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected EMPTY | got: [$2]"; fi; }
# assert_eq <label> <got> <want>
assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got: [$2] | want: [$3]"; fi; }

DENY='"permissionDecision":"deny"'

# ---- Q2 false-green SELF-CHECK: abort LOUD if chmod 444 does NOT block the owner append here ----
# A runtime where the "unwritable" setup silently allows the write would pass the matrix BEFORE
# AND AFTER the fix (a false-green that proves nothing — pipeline-discipline §6). So before relying
# on the mechanism, prove it denies the owner's `>>` under `set -e` on THIS runtime; otherwise abort.
selfcheck_unwritable() {
  local f="$1"; : > "$f"; chmod 444 "$f"
  if ( set -e; echo PROBE >> "$f" ) 2>/dev/null; then
    printf '\n!! ABORT: chmod 444 did NOT block the owner append on this runtime — the unwritable\n'
    printf '!! setup is a NO-OP here, so the fixture cannot distinguish fixed from broken (false-green).\n'
    chmod 777 "$f" 2>/dev/null; rm -f "$f"; exit 2
  fi
  chmod 777 "$f" 2>/dev/null; rm -f "$f"
}

# ---- run_gate <hook-relpath-or-abspath> <stdin-json> [writable] ----------------------------------
# Builds a temp autoloop project, writes a struggle-log (UNWRITABLE via chmod 444 unless arg 3 is
# "writable"), runs the gate end-to-end, captures STDOUT ONLY (stderr discarded — the decision
# channel is stdout). Echoes: STDOUT on line(s), then a final line `__SL__<last struggle-log line>`
# so a caller can also assert the appended log line (R-WRITABLE / AC-2). Cleans up the temp project.
run_gate() {
  local hook="$1" stdin="$2" mode="${3:-unwritable}"
  case "$hook" in /*|[A-Za-z]:*) ;; *) hook="$HOOKS_SRC/$hook" ;; esac
  local proj; proj="$(mktemp -d "$HOME/.aal-r12-XXXXXX")"
  mkdir -p "$proj/.claude" "$proj/docs/product-specs"; touch "$proj/.claude/.autoloop"
  local sl="$proj/.claude/struggle-log.md"; printf '# struggle log\n' > "$sl"
  [ "$mode" = "writable" ] || chmod 444 "$sl"
  local out lastline
  out=$(CLAUDE_PROJECT_DIR="$proj" AAL_GATES="pipeline-roles" \
        bash "$hook" <<<"$stdin" 2>/dev/null) || true
  chmod 777 "$sl" 2>/dev/null
  lastline=$(tail -1 "$sl" 2>/dev/null || true)
  rm -rf "$proj"
  printf '%s\n__SL__%s' "$out" "$lastline"
}
# helpers to split run_gate's combined output
gate_stdout() { printf '%s' "${1%__SL__*}"; }   # everything before the __SL__ marker
gate_logline(){ printf '%s' "${1##*__SL__}"; }   # the appended struggle-log line

# ---- build a HEAD-restored (suffix-stripped) copy of a gate for the RED→GREEN proof --------------
# Copies the gate + its lib/ deps into a temp HOOKDIR, then STRIPS the locked ` 2>/dev/null || true`
# suffix off the struggle-log append line — restoring the exact pre-fix HEAD shape (works for BOTH
# the `&&` one-liner and the `if/fi` block sites, since we drop the literal suffix from any append
# line that carries it). Echoes the temp hook's ABSOLUTE path. NEVER touches the real source.
build_head_copy() {
  local gate="$1"
  local d; d="$(mktemp -d "$HOME/.aal-r12-HEAD-XXXXXX")"
  mkdir -p "$d/lib"
  cp "$HOOKS_SRC/lib/activation.sh"  "$d/lib/activation.sh"
  cp "$HOOKS_SRC/lib/parse-json.sh"  "$d/lib/parse-json.sh"
  cp "$HOOKS_SRC/lib/log-denial.sh"  "$d/lib/log-denial.sh"
  # strip the suffix off the append-to-struggle-log line (restores HEAD's unguarded `>>`).
  # Delimiter is `#` (NOT `|` — the pattern contains a literal `||`, which would be parsed as the
  # s-command end and break sed; `/` is also out because of the `2>/dev/null`).
  sed 's# >> "$STRUGGLE_LOG" 2>/dev/null || true# >> "$STRUGGLE_LOG"#' \
      "$HOOKS_SRC/$gate" > "$d/$gate"
  printf '%s' "$d/$gate"
}

# Triggers that reach each gate's deny branch (verified end-to-end on the fixed code, writable log).
TRIG_BARE='{"team_name":""}'
TRIG_PLANNER='{"team_name":"realwave","subagent_type":"developer"}'
TRIG_VTYPE='{"team_name":"t","subagent_type":"badtype"}'
TRIG_LEADEDIT='{"file_path":"/x/src/foo.ts"}'
# byte-identical-to-HEAD struggle-log line block-bare-agent appends (arch §0.3 / AC-2)
DATE_NOW=$(date +%Y-%m-%d)
EXPECT_BARE_LOGLINE="| $DATE_NOW | team-lead | Agent spawn | Bare Agent call blocked by PreToolUse hook | No team_name in tool_input | Auto-blocked |"

echo "== R-12 deny-gate crash-allow regression matrix =="
echo ""

# ---- C-SELF: prove the unwritable mechanism is real BEFORE relying on it (Q2 false-green guard) --
echo "--- C-SELF: unwritable-mechanism self-check (loud abort if chmod 444 no-ops for the owner) ---"
selfcheck_unwritable "$HOME/.aal-r12-selfcheck-$$"
ok "C-SELF chmod 444 genuinely blocks the owner append on this runtime"
echo ""

# ---- R-1..R-4: each gate, fed its trigger with an UNWRITABLE struggle-log, MUST emit deny JSON ---
echo "--- R-1..R-4: deny JSON PRESENT under an unwritable struggle-log (the AC-1 make-or-break) ---"
R1=$(run_gate block-bare-agent.sh        "$TRIG_BARE")
assert_contains "R-1 block-bare-agent denies under unwritable log"        "$(gate_stdout "$R1")" "$DENY"
R2=$(run_gate enforce-planner-first.sh   "$TRIG_PLANNER")
assert_contains "R-2 enforce-planner-first denies under unwritable log"   "$(gate_stdout "$R2")" "$DENY"
R3=$(run_gate validate-agent-type.sh     "$TRIG_VTYPE")
assert_contains "R-3 validate-agent-type denies under unwritable log"     "$(gate_stdout "$R3")" "$DENY"
R4=$(run_gate block-lead-editing-source.sh "$TRIG_LEADEDIT")
assert_contains "R-4 block-lead-editing-source denies under unwritable log (SOLE side-effect; A-4)" "$(gate_stdout "$R4")" "$DENY"
echo ""

# ---- R-WRITABLE: writable log → deny PRESENT *and* the appended log line is byte-identical (AC-2) -
echo "--- R-WRITABLE: writable log → deny JSON + byte-identical struggle-log line (AC-2 happy path) ---"
RW=$(run_gate block-bare-agent.sh "$TRIG_BARE" writable)
assert_contains "R-WRITABLE deny JSON still present (guard altered only fatality)" "$(gate_stdout "$RW")" "$DENY"
assert_eq       "R-WRITABLE struggle-log line byte-identical to HEAD"              "$(gate_logline "$RW")" "$EXPECT_BARE_LOGLINE"
echo ""

# ---- R-RED→GREEN: HEAD-restored (suffix-stripped) copy of EACH gate → deny ABSENT (silent allow) -
# Proves the matrix actually catches the fail-open for ALL 4 gates individually (§Y-2 / LOW#1), not
# just that fixed code passes. Mirrors stop-dispatcher.test.sh's deliberately-broken-dispatcher RED.
echo "--- R-RED→GREEN: each gate's pre-fix HEAD copy emits EMPTY stdout under an unwritable log ---"
for spec in "block-bare-agent.sh|$TRIG_BARE" \
            "enforce-planner-first.sh|$TRIG_PLANNER" \
            "validate-agent-type.sh|$TRIG_VTYPE" \
            "block-lead-editing-source.sh|$TRIG_LEADEDIT"; do
  gate="${spec%%|*}"; trig="${spec#*|}"
  headcopy=$(build_head_copy "$gate")
  # sanity: the strip MUST have produced an unguarded append (else the RED proof is vacuous).
  if grep -qE '>> "\$STRUGGLE_LOG"( 2>/dev/null \|\| true)?$' "$headcopy" \
     && ! grep -qE '>> "\$STRUGGLE_LOG" 2>/dev/null \|\| true' "$headcopy"; then
    ok "RED setup: $gate suffix stripped (append is unguarded HEAD shape)"
  else
    bad "RED setup: $gate suffix NOT stripped — RED proof would be vacuous"
  fi
  RED=$(run_gate "$headcopy" "$trig")
  assert_empty "RED-prove: $gate pre-fix copy emits EMPTY stdout under unwritable log (the bug)" "$(gate_stdout "$RED")"
  # GREEN companion: the FIXED gate, same trigger + unwritable log, DOES deny (proves the row works).
  GREEN=$(run_gate "$gate" "$trig")
  assert_contains "GREEN: $gate fixed copy denies under the same unwritable log" "$(gate_stdout "$GREEN")" "$DENY"
  rm -rf "$(dirname "$headcopy")"
done
echo ""

echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
