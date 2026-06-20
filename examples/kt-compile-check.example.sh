#!/usr/bin/env bash
# EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json.
#
# A build-reminder gate (Kotlin / Compose stack pattern): a non-blocking PostToolUse reminder that
# fires after a source file is edited, nudging the agent to verify the build/compile before marking
# a task complete. It injects context (stdout), it does NOT deny — a compile-check is too slow to run
# on every edit, but the reminder keeps "it type-checks" from being assumed.
#
# This is the SHAPE of a stack-specific gate; adapt it to your stack:
#   change the `\.kt$` extension match to your source extension(s)
#   change the reminder text to name your build/compile command
#
# Wire it on PostToolUse with a Write|Edit|MultiEdit matcher in your settings.json.

INPUT=$(cat) || true
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null) || true

if [ -n "$FILE_PATH" ] && echo "$FILE_PATH" | grep -qi '\.kt$'; then
  echo "Kotlin file modified ($FILE_PATH). Remember: run build verification before marking task complete."
fi

exit 0
