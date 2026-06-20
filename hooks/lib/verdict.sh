#!/usr/bin/env bash
# Shared review-verdict parser for the merge/ship gates (require-pr-green-before-merge.sh +
# require-review-before-ship.sh). 2026-06-04 (Wave 4). Replaces the bare `grep -qi APPROVED`
# fallback that wrongly PASSED a CHANGES-REQUESTED / "NOT APPROVED" block whenever the word
# "APPROVED" appeared anywhere (a prior round, or "NOT APPROVED"). See struggle-log + the
# require-pr-green-verdict-fallback.test.sh RED→GREEN spec.
#
# CONTRACT (locked with the user):
#  - Only EXPLICIT verdict candidate lines count — a `VERDICT:` / `Verdict:` / `TECHNICAL
#    VERDICT:` line, OR a `##`/`###` header — AND only if it carries a recognized token.
#    Ordinary prose ("round 1 was APPROVED") and per-finding lines ("- F-7 Verdict: PASS")
#    are NOT candidates.
#  - The LAST candidate line in the block wins (final round supersedes earlier rounds).
#  - A rejection token on a line WINS over APPROVED on the same line (kills the "NOT APPROVED"
#    / "...was APPROVED, now CHANGES-REQUESTED" substring trap).
#  - Header candidates are stripped of (...) parentheticals first, so a history note like
#    "APPROVED @sha (round 1 was CHANGES-REQUESTED — fixed)" classifies as APPROVED.
#  - Exact APPROVED is the ONLY allow state. APPROVED_WITH_NOTES / APPROVED_WITH_CHANGES and
#    any unrecognized token → AMBIGUOUS → fail CLOSED with a clear message.

# Token regexes (case-insensitive via grep -i). Rejection set is checked BEFORE APPROVED.
_VERDICT_REJECT_RE='(NOT[[:space:]]+APPROVED|CHANGES[_[:space:]-]+(REQUESTED|REQUIRED)|NEEDS[_[:space:]-]+(FIXES|REVISION)|\bWONTFIX\b|\bREJECTED\b)'
_VERDICT_AMBIG_RE='APPROVED[_[:space:]-]+WITH'   # APPROVED_WITH_NOTES / APPROVED WITH CHANGES …
_VERDICT_APPROVE_RE='\bAPPROVED\b'

# decide_verdict: read a review block on stdin, echo one of:
#   APPROVED | DENY:<token> | AMBIGUOUS:<why> | NONE
decide_verdict() {
  local block line cline last="NONE" reason=""
  block=$(cat)
  while IFS= read -r line; do
    # candidate ONLY if it is a verdict-marker line OR a markdown header
    local is_marker=0 is_header=0
    printf '%s' "$line" | grep -qiE 'verdict[*[:space:]]*[:：]' && is_marker=1
    printf '%s' "$line" | grep -qE '^[[:space:]]*#{2,}[[:space:]]' && is_header=1
    [ "$is_marker" = 1 ] || [ "$is_header" = 1 ] || continue
    # headers: drop (...) history parentheticals before classifying
    if [ "$is_header" = 1 ]; then
      cline=$(printf '%s' "$line" | sed -E 's/\([^)]*\)//g')
    else
      cline="$line"
    fi
    # classify — rejection FIRST, then ambiguous-approved, then exact APPROVED.
    # A marker/header line with NO recognized token (e.g. "Verdict: PASS") is NOT a candidate.
    if printf '%s' "$cline" | grep -qiE "$_VERDICT_REJECT_RE"; then
      last="DENY"; reason=$(printf '%s' "$cline" | grep -oiE "$_VERDICT_REJECT_RE" | head -1)
    elif printf '%s' "$cline" | grep -qiE "$_VERDICT_AMBIG_RE"; then
      last="AMBIGUOUS"; reason="APPROVED_WITH_* qualifier (not an unambiguous approval)"
    elif printf '%s' "$cline" | grep -qiE "$_VERDICT_APPROVE_RE"; then
      last="APPROVED"; reason=""
    fi
    # else: marker/header but unrecognized token → leave `last` unchanged (skip)
  done <<< "$block"
  case "$last" in
    APPROVED)  echo "APPROVED" ;;
    DENY)      echo "DENY:${reason}" ;;
    AMBIGUOUS) echo "AMBIGUOUS:${reason}" ;;
    *)         echo "NONE" ;;
  esac
}

# classify_jsonl_verdict <token> -> allow | deny | fallthrough
# For the .claude/reviews/index.jsonl structured fast-path. Only exact APPROVED allows;
# the deny-token zoo (incl. CHANGES_REQUESTED with -ED, NEEDS-FIXES hyphen, WONTFIX) denies;
# APPROVED_WITH_* / unknown fall through to the markdown parser (conservative).
classify_jsonl_verdict() {
  case "$(printf '%s' "${1:-}" | tr 'a-z' 'A-Z')" in
    APPROVED) echo allow ;;
    CHANGES_REQUESTED|CHANGES-REQUESTED|CHANGES_REQUIRED|CHANGES-REQUIRED|NEEDS_FIXES|NEEDS-FIXES|NEEDS_REVISION|NEEDS-REVISION|WONTFIX|REJECTED) echo deny ;;
    *) echo fallthrough ;;
  esac
}

# ship_decision <is_merge:0|1> <has_pr:0|1> <local_eq_prhead:0|1> -> review | allow
# Routes `git push` vs `gh pr merge` for require-review-before-ship.sh. Fixes the R2-push
# SELF-LOCK (2026-06-04): the review+HEAD-SHA gate must NOT block an UPDATE push (new local
# commits not yet on the PR) — the reviewer can't review a HEAD that was never pushed
# (chicken-and-egg). The "no unreviewed code into main" duty lives on the MERGE path, which
# always review-gates. Mirrors require-tests-before-ship.sh:96-98 (local==PR-head ⇒ enforce).
#   - has_pr=0           → allow  (no PR yet: first push opens it / merge-no-PR is require-pr-green's call)
#   - merge (+ PR)       → review (always gate the merge)
#   - push + local!=head → allow  (R2/update push: pushing new commits for CI + reviewer to see)
#   - push + local==head → review (head already on the PR; safe to apply the verdict gate)
ship_decision() {
  local is_merge="${1:-0}" has_pr="${2:-0}" local_eq="${3:-1}"
  [ "$has_pr" = 1 ] || { echo allow; return; }
  [ "$is_merge" = 1 ] && { echo review; return; }
  [ "$local_eq" = 1 ] && { echo review; return; }
  echo allow
}
