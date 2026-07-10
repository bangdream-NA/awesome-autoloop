#!/usr/bin/env node
// block-backlog-archive-residue.mjs
// PostToolUse(Write|Edit|MultiEdit) on a project's ACTIVE BACKLOG.md (never the archive ledger / .bak).
// The sibling write-time gate block-backlog-status-drift inspects ONLY `### ` HEADER lines, so two
// NON-header archive-residue formats slip past it and balloon the active board:
//   (1) tombstone index lines  `(R-xxx -> DONE #N ... archived)`  -- start with `(`, not `### `
//   (2) `<!-- archived pipeline log ... -->` HTML comment blocks  -- render-invisible, so unnoticed
// This hook reads the POST-WRITE file FROM DISK (sees global accumulation) and BLOCKS if any
// archive-residue remains on the ACTIVE board. archive = the WHOLE card CUT into the archive ledger;
// the active board keeps ZERO residue. Fail-closed for residue; no-op for a clean/non-BACKLOG write.
import { readFileSync } from 'node:fs';

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch {}
let input;
try { input = JSON.parse(raw); } catch { process.exit(0); }

const fp = (input && input.tool_input && input.tool_input.file_path || '').replace(/\\/g, '/');
if (!/\/BACKLOG\.md$/i.test(fp)) process.exit(0);   // ACTIVE board only

let body = '';
try { body = readFileSync(fp, 'utf8'); } catch { process.exit(0); }
const lines = body.split(/\r?\n/);

const TOMB = /^\(\s*(?:R-|wave-)[^\n]*(?:(?:->|→)\s*(?:DONE|MERGED|ARCHIVED)\b|\barchived\b)/i;
const tombstones = lines.filter((l) => TOMB.test(l)).length;
const comments   = lines.filter((l) => /^<!--\s*archived/i.test(l)).length;
const doneHdr    = lines.filter((l) => /^###\s+(?:\[DONE\]|✅)/.test(l)).length;
const total = tombstones + comments + doneHdr;
if (total === 0) process.exit(0);

const bits = [];
if (tombstones) bits.push(`${tombstones} tombstone line(s) (R-... -> DONE/archived)`);
if (comments)   bits.push(`${comments} <!-- archived --> comment block(s)`);
if (doneHdr)    bits.push(`${doneHdr} done-badge header(s)`);

console.log(JSON.stringify({
  decision: 'block',
  reason:
    `ARCHIVE-RESIDUE GATE: the active BACKLOG.md still carries ${bits.join(' + ')}. ` +
    `"archive" means the WHOLE card is CUT into the archive ledger -- the active board keeps ZERO residue (the full text lives in the archive). ` +
    `block-backlog-status-drift only checks \`### \` header format, so a parenthesized tombstone (\`(R-\`) and an HTML comment (\`<!--\`) are its structural blind spots; this gate covers them. ` +
    `Clear the residue, then continue (the full text is already in the archive, so this is safe).`,
}));
process.exit(0);
