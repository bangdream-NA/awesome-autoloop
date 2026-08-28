#!/usr/bin/env node
import { readFileSync } from 'node:fs';

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(payload.tool_name || '');
if (!/^(Write|Edit|MultiEdit)$/.test(tool)) allow();

const ti = payload.tool_input || {};
const file = String(ti.file_path || '').replace(/\\/g, '/');
if (!/\/docs\/product-specs\/R-[^/]*-architecture\.md$/i.test(file)) allow();

let before = '';
try { before = readFileSync(file, 'utf8'); } catch { before = ''; }

let after = '';
if (tool === 'Write') {
  after = String(ti.content || '');
} else if (tool === 'Edit') {
  const o = String(ti.old_string || '');
  after = o ? before.split(o).join(String(ti.new_string || '')) : before + String(ti.new_string || '');
} else {
  after = (ti.edits || []).reduce((acc, e) => {
    const o = String(e.old_string || '');
    return o ? acc.split(o).join(String(e.new_string || '')) : acc + String(e.new_string || '');
  }, before);
}
if (!after.trim()) allow();

const IS_REAL_ARCH = /^#{1,3}\s*(?:§A\b|File Map\b)/im.test(after) || /^\|\s*path\s*\|/im.test(after);
if (!IS_REAL_ARCH) allow();

const SHIP_SECTION_RE = /^#{1,4}\s*§S\b[^\n]*\n([\s\S]{0,600})/im;
const sec = after.match(SHIP_SECTION_RE);

if (!sec) {
  deny(
    `BLOCKED: the architecture document has no **§S Ship action** — no section answers "which action carries this to production after it merges"\n\n`
    + `  file: ${file.split('/').slice(-1)[0]}\n\n`
    + `FIX. Add the section; one line is enough to start:\n`
    + `    ## §S Ship action\n`
    + `    <the action that carries this to production after it merges> · owner=<lead|user|auto>\n`
    + `Check it against the table in \`docs/runbooks/OPS.md\` §1: if a path in the File Map matches one of its rows, name that row;\n`
    + `if it matches no row, THAT GAP IS AN ITEM OF THIS WAVE. If the action needs a person, say which person.\n`
    + `Genuinely no ship action ⇒ \`SHIP-N/A: <why this diff needs no manual action>\`.`,
  );
}

const body = sec[1].trim();
const isNA = /^SHIP-N-?A\s*:\s*\S/i.test(body);
const hasOwner = /\bowner=(lead|user|auto)\b/i.test(body);

if (!isNA && !hasOwner) {
  deny(
    `BLOCKED: §S Ship action exists, but does not say WHO EXECUTES IT — \`owner=\` is missing\n\n`
    + `  file: ${file.split('/').slice(-1)[0]}\n`
    + `  the current first paragraph of §S: "${body.slice(0, 120)}"\n\n`
    + `FIX: \`<action> · owner=<lead|user|auto>\`, or make the whole section \`SHIP-N-A: <reason>\`.`,
  );
}

allow();
