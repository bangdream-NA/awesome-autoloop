#!/usr/bin/env bash
# Tests for block-audit-workflow-while-board-open.mjs — §15 audit-gate (PreToolUse Workflow).
# Node hook, so we roll a node-based runner (cf. block-backlog-status-drift.test.sh).
#
# REGRESSION FOCUS (2026-07-09): intent must be judged on the workflow's DECLARED
# identity (top-level name/description/title/scriptPath + the `export const meta`
# literal), NOT the whole script body — a DATA filename quoted in an agent prompt
# (struggle-log-audit-2026-05-28.md) used to misclassify a self-improve run as a
# site audit (the §8 whole-command-deny incidental-text trap). Fallback: a script
# whose meta literal can't be extracted is still scanned whole (conservative).
# Board state is controlled via the test-only AAL_AUDITGATE_BACKLOG env override.
set -u
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/"block-audit-workflow-while-board-open.mjs"

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
AAL_PROJ=/tmp/aal-fx-block-audit-workflow-while-board-open
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------

PASS=0; FAIL=0; FAILURES=()

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPD="$TESTS_DIR/.tmp-auditgate-$$"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
printf '# BACKLOG\n\n### [QUEUED] R-x · P2 · open card\n- log:\n' > "$TMPD/board-open.md"
printf '# BACKLOG\n\n(clear — no actionable cards)\n' > "$TMPD/board-clear.md"
# node needs Windows-style paths (git-bash /tmp-style paths diverge — pipeline-discipline §12)
BOARD_OPEN="$(cygpath -m "$TMPD/board-open.md" 2>/dev/null || echo "$TMPD/board-open.md")"
BOARD_CLEAR="$(cygpath -m "$TMPD/board-clear.md" 2>/dev/null || echo "$TMPD/board-clear.md")"

is_deny() { printf '%s' "$2" | AAL_AUDITGATE_BACKLOG="$1" node "$HOOK" 2>&1 | grep -q '"permissionDecision":"deny"'; }
deny()  { if is_deny "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY: $1"); fi; }
allow() { if is_deny "$2" "$3"; then FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-ALLOW-BUT-DENIED: $1"); else PASS=$((PASS+1)); fi; }

# --- the false-positive regression: 'audit' ONLY inside a quoted data filename → ALLOW even on an open board ---
# 🔴 ONE ARM FROM THE SOURCE FIXTURE IS NOT PORTED — an allow-arm for an audit aimed at a
# DIFFERENT project. The originating gate asked two questions (is this audit-shaped AND is it
# aimed at my project); the gate in this kit asks only the first: `AUDIT_RE = /\baudit\b|
# categorized|full-site/` over the workflow's meta, then reads the board. There is no
# target-project leg to exercise, so the arm would assert a distinction the shipped artifact does
# not draw. Dropped with this note rather than silently, and reported with the delivery.
allow "audit only in data filename (self-improve mining)" "$BOARD_OPEN" \
  '{"tool_input":{"script":"export const meta = { name: \"selfimprove-struggle-mining\", description: \"mine struggle logs for friction patterns\", phases: [] }\nconst files = [\"Z:/repo/.claude/struggle-log.md\", \"Z:/Users/x/.claude/struggle-log-audit-2026-05-28.md\"]\nawait agent(\"mine \" + files[1])"}}'

# --- declared audit intent + example-project + open board → DENY ---
deny  "declared audit meta + example-project, open board" "$BOARD_OPEN" \
  '{"tool_input":{"script":"export const meta = { name: \"full-site-audit\", description: \"categorized full-site audit of example-project\", phases: [] }\nawait agent(\"scan Z:/repo pages\")"}}'
deny  "named workflow param, no script" "$BOARD_OPEN" \
  '{"tool_input":{"name":"full-site-audit","description":"audit example-project by category"}}'
deny  "no extractable meta → whole-script fallback" "$BOARD_OPEN" \
  '{"tool_input":{"script":"await agent(\"run a full audit of the example-project site and file findings\")"}}'

# --- another project's / non-audit / cleared board → ALLOW ---
allow "ordinary example-project workflow, no audit intent" "$BOARD_OPEN" \
  '{"tool_input":{"script":"export const meta = { name: \"fix-wave\", description: \"implement one fix\" }\nawait agent(\"edit Z:/repo/apps/web\")"}}'
allow "audit meta + example-project on a CLEARED board" "$BOARD_CLEAR" \
  '{"tool_input":{"script":"export const meta = { name: \"full-site-audit\", description: \"categorized full-site audit of example-project\" }\nawait agent(\"scan Z:/repo\")"}}'

# --- fail-closed: board unreadable → DENY ---
deny  "board unreadable → fail-closed" "$TMPD/does-not-exist.md" \
  '{"tool_input":{"script":"export const meta = { name: \"full-site-audit\", description: \"audit example-project\" }\nawait agent(\"x\")"}}'

name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
