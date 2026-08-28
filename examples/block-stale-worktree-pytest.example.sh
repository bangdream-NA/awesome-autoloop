#!/usr/bin/env bash
INPUT=$(cat)
CMD=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

echo "$CMD" | grep -Eq '(^|[;&|]|&&|\|\||-c[[:space:]]+["'"'"'])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((python[0-9.]*|uv[[:space:]]+run|poetry[[:space:]]+run)[[:space:]]+(-m[[:space:]]+)?)?pytest\b' || exit 0
echo "$CMD" | grep -Eqi '<your-worktree-marker>' || exit 0
echo "$CMD" | grep -Eqi '<your-test-root>' || exit 0
echo "$CMD" | grep -Eq 'PYTHONPATH=src' && exit 0
echo "$CMD" | grep -q 'ALLOW_STALE_PYTEST' && exit 0

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (stale-worktree test): pytest in a worktree WITHOUT PYTHONPATH=src. The .venv editable-install points at MAIN src, so this silently tests STALE main code (every RED/GREEN + RED-on-revert is then INVALID). Re-run as:  cd <worktree>/<your-test-root> && find . -name __pycache__ -type d -exec rm -rf {} + ; PYTHONUTF8=1 PYTHONPATH=src python -m pytest ...  and assert  python -c \"import <your.module.path> as m; print(m.__file__)\"  resolves UNDER the worktree (not the main checkout). Deliberate override: prefix the command with ALLOW_STALE_PYTEST=1."}}
EOF
exit 0
