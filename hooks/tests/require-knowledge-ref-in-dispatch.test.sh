#!/usr/bin/env bash
# require-knowledge-ref-in-dispatch — an agent works wherever the brief tells it to, and a brief that
# names no worktree sends it into the shared checkout. The failure is silent: the work lands, in the
# wrong tree, and the worktree that was supposed to hold it sits clean, which reads as "the agent
# died". The gate denies a pipeline dispatch whose brief does not name a concrete worktree path.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-knowledge-ref-in-dispatch.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"
# The live-holder limb reads the agent roster; pinned at an empty directory so this fixture answers
# from its own state rather than from whichever agents happen to be running on the operator's machine.
export TEAM_ROSTER_DIR="$AAL_TMP/teams"
mkdir -p "$TEAM_ROSTER_DIR"
# -----------------------------------------------------------------------------------------------

a() { # $1 = prompt, $2 = subagent_type (default developer), $3 = agent name (default dev-x)
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:process.argv[2]||"developer",name:process.argv[3]||"dev-x",prompt:process.argv[1]}}))' \
    -- "$1" "${2:-developer}" "${3:-dev-x}"
}

# The gate's namesake limb wants a pointer to the knowledge base in every pipeline brief, and it runs
# AFTER the worktree limb. Every allow arm below therefore carries one — without it the arm would be
# denied by a different limb than the one it is about, and the label would be a lie.
KB='Read the knowledge base first: ~/.claude/knowledge/INDEX.md then ~/.claude/knowledge/developer/.'

# --- DENY: the three shapes of "no worktree named" -------------------------------------------------
assert_deny "neither the word nor a path" \
  "$(a "Implement the venue rendering, then report back.")" 'has to NAME THE WORKTREE'
# A path on its own is a reference, not an instruction: briefs cite paths all the time.
assert_deny "a path but never called a worktree" \
  "$(a "Implement the venue rendering. The spec is at /work/some-project/docs/product-specs/R-widget-plan.md")" 'has to NAME THE WORKTREE'
# And the reverse: the word with nothing to act on. "In your worktree" tells an agent nothing it can
# cd into, which is exactly how a dispatch ends up executing in the main checkout.
assert_deny "the word but no path" \
  "$(a "Work only in your worktree and do not touch the main checkout.")" 'has to NAME THE WORKTREE'

# 🔴 The load-bearing arms for the absolute-path widening, and they point the opposite way to every
# arm above. The widening was made so `/work/wt/<wave>` would count; it also made these three count,
# and each is an ordinary sentence in an ordinary brief. A must-red arm is structurally blind to
# that direction — the fixture stayed green right through the over-fire, because the two deny arms
# above feed "no path at all" and "a relative path" and neither goes near the new surface.
assert_deny "the word plus a stderr redirect is not a named worktree" \
  "$(a "Work only in your worktree. Send stderr to /dev/null and report what you find. $KB")" 'has to NAME THE WORKTREE'
assert_deny "the word plus a bare /tmp is not a named worktree" \
  "$(a "Work only in your worktree and keep scratch files under /tmp. $KB")" 'has to NAME THE WORKTREE'
assert_deny "the word plus a shebang path is not a named worktree" \
  "$(a "Work only in your worktree. Scripts start with /usr/bin/env bash. $KB")" 'has to NAME THE WORKTREE'

# --- ALLOW: both halves present ---------------------------------------------------------------------
assert_allow "the word and a drive-letter path" \
  "$(a "Worktree — work ONLY here: Z:/wt/r-widget on branch feat/r-widget. Drive git with git -C Z:/wt/r-widget. $KB")"
assert_allow "the word and a POSIX path" \
  "$(a "Worktree — work ONLY here: /home/dev/wt/r-widget on branch feat/r-widget. $KB")"
# The must-GREEN half of the tightening above: a worktree that genuinely lives under a temp or
# service root is still a named worktree, and excluding those roots outright would deny a correct
# brief. Only the roots that can never hold a checkout are refused.
assert_allow "a worktree under a temp root is still a worktree" \
  "$(a "Worktree — work ONLY here: /tmp/wt/r-widget on branch feat/r-widget. $KB")"
assert_allow "a worktree under a service root is still a worktree" \
  "$(a "Worktree — work ONLY here: /srv/wt/r-widget on branch feat/r-widget. $KB")"

# --- ALLOW: roles this gate does not judge -----------------------------------------------------------
# It guards the pipeline roles, which are the ones that write. A general search agent that never
# commits anything does not need a tree of its own, and denying it would make the tool unusable for
# the read-only work the pipeline depends on.
assert_allow "a general-purpose agent" "$(a "Find every caller of the venue helper." general-purpose search-x)"
assert_allow "not an Agent dispatch" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"ls docs"}}))')"

# --- DENY: the limb this gate is named for -----------------------------------------------------------
# A brief that names the tree but points at no knowledge sends the agent to rediscover what somebody
# already wrote down. It runs last, so it is only reachable once the worktree is named — which is why
# every allow arm above carries the pointer.
assert_deny "a worktree named, but no knowledge pointer" \
  "$(a "Worktree — work ONLY here: Z:/wt/r-widget on branch feat/r-widget.")" 'no pointer to the knowledge base'

# 🔴 That deny points at `~/.claude/knowledge/`, which is right BY DESIGN — the base accumulates
# across projects, so it lives in the operator's home and not in the read-only plugin cache. What was
# missing is the step that creates it: the installer's target follows the chosen install scope, and
# no shipped document names `templates/knowledge/` at all. On a clean install this gate blocked every
# dispatch while its FIX named a directory nothing had ever made. The text now carries the seed
# command — and a PATH inside operator-facing text rots the moment the directory moves, so this arm
# RESOLVES what the gate printed rather than trusting the sentence.
# 🔴 BOTH directions, because the tree under test decides which one applies and neither is a skip:
# a tree that SHIPS the seed must name it, and a tree that does not must name NOTHING rather than a
# path that does not exist. The second branch is not hypothetical — the teeth harness copies hooks/
# and bin/ and never templates/, so it runs this fixture in exactly that tree.
out="$(a "Worktree — work ONLY here: Z:/wt/r-widget on branch feat/r-widget." | node "$HOOK" 2>&1)"
SEEDPATH="$(printf '%s' "$out" | sed -n 's#.*cp -r \(.*\)/\. ~/.claude/knowledge/.*#\1#p' | head -1)"
SEEDSRC="$(cd "$(dirname "$0")/../.." && pwd)/templates/knowledge"
if [ -d "$SEEDSRC" ]; then
  if [ -n "$SEEDPATH" ] && [ -d "$SEEDPATH" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("KNOWLEDGE-SEED: the tree ships templates/knowledge and the FIX names no existing seed (got: '${SEEDPATH:-<none>}')"); fi
  # …and it has to be the directory that actually holds the channel, not merely one that exists —
  # a bare `-d` would survive the seed being repointed at the plugin root.
  if [ -n "$SEEDPATH" ] && [ -f "$SEEDPATH/INDEX.md" ] && [ -d "$SEEDPATH/developer" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("KNOWLEDGE-SEED-SHAPE: '${SEEDPATH:-<none>}' is not the knowledge channel (no INDEX.md + role directories)"); fi
else
  if [ -z "$SEEDPATH" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("KNOWLEDGE-SEED-PHANTOM: this tree ships no templates/knowledge, yet the FIX tells the operator to copy from '$SEEDPATH'"); fi
fi

# --- the configurable worktree marker actually escapes what it is given -------------------------------
# 🔴 This arm exists because the seam was broken when this fixture was written: the escaping call's
# replacement string had been corrupted into a fragment of the NEXT LINE of the file, so every regex
# metacharacter in a custom marker was replaced by that fragment instead of being escaped. With the
# default marker (`wt`, no metacharacters) the bug is invisible — the replace matches nothing — which
# is why it survived the port. A marker with a dot in it is the smallest input that tells the two
# apart, and the gate must still behave for the adopter who sets one.
export AAL_WORKTREE_MARKER='proj.wt'
assert_allow "a custom marker containing a regex metacharacter" \
  "$(a "Worktree — work ONLY here: Z:/proj.wt/r-widget on branch feat/r-widget. $KB")"
out="$(a "Worktree — work ONLY here: Z:/proj.wt/r-widget on branch feat/r-widget. $KB" | node "$HOOK" 2>&1)"
if printf '%s' "$out" | grep -qE 'MAIN_EXAMPLE|SyntaxError|Invalid regular expression'; then
  FAIL=$((FAIL+1))
  FAILURES+=("MARKER-ESCAPE: the custom marker leaked source text or broke the pattern (got: $(printf '%s' "$out" | head -c 140))")
else
  PASS=$((PASS+1))
fi
unset AAL_WORKTREE_MARKER

summary
