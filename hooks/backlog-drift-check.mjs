#!/usr/bin/env node
// Stop hook — BACKLOG drift detector.
// Catches the recurring drift: a wave whose PR has MERGED but whose active BACKLOG card is still
// marked QUEUED/IN-DEV/BLOCKED (never updated → a stale status). Uses the AUTHORITATIVE merged-PR
// history (gh) cross-matched against active-card aliases.
// THROTTLED to once / 30 min (state file) so it is not an every-turn gh cost.
// Default SKIP (exit 0, silent). On drift → exit 2 with a blocking reminder.
// Fail-OPEN-SAFE: any error → exit 0 (a drift-detector must never wedge the session).
import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';

const PROJ = process.env.CLAUDE_PROJECT_DIR || process.cwd();
const BACKLOG = path.join(PROJ, '.claude', 'BACKLOG.md');
const STATE = path.join(PROJ, '.claude', '.backlog-drift-check.json');

try {
  if (!fs.existsSync(BACKLOG)) process.exit(0);

  // throttle: 30 min
  const now = Date.now();
  let last = 0;
  try { last = JSON.parse(fs.readFileSync(STATE, 'utf8')).ts || 0; } catch { /* no state yet */ }
  if (now - last < 30 * 60 * 1000) process.exit(0);

  // Repo for the merged-PR history — auto-detect from the project's git remote (never hardcoded).
  // Unresolvable → no-op (a Stop WARN is lower-stakes than a merge DENY; fail-OPEN is correct).
  let repo;
  try {
    const url = execSync('git remote get-url origin', { cwd: PROJ, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 }).trim();
    repo = url.replace(/\.git$/, '').match(/[:/]([^/]+\/[^/]+)$/)?.[1];
  } catch { /* unresolvable */ }
  if (!repo) process.exit(0);

  // merged-PR slugs (authoritative done-signal) — recent 80
  let merged = [];
  try {
    const raw = execSync(
      `gh pr list --repo ${repo} --state merged --limit 80 --json headRefName,number,title`,
      { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] }
    );
    merged = JSON.parse(raw);
  } catch { process.exit(0); } // gh unavailable/offline → fail-open, don't block

  // only stamp state AFTER a successful gh call, so an offline turn doesn't burn the throttle window
  fs.writeFileSync(STATE, JSON.stringify({ ts: now }));

  const mergedSlugs = new Map(); // slug -> pr#
  for (const p of merged) {
    const slug = String(p.headRefName || '').replace(/^(feat|fix|docs|chore|refactor)\//, '').trim().toLowerCase();
    if (slug && slug.length >= 4) mergedSlugs.set(slug, p.number);
  }
  if (mergedSlugs.size === 0) process.exit(0);

  // BACKLOG.md holds ONLY active cards (DONE cards live in the separate BACKLOG-archive.md), so
  // EVERY `### [STATUS] name` line is an active card. Parse every `### [...]` card, no section gating.
  const lines = fs.readFileSync(BACKLOG, 'utf8').split('\n');
  const cards = [];
  let cur = null;
  const flush = () => { if (cur) cards.push(cur); cur = null; };
  for (const ln of lines) {
    if (/^###\s+\[/.test(ln)) {
      flush();
      const headerName = (ln.match(/^###\s+(?:\[[^\]]+\]\s*)?([^·]+?)\s*(?:·|$)/) || [])[1] || '';
      cur = { headerName: headerName.trim(), header: ln, body: ln + '\n', doneMarked: /✅|\bDONE\b|\bMERGED\b/i.test(ln) };
      continue;
    }
    if (/^#{1,3}\s/.test(ln)) { flush(); continue; } // any other heading ends the current card
    if (cur) cur.body += ln + '\n';
  }
  flush();

  // a card is "done-marked" if its header OR body already says ✅/MERGED/DONE/RECONCILED-OUT
  // (those are intentionally-tracked; drift = an UN-marked card whose wave shipped)
  const drift = [];
  for (const c of cards) {
    if (!c.headerName) continue;
    if (c.doneMarked || /✅|\bMERGED\b|\bDONE\b|RECONCILED-OUT/i.test(c.body)) continue;
    // PRIMARY alias only (first alias token) — absorbed history aliases (e.g. a card listing an
    // absorbed sibling slug) must NOT false-fire against an old merged PR of that name.
    const aliasLine = (c.body.match(/(?:aliases|别名)[:：]\**\s*(.+)/) || [])[1] || '';
    const firstAlias = (aliasLine.split(/[,，]/)[0] || '').trim().toLowerCase().replace(/[`*]/g, '');
    if (firstAlias.length < 4) continue;
    for (const [slug, pr] of mergedSlugs) {
      if (firstAlias === slug) { drift.push(`${c.headerName.trim()} ↔ merged PR #${pr} (primary alias "${slug}")`); break; }
    }
  }

  if (drift.length === 0) process.exit(0);

  process.stderr.write(
    `BACKLOG drift check: ${drift.length} ACTIVE card(s) match a MERGED PR but are NOT marked done (the "done-but-still-queued" drift). VERIFY each LIVE first-hand per your project's nature (web → a real-browser walk / curl the deployed page; api/data → curl the live endpoint or shard; CLI → run the built binary). If truly done, mark it done + move the card to BACKLOG-archive.md; if only the PR merged but a real deploy/verify is still outstanding, fix the card's status to say so. Then stop.\nDRIFTED:\n  - ${drift.join('\n  - ')}\n`
  );
  process.exit(2);
} catch {
  process.exit(0); // fail-open: never wedge the session on a detector bug
}
