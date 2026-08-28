#!/usr/bin/env bash
# The seven scope guards, and the predicate that replaced the literal in them.
#
# Seven hooks used to open with a guard matching one author's transcript directory. The
# architecture classifies that literal as a SCOPE GUARD, never the judgment, and names
# lib/activation.sh's `aal_is_autoloop_project` as its counterpart; `isAutoloopSession` in
# lib/is-autoloop-lead.mjs is the ESM half of the same predicate, with the same four probes in the
# same order.
#
# Direction of the change, which decides which arms carry the weight: for every user who is not
# the author, the guard went from "never fires" to "fires whenever this is an autoloop project" —
# a widening across the whole population. So G2 is the load-bearing arm: a session in a project
# that does NOT run the convention must stay silent, which is also what keeps these hooks inert in
# unrelated repos.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$HERE/.." && pwd)"
HOOK="$HOOKS/require-archive-gated-done-card.mjs"

TD="$(mktemp -d)"
NODE_TD="$TD"
if command -v cygpath >/dev/null 2>&1; then NODE_TD="$(cygpath -m "$TD")"; fi

# A marker file that does not exist, so sessionProject() cannot resolve a REAL repo out of the
# machine's lead marker and make these arms depend on whatever session is live.
export AAL_LEAD_MARKER_FILE="$NODE_TD/no-such-marker"
export AAL_PROJECT_REGISTRY="$NODE_TD/no-such-registry"
export AAL_GATE_DENIALS_OFF=1
unset AAL_AUTOLOOP_LEAD AAL_LEAD_REPO AAL_DEFAULT_REPO 2>/dev/null || true

PASS=0; FAIL=0; FAILURES=()
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); FAILURES+=("$1"); }

# A card that this gate must flag: shipped, still badged BLOCKED, no escape word, no gate token.
CARD='### [BLOCKED] R-shipped-but-still-gated · P2 · MERGED #1234
- problem: placeholder
- fix: placeholder'

# A: a git repo that DOES run the convention (probe 2 - a board under .claude/).
mkdir -p "$TD/A/.claude"
( cd "$TD/A" && git init -q )
printf '%s\n' "$CARD" > "$TD/A/.claude/BACKLOG.md"

# B: a git repo with the SAME board bytes, but not under .claude/, so none of the four probes fire.
mkdir -p "$TD/B"
( cd "$TD/B" && git init -q )
printf '%s\n' "$CARD" > "$TD/B/board.md"

# A transcript with no tool_use lines, so the authored-here check stays out of the way and the
# only variable between G1 and G2 is whether the project runs the convention.
printf '{"message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}\n' > "$TD/t.jsonl"

run_hook() { # $1=CLAUDE_PROJECT_DIR $2=board path $3=transcript path or empty
  local payload='{}'
  if [ -n "${3:-}" ]; then payload="$(printf '{"transcript_path":"%s"}' "$3")"; fi
  printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$1" AAL_BACKLOG="$2" node "$HOOK" 2>&1
}

O="$(run_hook "$NODE_TD/A" "$NODE_TD/A/.claude/BACKLOG.md" "$NODE_TD/t.jsonl")"
case "$O" in *'"decision":"block"'*) ok ;; *) bad "G1 autoloop project: the guard must let the gate run (got: $(printf '%s' "$O" | head -c 120))" ;; esac

O="$(run_hook "$NODE_TD/B" "$NODE_TD/B/board.md" "$NODE_TD/t.jsonl")"
if [ "$O" = "{}" ]; then ok; else bad "G2 NON-autoloop project: the guard must hold and the gate stay silent (got: $(printf '%s' "$O" | head -c 200))"; fi

# G3 pins the SHAPE of the guard, not its predicate: it is `tp && !isAutoloopSession(stdin)`, so a
# payload with no transcript path at all still runs the gate. Rewriting it as `!isAutoloopSession`
# would silence every fixture and every non-transcript caller, and G1/G2 would both still pass.
O="$(run_hook "$NODE_TD/B" "$NODE_TD/B/board.md" "")"
case "$O" in *'"decision":"block"'*) ok ;; *) bad "G3 no transcript path: the guard must not engage (got: $(printf '%s' "$O" | head -c 120))" ;; esac

# --- unit arms on the predicate itself --------------------------------------
# The probe imports the library under test by absolute URL, so the arms exercise the shipped file
# rather than a re-implementation of its four probes.
cp "$HOOKS/lib/is-autoloop-lead.mjs" "$TD/lib-copy.mjs"
printf 'import { isAutoloopProjectDir } from %s;\nprocess.stdout.write(String(isAutoloopProjectDir(process.argv[2])));\n' \
  "'file:///$NODE_TD/lib-copy.mjs'" > "$TD/probe.mjs"

probe() { node "$TD/probe.mjs" "$1" 2>&1; }
expect() { # $1=desc $2=dir $3=want
  local got; got="$(probe "$2")"
  if [ "$got" = "$3" ]; then ok; else bad "$1 — want[$3] got[$got]"; fi
}

mkdir -p "$TD/u1/.claude" && : > "$TD/u1/.claude/.autoloop"
mkdir -p "$TD/u2/.claude" && printf 'x\n' > "$TD/u2/.claude/BACKLOG.md"
mkdir -p "$TD/u3/.claude" && printf 'x\n' > "$TD/u3/.claude/code-reviews.md"
mkdir -p "$TD/u4/.claude" && printf 'BEGIN awesome-autoloop\n' > "$TD/u4/.claude/CLAUDE.md"
mkdir -p "$TD/u5/.claude" && printf 'just an ordinary project CLAUDE.md\n' > "$TD/u5/.claude/CLAUDE.md"
mkdir -p "$TD/u7"

expect "U1 .claude/.autoloop"                "$NODE_TD/u1" true
expect "U2 .claude/BACKLOG.md"               "$NODE_TD/u2" true
expect "U3 .claude/code-reviews.md"          "$NODE_TD/u3" true
expect "U4 .claude/CLAUDE.md with the marker" "$NODE_TD/u4" true
# U5 is the must-zero arm for probe 4: a CLAUDE.md WITHOUT the marker is not enough. Relaxing that
# probe to "the file exists" would adopt every project that has a CLAUDE.md, and U1-U4 stay green.
expect "U5 .claude/CLAUDE.md WITHOUT the marker" "$NODE_TD/u5" false
expect "U6 empty string"                     ""            false
expect "U7 a directory with no .claude at all" "$NODE_TD/u7" false

# --- the literal is gone, with a must-hit control ---------------------------
# The needle is the SHAPE of a transcript-directory slug, not one author's. Spelling the literal
# out here would put it back into the artifact the scanner reads, and this arm would then be the
# only thing keeping the scan red.
LEFT="$(grep -lE 'projects/C--Users-[A-Za-z0-9]+' "$HOOKS"/*.mjs 2>/dev/null | wc -l | tr -d ' ')"
if [ "$LEFT" = "0" ]; then ok; else bad "S1 an author-specific transcript-dir literal is still in $LEFT hook(s)"; fi
CTRL="$(grep -l 'isAutoloopSession' "$HOOKS"/*.mjs 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CTRL" = "7" ]; then ok; else bad "S1-control expected the replacement in exactly 7 hooks, found $CTRL (if this moved, S1's zero stops meaning anything)"; fi

rm -rf "$TD"

name="$(basename "$0")"
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS) (arms run: $TOTAL)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail) (arms run: $TOTAL)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
