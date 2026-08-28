#!/usr/bin/env bash
# Fixtures for require-review-before-ship.sh — gates `git push` / `gh pr merge` on
# an APPROVED review bound to the current HEAD SHA. Full deny paths need a live PR +
# review file, so we cover (a) ROUTING (commit & non-ship commands pass, since
# commits precede the PR) and (b) the HEAD-SHA marker regex — which MUST be
# bold/backtick-tolerant to match require-pr-green (reviewers write `**HEAD**: <sha>`).

source "$(dirname "$0")/_lib.sh"
source "$(dirname "$0")/../lib/verdict.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-review-before-ship.sh

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
AAL_PROJ=/tmp/aal-fx-require-review-before-ship
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------


# --- ALLOW: git commit is intentionally NOT gated (review comes after PR opens) ---
assert_allow "git commit"  '{"command":"git commit -m \"feat: x\""}'
assert_allow "git status"  '{"command":"git status"}'
assert_allow "pnpm test"   '{"command":"pnpm -r test"}'
assert_allow "gh pr view"  '{"command":"gh pr view 5"}'

# --- Unit: HEAD-SHA marker regex (hook line ~127). Asserts the bold/backtick-tolerant
#     form (aligned with require-pr-green) so `**HEAD**: <sha>` PASSES the push gate. ---
SHA=1c21291
HS_RE="(HEAD|@)[*\`[:space:]]*:?[*\`[:space:]]*${SHA}"
re_test() { local desc="$1" text="$2" expect="$3";
  if echo "$text" | grep -qiE "$HS_RE"; then [ "$expect" = hit ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILURES+=("UNEXPECTED-HIT: $desc"); };
  else [ "$expect" = miss ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-HIT: $desc"); }; fi; }

re_test "HEAD: <sha>"        "HEAD: $SHA"        hit
re_test "**HEAD**: <sha>"    "**HEAD**: $SHA"    hit
re_test "@ <sha>"            "@ $SHA"            hit
re_test "bare base 'off main <sha>'" "off main $SHA" miss

# --- Unit: leading `cd <dir> &&` project-dir resolution (Wave-4 fix 2026-06-04). EXACT replica
#     of the hook's LEADING_CD_DIR sed; fixes fail-closed-from-HOME ("No code review found")
#     when cwd=HOME + CLAUDE_PROJECT_DIR unset. Mirrors require-pr-green-before-merge.sh:25. ---
extract_cd() {
  echo "$1" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&;]+)"?[[:space:]]*(&&|;|$).*/\1/p' \
    | head -1 | tr -d '"' | sed 's/[[:space:]]*$//'
}
cdt() { local desc="$1" cmd="$2" exp="$3" got; got=$(extract_cd "$cmd");
  if [ "$got" = "$exp" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("cd-resolve $desc: want '$exp' got '$got'"); fi; }

cdt "Windows Z:/ form"        'cd Z:/repo && git push origin feat/x' 'Z:/repo'
cdt "MSYS /z/ form"           'cd /tmp/aal-fx-require-review-before-ship && gh pr merge 5 --squash' '/tmp/aal-fx-require-review-before-ship'
cdt "quoted path w/ space"    'cd "Z:/path with space/repo" && git push'     'Z:/path with space/repo'
cdt "leading whitespace"      '  cd /tmp/aal-fx-require-review-before-ship && git push'             '/tmp/aal-fx-require-review-before-ship'
cdt "no cd prefix → empty"    'git push origin feat/x'                       ''
cdt "cd not at start → empty" 'echo hi && cd /tmp/aal-fx-require-review-before-ship && git push'    ''

# --- Unit: ship_decision push-vs-merge routing (R2-push self-lock fix 2026-06-04).
#     review = apply the APPROVED+HEAD-SHA gate; allow = let it through (update push / no PR). ---
sd() { local desc="$1" exp="$2" got; got=$(ship_decision "$3" "$4" "$5");
  if [ "$got" = "$exp" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("ship_decision $desc (m=$3 pr=$4 eq=$5): want '$exp' got '$got'"); fi; }

#    desc                                              expect  is_merge has_pr local_eq
sd "1) first push, no PR → allow"                      allow      0       0      1
sd "2) R2 push, PR, local HEAD ahead → allow"          allow      0       1      0
sd "   push, PR, local == PR head → review"            review     0       1      1
sd "3/4) merge, PR → review (verdict gate owns deny)"  review     1       1      1
sd "   merge, PR, local ahead → still review"          review     1       1      0
sd "   merge, no PR → allow (require-pr-green's call)"  allow      1       0      1

# --- Integration: leading `cd <repo>` must make git resolve INSIDE the repo, not the hook's
#     start cwd (=HOME for home-launched sessions). 2026-06-05 fix (the missing `cd "$PROJECT_DIR"`).
#     RED→GREEN witness: the review file holds a REJECTION. Pre-fix → no cd → git empty →
#     HEAD_SHORT="" → degraded `tail -40` reads the REJECTION → DENY. Post-fix → cd into the
#     main-branch repo → skip-on-main (line ~79) → ALLOW (never reaches the degraded/verdict path).
# 🔴 Scratch lives in a temp dir the fixture creates and removes — NEVER under the operator's
# config root. Every path below is handed to the tool explicitly, so nothing requires it to sit
# there; with CLAUDE_CONFIG_DIR unset (the default for an adopter) the old form dropped files
# into a real ~/.claude, and on a machine where that directory is read-only source it is worse
# than untidy.
RT="$(mktemp -d)/rrbs-it"
rm -rf "$RT"; mkdir -p "$RT/repo/.claude"
( git -C "$RT/repo" init -q -b main 2>/dev/null || { git -C "$RT/repo" init -q; git -C "$RT/repo" symbolic-ref HEAD refs/heads/main 2>/dev/null; } )
git -C "$RT/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
printf '## PR #5 review\nVERDICT: CHANGES_REQUESTED — needs work\n' > "$RT/repo/.claude/code-reviews.md"
IT_IN=$(printf '{"command":"cd %s/repo && gh pr merge 5 --squash"}' "$RT")
IT_OUT=$(cd "$RT" && env -u CLAUDE_PROJECT_DIR bash "$HOOK" <<<"$IT_IN" 2>&1)
if [ -z "$(printf '%s' "$IT_OUT" | tr -d '[:space:]')" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("integration leading-cd→skip-on-main: expected ALLOW, got: $(printf '%s' "$IT_OUT"|head -c140)"); fi
rm -rf "$RT"

summary
