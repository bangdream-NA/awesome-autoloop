#!/usr/bin/env bash
# PreToolUse hook on Bash: BLOCK git push / gh pr merge if no recent code review
# Enforces: code-reviewer MUST approve before shipping.
# Convention (document for your project): reviews are appended to
# .claude/code-reviews.md with a `## PR #<N>` header per PR and a final
# `VERDICT: APPROVED @<HEAD-sha>` line. Requires `gh` for PR lookup.

set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0

source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/verdict.sh"

if ! aal_have_node; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: awesome-autoloop requires node on PATH to evaluate this gate, and node was not found. Install node >=18, or disable the plugin / remove this gate group from AAL_GATES. (Fail-closed: a security gate that can't evaluate must not silently allow.)"}}
JSON
  exit 0
fi

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command)

# Only gate `git push` and `gh pr merge`. Do NOT gate `git commit` —
# commits happen BEFORE PR opens, so reviews don't yet exist. Blocking commit
# would prevent the developer from forming the PR in the first place.
if ! echo "$COMMAND" | grep -qE '\b(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+merge)\b'; then
  exit 0
fi

# Locate the project directory — review log lives in the MAIN repo, never inside a
# worktree. From a worktree, `--show-toplevel` returns the worktree path; we need
# `--git-common-dir` which always points at the main repo's .git directory.
#
# Resolution order:
#   1. CLAUDE_PROJECT_DIR env (set by Claude Code at session start)
#   2. main repo from --git-common-dir (works from worktrees)
#   3. git toplevel (only correct when not in a worktree)
#   4. cwd as last resort
if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
  PROJECT_DIR="$CLAUDE_PROJECT_DIR"
else
  COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [ -n "$COMMON_DIR" ]; then
    # --git-common-dir may be relative (e.g. ".git") — make absolute first
    case "$COMMON_DIR" in
      /*|[A-Za-z]:*) ;;  # already absolute
      *) COMMON_DIR="$(pwd)/$COMMON_DIR" ;;
    esac
    case "$COMMON_DIR" in
      */.git) PROJECT_DIR="${COMMON_DIR%/.git}" ;;
      *) PROJECT_DIR=$(dirname "$COMMON_DIR") ;;
    esac
  else
    PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  fi
fi
# Honor a leading `cd <dir> &&` prefix so `cd <project> && git push ...` from ANY cwd
# resolves the project (consistency with require-pr-green-before-merge.sh).
LEADING_CD_DIR=$(aal_extract_cd_target "$COMMAND")
if [ -n "$LEADING_CD_DIR" ] && [ -d "$LEADING_CD_DIR" ]; then PROJECT_DIR="$LEADING_CD_DIR"; fi
# cd INTO the resolved repo before any git command below. The hook is spawned with the parent
# shell's start cwd (=HOME for home-launched sessions), NOT the cwd implied by a leading
# `cd <project> && gh pr merge`. Without this, `git branch`/`git rev-parse HEAD` return empty →
# the DEGRADED tail path (no PR-block bound, no SHA bind).
cd "$PROJECT_DIR" 2>/dev/null || true
REVIEW_FILE="$PROJECT_DIR/.claude/code-reviews.md"

# Missing review file → treat as an EMPTY review log and fall through to the branch/PR logic
# below (main/master exemption + no-PR allow + degraded tail). This makes the missing-file case
# consistent with ship_decision(has_pr=0)=allow — file-exists+no-PR and file-missing+no-PR both
# allow. The downstream "no review entry for THIS PR" deny still fires if a PR DOES exist but has
# no review block — so the merge-with-PR path stays gated. (No early exit; $REVIEW_FILE may not
# exist — the later reads are guarded.)

# HEAD SHA binding: require APPROVED to reference the current HEAD short-SHA.
# Reviewers conventionally include "@ <sha>" or "HEAD: <sha>" in their verdict block.
# If the latest review entry doesn't mention current HEAD, treat as stale — block.
#
# Degraded fallback: if not in a git repo / no HEAD, fall back to the tail check.

# Skip on main/master — direct main commits aren't gated by reviews
# (they're either merge commits from PRs already reviewed, or covered by other hooks).
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
case "$CURRENT_BRANCH" in
  main|master|trunk) exit 0 ;;
esac

HEAD_SHORT=$(git rev-parse --short=7 HEAD 2>/dev/null || echo "")

if [ -z "$HEAD_SHORT" ]; then
  # Not in a git repo / detached / etc. — degraded: parse the tail (no PR-block bounding / SHA bind)
  # Missing review file in this degraded state → no PR context, nothing to gate → ALLOW.
  [ -f "$REVIEW_FILE" ] || exit 0
  if [ "$(tail -40 "$REVIEW_FILE" | decide_verdict)" != "APPROVED" ]; then
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Latest code review is not APPROVED. Run /review and get APPROVED verdict before committing. (Degraded mode — no HEAD SHA bind because not in a git repo.)"}}
EOF
    exit 0
  fi
  exit 0
fi

# Find the PR for the current branch via gh. Required so we look at THIS PR's
# review block — not "global latest review" which mis-fires when multiple PRs
# are in flight (the latest review may be for a different wave's PR).
# If no PR exists yet (first push opens PR), allow — review will come after.
PR_NUM=""
if command -v gh >/dev/null 2>&1; then
  PR_NUM=$(gh pr view --json number --jq .number 2>/dev/null || echo "")
fi

# Route push vs merge (lib/verdict.sh ship_decision) — an UPDATE push (new local commits not
# yet on the PR) is ALLOWED so the reviewer can SEE them; the reviewer cannot review a HEAD
# that was never pushed. Only the MERGE path (and a same-head push) is review-gated.
IS_MERGE=0; echo "$COMMAND" | grep -qE '\bgh[[:space:]]+pr[[:space:]]+merge\b' && IS_MERGE=1
HAS_PR=0; [ -n "$PR_NUM" ] && HAS_PR=1
LOCAL_EQ=1   # default: treat as same-head (review-gate) unless we can PROVE local HEAD is ahead
if [ "$IS_MERGE" = 0 ] && [ "$HAS_PR" = 1 ]; then
  PR_HEAD=$(gh pr view --json headRefOid --jq .headRefOid 2>/dev/null || echo "")
  LOCAL_FULL=$(git rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$PR_HEAD" ] && [ -n "$LOCAL_FULL" ] && [ "$PR_HEAD" != "$LOCAL_FULL" ]; then LOCAL_EQ=0; fi
fi
[ "$(ship_decision "$IS_MERGE" "$HAS_PR" "$LOCAL_EQ")" = "allow" ] && exit 0
# else "review" → fall through to the review-block + verdict + HEAD-SHA gate below

# --- Structured verdict fast-path: .claude/reviews/index.jsonl (exact pr + HEAD-SHA). Mirrors
#     require-pr-green-before-merge.sh — a matching record gives a precise verdict (no markdown
#     substring footgun); no match / APPROVED_WITH_* → fall THROUGH to the markdown parser, so this
#     is only ever stricter-or-equal, never looser. ---
JSONL_FILE="$PROJECT_DIR/.claude/reviews/index.jsonl"
if [ -f "$JSONL_FILE" ]; then
  JV=$(cat "$JSONL_FILE" | node -e "
    let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{let v='';
      for(const line of d.split('\n')){ if(!line.trim()) continue;
        try{ const r=JSON.parse(line);
          if(String(r.pr)==='$PR_NUM' && typeof r.head_sha==='string' && r.head_sha.indexOf('$HEAD_SHORT')===0){ v=String(r.verdict||''); }
        }catch(_){}
      } console.log(v); });" 2>/dev/null)
  case "$(classify_jsonl_verdict "$JV")" in
    allow) exit 0 ;;
    deny)  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #${PR_NUM} structured review verdict is ${JV} (.claude/reviews/index.jsonl)."}}
EOF
           exit 0 ;;
    *)     : ;;  # no match / APPROVED_WITH_* → fall through to the markdown parser
  esac
fi

# Markdown fallback: per-verdict file reviews/pr<N>-r<round>.md (LATEST round) → monolith legacy.
# Each per-verdict file holds ONE review, so a whole-file read replaces the monolith's ^## PR #N
# block-bounding. `sort -V` orders r1 < r2 < r10 correctly. The verdict + HEAD-SHA checks below
# run identically on whichever file resolves (AC-R9 stricter-or-equal).
PV=$(ls "$PROJECT_DIR/.claude/reviews/pr${PR_NUM}-r"*.md 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$PV" ] && [ -f "$PV" ]; then
  LATEST_BLOCK=$(cat "$PV")
else
  [ -f "$REVIEW_FILE" ] || { cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #$PR_NUM has no review entry — no .claude/reviews/pr${PR_NUM}-r*.md and no .claude/code-reviews.md. Dispatch code-reviewer Mode B before pushing."}}
EOF
    exit 0; }
  LAST_HEADER_LINE=$(grep -nE "^## PR #${PR_NUM}\b" "$REVIEW_FILE" | tail -1 | cut -d: -f1 || echo "")
  if [ -z "$LAST_HEADER_LINE" ]; then
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #$PR_NUM has no review entry in .claude/reviews/pr${PR_NUM}-r*.md or .claude/code-reviews.md. Dispatch code-reviewer Mode B before pushing."}}
EOF
    exit 0
  fi
  LATEST_BLOCK=$(sed -n "${LAST_HEADER_LINE},\$p" "$REVIEW_FILE")
fi

# Verdict via shared parser (lib/verdict.sh): last explicit candidate wins, rejection beats
# same-line APPROVED, only EXACT APPROVED allows. Replaces a bare `grep -qi APPROVED`.
RVERDICT=$(printf '%s' "$LATEST_BLOCK" | decide_verdict)
if [ "$RVERDICT" != "APPROVED" ]; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: PR #${PR_NUM} latest review verdict is not a clean APPROVED (${RVERDICT}). Address findings + dispatch reviewer R2 — only an explicit 'VERDICT: APPROVED' allows push."}}
EOF
  exit 0
fi

# Check HEAD SHA reference — must appear with a (HEAD|head|@) prefix marker so
# we don't false-positive on the base-main commit mention (e.g. "off main 814c5169").
# Accepts: "HEAD 1c21291", "HEAD: 1c21291", "@1c21291", "@ 1c21291", "head: <sha>",
# AND markdown-bold/backtick wrappers "**HEAD**: <sha>" / "HEAD `<sha>`".
if ! echo "$LATEST_BLOCK" | grep -qiE "(HEAD|@)[*\`[:space:]]*:?[*\`[:space:]]*${HEAD_SHORT}"; then
  cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Latest review is APPROVED but doesn't reference current HEAD ($HEAD_SHORT) via 'HEAD: <sha>' or '@ <sha>' marker. Likely the review is for a prior commit. Dispatch reviewer R2 on current HEAD, or have the reviewer add 'HEAD: $HEAD_SHORT' to the latest review block."}}
EOF
  exit 0
fi

exit 0
