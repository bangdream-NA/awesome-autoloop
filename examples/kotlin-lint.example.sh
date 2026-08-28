#!/usr/bin/env bash

PROJECT_DIR="${PROJECT_DIR:-<PROJECT_DIR>}"
SRC="$PROJECT_DIR/<your/source/root>"
FILE="$1"
ERRORS=0
WARNS=0

emit_error() { ERRORS=$((ERRORS + 1)); echo "  BLOCK: $1"; echo "  FIX: $2"; }
emit_warn()  { WARNS=$((WARNS + 1));   echo "  WARN: $1"; echo "  FIX: $2"; }

[ -z "$FILE" ] && exit 0
[ -f "$FILE" ] || exit 0

REL="${FILE#"$SRC"/}"
LINES=$(wc -l < "$FILE")
BASENAME=$(basename "$FILE" .kt)


if echo "$REL" | grep -q "data/local/dao/"; then
  if ! grep -q "^interface.*Dao" "$FILE" 2>/dev/null; then
    emit_error "$REL: DAO must be an interface named *Dao" \
      "Change 'class ${BASENAME}' to 'interface ${BASENAME}' and ensure name ends with 'Dao'"
  fi
fi

if echo "$REL" | grep -q "data/repository/\|data/auth/"; then
  if grep -q "^class.*Repository[^I]" "$FILE" 2>/dev/null; then
    if ! grep -q "RepositoryImpl" "$FILE" 2>/dev/null; then
      emit_warn "$REL: Repository implementation should be named *RepositoryImpl" \
        "Rename class to ${BASENAME}Impl and extract interface ${BASENAME}"
    fi
  fi
fi

if echo "$REL" | grep -q "ui/" && grep -q "@HiltViewModel" "$FILE" 2>/dev/null; then
  if ! echo "$BASENAME" | grep -q "ViewModel$"; then
    emit_error "$REL: HiltViewModel class must end with 'ViewModel'" \
      "Rename class to ${BASENAME}ViewModel"
  fi
fi

if echo "$REL" | grep -q "data/local/entity/"; then
  if grep -q "^class " "$FILE" 2>/dev/null && ! grep -q "^data class " "$FILE" 2>/dev/null; then
    emit_warn "$REL: Entity should be a data class" \
      "Change 'class' to 'data class' for immutability and equals/hashCode"
  fi
fi

if echo "$REL" | grep -q "worker/"; then
  if grep -q "CoroutineWorker\|Worker()" "$FILE" 2>/dev/null && ! echo "$BASENAME" | grep -q "Worker$"; then
    emit_error "$REL: Worker class must end with 'Worker'" \
      "Rename to ${BASENAME}Worker"
  fi
fi


if grep -qn "println(\|System\.out\." "$FILE" 2>/dev/null; then
  LINENO=$(grep -n "println(\|System\.out\." "$FILE" | head -1 | cut -d: -f1)
  emit_error "$REL:$LINENO: Use android.util.Log, not println/System.out" \
    "Replace with Log.d(TAG, \"message\") where TAG = companion object { private const val TAG = \"${BASENAME}\" }"
fi

if grep -qn 'Log\.[diewv]("[A-Z]' "$FILE" 2>/dev/null; then
  LINENO=$(grep -n 'Log\.[diewv]("[A-Z]' "$FILE" | head -1 | cut -d: -f1)
  emit_warn "$REL:$LINENO: Log tag should use TAG constant, not inline string" \
    "Add 'companion object { private const val TAG = \"${BASENAME}\" }' and replace Log.x(\"...\") with Log.x(TAG, ...)"
fi

if grep -qn "Log\.v(" "$FILE" 2>/dev/null; then
  LINENO=$(grep -n "Log\.v(" "$FILE" | head -1 | cut -d: -f1)
  emit_warn "$REL:$LINENO: Log.v() is too verbose for production" \
    "Replace with Log.d() or wrap in 'if (BuildConfig.DEBUG) Log.v(...)'"
fi


if [ "$LINES" -gt 800 ]; then
  emit_error "$REL: $LINES lines (max 800)" \
    "Extract composables/functions to separate files. For Screens: split into *Screen.kt (scaffold) + *Content.kt (body) + *Components.kt (reusable parts)"
elif [ "$LINES" -gt 500 ]; then
  emit_warn "$REL: $LINES lines (approaching 800 limit)" \
    "Consider extracting large composables or helper functions to keep under 500 lines"
fi

LONG_FUN=$(awk '/^[[:space:]]*(fun |override fun )/{name=$0; count=0} {count++} count>50 && /^[[:space:]]*\}/{print NR": "name" ("count" lines)"; count=0}' "$FILE" 2>/dev/null | head -3)
if [ -n "$LONG_FUN" ]; then
  emit_warn "$REL: Function over 50 lines detected" \
    "Extract helper functions. For Composables: split into smaller @Composable functions. For logic: extract to private methods or utility functions."
fi


if grep -q "suspend fun" "$FILE" 2>/dev/null; then
  if grep -q "catch.*Exception" "$FILE" 2>/dev/null; then
    if ! grep -q "CancellationException" "$FILE" 2>/dev/null; then
      LINENO=$(grep -n "catch.*Exception" "$FILE" | head -1 | cut -d: -f1)
      emit_error "$REL:$LINENO: Suspend function catches Exception without rethrowing CancellationException" \
        "Add 'if (e is CancellationException) throw e' as the first line of the catch block, or use 'catch (e: IOException)' for a narrower catch"
    fi
  fi
fi

if ! echo "$REL" | grep -qi "test"; then
  BANGBANG=$(grep -c '!!' "$FILE" 2>/dev/null) || BANGBANG=0
  if [ "$BANGBANG" -gt 0 ]; then
    LINENO=$(grep -n '!!' "$FILE" | head -1 | cut -d: -f1)
    emit_warn "$REL:$LINENO: $BANGBANG force unwrap(s) found — risky in production" \
      "Replace '!!' with '?: return', '?: throw IllegalStateException(\"reason\")', or 'requireNotNull(value) { \"reason\" }'"
  fi
fi

if echo "$REL" | grep -q "ui/" && grep -q "@Composable" "$FILE" 2>/dev/null; then
  if grep -qn 'text = "[A-Z]' "$FILE" 2>/dev/null; then
    LINENO=$(grep -n 'text = "[A-Z]' "$FILE" | head -1 | cut -d: -f1)
    emit_warn "$REL:$LINENO: Hardcoded string in Composable — use stringResource(R.string.x)" \
      "Add string to res/values/strings.xml, then use stringResource(R.string.your_key)"
  fi
fi

if grep -qn "^import.*\.\*$" "$FILE" 2>/dev/null; then
  LINENO=$(grep -n "^import.*\.\*$" "$FILE" | head -1 | cut -d: -f1)
  emit_error "$REL:$LINENO: Star import detected — agents need explicit imports to trace dependencies" \
    "Replace 'import package.*' with explicit imports for each used class"
fi

PUBLIC_CLASSES=$(grep -c "^class \|^data class \|^object \|^interface \|^sealed \|^enum \|^abstract class " "$FILE" 2>/dev/null) || PUBLIC_CLASSES=0
if [ "$PUBLIC_CLASSES" -gt 2 ]; then
  emit_warn "$REL: $PUBLIC_CLASSES top-level declarations (prefer 1 per file)" \
    "Extract additional classes to separate files named after each class"
fi


if ! echo "$REL" | grep -q "util/"; then
  SCATTERED_FUNS=$(grep -n "^private fun format\|^private fun convert\|^private fun parse\|^private fun map[A-Z]\|^private fun calculate" "$FILE" 2>/dev/null | head -1)
  if [ -n "$SCATTERED_FUNS" ]; then
    SLINE=$(echo "$SCATTERED_FUNS" | cut -d: -f1)
    SFUN=$(echo "$SCATTERED_FUNS" | sed 's/.*private fun //' | sed 's/(.*//')
    emit_warn "$REL:$SLINE: Private helper '$SFUN' should be in util/ for reuse" \
      "Move to util/ (e.g. util/TimeFormatting.kt or util/Mappers.kt), make public, import from here"
  fi
fi


if grep -qn " as [A-Z]" "$FILE" 2>/dev/null; then
  UNSAFE_LINE=$(grep -n " as [A-Z]" "$FILE" 2>/dev/null | grep -v "getSystemService\|context\.\| as? " | head -1)
  if [ -n "$UNSAFE_LINE" ]; then
    ULINE=$(echo "$UNSAFE_LINE" | cut -d: -f1)
    emit_warn "$REL:$ULINE: Unsafe cast — validate boundary or use typed SDK" \
      "Replace 'x as Type' with 'when (x) { is Type -> ... }' or 'x as? Type ?: fallback'. Never guess data shapes."
  fi
fi


if echo "$REL" | grep -q "dao/"; then
  if grep -qn '@Query.*+\|@Query.*\$' "$FILE" 2>/dev/null; then
    LINENO=$(grep -n '@Query.*+\|@Query.*\$' "$FILE" | head -1 | cut -d: -f1)
    emit_error "$REL:$LINENO: SQL string concatenation in @Query — SQL injection risk" \
      "Use Room's :paramName binding syntax: @Query(\"SELECT * FROM table WHERE col = :paramName\")"
    fi
fi

if echo "$BASENAME" | grep -qi "<your-local-only-worker>"; then
  if grep -q "NetworkType.CONNECTED\|NetworkType.NOT_ROAMING" "$FILE" 2>/dev/null; then
    emit_error "$REL: a local-only worker should not require a network constraint" \
      "Remove .setRequiredNetworkType(NetworkType.CONNECTED) — this job reads local data only"
  fi
fi

if [ "$ERRORS" -gt 0 ] || [ "$WARNS" -gt 0 ]; then
  echo "  ───"
  echo "  ${ERRORS} error(s), ${WARNS} warning(s) in $REL"
fi

exit 0
