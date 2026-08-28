#!/usr/bin/env bash
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
' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/teams" 2>/dev/null || true
exit 0
