#!/usr/bin/env bash
# require-full-read-before-hook-edit — editing a gate from a grep hit changes a predicate whose
# other arms you have not seen. The gate denies a write to an existing hook file unless the same
# session Read that file through, and it counts only the Read tool, only within four hours.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-full-read-before-hook-edit.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/.claude/hooks/__tests__" "$AAL_TMP/.claude/knowledge"
: > "$AAL_TMP/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N"
export CLAUDE_CONFIG_DIR="$AAL_TMP_N/.claude"
trap 'rm -rf "$AAL_TMP"' EXIT

HOOKS="$AAL_TMP_N/.claude/hooks"
# A ten-line target, so a partial read can be expressed as an offset/limit that stops short of the
# end and a full read can be expressed as two pages that meet.
seq 1 10 > "$AAL_TMP/.claude/hooks/some-gate.mjs"
printf 'x\n'    > "$AAL_TMP/.claude/struggle-log.md"
printf 'x\n'    > "$AAL_TMP/.claude/hooks/__tests__/some-gate.test.mjs"
printf 'x\n'    > "$AAL_TMP/.claude/knowledge/note.md"
printf 'x\n'    > "$AAL_TMP/plain.mjs"

# 🔴 The transcripts are WRITTEN here, and that is not decoration: if the payload names a path that
# does not exist, the library falls back to scanning the operator's OWN transcript directory and
# answers from whatever they happen to have read today. Every arm below would then depend on the
# machine it runs on. Timestamps are relative to now for the same reason the freshness window is
# four hours — a hardcoded stamp ages out of the window and quietly turns an allow arm into a deny.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(aal_date_rel '-5 hours' +%Y-%m-%dT%H:%M:%SZ)"
mktranscript() { # $1 = out path, $2 = json for input, $3 = timestamp
  node -e 'const fs=require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({timestamp:process.argv[3],message:{content:[{type:"tool_use",name:"Read",input:JSON.parse(process.argv[2])}]}})+"\n");' \
    -- "$1" "$2" "$3"
}
T_NONE="$AAL_TMP/t-none.jsonl";  printf '%s\n' '{"message":{"content":[]}}' > "$T_NONE"
T_FULL="$AAL_TMP/t-full.jsonl";  mktranscript "$T_FULL"  "{\"file_path\":\"$HOOKS/some-gate.mjs\"}" "$NOW"
T_STALE="$AAL_TMP/t-stale.jsonl"; mktranscript "$T_STALE" "{\"file_path\":\"$HOOKS/some-gate.mjs\"}" "$OLD"
T_PART="$AAL_TMP/t-part.jsonl";  mktranscript "$T_PART"  "{\"file_path\":\"$HOOKS/some-gate.mjs\",\"offset\":1,\"limit\":4}" "$NOW"
T_OTHER="$AAL_TMP/t-other.jsonl"; mktranscript "$T_OTHER" "{\"file_path\":\"$HOOKS/another-gate.mjs\"}" "$NOW"
# Two consecutive pages that between them reach the end: the gate stitches them, which is what makes
# reading a long file possible at all.
node -e 'const fs=require("fs");const mk=(i,ts)=>JSON.stringify({timestamp:ts,message:{content:[{type:"tool_use",name:"Read",input:i}]}});
fs.writeFileSync(process.argv[1], mk({file_path:process.argv[2],offset:1,limit:5},process.argv[3])+"\n"+mk({file_path:process.argv[2],offset:6,limit:5},process.argv[3])+"\n");' \
  -- "$AAL_TMP/t-pages.jsonl" "$HOOKS/some-gate.mjs" "$NOW"
T_PAGES="$AAL_TMP/t-pages.jsonl"
# -----------------------------------------------------------------------------------------------

ed() { # $1 = file_path, $2 = transcript
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",transcript_path:process.argv[2],tool_input:{file_path:process.argv[1],old_string:"1",new_string:"2"}}))' -- "$1" "$2"
}

# --- DENY: changing a hook nobody read -------------------------------------------------------------
assert_deny "no Read at all"          "$(ed "$HOOKS/some-gate.mjs" "$T_NONE")"  'Read it before you change it'
assert_deny "a Read of a DIFFERENT hook" "$(ed "$HOOKS/some-gate.mjs" "$T_OTHER")" 'Read it before you change it'
assert_deny "a partial read"          "$(ed "$HOOKS/some-gate.mjs" "$T_PART")"  'Read it before you change it'
# Four hours is the window. Without this arm, dropping the freshness check would read green — and
# "I read it yesterday" is exactly the state the gate exists to catch.
assert_deny "a read older than the window" "$(ed "$HOOKS/some-gate.mjs" "$T_STALE")" 'Read it before you change it'

# --- ALLOW: the file was actually read through ------------------------------------------------------
assert_allow "a whole-file Read"      "$(ed "$HOOKS/some-gate.mjs" "$T_FULL")"
assert_allow "two pages that meet"    "$(ed "$HOOKS/some-gate.mjs" "$T_PAGES")"

# --- ALLOW: files this gate does not guard -----------------------------------------------------------
# Each of these is a different exclusion in the predicate, and each needs its own arm: collapsing any
# one of them would deny work the gate was never meant to touch, and the suite would still be green.
assert_allow "a NEW hook that does not exist yet" "$(ed "$HOOKS/brand-new-gate.mjs" "$T_NONE")"
assert_allow "a fixture under __tests__"          "$(ed "$HOOKS/__tests__/some-gate.test.mjs" "$T_NONE")"
assert_allow "a knowledge note"                   "$(ed "$AAL_TMP_N/.claude/knowledge/note.md" "$T_NONE")"
# The ledger exclusion is anchored at the ROOT of the config directory, not at any depth: a file
# of the same name inside hooks/ is a hook, and measuring that was the difference between this arm
# passing for the right reason and passing for the wrong one.
assert_allow "an append-only ledger at the config root" "$(ed "$AAL_TMP_N/.claude/struggle-log.md" "$T_NONE")"
assert_allow "a file outside the config dir"      "$(ed "$AAL_TMP_N/plain.mjs" "$T_NONE")"

# --- ALLOW: tools that are not a write ----------------------------------------------------------------
assert_allow "a Read of the hook itself" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Read",transcript_path:process.argv[2],tool_input:{file_path:process.argv[1]}}))' -- "$HOOKS/some-gate.mjs" "$T_NONE")"

summary
