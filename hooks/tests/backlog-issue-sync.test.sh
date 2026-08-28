#!/usr/bin/env bash
# backlog-issue-sync — mirrors board cards into issues so people outside the loop can see what is
# being worked on. The card is the canonical record and the issue is a copy, which is why the
# interesting behaviour is what it REFUSES to copy: a card that mentions operational detail has its
# body withheld, and a repository that is public is refused outright.
#
# Every arm here is a DRY RUN. The apply path creates and edits real issues through the GitHub CLI,
# and a fixture has no business doing that; what the dry run covers is the plan, the refusals and the
# withholding, which is where the judgement lives.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$HOOKS_DIR/backlog-issue-sync.mjs"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/.claude"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N"
export CLAUDE_CONFIG_DIR="$AAL_TMP_N/config"
trap 'rm -rf "$AAL_TMP"' EXIT

BOARD="$AAL_TMP/.claude/BACKLOG.md"
BOARD_N="$AAL_TMP_N/.claude/BACKLOG.md"
BULLET='-'
card() { printf '%s [%s] %s P%s\n%s %s: %s\n' '###' "$1" "$2" "${4:-3}" "$BULLET" 'problem' "$3"; }
board() { printf '# Backlog\n\n%s\n' "$1" > "$BOARD"; }

# No parameters, deliberately: all four call sites are a bare `run`, so the two defaults were taken
# every time and the values below ARE the fixture's contract. Written as `${2:-…}` they read as a
# seam that does not exist, and shellcheck 0.9.0 (the version CI ships) correctly says so —
# SC2120 at this line plus SC2119 at each call site, which is the whole lint lane's exit 123.
run() { AAL_BACKLOG="$BOARD_N" AAL_REPO='owner/private-repo' AAL_PUBLIC_REPO='' node "$TOOL" 2>&1; }
check() { # $1 = label, $2 = pattern that must appear, $3 = the output
  if printf '%s' "$3" | grep -q "$2"; then PASS=$((PASS+1));
  else FAIL=$((FAIL+1)); FAILURES+=("$1: expected /$2/ (got: $(printf '%s' "$3" | tail -c 160))"); fi
}
refute() { # $1 = label, $2 = pattern that must NOT appear, $3 = the output
  if printf '%s' "$3" | grep -q "$2"; then FAIL=$((FAIL+1)); FAILURES+=("$1: /$2/ appeared and should not have");
  else PASS=$((PASS+1)); fi
}
# -----------------------------------------------------------------------------------------------

# --- the plan, for a card with no issue number yet ---------------------------------------------------
board "$(card QUEUED R-widget 'the detail page renders no venue' 1)"
out="$(run)"
check "CREATE" 'CREATE' "$out"
check "the card is named" 'R-widget' "$out"
check "and nothing is written" 'Nothing was written' "$out"

# --- a card that already carries an issue number becomes an update ------------------------------------
board "$(card QUEUED R-widget 'the detail page renders no venue' 1)
$(printf '%s %s: #%s\n' "$BULLET" 'issue' 42)"
out="$(run)"
check "UPDATE" 'UPDATE #42' "$out"
refute "…and not a second create" '^CREATE' "$out"

# --- 🔴 the withholding is DECIDED here and SHOWN nowhere -------------------------------------------------
# The tool composes each issue body, and a card mentioning an operational path, a credential name or a
# vulnerability gets a withheld marker instead of its text. That decision is real — but the dry run
# prints only the action, the card name, the status and the priority, so no body ever appears.
# Measured: with a card whose problem line names a host, a system path and a token, the dry-run output
# contains neither the sentence nor the marker.
#
# The arm below pins what CAN be observed: the sensitive text does not leak into the dry run either.
# What cannot be pinned without publishing is the positive half — that the marker is what reaches the
# issue. Named here rather than left for a reader to infer from the arm count.
#
# It is also a finding in its own right, reported rather than fixed: a dry run exists so an operator
# can see what will be published BEFORE it is, and the one part worth reading before publishing — the
# body — is the part it does not show.
board "$(card QUEUED R-widget 'ssh deploy@box and read /srv/app/config for the ADMIN_RELAY_TOKEN' 1)"
out="$(run)"
refute "the sensitive sentence is not in the dry run" 'ADMIN_RELAY_TOKEN' "$out"
check  "…while the card itself is still planned"      'R-widget' "$out"

# --- refusals ----------------------------------------------------------------------------------------------
# Pointing this at the public mirror would copy internal material outside by construction, so it stops
# before planning anything.
out="$(AAL_BACKLOG="$BOARD_N" AAL_REPO='owner/public-mirror' AAL_PUBLIC_REPO='public-mirror' node "$TOOL" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'REFUSED'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("PUBLIC-REPO: rc=$rc out='$(printf '%s' "$out" | head -c 140)'")
fi
# And with nothing to point at, it says what it needs rather than guessing a repository.
out="$(AAL_BACKLOG='' AAL_REPO='' node "$TOOL" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'AAL_BACKLOG'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-CONFIG: rc=$rc out='$(printf '%s' "$out" | head -c 140)'")
fi

# --- archived cards are not mirrored -------------------------------------------------------------------------
board "$(card ARCHIVED R-old 'something that was finished last month' 3)"
out="$(run)"
check "the archived card is counted"  '1 total, 0 active' "$out"
refute "…and it is not in the plan"   'R-old ' "$out"

summary
