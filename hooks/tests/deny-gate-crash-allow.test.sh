#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: [$2]" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: [$2]" ;; *) ok "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected EMPTY | got: [$2]"; fi; }
assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got: [$2] | want: [$3]"; fi; }

DENY='"permissionDecision":"deny"'

selfcheck_unwritable() {
  local f="$1"; : > "$f"; chmod 444 "$f"
  if ( set -e; echo PROBE >> "$f" ) 2>/dev/null; then
    printf '\n!! ABORT: chmod 444 did NOT block the owner append on this runtime — the unwritable\n'
    printf '!! setup is a NO-OP here, so the fixture cannot distinguish fixed from broken (false-green).\n'
    chmod 777 "$f" 2>/dev/null; rm -f "$f"; exit 2
  fi
  chmod 777 "$f" 2>/dev/null; rm -f "$f"
}

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
gate_stdout() { printf '%s' "${1%__SL__*}"; }
gate_logline(){ printf '%s' "${1##*__SL__}"; }

build_head_copy() {
  local gate="$1"
  local d; d="$(mktemp -d "$HOME/.aal-r12-HEAD-XXXXXX")"
  mkdir -p "$d/lib"
  cp "$HOOKS_SRC/lib/activation.sh"  "$d/lib/activation.sh"
  cp "$HOOKS_SRC/lib/parse-json.sh"  "$d/lib/parse-json.sh"
  cp "$HOOKS_SRC/lib/log-denial.sh"  "$d/lib/log-denial.sh"
  sed 's# >> "$STRUGGLE_LOG" 2>/dev/null || true# >> "$STRUGGLE_LOG"#' \
      "$HOOKS_SRC/$gate" > "$d/$gate"
  printf '%s' "$d/$gate"
}

TRIG_BARE='{"team_name":""}'
TRIG_PLANNER='{"team_name":"realwave","subagent_type":"developer"}'
TRIG_VTYPE='{"team_name":"t","subagent_type":"badtype"}'
TRIG_LEADEDIT='{"file_path":"/x/src/foo.ts"}'
DATE_NOW=$(date +%Y-%m-%d)
EXPECT_BARE_LOGLINE="| $DATE_NOW | team-lead | Agent spawn | Bare Agent call blocked by PreToolUse hook | No team_name in tool_input | Auto-blocked |"

echo "== R-12 deny-gate crash-allow regression matrix =="
echo ""

echo "--- C-SELF: unwritable-mechanism self-check (loud abort if chmod 444 no-ops for the owner) ---"
selfcheck_unwritable "$HOME/.aal-r12-selfcheck-$$"
ok "C-SELF chmod 444 genuinely blocks the owner append on this runtime"
echo ""

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

echo "--- R-WRITABLE: writable log → deny JSON + byte-identical struggle-log line (AC-2 happy path) ---"
RW=$(run_gate block-bare-agent.sh "$TRIG_BARE" writable)
assert_contains "R-WRITABLE deny JSON still present (guard altered only fatality)" "$(gate_stdout "$RW")" "$DENY"
assert_eq       "R-WRITABLE struggle-log line byte-identical to HEAD"              "$(gate_logline "$RW")" "$EXPECT_BARE_LOGLINE"
echo ""

echo "--- R-RED→GREEN: each gate's pre-fix HEAD copy emits EMPTY stdout under an unwritable log ---"
for spec in "block-bare-agent.sh|$TRIG_BARE" \
            "enforce-planner-first.sh|$TRIG_PLANNER" \
            "validate-agent-type.sh|$TRIG_VTYPE" \
            "block-lead-editing-source.sh|$TRIG_LEADEDIT"; do
  gate="${spec%%|*}"; trig="${spec#*|}"
  headcopy=$(build_head_copy "$gate")
  if grep -qE '>> "\$STRUGGLE_LOG"( 2>/dev/null \|\| true)?$' "$headcopy" \
     && ! grep -qE '>> "\$STRUGGLE_LOG" 2>/dev/null \|\| true' "$headcopy"; then
    ok "RED setup: $gate suffix stripped (append is unguarded HEAD shape)"
  else
    bad "RED setup: $gate suffix NOT stripped — RED proof would be vacuous"
  fi
  RED=$(run_gate "$headcopy" "$trig")
  assert_empty "RED-prove: $gate pre-fix copy emits EMPTY stdout under unwritable log (the bug)" "$(gate_stdout "$RED")"
  GREEN=$(run_gate "$gate" "$trig")
  assert_contains "GREEN: $gate fixed copy denies under the same unwritable log" "$(gate_stdout "$GREEN")" "$DENY"
  rm -rf "$(dirname "$headcopy")"
done
echo ""

echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
