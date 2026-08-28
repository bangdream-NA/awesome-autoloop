#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-admin-dod-as-usergated');

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch {}
let input;
try { input = JSON.parse(raw); } catch { process.exit(0); }
const cmd = (input && input.tool_input && input.tool_input.command) || '';

if (!/BACKLOG\.md/.test(cmd)) process.exit(0);
if (!/\[USER-GATED\]/.test(cmd)) process.exit(0);

const adminWalled = /admin[-\s]?wall|admin access|elevated-session|real sign-?in|real admin|admin session|<your-admin-method>|approve[\s-]*<your-ingest>|review-queue|admin-gated|admin half|submit[\s-]*queue/i.test(cmd);
const trueUserGate = /real OAuth|email[-\s]?mismatch|specific inbox|irreversible|infra decision|payment|the user(?:'s)?.{0,12}(copy|design|lock|ruling|entity)|NOT[-\s]?<your-admin-method>|<your-admin-method>[-\s]?N\/?A/i.test(cmd);

if (adminWalled && !trueUserGate) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `BLOCKED: ADMIN-DoD is not USER-GATED. This card is written as [USER-GATED], but what blocks it is a DoD behind the ADMIN WALL — and that is reachable with an elevated session (see your admin-access runbook). Walk the admin half (submit -> queue -> approve -> ingest -> render) first-hand; do not hand it to the user as "waiting for a real sign-in".
FIX: change it to [QUEUED] and have the lead walk it with the elevated-session.
Exception: the elevated-session route really is unreachable (a real OAuth email mismatch that needs a specific inbox / irreversible infrastructure / a payment / the user's own copy or design ruling) ⇒ write the exact reason on the card (for example "NOT-<your-admin-method>: real OAuth email-mismatch"), and only then may it be USER-GATED.`,
    },
  }));
  process.exit(0);
}
process.exit(0);
