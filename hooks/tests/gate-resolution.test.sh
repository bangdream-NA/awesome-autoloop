#!/usr/bin/env bash
# gate-resolution.test.sh — R-13 cross-wire fixture matrix (arch §A-5 / AC-8).
#
# Proves the shared `aal_extract_cd_target` helper resolves the merge command's EFFECTIVE cwd (the
# LAST `cd <dir>` anywhere in the command, not the leading-^ one), and that each gate's CLASS policy
# is preserved: Class-A board gate fail-closes on an unresolvable cd (never cross-wires another
# project's board — the 2026-06-11 incident); Class-B cd-into gates keep their env/git fallback;
# Class-C advisory keeps `pwd` fail-open.
#
# Toolchain: bash + node only (no .bats). Self-contained: builds temp project repos + a temp HOOKDIR
# of real-file copies, stubs `gh` on PATH so the board gate runs offline, drives each scenario,
# asserts the resolved project / decision. Extends the R-10 stop-dispatcher.test.sh harness style
# (same ok/bad/assert_* helpers, same temp-dir discipline).
#
# RED→GREEN (G-12): after the matrix is GREEN against the real gate, the harness builds a
# DELIBERATELY-BROKEN gate (old leading-^ / first-cd extraction restored) and asserts G-2/G-7 now
# FAIL — proving the matrix actually catches the cross-wire bug. Run:
#   bash hooks/tests/gate-resolution.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
ACTIVATION_SRC="$HOOKS_SRC/lib/activation.sh"
PARSEJSON_SRC="$HOOKS_SRC/lib/parse-json.sh"
BOARD_GATE_SRC="$HOOKS_SRC/require-backlog-reconciled-before-merge.sh"
BOARD_CJS_SRC="$HOOKS_SRC/require-backlog-reconciled-before-merge.cjs"
STALEBASE_SRC="$HOOKS_SRC/block-pr-merge-stale-base.sh"

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# assert_eq <label> <got> <want>
assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got[$2] want[$3]"; fi; }
# assert_contains <label> <haystack> <needle>
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
# assert_not_contains <label> <haystack> <needle>
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }
# assert_empty <label> <haystack>
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected EMPTY | got: $2"; fi; }
# assert_nonempty <label> <haystack>
assert_nonempty()     { if [ -n "$2" ]; then ok "$1"; else bad "$1 — expected NON-empty"; fi; }

# ---------------------------------------------------------------------------------------------
# build_hookdir <dir> [board_gate_override] — temp HOOKDIR with the real lib + board gate copy +
# a `gh` stub on a private bin (returns the canned merged-slug list from $GH_STUB_SLUGS).
# ---------------------------------------------------------------------------------------------
build_hookdir() {
  local d="$1"; local gate="${2:-$BOARD_GATE_SRC}"
  mkdir -p "$d/lib" "$d/bin"
  cp "$ACTIVATION_SRC"  "$d/lib/activation.sh"
  cp "$PARSEJSON_SRC"   "$d/lib/parse-json.sh"
  cp "$gate"            "$d/require-backlog-reconciled-before-merge.sh"
  cp "$BOARD_CJS_SRC"   "$d/require-backlog-reconciled-before-merge.cjs"
  cp "$STALEBASE_SRC"   "$d/block-pr-merge-stale-base.sh"
  # gh stub: `gh pr list --repo … --json headRefName --jq …` -> the canned slugs from env.
  cat > "$d/bin/gh" <<'GH'
#!/usr/bin/env bash
# stub gh — only the `pr list … merged` form is exercised by the board gate.
case "$*" in
  *"pr list"*"--state merged"*) printf '%s\n' "${GH_STUB_SLUGS:-}" ;;
  *) ;;
esac
exit 0
GH
  chmod +x "$d/bin/gh" "$d/require-backlog-reconciled-before-merge.sh" "$d/block-pr-merge-stale-base.sh"
}

# build_project <dir> <sentinel> — a git repo with .claude/BACKLOG.md carrying a card whose PRIMARY
# alias = <sentinel> (so a merged-slug == sentinel makes the .cjs deny + quote THIS board's title).
build_project() {
  local p="$1"; local sentinel="$2"
  mkdir -p "$p/.claude"
  ( cd "$p" && git init -q && git remote add origin "https://github.com/fixture/$sentinel.git" )
  cat > "$p/.claude/BACKLOG.md" <<EOF
# BACKLOG ($sentinel)

### [QUEUED] BOARD-CARD-$sentinel · open
- aliases: $sentinel
- problem: fixture card so the cross-ref quotes THIS board on a sentinel match.
- fix: n/a
EOF
}

# run_board_gate <hookdir> <cmd> [extra env…] — feed the board gate a PreToolUse(Bash) payload for
# <cmd>; the stub `gh` is front-loaded onto the GATE process's PATH (passed via env so it reaches the
# gate, NOT just the upstream printf); capture stdout (deny JSON or empty=allow).
run_board_gate() {
  local d="$1"; local cmd="$2"; shift 2
  local payload
  payload=$(CMD="$cmd" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",command:process.env.CMD}))')
  printf '%s' "$payload" | env "$@" PATH="$d/bin:$PATH" bash "$d/require-backlog-reconciled-before-merge.sh"
}

echo "== R-13 gate-resolution matrix =="
echo ""

# ---------------------------------------------------------------------------------------------
# G-1 — helper unit: aal_extract_cd_target on the §0.4 E1-E12 strings (last-cd-wins, no ^-anchor).
# ---------------------------------------------------------------------------------------------
echo "--- G-1 helper unit (aal_extract_cd_target on the §0.4 matrix) ---"
# shellcheck source=/dev/null
source "$ACTIVATION_SRC"
# Generic placeholder paths (no drive-letter / machine form — the helper is path-shape-agnostic; it
# parses the `cd` token regardless of path, so /proj/a is as valid a probe as any real path).
assert_eq "G-1 E1 leading"      "$(aal_extract_cd_target 'cd /proj/a && M')"                      "/proj/a"
assert_eq "G-1 E2 compound"     "$(aal_extract_cd_target 'git -C /proj/a st && cd /proj/a && M')" "/proj/a"
assert_eq "G-1 E3 multi-cd"     "$(aal_extract_cd_target 'cd /proj/a && cd /proj/b && M')"        "/proj/b"
assert_eq "G-1 E4 quoted-space" "$(aal_extract_cd_target 'cd "/proj/My Project" && M')"          "/proj/My Project"
assert_eq "G-1 E5 cd-dash"      "$(aal_extract_cd_target 'x && cd - && M')"                       "-"
assert_eq "G-1 E6 semicolon"    "$(aal_extract_cd_target 'cd /proj/a ; M')"                       "/proj/a"
assert_empty "G-1 E8 no-cd"     "$(aal_extract_cd_target 'git -C /proj/a fetch && M')"
assert_eq "G-1 E9 nonexist"     "$(aal_extract_cd_target 'cd /no/such/dir && M')"                 "/no/such/dir"
assert_eq "G-1 E10 trail-ws"    "$(aal_extract_cd_target 'cd /proj/a &&  M')"                     "/proj/a"
assert_eq "G-1 E11 pipe"        "$(aal_extract_cd_target 'cd /proj/a | M')"                       "/proj/a"
assert_empty "G-1 E12 subshell" "$(aal_extract_cd_target '(cd /proj/a && M)')"
echo ""

# Shared fixtures for the gate-level rows: two projects on disk + a hookdir whose gh stub returns
# BOTH sentinels as "merged" (so whichever board the gate reads, its OWN card is flagged stale).
ROOT=$(mktemp -d)
build_project "$ROOT/projA" "AAL-FIXTURE-PROJA-BOARD"
build_project "$ROOT/projB" "AAL-FIXTURE-PROJB-BOARD"
HD=$(mktemp -d); build_hookdir "$HD"
BOTH_SLUGS=$(printf 'AAL-FIXTURE-PROJA-BOARD\nAAL-FIXTURE-PROJB-BOARD')

echo "--- G-2..G-10 Class-A board gate (require-backlog-reconciled) ---"

# G-2 compound (AC-1): `git -C A … && cd A && gh pr merge` resolves to A's board.
OUT=$(run_board_gate "$HD" "git -C $ROOT/projA status && cd $ROOT/projA && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-2 compound -> A's board read"          "$OUT" "AAL-FIXTURE-PROJA-BOARD"
assert_not_contains "G-2 compound -> B's board NOT read"      "$OUT" "AAL-FIXTURE-PROJB-BOARD"

# G-3 leading (AC-2): plain `cd A && gh pr merge` resolves to A (no regression).
OUT=$(run_board_gate "$HD" "cd $ROOT/projA && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-3 leading -> A's board read"           "$OUT" "AAL-FIXTURE-PROJA-BOARD"
assert_not_contains "G-3 leading -> B's board NOT read"       "$OUT" "AAL-FIXTURE-PROJB-BOARD"

# G-4 no-cd fail-closed (AC-3): a merge with NO cd to a real dir → deny with the guidance, never allow.
OUT=$(run_board_gate "$HD" "git -C $ROOT/projA fetch && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains "G-4 no-cd -> deny"                           "$OUT" '"permissionDecision":"deny"'
assert_contains "G-4 no-cd -> 'cannot resolve WHICH project'" "$OUT" "cannot resolve WHICH project"
assert_not_contains "G-4 no-cd -> did NOT reach any board"    "$OUT" "AAL-FIXTURE-PROJ"

# G-5 non-autoloop no-op (AC-4): a repo with ALL FOUR markers absent → exit 0, empty stdout.
NOAUTO=$(mktemp -d); ( cd "$NOAUTO" && git init -q && git remote add origin https://github.com/fixture/noauto.git )
mkdir -p "$NOAUTO/.claude"   # .claude/ exists but carries NONE of: .autoloop / BACKLOG.md / code-reviews.md / managed CLAUDE.md
OUT=$(run_board_gate "$HD" "cd $NOAUTO && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_empty "G-5 non-autoloop (aal_is_autoloop_project false) -> no-op, empty stdout" "$OUT"
# control: dropping a code-reviews.md (but still no BACKLOG.md) makes it autoloop-managed → NOT a no-op
: > "$NOAUTO/.claude/code-reviews.md"
OUT2=$(run_board_gate "$HD" "cd $NOAUTO && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
# autoloop now true, but still no BACKLOG.md at projDir → the gate's own `[ -f BACKLOG ] || exit 0` no-op fires.
assert_empty "G-5b autoloop-true but no BACKLOG -> narrower no-op (still empty)" "$OUT2"
rm -rf "$NOAUTO"

# G-6 two-projects A<->B (AC-5, F-205 MAKE-OR-BREAK): cd A run touches ONLY A's board; cd B ONLY B's.
echo ""
echo "--- G-6 two-projects side-by-side (AC-5 / F-205 make-or-break) ---"
OUT_A=$(run_board_gate "$HD" "cd $ROOT/projA && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
OUT_B=$(run_board_gate "$HD" "cd $ROOT/projB && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-6 cd-A run references A's sentinel"    "$OUT_A" "AAL-FIXTURE-PROJA-BOARD"
assert_not_contains "G-6 cd-A run NEVER opens B's board"      "$OUT_A" "AAL-FIXTURE-PROJB-BOARD"
assert_contains     "G-6 cd-B run references B's sentinel"    "$OUT_B" "AAL-FIXTURE-PROJB-BOARD"
assert_not_contains "G-6 cd-B run NEVER opens A's board"      "$OUT_B" "AAL-FIXTURE-PROJA-BOARD"
echo ""

echo "--- G-7..G-10 edge rows (Class-A) ---"
# G-7 multi-cd last-wins: `cd A && cd B && gh pr merge` resolves to B (the row the old idioms got wrong).
OUT=$(run_board_gate "$HD" "cd $ROOT/projA && cd $ROOT/projB && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-7 multi-cd -> last wins (B's board)"   "$OUT" "AAL-FIXTURE-PROJB-BOARD"
assert_not_contains "G-7 multi-cd -> A's board NOT read"      "$OUT" "AAL-FIXTURE-PROJA-BOARD"

# G-8 quoted spaces: cd "<dir with spaces>" && gh pr merge resolves to the quoted dir.
build_project "$ROOT/proj C" "AAL-FIXTURE-PROJC-BOARD"
OUT=$(run_board_gate "$HD" "cd \"$ROOT/proj C\" && gh pr merge 1" GH_STUB_SLUGS="AAL-FIXTURE-PROJC-BOARD")
assert_contains "G-8 quoted-space dir -> C's board read"      "$OUT" "AAL-FIXTURE-PROJC-BOARD"

# G-9 subshell → fail-closed: `(cd A && gh pr merge)` extracts EMPTY → deny, never silently cross-wires.
OUT=$(run_board_gate "$HD" "(cd $ROOT/projA && gh pr merge 1)" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-9 subshell -> deny (fail-closed)"      "$OUT" '"permissionDecision":"deny"'
assert_not_contains "G-9 subshell -> did NOT open A's board"  "$OUT" "AAL-FIXTURE-PROJA-BOARD"

# G-10 nonexistent cd → fail-closed: `[ -d ]` false → deny.
OUT=$(run_board_gate "$HD" "cd $ROOT/no-such-proj && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains "G-10 nonexistent cd -> deny (fail-closed)"   "$OUT" '"permissionDecision":"deny"'
echo ""

# ---------------------------------------------------------------------------------------------
# G-11 — Class-C (block-pr-merge-stale-base) last-wins + fail-OPEN posture preserved.
# We assert at the extraction layer (the gate's REPO_DIR resolution) using the same helper the gate
# now calls, since the full stale-base gate needs live gh/git network. The posture check: with a cd
# present it resolves the LAST cd; with NO cd it falls to pwd (NOT a deny).
# ---------------------------------------------------------------------------------------------
echo "--- G-11 Class-C extraction last-wins + fail-open ---"
REPO_DIR=$(aal_extract_cd_target "cd $ROOT/projA && cd $ROOT/projB && gh pr merge 1")
assert_eq "G-11 Class-C multi-cd -> last (B), not first (A)"  "$REPO_DIR" "$ROOT/projB"
# fail-open: no cd → helper empty → the gate's `[ -z ] || [ ! -d ]` branch sets REPO_DIR=pwd (not a deny).
NOCD=$(aal_extract_cd_target "gh pr merge 1")
assert_empty "G-11 Class-C no-cd -> empty (gate then uses pwd, fail-open)" "$NOCD"
# prove the gate text still has the pwd fail-open fallback (not converted to a deny).
assert_contains "G-11 Class-C gate keeps pwd fail-open" "$(cat "$STALEBASE_SRC")" 'REPO_DIR=$(pwd)'
echo ""

# ---------------------------------------------------------------------------------------------
# G-12 — RED→GREEN proof. Build a board gate COPY with the OLD leading-^ `sed` extraction restored
# and assert G-2 (compound) + G-7 (multi-cd) now FAIL — the old extraction returns EMPTY on the
# compound (→ deny, never reaches A's board) and resolves A (not B) on multi-cd.
# ---------------------------------------------------------------------------------------------
echo "--- G-12 RED->GREEN proof (old extraction must FAIL G-2/G-7) ---"
OLD_GATE="$ROOT/old-board-gate.sh"
# Reconstruct the pre-R-13 Class-A site: old leading-^ sed + aal_resolve_project_dir fallback. The
# old extraction line is captured in a single-quoted heredoc (ZERO shell/escape processing — a `\1`
# stays a literal `\1`, the sed capture-group back-ref the historical line actually used). We then
# awk-swap the new 3-line block for it. (Avoid a node/JS-template reconstruction — its `\\` escaping
# silently mangled `\1` into `\\1`, which sed reads as a literal backslash → empty PROJ_DIR.)
cat > "$ROOT/old-extraction.frag" <<'FRAG'
PROJ_DIR=$(printf '%s' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&;]+)"?[[:space:]]*(&&|;).*/\1/p' | head -1 | sed 's/[[:space:]]*$//' || true)
[ -n "$PROJ_DIR" ] || PROJ_DIR="$(aal_resolve_project_dir)"
if [ -z "__never__" ]; then
FRAG
# awk: from `PROJ_DIR=$(aal_extract_cd_target …)` through the following `if [ -z … ]; then`,
# delete those 2 lines and splice in the fragment.
awk -v frag="$ROOT/old-extraction.frag" '
  /^PROJ_DIR=\$\(aal_extract_cd_target/ { while ((getline l < frag) > 0) print l; close(frag); skip=1; next }
  skip && /^if \[ -z "\$PROJ_DIR" \] \|\| \[ ! -d "\$PROJ_DIR" \]; then/ { skip=0; next }
  { print }
' "$HD/require-backlog-reconciled-before-merge.sh" > "$OLD_GATE"
HD_OLD=$(mktemp -d); build_hookdir "$HD_OLD" "$OLD_GATE"
# Sanity: the reconstructed gate must carry the old sed back-ref + resolver fallback (not the helper).
assert_contains "G-12 setup: old gate restored old sed extraction" "$(cat "$OLD_GATE")" 'sed -nE'
assert_not_contains "G-12 setup: old gate has NO helper call"      "$(cat "$OLD_GATE")" 'aal_extract_cd_target "$CMD"'
# G-2 under OLD: compound `git -C A && cd A && merge` — old ^-anchor matches no cd → empty →
# falls to aal_resolve_project_dir. With CLAUDE_PROJECT_DIR pointing at B, it CROSS-WIRES to B
# (the exact bug). Assert the old gate does NOT correctly read A (it reads B or denies) → RED.
OUT_OLD=$(run_board_gate "$HD_OLD" "git -C $ROOT/projA status && cd $ROOT/projA && gh pr merge 1" \
          GH_STUB_SLUGS="$BOTH_SLUGS" CLAUDE_PROJECT_DIR="$ROOT/projB")
assert_contains     "G-12 RED: old gate compound -> CROSS-WIRES to B" "$OUT_OLD" "AAL-FIXTURE-PROJB-BOARD"
assert_not_contains "G-12 RED: old gate compound -> did NOT read A"   "$OUT_OLD" "AAL-FIXTURE-PROJA-BOARD"
# G-7 under OLD: `cd A && cd B && merge` — old greedy `[^"&;]+` + head -1 resolves A (WRONG; should
# be B). The NEW helper (proven in G-7 above) resolves B. The contrast IS the RED→GREEN proof.
OUT_OLD2=$(run_board_gate "$HD_OLD" "cd $ROOT/projA && cd $ROOT/projB && gh pr merge 1" \
           GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains "G-12 RED: old gate multi-cd -> resolves A (the bug)" "$OUT_OLD2" "AAL-FIXTURE-PROJA-BOARD"
# GREEN restate: the NEW gate (already proven in G-2/G-7 above) gets these right — the contrast IS the proof.
echo "    (GREEN side proven by G-2 + G-7 above against the real gate)"
echo ""

rm -rf "$ROOT" "$HD" "$HD_OLD"

echo ""
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
