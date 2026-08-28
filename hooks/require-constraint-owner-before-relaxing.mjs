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
if (!/^(Write|Edit|MultiEdit)$/.test(String(payload.tool_name || ''))) allow();

const tin = payload.tool_input || {};
const target = String(tin.file_path || '').replace(/\\/g, '/');
if (!/(BACKLOG[^/]*\.md|docs\/product-specs\/[^/]+\.md)$/i.test(target)) allow();

const introduced = [tin.content, tin.new_string,
  ...(Array.isArray(tin.edits) ? tin.edits.map((e) => e && e.new_string) : [])]
  .filter(Boolean).join('\n');
if (!introduced) allow();

const LOOSEN = '(?:remove|removing|drop|dropping|delete|deleting|disable|disabling|relax|relaxing|loosen|loosening|bypass|waive|waiving|turn off|lift|downgrade|make it looser)';
const CONSTRAINT = '(?:sticky|setgid|setuid|ACL|acl|chmod|chown|permission bits?|sudoers|allow-?list|allowlist|deny-?list|routable|locked decision|USER LOCK|fail-closed)';
const CITATION = /[A-Za-z0-9_.\-/]+\.(?:md|ts|tsx|mjs|js|sh|json|yml|yaml):\d+/;

const LOOSEN_RE = new RegExp(LOOSEN, 'i');
const CONSTRAINT_RE = new RegExp(CONSTRAINT);

const hits = [];
for (const raw of introduced.split(/\r?\n/)) {
  // The sentence split fires on terminal punctuation FOLLOWED BY WHITESPACE. Without that lookahead
  // an ASCII period splits inside a file path — `hardening.md:88` becomes `hardening.` plus `md:88` —
  // and the citation lands in a different fragment from the proposal it is supposed to justify. The
  // effect is that the way out this gate documents cannot be taken in the natural word order:
  // "remove the sticky bit, it is set at docs/runbooks/hardening.md:88" is denied, and the denial
  // asks for the citation that is already there. Measured against every shape a citation takes.
  for (const s of raw.split(/(?<=[.;!?])(?=\s|$)|·/)) {
    if (!LOOSEN_RE.test(s) || !CONSTRAINT_RE.test(s)) continue;
    if (CITATION.test(s)) continue;
    hits.push(s.trim().slice(0, 110));
  }
}
if (!hits.length) allow();

deny(
  `BLOCKED: an option proposes RELAXING a constraint without citing THE LINE THAT DEFINES IT. ${hits.length} sentence(s) matched:\n`
  + hits.slice(0, 3).map((h) => `    · ${h}`).join('\n') + '\n'
  + `Add a file:line to that same sentence (or a §A-x / AC-n) — where the definition you read actually lives.\n`
  + `Search by the CONSTRAINT'S OWN IDENTIFIER, not by the card slug: sticky · setfacl · 1775 · the field name. A zero result needs a must-hit control.\n`
  + `Cannot cite the line ⇒ "remove it" does not go into any artifact. A security bit set deliberately and one set carelessly are byte-identical in stat's output.\n`
  + `Measured: "remove the sticky bit from .git" was written onto a card while it was a designed control in a hardening runbook,\n`
  + `whose next paragraphs argued verbatim that the bit blocks exactly the escalation an AC named. The rule was already written down, and it was still violated.\n`
  + `NOTE: merely RELAYING someone else's proposal ⇒ say in the same sentence which line you are relaying it FROM. That is the citation this gate wants.`,
);
