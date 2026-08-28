#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-fulljourney-dod-on-archive');

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch {}
let input;
try { input = JSON.parse(raw); } catch { process.exit(0); }

const tn = (input && input.tool_name) || '';
const ti = (input && input.tool_input) || {};
let cmd = '';
if (tn === 'Write') cmd = (ti.file_path || '') + '\n' + (ti.content || '');
else if (tn === 'Edit') cmd = (ti.file_path || '') + '\n' + (ti.new_string || '');
else if (tn === 'MultiEdit') cmd = (ti.file_path || '') + '\n' + JSON.stringify(ti.edits || '');
else cmd = ti.command || '';

if (tn === 'Bash' && cmd) {
  for (const m of String(cmd).matchAll(/(?:^|[\s'"])((?:[A-Za-z]:)?[^\s'"|;&]*\.(?:mjs|js|sh))/g)) {
    try {
      const body = readFileSync(m[1].replace(/^["']|["']$/g, ''), 'utf8');
      if (body) cmd += '\n' + body;
    } catch {  }
  }
}

if (!/BACKLOG-archive/.test(cmd)) process.exit(0);
if (tn !== 'Bash' && !/BACKLOG-archive/i.test(String(ti.file_path || ''))) process.exit(0);
if (!/\bDONE\b|\[DONE\]|\bDoD\b/i.test(cmd)) process.exit(0);

const DATA_LAYER_ANCHOR = /data-pipeline\/|<your-data-modules>|published partition|partition field|<your-id-fields>/i;
const hasConsumers = /CONSUMERS:[^\n\r]{10,}/i.test(cmd);
const consumersNA = /CONSUMERS-N\/A:[^\n\r]{15,}/i.test(cmd);
if (DATA_LAYER_ANCHOR.test(cmd) && !hasConsumers && !consumersNA) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'BLOCKED: CONSUMERS-ENUMERATION. This is a data-layer wave (a data-pipeline / canonical / bridge / partition anchor matched), and the card does not enumerate the downstream consumers.\n'
        + 'Three steps before archiving: (a) grep that field or partition for every consumer (each builder and each rendering surface); (b) re-publish, then walk each one; (c) run a partition-key duplicate check over the aggregate views (calendar / list / dashboard).\n'
        + 'FIX: write `CONSUMERS: <the surfaces you walked>` on the card (10+ chars). If no shared data field is touched at all (pure lint / tests only / docs) ⇒ `CONSUMERS-N/A: <reason, 15+ chars>`.\n'
        + 'NOTE: both tokens must be BARE — a `**` or any markdown between the token and its colon and the match fails.',
    },
  }));
  process.exit(0);
}

const forcedWritePath = /WAVE-TYPE:\s*write-?path/i.test(cmd);

const DEPLOY_WAVE = /scripts\/provision\/|deploy\/sudoers|allowlist|<your-deploy-workflow>|verify-state\.sh|<your-runner-workflow>|provision-drift|systemd|sudoers|escalation|privilege|deploy script/i;
const LIVE_RUN = /on the box|live-?run|really ran|actually executed|rc=0[^\n]{0,40}(?:box|deploy)|deploy[^\n]{0,20}rc=|workflow_dispatch/i;
if (DEPLOY_WAVE.test(cmd) && !LIVE_RUN.test(cmd)) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `BLOCKED: a deploy/provision-script wave is being archived, and the DoD holds no evidence that it was RUN FOR REAL ON THE BOX\n\n` +
        `FIX, one of two:\n` +
        `  1. run it once for real (read the runbook first, starting at \`OPS.md\`), and write into the card what you executed, what you observed, and the rc.\n` +
        `     A read-only probe counts as a live run, as long as it really executed on that machine.\n` +
        `  2. it genuinely cannot be run (for instance the lane is schedule-only) ⇒ write ITS NEXT REAL RUN as an explicit DoD item,\n` +
        `     wording it with one of: on the box / live-run / workflow_dispatch.\n` +
        `NOTE: the test is whether you can name the machine, the command, and what you saw. If you cannot, it has not been run.`,
    },
  }));
  process.exit(0);
}

const userFacing = /render|\bpage\b|\bUI\b|\buser\b|\bCTA\b|visual|empty.?state|masthead|locale|\bbutton\b|\bview\b|front-?end|web|contribute|calendar|detail|\blist\b|hero/i.test(cmd) || forcedWritePath;
if (!userFacing) process.exit(0);

const NEG_WINDOW_AFTER = 40;
const NEG_WINDOW_BEFORE = 40;
const VISUAL_TERMS = String.raw`Playwright|screenshot|visual|live-?walk|live-?verif|render.?confirm`;
const JOURNEY_TERMS = String.raw`user.?journey|end-?to-?end|every layer|each layer|entry|→[^\n]{0,4}→|approve.?→.?<your-ingest>|submit.?→`;
const WRITE_TERMS = String.raw`submit|form.?submit|review-?queue|queue|\bclaim\b|awaiting review|enqueue|approve|approved|<your-admin-method>|<your-ingest>|re-?ingest|backfill|live.?render|render.?confirm|public render|reflected on the page`;
const NEG_LEAD = String.raw`(?:NO|no|not|none|owes?|owing|un-?done|to-?do|to be run|to be filled|to be verified|not yet|FOLLOW-UP|carried over)`;
const NEG_TAIL = String.raw`(?:to-?do|to be run|to be filled|to be verified|owed|owing|un-?done|unverified|not yet|FOLLOW-UP|carried over)`;
const stripNegated = (s) => s
  .replace(new RegExp(String.raw`\b${NEG_LEAD}[\s\p{sc=Han}\w]{0,15}(?:${VISUAL_TERMS}|${JOURNEY_TERMS}|${WRITE_TERMS})[^\n\r]{0,${NEG_WINDOW_AFTER}}`, 'giu'), '')
  .replace(new RegExp(String.raw`(?:${VISUAL_TERMS}|${JOURNEY_TERMS}|${WRITE_TERMS})[^\n\r]{0,${NEG_WINDOW_BEFORE}}${NEG_TAIL}`, 'giu'), '');
const cmdSemantic = stripNegated(cmd);

const hasJourney = /user.?journey|end-?to-?end|every layer|each layer|entry.?→|→.*→.*→|approve.?→.?<your-ingest>|submit.?→/i.test(cmdSemantic);
const hasVisual = /Playwright|screenshot|visual confirm|visually verified|live-?walk|live-?verif|render.?confirm/i.test(cmdSemantic);

const explicitVisualNA = /VISUAL-N\/A:[^\n\r]{15,}/i.test(cmd);

const shortcutEntry = /\?code=[a-z_]+|inject[a-z_\s]{0,14}(?:<your-auth-prefix>-?)?outcome|outcome[-_=][a-z_]+[^\n]{0,16}cookie|(?:hit|open)[^\n]{0,16}(?:error|result|state)[^\n]{0,4}page/i.test(cmd);

const WRITE_PATH_SIGNAL = /correction|apply-?chain|apply-?registry|apply-?wire|\bapply\b|review-?queue|\bapprove\b|\breview\b|\breject\b|elevated-session|\bsubmit(?:ted)?\b|contribute|\bform\b|\beditor\b|\bedit\b|\bsave\b|\bpersist(?:ent)?\b|\bmutation\b|back-?office|queue-?action|admin[-\s]?action|user submission|write-?path|\bwrite\b/i;
const isWritePath = WRITE_PATH_SIGNAL.test(cmd) || forcedWritePath;
const WRITE_STAGES = [
  /submit|form.?submit|user submission/i,
  /review-?queue|queue|\bclaim\b|awaiting review|enqueue/i,
  /approve|approved|admin.?approve|<your-admin-method>/i,
  /<your-ingest>|re-?ingest|pipeline|backfill/i,
  /live.?render|render.?confirm|live page|public render|reflected on the page/i,
];
const writeStages = WRITE_STAGES.reduce((n, re) => n + (re.test(cmdSemantic) ? 1 : 0), 0);
const hasWriteJourney = writeStages >= 3;
const explicitWriteJourneyNA = /WRITE-JOURNEY-N\/A:[^\n\r]{15,}/i.test(cmd);

const readOK = (hasJourney && hasVisual && !shortcutEntry) || explicitVisualNA;
const writeOK = !isWritePath || hasWriteJourney || explicitWriteJourneyNA;

if (readOK && writeOK) process.exit(0);

const miss = [];
if (!readOK) {
  if (!hasJourney) miss.push('the journey is NOT spelled out — write the arrow chain (entry action -> each layer -> final result), e.g. submit->admin->approve-><your-ingest>->live-render, not a single endpoint. "journey to-do" and "FOLLOW-UP carried over" are stripped before matching');
  if (!hasVisual) miss.push('NO visual/live verify — a render or UX assertion needs a Playwright screenshot you actually LOOKED AT, not psql/curl/DOM counts. Provable but not visible ⇒ write the bare token `VISUAL-N/A: <reason, 15+ chars>` (no markdown between token and colon)');
  if (shortcutEntry) miss.push('the journey is triggered by a SHORTCUT (a forged `?code=` parameter or an injected outcome marker) — start from a real user action: a real OAuth sign-in, a real form submit, a real CTA click');
}
if (!writeOK) miss.push('the WRITE journey is NOT walked — this wave introduced a write path (submit / apply / approve / editor-save), so the DoD has to walk it for real: real user SUBMIT -> review-queue -> admin approve (with an elevated session) -> re-ingest -> live-render confirmed by looking at a screenshot (3+ legs, written as an arrow chain). A read-only walk is not enough. Genuinely no write path ⇒ the bare token `WRITE-JOURNEY-N/A: <reason, 15+ chars>` (no reason, no release)');

console.log(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      `BLOCKED: FULL-JOURNEY-DoD. A user-visible card is being archived as DONE with an incomplete DoD — ${miss.join('; AND ')}\n`
      + `FIX: walk it first-hand from the entry action through every layer to the final result; use an elevated session for the admin write step (see your admin-access runbook).\n`
      + `Then record in the card's DoD: the user journey (…→…→…), the visual verification (screenshot / Playwright), and for a write-path wave the write chain. Then archive.`,
  },
}));
process.exit(0);
