#!/usr/bin/env bash
# archive-residue.test.sh — A-4. Proves block-backlog-archive-residue.mjs (PostToolUse) blocks when the
# ACTIVE BACKLOG.md still carries archive-residue that block-backlog-status-drift's `### `-header-only
# view misses: a parenthesized tombstone `(R-... -> DONE/archived)`, an `<!-- archived -->` comment, or
# a `### [DONE]`/✅ badge header. Clean boards, a benign `(... -> DONE ...)` line, and non-BACKLOG paths
# no-op. The .mjs reads the POST-WRITE file FROM DISK, so each case writes a temp board then feeds its path.
# Toolchain: bash + node. Run: bash hooks/tests/archive-residue.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/block-backlog-archive-residue.mjs"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected ALLOW (empty) | got: $2"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
# run <backlog-file> -> gate stdout (PostToolUse block JSON or empty=allow)
run() {
  local fp="$1" payload
  payload=$(FP="$fp" node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.env.FP,content:"x"}}))')
  printf '%s' "$payload" | node "$GATE"
}

echo "== archive-residue gate (A-4) =="

# RED-tombstone
B="$D/BACKLOG.md"; printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n\n(R-old -> DONE #12 archived)\n' > "$B"
OUT=$(run "$B"); assert_contains "RED parenthesized tombstone → block" "$OUT" '"decision":"block"'
assert_contains "RED tombstone reason names the count" "$OUT" "tombstone line"

# RED-comment
printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n\n<!-- archived pipeline log for R-old -->\n' > "$B"
OUT=$(run "$B"); assert_contains "RED <!-- archived --> comment → block" "$OUT" "comment block"

# RED-donehdr
printf '# BACKLOG\n\n### [DONE] R-old · shipped\n- log: x\n' > "$B"
OUT=$(run "$B"); assert_contains "RED ### [DONE] badge header → block" "$OUT" "done-badge header"

# GREEN-clean
printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n- problem: y\n- fix: z\n' > "$B"
OUT=$(run "$B"); assert_empty "GREEN clean active board → ALLOW" "$OUT"

# GREEN-benign: a `(... -> DONE ...)` line that is NOT a wave tombstone (doesn't start with `(R-`/`(wave-`).
printf '# BACKLOG\n\n### [QUEUED] R-live · P2\n- aliases: r-live\n- fix: (see the note -> DONE list below)\n' > "$B"
OUT=$(run "$B"); assert_empty "GREEN benign '(see the note -> DONE below)' → ALLOW" "$OUT"

# GREEN-nonboard: a non-BACKLOG path (even with a tombstone-looking line) → no-op.
NB="$D/notes.md"; printf '(R-old -> DONE #1 archived)\n' > "$NB"
OUT=$(run "$NB"); assert_empty "GREEN non-BACKLOG path → no-op (ALLOW)" "$OUT"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
