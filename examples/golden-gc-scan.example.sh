#!/usr/bin/env bash
# EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json
# (or just run it standalone: `bash golden-gc-scan.example.sh`).
#
# A "golden principles" GC scan (Kotlin / Compose stack pattern): a standalone debt/drift report an
# agent can read to find scattered helpers, unsafe casts, multi-class files, star imports, oversized
# files, missing CancellationException rethrows, hardcoded UI strings, and LiveData usage. It is a
# REPORT, not a gate — it prints findings + fixes; nothing is denied. Run it periodically.
#
# This is the SHAPE of a stack-specific scan; replace the placeholders below with your own:
#   <PROJECT_DIR>            your project root
#   <your/source/root>      the path under PROJECT_DIR holding your package tree
#   <your-helper-patterns>  the private-helper name fragments YOUR codebase tends to scatter
# Adapt the H*/G* checks to YOUR conventions; the SHAPE (one scan, parseable findings) is the point.

PROJECT_DIR="${PROJECT_DIR:-<PROJECT_DIR>}"
SRC="$PROJECT_DIR/<your/source/root>"
UTIL="$SRC/util"

echo "GOLDEN PRINCIPLES GC SCAN — $(date +%Y-%m-%d)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── H1: Shared util, not local helpers ───
echo "## H1: Duplicate/scattered helpers"
# Find private format/convert/parse/map/calculate functions that appear in multiple files.
# Adapt <your-helper-patterns> to the helper-name fragments your codebase tends to duplicate.
DUPES=""
for PATTERN in "<your-helper-patterns>" "calculate\|compute"; do
  HITS=$(grep -rn "private fun.*$PATTERN" "$SRC" --include="*.kt" 2>/dev/null | grep -v test/)
  COUNT=$(echo "$HITS" | grep -c "." 2>/dev/null) || COUNT=0
  if [ "$COUNT" -gt 1 ]; then
    DUPES="${DUPES}${HITS}\n"
  fi
done
# Also find functions that exist in non-util packages but could be shared
SCATTERED=$(grep -rn "^private fun format\|^private fun convert\|^private fun parse\|^private fun map" "$SRC" --include="*.kt" 2>/dev/null | grep -v "util/\|test/" | sed "s|$SRC/||")
if [ -n "$SCATTERED" ]; then
  echo "$SCATTERED" | head -10
  SCOUNT=$(echo "$SCATTERED" | wc -l)
  echo "→ $SCOUNT scattered helper(s) should be in util/"
  echo "  FIX: Move to util/ with public visibility. Delete private copies."
else
  echo "✓ No scattered helpers found"
fi
echo ""

# ─── H2: Typed data, not guessed shapes ───
echo "## H2: Unsafe casts"
UNSAFE=$(grep -rn " as [A-Z]" "$SRC" --include="*.kt" 2>/dev/null | grep -v "test/\| as?\|import\|getSystemService\|context\." | sed "s|$SRC/||")
if [ -n "$UNSAFE" ]; then
  echo "$UNSAFE"
  UCOUNT=$(echo "$UNSAFE" | grep -c "." || echo 0)
  echo "→ $UCOUNT unsafe cast(s)"
  echo "  FIX: Replace 'x as Type' with 'x as? Type ?: fallback' or use 'when (x) { is Type -> }'"
else
  echo "✓ No unsafe casts"
fi
echo ""

# ─── H3: One class per file ───
echo "## H3: Multi-class files"
MULTI=""
while IFS= read -r f; do
  COUNT=$(grep -c "^class \|^data class \|^object \|^interface \|^sealed \|^enum class \|^abstract class " "$f" 2>/dev/null) || COUNT=0
  if [ "$COUNT" -gt 2 ]; then
    REL="${f#$SRC/}"
    MULTI="${MULTI}  $REL: $COUNT declarations\n"
  fi
done < <(find "$SRC" -name "*.kt" -not -path "*/test/*")
if [ -n "$MULTI" ]; then
  echo -e "$MULTI"
  echo "  FIX: Extract additional classes to separate files named after each class"
else
  echo "✓ All files have ≤2 declarations"
fi
echo ""

# ─── H4: Star imports ───
echo "## H4: Star imports"
STARS=$(grep -rn "^import.*\.\*$" "$SRC" --include="*.kt" 2>/dev/null | grep -v test/ | sed "s|$SRC/||")
if [ -n "$STARS" ]; then
  echo "$STARS"
  echo "  FIX: Replace with explicit imports for each used class"
else
  echo "✓ No star imports"
fi
echo ""

# ─── H5: File size ───
echo "## H5: Oversized files"
OVER=""
while IFS= read -r f; do
  L=$(wc -l < "$f")
  REL="${f#$SRC/}"
  if [ "$L" -gt 800 ]; then
    OVER="${OVER}  BLOCK $REL: $L lines (>800)\n"
  elif [ "$L" -gt 500 ]; then
    OVER="${OVER}  WARN  $REL: $L lines (>500)\n"
  fi
done < <(find "$SRC" -name "*.kt" -not -path "*/test/*")
if [ -n "$OVER" ]; then
  echo -e "$OVER"
  echo "  FIX: Split Screen.kt → Screen.kt + Content.kt + Components.kt"
else
  echo "✓ All files under 500 lines"
fi
echo ""

# ─── G3: CancellationException ───
echo "## G3: Missing CancellationException rethrow"
CE_ISSUES=""
while IFS= read -r f; do
  if grep -q "suspend fun" "$f" 2>/dev/null; then
    if grep -q "catch.*Exception" "$f" 2>/dev/null; then
      if ! grep -q "CancellationException" "$f" 2>/dev/null; then
        REL="${f#$SRC/}"
        LINE=$(grep -n "catch.*Exception" "$f" | head -1 | cut -d: -f1)
        CE_ISSUES="${CE_ISSUES}  $REL:$LINE\n"
      fi
    fi
  fi
done < <(find "$SRC" -name "*.kt" -not -path "*/test/*")
if [ -n "$CE_ISSUES" ]; then
  echo -e "$CE_ISSUES"
  echo "  FIX: Add 'if (e is CancellationException) throw e' as first line of catch block"
else
  echo "✓ All suspend catches handle CancellationException"
fi
echo ""

# ─── G4: Hardcoded strings in Composables ───
echo "## G4: Hardcoded strings in UI"
HARDCODED=$(grep -rn 'text = "[A-Z]' "$SRC/ui/" --include="*.kt" 2>/dev/null | grep -v "test/\|preview\|Preview" | sed "s|$SRC/||" | head -10)
if [ -n "$HARDCODED" ]; then
  HCOUNT=$(grep -rn 'text = "[A-Z]' "$SRC/ui/" --include="*.kt" 2>/dev/null | grep -v "test/" | wc -l)
  echo "$HARDCODED"
  [ "$HCOUNT" -gt 10 ] && echo "  ... and $((HCOUNT-10)) more"
  echo "  FIX: Add string to res/values/strings.xml, use stringResource(R.string.key)"
else
  echo "✓ No hardcoded strings in Composables"
fi
echo ""

# ─── G5: LiveData check ───
echo "## G5: LiveData usage (should be StateFlow)"
LIVEDATA=$(grep -rn "LiveData\|MutableLiveData" "$SRC" --include="*.kt" 2>/dev/null | grep -v test/ | sed "s|$SRC/||")
if [ -n "$LIVEDATA" ]; then
  echo "$LIVEDATA"
  echo "  FIX: Replace MutableLiveData with MutableStateFlow, LiveData with StateFlow"
else
  echo "✓ No LiveData usage"
fi
echo ""

# ─── Summary ───
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SCAN COMPLETE"

# Count issues
TOTAL_BLOCK=0
TOTAL_WARN=0
[ -n "$CE_ISSUES" ] && TOTAL_BLOCK=$((TOTAL_BLOCK + $(echo -e "$CE_ISSUES" | grep -c "." || echo 0)))
[ -n "$STARS" ] && TOTAL_BLOCK=$((TOTAL_BLOCK + $(echo "$STARS" | grep -c "." || echo 0)))
[ -n "$LIVEDATA" ] && TOTAL_BLOCK=$((TOTAL_BLOCK + $(echo "$LIVEDATA" | grep -c "." || echo 0)))
[ -n "$UNSAFE" ] && TOTAL_WARN=$((TOTAL_WARN + $(echo "$UNSAFE" | grep -c "." || echo 0)))
[ -n "$SCATTERED" ] && TOTAL_WARN=$((TOTAL_WARN + $(echo "$SCATTERED" | grep -c "." || echo 0)))

echo "BLOCK: $TOTAL_BLOCK | WARN: $TOTAL_WARN"
