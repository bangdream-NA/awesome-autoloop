#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { isDodFailed } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-dod-pending-archive');

let raw = ''; try { raw = readFileSync(0, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }
let j; try { j = JSON.parse(raw); } catch { process.stdout.write('{}'); process.exit(0); }
const tn = j && j.tool_name || '';
const ti = (j && j.tool_input) || {};

let text = '', fp = '';
if (tn === 'Bash') { text = ti.command || ''; }
else if (tn === 'Write') { fp = ti.file_path || ''; text = fp + '\n' + (ti.content || ''); }
else if (tn === 'Edit') { fp = ti.file_path || ''; text = fp + '\n' + (ti.new_string || ''); }
else if (tn === 'MultiEdit') { fp = ti.file_path || ''; text = fp + '\n' + JSON.stringify(ti.edits || ''); }
else { process.stdout.write('{}'); process.exit(0); }

if (tn !== 'Bash' && !/BACKLOG-archive/i.test(String(fp || ''))) { process.stdout.write('{}'); process.exit(0); }

const targetsArchive = /BACKLOG-archive/.test(text);
if (!targetsArchive) { process.stdout.write('{}'); process.exit(0); }

const pending = /DoD[-\s]?PENDING|DoD pending|DoD not (?:yet )?done|pending[^\n]{0,45}(republish|regen|host[-\s]?setup|Playwright|live[-\s]?verif|deploy|server-op|backfill)|batched[^\n]{0,25}(server-op|republish|DoD)/i;
const resolved = /DoD[-\s]?(VERIFIED|DONE|PASS|COMPLETE)|DoD ✅|✅[^\n]{0,3}(COMPLETE|DONE|VERIFIED)|VERIFIED LIVE/i;

if (isDodFailed(text)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'DoD-FAILED CARD CANNOT BE ARCHIVED: the card carries `dod-failed-at=<ISO Z>` with no later `dod-failed-cleared-at=` — the DoD ran and FAILED, so what is live is broken. Archiving it unbinds the dispatch lock: the board goes quiet while the thing stays broken.\n'
        + 'FIX, one of three: (1) fix it, re-run the DoD, record `dod-failed-cleared-at=<ISO Z>` (read back from `date -u +%Y-%m-%dT%H:%M:%SZ`) with evidence, then archive; (2) leave the card ACTIVE — a failed DoD reopens work, and [QUEUED]/[IN-DEV] is the honest state; (3) the DoD-FAILED record is itself wrong ⇒ correct it first, with first-hand LIVE evidence.',
    },
  }));
  process.exit(0);
}

const GATED_RE = /DoD[-\s]?(GATED|BLOCKED)/gi;
const TRANSFER_RE = /carried over|\[\[R-[A-Za-z0-9-]+\]\]|→\s*(?:card\s+)?R-[a-z0-9-]+|->\s*(?:card\s+)?R-[a-z0-9-]+|debt[-\s]?card/i;
let lastGated = -1, gm;
while ((gm = GATED_RE.exec(text)) !== null) lastGated = gm.index;
let lastVerified = -1;
const VER_RE = /DoD[-\s]?(VERIFIED|DONE|PASS|COMPLETE)|DoD ✅|VERIFIED LIVE/gi;
let vm; while ((vm = VER_RE.exec(text)) !== null) lastVerified = vm.index;
if (lastGated > -1 && lastGated > lastVerified && !TRANSFER_RE.test(text)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'GATED-DoD CARD CANNOT BE ARCHIVED WITHOUT A DEBT TRANSFER: the card carries a LIVE DoD-GATED / DoD-BLOCKED obligation (the last DoD word is GATED, with no later DoD-VERIFIED closing it). Archiving it deletes that debt silently from every tracker.\n'
        + 'FIX, one of three: (1) do the gated DoD now, write the DoD-VERIFIED evidence, then archive; (2) leave the card active ([BLOCKED] plus observe-until / owner); (3) file a successor debt card on the ACTIVE board and reference it from this card (carried over [[R-<slug>]] / -> card R-<slug>), then archive.',
    },
  }));
  process.exit(0);
}

if (pending.test(text) && !resolved.test(text)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'DoD-PENDING CARD CANNOT BE ARCHIVED: the card being archived carries a DoD-incomplete marker (DoD-PENDING / pending republish|regen|Playwright|verify / batched server-op / backfill-pending), and the same block of text holds no DoD-VERIFIED closing it out.\n'
        + 'FIX: finish the card\u2019s DoD and verify it LIVE (populate / republish / Playwright), write the DoD-VERIFIED evidence into the card, then archive; or leave the card active until the DoD is done.\n'
        + 'NOTE: if the pending marker is a DECOUPLED follow-up and the DoD itself was verified ⇒ write that DoD-VERIFIED line explicitly, so there is no ambiguity.',
    },
  }));
  process.exit(0);
}
process.stdout.write('{}');
process.exit(0);
