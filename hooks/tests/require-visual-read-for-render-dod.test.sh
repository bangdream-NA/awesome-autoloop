#!/usr/bin/env bash
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/require-visual-read-for-render-dod.mjs"
PASS=0; FAIL=0; FAILURES=()

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPD="$TESTS_DIR/.tmp-visualgate-$"
# The gate keys on `/projects/<slug>/`, where <slug> is homeDir() with every non-alphanumeric
# byte replaced by a dash. Derive it the same way rather than hard-coding one machine's value.
HOME_SLUG="$(printf '%s' "${USERPROFILE:-$HOME}" | tr -c 'A-Za-z0-9' '-')"
PDIR="projects/$HOME_SLUG"
mkdir -p "$TMPD/oplog" "$TMPD/oplog-na" "$TMPD/$PDIR"
trap 'rm -rf "$TMPD"' EXIT

ROW='- 2026-07-09 · R-foo · live page render DoD-VERIFIED LIVE — screenshot visual read: layout fine, empty state clear'
ROW_NA='- 2026-07-09 · R-bar · render page DoD-VERIFIED — VISUAL-N/A: surface auth-gated, live is unreachable'
printf '# oplog\n%s\n' "$ROW"    > "$TMPD/oplog/autoloop-log-2026-07-09.md"
printf '# oplog\n%s\n' "$ROW_NA" > "$TMPD/oplog-na/autoloop-log-2026-07-09.md"

node -e '
const fs = require("fs"); const d = process.argv[1]; const ROW = process.argv[2]; const P = process.argv[3];
fs.writeFileSync(d + "/" + P + "/t1.jsonl",
  JSON.stringify({ type: "tool_result", content: "quoted: " + ROW }) + "\n");
fs.writeFileSync(d + "/" + P + "/t2.jsonl",
  JSON.stringify({ type: "tool_use", name: "Bash", input: { command: "cat >> oplog.md << EOF\n" + ROW + "\nEOF" } }) + "\n");
const b64 = "iVBORw0KGgoAAAANSUhEUg".repeat(15);
fs.writeFileSync(d + "/" + P + "/t3.jsonl",
  fs.readFileSync(d + "/" + P + "/t2.jsonl", "utf8")
  + "{\"type\":\"tool_result\",\"content\":[{\"type\":\"image\",\"source\":{\"media_type\":\"image/png\",\"data\":\"" + b64 + "\"}}]}\n");
' "$(cygpath -m "$TMPD" 2>/dev/null || echo "$TMPD")" "$ROW" "$PDIR"

WTMPD="$(cygpath -m "$TMPD" 2>/dev/null || echo "$TMPD")"
is_block() {
  printf '{"transcript_path":"%s"}' "$WTMPD/$PDIR/$2" \
    | AAL_VISUALGATE_DIR="$WTMPD/$1" node "$HOOK" 2>&1 | grep -q '"decision":"block"'
}
block() { if is_block "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-BLOCK: $1"); fi; }
allow() { if is_block "$2" "$3"; then FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-ALLOW-BUT-BLOCKED: $1"); else PASS=$((PASS+1)); fi; }

allow "foreign claim (row only READ into context)"      oplog    t1.jsonl
block "authored claim, no image-read"                   oplog    t2.jsonl
allow "authored claim + genuine image-read"             oplog    t3.jsonl
allow "VISUAL-N/A escape on the claim row"              oplog-na t2.jsonl

mkdir -p "$TMPD/oplog-mixed" "$TMPD/oplog-mixed-own"
MY_PLAIN='- 2026-07-09 · harness ops row (hook fixes, no rendering-surface claim of any kind)'
FOREIGN_CLAIM='  og-wave render DoD-VERIFIED LIVE — screenshot visual read, PNG confirmed (written by a foreign session)'
printf '# oplog\n%s\n%s\n' "$MY_PLAIN" "$FOREIGN_CLAIM" > "$TMPD/oplog-mixed/autoloop-log-2026-07-10.md"
printf '# oplog\n%s\n%s\n' "$ROW" "$FOREIGN_CLAIM"      > "$TMPD/oplog-mixed-own/autoloop-log-2026-07-10.md"
node -e '
const fs = require("fs"); const d = process.argv[1]; const MY = process.argv[2]; const P = process.argv[3];
fs.writeFileSync(d + "/" + P + "/t4.jsonl",
  JSON.stringify({ type: "tool_use", name: "Bash", input: { command: "cat >> oplog.md << EOF\n" + MY + "\nEOF" } }) + "\n");
' "$WTMPD" "$MY_PLAIN" "$PDIR"
allow "mixed segment: foreign claim line glued after MY plain row" oplog-mixed     t4.jsonl
block "mixed segment: MY OWN claim line still enforced"            oplog-mixed-own t2.jsonl

is_block_sid() {
  printf '{"transcript_path":"%s","session_id":"%s"}' "$WTMPD/$PDIR/$2" "$3" \
    | AAL_VISUALGATE_DIR="$WTMPD/$1" node "$HOOK" 2>&1 | grep -q '"decision":"block"'
}
block_sid() { if is_block_sid "$2" "$3" "$4"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-BLOCK: $1"); fi; }
allow_sid() { if is_block_sid "$2" "$3" "$4"; then FAIL=$((FAIL+1)); FAILURES+=("EXPECTED-ALLOW-BUT-BLOCKED: $1"); else PASS=$((PASS+1)); fi; }

mkdir -p "$TMPD/oplog-nabare" "$TMPD/oplog-na2" "$TMPD/oplog-naked" "$TMPD/oplog-gated" "$TMPD/oplog-datamerge"
printf '# oplog\n- 2026-07-17 · R-baz · render page DoD-VERIFIED — VISUAL-N/A:\n' > "$TMPD/oplog-nabare/autoloop-log-2026-07-17-deadbeef.md"
printf '# oplog\n%s\n' "$ROW_NA" > "$TMPD/oplog-na2/autoloop-log-2026-07-17-deadbeef.md"
printf '# oplog\n- 2026-07-17 · R-ui-thing MERGED #912 — button layout wave merged\n' > "$TMPD/oplog-naked/autoloop-log-2026-07-17-deadbeef.md"
printf '# oplog\n- 2026-07-17 · R-ui-thing MERGED #912 — button layout wave merged\n- 2026-07-17 · #912 DoD-GATED (a CDN challenge blocks the lead IP; walk it once that is lifted)\n' > "$TMPD/oplog-gated/autoloop-log-2026-07-17-deadbeef.md"
printf '# oplog\n- 2026-07-17 · R-data-thing MERGED #913 — data-pipeline lint cleanup wave\n' > "$TMPD/oplog-datamerge/autoloop-log-2026-07-17-deadbeef.md"

printf '{"type":"assistant","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo ops"}}]}}\n' > "$TMPD/$PDIR/t8.jsonl"
printf '{"type":"assistant","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_use","name":"Edit","input":{"new_string":"- 2026-07-17 · R-baz · render page DoD-VERIFIED — VISUAL-N/A:"}}]}}\n' > "$TMPD/$PDIR/t12-nabare.jsonl"
printf '{"type":"assistant","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_use","name":"Edit","input":{"new_string":"- 2026-07-17 · R-ui-thing MERGED #912 — button layout wave merged"}}]}}\n' > "$TMPD/$PDIR/t12-naked.jsonl"
block_sid "bare VISUAL-N/A (no reason) no longer exempts (authored)"  oplog-nabare    t12-nabare.jsonl deadbeef-0000
allow_sid "substantive VISUAL-N/A still exempts (via sid8 owner)"    oplog-na2       t8.jsonl deadbeef-0000
block_sid "naked render merge authored here: no visual evidence"      oplog-naked     t12-naked.jsonl deadbeef-0000
allow_sid "own-sid8 never-seen row (pre-reboot history) opens"        oplog-naked     t8.jsonl deadbeef-0000
allow_sid "naked merge cleared by DoD-GATED row"                     oplog-gated     t8.jsonl deadbeef-0000
allow_sid "non-render merge needs no visual"                         oplog-datamerge t8.jsonl deadbeef-0000
allow_sid "foreign sid does not inherit (no ownership, not authored)" oplog-naked    t8.jsonl 99999999-0000

mkdir -p "$TMPD/oplog-xs" "$TMPD/oplog-xsbuild"
XROW='- 2026-07-17 · MERGE PR #999 render wave DoD-VERIFIED visual read, homepage hero layout checked'
printf '# oplog\n%s\n' "$XROW" > "$TMPD/oplog-xs/autoloop-log-2026-07-17-cafebabe.md"
printf '# oplog\n- 2026-07-18 · read-only analysis row\n' > "$TMPD/oplog-xs/autoloop-log-2026-07-18-aaaaaaaa.md"
# 🔴 This was `touch -d '2 hours ago' … 2>/dev/null || true`. `touch -d` is GNU-only, so on macOS
# the stamp was never applied — and the suppression made that invisible, leaving the arms below to
# pass against an mtime nobody set. `touch -t CCYYMMDDhhmm.SS` is POSIX; the instant is computed as
# an absolute epoch first because `date -d` is the same GNU-only extension (BSD spells it `date -r`,
# and the twin is kept on one line). This fixture keeps its own counters and does not source
# _lib.sh, so aal_touch_rel is inlined here rather than imported.
# `touch -t` reads LOCAL time, so the stamp is formatted without `-u` — building it in UTC puts the
# mtime off by the host's offset, and a CI runner (UTC) cannot tell the two apart.
XS_EPOCH=$(( $(date -u +%s) - 7200 ))
XS_STAMP="$(date -d "@$XS_EPOCH" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$XS_EPOCH" +%Y%m%d%H%M.%S)"
touch -t "$XS_STAMP" "$TMPD/oplog-xs/autoloop-log-2026-07-17-cafebabe.md"
node -e '
const fs = require("fs"); const d = process.argv[1]; const XROW = process.argv[2]; const P = process.argv[3];
fs.writeFileSync(d + "/" + P + "/t7.jsonl",
  JSON.stringify({ type: "assistant", sessionId: "aaaaaaaa-1111-2222-3333-444444444444",
    message: { content: [{ type: "tool_use", name: "Bash", input: { command: "node analyze.js" } }] } }) + "\n");
fs.writeFileSync(d + "/" + P + "/mk-cafebabe.js",
  "const fs=require(\"fs\");fs.writeFileSync(process.argv[2],JSON.stringify({type:\"assistant\",sessionId:\"cafebabe-0000-0000-0000-000000000000\",message:{content:[{type:\"tool_use\",name:\"Edit\",input:{new_string:process.argv[3]}}]}})+\"\\n\");");
' "$WTMPD" "$XROW" "$PDIR"

allow_sid "inherited claim, authoring transcript ABSENT -> fail-open"  oplog-xs t7.jsonl aaaaaaaa-1111
node "$WTMPD/$PDIR/mk-cafebabe.js" "$WTMPD/$PDIR/cafebabe-0000-0000-0000-000000000000.jsonl" "$XROW"
block_sid "inherited claim, authoring transcript readable WITHOUT image" oplog-xs t7.jsonl aaaaaaaa-1111
printf '{"type":"assistant","sessionId":"cafebabe-0000-0000-0000-000000000000","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"Z:/scratch/hero.png"}}]}}\n' >> "$TMPD/$PDIR/cafebabe-0000-0000-0000-000000000000.jsonl"
allow_sid "inherited claim, authoring transcript WITH image-Read"       oplog-xs t7.jsonl aaaaaaaa-1111
rm -f "$TMPD/$PDIR/cafebabe-0000-0000-0000-000000000000.jsonl"
printf '# oplog\n- 2026-07-18 · MERGED #914 — infra guard build hardening merge row\n' > "$TMPD/oplog-xsbuild/autoloop-log-2026-07-18-aaaaaaaa.md"
allow_sid "infra merge row with the word build is NOT a render wave"    oplog-xsbuild t7.jsonl aaaaaaaa-1111

mkdir -p "$TMPD/oplog-prosemerge" "$TMPD/oplog-echo"
printf '# oplog\n- 2026-07-18 · planrev r1 verdict:MEDIUM = #636 already merged a prose correction; the §2 fourth-layer visual-consistency AC is missing\n' > "$TMPD/oplog-prosemerge/autoloop-log-2026-07-18-deadbeef.md"
allow_sid "prose mention of a sibling merged PR is not a merge action"  oplog-prosemerge t8.jsonl deadbeef-0000
ECHOROW='- 2026-07-17 · R-baz · render page DoD-VERIFIED visual read, homepage hero layout checked fine'
printf '# oplog\n%s\n' "$ECHOROW" > "$TMPD/oplog-echo/autoloop-log-2026-07-17-deadbeef.md"
{ printf '{"type":"assistant","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo ops"}}]}}\n';
  printf '{"type":"user","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_result","content":"%s"}]}}\n' "$ECHOROW"; } > "$TMPD/$PDIR/t9.jsonl"
allow_sid "own historical claim seen only as read-echo (reboot) opens"  oplog-echo t9.jsonl deadbeef-0000

AHDR='### [DONE 2026-07-19] R-fake-hero-btn · DoD-VERIFIED (LIVE-confirmed visual) · homepage hero button render wave'
mkdir -p "$TMPD/oplog-arch" "$TMPD/oplog-archna"
printf '# oplog\n- 2026-07-19 · ops housekeeping row\n' > "$TMPD/oplog-arch/autoloop-log-2026-07-19-deadbeef.md"
printf '%s\n- log: archived after wave\n' "$AHDR" > "$TMPD/oplog-arch/BACKLOG-archive.md"
printf '# oplog\n- 2026-07-19 · ops housekeeping row\n' > "$TMPD/oplog-archna/autoloop-log-2026-07-19-deadbeef.md"
printf '%s\n- DoD evidence: VISUAL-N/A: this card is a synthetic test fixture with no real rendering surface to capture\n' "$AHDR" > "$TMPD/oplog-archna/BACKLOG-archive.md"
printf '{"type":"assistant","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_use","name":"Edit","input":{"new_string":"%s"}}]}}\n' "$AHDR" > "$TMPD/$PDIR/t10.jsonl"
block_sid "archived render card claims DoD, written here, no image"     oplog-arch   t10.jsonl deadbeef-0000
allow_sid "archived render card with substantive VISUAL-N/A in body"    oplog-archna t10.jsonl deadbeef-0000
allow_sid "historical archive block (not written by this transcript)"   oplog-arch   t8.jsonl  deadbeef-0000
cp "$TMPD/$PDIR/t10.jsonl" "$TMPD/$PDIR/t11.jsonl"
printf '{"type":"assistant","sessionId":"deadbeef-0000","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"Z:/scratch/dod-hero.png"}}]}}\n' >> "$TMPD/$PDIR/t11.jsonl"
allow_sid "archived render card written here WITH adjacent image-Read"  oplog-arch   t11.jsonl deadbeef-0000

name="$(basename "$0")"
if [ "$FAIL" -eq 0 ]; then
  echo "  $name: PASS ($PASS/$PASS)"
  exit 0
else
  echo "  $name: FAIL ($PASS pass, $FAIL fail)"
  for f in "${FAILURES[@]}"; do echo "    - $f"; done
  exit 1
fi
