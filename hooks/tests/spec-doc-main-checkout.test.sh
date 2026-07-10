#!/usr/bin/env bash
# spec-doc-main-checkout.test.sh — A-3. Proves block-spec-doc-in-main-checkout.mjs denies writing a
# wave spec doc (docs/product-specs/…) into the shared MAIN checkout (AAL_MAIN_REPO), allows the same
# under the worktree, and no-ops for non-spec paths / when AAL_MAIN_REPO is unset.
# Runs the .mjs directly (judges from AAL_MAIN_REPO + the tool_input file_path; no board/activation).
# Toolchain: bash + node. Run: bash hooks/tests/spec-doc-main-checkout.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/block-spec-doc-in-main-checkout.mjs"
MAIN="/main/repo"; WT="/wt-root"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

# run <file_path> [main] [wtroot] -> gate stdout. If main empty, AAL_MAIN_REPO is unset (no-op case).
run() {
  local fp="$1" main="${2-$MAIN}" wt="${3-$WT}" payload
  payload=$(FP="$fp" node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.env.FP,content:"x"}}))')
  if [ -z "$main" ]; then
    printf '%s' "$payload" | env -u AAL_MAIN_REPO AAL_WORKTREE_ROOT="$wt" node "$GATE"
  else
    printf '%s' "$payload" | env AAL_MAIN_REPO="$main" AAL_WORKTREE_ROOT="$wt" node "$GATE"
  fi
}

echo "== spec-doc -> worktree not main (A-3) =="

# RED: a plan doc under MAIN/docs/product-specs/ → DENY.
OUT=$(run "$MAIN/docs/product-specs/R-foo-plan.md")
assert_contains "RED plan doc under MAIN/docs/product-specs → DENY" "$OUT" "WAVE SPEC DOC"

# RED-arch: architecture doc, backslash path (Windows) normalized → DENY.
OUT=$(run "$MAIN\\docs\\product-specs\\R-foo-architecture.md")
assert_contains "RED architecture doc (backslash path) → DENY" "$OUT" "WAVE SPEC DOC"

# GREEN-worktree: the SAME spec doc under the worktree (not main) → ALLOW.
OUT=$(run "$WT/r-foo/docs/product-specs/R-foo-plan.md")
assert_empty "GREEN spec doc under worktree → ALLOW" "$OUT"

# GREEN-nonspec: a non-spec path under MAIN → ALLOW (only docs/product-specs is gated).
OUT=$(run "$MAIN/hooks/some-hook.mjs")
assert_empty "GREEN non-spec path under MAIN → ALLOW" "$OUT"

# GREEN-no-env: AAL_MAIN_REPO unset → no-op even for a main-repo spec path.
OUT=$(run "$MAIN/docs/product-specs/R-foo-plan.md" "")
assert_empty "GREEN no AAL_MAIN_REPO → no-op (ALLOW)" "$OUT"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
