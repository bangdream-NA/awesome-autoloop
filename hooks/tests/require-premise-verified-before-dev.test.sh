#!/usr/bin/env bash
# Tests for require-premise-verified-before-dev.sh target-wave resolution
# (lib/premise-target.mjs). Regression origin (2026-06-04): the old
# `grep -oiE … | head -1` matched the substring inside the description
# "Develop calenda‹r-308› fix" → WAVE='r-308' → false-blocked a wave that WAS
# premise-verified (real key R-audit-home-calendar-event-308).
#
# Death-constraint contract: a false BLOCK is recoverable (PREMISE-VERIFIED
# escape); a false ALLOW is not. So these tests assert BOTH that the real wave
# now resolves+allows AND that an unrelated mentioned-but-not-target verified
# wave does NOT leak its verdict to the dispatch.
#
# Fixtures are MOCKED files at node-resolvable C:/ paths (NOT the live repo, NOT
# MSYS /tmp — node can't resolve /tmp/ env-var paths; §12 Windows footgun).
set -u
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/"require-premise-verified-before-dev.sh"

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
AAL_PROJ=/tmp/aal-fx-require-premise-verified-before-dev
rm -rf "$AAL_PROJ"
mkdir -p "$AAL_PROJ/.claude"
: > "$AAL_PROJ/.claude/.autoloop"
git -C "$AAL_PROJ" init -q 2>/dev/null || true
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# ---------------------------------------------------------------------------------

# The scratch ledger is a mktemp, never a directory inside the operator's own config root: a
# fixture that writes there is green on the author's machine and, for anyone else, either
# fails or edits real state.
FIX=$(mktemp -d)
PRF="$FIX/plan-reviews.md"
BLF="$FIX/backlog.md"
PASS=0; FAIL=0

mkdir -p "$FIX"
cat > "$PRF" <<'EOF'
## R-audit-home-calendar-event-308 plan review — 2026-06-04 [R1]
- verdict: APPROVED
**JSONL**: {"plan":"R-audit-home-calendar-event-308","verdict":"APPROVED","mode":"A"}

## R-audit-other-already-verified plan review — 2026-06-04 [R1]
- verdict: APPROVED
EOF
cat > "$BLF" <<'EOF'
### [IN-DEV] R-audit-home-calendar-event-308 · 🟢P3 (premise re-verified LIVE 308)
- aliases: r-audit-home-calendar-event-308, calendar-event-bare-uuid-308, bf-cal-event-308
- Status: IN-DEV

### [QUEUED] R-audit-foo-unverified · 🟡P2
- aliases: r-audit-foo-unverified
EOF

# run <json> -> echoes the hook's stdout (deny payload, or empty on allow)
# AAL_REVIEWS_JSONL is passed explicitly: the resolver only derives the jsonl path from a
# drive-letter board path found in the PROMPT, otherwise from CLAUDE_PROJECT_DIR — neither of
# which is where this fixture writes its rows.
run() { printf '%s' "$1" | AAL_PLAN_REVIEWS="$PRF" AAL_BACKLOG="$BLF" AAL_REVIEWS_JSONL="$FIX/reviews/index.jsonl" bash "$HOOK" 2>/dev/null; }

want_allow() { # label, json
  local out; out="$(run "$2")"
  if [ -z "$out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: expected ALLOW (empty) got: ${out:0:120}"; fi
}
want_deny() { # label, json
  local out; out="$(run "$2")"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: expected DENY got: ${out:0:120}"; fi
}
deny_has() { # label, json, needle
  local out; out="$(run "$2")"
  if printf '%s' "$out" | grep -qF "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1]: deny should mention '$3' — got: ${out:0:160}"; fi
}
deny_absent() { # label, json, needle
  local out; out="$(run "$2")"
  if printf '%s' "$out" | grep -qF "$3"; then FAIL=$((FAIL+1)); echo "FAIL [$1]: deny must NOT mention '$3' — got: ${out:0:160}"; else PASS=$((PASS+1)); fi
}

# Build a developer dispatch JSON. $1=description $2=name $3=prompt
dev() {
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:"developer",description:process.argv[1],name:process.argv[2],prompt:process.argv[3]}}))' "$1" "$2" "$3"
}

# ── 1. RED→GREEN core: description "calendar-308" (old → r-308) + real anchor.
J1="$(dev 'Develop calendar-308 fix' 'dev-calendar308' 'You are the developer for wave **R-audit-home-calendar-event-308** on team example-autoloop. Worktree feat/r-audit-home-calendar-event-308. Implement A-1 in calendar-merge.ts.')"
want_allow "1 real-input resolves canonical, allows (was r-308 false-block)" "$J1"
deny_absent "1b deny would never name r-308" "$(dev 'Develop calendar-308 fix' 'dev-calendar308' 'no anchor here, only calendar-308 text and an unverified target')" "r-308"

# ── 2. CRITICAL over-allow guard: target unverified, but prompt MENTIONS a
#      different verified wave → must DENY (not leak the other wave's verdict).
J2="$(dev 'Develop foo fix' 'dev-foounverified' 'You are the developer for wave **R-audit-foo-unverified** on team X. See sibling R-audit-home-calendar-event-308 (APPROVED) for the pattern. Implement.')"
want_deny "2 mentioned-verified-wave does NOT allow unverified target" "$J2"
deny_has  "2b deny names the RESOLVED target, not the mention" "$J2" "R-audit-foo-unverified"
deny_absent "2c deny must not be about calendar-308" "$J2" "calendar-event-308"

# ── 3. Clean verified target → allow.
want_allow "3 verified target allows" "$(dev 'fix x' 'dev-cal' 'You are the developer for wave **R-audit-home-calendar-event-308**. go.')"

# ── 4. Incidental 308 text, NO anchor, NO dev-<wave> name → NOWAVE → DENY
#      (fail-closed), and must NOT phantom-extract r-308.
J4="$(dev 'redirect cleanup' 'helper' 'Fix the redirect to /events/308 and the calendar-308 label. No wave named.')"
want_deny "4 no identifiable target → fail-closed deny" "$J4"
deny_has  "4b deny says could-not-identify" "$J4" "could not identify"
deny_absent "4c r-308 substring never becomes a phantom target" "$J4" "r-308"

# ── 5. Alias fallback: anchor is an ALIAS form; PR keyed by canonical; BACKLOG links them.
want_allow "5 alias-form target allowed via BACKLOG alias harvest" "$(dev 'fix' 'dev-cal' 'You are the developer for wave **calendar-event-bare-uuid-308**. go.')"
# 5b stem/suffix tolerance: prefix target is substring of the longer PR key.
want_allow "5b prefix target matches longer PR key" "$(dev 'fix' 'dev-cal' 'You are the developer for wave **R-audit-home-calendar-event**. go.')"

# ── 6. Deny payload is valid JSON (both deny reasons).
for label in "NOWAVE" "NOVERDICT"; do
  case "$label" in
    NOWAVE)    JJ="$J4" ;;
    NOVERDICT) JJ="$J2" ;;
  esac
  OUT="$(run "$JJ")"
  if printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s);process.exit(0)})' 2>/dev/null; then
    PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [6 $label deny JSON parses]: ${OUT:0:160}"; fi
done

# ── 7. Non-developer dispatch passes through (allow).
want_allow "7 planner passes through" '{"tool_name":"Agent","tool_input":{"subagent_type":"planner","name":"planner-x","prompt":"plan wave **R-audit-foo-unverified**"}}'

# ── 8. PREMISE-VERIFIED escape (developer, trivial no-premise wave) → allow.
want_allow "8 PREMISE-VERIFIED escape allows" "$(dev 'fix' 'dev-trivial' 'developer for wave **R-audit-nope-no-verdict**. # PREMISE-VERIFIED: curled the published partition, 0 dup, see log.')"

# ── 9. JSONL-FIRST (2026-07-10 per-verdict ledger model; kit plan-review BLOCKER-1's home twin):
#     a plan-reviewer now writes reviews/index.jsonl + a per-verdict file and NOT the frozen
#     monolith — a jsonl-only Mode-A APPROVED must ALLOW the dev dispatch (else post-migration
#     deadlock), and a jsonl row that is NEEDS_REVISION / mode-B / other-wave must NOT leak an allow.
mkdir -p "$FIX/reviews"
printf '%s\n' '{"plan":"R-jsonl-only-wave","verdict":"APPROVED","mode":"A","round":1}' > "$FIX/reviews/index.jsonl"
printf '%s\n' '{"plan":"R-jsonl-rejected-wave","verdict":"NEEDS_REVISION","mode":"A","round":1}' >> "$FIX/reviews/index.jsonl"
want_allow "9a jsonl-only APPROVED allows dev" "$(dev 'impl' 'dev-jl' 'developer for wave **R-jsonl-only-wave** build it')"
want_deny  "9b jsonl NEEDS_REVISION does not allow" "$(dev 'impl' 'dev-jl2' 'developer for wave **R-jsonl-rejected-wave** build it')"
# 9c. APPROVED r1 superseded by NEEDS_REVISION r2 → DENY (shared lib/plan-verdict.mjs: LAST row wins).
#     RED-proof for the shared-resolver back-port (kit 2026-07-10): the pre-refactor approved-only
#     substring scan false-ALLOWED this sequence (matched the stale r1 APPROVED, never saw r2).
printf '%s\n' '{"plan":"R-jsonl-flipflop-wave","verdict":"APPROVED","mode":"A","round":1}' >> "$FIX/reviews/index.jsonl"
printf '%s\n' '{"plan":"R-jsonl-flipflop-wave","verdict":"NEEDS_REVISION","mode":"A","round":2}' >> "$FIX/reviews/index.jsonl"
want_deny  "9c jsonl APPROVED then NEEDS_REVISION → deny (last wins)" "$(dev 'impl' 'dev-jl3' 'developer for wave **R-jsonl-flipflop-wave** build it')"

# ── 10. Prompt-path derivation survives "repo: X;board: Y" prose (2026-07-16 regex fix).
#     NO AAL_* env here — this exercises the prompt-derived projDir path. Pre-fix, the lazy
#     path-match glued from the FIRST drive-letter mention across ";board: " → garbled projDir →
#     jsonl unreadable → false NOVERDICT on a wave with a real APPROVED row (hit live on
#     dev-mygo9th). Post-fix (":" ";" excluded from the path char-class) the clean second path
#     wins and the APPROVED row allows.
FIX2=$(mktemp -d)
mkdir -p "$FIX2/.claude/reviews"
FIX2W="$(cygpath -m "$FIX2" 2>/dev/null || echo "$FIX2")"
printf '%s\n' '{"plan":"R-pathtest-semicolon-wave","verdict":"APPROVED","mode":"A","round":1}' > "$FIX2/.claude/reviews/index.jsonl"
OUT10=$(printf '%s' "$(dev 'impl' 'dev-pt' "developer for wave **R-pathtest-semicolon-wave** repo: Z:/somewhere;board: $FIX2W/.claude/BACKLOG.md build it")" | AAL_REVIEWS_JSONL="$FIX2/.claude/reviews/index.jsonl" bash "$HOOK" 2>/dev/null)
if [ -z "$OUT10" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [10 semicolon-prose path derivation allows]: ${OUT10:0:140}"; fi
rm -rf "$FIX2"

# --- 11. the DECLARED card anchor beats a longest-token harvest ---------------------------
#     The brief declares its card as `R-short-declared-wave` (which has an APPROVED row) and
#     followup-card slug in a KNOWN-GAP instruction. Pre-fix, "longest token wins" resolved the
#     the follow-up slug and denies the wrong wave. The declared anchor has to win.
# 🔴 Scratch lives in a temp dir the fixture creates and removes — NEVER under the operator's
# config root. Every path below is handed to the tool explicitly, so nothing requires it to sit
# there; with CLAUDE_CONFIG_DIR unset (the default for an adopter) the old form dropped files
# into a real ~/.claude, and on a machine where that directory is read-only source it is worse
# than untidy.
FIX3=$(mktemp -d)
mkdir -p "$FIX3/reviews"
printf '%s\n' '{"plan":"R-short-declared-wave","verdict":"APPROVED","mode":"A","round":1}' > "$FIX3/reviews/index.jsonl"
: > "$FIX3/plan-reviews.md"; : > "$FIX3/BACKLOG.md"
OUT11=$(printf '%s' "$(dev 'impl' 'dev-anchor' 'developer for wave **R-short-declared-wave** (read the card in full). KNOWN GAP note points at [[R-much-longer-incidental-followup-card-slug-name]], which is NOT this wave. build it')" | AAL_PLAN_REVIEWS="$FIX3/plan-reviews.md" AAL_BACKLOG="$FIX3/BACKLOG.md" AAL_REVIEWS_JSONL="$FIX3/reviews/index.jsonl" bash "$HOOK" 2>/dev/null)
if [ -z "$OUT11" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [11 declared anchor beats a longer incidental slug]: ${OUT11:0:140}"; fi
rm -rf "$FIX3"

rm -rf "$FIX"
echo "──────────────────────────────────────────"
echo "require-premise-verified: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
