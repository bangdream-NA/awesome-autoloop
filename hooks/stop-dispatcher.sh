#!/usr/bin/env bash
# stop-dispatcher.sh — ONE Stop mount that runs every consolidated Stop check in a single parent
# process, draining stdin ONCE and feeding it to each, isolating per-check failures, and merging
# all block reasons + all systemMessage warns into ONE valid Stop-hook JSON object.
#
# WHY ONE MOUNT: (1) collapses 9 MSYS bash spawns + redundant lib re-sourcing into one process
# (the ~2.6s fixed-tax win, R-10 arch §0.3); (2) GUARANTEES lossless block+warn aggregation — the
# harness's cross-mount systemMessage merge is undocumented (§0.4), so one mount = one deterministic
# merge.
#
# CONTRACT each consolidated check keeps (verbatim — this wave does NOT change what any check DOES):
#   - blocks via stdout {"decision":"block","reason":...} + exit 0  (5 of them), OR
#   - blocks via exit 2 + stderr-as-reason                          (backlog-drift-check only), OR
#   - warns via stdout {"systemMessage":...} + exit 0               (conditional), OR
#   - no-ops (exit 0, empty stdout).
# Each check STILL self-gates on AAL_GATES + aal_is_autoloop_project + node-guard internally, so
# group-deselect / non-autoloop / node-absent are handled INSIDE each child exactly as before.
#
# doctor-dispatched: session-learnings check-stale-agents prune-team-inboxes roster-tripwire ledger-size-guard worktree-count-guard check-unwalked-merges backlog-drift-check backlog-drift-guard oplog-turn-reminder render-finding-playwright-guard
set -uo pipefail
HOOKDIR="$(dirname "$0")"

# --- stdin ONCE: capture the Stop payload and re-feed it to every stdin-consuming child. ---
INPUT=$(cat 2>/dev/null || echo '{}')

# --- The registry: ORDER PRESERVED from the old Stop array (hooks.json Stop group). One line per
#     check = one-line edit to add/remove (future Stop additions fold in here). ---
CHECKS=(
  session-learnings
  check-stale-agents
  prune-team-inboxes
  roster-tripwire
  ledger-size-guard
  worktree-count-guard
  check-unwalked-merges
  backlog-drift-check
  backlog-drift-guard
  oplog-turn-reminder
  render-finding-playwright-guard
)

REASONS=""   # merged decision:block reasons (|-delimited)
WARNS=""     # merged systemMessage warns (|-delimited)
STATE_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}/aal-state"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# PERF (2026-07-10, R-stop-dispatcher-perf-mirror): run every check CONCURRENTLY. Each check is
# independent (own throttle/state files), so wall-time collapses from the SUM of all checks to the
# SLOWEST one. The per-check CONTRACT is unchanged; outputs are read back in REGISTRY ORDER after
# `wait`, so the merged block/warn text is byte-stable regardless of completion order. Each child
# writes its stdout/stderr/rc to state files keyed by $$ (the PARENT dispatcher PID — stable inside
# the subshell, NOT $BASHPID) + the check name, so two concurrent Stop dispatchers (two sessions)
# never clobber each other, and within one dispatcher each check name is unique.
for c in "${CHECKS[@]}"; do
  SCRIPT="$HOOKDIR/${c}.sh"
  [ -f "$SCRIPT" ] || continue
  (
    OUTF="$STATE_DIR/.disp-out.$$.$c"; ERRF="$STATE_DIR/.disp-err.$$.$c"; RCF="$STATE_DIR/.disp-rc.$$.$c"
    RC=0
    # ISOLATION: one crashing/non-zero child never aborts the others (each runs in its own subshell).
    # The child drains the INPUT we feed it (stdin-once); a non-stdin child simply ignores it.
    printf '%s' "$INPUT" | bash "$SCRIPT" >"$OUTF" 2>"$ERRF" || RC=$?
    printf '%s' "$RC" > "$RCF"
  ) &
done
wait 2>/dev/null || true

for c in "${CHECKS[@]}"; do
  SCRIPT="$HOOKDIR/${c}.sh"
  [ -f "$SCRIPT" ] || continue
  OUTF="$STATE_DIR/.disp-out.$$.$c"; ERRF="$STATE_DIR/.disp-err.$$.$c"; RCF="$STATE_DIR/.disp-rc.$$.$c"
  OUT=$(cat "$OUTF" 2>/dev/null || true)
  ERR=$(cat "$ERRF" 2>/dev/null || true)
  RC=$(cat "$RCF" 2>/dev/null || echo 0)
  rm -f "$OUTF" "$ERRF" "$RCF" 2>/dev/null || true

  if [ "$RC" = "2" ]; then
    # exit-2 block (backlog-drift-check): stderr IS the reason.
    [ -n "$ERR" ] && REASONS="${REASONS}${REASONS:+ | }${ERR}"
  elif [ -n "$OUT" ]; then
    # JSON child: extract decision/reason/systemMessage in ONE node call.
    PARSED=$(printf '%s' "$OUT" | node -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(d);process.stdout.write((o.decision==="block"&&o.reason?("R\t"+o.reason+"\n"):"")+(o.systemMessage?("W\t"+o.systemMessage+"\n"):""))}catch{}})' 2>/dev/null)
    while IFS=$'\t' read -r tag val; do
      [ "$tag" = "R" ] && [ -n "$val" ] && REASONS="${REASONS}${REASONS:+ | }${val}"
      [ "$tag" = "W" ] && [ -n "$val" ] && WARNS="${WARNS}${WARNS:+ | }${val}"
    done <<< "$PARSED"
  fi
  # RC 0 / empty OUT (no-op or crash with no usable output) → contributes nothing. Loop continues.
done

# --- Emit ONE merged object through the BLOCK CHANNEL. ---
# FIX R-14 (refutes R-10 §Y-3): a single Stop object carrying BOTH decision:block AND a top-level
# systemMessage is NOT honored by this harness — it consumes ONLY the toast and DROPS the block
# injection (lead's first-hand probe; the §0.4 web-doc schema claim was never live-verified). So
# EVERYTHING goes through the block channel: reasons first, then warns folded into the reason with
# the same ` | ` delimiter used for the within-bucket merge. The object NEVER carries top-level
# systemMessage. Full texts reach Claude. (HOME ~/.claude/hooks/stop-dispatcher.sh:67-71 referent.)
# ALWAYS stdout + exit 0 — NEVER exit 2 (exit-2 makes the harness ignore our merged stdout).
ALL="$REASONS"
[ -n "$WARNS" ] && ALL="${ALL}${ALL:+ | }${WARNS}"
if [ -n "$ALL" ]; then
  node -e 'process.stdout.write(JSON.stringify({decision:"block",reason:process.argv[1]}))' "$ALL"
fi
# all no-op → emit NOTHING (clean silent allow); the harness accepts empty stdout + exit 0.
exit 0
