#!/usr/bin/env bash
# Tests for block-backlog-status-drift.mjs — single-status BACKLOG.md format gate (fail-closed).
# Node hook (not bash), so we roll our own node-based runner (cf. backlog-format.test.sh; _lib.sh's
# assert_* shell out via `bash "$HOOK"` which can't run a .mjs).
#
# REGRESSION FOCUS (2026-06-06): a BARE-badge done header — `### ✅` / `### DONE` / `### MERGED`
# with NO [..] bracket — must be DENIED on the ACTIVE board. The old matcher only inspected
# `^###\s+\[` (bracketed) headers, so bare-badge done-markers slipped past the whitelist check and
# 5 such ✅ cards accumulated on the active board (invisible to this gate AND to backlog-reconcile,
# which keys on the same bracket anchor). Archive file + plain log-appends must still ALLOW.
set -u
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/"block-backlog-status-drift.mjs"

# --- portable activation + repo context ------------------------------------------
# Two things every mounted gate needs before it will judge anything, and both are absent in a
# bare temp dir:
#   1. an AUTOLOOP-MANAGED project — lib/activation.sh accepts `.claude/.autoloop` |
#      `.claude/BACKLOG.md` | `.claude/code-reviews.md` | a marked `.claude/CLAUDE.md`. Without it
#      the gate exits 0 in silence and every deny arm reads EXPECTED-DENY-BUT-ALLOWED with EMPTY
#      output — the fixture then measures the guard instead of the gate.
#   2. a resolvable GIT REPOSITORY — the commit/merge gates refuse fail-closed otherwise, and that
#      refusal lands on the ALLOW arms as "the git repository cannot be resolved".
# The path is a literal so single-quoted JSON payloads below can name it; it is created fresh and
# removed on EXIT, and the resolution order prefers a payload `cd` hint that actually exists.
# ⚠️ Being a literal, it is also NOT unique per run: two copies of THIS fixture running at the
# same time share the directory and the first one's EXIT trap removes it under the second.
# run-all.sh is sequential and each CI job runs one OS, so that does not arise there — but do
# not parallelise a single fixture against itself.
AAL_PROJ=/tmp/aal-fx-block-backlog-status-drift
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------

PASS=0; FAIL=0; FAILURES=()

is_deny() { printf '%s' "$1" | node "$HOOK" 2>&1 | grep -q '"permissionDecision":"deny"'; }
deny()  { if is_deny "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-DENY: $1"); fi; }
allow() { if is_deny "$2"; then FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-ALLOW-BUT-DENIED: $1"); else PASS=$((PASS+1)); fi; }

# --- the blind-spot regressions: bare badge, NO brackets, on the active board → DENY ---
deny  "bare ✅ badge on active"   '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","new_string":"### ✅ R-foo · DONE+LIVE #1\n- x"}}'
deny  "bare DONE word on active"  '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","new_string":"### DONE R-foo"}}'
deny  "bare MERGED on active"     '{"tool_name":"Write","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","content":"### MERGED R-foo"}}'
deny  "MultiEdit bare ✅"         '{"tool_name":"MultiEdit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","edits":[{"new_string":"### ✅ R-bar"}]}}'

# --- bracketed non-whitelist still denied (pre-existing behavior preserved) ---
deny  "[DONE] bracket on active"  '{"tool_name":"Write","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","content":"### [DONE] R-foo"}}'
deny  "invented [MERGED-DoD]"     '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","new_string":"### [MERGED-DoD-PENDING] R-foo"}}'

# --- legit edits must ALLOW ---
allow "whitelisted [QUEUED]"      '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","new_string":"### [QUEUED] R-foo · P3\n- aliases: r-foo"}}'
allow "whitelisted [USER-GATED]"  '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","new_string":"### [USER-GATED] R-foo"}}'
allow "log-only append no header" '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG.md","new_string":"  - 2026-06-06 · note · team-lead · did a thing"}}'
# --- (B) BACKLOG-archive DoD-gate (USER LOCK 2026-06-07): an archived card must POSITIVELY prove DoD
#     met OR be a no-DoD-needed category. The blind-spot the OLD blocklist missed: a card that says
#     NOTHING about DoD used to pass. Verdict is read from the HEADER line (a stale "DoD pending" log
#     line in the body must NOT override a header that now reads DoD-VERIFIED — the #514 false-positive). ---
deny  "archive NO-DoD (the hole)"   '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · MERGED #9 @abc1234 — fixed the thing"}}'
deny  "archive bare ### ✅ · DONE (no proof)" '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-foo · DONE"}}'
deny  "archive header DoD pending"  '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · MERGED #9 — DoD pending, republish owed"}}'
allow "archive DoD-VERIFIED"        '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · MERGED #9 @abc1234 — DoD-VERIFIED LIVE"}}'
allow "archive DoD-met"             '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · MERGED #9 — DoD-met(P3 latent, live-verify N/A)"}}'
allow "archive LIVE-confirmed"      '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · DONE — USER LIVE-confirmed"}}'
allow "archive TRIAGE-COMPLETE"     '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · TRIAGE-COMPLETE all spawned waves merged"}}'
allow "archive WONTFIX (no DoD)"    '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### 🗑️ WONTFIX R-x · USER-DROPPED"}}'
allow "archive PHANTOM (no DoD)"    '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · ARCHIVED PHANTOM (already fixed on HEAD)"}}'
allow "archive header VERIFIED + body stale pending" '{"tool_name":"Edit","tool_input":{"file_path":"Z:/repo/.claude/BACKLOG-archive.md","new_string":"### ✅ R-x · MERGED #9 — DoD-VERIFIED LIVE\n- log: earlier DoD pending(LEAD) pipeline run still to verify"}}'

name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
