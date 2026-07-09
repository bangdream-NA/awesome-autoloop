#!/usr/bin/env bash
# prune-team-inboxes.test.sh — R-stop-dispatcher-perf-mirror fixture (arch §A-3 / AC1+AC2).
#
# Part A (AC1 — single-process): over a many-file inbox tree the prune hook spawns ZERO per-file
#   `wc -c` subprocesses and EXACTLY ONE node scan. Proven with self-checked counting shims (a
#   false-green guard aborts LOUD if the shims no-op — pipeline-discipline §6), plus a static grep.
# Part B (AC2 — byte-identity semantics, RED→GREEN): for a >250000-byte inbox the keep/drop
#   partition keeps ALL unread + the most-recent 50, archives the rest to <file>.pruned-<ts>.bak,
#   and emits the byte-exact `INBOX PRUNE GUARD …` summary. A deliberately-broken copy (keep-all-
#   unread arm removed) DROPS an old-but-unread message (RED); the real hook keeps it (GREEN). Plus
#   the strict `> 250000` boundary (250000 not pruned; 250001 pruned).
#
# Toolchain: bash + node only. Self-contained: mktemp sandboxes, ok/bad/assert helpers, RESULT line.
# Run:  bash hooks/tests/prune-team-inboxes.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
HOOK="$HOOKS_SRC/prune-team-inboxes.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
# assert_eq <label> <got> <want>
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — got: [$2] | want: [$3]"; fi; }

echo "== R-stop-dispatcher-perf-mirror prune fixture (AC1 single-process + AC2 byte-identity) =="
echo ""

# ---------------------------------------------------------------------------------------------
# Part A — AC1: single-process scan (0 per-file wc spawns, exactly 1 node scan)
# ---------------------------------------------------------------------------------------------
echo "--- Part A: AC1 single-process spawn-count (self-checked wc/node shims) ---"

SBX_A=$(mktemp -d)
mkdir -p "$SBX_A/.claude/teams/T/inboxes"; : > "$SBX_A/.claude/.autoloop"
NFILES=25
i=0; while [ "$i" -lt "$NFILES" ]; do printf '[]' > "$SBX_A/.claude/teams/T/inboxes/box$i.json"; i=$((i+1)); done

# Resolve the REAL binaries BEFORE the shim dir is on PATH (so the shims exec the real tool, not
# themselves). Counting shims append one line per INVOCATION, then exec the real binary.
REAL_WC=$(command -v wc); REAL_NODE=$(command -v node)
SHIMDIR=$(mktemp -d)
WC_COUNT="$SHIMDIR/wc.count"; NODE_COUNT="$SHIMDIR/node.count"
: > "$WC_COUNT"; : > "$NODE_COUNT"
cat > "$SHIMDIR/wc" <<SHIM
#!/usr/bin/env bash
printf 'x\n' >> "$WC_COUNT"
exec "$REAL_WC" "\$@"
SHIM
cat > "$SHIMDIR/node" <<SHIM
#!/usr/bin/env bash
printf 'x\n' >> "$NODE_COUNT"
exec "$REAL_NODE" "\$@"
SHIM
chmod +x "$SHIMDIR/wc" "$SHIMDIR/node"

# FALSE-GREEN SELF-CHECK (Q1 guard): prove the shims genuinely count on THIS runtime before trusting
# a later 0/1. A no-op shim would pass the AC1 assertion vacuously (green before AND after any fix).
PATH="$SHIMDIR:$PATH" wc -c < "$SBX_A/.claude/teams/T/inboxes/box0.json" >/dev/null 2>&1 || true
PATH="$SHIMDIR:$PATH" node -e '' >/dev/null 2>&1 || true
SC_WC=$("$REAL_WC" -l < "$WC_COUNT" | tr -d ' ')
SC_NODE=$("$REAL_WC" -l < "$NODE_COUNT" | tr -d ' ')
if [ "${SC_WC:-0}" -ge 1 ] && [ "${SC_NODE:-0}" -ge 1 ]; then
  ok "SELF-CHECK: wc + node shims genuinely count invocations (wc=$SC_WC node=$SC_NODE)"
else
  printf '\n!! ABORT: counting shims are a NO-OP on this runtime (wc=%s node=%s) — any later 0/1\n' "$SC_WC" "$SC_NODE"
  printf '!! spawn-count assertion would be vacuous (false-green, pipeline-discipline §6).\n'
  rm -rf "$SBX_A" "$SHIMDIR"; exit 2
fi

# RESET, run the REAL hook over the >=25-file tree through the shims.
: > "$WC_COUNT"; : > "$NODE_COUNT"
PATH="$SHIMDIR:$PATH" HOME="$SBX_A" CLAUDE_PROJECT_DIR="$SBX_A" AAL_GATES="pipeline-roles:" \
  bash "$HOOK" >/dev/null 2>&1 || true
RUN_WC=$("$REAL_WC" -l < "$WC_COUNT" | tr -d ' ')
RUN_NODE=$("$REAL_WC" -l < "$NODE_COUNT" | tr -d ' ')
assert_eq "AC1 ZERO per-file wc spawns over the $NFILES-file tree"      "$RUN_WC"   "0"
assert_eq "AC1 EXACTLY ONE node scan over the $NFILES-file tree"        "$RUN_NODE" "1"

# Static companion: the executable CODE has ZERO `wc -c`. NB: the §A-1 PERF *comment* documents the
# OLD `wc -c` shape, so we grep NON-comment lines only (else the doc comment false-fails this) — the
# structural proof is about the CODE, not the documentation (dev deviation DEV-1).
WC_IN_CODE=$(grep -vE '^[[:space:]]*#' "$HOOK" | grep -c 'wc -c' || true)
assert_eq "AC1 static: 0 'wc -c' in executable code (per-file loop gone)"  "${WC_IN_CODE:-x}" "0"
rm -rf "$SBX_A" "$SHIMDIR"
echo ""

# ---------------------------------------------------------------------------------------------
# Part B — AC2: byte-identity semantics (partition + summary) + RED→GREEN + strict boundary
# ---------------------------------------------------------------------------------------------
echo "--- Part B: AC2 semantics byte-identity (partition + summary; RED→GREEN) + boundary ---"

# make_inbox_60 <path> — 60-element inbox; idx 0-9 read:true EXCEPT idx 3 read:false (an old-but-
# UNREAD message in the droppable region — must be kept); idx 10-59 read:true; ~5KB pad/elem so the
# file is > 250000 bytes. cutoff = 60 - 50 = 10.
make_inbox_60() {
  node -e '
    const fs=require("fs"); const a=[];
    for(let i=0;i<60;i++){ const read = i<10 ? (i!==3) : true; a.push({read, idx:i, pad:"x".repeat(5000)}); }
    fs.writeFileSync(process.argv[1], JSON.stringify(a));
  ' "$1"
}
# sorted comma-joined idx list of a JSON array file; length of a JSON array file
idx_of() { node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(a.map(m=>m.idx).sort((x,y)=>x-y).join(","))' "$1" 2>/dev/null; }
len_of() { node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(a.length))' "$1" 2>/dev/null; }

# --- B-partition: run the REAL hook (ONE inbox), assert partition + byte-exact systemMessage ---
SBX_B=$(mktemp -d); mkdir -p "$SBX_B/.claude/teams/TL/inboxes"; : > "$SBX_B/.claude/.autoloop"
INBOX="$SBX_B/.claude/teams/TL/inboxes/team-lead.json"
make_inbox_60 "$INBOX"
OUT=$(HOME="$SBX_B" CLAUDE_PROJECT_DIR="$SBX_B" AAL_GATES="pipeline-roles:" bash "$HOOK" 2>/dev/null || true)
BAK=$(find "$SBX_B/.claude/teams/TL/inboxes" -name 'team-lead.pruned-*.bak' 2>/dev/null | tail -1)
LIVE_LEN=$(len_of "$INBOX"); LIVE_IDX=$(idx_of "$INBOX")
if [ -n "$BAK" ]; then BAK_LEN=$(len_of "$BAK"); BAK_IDX=$(idx_of "$BAK"); else BAK_LEN="NONE"; BAK_IDX="NONE"; fi
assert_eq "AC2 live inbox kept 51 entries"                 "$LIVE_LEN" "51"
assert_eq "AC2 .bak archived 9 entries"                    "$BAK_LEN"  "9"
assert_eq "AC2 dropped set = {0,1,2,4,5,6,7,8,9} exactly"   "$BAK_IDX"  "0,1,2,4,5,6,7,8,9"
case ",$LIVE_IDX," in *",3,"*)  ok "AC2 old-but-UNREAD idx 3 KEPT (never drop an unread message)" ;; *) bad "AC2 idx 3 LOST — live=$LIVE_IDX" ;; esac
case ",$LIVE_IDX," in *",10,"*) case ",$LIVE_IDX," in *",59,"*) ok "AC2 recent tail 10..59 all kept" ;; *) bad "AC2 recent tail 59 missing — live=$LIVE_IDX" ;; esac ;; *) bad "AC2 recent head 10 missing — live=$LIVE_IDX" ;; esac
EXPECT_MSG='{"systemMessage":"INBOX PRUNE GUARD (surfacing-bloat fix — kept ALL unread + recent): | team-lead.json: 60→51 (archived 9 read; kept 1 unread + recent)"}'
assert_eq "AC2 systemMessage byte-exact (leading ' | ', arrow, em-dash, 'kept 1 unread')" "$OUT" "$EXPECT_MSG"
rm -rf "$SBX_B"

# --- B-boundary: the byte gate is STRICT (> 250000). 250000 → NOT pruned; 250001 → pruned. ---
# build_inbox_bytes <path> <target> — a 60-elem all-read array padded to EXACTLY <target> bytes
# (each pad 'x' is 1 JSON byte, so we land exact). >50 elems + old+read ⇒ WOULD prune if size-gated in.
build_inbox_bytes() {
  node -e '
    const fs=require("fs"); const target=+process.argv[2];
    const build=(n)=>{const a=[];for(let i=0;i<60;i++)a.push({read:true,idx:i,pad:"x".repeat(i===0?n:5)});return JSON.stringify(a);};
    let n=0,s=build(0);
    while(Buffer.byteLength(s)<target){n++;s=build(n);}
    fs.writeFileSync(process.argv[1],s);
    process.stdout.write(String(Buffer.byteLength(s)));
  ' "$1" "$2"
}
SBX_LO=$(mktemp -d); mkdir -p "$SBX_LO/.claude/teams/TL/inboxes"; : > "$SBX_LO/.claude/.autoloop"
SZ_LO=$(build_inbox_bytes "$SBX_LO/.claude/teams/TL/inboxes/team-lead.json" 250000)
assert_eq "boundary LO built to exactly 250000 bytes" "$SZ_LO" "250000"
HOME="$SBX_LO" CLAUDE_PROJECT_DIR="$SBX_LO" AAL_GATES="pipeline-roles:" bash "$HOOK" >/dev/null 2>&1 || true
LO_BAK=$(find "$SBX_LO" -name 'team-lead.pruned-*.bak' 2>/dev/null | tail -1)
if [ -z "$LO_BAK" ]; then ok "boundary: 250000 bytes NOT pruned (strict > gate)"; else bad "boundary: 250000 bytes WAS pruned (gate not strict)"; fi
rm -rf "$SBX_LO"

SBX_HI=$(mktemp -d); mkdir -p "$SBX_HI/.claude/teams/TL/inboxes"; : > "$SBX_HI/.claude/.autoloop"
SZ_HI=$(build_inbox_bytes "$SBX_HI/.claude/teams/TL/inboxes/team-lead.json" 250001)
assert_eq "boundary HI built to exactly 250001 bytes" "$SZ_HI" "250001"
HOME="$SBX_HI" CLAUDE_PROJECT_DIR="$SBX_HI" AAL_GATES="pipeline-roles:" bash "$HOOK" >/dev/null 2>&1 || true
HI_BAK=$(find "$SBX_HI" -name 'team-lead.pruned-*.bak' 2>/dev/null | tail -1)
if [ -n "$HI_BAK" ]; then ok "boundary: 250001 bytes IS pruned (over strict gate)"; else bad "boundary: 250001 bytes NOT pruned"; fi
rm -rf "$SBX_HI"

# --- B-RED→GREEN: a broken copy with the keep-all-unread arm REMOVED drops idx 3 (RED); the REAL
#     hook keeps it (GREEN). Mirrors stop-dispatcher.test.sh's deliberately-broken-copy RED-prove. ---
BROKENDIR=$(mktemp -d); BROKEN="$BROKENDIR/prune-broken.sh"
sed 's#((m && m.read !== true) || i >= cutoff)#(i >= cutoff)#' "$HOOK" > "$BROKEN"
if grep -q '((m && m.read !== true) || i >= cutoff)' "$BROKEN"; then
  bad "RED setup: keep-all-unread arm NOT removed — RED proof would be vacuous"
elif grep -q '(i >= cutoff) ? keep.push' "$BROKEN"; then
  ok "RED setup: keep-all-unread arm stripped from the broken copy"
else
  bad "RED setup: broken copy predicate has an unexpected shape"
fi
mkdir -p "$BROKENDIR/lib"; cp "$HOOKS_SRC/lib/activation.sh" "$HOOKS_SRC/lib/parse-json.sh" "$BROKENDIR/lib/"
SBX_R=$(mktemp -d); mkdir -p "$SBX_R/.claude/teams/TL/inboxes"; : > "$SBX_R/.claude/.autoloop"
make_inbox_60 "$SBX_R/.claude/teams/TL/inboxes/team-lead.json"
HOME="$SBX_R" CLAUDE_PROJECT_DIR="$SBX_R" AAL_GATES="pipeline-roles:" bash "$BROKEN" >/dev/null 2>&1 || true
R_IDX=$(idx_of "$SBX_R/.claude/teams/TL/inboxes/team-lead.json")
case ",$R_IDX," in *",3,"*) bad "RED-prove: broken copy KEPT idx 3 — fixture would NOT catch a lost-unread regression" ;; *) ok "RED-prove: broken copy (no keep-unread arm) DROPS idx 3 (row goes RED)" ;; esac
SBX_G=$(mktemp -d); mkdir -p "$SBX_G/.claude/teams/TL/inboxes"; : > "$SBX_G/.claude/.autoloop"
make_inbox_60 "$SBX_G/.claude/teams/TL/inboxes/team-lead.json"
HOME="$SBX_G" CLAUDE_PROJECT_DIR="$SBX_G" AAL_GATES="pipeline-roles:" bash "$HOOK" >/dev/null 2>&1 || true
G_IDX=$(idx_of "$SBX_G/.claude/teams/TL/inboxes/team-lead.json")
case ",$G_IDX," in *",3,"*) ok "GREEN: REAL hook KEEPS the old-but-unread idx 3" ;; *) bad "GREEN: REAL hook dropped idx 3 — live=$G_IDX" ;; esac
rm -rf "$SBX_R" "$SBX_G" "$BROKENDIR"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
