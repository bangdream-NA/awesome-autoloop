#!/usr/bin/env bash
# require-ship-action-before-archive — merged is not shipped. A card archived for a PR whose files
# need a manual delivery step, with nothing recording that the step ran, closes a wave that never
# reached production. The gate parses the ship table out of the operations runbook, asks GitHub which
# files the PR touched, and denies the archive write when a manual row matches and the card is silent.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-ship-action-before-archive.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT

REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude" "$REPO/docs/runbooks"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
aal_pin_project "$REPO_N"

# The ship table is READ from the runbook rather than duplicated in the gate, so the fixture writes
# one. Two rows, one manual and one automatic, because that distinction is the whole predicate.
cat > "$REPO/docs/runbooks/OPS.md" <<'OPS'
# Operations

## §1 Ship actions

| Change touches | Ship action | Channel |
| --- | --- | --- |
| `data-pipeline/**` | **republish the dataset** | manual |
| `apps/web/**` | **the deploy workflow** | automatic on push |
OPS

# 🔴 The sandbox repository has NO REMOTE, and the fixture runs from inside it. That is what makes the
# GitHub call deterministic: `gh` cannot resolve a repository, so it fails, and the gate takes its
# fail-closed path every time instead of reaching whatever repository the suite happens to sit in.
# Measured first the other way round: run from this checkout, the gate answered from a real
# `gh pr view 12` against its own remote, and three arms passed for reasons unrelated to the fixture.
cd "$REPO" || exit 1

ARCHIVE="$REPO_N/.claude/BACKLOG-archive-01.md"
BULLET='-'
merged_card() { printf '%s [%s] %s · MERGED #%s\n' '###' 'DONE' "$1" "$2"; }
ship_line()   { printf '%s %s: %s\n' "$BULLET" 'ship' "$1"; }
# -----------------------------------------------------------------------------------------------

w() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:process.argv[2]}}))' -- "$1" "$2"; }

# --- DENY: the file list cannot be resolved, which is not evidence of "nothing to ship" ---------------
# An empty answer from the tool and "this PR touched nothing" are byte-identical from here, and only
# one of them is safe to allow. This is the branch every adopter meets when a PR number is stale or
# the network is down, so it is worth more than the happy path it stands in for.
assert_deny "the PR cannot be resolved" \
  "$(w "$ARCHIVE" "$(merged_card R-widget 12)")" 'failing CLOSED'
assert_deny "…and the denial says merged is not shipped" \
  "$(w "$ARCHIVE" "$(merged_card R-widget 12)")" 'Merged is not shipped'

# --- ALLOW: the card already records a ship action, so nothing needs resolving --------------------------
# This check runs BEFORE the network, which is what keeps a card that did its job from being held
# hostage to whether GitHub is reachable.
assert_allow "a ship line with evidence" \
  "$(w "$ARCHIVE" "$(merged_card R-widget 12)
$(ship_line 'republish the dataset · owner=lead · ran=2026-08-26T09:00:00Z, the partition timestamp came back new')")"
assert_allow "an explicit not-applicable" \
  "$(w "$ARCHIVE" "$(merged_card R-widget 12)
$(ship_line 'N/A — the diff is tests only')")"

# --- ALLOW: nothing here is a claim about a merged PR ------------------------------------------------------
assert_allow "an archive entry naming no PR" "$(w "$ARCHIVE" "$(printf '%s [%s] %s\n' '###' 'DONE' 'R-widget')")"
# A single-digit number is not a PR reference to this gate: two digits is the floor, so a card
# mentioning "#5" is not dragged into a GitHub lookup.
assert_allow "a one-digit number"            "$(w "$ARCHIVE" "$(merged_card R-widget 5)")"
assert_allow "an empty write"                "$(w "$ARCHIVE" "")"

# --- ALLOW: files this gate does not judge --------------------------------------------------------------------
assert_allow "the active board"   "$(w "$REPO_N/.claude/BACKLOG.md" "$(merged_card R-widget 12)")"
assert_allow "a plan document"    "$(w "$REPO_N/docs/product-specs/R-widget-plan.md" "$(merged_card R-widget 12)")"
assert_allow "not a write at all" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"cat archive.md"}}))')"

# --- ALLOW: no ship table to read -------------------------------------------------------------------------------
# The requirement comes from the runbook, not from the gate. A project without that table has not
# declared any manual channel, and inventing one would deny every archive write on day one.
mv "$REPO/docs/runbooks/OPS.md" "$REPO/docs/runbooks/OPS.md.bak"
assert_allow "no operations runbook" "$(w "$ARCHIVE" "$(merged_card R-widget 12)")"
mv "$REPO/docs/runbooks/OPS.md.bak" "$REPO/docs/runbooks/OPS.md"

# 🔴 NOT ASSERTED: the branch where GitHub ANSWERS and a manual row matches — the denial that names
# the action. Reaching it needs a `gh` that returns a file list, and this gate shells out to the real
# binary with no seam for a substitute. A shell stub on PATH does not work: the call is made from
# node, whose process launcher will not run an extensionless script and — measured here — refuses a
# `.cmd` outright, so it walks past both and finds the real binary. Naming the gap rather than
# leaving a reader to infer coverage from the arm count; a seam for the file-list lookup would make
# this reachable, and that is a change to the gate rather than to its fixture.

summary
