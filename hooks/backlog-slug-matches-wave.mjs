#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const allow = () => { process.stdout.write('{}'); process.exit(0); };
let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const ti = payload.tool_input || {};
const fp = String(ti.file_path || '');
if (!/BACKLOG\.md$/i.test(fp)) allow();
if (/BACKLOG-(archive|detail)/i.test(fp)) allow();

const introduced = [ti.content, ti.new_string].filter(Boolean).join('\n');
if (!introduced.trim()) allow();


let waveCompat;
try { ({ waveCompat } = await import('./lib/plan-verdict.mjs')); }
catch { allow(); }

const H = '#'.repeat(3) + ' ';
const offenders = [];
const lines = introduced.split(/\r?\n/);
for (let i = 0; i < lines.length; i++) {
  if (!lines[i].startsWith(H)) continue;
  const slug = (lines[i].match(/\bR-[a-z0-9][a-z0-9-]{4,}/i) || [])[0];
  if (!slug) continue;
  let end = lines.length;
  for (let k = i + 1; k < lines.length; k++) if (lines[k].startsWith(H)) { end = k; break; }
  const al = String(lines.slice(i, end).find((l) => l.startsWith('- aliases:')) || '');
  const br = (al.match(/feat\/(r-[a-z0-9][a-z0-9-]*)/i) || [])[1];
  if (!br) continue;
  const wave = 'R-' + br.replace(/^r-/i, '').replace(/\d+$/, '');
  if (waveCompat(slug, wave)) continue;
  offenders.push({ slug, wave, br });
}
if (!offenders.length) allow();

const body = offenders.map((o) =>
  `  · card slug \`${o.slug}\`\n    branch \`feat/${o.br}\` ⇒ the wave name should be \`${o.wave}\``).join('\n');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
`BLOCKED: **the card slug does not match the wave name**

${body}

**Why this is not naming fussiness — it makes two gates give OPPOSITE answers**: the \`plan\` field in the \`index.jsonl\` ledger holds the WAVE NAME.
  \`jsonlPlanVerdict(ledger, [slug])\`             -> \`none\`      <- the developer gate takes this path and REFUSES the dispatch
  \`jsonlPlanVerdict(ledger, [slug, ...aliases])\` -> \`approved\`  <- the dispatch gate takes this path and ALLOWS it
One concept, two mechanisms, no shared predicate ⇒ opposite answers, and each half looks correct on its own.

**The fix is one edit, and it ADDS rather than changes**:
  1. change the card-header slug to the wave name (the one above)
  2. **append the old slug to \`- aliases:\`** — every existing reference in the ledger, the archives and PR bodies keeps resolving
Do NOT do it the other way round by editing the ledger or the branch name: those are already aligned with the plan document, the PR and the verdict filenames. The card is the outlier.`,
  },
}));
process.exit(0);
