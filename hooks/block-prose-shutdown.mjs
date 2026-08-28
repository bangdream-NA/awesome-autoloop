#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { stripQuoted } from './lib/transcript-last-assistant.mjs';
import { recordShutdownSent, canTaskStop } from './lib/shutdown-ledger.mjs';
autoLogOnDeny('block-prose-shutdown', 'prose-shutdown-not-structured');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let payload = '';
try { payload = readFileSync(0, 'utf8'); } catch { allow(); }

let parsed;
try { parsed = JSON.parse(payload) || {}; } catch { allow(); }
const inp = parsed.tool_input || {};

if (parsed.tool_name === 'TaskStop') {
  const t = String(inp.task_id || '<agent>');
  const verdict = canTaskStop(parsed.session_id || '', t);
  if (verdict.ok) allow();
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
`BLOCKED: \`TaskStop\` is not available yet — ${verdict.why}

The test: a REAL shutdown_request was sent, then end-turn, then end-turn again — two consecutive turns.

FIX. Send this now, to \`${t}\`:

  SendMessage({
    to: "${t}",
    message: { "type": "shutdown_request", "reason": "<why it can be shut down now>" }
  })

The test: it counts as sent only when the receipt carries \`Request ID: shutdown-…@${t}\`.
Then **end the turn**. Do not re-read the roster in the same turn — that reading has zero discriminating power.`,
    },
  }));
  process.exit(0);
}

const msg = inp.message;

if (msg && typeof msg === 'object') {
  if (msg.type === 'shutdown_request') recordShutdownSent(parsed.session_id || '', inp.to);
  allow();
}
if (typeof msg === 'string') {
  try { const o = JSON.parse(msg); if (o && typeof o === 'object' && o.type) allow(); } catch {  }
}
if (typeof msg !== 'string') allow();

if (/#\s*PROSE-SHUTDOWN-OK:\s*\S/.test(msg)) allow();

const bare = stripQuoted(msg);
const SHUTDOWN_INTENT = new RegExp([
  'shutdown_request',
  '\\bshutdown\\b(?!\\s*_)',
  'stand[ -]?down',
  '\\b(?:you)\\s*(?:can|may|should|could)\\s*(?:now\\s+)?(?:shut\\s*down|stand\\s*down|stop|wrap\\s*up|close\\s*out|log\\s*off|sign\\s*off)\\b',
  '\\byou(?:\\s+are|\'re)\\s+(?:all\\s+)?done\\b',
  '\\bno\\s+(?:further|more)\\s+work\\b',
  '\\bnothing\\s+more\\s+for\\s+you\\s+to\\s+do\\b',
  '\\bplease\\s+(?:shut\\s*down|stand\\s*down|wrap\\s*up\\s+and\\s+stop|stop\\s+working)\\b',
  '\\bshut(?:ting|s)?\\s+(?:you|him|her|them|it)\\s+down\\b',
  'shut (?:it|you) down(?:,? please|,? then)?',
  '(?:approve|approved|allow|permit)(?: you)? to shut down',
  '(?:you can|please|now) (?:shut down|stop|stand down|wrap up|clock off)',
  'shut yourself down|stop yourself|you can clock off',
].join('|'), 'i');
if (!SHUTDOWN_INTENT.test(bare)) allow();

const to = String(inp.to || '(unspecified)');
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
`BLOCKED: a prose-shaped shutdown order — the harness cannot read it, and the agent is never removed from the roster. Recipient: ${to}
Your message is a plain string that mentions \`shutdown_request\`. It will be delivered, the agent will reply "ok, shutting down" — and it is still alive, so any later SendMessage wakes it up again.

FIX (pass \`message\` as an OBJECT, not a string):

  SendMessage({
    to: "${to}",
    message: { "type": "shutdown_request", "reason": "<why it can be shut down now>" }
  })

The test: the correct form returns \`Request ID: shutdown-…@${to}\`. No such line in the receipt means it did not take effect.
Exemption: you really are discussing the protocol in prose ⇒ add one line to the message: \`# PROSE-SHUTDOWN-OK: <reason>\`.`,
  },
}));
process.exit(0);
