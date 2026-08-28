#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-oplog-row-format.mjs
PASS=0; FAIL=0; FAILURES=()

is_deny() { printf '%s' "$1" | node "$HOOK" 2>&1 | grep -q '"permissionDecision":"deny"'; }
deny() {
  local desc="$1"; local payload="$2"; local expect_sub="${3:-}"
  local out
  out=$(printf '%s' "$payload" | node "$HOOK" 2>&1 || true)
  if echo "$out" | grep -q '"permissionDecision":"deny"'; then
    if [ -n "$expect_sub" ] && ! echo "$out" | grep -q "$expect_sub"; then
      FAIL=$((FAIL+1)); FAILURES+=("DENY-WRONG-REASON: $desc (got: $(echo "$out" | head -c 180))")
    else
      PASS=$((PASS+1))
    fi
  else
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY-BUT-ALLOWED: $desc (got: $(echo "$out" | head -c 180))")
  fi
}
allow() {
  local desc="$1"; local payload="$2"
  if is_deny "$payload"; then
    FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-ALLOW-BUT-DENIED: $desc")
  else
    PASS=$((PASS+1))
  fi
}

allow "other md file" \
  '{"tool_name":"Write","tool_input":{"file_path":"Z:/my-project/.claude/BACKLOG.md","content":"- this is a very long backlog line that would fail if the gate were not path-scoped and keeps going past six hundred characters to make sure path scoping is the only thing that saves it from a length denial which would otherwise fire on any long bullet"}}'

GOOD='- 2026-07-20 04:1xZ · **#903 reingest timer DoD-VERIFIED (batch 81)**: install+AC-9 loud-fail+AC-11 real tick journal · problem=18@rest.3 all open-refusal · proof=matched_open 18/18 after_install'
allow "canonical concise bullet" \
  "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"Z:/my-project/.claude/autoloop-log-2026-07-18-99bcf8b8.md\",\"content\":\"# head\\n\\n${GOOD}\\n\"}}"

ESSAY_BODY=$(node -e 'process.stdout.write("x".repeat(700))')
deny "essay bullet too long" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"Z:/x/.claude/autoloop-log-2026-07-18-99bcf8b8.md\",\"old_string\":\"x\",\"new_string\":\"- **three plans all passed (batch 80)**: ${ESSAY_BODY}\"}}" \
  "op-log format"

deny "ledger bullet missing glue" \
  '{"tool_name":"Write","tool_input":{"file_path":"Z:/x/.claude/autoloop-log-foo.md","content":"- **MERGE PR #909 (batch 112)** proof codereview APPROVED but this line forgot the middle-dot glue"}}' \
  "missing"

allow "short section sub-bullet" \
  '{"tool_name":"Write","tool_input":{"file_path":"Z:/x/.claude/autoloop-log-foo.md","content":"## 12:50Z — start\n- Board = 15 cards, matches handoff.\n"}}'

ESSAY2=$(node -e 'process.stdout.write("y".repeat(650))')
deny "edit new_string essay" \
  "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"Z:/my-project/.claude/autoloop-log-2026-07-18-99bcf8b8.md\",\"old_string\":\"a\",\"new_string\":\"- ${ESSAY2}\"}}" \
  "op-log format"

allow "action arrow shape" \
  '{"tool_name":"Write","tool_input":{"file_path":"Z:/my-project/.claude/autoloop-log-2026-07-20-abcdef01.md","content":"- 2026-07-20 05:0xZ · **stall-check**: cron alive → 0 dead waves · proof=CronList 1 job\n"}}'

name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
