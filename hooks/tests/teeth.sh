#!/usr/bin/env bash
# teeth.sh — does every gate fixture actually FAIL when its gate stops working?
#
# AC7e's word is "seen red". A fixture that has only ever been observed green proves nothing about
# the gate; it proves the fixture ran. This harness answers the question mechanically and
# repeatably, so "seen red" becomes a standing assertion about the tree instead of a claim about
# the author's process.
#
# Method, per fixture: copy the tree, NEUTER that fixture's gate, run the fixture, require FAILURE.
# Two mutations, because one is blind to half the corpus:
#   INERT    the gate exits 0 in silence  — every DENY arm should go red
#   DENY-ALL the gate denies everything   — every ALLOW arm should go red
# A fixture with teeth fails under at least one; the mutation that flipped it is printed.
#
# 🔴 The harness's own failure mode is that the MUTATION does not apply — the copy is byte-identical
# to the original, the fixture passes, and "this fixture has no teeth" is indistinguishable from
# "my sed missed". So every mutation is verified to have changed the file before its green is given
# any meaning, and a mutation that did not apply is reported as a FAILURE, never as a skip.
#
# 🔴 It is a TEST ARTIFACT: no event mounts it, it is in no delegate registry, and its filename is
# outside run-all.sh's `*.test.sh` glob on purpose — it neuters gates in throwaway copies and must
# never be reachable from a hook. Run it by hand or from a CI step.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"          # hooks/
ROOT="$(cd "$KIT/.." && pwd)"          # repo root

# Fixtures whose subject is NOT a single mounted gate. Each carries its reason; the list is
# asserted below (every name must exist), because an exclusion list that quietly names a file that
# is gone stops excluding anything and nobody finds out.
EXCLUDED="
_lib.sh:a fixture library, not a fixture
_lib.mjs:a fixture library, not a fixture
run-all.sh:the runner
teeth.sh:this harness
lib-assert-allow.test.sh:tests the fixture library's own assert helper
sanitize-accept-patterns.test.sh:tests bin/sanitize-check.sh, not a hooks/ gate
sanitize-ci-username.test.sh:tests bin/sanitize-check.sh, not a hooks/ gate
sanitize-cjk-denylist.test.sh:tests bin/sanitize-check.sh, not a hooks/ gate
gate-resolution.test.sh:tests how gates are RESOLVED, across many gates at once
deny-gate-crash-allow.test.sh:a cross-gate property (a crashed gate must not read as allow)
shared-lib-behaviour-change.test.sh:a cross-gate property over a shared library
dispatcher-registry-in-step.test.sh:tests the dispatcher registry, not one gate
stop-dispatcher.test.sh:tests the dispatcher and its delegates as a set
autoloop-scope-guard.test.sh:a cross-gate property over the activation guard
posix-path-predicates.test.sh:a cross-gate property over every path predicate at once
posix-utility-flags.test.mjs:a cross-tree property over GNU-only utility flags in every shipped .sh
knowledge-role-isolation.test.sh:tests a directory convention, not a single gate
backlog-format.test.sh:tests a reporting tool that is not mounted as a gate
archive-residue.test.sh:tests a repo-state property
oplog-grepall.test.sh:tests a ledger property across files
oplog-rotation.test.sh:tests a ledger property across files
prune-team-inboxes.test.sh:tests a maintenance utility
backlog-reconcile.test.sh:tests a reconciler CLI, not a mounted gate
backlog-reconcile-assoc.test.sh:tests a reconciler CLI, not a mounted gate
backlog-reconcile-checkb.test.sh:tests a reconciler CLI, not a mounted gate
statusdrift-anchor-exclusion.test.sh:exercises one predicate inside a gate, not the gate's mount
statusdrift-demote-guard.test.sh:exercises one predicate inside a gate, not the gate's mount
sopvalidate-cardpr-anchor.test.sh:exercises one predicate inside backlog-sop-validate
planverdict-architect-jsonl.test.sh:exercises the shared plan-verdict library
planverdict-dev-jsonl.test.sh:exercises the shared plan-verdict library
empty-board-and-comment-strip.test.sh:a shared board-parsing property
conventional-commit-first-m.test.sh:one predicate inside the commit preflight
backlog-gate-vocab-widening.test.sh:exercises a vocabulary table, not a mount
backlog-ownership-token-required.test.mjs:exercises a board field predicate
require-verdict-driven-forward-card-field.test.mjs:exercises a board field predicate
require-wave-doc-read-before-dod-token.test.mjs:reads transcripts, no single gate to neuter
backlog-format.test.sh:reporting tool, not a mounted gate
"

# Which artifact does this fixture actually RUN? Derived from the fixture's own text — every
# candidate filename it mentions that exists under hooks/ — rather than from its filename. A
# name-based guess picks the wrong sibling whenever a gate ships as both a `.sh` wrapper and a
# `.mjs` body, and the wrong-artifact mutation is indistinguishable from a toothless fixture.
gates_for_fixture() {
  grep -ohE '[A-Za-z0-9_.-]+\.(sh|mjs)' "$1" 2>/dev/null \
    | sort -u \
    | while IFS= read -r cand; do
        case "$cand" in _lib.sh|_lib.mjs|run-all.sh|teeth.sh|*.test.sh|*.test.mjs) continue ;; esac
        [ -f "$KIT/$cand" ] && printf '%s\n' "$cand"
      done
}

excluded_reason() {
  printf '%s\n' "$EXCLUDED" | while IFS=: read -r n r; do
    [ -n "$n" ] || continue
    [ "$n" = "$1" ] && { printf '%s' "$r"; return; }
  done
}

DENY_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"TEETH-HARNESS: deny-all mutant"}}'

# A throwaway copy of the tree the fixtures run against. Every failure here is REPORTED: stderr is
# kept, no `|| true` swallows the rc, and a copy that did not happen stops the fixture being judged.
copy_tree() { # $1 = destination directory
  mkdir -p "$1/hooks" "$1/bin" || return 1
  cp -r "$KIT/." "$1/hooks/" || return 1
  cp "$ROOT/bin/sanitize-check.sh" "$1/bin/" || return 1
  return 0
}

# A fixture is a shell script or an ES module; handing one to the other's interpreter fails in a way
# that reads like the gate having teeth.
run_fixture() { # $1 = fixture path -> rc of the fixture
  case "$1" in
    *.mjs) node "$1" >/dev/null 2>&1 ;;
    *)     bash "$1" >/dev/null 2>&1 ;;
  esac
}

TEETH=0; NOTEETH=0; BROKEN=0; SKIPPED=0
NOTEETH_NAMES=""; BROKEN_NAMES=""
results=0

# The exclusion list must describe files that exist. Read it LINE by line: an unquoted
# `for x in $LIST` splits on every space, so each word of each reason becomes its own "entry" and
# the harness reports a few hundred phantom failures that drown the real ones.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  n="${line%%:*}"
  [ -n "$n" ] || continue
  if [ ! -f "$HERE/$n" ]; then
    echo "  BROKEN EXCLUSION: $n is on the exclusion list but does not exist"
    BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $n(stale-exclusion)"
  fi
done <<EOF
$EXCLUDED
EOF

for f in "$HERE"/*.test.sh "$HERE"/*.test.mjs; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if [ -n "$(excluded_reason "$name")" ]; then
    SKIPPED=$((SKIPPED + 1))
    printf '  %-46s excluded — %s\n' "$name" "$(excluded_reason "$name")"
    continue
  fi
  gates="$(gates_for_fixture "$f")"
  results=$((results + 1))
  if [ -z "$gates" ]; then
    printf '  %-46s 🔴 NO GATE RESOLVED — the fixture names no file that exists under hooks/\n' "$name"
    BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name(no-gate)"
    continue
  fi

  # 🔴 THE BASELINE ARM. Teeth is the DELTA between "green with the gate intact" and "red with the
  # gate neutered", and only the second endpoint used to be measured. A fixture that cannot run in
  # the temp tree AT ALL — a missing dependency, a path that does not survive the copy — fails under
  # both mutations and is reported as `RED under: inert denyall`, the most reassuring line here.
  # So it is run unmutated first, in the same temp tree: red there is a HARNESS failure with the
  # file named, never evidence about the gate.
  T="$(mktemp -d)"
  if ! copy_tree "$T"; then
    printf '  %-46s 🔴 HARNESS: the temp tree could not be built\n' "$name"
    BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name(tree-copy-failed)"
    rm -rf "$T"; continue
  fi
  if [ ! -f "$T/hooks/tests/$name" ]; then
    printf '  %-46s 🔴 HARNESS: the fixture is not in the copied tree\n' "$name"
    BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name(missing-in-temp-tree)"
    rm -rf "$T"; continue
  fi
  if ! run_fixture "$T/hooks/tests/$name"; then
    printf '  %-46s 🔴 RED UNMUTATED — it fails with its gate INTACT, so red under a mutation says nothing\n' "$name"
    BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name(red-unmutated)"
    rm -rf "$T"; continue
  fi
  rm -rf "$T"

  flipped=""; applied=0
  for mode in inert denyall; do
    T="$(mktemp -d)"
    # 🔴 A failed copy used to be swallowed by `2>/dev/null || true`, and `cmp` against a file that
    # does not exist reports "differs" — so the mutation control passed when NOTHING had been
    # copied. A setup that did not happen is a harness failure, not a reading.
    if ! copy_tree "$T"; then
      printf '  %-46s 🔴 HARNESS: the temp tree could not be built (%s)\n' "$name" "$mode"
      BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name($mode-tree-copy-failed)"
      rm -rf "$T"; continue
    fi
    # EVERY artifact this fixture names is neutered, not a guessed one. Over-neutering can only
    # make red MORE likely, so a fixture that stays green here is genuinely toothless; picking one
    # candidate and picking wrong produces a green that means nothing.
    changed=0
    while IFS= read -r gate; do
      [ -n "$gate" ] || continue
      case "$gate" in
        *.sh)
          if [ "$mode" = inert ]; then printf '#!/usr/bin/env bash\nexit 0\n' > "$T/hooks/$gate"
          else printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nprintf %%s %s\nexit 0\n' "'$DENY_JSON'" > "$T/hooks/$gate"; fi ;;
        *.mjs)
          if [ "$mode" = inert ]; then printf '#!/usr/bin/env node\nprocess.exit(0);\n' > "$T/hooks/$gate"
          else printf '#!/usr/bin/env node\nconsole.log(%s);\nprocess.exit(0);\n' "'$DENY_JSON'" > "$T/hooks/$gate"; fi ;;
        *) continue ;;
      esac
      # Both halves, in this order: the mutant must EXIST and it must DIFFER. `cmp` alone answers
      # "differs" for a file that was never written, which is the reading a failed copy produces.
      if [ -s "$T/hooks/$gate" ] && ! cmp -s "$KIT/$gate" "$T/hooks/$gate"; then
        changed=$((changed + 1))
      fi
    done <<INNER
$gates
INNER
    # 🔴 the mutation's own control: at least one artifact must actually differ from the original
    if [ "$changed" -eq 0 ]; then
      printf '  %-46s 🔴 MUTATION DID NOT APPLY (%s)\n' "$name" "$mode"
      BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name($mode-not-applied)"
      rm -rf "$T"; continue
    fi
    applied=$((applied + 1))
    tf="$T/hooks/tests/$name"
    # 🔴 The `else` this test used to be missing. With the fixture absent from the temp tree nothing
    # ran, `flipped` stayed empty, and the gate was reported as NO TEETH — a setup failure dressed
    # up as a finding about the fixture.
    if [ ! -f "$tf" ]; then
      printf '  %-46s 🔴 HARNESS: the fixture vanished from the temp tree (%s)\n' "$name" "$mode"
      BROKEN=$((BROKEN + 1)); BROKEN_NAMES="$BROKEN_NAMES $name($mode-fixture-missing)"
      applied=$((applied - 1))
      rm -rf "$T"; continue
    fi
    run_fixture "$tf" || flipped="${flipped}${mode} "
    rm -rf "$T"
  done

  if [ "$applied" -eq 0 ]; then
    continue                     # already counted as BROKEN above
  elif [ -n "$flipped" ]; then
    TEETH=$((TEETH + 1)); printf '  %-46s RED under: %s\n' "$name" "$flipped"
  else
    NOTEETH=$((NOTEETH + 1)); NOTEETH_NAMES="$NOTEETH_NAMES $name"
    printf '  %-46s 🔴 NO TEETH — green with its gate neutered both ways\n' "$name"
  fi
done

echo "──────────────────────────────────────────"
# 🔴 The denominator is checked, not asserted. exercised + excluded must equal the number of
# fixture files on disk: a fixture that falls through both lists is invisible in every other line
# of this report, and an unseen fixture reads exactly like a passing one.
FIXTURES=0
for f in "$HERE"/*.test.sh "$HERE"/*.test.mjs; do [ -f "$f" ] && FIXTURES=$((FIXTURES + 1)); done
ACCOUNTED=$((results + SKIPPED))
printf 'gates exercised: %s   with teeth: %s   without: %s   harness failures: %s   excluded: %s\n' \
  "$results" "$TEETH" "$NOTEETH" "$BROKEN" "$SKIPPED"
printf 'accounting: %s exercised + %s excluded = %s   fixture files on disk: %s\n' \
  "$results" "$SKIPPED" "$ACCOUNTED" "$FIXTURES"
if [ "$ACCOUNTED" -ne "$FIXTURES" ]; then
  printf '🔴 %s fixture(s) are in neither list — the report above does not cover the corpus\n' \
    "$((FIXTURES - ACCOUNTED))"
  BROKEN=$((BROKEN + 1))
fi
[ -n "$NOTEETH_NAMES" ] && echo "no teeth:$NOTEETH_NAMES"
[ -n "$BROKEN_NAMES" ]  && echo "harness could not test:$BROKEN_NAMES"
[ "$NOTEETH" -eq 0 ] && [ "$BROKEN" -eq 0 ]
