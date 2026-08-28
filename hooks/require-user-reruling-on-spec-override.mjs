#!/usr/bin/env node
//   `:8` the file table held only `Footer.tsx` + `globals.css` + one e2e — **the component in question was not in it**.
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-user-reruling-on-spec-override');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8')); } catch { allow(); }

const tool = String(payload.tool_name || '');
const ti = payload.tool_input || {};
const fp = String(ti.file_path || '').replace(/\\/g, '/');

if (!/\/docs\/product-specs\/[^/]+\.md$/i.test(fp)) allow();

let added = '';
if (tool === 'Write') added = String(ti.content || '');
else if (tool === 'Edit') added = String(ti.new_string || '');
else if (tool === 'MultiEdit') added = (ti.edits || []).map((e) => String(e.new_string || '')).join('\n');
else allow();
if (!added.trim()) allow();

const CROSS_WAVE_HINT = /mother wave|parent wave|another wave|a different wave|upstream wave|other wave|previous wave|sibling wave/i;
const OVERRIDE_PROSE = /\b(overrid(?:e|ing|den)|reversing|revoke[sd]?|overturn(?:s|ed|ing)?|void(?:s|ed)?)\b|fails this wave|deliberately declined|declined by the mother/i;
const SUPERSEDES = /\bSUPERSEDES?\b|\breplaces\b/i;
const SELF_REVISION = /\b([A-Z]+-\d+)-r\d+\s+SUPERSEDES\s+\1\b|\b(?:this|the same) wave\b|\bwithin this wave\b|its own r\d/i;

const hasOverride = OVERRIDE_PROSE.test(added) || (SUPERSEDES.test(added) && CROSS_WAVE_HINT.test(added));
if (!hasOverride) allow();
if (SELF_REVISION.test(added) && !OVERRIDE_PROSE.test(added)) allow();

const RERULING = /^-\s*user-reruling\s*:/m
  || false;
const HAS_ANCHOR =
  /^-\s*user-reruling\s*:/m.test(added) ||
  (/\b(?:the user|USER LOCK)\b/i.test(added) && /20\d\d-\d\d-\d\d/.test(added) && /(AskUserQuestion|re-?rul|USER LOCK)/i.test(added));

if (HAS_ANCHOR) allow();

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      `BLOCKED: this spec OVERTURNS another wave's settled choice, with no anchor showing the user RE-RULED\n\n` +
      `  matched: ${JSON.stringify((added.match(OVERRIDE_PROSE) || ['(none — triggered by SUPERSEDES plus a cross-wave hint)'])[0])}\n` +
      `  vocabulary: \`override/overriding/overridden\` · \`reversing\` · \`revoke(s|d)\` · \`overturn\` · \`void\` · ` +
      `\`fails this wave\` · \`deliberately declined\` · \`declined by the mother\`\n\n` +
      `FIX, one of two:\n` +
      `  1. do not overturn it — build to the design the upstream locked, and write the conflict as an Open Question for the lead to put to the user\n` +
      `  2. it really was re-ruled ⇒ add the anchor line **in this same write**:\n` +
      `     - user-reruling: <ISO Z>, re-ruled via AskUserQuestion, <the new ruling>; the previous <old ruling> is void\n` +
      `Exemption: the word is only incidental ("the reading is void") ⇒ use a word that is not in the vocabulary. **Do not add a fake anchor.**`,
  },
}));
process.exit(0);
