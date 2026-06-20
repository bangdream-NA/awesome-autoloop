#!/usr/bin/env bash
# prune-team-inboxes.sh — Stop / PostToolUse(SendMessage) hook. Cap team inbox size so
# teammate→team-lead message SURFACING doesn't break.
#
# ROOT CAUSE: a persistent team's `~/.claude/teams/<team>/inboxes/team-lead.json` is NEVER
# auto-pruned; across many sessions it can grow to thousands of msgs / multiple MB. At that
# scale the harness still WRITES incoming messages + marks them read=true, but STOPS injecting
# them into the team-lead's conversation (no separate delivery cursor — the `read` flag IS the
# delivery state). Result: agents look "stalled" (no message) while actually delivering to disk
# → the team-lead wrongly shuts down WORKING agents. Resetting the inbox to [] flushes the
# backlog.
#
# STRATEGY: for any inbox file >250KB, keep ALL unread (read!==true) + the most-recent KEEP
# entries; archive the dropped (old, read) ones to <file>.pruned-<ts>.bak. NEVER drop an unread
# message. Size-gated so it's a near-no-op on a healthy inbox.
set -eu
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
KEEP=50
# Surfacing breaks on SIZE (the harness stops injecting once the inbox file is large),
# NOT on count — a few VERBOSE messages (long agent dispatches/reports) can blow past the
# break at low msg counts. So the byte gate is authoritative.
THRESH_BYTES=250000
CHANGED=""
for f in "$HOME"/.claude/teams/*/inboxes/*.json; do
  [ -f "$f" ] || continue
  sz=$(wc -c < "$f" 2>/dev/null || echo 0)
  [ "${sz:-0}" -gt "$THRESH_BYTES" ] || continue
  out=$(KEEP="$KEEP" node -e '
    const fs=require("fs"), path=require("path");
    const f=process.argv[1], KEEP=+process.env.KEEP;
    let a; try{a=JSON.parse(fs.readFileSync(f,"utf8"))}catch(e){process.exit(0)}
    if(!Array.isArray(a)||a.length<=KEEP){process.exit(0)}
    const cutoff=a.length-KEEP;
    const keep=[], drop=[];
    a.forEach((m,i)=>{ ((m && m.read!==true) || i>=cutoff) ? keep.push(m) : drop.push(m); });
    if(!drop.length){process.exit(0)}
    const ts=new Date().toISOString().replace(/[:.]/g,"-");
    fs.writeFileSync(f.replace(/\.json$/,".pruned-"+ts+".bak"), JSON.stringify(drop));
    // C-17: atomic write (temp + rename) so a concurrent Stop+SendMessage RMW on the SAME
    // inbox cannot interleave and lose an unread append. rename is atomic on the same fs (same dir).
    const tmp=f+".tmp-"+process.pid+"-"+Date.now();
    fs.writeFileSync(tmp, JSON.stringify(keep));
    fs.renameSync(tmp, f);
    const unread=keep.filter(m=>m&&m.read!==true).length;
    process.stdout.write(path.basename(f)+": "+a.length+"→"+keep.length+" (archived "+drop.length+" read; kept "+unread+" unread + recent)");
  ' "$f" 2>/dev/null || true)
  [ -n "$out" ] && CHANGED="${CHANGED} | ${out}"
done
if [ -n "$CHANGED" ]; then
  printf '{"systemMessage":"INBOX PRUNE GUARD (surfacing-bloat fix — kept ALL unread + recent):%s"}' "$CHANGED"
fi
exit 0
