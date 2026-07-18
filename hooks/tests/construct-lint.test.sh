#!/usr/bin/env bash
# construct-lint.test.sh — AC8a: the perf-changed hooks (+ the new run-all.sh) carry ZERO bash-4+-only
# constructs, so they run on macOS stock bash 3.2.57 and MSYS Git-bash. Enforceable on MSYS without a
# real 3.2 box. Plain `wait` (no -n) is the 3.2-safe parallel primitive the dispatcher must use.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; HOOKS_SRC="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
FILES="$HOOKS_SRC/stop-dispatcher.sh $HOOKS_SRC/prune-team-inboxes.sh $HERE/run-all.sh"
echo "== AC8a construct-lint (0 bash-4+-only constructs) =="
for f in $FILES; do [ -f "$f" ] || bad "missing scan target: $f"; done
lint() { # <label> <ERE>
  local hits
  # shellcheck disable=SC2086  # $FILES is an intentional space-separated scan list (multi-arg to grep)
  hits=$(grep -REn "$2" $FILES 2>/dev/null || true)
  if [ -z "$hits" ]; then ok "no $1"; else bad "$1 FOUND: $hits"; fi
}
lint "wait -n"           'wait[[:space:]]+-n'
lint "declare -A"        'declare[[:space:]]+-A'
lint "local -A"          'local[[:space:]]+-A'
lint "\${x,,} lowercase" '\$\{[A-Za-z_][A-Za-z0-9_]*,,'
lint "\${x^^} uppercase" '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^'
lint "\${x@} transform"  '\$\{[A-Za-z_][A-Za-z0-9_]*@'
lint "mapfile"           'mapfile'
lint "readarray"         'readarray'
# positive: the dispatcher uses PLAIN wait (the 3.2-safe primitive)
if grep -qE '^[[:space:]]*wait([[:space:]]|$)' "$HOOKS_SRC/stop-dispatcher.sh"; then ok "dispatcher uses plain wait"; else bad "dispatcher missing plain wait"; fi
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
