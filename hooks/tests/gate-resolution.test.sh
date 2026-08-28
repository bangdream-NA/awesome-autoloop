#!/usr/bin/env bash
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

assert_eq()           { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got[$2] want[$3]"; fi; }
assert_contains()     { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }
assert_empty()        { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected EMPTY | got: $2"; fi; }
assert_nonempty()     { if [ -n "$2" ]; then ok "$1"; else bad "$1 — expected NON-empty"; fi; }

build_hookdir() {
  local d="$1"; local gate="${2:-$BOARD_GATE_SRC}"
  mkdir -p "$d/lib" "$d/bin"
  cp "$ACTIVATION_SRC"  "$d/lib/activation.sh"
  cp "$PARSEJSON_SRC"   "$d/lib/parse-json.sh"
  cp "$gate"            "$d/require-backlog-reconciled-before-merge.sh"
  cp "$BOARD_CJS_SRC"   "$d/require-backlog-reconciled-before-merge.cjs"
  cp "$STALEBASE_SRC"   "$d/block-pr-merge-stale-base.sh"
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

run_board_gate() {
  local d="$1"; local cmd="$2"; shift 2
  local payload
  payload=$(CMD="$cmd" node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",command:process.env.CMD}))')
  printf '%s' "$payload" | env CLAUDE_PROJECT_DIR="$AAL_AMBIENT" "$@" PATH="$d/bin:$PATH" bash "$d/require-backlog-reconciled-before-merge.sh"
}

echo "== R-13 gate-resolution matrix =="
echo ""

echo "--- G-1 helper unit (aal_extract_cd_target on the §0.4 matrix) ---"
# shellcheck source=/dev/null
source "$ACTIVATION_SRC"
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

ROOT=$(mktemp -d)
build_project "$ROOT/projA" "AAL-FIXTURE-PROJA-BOARD"
build_project "$ROOT/projB" "AAL-FIXTURE-PROJB-BOARD"
HD=$(mktemp -d); build_hookdir "$HD"
# keys on the RESOLVED ambient project (CLAUDE_PROJECT_DIR -> git-common-dir -> cwd), NOT the
# point CLAUDE_PROJECT_DIR at it in run_board_gate (placed BEFORE "$@" so G-12's explicit
# per-row CLAUDE_PROJECT_DIR override still last-wins). Board TARGET is unaffected (extracted from
AAL_AMBIENT=$(mktemp -d); mkdir -p "$AAL_AMBIENT/.claude"; : > "$AAL_AMBIENT/.claude/.autoloop"
BOTH_SLUGS=$(printf 'AAL-FIXTURE-PROJA-BOARD\nAAL-FIXTURE-PROJB-BOARD')

echo "--- G-2..G-10 Class-A board gate (require-backlog-reconciled) ---"

OUT=$(run_board_gate "$HD" "git -C $ROOT/projA status && cd $ROOT/projA && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-2 compound -> A's board read"          "$OUT" "AAL-FIXTURE-PROJA-BOARD"
assert_not_contains "G-2 compound -> B's board NOT read"      "$OUT" "AAL-FIXTURE-PROJB-BOARD"

OUT=$(run_board_gate "$HD" "cd $ROOT/projA && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-3 leading -> A's board read"           "$OUT" "AAL-FIXTURE-PROJA-BOARD"
assert_not_contains "G-3 leading -> B's board NOT read"       "$OUT" "AAL-FIXTURE-PROJB-BOARD"

OUT=$(run_board_gate "$HD" "git -C $ROOT/projA fetch && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains "G-4 no-cd -> deny"                           "$OUT" '"permissionDecision":"deny"'
assert_contains "G-4 no-cd -> 'cannot resolve WHICH project'" "$OUT" "cannot resolve WHICH project"
assert_not_contains "G-4 no-cd -> did NOT reach any board"    "$OUT" "AAL-FIXTURE-PROJ"

NOAUTO=$(mktemp -d); ( cd "$NOAUTO" && git init -q && git remote add origin https://github.com/fixture/noauto.git )
mkdir -p "$NOAUTO/.claude"
OUT=$(run_board_gate "$HD" "cd $NOAUTO && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_empty "G-5 non-autoloop (aal_is_autoloop_project false) -> no-op, empty stdout" "$OUT"
: > "$NOAUTO/.claude/code-reviews.md"
OUT2=$(run_board_gate "$HD" "cd $NOAUTO && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_empty "G-5b autoloop-true but no BACKLOG -> narrower no-op (still empty)" "$OUT2"
rm -rf "$NOAUTO"

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
OUT=$(run_board_gate "$HD" "cd $ROOT/projA && cd $ROOT/projB && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-7 multi-cd -> last wins (B's board)"   "$OUT" "AAL-FIXTURE-PROJB-BOARD"
assert_not_contains "G-7 multi-cd -> A's board NOT read"      "$OUT" "AAL-FIXTURE-PROJA-BOARD"

build_project "$ROOT/proj C" "AAL-FIXTURE-PROJC-BOARD"
OUT=$(run_board_gate "$HD" "cd \"$ROOT/proj C\" && gh pr merge 1" GH_STUB_SLUGS="AAL-FIXTURE-PROJC-BOARD")
assert_contains "G-8 quoted-space dir -> C's board read"      "$OUT" "AAL-FIXTURE-PROJC-BOARD"

OUT=$(run_board_gate "$HD" "(cd $ROOT/projA && gh pr merge 1)" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains     "G-9 subshell -> deny (fail-closed)"      "$OUT" '"permissionDecision":"deny"'
assert_not_contains "G-9 subshell -> did NOT open A's board"  "$OUT" "AAL-FIXTURE-PROJA-BOARD"

OUT=$(run_board_gate "$HD" "cd $ROOT/no-such-proj && gh pr merge 1" GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains "G-10 nonexistent cd -> deny (fail-closed)"   "$OUT" '"permissionDecision":"deny"'
echo ""

echo "--- G-11 Class-C extraction last-wins + fail-open ---"
REPO_DIR=$(aal_extract_cd_target "cd $ROOT/projA && cd $ROOT/projB && gh pr merge 1")
assert_eq "G-11 Class-C multi-cd -> last (B), not first (A)"  "$REPO_DIR" "$ROOT/projB"
NOCD=$(aal_extract_cd_target "gh pr merge 1")
assert_empty "G-11 Class-C no-cd -> empty (gate then uses pwd, fail-open)" "$NOCD"
assert_contains "G-11 Class-C gate keeps pwd fail-open" "$(cat "$STALEBASE_SRC")" 'REPO_DIR=$(pwd)'
echo ""

echo "--- G-12 RED->GREEN proof (old extraction must FAIL G-2/G-7) ---"
OLD_GATE="$ROOT/old-board-gate.sh"
cat > "$ROOT/old-extraction.frag" <<'FRAG'
PROJ_DIR=$(printf '%s' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^"&;]+)"?[[:space:]]*(&&|;).*/\1/p' | head -1 | sed 's/[[:space:]]*$//' || true)
[ -n "$PROJ_DIR" ] || PROJ_DIR="$(aal_resolve_project_dir)"
if [ -z "__never__" ]; then
FRAG
awk -v frag="$ROOT/old-extraction.frag" '
  /^PROJ_DIR=\$\(aal_extract_cd_target/ { while ((getline l < frag) > 0) print l; close(frag); skip=1; next }
  skip && /^if \[ -z "\$PROJ_DIR" \] \|\| \[ ! -d "\$PROJ_DIR" \]; then/ { skip=0; next }
  { print }
' "$HD/require-backlog-reconciled-before-merge.sh" > "$OLD_GATE"
HD_OLD=$(mktemp -d); build_hookdir "$HD_OLD" "$OLD_GATE"
assert_contains "G-12 setup: old gate restored old sed extraction" "$(cat "$OLD_GATE")" 'sed -nE'
assert_not_contains "G-12 setup: old gate has NO helper call"      "$(cat "$OLD_GATE")" 'aal_extract_cd_target "$CMD"'
# falls to aal_resolve_project_dir. With CLAUDE_PROJECT_DIR pointing at B, it CROSS-WIRES to B
OUT_OLD=$(run_board_gate "$HD_OLD" "git -C $ROOT/projA status && cd $ROOT/projA && gh pr merge 1" \
          GH_STUB_SLUGS="$BOTH_SLUGS" CLAUDE_PROJECT_DIR="$ROOT/projB")
assert_contains     "G-12 RED: old gate compound -> CROSS-WIRES to B" "$OUT_OLD" "AAL-FIXTURE-PROJB-BOARD"
assert_not_contains "G-12 RED: old gate compound -> did NOT read A"   "$OUT_OLD" "AAL-FIXTURE-PROJA-BOARD"
OUT_OLD2=$(run_board_gate "$HD_OLD" "cd $ROOT/projA && cd $ROOT/projB && gh pr merge 1" \
           GH_STUB_SLUGS="$BOTH_SLUGS")
assert_contains "G-12 RED: old gate multi-cd -> resolves A (the bug)" "$OUT_OLD2" "AAL-FIXTURE-PROJA-BOARD"
echo "    (GREEN side proven by G-2 + G-7 above against the real gate)"
echo ""

rm -rf "$ROOT" "$HD" "$HD_OLD" "$AAL_AMBIENT"

echo ""
echo "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] || exit 1
