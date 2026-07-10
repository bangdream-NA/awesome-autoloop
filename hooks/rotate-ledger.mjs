#!/usr/bin/env node
// rotate-ledger.mjs — safe session-ledger rotation helper (a lead-invoked utility, NOT a hook).
//
// Distilled from real ledger-rotation-slip incidents: rotating by FILE-POSITION or by an assumed
// time order repeatedly moved gate-needed, in-flight review verdicts into an archive, and hand-rolled
// section carves ate card headers. It is the ACTION counterpart to the DETECTED `ledger-size-guard.sh`,
// which only WARNS when a ledger nears the 256KB Read-tool ceiling. This helper:
//   1. splits by RECENCY (keeps sections whose newest date is within --keep-days), never %-position;
//   2. archives to a FRESH file (<name>-archive-<stamp>[-N].md) — never appends over an existing
//      archive slot (that path once truncated real content);
//   3. keeps every OPEN PR's `## PR #N` block in the ACTIVE file (a safety net for the legacy
//      per-PR review monoliths), restoring any that recency would have archived;
//   4. is dry-run by default; --apply writes.
//
// SCOPE: MARKDOWN `## `-headed ledgers ONLY (op-log / struggle-log / the legacy review monoliths).
// It does NOT rotate the per-project `reviews/index.jsonl` machine store — a JSON-Lines file is a
// line-boundary mechanism, split by hand into `index-archive-NN.jsonl`, and is deliberately out of
// scope here.
//
// Config: AAL_ROTATE_MIN_KB (default 200) — the size at/above which a ledger is eligible to rotate.
//         AAL_NO_GH=1        — skip the `gh` open-PR lookup (offline / no GitHub); falls back to a
//                              conservative 30-day retention of `## PR #` blocks.
// Usage:  node hooks/rotate-ledger.mjs <ledger.md> [--keep-days 14] [--apply]
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';
import path from 'node:path';

const args = process.argv.slice(2);
const file = args.find((a) => !a.startsWith('--'));
const APPLY = args.includes('--apply');
const kdIdx = args.indexOf('--keep-days');
const KEEP_DAYS = kdIdx >= 0 ? Number(args[kdIdx + 1]) || 14 : 14;
const MIN_KB = Number(process.env.AAL_ROTATE_MIN_KB) || 200;
const NO_GH = process.env.AAL_NO_GH === '1' || process.env.AAL_NO_GH === 'true';
if (!file || !existsSync(file)) {
  console.error('usage: node rotate-ledger.mjs <ledger.md> [--keep-days N] [--apply]\nledger not found: ' + file);
  process.exit(1);
}

const src = readFileSync(file, 'utf8');
if (Buffer.byteLength(src, 'utf8') < MIN_KB * 1024) {
  console.log(`ledger is ${Math.round(Buffer.byteLength(src, 'utf8') / 1024)}KB (<${MIN_KB}KB) — no rotation needed.`);
  process.exit(0);
}

// Split into a preamble + `## `-headed sections. Ordering direction does NOT matter — recency is
// judged per-section by the newest date string it contains.
const parts = src.split(/\r?\n(?=## )/);
const preamble = parts[0].startsWith('## ') ? '' : parts.shift();
const DATE_RE = /20\d\d-\d\d-\d\d/g;
const newestDate = (s) => {
  let latest = '';
  for (const m of s.match(DATE_RE) || []) if (m > latest) latest = m;
  return latest;
};
const now = new Date();
const cutoff = new Date(now.getTime() - KEEP_DAYS * 86400000).toISOString().slice(0, 10);

let keep = [], old = [];
for (const sec of parts) {
  const d = newestDate(sec);
  // undated sections are NEVER archived (can't prove they're old — keep, fail toward safety)
  (d && d < cutoff ? old : keep).push(sec);
}

// Safety net for the legacy per-PR monoliths: keep every OPEN PR's `## PR #N` block ACTIVE regardless
// of date. Only consult `gh` when an about-to-be-archived section is actually a `## PR #N` block — a
// struggle-log / op-log (no PR headers) never shells out, so this stays offline for the common case.
let openPRs = null;
const oldHasPR = old.some((s) => /^## PR #\d+/.test(s));
if (oldHasPR && !NO_GH) {
  try {
    const dir = path.dirname(path.dirname(path.resolve(file))); // <repo>/.claude/x.md → <repo>
    openPRs = JSON.parse(
      execSync('gh pr list --state open --limit 100 --json number -q "[.[].number]"', { cwd: dir, encoding: 'utf8', timeout: 20000 })
    );
  } catch { openPRs = null; }
}
if (openPRs === null) {
  // No gh list (offline, AAL_NO_GH, or no PR blocks to protect): be conservative — any `## PR #`
  // block from the last 30 days stays active; everything else archives by recency.
  const cons = new Date(now.getTime() - 30 * 86400000).toISOString().slice(0, 10);
  const stillOld = [];
  for (const sec of old) (/^## PR #\d+/.test(sec) && newestDate(sec) >= cons ? keep : stillOld).push(sec);
  old = stillOld;
} else {
  const restored = [];
  const stillOld = [];
  for (const sec of old) {
    const m = sec.match(/^## PR #(\d+)/);
    if (m && openPRs.includes(Number(m[1]))) { keep.push(sec); restored.push('#' + m[1]); }
    else stillOld.push(sec);
  }
  old = stillOld;
  if (restored.length) console.log('post-verify RESTORED in-flight PR blocks to active: ' + restored.join(', '));
}

if (!old.length) {
  console.log('nothing old enough to archive (keep-days=' + KEEP_DAYS + ') — no rotation.');
  process.exit(0);
}

const stamp = new Date().toISOString().slice(0, 10);
let archivePath = file.replace(/\.md$/, `-archive-${stamp}.md`);
let n = 2;
while (existsSync(archivePath)) archivePath = file.replace(/\.md$/, `-archive-${stamp}-${n++}.md`); // NEVER clobber an existing slot

const activeOut = (preamble || '') + keep.join('\n') + '\n';
const archiveOut = `# Archived from ${path.basename(file)} on ${stamp} (recency rotation, keep-days=${KEEP_DAYS})\n\n` + old.join('\n') + '\n';

console.log(`plan: keep ${keep.length} section(s) active (${Math.round(Buffer.byteLength(activeOut, 'utf8') / 1024)}KB), archive ${old.length} section(s) → ${path.basename(archivePath)} (${Math.round(Buffer.byteLength(archiveOut, 'utf8') / 1024)}KB)`);
if (!APPLY) {
  console.log('dry-run (pass --apply to write).');
  process.exit(0);
}
writeFileSync(archivePath, archiveOut);
writeFileSync(file, activeOut);
console.log('applied.');
