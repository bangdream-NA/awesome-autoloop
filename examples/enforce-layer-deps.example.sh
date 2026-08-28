#!/usr/bin/env bash

INPUT=$(cat) || true
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null) || true

[ -z "$FILE_PATH" ] && exit 0
echo "$FILE_PATH" | grep -qi '\.kt$' || exit 0
echo "$FILE_PATH" | grep -qi '<your-project-marker>' || exit 0

OUTPUT=$(PROJECT_DIR="<PROJECT_DIR>" bash ~/.claude/hooks/arch-layer-lint.sh "$FILE_PATH" 2>/dev/null) || true

if [ -n "$OUTPUT" ]; then
  echo "ARCH LAYER VIOLATION in $(basename "$FILE_PATH"):"
  echo "$OUTPUT"
fi

exit 0
