#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-prior-ruling-search-on-new-card');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let input = {};
try { input = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = input.tool_name || '';
if (!/^(Write|Edit)$/.test(tool)) allow();

const ti = input.tool_input || {};
const path = String(ti.file_path || '').replace(/\\/g, '/');
if (!/\/BACKLOG\.md$/i.test(path)) allow();

const added = tool === 'Edit' ? String(ti.new_string || '') : '';
if (!added) allow();

const oldText = tool === 'Edit' ? String(ti.old_string || '') : '';

const headersOf = (s) => (s.match(/^### \[[A-Z-]+\][^\n]*/gm) || []);
const slugOf = (h) => (h.match(/^### \[[A-Z-]+\]\s+([A-Za-z0-9._-]+)/) || [])[1] || h;
const before = new Set(headersOf(oldText).map(slugOf));
const newHeaders = headersOf(added).filter((h) => !before.has(slugOf(h)));

const introducesDodVerdict =
  (/DoD-FAILED/.test(added) && !/DoD-FAILED/.test(oldText)) ||
  (/DoD-VERIFIED/.test(added) && !/DoD-VERIFIED/.test(oldText));
const DEFERRED_SEARCH =
  /^-\s*(?:phantom-gate|prior-ruling|ruling-search|family-scan)\s*:[^\n]*?(?:to be (?:done|filled|checked|searched)|not (?:yet )?searched|later|next round|come back to it|\bTODO\b|\bTBD\b|\bpending\b)/im;
const cardHasFamilyScan = (() => {
  if (!path.endsWith('BACKLOG.md')) return false;
  const slug = (String(added).match(/^###\s+\[[^\]]*\][^\n]*?\b(R-[a-z0-9-]{6,})/m) || [])[1]
    || (String(oldText).match(/^###\s+\[[^\]]*\][^\n]*?\b(R-[a-z0-9-]{6,})/m) || [])[1];
  if (!slug) return false;
  let board = '';
  try { board = readFileSync(path, 'utf8'); } catch { return false; }
  const blocks = board.split(/\n(?=### )/);
  const blk = blocks.find((b) => {
    const head = b.split('\n')[0] || '';
    return head.startsWith('### ') && new RegExp(`\\]\\s*(?:PR\\s*#\\d+\\s*·\\s*)?${slug}\\b`).test(head);
  });
  if (!blk) return false;
  const line = (blk.match(/^-\s*(?:family-scan|wave-scan)\s*:[^\n]*/m) || [])[0];
  if (!line) return false;
  return !DEFERRED_SEARCH.test(line);
})();
if (introducesDodVerdict && !/^-\s*(family-scan|wave-scan)\s*:/m.test(added) && !cardHasFamilyScan) {
  const isVerified = /DoD-VERIFIED/.test(added) && !/DoD-FAILED/.test(added);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        (isVerified
          ? `BLOCKED: writing \`DoD-VERIFIED\` with no FAMILY-SCAN field\n\n`
          : `BLOCKED: writing \`DoD-FAILED\` with no FAMILY-SCAN field\n\n`) +
        `The test: **"if this were designed on purpose, which file would that sentence be in?"** If the answer is a file you have not searched, the search is not finished.\n\n` +
        `FIX. Read both documents of this wave's family first (a sibling wave counts as family):\n` +
        `  ls docs/product-specs/*<family keyword>*\n` +
        `  grep -n '<the verbatim error string or stage name>' docs/product-specs/*<family keyword>*\n` +
        `  Read at least \`Locked decisions\` · \`Target end-state\` · \`Scope\` / \`Out of scope\`, ` +
        `and the words \`designed\` / \`EXPECTED\` / \`stop boundary\`\n` +
        `Then add one line in this same edit:\n` +
        `  - family-scan: family=<plan/arch paths> · was this failure already written as EXPECTED=<the quote, or "none"> · sibling cards=<slug or "none">`,
    },
  }));
  process.exit(0);
}

if (!newHeaders.length) allow();

const claims = newHeaders.filter((h) => !/^### \[(WITHDRAWN|DONE|ARCHIVED)\]/.test(h));
if (!claims.length) allow();

const HAS_SEARCH = /^-\s*(phantom-gate|prior-ruling|ruling-search)\s*:/m.test(added)
  && !DEFERRED_SEARCH.test(added);

const familyClaims = claims.filter((h) => /dod-remedy-for=/.test(h));
const HAS_FAMILY = /^-\s*(family-scan|wave-scan)\s*:/m.test(added);
if (familyClaims.length && !HAS_FAMILY) {
  const fnames = familyClaims.map((h) => (h.match(/^### \[[A-Z-]+\]\s+(\S+)/) || [])[1] || h.slice(0, 60));
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `BLOCKED: a new card claims to belong to a wave family (it carries \`dod-remedy-for=\`) with no FAMILY-SCAN field\n` +
        `Cards being added: ${fnames.map((n) => `\`${n}\``).join(' · ')}\n\n` +
        `FIX. Read BOTH the architecture and the plan of the parent wave first (identify them by the doc header's \`backlog card <slug>\`; the filename slug is often different):\n` +
        `  ls docs/product-specs/*<family keyword>*\n` +
        `  Read at least \`## Locked decisions\` · \`## Target end-state\` · \`## Scope\` / \`Out of scope\`;\n` +
        `  and grep \`supersede\` inside the \`-architecture.md\` — that is where it overrules its own plan.\n` +
        `Then scan the neighbourhood: what the sibling cards with the same \`dod-remedy-for=\` are doing, and whether an agent is in flight. Then add one line:\n` +
        `  - family-scan: parent wave=<plan path> · already decided=<the quote, or "no relevant decision"> · sibling cards=<slug or "none"> · in flight=<agent name or "none">`,
    },
  }));
  process.exit(0);
}

if (HAS_SEARCH) allow();

const names = claims.map((h) => (h.match(/^### \[[A-Z-]+\]\s+(\S+)/) || [])[1] || h.slice(0, 60));

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      `BLOCKED: a new card with no PRIOR-RULING-SEARCH field\n` +
      `Cards being added: ${names.map((n) => `\`${n}\``).join(' · ')}\n\n` +
      `FIX. Run this first, using the subject's OWN IDENTIFIER rather than a topic word:\n` +
      `  grep -rn '<the identifier>' ${projectPaths()?.claude || '<project>/.claude'}/autoloop-log-*.md\n` +
      `Then add one line to the card:\n` +
      `  - phantom-gate: grep '<the identifier>' => 0 hits\n` +
      `  (if there ARE hits: hit <file:line>, ruling=<the quote>, question=<what was asked then>, date=<YYYY-MM-DD>)`,
  },
}));
process.exit(0);
