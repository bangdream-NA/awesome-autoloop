#!/usr/bin/env bash
# EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json.
#
# A stale-worktree test gate (Python / editable-install topology): if you run your test suite
# from a git WORKTREE while the project's virtualenv holds an EDITABLE install (`pip install -e`)
# pointing at the MAIN checkout's src/, the worktree's pytest silently imports MAIN code — so every
# RED/GREEN (and every "RED-on-revert" proof) tests the wrong tree and is meaningless. This gate
# DENIES a worktree test run that doesn't force `PYTHONPATH=src` to override the editable install.
#
# This is the SHAPE of a project-specific gate; replace the placeholders below with your own:
#   <your-worktree-marker>   a substring identifying your worktree dirs (e.g. a -wt suffix)
#   <your-test-root>         the package/dir whose tests this guards (e.g. backend, data-pipeline)
#   <your.module.path>       an import path that should resolve UNDER the worktree, for the assert
#
# Adapt the `pytest` token if your runner differs (unittest, nox, tox). jq is intentionally NOT
# required — this parses the payload with grep/sed so it runs on a minimal box.
INPUT=$(cat)
CMD=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

# only test-runner invocations
echo "$CMD" | grep -q 'pytest' || exit 0
# only when clearly targeting a worktree's guarded test root
echo "$CMD" | grep -Eqi '<your-worktree-marker>' || exit 0
echo "$CMD" | grep -Eqi '<your-test-root>' || exit 0
# the required form (allow)
echo "$CMD" | grep -Eq 'PYTHONPATH=src' && exit 0
# deliberate override marker (allow)
echo "$CMD" | grep -q 'ALLOW_STALE_PYTEST' && exit 0

cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (stale-worktree test): pytest in a worktree WITHOUT PYTHONPATH=src. The .venv editable-install points at MAIN src, so this silently tests STALE main code (every RED/GREEN + RED-on-revert is then INVALID). Re-run as:  cd <worktree>/<your-test-root> && find . -name __pycache__ -type d -exec rm -rf {} + ; PYTHONUTF8=1 PYTHONPATH=src python -m pytest ...  and assert  python -c \"import <your.module.path> as m; print(m.__file__)\"  resolves UNDER the worktree (not the main checkout)."}}
EOF
exit 0
