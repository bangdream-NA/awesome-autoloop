#!/usr/bin/env node
// block-truncate-existing-ledger.mjs — block a TRUNCATING write to an EXISTING archive/ledger .md.
// NEVER discard ledger content. Footgun: a single truncating redirect (`... > ledger-archive-01.md`)
// assumed `01` was the next free slot when it already existed → the existing archive was CLEARED,
// unrecoverable. This gate refuses a `>` / Out-File / Set-Content onto a file that already exists.
//
// DENY (when the target FILE ALREADY EXISTS):
//   >  TARGET            (single truncating redirect, incl. 2>, >|)
//   cat ... > TARGET
//   Out-File ... TARGET        (PowerShell)
//   Set-Content ... TARGET     (PowerShell)
// ALLOW (always):
//   >> TARGET            (append)
//   mv tmp TARGET        (rename — the correct split-replace mechanism)
//   Out-File -Append / Add-Content
//   >  TARGET            when TARGET does NOT yet exist (creating a fresh next-free slot)
//   Edit/Write tools     (different matcher; not Bash)
// fail-OPEN on any parse/IO uncertainty (a hook bug must not wedge the lead).
import { readFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

// protected basename: an *archive*.md OR a known append-only ledger
const PROT_ARCHIVE = /archive[\w.-]*\.md$/i;
const PROT_LEDGER  = /(^|[\\/])(BACKLOG|plan-reviews|code-reviews|struggle-log|autoloop-log[\w.-]*)\.md$/i;
const isProt = (t) => PROT_ARCHIVE.test(t) || PROT_LEDGER.test(t);

// resolve a target against the likely roots; return the existing path or ''
function existingPath(target) {
  const t = String(target).replace(/^["']|["']$/g, '');
  for (const base of ['', process.cwd() + '/', (process.env.HOME || '') + '/']) {
    try { const p = base ? resolve(base, t) : resolve(t); if (existsSync(p)) return p; } catch {}
  }
  return '';
}

function main() {
  let input;
  try { input = JSON.parse(readFileSync(0, 'utf8')); } catch { process.exit(0); } // fail-open
  if ((input.tool_name || '') !== 'Bash') process.exit(0);
  const cmd = String(input.tool_input?.command || '');
  if (!cmd) process.exit(0);

  const hits = [];
  // 1) truncating redirect:  '>'  not part of '>>'  → optional '|' (clobber) → optional quote → target
  const reRedir = /(?<!>)>(?!>)\|?\s*(['"])?([^\s'"|;&)>]+)\1?/g;
  let m;
  while ((m = reRedir.exec(cmd))) { const t = m[2]; if (t && isProt(t)) hits.push({ form: "'>' (truncate)", target: t }); }
  // 2) PowerShell Out-File / Set-Content (skip -Append)
  const rePs = /\b(Out-File|Set-Content)\b([^\n|;]*?)(['"])?([^\s'"|;&)]+\.md)\3?/gi;
  while ((m = rePs.exec(cmd))) { const t = m[4]; if (t && isProt(t) && !/-Append\b/i.test(m[2])) hits.push({ form: m[1], target: t }); }

  // only DENY when the target FILE EXISTS (a fresh new slot is allowed)
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
try { main(); } catch { process.exit(0); } // fail-OPEN
