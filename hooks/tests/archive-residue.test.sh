#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/block-backlog-archive-residue.mjs"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
run() {
  local fp="$1" payload
  payload=$(FP="$fp" node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.env.FP,content:"x"}}))')
  printf '%s' "$payload" | node "$GATE"
}

echo "== archive-residue gate (A-4) =="

B="$D/BACKLOG.md"; printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n\n(R-old -> DONE #12 archived)\n' > "$B"
OUT=$(run "$B"); assert_contains "RED parenthesized tombstone → block" "$OUT" '"decision":"block"'
assert_contains "RED tombstone reason names the count" "$OUT" "tombstone line"

printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n\n<!-- archived pipeline log for R-old -->\n' > "$B"
OUT=$(run "$B"); assert_contains "RED <!-- archived --> comment → block" "$OUT" "comment block"

printf '# BACKLOG\n\n### [DONE] R-old · shipped\n- log: x\n' > "$B"
OUT=$(run "$B"); assert_contains "RED ### [DONE] badge header → block" "$OUT" "done-badge header"

printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n- problem: y\n- fix: z\n' > "$B"
OUT=$(run "$B"); assert_empty "GREEN clean active board → ALLOW" "$OUT"

printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n- fix: (see the note -> DONE list below)\n' > "$B"
OUT=$(run "$B"); assert_empty "GREEN benign '(see the note -> DONE below)' → ALLOW" "$OUT"

NB="$D/notes.md"; printf '(R-old -> DONE #1 archived)\n' > "$NB"
OUT=$(run "$NB"); assert_empty "GREEN non-BACKLOG path → no-op (ALLOW)" "$OUT"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
