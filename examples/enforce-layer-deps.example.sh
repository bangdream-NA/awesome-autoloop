#!/usr/bin/env bash
# EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json.
#
# A layer-dependency gate (Kotlin / Compose stack pattern): a non-blocking PostToolUse warning that
# runs an architecture-layer lint on a just-edited source file and surfaces any forward-only-layer
# violation (e.g. a data-layer file importing the ui layer). It pairs with the `arch-layer-lint`
# example (which holds the actual layer rules) — this hook is just the PostToolUse trigger wrapper.
#
# This is the SHAPE of a stack-specific gate; replace the placeholders below with your own:
#   <PROJECT_DIR>            your project root (passed to the lint as PROJECT_DIR)
#   <your-project-marker>    a path substring identifying YOUR source files (so it only lints yours)
#   <your-source-ext>        your source extension (here .kt for Kotlin)
#
# Wire it on PostToolUse with a Write|Edit|MultiEdit matcher in your settings.json. Adapt the path
# to wherever you keep your copy of arch-layer-lint.example.sh (drop the `.example`).

INPUT=$(cat) || true
FILE_PATH=$(echo "$INPUT" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' 2>/dev/null) || true

[ -z "$FILE_PATH" ] && exit 0
echo "$FILE_PATH" | grep -qi '\.kt$' || exit 0
echo "$FILE_PATH" | grep -qi '<your-project-marker>' || exit 0

# Run the layer lint on just this file (adapt the path to your copy of arch-layer-lint).
OUTPUT=$(PROJECT_DIR="<PROJECT_DIR>" bash ~/.claude/hooks/arch-layer-lint.sh "$FILE_PATH" 2>/dev/null) || true

if [ -n "$OUTPUT" ]; then
  echo "ARCH LAYER VIOLATION in $(basename "$FILE_PATH"):"
  echo "$OUTPUT"
fi

exit 0
