#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"

TMP=$(mktemp -d)
mkdir -p "$TMP/proj/.claude"
BOARD_WIN="$(cd "$TMP/proj" && pwd -W 2>/dev/null || pwd)"
STATE="$TMP/proj/.claude/.reconcile-state.json"

mk_state() { printf '{"ts":%s,"dirty":%s,"ghOk":true,"repo":"o/r","driftCount":%s,"verifyCount":0,"report":"⚠️ test drift"}' "$(date +%s)000" "$1" "$2" > "$STATE"; }

HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-autoloop-on-board-drift.mjs
run_mjs() { echo "$1" | node "$HOOK" 2>&1 || true; }

mk_state true 3
P_DIRTY="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"planner\",\"name\":\"planner-x\",\"prompt\":\"board: $BOARD_WIN/.claude/BACKLOG.md do the wave\"}}"
OUT=$(run_mjs "$P_DIRTY")
if echo "$OUT" | grep -q '"permissionDecision":"deny"' && echo "$OUT" | grep -q 'DRIFT LOCK'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("dirty board dispatch should DENY: $(echo "$OUT"|head -c 120)"); fi

mk_state false 0
OUT=$(run_mjs "$P_DIRTY")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("clean board dispatch should ALLOW"); else PASS=$((PASS+1)); fi

mk_state true 3
P_EXPLORE="{\"tool_name\":\"Agent\",\"tool_input\":{\"subagent_type\":\"Explore\",\"name\":\"probe\",\"prompt\":\"board: $BOARD_WIN/.claude/BACKLOG.md look around\"}}"
OUT=$(run_mjs "$P_EXPLORE")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("non-pipeline role should ALLOW even on dirty board"); else PASS=$((PASS+1)); fi

P_NOBOARD='{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-y","prompt":"no board path in this brief"}}'
OUT=$(run_mjs "$P_NOBOARD")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("no board path should ALLOW (fail-open)"); else PASS=$((PASS+1)); fi

# 🔴 The load-bearing arms for the POSIX widening. Arm 1 above is its must-RED half, and it is the
# one that failed on ubuntu and macOS: the matcher accepted only `X:/…` and the Git-Bash `/c/…`, so
# a genuine POSIX board resolved to nothing and the gate exited 0 in silence. A widened matcher
# fails by matching TOO MUCH and a must-red arm is structurally blind to that, so both over-fire
# shapes are named: a board mentioned RELATIVELY, and a URL whose slashes look absolute.
P_RELBOARD='{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-r","prompt":"read .claude/BACKLOG.md first, then start the wave"}}'
OUT=$(run_mjs "$P_RELBOARD")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("a RELATIVE .claude/BACKLOG.md is not a board path and must ALLOW"); else PASS=$((PASS+1)); fi

P_URLBOARD='{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-u","prompt":"the convention is documented at https://example.invalid/repo/.claude/BACKLOG.md"}}'
OUT=$(run_mjs "$P_URLBOARD")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("a URL is not a board path and must ALLOW"); else PASS=$((PASS+1)); fi

rm -f "$STATE"
OUT=$(run_mjs "$P_DIRTY")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("missing state should ALLOW (fail-open)"); else PASS=$((PASS+1)); fi

mk_state true 3
touch -t 202601010000 "$STATE" 2>/dev/null || true
OUT=$(run_mjs "$P_DIRTY")
if echo "$OUT" | grep -q '"permissionDecision":"deny"'; then FAIL=$((FAIL+1)); FAILURES+=("stale state should ALLOW"); else PASS=$((PASS+1)); fi

HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-merge-on-board-drift.sh
mk_state true 4
MERGE_CMD_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $BOARD_WIN && gh pr merge 999 --squash\"}}"
assert_deny "merge on dirty board" "$MERGE_CMD_JSON" 'DRIFT LOCK'
mk_state false 0
assert_allow "merge on clean board" "$MERGE_CMD_JSON"
assert_allow "non-merge command ignores state" "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd $BOARD_WIN && git status\"}}"
mk_state true 4
assert_allow "merge without leading cd (unresolvable project) fail-open" '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 999 --squash"}}'

rm -rf "$TMP"
summary
