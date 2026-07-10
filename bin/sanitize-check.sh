#!/usr/bin/env bash
# sanitize-check.sh — the public-flip sanitization gate (AC-5).
# Scans the SHIPPED tree for secret / identity / project-leak literals and EMITS A REPORT
# (files scanned + any hits + the docs-excluded note). The author reads this report before
# flipping the repo public. Exit 0 on PASS (0 hits), 1 on FAIL.
#
# Run from the repo root: bash bin/sanitize-check.sh
set -uo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 2

# Scope: exactly these paths (the artifact that flips public). EXCLUDES docs/** (the specs
# legitimately name what they scrub and never ship public).
SCAN_PATHS=".claude-plugin .github hooks agents skills templates examples bin README.md LICENSE"

# The OS username is resolved at runtime (never hardcoded here, so the doc carries no identity).
OS_USER="${USERNAME:-${USER:-}}"

# Forbidden-pattern set (case-insensitive ERE). Built from the project literals that must
# never ship. ALLOWED (NOT a hit): awesome-autoloop / awesome, the public GitHub handle
# suhang56, the harness paths ~/.claude/teams + ~/.claude/agents, the plugin env vars
# ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA}/${CLAUDE_PROJECT_DIR}. The framework's config
# env all uses the AAL_* prefix (not flagged); only the <REDACTED> / <REDACTED> secret+roster
# var NAMES are flagged, so a <REDACTED> secret/roster leak can never ship.
PATTERNS=(
  '<REDACTED>'
  'bang.?dream'
  '<REDACTED>'
  'flight[ -]?log'
  '<REDACTED>'
  '<REDACTED>-app-1'
  'api\.<REDACTED>'
  '\.<REDACTED>\.fans'
  '/etc/<REDACTED>'
  '<REDACTED>'
  '<REDACTED>'
  '@<REDACTED>-fans'
  '<REDACTED>'
  '<REDACTED>'
  'api\.<REDACTED>'
  '<REDACTED>'
  '<REDACTED>'
  '<REDACTED>'
  '<REDACTED>'
  '@gmail\.com'
  '<REDACTED>'
)
# Add the OS username as a pattern only if it is set and not a generic word.
if [ -n "$OS_USER" ] && [ "${#OS_USER}" -ge 3 ]; then
  PATTERNS+=("$(printf '%s' "$OS_USER" | sed 's/[].[^$*\/]/\\&/g')")
fi

TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPORT="$ROOT/sanitization-report.txt"

# SELF-EXCLUDE: this script's own PATTERNS array necessarily contains the forbidden literals
# (they are what it searches FOR) — they are the scanner's logic, NOT shipped content to vet.
# A scanner doesn't scan itself; excluding it is correct, not a loophole.
SELF="${BASH_SOURCE[0]}"
SELF_BASE=$(basename "$SELF")

# SINGLE-PASS scan. The old form (files×patterns nested loop, ~1,771 grep spawns) was pathologically
# slow on Windows/Git-Bash MSYS (timed out at 120s). This is ONE recursive grep over the whole scan
# set, with docs/** and this script excluded by grep's own flags — no per-file / per-pattern spawning.
PATFILE=$(mktemp)
printf '%s\n' ${PATTERNS[@]+"${PATTERNS[@]}"} > "$PATFILE"

# Files-scanned count: ONE find over all scan paths (the per-path find-IN-A-LOOP was part of the spew).
# SC2086: SCAN_PATHS is a space-separated path LIST that MUST split into separate find args.
# shellcheck disable=SC2086
FILES_SCANNED=$(find $SCAN_PATHS -type f -not -path '*/docs/*' 2>/dev/null \
  | grep -cv "/$SELF_BASE\$" | tr -d ' ')

# The scan: ONE grep -rniE, docs + self excluded by grep's flags (SCAN_PATHS may include bare files
# like README.md — grep -r accepts a mix of files + dirs). Each non-empty line is a hit path:lineno:text.
# SC2086: SCAN_PATHS must word-split into separate grep -r roots.
# shellcheck disable=SC2086
HITLINES=$(grep -rniE -f "$PATFILE" --exclude-dir=docs --exclude="$SELF_BASE" \
  $SCAN_PATHS 2>/dev/null || true)
rm -f "$PATFILE"

HIT_COUNT=0
[ -n "$HITLINES" ] && HIT_COUNT=$(printf '%s\n' "$HITLINES" | grep -c .)

# Build the report.
{
  echo "Awesome Autoloop — sanitization report ($TS)"
  echo "Scanned paths: $SCAN_PATHS"
  echo "Excluded:      docs/** (design specs — not part of the public artifact)"
  echo "Files scanned: $FILES_SCANNED"
  echo "Patterns checked: ${#PATTERNS[@]} (secret / identity / project-leak / machine-path classes)"
  echo ""
  if [ "$HIT_COUNT" -eq 0 ]; then
    echo "HITS: <none>"
    echo ""
    echo "RESULT: PASS (0 hits)"
  else
    echo "HITS:"
    printf '%s\n' "$HITLINES" | grep . | while IFS= read -r h; do echo "  $h"; done
    echo ""
    echo "RESULT: FAIL ($HIT_COUNT hits)"
  fi
} | tee "$REPORT"

[ "$HIT_COUNT" -eq 0 ]
