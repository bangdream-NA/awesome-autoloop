#!/usr/bin/env bash

INPUT=$(cat) || true
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null) || true

if [ -n "$FILE_PATH" ] && echo "$FILE_PATH" | grep -qi '\.kt$'; then
  echo "Kotlin file modified ($FILE_PATH). Remember: run build verification before marking task complete."
fi

exit 0
