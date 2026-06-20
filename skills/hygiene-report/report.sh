#!/usr/bin/env bash
# hygiene-report — repo debt / readability snapshot for the CURRENT git repo.
# Stack-agnostic (counts tracked source files, any language). Read-only.
# Lightweight readability + hygiene-score snapshot.
#
# Run from a repo root: bash ${CLAUDE_PLUGIN_ROOT}/skills/hygiene-report/report.sh [line_threshold]
set -uo pipefail

THRESH="${1:-800}"          # files over this many lines are flagged
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a git repo"; exit 1; }
cd "$ROOT" || exit 1
NAME=$(basename "$ROOT")

# Tracked SOURCE files, excluding generated / vendored / data blobs / docs / binary.
# (A readability-debt report targets code; data fixtures + historical specs being
#  large is expected, not debt — they'd otherwise dominate + tank the score.)
EXCLUDE='(^|/)(node_modules|dist|build|\.next|coverage|out|vendor|fixtures?|__snapshots__)/|(^|/)data[-/]|(^|/)docs/|\.(lock|min\.(js|css)|map|png|jpg|jpeg|gif|svg|ico|woff2?|ttf|base64|snap|html|sqlite|gz|sql|json|ndjson|parquet|dump|csv|tsv)$|-lock\.(json|yaml)$|pnpm-lock'
FILES=()
while IFS= read -r f; do [ -n "$f" ] && FILES+=("$f"); done < <(git ls-files | grep -ivE "$EXCLUDE")

echo "== hygiene-report :: $NAME ($(git rev-parse --short HEAD 2>/dev/null)) =="
echo "tracked source files (post-exclude): ${#FILES[@]}"

# --- Largest files + over-threshold ---
TMP=$(mktemp); : >"$TMP"
for f in ${FILES[@]+"${FILES[@]}"}; do [ -f "$f" ] || continue; n=$(wc -l <"$f" 2>/dev/null || echo 0); printf '%s\t%s\n' "$n" "$f" >>"$TMP"; done
OVER=$(awk -F'\t' -v t="$THRESH" '$1>t' "$TMP" | sort -rn | head -40)
OVER_N=$(printf '%s\n' "$OVER" | grep -c . || true)

echo ""
echo "1. Largest files (top 15)"
sort -rn "$TMP" | head -15 | awk -F'\t' '{printf "   %6d  %s\n",$1,$2}'

echo ""
echo "2. Files over $THRESH lines  ($OVER_N)"
if [ "$OVER_N" -gt 0 ]; then printf '%s\n' "$OVER" | awk -F'\t' '{printf "   %6d  %s\n",$1,$2}'; else echo "   none"; fi

# --- TODO / FIXME hotspots ---
echo ""
echo "3. TODO/FIXME hotspots (top 12 files)"
TODO_TOTAL=$(grep -rInE 'TODO|FIXME|HACK|XXX' ${FILES[@]+"${FILES[@]}"} </dev/null 2>/dev/null | wc -l | tr -d ' ')
grep -rIlE 'TODO|FIXME|HACK|XXX' ${FILES[@]+"${FILES[@]}"} </dev/null 2>/dev/null \
  | while IFS= read -r f; do c=$(grep -cE 'TODO|FIXME|HACK|XXX' "$f" 2>/dev/null); printf '%s\t%s\n' "$c" "$f"; done \
  | sort -rn | head -12 | awk -F'\t' '{printf "   %4d  %s\n",$1,$2}'
echo "   (total markers: ${TODO_TOTAL:-0})"

# --- 30-day churn ---
echo ""
echo "4. Fastest-changing files (last 30 days, top 12)"
git log --since="30 days ago" --name-only --pretty=format: 2>/dev/null \
  | grep -ivE "$EXCLUDE" | grep . | sort | uniq -c | sort -rn | head -12 \
  | awk '{printf "   %4d  %s\n",$1,$2}'

# --- Lightweight hygiene score ---
echo ""
SCORE=100
SCORE=$(( SCORE - 3*OVER_N ))                                  # -3 per file >threshold
TODO_PEN=$(( ${TODO_TOTAL:-0} / 10 )); SCORE=$(( SCORE - TODO_PEN ))   # -1 per 10 markers
[ "$SCORE" -lt 0 ] && SCORE=0
echo "== hygiene score: $SCORE/100  (-$((3*OVER_N)) oversized files, -$TODO_PEN TODO density) =="
echo "   (advisory only — for visibility on where rot accumulates, not a gate)"
rm -f "$TMP"
