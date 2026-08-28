#!/usr/bin/env bash
# (activation guard satisfied via a temp autoloop project marker + CLAUDE_PROJECT_DIR).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
HOOK="$HOOKS_SRC/enforce-conventional-commit.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

PROJ=$(mktemp -d); mkdir -p "$PROJ/.claude"; printf '# BACKLOG (fixture)\n' > "$PROJ/.claude/BACKLOG.md"
cleanup() { rm -rf "$PROJ"; }
trap cleanup EXIT

run_commit() {
  local cmd="$1" payload
  payload=$(C="$cmd" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.env.C}}))')
  printf '%s' "$payload" | env AAL_GATES="commit-hygiene:" CLAUDE_PROJECT_DIR="$PROJ" bash "$HOOK" 2>/dev/null
}

echo "== conventional-commit FIRST -m (subject) =="

OUT=$(run_commit 'git commit -m "fix(hooks): anchor cardPR to delivery arrow" -m "B1: body mentioning PR #500 and more" -m "trailing body line"')
assert_empty "RED multi--m valid subject + non-conv bodies → ALLOW (first -m validated)" "$OUT"

OUT=$(run_commit 'git commit -m "just some words" -m "fix: a later conventional-looking body"')
assert_contains "GREEN-deny non-conv FIRST -m → DENY (even if a later -m looks conventional)" "$OUT" "conventional format"

OUT=$(run_commit 'git commit -m "feat(scope): add a thing"')
assert_empty "GREEN-single conventional → ALLOW" "$OUT"

OUT=$(run_commit 'git commit -m "wip stuff"')
assert_contains "GREEN-single non-conventional → DENY" "$OUT" "conventional format"

OUT=$(run_commit 'git commit -am "chore(ci): bump"')
assert_empty "GREEN-glued -am conventional → ALLOW" "$OUT"

OUT=$(run_commit 'git commit -F /some/msg.txt')
assert_empty "GREEN -F (no -m) → ALLOW (unparseable message, hook defers to git)" "$OUT"

OUT=$(run_commit 'git commit --author="John Doe <j@x.com>" -m "feat: z"')
assert_empty "REGRESSION --author=\"X Y\" prefix + conventional -m → ALLOW" "$OUT"

OUT=$(run_commit 'git commit --date="2021-01-01T00:00:00" -m "feat: z"')
assert_empty "REGRESSION --date= prefix + conventional -m → ALLOW" "$OUT"

OUT=$(run_commit 'git commit -c "deadbeef" -m "feat: z"')
assert_empty "REGRESSION -c \"hash\" prefix + conventional -m → ALLOW" "$OUT"

OUT=$(run_commit 'git commit --author="John Doe <j@x.com>" -m "wip stuff"')
assert_contains "REGRESSION --author= prefix + non-conv -m → DENY (subject still checked)" "$OUT" "conventional format"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
