#!/usr/bin/env node
import { readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { pilotVerdict } from './lib/backlog-pilot-core.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
import { isAutoloopSession } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-lead-debt-direct');

let stdin = {};
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { stdin = {}; }
const tp = String(stdin.transcript_path || '').replace(/\\/g, '/');
if (tp && !isAutoloopSession(stdin)) { process.stdout.write('{}'); process.exit(0); }

const DIR = process.env.AAL_LEADDEBT_DIR || projectPaths()?.claude || '';
const LEDGER = path.join(DIR, 'LEAD-DEBTS.md');
const BOARD = process.env.AAL_LEADDEBT_BOARD || path.join(DIR, 'BACKLOG.md');

let ownsProject = false;
try {
  const files = readdirSync(DIR)
    .filter((f) => /^autoloop-log-.*\.md$/.test(f))
    .map((f) => { try { return { f, m: statSync(path.join(DIR, f)).mtimeMs }; } catch { return null; } })
    .filter(Boolean)
    .sort((a, b) => a.m - b.m);
  const newest = files[files.length - 1];
  const sidm = newest && newest.f.match(/-([0-9a-f]{8})\.md$/i);
  ownsProject = !!(sidm && String(stdin.session_id || '').toLowerCase().startsWith(sidm[1].toLowerCase()));
} catch { ownsProject = false; }
if (!ownsProject && !process.env.AAL_LEADDEBT_FORCE_OWN) { process.stdout.write('{}'); process.exit(0); }


let ledgerText = '';
try { ledgerText = readFileSync(LEDGER, 'utf8'); } catch { ledgerText = ''; }
const now = Date.now();
const H = 3600 * 1000;
const violations = [];
for (const raw of ledgerText.split('\n')) {
  const line = raw.trim();
  if (!line.startsWith('- [')) continue;
  let m;
  if ((m = line.match(/^- \[open\]\s+(\S+)/))) {
    violations.push(`[open] ${m[1]} — do it now (then mark [done YYYY-MM-DD] with 15+ chars of evidence), or write a verifiable gate ([gated until:<date> | blocked-by=pr#N | user]), or start this turn and mark [working YYYY-MM-DD]`);
  } else if ((m = line.match(/^- \[working\s+(20\d\d-\d\d-\d\d)\]\s+(\S+)/))) {
    const age = now - Date.parse(m[1]);
    if (!(age >= -26 * H && age <= 48 * H)) violations.push(`[working ${m[1]}] ${m[2]} — working for over 48h is a debt in disguise; finish it and mark [done], or if you really are blocked write [gated …] naming what blocks it`);
  } else if ((m = line.match(/^- \[gated until:(20\d\d-\d\d-\d\d)\]\s+(\S+)/))) {
    if (Date.parse(m[1]) <= now) violations.push(`[gated until:${m[1]}] ${m[2]} — expired; do it, or restate a new date with a new EXTERNAL ETA`);
    const anchorRe = /gate-(observed|extended)-at=(20\d\d-\d\d-\d\dT\d\d:\d\d:\d\dZ)/gi;
    const anchors = [...line.matchAll(anchorRe)].map((x) => ({ kind: x[1].toLowerCase(), ts: Date.parse(x[2]) })).filter((x) => Number.isFinite(x.ts)).sort((a, b) => a.ts - b.ts);
    if (!anchors.length || anchors[0].kind !== 'observed') {
      violations.push(`[gated until:${m[1]}] ${m[2]} — the gate has no machine-verifiable anchor gate-observed-at=...Z, so the 24h/1h rule cannot be checked`);
    } else {
      if (anchors[anchors.length - 1].ts - anchors[0].ts > 24 * H) violations.push(`[gated until:${m[1]}] ${m[2]} — the gate now spans more than 24h; say why and rebuild it`);
      for (let i = 1; i < anchors.length; i++) {
        if (anchors[i].ts - anchors[i - 1].ts > H) { violations.push(`[gated until:${m[1]}] ${m[2]} — a single extension exceeded 1h, which breaks the one-hour-at-a-time rule`); break; }
      }
    }
  } else if (/^- \[gated (blocked-by=pr#\d+|user)\]/.test(line)) {
  } else if ((m = line.match(/^- \[done\s+(20\d\d-\d\d-\d\d)\]\s+(\S+)\s*·\s*(.*)$/))) {
    if ((m[3] || '').trim().length < 15) violations.push(`[done] ${m[2]} — done with fewer than 15 chars of evidence is just a claim; add the evidence or put it back to [open]`);
  } else if (/^- \[void\]\s+\S+\s*·\s*.{15,}/.test(line)) {
  } else {
    violations.push(`malformed ledger row "${line.slice(0, 60)}…" — use [open] / [working <date>] / [gated until:<date>|blocked-by=pr#N|user] / [done <date> · evidence] / [void · reason]`);
  }
}

try {
  const active = (() => {
    const b = readFileSync(BOARD, 'utf8');
    const cut = b.search(/## AUDIT-R1|ALREADY DONE BELOW/);
    return cut > 0 ? b.slice(0, cut) : b;
  })();
  for (const o of pilotVerdict(active).owed) {
    violations.push(`${o.kind}: ${o.card} [${o.status}] — ${o.detail}`);
  }
} catch {  }

try {
  const board = readFileSync(BOARD, 'utf8');
  const ledgerLC = ledgerText.toLowerCase();
  for (const card of board.split(/\n(?=### \[)/)) {
    if (!/^### \[/.test(card)) continue;
    if (!/DoD-GATED[^\n]*?(server-op|lead[- ]?(owed|debt|owned|runs it))/i.test(card)) continue;
    const slug = (card.match(/R-[a-z0-9-]+/i) || [])[0];
    if (slug && !ledgerLC.includes(slug.toLowerCase())) {
      violations.push(`unregistered: card ${slug} declares a lead/server-op-gated DoD but is not in LEAD-DEBTS.md — register a row ([open] / [gated …]) or [void] with the reason it is not a lead debt`);
    }
  }
} catch {  }

if (!violations.length) { process.stdout.write('{}'); process.exit(0); }
process.stdout.write(JSON.stringify({
  decision: 'block',
  reason:
    `LEAD-DEBT, do it directly: there is an unhandled lead debt — handle it THIS turn (for a server op, read the runbook first). It does not carry to the next turn:\n- ${violations.join('\n- ')}\n` +
    `There are two kinds of disposal; each row says which it is:\n` +
    `· **a ledger row** (${DIR}/LEAD-DEBTS.md; existing rows are still governed): do it (mark [done YYYY-MM-DD] plus 15+ chars of evidence) / really doing it now (mark [working YYYY-MM-DD]) / genuinely blocked externally (write [gated until:<date>|blocked-by=pr#N|user] plus the reason). Editing the ledger releases this stop automatically.\n` +
    `· **DoD owed / DoD-FAILED**: DERIVED FROM THE BOARD, never written into the ledger — archiving a card unbinds it automatically, so no dead row is left pointing at something that no longer exists. Walk that card's full-journey DoD, land the evidence on the card, and archive it; or write a machine-verifiable dated gate (\`observe-until YYYY-MM-DD\` plus \`gate-observed-at=<ISO Z>\`, 12h total span at most, one change at most). **There is no field you can type to make it go away** — it is recomputed every turn and disappears only when the facts change.`,
}));
process.exit(0);
