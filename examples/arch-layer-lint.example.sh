#!/usr/bin/env bash

PROJECT_DIR="${PROJECT_DIR:-<PROJECT_DIR>}"
SRC="$PROJECT_DIR/<your/source/root>"
PKG="<your.app.package>"
VIOLATIONS=0
WARNINGS=0

check_file() {
  local FILE="$1"
  local REL="${FILE#"$SRC"/}"

  local LAYER=""
  case "$REL" in
    data/local/entity/*) LAYER="L0:entity" ;;
    data/local/dao/*) LAYER="L1:dao" ;;
    data/local/model/*) LAYER="cross:model" ;;
    data/repository/*) LAYER="L2:repository" ;;
    data/auth/*|data/network/*|data/export/*|data/preferences/*) LAYER="L2:service" ;;
    worker/*) LAYER="L3:worker" ;;
    di/*) LAYER="cross:di" ;;
    util/*) LAYER="cross:util" ;;
    ui/theme/*|ui/components/*|ui/navigation/*) LAYER="cross:ui-shared" ;;
    ui/*)
      if echo "$REL" | grep -qi "ViewModel"; then
        LAYER="L4:viewmodel"
      else
        LAYER="L5:ui"
      fi
      ;;
    *) LAYER="unknown" ;;
  esac

  [[ "$LAYER" == cross:* ]] && return
  [[ "$LAYER" == "unknown" ]] && return

  local IMPORTS
  IMPORTS=$(grep "^import ${PKG}\." "$FILE" 2>/dev/null | sed "s/import ${PKG}\.//" || true)
  [ -z "$IMPORTS" ] && return

  while IFS= read -r imp; do
    local VIOLATION=""

    case "$LAYER" in
      L0:entity)
        if echo "$imp" | grep -qE "^(data\.local\.dao|data\.repository|ui\.|worker\.)"; then
          VIOLATION="[LAYER] $REL imports $imp — entity cannot depend on dao/repo/ui/worker"
        fi
        ;;
      L1:dao)
        if echo "$imp" | grep -qE "^(data\.repository|ui\.|worker\.)"; then
          VIOLATION="[LAYER] $REL imports $imp — dao cannot depend on repo/ui/worker"
        fi
        ;;
      L2:repository|L2:service)
        if echo "$imp" | grep -qE "^ui\."; then
          VIOLATION="[LAYER] $REL imports $imp — data layer cannot depend on ui"
        fi
        ;;
      L3:worker)
        if echo "$imp" | grep -qE "^ui\."; then
          VIOLATION="[LAYER] $REL imports $imp — worker cannot depend on ui"
        fi
        ;;
      L4:viewmodel)
        if echo "$imp" | grep -qE "^ui\." && echo "$imp" | grep -qiE "Screen$|Content$|Composable"; then
          VIOLATION="[LAYER] $REL imports $imp — viewmodel cannot depend on composables"
        fi
        ;;
      L5:ui)
        local THIS_SCREEN IMP_SCREEN
        THIS_SCREEN=$(echo "$REL" | cut -d/ -f2)
        IMP_SCREEN=$(echo "$imp" | sed 's/^ui\.\([^.]*\)\..*/\1/')
        if echo "$imp" | grep -q "^ui\." && [ "$IMP_SCREEN" != "$THIS_SCREEN" ]; then
          if ! echo "$imp" | grep -qE "^ui\.(theme|components|navigation)\."; then
            WARNINGS=$((WARNINGS + 1))
            echo "  [CROSS-SCREEN] $REL imports ui.$IMP_SCREEN — should use ui/components/ instead"
          fi
        fi
        ;;
    esac

    if [ -n "$VIOLATION" ]; then
      VIOLATIONS=$((VIOLATIONS + 1))
      echo "  $VIOLATION"
    fi
  done <<< "$IMPORTS"
}

if [ -n "$1" ] && [ -f "$1" ]; then
  check_file "$1"
  exit $VIOLATIONS
fi

echo "ARCH LAYER LINT — $(date +%Y-%m-%d)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

find "$SRC" -name "*.kt" -type f | while read -r f; do
  check_file "$f"
done

echo ""
echo "Violations: $VIOLATIONS | Warnings: $WARNINGS"
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "STATUS: FAIL"
  exit 1
else
  echo "STATUS: PASS"
  exit 0
fi
