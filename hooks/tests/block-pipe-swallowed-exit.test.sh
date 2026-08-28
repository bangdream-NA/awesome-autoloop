#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-pipe-swallowed-exit.sh

# 🔴 The gate no-ops outside an autoloop project, so without a pinned one the four deny arms below
# reported EXPECTED-DENY-BUT-ALLOWED on every fresh clone while passing on the author's machine —
# where a worktree's git-common-dir happens to answer with a checkout that does carry the marker.
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT
aal_pin_new_project "$AAL_TMP/proj" > /dev/null

assert_deny "mv piped to head then && success-echo (instance #5)" \
  '{"tool_name":"Bash","tool_input":{"command":"mv /z/a /z/b 2>&1 | head -1 && echo OK-moved || echo failed"}}' \
  'PIPE-SWALLOWED-EXIT'
assert_deny "push piped to tail then && open PR (instance #6)" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin br 2>&1 | tail -1 && gh pr create -t x -b y"}}' \
  'PIPE-SWALLOWED-EXIT'
assert_deny "script piped to tail; echo EXIT=\$? (instance #7)" \
  '{"tool_name":"Bash","tool_input":{"command":"bash setup.sh 2>&1 | tail -20; echo EXIT=$?"}}' \
  'PIPE-SWALLOWED-EXIT'

assert_allow "escape token PIPE-EXIT-OK" \
  '{"tool_name":"Bash","tool_input":{"command":"ls /tmp | head -3 && echo listed # PIPE-EXIT-OK"}}'
assert_allow "heredoc containing the pattern as DATA text (incidental, §8)" \
  '{"tool_name":"Bash","tool_input":{"command":"cat > /tmp/doc.md <<'"'"'EOF'"'"'\nbad: cmd | tail -1 && echo done\nEOF"}}'
assert_allow "pipefail present — pipeline exit reflects failing stage" \
  '{"tool_name":"Bash","tool_input":{"command":"set -o pipefail; git push 2>&1 | tail -1 && echo pushed"}}'

assert_allow "result-state judgment with pipe inside \$() — the CORRECT pattern" \
  '{"tool_name":"Bash","tool_input":{"command":"[ $(grep -c foo file.txt | wc -l) -gt 0 ] && echo has-foo"}}'
assert_allow "plain pipe to head, no success judgment" \
  '{"tool_name":"Bash","tool_input":{"command":"gh run list --limit 30 2>&1 | head -20"}}'
assert_allow "&& before the pipe, nothing judged after truncator" \
  '{"tool_name":"Bash","tool_input":{"command":"cd /z/x && git log --oneline | head -5"}}'
assert_allow "empty command" \
  '{"tool_name":"Bash","tool_input":{}}'

NEWLINE_PAD=$(printf 'mv a b 2>&1 | head -1 && echo "moved"\n'; for _ in $(seq 1 2600); do printf '# %s\n' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done)
assert_deny "long MULTI-LINE danger shape (>200KB) must still deny — gate's own SIGPIPE regression" \
  "$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$NEWLINE_PAD" | python -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")" \
  'PIPE-SWALLOWED-EXIT'

summary
