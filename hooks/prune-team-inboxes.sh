#!/usr/bin/env bash
# prune-team-inboxes.sh — Stop / PostToolUse(SendMessage) hook. Cap team inbox size so
# teammate→team-lead message SURFACING doesn't break.
#
# ROOT CAUSE: a persistent team's `~/.claude/teams/<team>/inboxes/team-lead.json` is NEVER
# auto-pruned; across many sessions it can grow to thousands of msgs / multiple MB. At that
# scale the harness still WRITES incoming messages + marks them read=true, but STOPS injecting
# them into the team-lead's conversation (no separate delivery cursor — the `read` flag IS the
# delivery state). Result: agents look "stalled" (no message) while actually delivering to disk
# → the team-lead wrongly shuts down WORKING agents. Resetting the inbox to [] flushes the backlog.
#
# STRATEGY: for any inbox file >250KB, keep ALL unread (read!==true) + the most-recent KEEP
# entries; archive the dropped (old, read) ones to <file>.pruned-<ts>.bak. NEVER drop an unread
# message. Size-gated so it's a near-no-op on a healthy inbox.
#
# PERF (2026-07-10, R-stop-dispatcher-perf-mirror): the previous shape spawned a `wc -c` subprocess
# PER inbox file every Stop, even the all-healthy no-op case (546 files × ~45ms MSYS spawn ≈ 24s of
# pure no-op tax). This version does the ENTIRE scan in ONE node process. Semantics are byte-
# identical. The teams root is taken from the bash $HOME (NOT node os.homedir(): on win32 os.homedir()
# reads USERPROFILE, which can diverge from the MSYS $HOME this hook has always globbed) and passed as
# process.argv[1] — the kit's existing `node -e '…' "$f"` idiom, now carrying the root instead of one file.
set -eu
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
aal_have_node || exit 0
node -e '
  const fs = require("fs"), path = require("path");
  const KEEP = 50, THRESH_BYTES = 250000;
  const root = process.argv[1];
  // Surfacing breaks on SIZE (the harness stops injecting once the inbox file is large), NOT on
  // count — a few VERBOSE messages can blow past the break at low counts. Byte gate is authoritative.
  let teams = [];
  try { teams = fs.readdirSync(root).sort(); } catch (e) { process.exit(0); }
  const changed = [];
  for (const t of teams) {
    const inboxDir = path.join(root, t, "inboxes");
    let files = [];
    try { files = fs.readdirSync(inboxDir).sort(); } catch (e) { continue; }
    for (const fn of files) {
      if (!fn.endsWith(".json")) continue;
      const f = path.join(inboxDir, fn);
      let sz = 0;
      try { sz = fs.statSync(f).size; } catch (e) { continue; }
      if (sz <= THRESH_BYTES) continue;
      let a;
      try { a = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { continue; }
      if (!Array.isArray(a) || a.length <= KEEP) continue;
      const cutoff = a.length - KEEP;
      const keep = [], drop = [];
      a.forEach((m, i) => { ((m && m.read !== true) || i >= cutoff) ? keep.push(m) : drop.push(m); });
      if (!drop.length) continue;
      const ts = new Date().toISOString().replace(/[:.]/g, "-");
      try {
        // .bak first (archive the drop), then atomically replace the LIVE inbox: temp sibling +
        // rename (atomic on the same fs) so a concurrent Stop+SendMessage can never leave a torn/
        // half-written inbox. C-17 — corruption-safety, NOT RMW lost-update safety (see spec §0.7/§Z-1).
        fs.writeFileSync(f.replace(/\.json$/, ".pruned-" + ts + ".bak"), JSON.stringify(drop));
        const tmp = f + ".tmp-" + process.pid + "-" + Date.now();
        fs.writeFileSync(tmp, JSON.stringify(keep));
        fs.renameSync(tmp, f);
      } catch (e) { continue; }
      const unread = keep.filter(m => m && m.read !== true).length;
      changed.push(path.basename(f) + ": " + a.length + "→" + keep.length + " (archived " + drop.length + " read; kept " + unread + " unread + recent)");
    }
  }
  if (changed.length) {
    process.stdout.write(JSON.stringify({ systemMessage: "INBOX PRUNE GUARD (surfacing-bloat fix — kept ALL unread + recent):" + changed.map(e => " | " + e).join("") }));
  }
' "$HOME/.claude/teams" 2>/dev/null || true
exit 0
