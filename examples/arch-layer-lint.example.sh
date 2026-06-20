#!/usr/bin/env bash
# EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json.
#
# An architecture-layer lint (Kotlin / Compose stack pattern): enforces forward-only dependencies
# between layers — a lower layer must never import a higher one (entity → dao → repository →
# worker → viewmodel → ui). Cross-cutting packages (di/, util/, shared models) may be imported by
# any layer. It can be sourced by a PostToolUse hook (see enforce-layer-deps.example.sh) or run
# standalone: `bash arch-layer-lint.example.sh [file]`.
#
# Layer order (forward-only):
#   L0: entity (data/local/entity)
#   L1: dao (data/local/dao)
#   L2: repository (data/repository, data/*)
#   L3: worker (worker/)
#   L4: viewmodel (ui/*/ViewModel)
#   L5: ui (ui/*Screen, ui/*Composable)
#
# This is the SHAPE of a stack-specific gate; replace the placeholders below with your own:
#   <PROJECT_DIR>            your project root
#   <your/source/root>       the path under PROJECT_DIR holding your package tree
#   <your.app.package>       your root package (e.g. com.example.app), as it appears in `import`s
# Also edit the `data/*` service-layer glob list in the case below to YOUR data-service package dirs.
# Adapt the layer names / package paths to YOUR module structure; the forward-only RULE is the point.

PROJECT_DIR="${PROJECT_DIR:-<PROJECT_DIR>}"
SRC="$PROJECT_DIR/<your/source/root>"
PKG="<your.app.package>"
VIOLATIONS=0
WARNINGS=0

check_file() {
  local FILE="$1"
  local REL="${FILE#$SRC/}"

  # Determine this file's layer
  local LAYER=""
  case "$REL" in
    data/local/entity/*) LAYER="L0:entity" ;;
    data/local/dao/*) LAYER="L1:dao" ;;
    data/local/model/*) LAYER="cross:model" ;;
    data/repository/*) LAYER="L2:repository" ;;
    # The data/* service subdirs that count as the L2 service layer. Replace this glob list
    # with YOUR own data-service package dirs (these are illustrative defaults).
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

  # Skip cross-cutting and unknown
  [[ "$LAYER" == cross:* ]] && return
  [[ "$LAYER" == "unknown" ]] && return

  # Extract app-internal imports
  local IMPORTS=$(grep "^import ${PKG}\." "$FILE" 2>/dev/null | sed "s/import ${PKG}\.//" || true)
  [ -z "$IMPORTS" ] && return

  while IFS= read -r imp; do
    local VIOLATION=""

    case "$LAYER" in
      L0:entity)
        # Entity can only import: other entities, model, util
        if echo "$imp" | grep -qE "^(data\.local\.dao|data\.repository|ui\.|worker\.)"; then
          VIOLATION="[LAYER] $REL imports $imp — entity cannot depend on dao/repo/ui/worker"
        fi
        ;;
      L1:dao)
        # DAO can import: entity, model, util — NOT repo/vm/ui
        if echo "$imp" | grep -qE "^(data\.repository|ui\.|worker\.)"; then
          VIOLATION="[LAYER] $REL imports $imp — dao cannot depend on repo/ui/worker"
        fi
        ;;
      L2:repository|L2:service)
        # Repository/service can import: entity, dao, model, network, other data/, util — NOT vm/ui
        if echo "$imp" | grep -qE "^ui\."; then
          VIOLATION="[LAYER] $REL imports $imp — data layer cannot depend on ui"
        fi
        ;;
      L3:worker)
        # Worker can import: entity, dao, repo, network, util — NOT vm/ui
        if echo "$imp" | grep -qE "^ui\."; then
          VIOLATION="[LAYER] $REL imports $imp — worker cannot depend on ui"
        fi
        ;;
      L4:viewmodel)
        # ViewModel can import: entity, dao, repo, util, model — NOT composables
        # Allow importing from own ui package's state classes
        if echo "$imp" | grep -qE "^ui\." && echo "$imp" | grep -qiE "Screen$|Content$|Composable"; then
          VIOLATION="[LAYER] $REL imports $imp — viewmodel cannot depend on composables"
        fi
        ;;
      L5:ui)
        # UI composable: check cross-screen imports
        local THIS_SCREEN=$(echo "$REL" | cut -d/ -f2)
        local IMP_SCREEN=$(echo "$imp" | sed 's/^ui\.\([^.]*\)\..*/\1/')
        if echo "$imp" | grep -q "^ui\." && [ "$IMP_SCREEN" != "$THIS_SCREEN" ]; then
          # Allow imports from shared packages
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

# If called with a specific file, check only that file
if [ -n "$1" ] && [ -f "$1" ]; then
  check_file "$1"
  exit $VIOLATIONS
fi

# Otherwise, scan all source files
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
