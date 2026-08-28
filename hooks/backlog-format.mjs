#!/usr/bin/env node
// Reports which active cards are missing a canonical field. It READS a board and never writes one.
//
// 🔴 It used to insert `- problem:` / `- fix:` placeholders and write the file back under --apply.
// Two properties of that made it dangerous, and both are removed here rather than guarded:
//
//   1. INSERTING AN ABSENT FIELD MANUFACTURES THE STATE IT IS SUPPOSED TO DETECT. A card that was
//      missing a field came out carrying a well-formed field whose value was a placeholder, and
//      every downstream reader of that field sees something indistinguishable from a real entry.
//      A detector that fills in its own finding fails GREEN.
//   2. THE BOARD PATH WAS DISCOVERED, NOT GIVEN. With no argument and no env var it fell back to
//      whatever project the process happened to resolve to — so an invocation meant for a fixture
//      board could reach a live one and rewrite it. A tool that only reads is far less dangerous,
//      but the fallback is gone too: the board is now an explicit argument, and its absence is a
//      refusal rather than a default.
//
// Field-name aliases belong on the READ side and nowhere else: recognising that a card already
// carries the information is a judgment about the card. Writing a name the card did not use is an
// edit, and this tool no longer makes edits.
import { readFileSync } from 'node:fs';

const STATUS_WL = ['QUEUED', 'IN-DEV', 'REVIEW', 'BLOCKED', 'USER-GATED'];
const args = process.argv.slice(2);
const BACKLOG = process.env.AAL_BACKLOG || args.find((a) => !a.startsWith('--')) || '';

if (!BACKLOG) {
  console.error('backlog-format: no board given. Pass the path explicitly:');
  console.error('  node hooks/backlog-format.mjs <path-to-board.md>');
  console.error('  AAL_BACKLOG=<path-to-board.md> node hooks/backlog-format.mjs');
  console.error('It reports missing fields and never writes; a discovered default is exactly how a');
  console.error('run meant for one board reaches another.');
  process.exit(2);
}

if (args.includes('--apply')) {
  console.error('backlog-format: --apply is not supported — this tool reports, it does not edit.');
  console.error('A missing field is a fact about the card; filling it with a placeholder hides it.');
  process.exit(2);
}

const rawText = readFileSync(BACKLOG, 'utf8');
const lines = rawText.split(/\r?\n/);

// Read-side aliases only. Each entry is one CONCEPT and the spellings that already express it.
const FIELDS = [
  { name: 'problem', re: /^\s*-\s*(problem|issue|symptom)\s*:/i },
  { name: 'fix', re: /^\s*-\s*(fix|remedy|repair)\s*:/i },
];

const missing = [];
let i = 0;
let cards = 0;
while (i < lines.length) {
  const m = lines[i].match(/^###\s+\[([^\]]+)\]\s+(.+)$/);
  if (!m || !STATUS_WL.includes(m[1])) { i++; continue; }
  const name = m[2].split('·')[0].split('(')[0].trim();
  const body = [];
  let j = i + 1;
  for (; j < lines.length && !/^#{2,3}\s/.test(lines[j]); j++) body.push(lines[j]);
  cards++;
  for (const f of FIELDS) {
    if (!body.some((l) => f.re.test(l))) missing.push({ name, field: f.name });
  }
  i = j;
}

if (missing.length === 0) {
  console.log(`backlog-format: ${cards} active card(s), every one carries problem + fix. (${BACKLOG})`);
  process.exit(0);
}

const cardSet = new Set(missing.map((c) => c.name));
console.log(`backlog-format: ${missing.length} missing field(s) across ${cardSet.size} of ${cards} card(s) in ${BACKLOG}`);
let last = null;
for (const c of missing) {
  if (c.name !== last) { console.log(`  ${c.name}`); last = c.name; }
  console.log(`    missing: - ${c.field}:`);
}
console.log('\nNothing was written. Fill these in on the card itself — a placeholder inserted here');
console.log('would read downstream as a field that has been answered.');
process.exit(1);
