#!/usr/bin/env bash

source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-lead-writing-reviews.sh

# 🔴 The gate's first act is aal_is_autoloop_project; outside one it exits 0 = ALLOW, and all eight
# deny arms below then report EXPECTED-DENY-BUT-ALLOWED with EMPTY output while the gate is behaving
# exactly as README.md promises. The payload paths are synthetic (`Z:/my-project`), so the pinned
# project only has to exist — it is what switches the gate on, not what it judges.
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT
aal_pin_new_project "$AAL_TMP/proj" > /dev/null

assert_deny "Write index.jsonl"      '{"tool_name":"Write","tool_input":{"file_path":"Z:/my-project/.claude/reviews/index.jsonl"}}' 'reviewer'
assert_deny "Edit verdict md"        '{"tool_name":"Edit","tool_input":{"file_path":"Z:/my-project/.claude/reviews/pr908-r1.md"}}' 'reviewer'
assert_deny "Edit planrev md"        '{"tool_name":"Edit","tool_input":{"file_path":"Z:/my-project/.claude/reviews/handseed-planrev-r1.md"}}' 'reviewer'
assert_deny "windows backslash path" '{"tool_name":"Write","tool_input":{"file_path":"Z:\\my-project\\.claude\\reviews\\index.jsonl"}}' 'reviewer'

assert_deny "bash append >> jsonl"   '{"tool_name":"Bash","tool_input":{"command":"printf '"'"'{\"pr\":908}'"'"' >> Z:/my-project/.claude/reviews/index.jsonl"}}' 'reviewer'
assert_deny "bash tee into reviews"  '{"tool_name":"Bash","tool_input":{"command":"echo row | tee Z:/my-project/.claude/reviews/index.jsonl"}}' 'reviewer'
assert_deny "bash sed -i verdict md" '{"tool_name":"Bash","tool_input":{"command":"sed -i '"'"'s/APPROVED/X/'"'"' Z:/my-project/.claude/reviews/pr905-r1.md"}}' 'reviewer'  # PORTABLE-OK: the command is this arm's PAYLOAD -- a string the gate judges, never a command this fixture runs
assert_deny "bash cp into reviews"   '{"tool_name":"Bash","tool_input":{"command":"cp /tmp/fake.md Z:/my-project/.claude/reviews/pr908-r1.md"}}' 'reviewer'

assert_allow "grep jsonl (read)"     '{"tool_name":"Bash","tool_input":{"command":"grep -i pr908 Z:/my-project/.claude/reviews/index.jsonl"}}'
assert_allow "cat verdict (read)"    '{"tool_name":"Bash","tool_input":{"command":"cat Z:/my-project/.claude/reviews/pr908-r1.md"}}'
assert_allow "node read jsonl"       '{"tool_name":"Bash","tool_input":{"command":"node -e '"'"'console.log(require(\"fs\").readFileSync(\".claude/reviews/index.jsonl\",\"utf8\"))'"'"'"}}'
assert_allow "redirect reviews OUT"  '{"tool_name":"Bash","tool_input":{"command":"cat Z:/my-project/.claude/reviews/index.jsonl > /tmp/out.txt"}}'
assert_allow "heredoc to struggle-log mentioning reviews/" '{"tool_name":"Bash","tool_input":{"command":"cat >> Z:/my-project/.claude/struggle-log.md <<'"'"'EOF'"'"' the lead nearly did printf >> index.jsonl to fill in a .claude/reviews/ record for the reviewer EOF"}}'
assert_allow "write oplog prose w/ >> + reviews/ mention"  '{"tool_name":"Bash","tool_input":{"command":"printf '"'"'%s'"'"' '"'"'lead tried printf >> .claude/reviews/index.jsonl'"'"' >> Z:/my-project/.claude/autoloop-log-x.md"}}'

assert_allow "BACKLOG.md edit"       '{"tool_name":"Edit","tool_input":{"file_path":"Z:/my-project/.claude/BACKLOG.md"}}'
assert_allow "op-log write"          '{"tool_name":"Write","tool_input":{"file_path":"Z:/my-project/.claude/autoloop-log-x.md"}}'
assert_allow "app source (other hook)" '{"tool_name":"Write","tool_input":{"file_path":"Z:/my-project/apps/web/app/page.tsx"}}'
assert_allow "bash git status"       '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

summary
