#!/usr/bin/env bash
# rotate-ledger.test.sh — regression fixture for hooks/rotate-ledger.mjs.
#
# Proves the recency-rotation contract in self-contained temp dirs: recency split, undated-section
# kept, never-clobber (a 2nd same-day rotation -> a distinct archive slot), dry-run writes nothing,
# --apply writes both files, under-threshold no-op, all-newer no-op, CRLF section split survives,
# and AAL_NO_GH is honored (offline, conservative PR retention). Toolchain: bash + node only.
#
# B12 self-compliance (the mtime-ordering footgun): this tool judges recency by the DATE STRINGS in a
# section's CONTENT, never by file mtime, so NO assertion here depends on mtime order -- the coarse-
# clock `touch` footgun is designed out, not merely guarded. Sections use a FIXED ancient date
# (2020-01-01, always older than --keep-days) for "old" and `$(date +%Y-%m-%d)` (today; portable on
# GNU + BSD) for "recent", so the split is deterministic across time with no date math. All paths are
# passed to node as ARGUMENTS (MSYS auto-converts an arg path on Git-Bash), never via env, so a temp
# path never diverges between bash and node (pipeline-discipline temp-path footgun).
# Run:  bash hooks/tests/rotate-ledger.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$(cd "$HERE/.." && pwd)/rotate-ledger.mjs"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
halt(){ echo ""; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

command -v node >/dev/null 2>&1 || { echo "node not found -- skipping (bash+node required)"; exit 0; }
TODAY="$(date +%Y-%m-%d)"

# A ledger with one ancient section + one recent section, padded > the (test) 1KB threshold.
seed_split() {  # <file>
  {
    printf '## 2020-01-01 - ancient entry\n'
    for i in $(seq 1 40); do printf 'old padding line %s xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$i"; done
    printf '\n## %s - recent entry\n' "$TODAY"
    for i in $(seq 1 40); do printf 'new padding line %s yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n' "$i"; done
  } > "$1"
}

echo "== rotate-ledger recency-rotation matrix =="

# ===== 1. RECENCY SPLIT + 5. APPLY writes both files =====
D1=$(mktemp -d); L1="$D1/struggle-log.md"; seed_split "$L1"
BYTES=$(wc -c < "$L1" | tr -d ' ')
[ "$BYTES" -gt 1024 ] && ok "SETUP: seed ledger is >1KB ($BYTES)" || { bad "SETUP: seed not >1KB ($BYTES) (halt)"; halt; }
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L1" --apply >/dev/null 2>&1
ARCH1="$D1/struggle-log-archive-$TODAY.md"
if [ -f "$ARCH1" ]; then ok "APPLY: archive file created ($TODAY slot)"; else bad "APPLY: no archive file created"; fi
if grep -q '2020-01-01' "$ARCH1" 2>/dev/null; then ok "RECENCY: ancient section moved to archive"; else bad "RECENCY: ancient section not archived"; fi
if grep -q "$TODAY" "$L1" && ! grep -q '2020-01-01' "$L1"; then ok "RECENCY: recent kept active, ancient removed from active"; else bad "RECENCY: active file wrong"; fi

# ===== 3. NEVER-CLOBBER: re-seed + 2nd same-day --apply -> distinct -2 slot, 1st archive untouched =====
ARCH1_SUM=$(wc -c < "$ARCH1" | tr -d ' ')
seed_split "$L1"
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L1" --apply >/dev/null 2>&1
ARCH2="$D1/struggle-log-archive-$TODAY-2.md"
if [ -f "$ARCH2" ]; then ok "NEVER-CLOBBER: 2nd same-day rotation minted a distinct -2 slot"; else bad "NEVER-CLOBBER: no -2 slot"; fi
NOW_SUM=$(wc -c < "$ARCH1" | tr -d ' ')
[ "$ARCH1_SUM" = "$NOW_SUM" ] && ok "NEVER-CLOBBER: original archive left byte-identical" || bad "NEVER-CLOBBER: original archive modified"
rm -rf "$D1"

# ===== 2. UNDATED SECTION KEPT =====
D2=$(mktemp -d); L2="$D2/struggle-log.md"
{
  printf '## an undated note (no date anywhere)\n'
  for i in $(seq 1 40); do printf 'undated padding %s zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n' "$i"; done
  printf '\n## 2020-01-01 - ancient entry\n'
  for i in $(seq 1 40); do printf 'old padding %s wwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwwww\n' "$i"; done
} > "$L2"
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L2" --apply >/dev/null 2>&1
if grep -q 'undated note' "$L2"; then ok "UNDATED: undated section stayed active"; else bad "UNDATED: undated section wrongly archived"; fi
rm -rf "$D2"

# ===== 4. DRY-RUN writes nothing =====
D3=$(mktemp -d); L3="$D3/struggle-log.md"; seed_split "$L3"
BEFORE=$(wc -c < "$L3" | tr -d ' ')
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L3" >/dev/null 2>&1
AFTER=$(wc -c < "$L3" | tr -d ' ')
NARCH=$(ls "$D3"/*archive* 2>/dev/null | wc -l | tr -d ' ')
{ [ "$BEFORE" = "$AFTER" ] && [ "$NARCH" = "0" ]; } && ok "DRY-RUN: active unchanged + no archive written" || bad "DRY-RUN: wrote something (before=$BEFORE after=$AFTER archives=$NARCH)"
rm -rf "$D3"

# ===== UNDER-THRESHOLD no-op (AAL_ROTATE_MIN_KB honored) =====
D4=$(mktemp -d); L4="$D4/struggle-log.md"; seed_split "$L4"
BEFORE=$(wc -c < "$L4" | tr -d ' ')
AAL_ROTATE_MIN_KB=999999 AAL_NO_GH=1 node "$TOOL" "$L4" --apply >/dev/null 2>&1
AFTER=$(wc -c < "$L4" | tr -d ' ')
NARCH=$(ls "$D4"/*archive* 2>/dev/null | wc -l | tr -d ' ')
{ [ "$BEFORE" = "$AFTER" ] && [ "$NARCH" = "0" ]; } && ok "UNDER-THRESHOLD: below AAL_ROTATE_MIN_KB -> no-op" || bad "UNDER-THRESHOLD: rotated below threshold (archives=$NARCH)"
rm -rf "$D4"

# ===== ALL-NEWER no-op (nothing older than keep-days -> no write) =====
D5=$(mktemp -d); L5="$D5/struggle-log.md"
{
  printf '## %s - recent A\n' "$TODAY"
  for i in $(seq 1 40); do printf 'padding A %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"; done
  printf '\n## %s - recent B\n' "$TODAY"
  for i in $(seq 1 40); do printf 'padding B %s bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' "$i"; done
} > "$L5"
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L5" --apply >/dev/null 2>&1
NARCH=$(ls "$D5"/*archive* 2>/dev/null | wc -l | tr -d ' ')
[ "$NARCH" = "0" ] && ok "ALL-NEWER: all within keep-days -> nothing archived" || bad "ALL-NEWER: archived a within-keep-days section (archives=$NARCH)"
rm -rf "$D5"

# ===== CRLF section split survives =====
D6=$(mktemp -d); L6="$D6/struggle-log.md"; seed_split "$L6"
node -e "const fs=require('fs');const p=process.argv[1];fs.writeFileSync(p,fs.readFileSync(p,'utf8').replace(/\n/g,'\r\n'))" "$L6"
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L6" --apply >/dev/null 2>&1
ARCH6="$D6/struggle-log-archive-$TODAY.md"
{ [ -f "$ARCH6" ] && grep -q '2020-01-01' "$ARCH6" 2>/dev/null && grep -q "$TODAY" "$L6"; } && ok "CRLF: CRLF section split survived (ancient archived, recent kept)" || bad "CRLF: section split failed under CRLF"
rm -rf "$D6"

# ===== AAL_NO_GH honored: ancient PR block archives conservatively, no network =====
D7=$(mktemp -d); L7="$D7/code-reviews.md"
{
  printf '## PR #123 - ancient review 2020-01-01\n'
  for i in $(seq 1 40); do printf 'pr padding %s pppppppppppppppppppppppppppppppppppppppp\n' "$i"; done
  printf '\n## %s - recent entry\n' "$TODAY"
  for i in $(seq 1 40); do printf 'recent padding %s qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq\n' "$i"; done
} > "$L7"
AAL_ROTATE_MIN_KB=1 AAL_NO_GH=1 node "$TOOL" "$L7" --apply >/dev/null 2>&1
ARCH7="$D7/code-reviews-archive-$TODAY.md"
{ [ -f "$ARCH7" ] && grep -q 'PR #123' "$ARCH7" 2>/dev/null; } && ok "AAL_NO_GH: offline run archived the >30d PR block via conservative fallback" || bad "AAL_NO_GH: PR block not archived"
rm -rf "$D7"

echo ""; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
