// Cross-ref helper for require-backlog-reconciled-before-merge.sh (kept as a separate file to
// avoid shell-quoting hazards in an inline `node -e` — a literal single-quote in the script body
// would close the bash single-quoted wrapper). argv: [node, this, backlogPath, mergedSlugs(\n-sep)].
const fs = require("node:fs");
const [, , backlog, slugsRaw = ""] = process.argv;

const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }) + "\n");
  process.exit(0);
};

// __NONE__ = the .sh VERIFIED gh succeeded with zero merged PRs (a brand-new repo's first
// merge) — nothing can be stale yet → allow. A truly EMPTY slugsRaw still means gh FAILED → deny.
if (slugsRaw.trim() === "__NONE__") process.exit(0);
if (!slugsRaw.trim()) {
  deny("BLOCKED merge (fail-closed): `gh pr list --state merged` returned empty — cannot verify the BACKLOG active board is reconciled, so a merge here risks leaving the prior batch stale. Fix gh/network, or reconcile the board manually + re-run.");
}

const slugs = new Set(slugsRaw.split("\n").map((s) => s.trim()).filter(Boolean));
let bl;
try { bl = fs.readFileSync(backlog, "utf8").split("\n"); } catch { process.exit(0); }

const stale = [];
for (let i = 0; i < bl.length; i++) {
  const m = bl[i].match(/^### \[(QUEUED|REVIEW|IN-DEV)\]\s*(.+)/);
  if (!m) continue;
  const title = m[2].split("·")[0].trim();
  for (let j = i + 1; j < Math.min(i + 8, bl.length); j++) {
    if (bl[j].match(/^### /)) break;
    const a = bl[j].match(/^-\s*(?:aliases|别名)[:：]\s*(.+)/);
    if (a) {
      const first = a[1].split(",")[0].trim(); // PRIMARY alias only — absorbed history aliases don't false-fire
      if (slugs.has(first)) stale.push(title + " → merged slug \"" + first + "\"");
      break;
    }
  }
}

if (stale.length) {
  deny("BLOCKED merge — merge-then-archive ENFORCED. The BACKLOG active board still lists card(s) whose PRIMARY alias matches an ALREADY-MERGED PR (merged but never archived): [" + [...new Set(stale)].join(" ; ") + "]. For EACH: append a '### ✅ name · DONE #N @sha' block to BACKLOG-archive.md, then DELETE the card from the active board. THEN re-run this merge. (Soft reminders failed → this is the fail-closed gate.)");
}
// no stale → allow: no output, exit 0
