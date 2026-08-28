#!/usr/bin/env node
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { projectPaths } from './lib/is-autoloop-lead.mjs';

const allow = () => { process.stdout.write('{}'); process.exit(0); };
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let payload;
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }
if (String(payload.tool_name || '') !== 'Agent') allow();

const ti = payload.tool_input || {};
if (String(ti.subagent_type || '') !== 'planner') allow();

const prompt = String(ti.prompt || '');
const slug = (prompt.match(/^#\s*CARD:\s*(R-[a-z0-9-]+)/im) || [])[1];
if (!slug) allow();

const OPLOG_DIR = projectPaths()?.claude || '';
const SPEC_DIR = projectPaths()?.specs || '';

const originCite = (prompt.match(/(autoloop-log-[\w.-]+\.md):(\d+)/i) || []);
const originOk = /#\s*NO-ORIGIN:\s*\S/i.test(prompt)
  || (originCite[1] && existsSync(`${OPLOG_DIR}/${originCite[1]}`));

const CONSTRAINT_CLAIM = /by design|structurally (?:cannot|impossible)|not permitted|\b(?:needs?|requires?) root\b|\bno (?:permission|access|rights)\b|\b(?:cannot|can not|cannot be|unable to)\s+(?:be\s+)?(?:done|written|read|reached|obtained|installed|granted)\b|only .{0,12}can/i;
const needsOwner = CONSTRAINT_CLAIM.test(prompt);
const ownerCite = (prompt.match(/#\s*CONSTRAINT-OWNER:\s*([^\n]+)/i) || [])[1] || '';
const stemOfCard = slug.replace(/^R-/, '').split('-').slice(0, 2).join('-');
const ownerSpecs = [...new Set(ownerCite.match(/R-[a-z0-9-]+/gi) || [])]
  .filter((s) => {
    if (!existsSync(SPEC_DIR)) return false;
    const hit = readdirSync(SPEC_DIR).some((f) => f.startsWith(`${s}-`) || f === `${s}.md`);
    return hit && !s.toLowerCase().includes(stemOfCard.toLowerCase());
  });
const ownerOk = !needsOwner
  || /^\s*(?:none|N-?A)\b/i.test(ownerCite)
  || ownerSpecs.length > 0;

const shipOk = /#\s*SHIP:\s*\S/i.test(prompt);

if (originOk && ownerOk && shipOk) allow();

const rows = [];
if (!originOk) {
  rows.push(
    '  `# ORIGIN:` — **where this wave came from**\n'
    + '      Cite its birth entry in the op-log: `# ORIGIN: autoloop-log-<...>.md:<line> · <one sentence>`\n'
    + '      That entry is one YOU wrote, so there is nothing to search for. And it usually answers both\n'
    + '      "should this be a wave" and "how does the result reach production" — measured: one `sudo -n -l`\n'
    + '      table said both "the logs cannot be read, so open a wave" and "and it cannot be installed either",\n'
    + '      and only the first half was read. Genuinely no origin (asked for directly, or an audit finding) ⇒ `# NO-ORIGIN: <reason>`',
  );
}
if (!ownerOk) {
  rows.push(
    '  `# CONSTRAINT-OWNER:` — **who decided this limit**\n'
    + '      The brief contains a LIMIT CLAIM ("cannot be done", "no permission", "by design", "needs root").\n'
    + '      Once a limit is confirmed TRUE there is a second question: was it DESIGNED that way?\n'
    + '      Write: `# CONSTRAINT-OWNER: R-<the wave that owns the constraint> · <the section that ruled it>`\n'
    + `      NOTE: it has to be a DIFFERENT family — searching by this card's slug (\`${stemOfCard}\`) only finds the card's own family,\n`
    + '      and the owner of a constraint shares no literal token with the card slug, so **searching by slug structurally cannot find it**.\n'
    + '      Measured: a 17-document family was never searched at all, and one of the options then put to the user\n'
    + '      was the exact thing a plan in that family forbade, verbatim.\n'
    + '      Confirmed unrelated ⇒ `# CONSTRAINT-OWNER: none` (it is an assertion, not an incantation)',
  );
}
if (!shipOk) {
  rows.push(
    '  `# SHIP:` — **which action carries this to production after it merges**\n'
    + '      Write: `# SHIP: <action> · owner=<lead|user|auto>`. If you do not know, write `# SHIP: unknown — needs a ruling`.\n'
    + '      This question is a DELIVERABLE of the wave, not a footnote. Measured: one PR passed the whole pipeline,\n'
    + '      18 F-gates green, APPROVED, merged — and production changed by zero bytes, because no baton was ever asked.\n'
    + '      Same lineage downstream: the architecture\u2019s `§S Ship action` (required) and the `- ship: … ran=` field at DoD time.',
  );
}

deny(
  `BLOCKED: the planner brief is missing its named anchors — these three cannot rely on anyone remembering\n`
  + `\n`
  + `  card: ${slug}\n\n`
  + rows.join('\n\n') + '\n\n'
  + `Why fields and not habits: all three of these used to be "I should remember to do it", and all three were missed at once.\n`
  + `Each one alone looks like an oversight; together they are a wave that walked the whole pipeline, was APPROVED, merged, and did nothing.\n`
  + `**Writing an obligation into a greppable field** is this repo's standard answer to that class (principles, Write state into machine-read fields).`,
);
