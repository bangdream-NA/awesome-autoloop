#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-frozen-knowledge-append');

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }

let fp = '';
let isCreate = false;
try {
  const j = JSON.parse(raw);
  const ti = (j && j.tool_input) || {};
  fp = ti.file_path || ti.path || '';
  isCreate = false;
} catch { process.stdout.write('{}'); process.exit(0); }

const norm = String(fp).replace(/\\/g, '/');

const FROZEN = [
  { re: /[\/\\]\.claude[\/\\]knowledge[\/\\]common[\/\\]data-pipeline\.md$/i, what: '~/.claude/knowledge/common/data-pipeline.md' },
  { re: /[\/\\]\.claude[\/\\]knowledge[\/\\]common[\/\\]web-frontend\.md$/i, what: '~/.claude/knowledge/common/web-frontend.md' },
  { re: /[\/\\]\.claude[\/\\]knowledge[\/\\]common[\/\\]verification-recipes-live-[a-z0-9-]+\.md$/i, what: '<config dir>/knowledge/common/verification-recipes-live-<project>.md' },
];

const hit = FROZEN.find((f) => f.re.test(norm));
if (hit && !isCreate) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'BLOCKED: a FROZEN knowledge baseline may not be appended to or edited inside a wave: `' + hit.what + '`\n\n' +
        'FIX: contribute ONE NEW FILE, self-indexed by its filename:\n' +
        '  • a knowledge fragment  -> <knowledge root>/fragments/<topic>--<yyyymmdd>-<wave-slug>.md\n' +
        '  • a role note           -> <knowledge root>/<role>/<slug>.md\n' +
        '  • the cross-project tier -> <config dir>/knowledge/<role|common>/<slug>.md\n' +
        'Readers are told to `ls fragments/` and open every filename that matches their task, so a new file is discoverable WITHOUT an index line.\n' +
        'A genuine factual ERROR inside a frozen file (as opposed to an append) is a separate docs PR owned by the lead. Hand it over; do not fix it inside your wave.',
    },
  }));
  process.exit(0);
}

process.stdout.write('{}');
process.exit(0);
