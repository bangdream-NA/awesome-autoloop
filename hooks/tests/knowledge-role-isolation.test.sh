#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
GATE="$HOOKS_SRC/knowledge-role-isolation.mjs"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v node >/dev/null 2>&1 || { echo "  [FAIL] node absent — this fixture cannot run"; exit 1; }
[ -f "$GATE" ] || { echo "  [FAIL] gate not found: $GATE"; exit 1; }

DENY='"permissionDecision":"deny"'

run() {
  FP="$1" ACTOR="$2" TOOL="${3:-Write}" node -e '
process.stdout.write(JSON.stringify({
  tool_name: process.env.TOOL,
  tool_input: { file_path: process.env.FP },
}));
' | AAL_AGENT_TYPE="$2" node "$GATE" 2>/dev/null
}

echo "== must-RED: a role writing into a DIFFERENT role directory is DENIED =="
OUT=$(run "/proj/.claude/knowledge/architect/note.md" "developer")
case "$OUT" in
  *"$DENY"*) ok "RED  developer -> knowledge/architect/ is DENIED" ;;
  *)         bad "RED  developer -> knowledge/architect/ should DENY | got: [$OUT]" ;;
esac
case "$OUT" in
  *"knowledge/developer/note.md"*) ok "RED  the deny names the CORRECT destination (its own role dir)" ;;
  *)                               bad "RED  the deny must name knowledge/developer/note.md | got: [$OUT]" ;;
esac
case "$OUT" in
  *"knowledge/common/"*) ok "RED  the deny offers the second exit (common/) with the index line format" ;;
  *)                     bad "RED  the deny must offer knowledge/common/ | got: [$OUT]" ;;
esac

OUT=$(run "/proj/.claude/knowledge/code-reviewer/x.md" "planner" "Edit")
case "$OUT" in
  *"$DENY"*) ok "RED  planner -> knowledge/code-reviewer/ via Edit is DENIED" ;;
  *)         bad "RED  Edit must be gated too | got: [$OUT]" ;;
esac

echo ""
echo "== must-GREEN: the arms that carry the weight, because a deny gate that over-fires is worse =="
OUT=$(run "/proj/.claude/knowledge/developer/note.md" "developer")
[ -z "${OUT//\{\}/}" ] && ok "GREEN developer -> its OWN knowledge/developer/ is ALLOWED" || bad "GREEN own-role write must be allowed | got: [$OUT]"

OUT=$(run "/proj/.claude/knowledge/common/shared.md" "developer")
[ -z "${OUT//\{\}/}" ] && ok "GREEN any role -> knowledge/common/ is ALLOWED" || bad "GREEN common/ must be allowed | got: [$OUT]"

OUT=$(run "/proj/src/app.ts" "developer")
[ -z "${OUT//\{\}/}" ] && ok "GREEN a path outside knowledge/ is ALLOWED (the gate is scoped)" || bad "GREEN non-knowledge path must be allowed | got: [$OUT]"

OUT=$(run "/proj/.claude/knowledge/INDEX.md" "developer")
[ -z "${OUT//\{\}/}" ] && ok "GREEN the ROOT index is not a role dir, so this gate does not fire on it" || bad "GREEN root index must not fire here | got: [$OUT]"

OUT=$(run "/proj/.claude/knowledge/architect/note.md" "")
[ -z "${OUT//\{\}/}" ] && ok "GREEN unknown actor -> ALLOW (fails OPEN: this gate never guesses a role)" || bad "GREEN unknown actor must allow | got: [$OUT]"

OUT=$(run "/proj/.claude/knowledge/architect/note.md" "developer" "Read")
[ -z "${OUT//\{\}/}" ] && ok "GREEN a READ of another role's dir is ALLOWED (the contract restricts writes only)" || bad "GREEN read must be allowed | got: [$OUT]"

OUT=$(run "/proj/.claude/knowledge/notarole/x.md" "developer")
[ -z "${OUT//\{\}/}" ] && ok "GREEN a directory that is not a pipeline role is not gated" || bad "GREEN non-role dir must be allowed | got: [$OUT]"

echo ""
echo "RESULT: $PASS passed, $FAIL failed (arms run: $((PASS+FAIL)))"
[ "$FAIL" -eq 0 ]
