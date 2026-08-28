#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const PROT_ARCHIVE = /archive[\w.-]*\.md$/i;
const PROT_LEDGER  = /(^|[\\/])(BACKLOG|plan-reviews|code-reviews|struggle-log|autoloop-log[\w.-]*)\.md$|(^|[\\/])reviews[\\/]index[\w.-]*\.jsonl$/i;
const isProt = (t) => PROT_ARCHIVE.test(t) || PROT_LEDGER.test(t);

function existingPath(target) {
  const t = String(target).replace(/^["']|["']$/g, '');
  for (const base of ['', process.cwd() + '/', (process.env.HOME || '') + '/']) {
    try { const p = base ? resolve(base, t) : resolve(t); if (existsSync(p)) return p; } catch {}
  }
  return '';
}

function main() {
  let input;
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); }
  if ((input.tool_name || '') !== 'Bash') process.exit(0);
  const cmd = String(input.tool_input?.command || '');
  if (!cmd) process.exit(0);

  const hits = [];
  const reRedir = /(?<!>)>(?!>)\|?\s*(['"])?([^\s'"|;&)>]+)\1?/g;
  let m;
  while ((m = reRedir.exec(cmd))) { const t = m[2]; if (t && isProt(t)) hits.push({ form: "'>' (truncate)", target: t }); }
  const rePs = /\b(Out-File|Set-Content)\b([^\n|;]*?)(['"])?([^\s'"|;&)]+\.(?:md|jsonl))\3?/gi;
  while ((m = rePs.exec(cmd))) { const t = m[4]; if (t && isProt(t) && !/-Append\b/i.test(m[2])) hits.push({ form: m[1], target: t }); }

  const real = [];
  for (const h of hits) { const p = existingPath(h.target); if (p) real.push({ ...h, path: p }); }
  if (real.length === 0) process.exit(0);

  const list = real.map((h) => `  • ${h.form} → ${h.target}`).join('\n');
  const reason =
    `BLOCKED (never discard ledger content): a TRUNCATING write to an EXISTING archive/ledger file:\n${list}\n\n` +
    `'>' / Out-File / Set-Content CLEAR the file before writing → its content is LOST.\n\nInstead:\n` +
    `  • APPEND with '>>' (or use the Edit/Write tool — different matcher, allowed).\n` +
    `  • To SPLIT into a NEW archive: 'ls <ledger>-archive-*' → use the next FREE number (e.g. -archive-07) → write a .tmp → 'mv' it (mv is allowed).\n` +
    `  • NEVER '>' a name without first confirming it does not already exist.`;
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason } }));
}
try { main(); } catch { process.exit(0); }
