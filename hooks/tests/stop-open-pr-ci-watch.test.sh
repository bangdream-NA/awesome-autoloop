#!/usr/bin/env bash
# stop-open-pr-ci-watch — the end-of-turn reading of what GitHub says about the open PRs, as opposed
# to what the board claims. It is the last thing standing between "the card says merged" and a PR
# that has been red for two days.
#
# What it owes, and what the arms below check:
#   · a PR that is APPROVED at its CURRENT head and mergeable is named as mergeable;
#   · a red PR nobody has touched is named as red;
#   · while checks are still RUNNING it says nothing — a verdict on an unfinished run is noise, and
#     a channel that speaks every turn stops being read;
#   · a draft and a bot branch are not the operator's queue;
#   · APPROVED pinned to a DIFFERENT sha is not approved — that is the failure this gate exists for,
#     and it is invisible to anything that only reads the verdict word;
#   · outside a resolvable autoloop project, and with no `gh` on PATH, it is silent rather than wrong.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$HOOKS_DIR/stop-open-pr-ci-watch.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude/reviews" "$AAL_TMP/home/.claude/hooks"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
aal_pin_project "$REPO_N"
# The gate derives `owner/repo` from origin's URL and goes quiet when there is none, so a fixture
# without a remote would test the quiet path and nothing else. The URL is never contacted: every
# call that would leave the machine goes through the fake `gh` below.
git -C "$REPO" remote add origin https://github.com/example/widget.git
# HOME holds the roster and the state directory this reads; pointed at the sandbox so the run
# neither inherits the operator's teams nor writes into them.
export HOME="$AAL_TMP_N/home"
export USERPROFILE="$AAL_TMP_N/home"
trap 'rm -rf "$AAL_TMP"' EXIT

# 🔴 This gate reaches `gh` from node, not from the shell, so the fixture library's fake_gh — a
# shell script on PATH — is INVISIBLE to it. Measured on this host: node skipped the shell-script
# stub in silence and reached the operator's REAL `gh`, which answered with a live GraphQL error for
# a repository that does not exist. A stub that looks installed and is never called is worse than
# none: the arms would have been reporting on the network.
# GH_PATH is read as a command, so the stub is a node script invoked by node — the one spelling
# Windows can spawn (`.cmd`/`.bat` are refused outright, an extensionless script is not an image).
FAKE_GH="$AAL_TMP_N/fake-gh.mjs"
cat > "$AAL_TMP/fake-gh.mjs" <<'FAKEGH'
const a = process.argv.slice(2).join(' ');
if (a === '--version') { process.stdout.write('gh version 0.0.0 (fixture)\n'); process.exit(0); }
if (/^pr list .*--state open/.test(a)) { process.stdout.write(process.env.FAKE_GH_OPEN_JSON || '[]'); process.exit(0); }
// Everything else — `run list`, `run view` — is a channel this fixture does not drive. Failing is
// what the real thing does when it cannot answer, and the gate already treats that as no data.
process.exit(1);
FAKEGH
export GH_PATH="node $FAKE_GH"
# The control for the stub itself: if it cannot answer `--version`, the gate resolves no `gh` at all
# and every arm below goes quiet for a reason that has nothing to do with what it is testing.
if ! node "$AAL_TMP_N/fake-gh.mjs" --version > /dev/null 2>&1; then
  echo "  stop-open-pr-ci-watch.test.sh: FAIL (the fake gh does not answer --version; no arm below means anything)"
  exit 1
fi

BOARD="$REPO/.claude/$(printf '%s%s' 'BACK' 'LOG.md')"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
OTHER_SHA="0123456789abcdef0123456789abcdef01234567"

# A card that owns PR #12 and is past review, so the stage-hold limb does not claim the PR before
# the CI limb can speak about it.
board() { printf '%s\n\n### [REVIEW] R-widget · P2 · PR #12\n- aliases: r-widget\n- problem: the detail page renders no venue\n- fix: render it\n' '# board' > "$BOARD"; }
board

verdict() { # $1 = verdict word, $2 = the sha it is pinned to
  printf '{"pr":12,"verdict":"%s","head_sha":"%s","ts":"2026-08-01T00:00:00Z"}\n' "$1" "$2" \
    > "$REPO/.claude/reviews/index.jsonl"
}
no_verdict() { rm -f "$REPO/.claude/reviews/index.jsonl"; }

# One open PR, described exactly as `gh pr list --json` describes one.
pr() { # $1 = mergeStateStatus, $2 = checks JSON array, $3 = branch, $4 = isDraft
  node -e 'process.stdout.write(JSON.stringify([{
      number: 12,
      headRefName: process.argv[3],
      headRefOid: process.argv[5],
      mergeStateStatus: process.argv[1],
      statusCheckRollup: JSON.parse(process.argv[2]),
      isDraft: process.argv[4] === "true",
    }]))' -- "$1" "$2" "$3" "$4" "$HEAD_SHA"
}
GREEN='[{"conclusion":"SUCCESS","status":"COMPLETED"}]'
RED='[{"conclusion":"FAILURE","status":"COMPLETED","completedAt":"2026-08-01T00:00:00Z"}]'
RUNNING='[{"status":"IN_PROGRESS"}]'

p() { node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555"}))'; }
run() { p | node "$HOOK" 2>&1; }
# -----------------------------------------------------------------------------------------------

# --- SILENT: nothing open, nothing owed ----------------------------------------------------------
# The first thing this gate has to get right is saying nothing, because it runs at the end of every
# single turn.
export FAKE_GH_OPEN_JSON='[]'
out="$(run)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("QUIET-NO-PRS: it spoke with no open PR and no worktree debt (got: $(printf '%s' "$out" | head -c 160))"); fi

# --- FIRES: APPROVED at the head, clean, nothing red ---------------------------------------------
verdict APPROVED "$HEAD_SHA"
FAKE_GH_OPEN_JSON="$(pr CLEAN "$GREEN" feat/r-widget false)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if printf '%s' "$out" | grep -q 'mergeable right now' && printf '%s' "$out" | grep -q '#12'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("MERGEABLE: an APPROVED, CLEAN, green PR was not named as mergeable (got: $(printf '%s' "$out" | head -c 200))"); fi

# --- FIRES: APPROVED, but pinned to a DIFFERENT sha ----------------------------------------------
# 🔴 The arm this gate exists for. The verdict word is identical; only the sha differs, and reading
# the word alone reports a PR as ready to merge when the commit it approved is no longer the head.
verdict APPROVED "$OTHER_SHA"
out="$(run)"
if printf '%s' "$out" | grep -q 'mergeable right now'; then
  FAIL=$((FAIL+1)); FAILURES+=("STALE-PIN: APPROVED pinned to another sha was still called mergeable")
else PASS=$((PASS+1)); fi

# --- FIRES: red, and nobody has touched the card since ------------------------------------------
verdict APPROVED "$HEAD_SHA"
FAKE_GH_OPEN_JSON="$(pr CLEAN "$RED" feat/r-widget false)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if printf '%s' "$out" | grep -q 'red, and nobody is on it' && printf '%s' "$out" | grep -q '#12'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("RED: a failing PR was not reported (got: $(printf '%s' "$out" | head -c 200))"); fi

# --- SILENT: the checks have not finished --------------------------------------------------------
# A run in progress has no verdict yet; reporting one would train the reader to skip this channel.
FAKE_GH_OPEN_JSON="$(pr CLEAN "$RUNNING" feat/r-widget false)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("QUIET-RUNNING: it spoke while the checks were still running (got: $(printf '%s' "$out" | head -c 200))"); fi

# --- SILENT: a draft is not in the queue ---------------------------------------------------------
FAKE_GH_OPEN_JSON="$(pr CLEAN "$RED" feat/r-widget true)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("QUIET-DRAFT: a draft PR was reported (got: $(printf '%s' "$out" | head -c 200))"); fi

# --- a bot branch is separated from the operator's queue -----------------------------------------
# It is still red, but it is not work anybody here is going to do, so it must not appear in the
# section the reader is meant to act on.
FAKE_GH_OPEN_JSON="$(pr CLEAN "$RED" dependabot/npm/left-pad false)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if printf '%s' "$out" | grep -q 'red, and nobody is on it'; then
  FAIL=$((FAIL+1)); FAILURES+=("BOT: a dependabot branch was listed as unowned red work")
else PASS=$((PASS+1)); fi

# --- BEHIND with an APPROVED verdict at the head is a pull, not a dispatch -----------------------
verdict APPROVED "$HEAD_SHA"
FAKE_GH_OPEN_JSON="$(pr BEHIND "$GREEN" feat/r-widget false)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if printf '%s' "$out" | grep -q 'one step short of moving'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("BEHIND: a BEHIND PR whose verdict matches the head was not offered as a pull (got: $(printf '%s' "$out" | head -c 200))"); fi

# --- BEHIND with a verdict that is NOT approved needs a person, not a pull -----------------------
verdict CHANGES_REQUIRED "$HEAD_SHA"
out="$(run)"
if printf '%s' "$out" | grep -q 'dispatch a developer first'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("BEHIND-UNAPPROVED: a BEHIND PR under CHANGES_REQUIRED was not routed to a dispatch (got: $(printf '%s' "$out" | head -c 200))"); fi

# --- a PR with no verdict at all is unreviewed, not mergeable ------------------------------------
no_verdict
FAKE_GH_OPEN_JSON="$(pr CLEAN "$GREEN" feat/r-widget false)"
export FAKE_GH_OPEN_JSON
out="$(run)"
if printf '%s' "$out" | grep -q 'mergeable right now'; then
  FAIL=$((FAIL+1)); FAILURES+=("NO-VERDICT: a PR with no verdict on file was called mergeable")
else PASS=$((PASS+1)); fi

# --- SILENT: outside a project it can resolve ----------------------------------------------------
verdict APPROVED "$HEAD_SHA"
out="$(p | AAL_AUTOLOOP_LEAD='' AAL_LEAD_REPO='' AAL_DEFAULT_REPO='' CLAUDE_PROJECT_DIR="$AAL_TMP_N/not-a-project" node "$HOOK" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("SCOPE: it spoke with no project resolved (got: $(printf '%s' "$out" | head -c 160))"); fi

# --- SILENT: `gh` is not installed ---------------------------------------------------------------
# Every reading it could make comes from `gh`. With none, the honest answer is nothing — inventing
# one from the board would be the exact substitution this gate was written to prevent.
# GH_PATH names a binary that does not exist, and HOME has no `gh` under it, so the only candidate
# left is a bare `gh` on PATH — which the sandbox PATH does not carry either.
out="$(p | GH_PATH="$AAL_TMP_N/no-such-gh-binary" PATH="$(dirname "$(command -v node)")" node "$HOOK" 2>&1)"
if [ -z "$out" ] || [ "$out" = "{}" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("NO-GH: it spoke with no gh on PATH (got: $(printf '%s' "$out" | head -c 160))"); fi

summary
