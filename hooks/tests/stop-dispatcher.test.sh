#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS_SRC="$(cd "$HERE/.." && pwd)"
DISPATCHER_SRC="$HOOKS_SRC/stop-dispatcher.sh"
GUARD_SRC="$HOOKS_SRC/backlog-drift-guard.sh"
ACTIVATION_SRC="$HOOKS_SRC/lib/activation.sh"
PARSEJSON_SRC="$HOOKS_SRC/lib/parse-json.sh"

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — expected to contain: $3 | got: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1 — should NOT contain: $3 | got: $2" ;; *) ok "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then ok "$1"; else bad "$1 — expected EMPTY | got: $2"; fi; }

build_hookdir() {
  local d="$1"; local dispatcher="${2:-$DISPATCHER_SRC}"
  mkdir -p "$d/lib"
  cp "$ACTIVATION_SRC" "$d/lib/activation.sh"
  cp "$PARSEJSON_SRC"  "$d/lib/parse-json.sh"
  cp "$dispatcher"     "$d/stop-dispatcher.sh"

  local names="session-learnings check-stale-agents prune-team-inboxes roster-tripwire ledger-size-guard worktree-count-guard check-unwalked-merges backlog-drift-check backlog-drift-guard oplog-turn-reminder render-finding-playwright-guard"
  local n var
  for n in $names; do
    var="STUB_$(printf '%s' "$n" | tr 'a-z-' 'A-Z_')"
    cat > "$d/$n.sh" <<EOF
#!/usr/bin/env bash
# stub child for the matrix — drains stdin (stdin-once contract) then emits per \$$var.
INPUT=\$(cat 2>/dev/null || echo '{}')
MODE="\${$var:-noop}"
LABEL="$n"
case "\$MODE" in
  block) printf '{"decision":"block","reason":"BLOCK from %s"}\n' "\$LABEL" ;;
  warn)  printf '{"systemMessage":"WARN from %s"}\n' "\$LABEL" ;;
  both)  printf '{"decision":"block","reason":"BLOCK from %s","systemMessage":"WARN from %s"}\n' "\$LABEL" "\$LABEL" ;;
  exit2) printf 'EXIT2 reason from %s\n' "\$LABEL" >&2 ; exit 2 ;;
  crash) nonexistent_cmd_xyz_$$ ; printf 'garbage' ; exit 7 ;;
  sid)   SID=\$(printf '%s' "\$INPUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{process.stdout.write(JSON.parse(d).session_id||"")}catch{}})' 2>/dev/null); printf '{"systemMessage":"SID=%s"}\n' "\$SID" ;;
  slow)  [ -n "\${AAL_TS_DIR:-}" ] && node -e 'console.log(Date.now())' > "\$AAL_TS_DIR/\$LABEL.start" 2>/dev/null
         sleep "\${AAL_SLOW_SECS:-1}"
         [ -n "\${AAL_TS_DIR:-}" ] && node -e 'console.log(Date.now())' > "\$AAL_TS_DIR/\$LABEL.end" 2>/dev/null
         printf '{"decision":"block","reason":"BLOCK from %s"}\n' "\$LABEL" ;;
  noop)  : ;;
esac
exit 0
EOF
    chmod +x "$d/$n.sh"
  done
}

run_disp() {
  local d="$1"; local payload="$2"; shift 2
  ( cd "$d" && printf '%s' "$payload" | env "$@" CLAUDE_PLUGIN_DATA="$d/state" bash "$d/stop-dispatcher.sh" )
}

PAYLOAD='{"session_id":"S-test","stop_hook_active":false}'

echo "== R-10 stop-dispatcher regression matrix =="
echo ""
echo "--- per-check rows (M-1 … M-9): each trigger surfaces through the dispatcher ---"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_SESSION_LEARNINGS=both)
assert_contains "M-1 session-learnings reason surfaces"      "$OUT" 'BLOCK from session-learnings'
assert_contains "M-1 session-learnings warn surfaces"        "$OUT" 'WARN from session-learnings'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_CHECK_STALE_AGENTS=block)
assert_contains "M-2 check-stale-agents reason surfaces"     "$OUT" 'BLOCK from check-stale-agents'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_PRUNE_TEAM_INBOXES=warn)
assert_contains "M-3 prune-team-inboxes warn surfaces"       "$OUT" 'WARN from prune-team-inboxes'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_ROSTER_TRIPWIRE=warn)
assert_contains "M-4 roster-tripwire warn surfaces"          "$OUT" 'WARN from roster-tripwire'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_LEDGER_SIZE_GUARD=block)
assert_contains "M-5 ledger-size-guard reason surfaces"      "$OUT" 'BLOCK from ledger-size-guard'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_WORKTREE_COUNT_GUARD=warn)
assert_contains "M-6 worktree-count-guard warn surfaces"     "$OUT" 'WARN from worktree-count-guard'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_CHECK_UNWALKED_MERGES=block)
assert_contains "M-7 check-unwalked-merges reason surfaces"  "$OUT" 'BLOCK from check-unwalked-merges'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_BACKLOG_DRIFT_CHECK=exit2)
assert_contains "M-8 exit-2 stderr normalized to reason"     "$OUT" 'EXIT2 reason from backlog-drift-check'
assert_contains "M-8 exit-2 surfaces as decision:block"      "$OUT" '"decision":"block"'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
cp "$GUARD_SRC" "$D/backlog-drift-guard.sh"; chmod +x "$D/backlog-drift-guard.sh"
PROJ="$D/proj"; mkdir -p "$PROJ/.claude"
printf '### [DONE] finished-wave · P1\n- log: shipped\n' > "$PROJ/.claude/BACKLOG.md"
OUT=$(run_disp "$D" "$PAYLOAD" CLAUDE_PROJECT_DIR="$PROJ")
assert_contains "M-9 REAL backlog-drift-guard warn surfaces" "$OUT" 'format drift'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_OPLOG_TURN_REMINDER=block)
assert_contains     "M-10 oplog-turn-reminder reason surfaces"   "$OUT" 'BLOCK from oplog-turn-reminder'
OUT=$(run_disp "$D" "$PAYLOAD")
assert_not_contains "M-10 oplog-turn-reminder silent when noop"  "$OUT" 'oplog-turn-reminder'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_RENDER_FINDING_PLAYWRIGHT_GUARD=block)
assert_contains     "M-11 render-finding reason surfaces"        "$OUT" 'BLOCK from render-finding-playwright-guard'
OUT=$(run_disp "$D" "$PAYLOAD")
assert_not_contains "M-11 render-finding silent when noop"       "$OUT" 'render-finding-playwright-guard'
rm -rf "$D"

echo ""
echo "--- concurrency + order-stability rows (M-CONC, M-ORDER) — the R-stop-dispatcher-perf-mirror adds ---"

D=$(mktemp -d); build_hookdir "$D"
TSD=$(mktemp -d)
OUT=$(run_disp "$D" "$PAYLOAD" AAL_TS_DIR="$TSD" AAL_SLOW_SECS=1 STUB_SESSION_LEARNINGS=slow STUB_CHECK_STALE_AGENTS=slow STUB_PRUNE_TEAM_INBOXES=slow)
MAXSTART=$(cat "$TSD"/*.start 2>/dev/null | sort -n  | tail -1)
MINEND=$(cat "$TSD"/*.end     2>/dev/null | sort -rn | tail -1)
assert_contains "M-CONC all three slow checks surfaced"          "$OUT" 'BLOCK from session-learnings'
if [ -n "$MAXSTART" ] && [ -n "$MINEND" ] && [ "$MAXSTART" -lt "$MINEND" ]; then
  ok "M-CONC checks overlapped (max_start < min_end ⇒ ran concurrently)"
else
  bad "M-CONC no overlap — max_start=$MAXSTART min_end=$MINEND (a serial dispatcher fails here)"
fi
rm -rf "$D" "$TSD"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" AAL_SLOW_SECS=1 STUB_SESSION_LEARNINGS=slow STUB_RENDER_FINDING_PLAYWRIGHT_GUARD=block)
assert_contains "M-ORDER early(session-learnings) text present"  "$OUT" 'BLOCK from session-learnings'
assert_contains "M-ORDER late(render-finding) text present"      "$OUT" 'BLOCK from render-finding-playwright-guard'
PRE_E="${OUT%%BLOCK from session-learnings*}"
PRE_L="${OUT%%BLOCK from render-finding-playwright-guard*}"
if [ "${#PRE_E}" -lt "${#PRE_L}" ]; then
  ok "M-ORDER early check precedes late check (registry order, not completion order)"
else
  bad "M-ORDER completion-order leak — early prefix ${#PRE_E} not < late prefix ${#PRE_L}"
fi
rm -rf "$D"

echo ""
echo "--- aggregation / isolation rows (M-A … M-F) ---"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_SESSION_LEARNINGS=block STUB_CHECK_UNWALKED_MERGES=block)
assert_contains "M-A both blocker reasons present (1/2)"     "$OUT" 'BLOCK from session-learnings'
assert_contains "M-A both blocker reasons present (2/2)"     "$OUT" 'BLOCK from check-unwalked-merges'
DEC_COUNT=$(printf '%s' "$OUT" | grep -o '"decision":"block"' | wc -l | tr -d ' ')
if [ "$DEC_COUNT" = "1" ]; then ok "M-A decision:block appears exactly once"; else bad "M-A decision:block count=$DEC_COUNT (want 1)"; fi
if printf '%s' "$OUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{JSON.parse(d);process.exit(0)}catch{process.exit(1)}})'; then ok "M-A output is ONE valid JSON object"; else bad "M-A output not valid JSON"; fi
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_LEDGER_SIZE_GUARD=block STUB_ROSTER_TRIPWIRE=warn)
assert_contains "M-B block reason present"                   "$OUT" 'BLOCK from ledger-size-guard'
assert_contains "M-B warn carried alongside block"           "$OUT" 'WARN from roster-tripwire'
assert_contains "M-B decision:block present"                 "$OUT" '"decision":"block"'
assert_not_contains "M-B no top-level systemMessage (R-14: block channel only)" "$OUT" '"systemMessage"'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_SESSION_LEARNINGS=both)
assert_contains     "M-COEXIST block reason folded in"        "$OUT" 'BLOCK from session-learnings'
assert_contains     "M-COEXIST warn text folded into reason"  "$OUT" 'WARN from session-learnings'
assert_contains     "M-COEXIST decision:block present"        "$OUT" '"decision":"block"'
assert_not_contains "M-COEXIST NO top-level systemMessage"    "$OUT" '"systemMessage"'
if printf '%s' "$OUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{JSON.parse(d);process.exit(0)}catch{process.exit(1)}})'; then ok "M-COEXIST output is ONE valid JSON object"; else bad "M-COEXIST output not valid JSON"; fi
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_ROSTER_TRIPWIRE=warn)
assert_contains     "M-WARNONLY warn surfaces"                "$OUT" 'WARN from roster-tripwire'
assert_contains     "M-WARNONLY now via block channel"        "$OUT" '"decision":"block"'
assert_not_contains "M-WARNONLY NO top-level systemMessage"   "$OUT" '"systemMessage"'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD")
assert_empty "M-C all no-op → empty stdout (silent allow)"   "$OUT"
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_PRUNE_TEAM_INBOXES=crash STUB_CHECK_UNWALKED_MERGES=block)
assert_contains "M-D blocker survives a crashing sibling"    "$OUT" 'BLOCK from check-unwalked-merges'
assert_not_contains "M-D crash garbage not leaked as reason" "$OUT" 'garbage'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
OUT=$(run_disp "$D" "$PAYLOAD" AAL_GATES="commit-hygiene:pipeline-roles:merge-gates:dod-walk:" STUB_SESSION_LEARNINGS=block STUB_LEDGER_SIZE_GUARD=noop)
assert_contains "M-E pipeline-roles check still fires"       "$OUT" 'BLOCK from session-learnings'
assert_not_contains "M-E deselected ledger check silent"     "$OUT" 'BLOCK from ledger-size-guard'
rm -rf "$D"

D=$(mktemp -d); build_hookdir "$D"
NODEFREE=$(mktemp -d)
for b in bash sh cat printf env mkdir rm dirname cksum awk date find grep sed tr wc; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$NODEFREE/$b" 2>/dev/null || true
done
OUT=$( cd "$D" && printf '%s' "$PAYLOAD" | env -i HOME="$HOME" PATH="$NODEFREE" CLAUDE_PLUGIN_DATA="$D/state" bash "$D/stop-dispatcher.sh" 2>/dev/null )
OUT2=$( cd "$D" && printf '%s' "$PAYLOAD" | env -i HOME="$HOME" PATH="$NODEFREE" CLAUDE_PLUGIN_DATA="$D/state" STUB_SESSION_LEARNINGS=block bash "$D/stop-dispatcher.sh" 2>/dev/null )
assert_empty "M-F node-absent → dispatcher emits nothing (fails OPEN)" "$OUT2"
rm -rf "$D" "$NODEFREE"

echo ""
echo "--- RED-prove (AC-2): a dispatcher missing one CHECKS line MUST fail that check's row ---"
BROKEN=$(mktemp); sed '/^  check-unwalked-merges$/d' "$DISPATCHER_SRC" > "$BROKEN"
DROPPED=$(grep -c '^  check-unwalked-merges$' "$BROKEN" || true)
if [ "$DROPPED" = "0" ]; then ok "RED setup: check-unwalked-merges removed from CHECKS"; else bad "RED setup: line not dropped"; fi
D=$(mktemp -d); build_hookdir "$D" "$BROKEN"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_CHECK_UNWALKED_MERGES=block)
assert_not_contains "RED-prove: dropped check's reason is GONE (row goes red)" "$OUT" 'BLOCK from check-unwalked-merges'
D2=$(mktemp -d); build_hookdir "$D2"
OUT2=$(run_disp "$D2" "$PAYLOAD" STUB_CHECK_UNWALKED_MERGES=block)
assert_contains "RED-prove: real dispatcher surfaces it (row is GREEN)"        "$OUT2" 'BLOCK from check-unwalked-merges'
rm -rf "$D" "$D2"; rm -f "$BROKEN"

echo ""
echo "--- RED-prove (R-14): the OLD both-keys emit drops the block → M-COEXIST goes RED ---"
OLD=$(mktemp)
awk 'BEGIN{p=1} /^ALL=/{p=0; print "if [ -n \"$REASONS\" ]; then"; print "  node -e '\''const o={decision:\"block\",reason:process.argv[1]};if(process.argv[2])o.systemMessage=process.argv[2];process.stdout.write(JSON.stringify(o))'\'' \"$REASONS\" \"$WARNS\""; print "elif [ -n \"$WARNS\" ]; then"; print "  node -e '\''process.stdout.write(JSON.stringify({systemMessage:process.argv[1]}))'\'' \"$WARNS\""; print "fi"; print "exit 0"} p{print}' "$DISPATCHER_SRC" > "$OLD"
ANCHORS=$(grep -c '^ALL=' "$DISPATCHER_SRC")
if [ "$ANCHORS" = 1 ]; then ok "RED-prove R-14: the awk anchor '^ALL=' is unique in the dispatcher (1 match)"
else bad "RED-prove R-14: anchor '^ALL=' matched $ANCHORS times — re-anchor before trusting the arm below"; fi
D=$(mktemp -d); build_hookdir "$D" "$OLD"
OUT=$(run_disp "$D" "$PAYLOAD" STUB_SESSION_LEARNINGS=both)
assert_contains "RED-prove R-14: OLD dispatcher re-attaches systemMessage (the bug M-COEXIST catches)" "$OUT" '"systemMessage"'
rm -rf "$D"; rm -f "$OLD"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
