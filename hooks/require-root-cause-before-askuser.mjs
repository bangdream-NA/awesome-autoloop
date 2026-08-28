#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { MEASURED_RE, RULED_OUT_RE } from './lib/measured-markers.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-root-cause-before-askuser', 'askuser-without-root-cause');

const allow = () => { process.stdout.write('{}'); process.exit(0); };

let payload = '';
try { payload = readFileSync(0, 'utf8'); } catch { allow(); }
let stdin = {}, inp;
try { stdin = JSON.parse(payload) || {}; inp = stdin.tool_input || {}; } catch { allow(); }

const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

const qs = Array.isArray(inp.questions) ? inp.questions : [];
if (!qs.length) allow();

const text = qs.map((q) => [q.question, q.header,
  ...(Array.isArray(q.options) ? q.options.map((o) => `${o.label} ${o.description}`) : [])].join('\n')).join('\n\n');

const BOX_RE = new RegExp([
  ...(process.env.AAL_PROD_HOSTS || '').split(',').map((h) => h.trim()).filter(Boolean),
  '/srv/', 'deploy@',
  'root console', 'rescue console', 'VNC', 'IPMI', 'out-of-band console',
  'systemctl', 'systemd', 'daemon-reload', 'systemd-analyze', 'unit file', '\\.timer\\b',
  'sudoers', 'setfacl', 'chown', 'wrapper', 'break-?glass',
  '\\bssh\\b', 'deploy\\.sh', '18-app-deploy', 'republish', 'ingest',
  'production box', 'on the server', 'the go-live step', '\\bVPS\\b',
].join('|'), 'i');

if (BOX_RE.test(text)) {
  let readRunbook = false;
  try {
    const tp = String(stdin.transcript_path || '');
    if (tp) {
      for (const raw of readFileSync(tp, 'utf8').split(/\r?\n/)) {
        if (!raw.trim()) continue;
        let j; try { j = JSON.parse(raw); } catch { continue; }
        const content = j?.message?.content;
        if (!Array.isArray(content)) continue;
        for (const c of content) {
          if (c?.type !== 'tool_use' || c?.name !== 'Read') continue;
          if (/\/docs\/runbooks\//i.test(String(c?.input?.file_path || '').replace(/\\+/g, '/'))) {
            readRunbook = true; break;
          }
        }
        if (readRunbook) break;
      }
    }
  } catch {  }

  if (!readRunbook) {
    deny(`BLOCKED: this question is ABOUT the production box, and no runbook was Read this turn

FIX: read first, then ask — the answer is usually already in there:
  Read <your-repo>/docs/runbooks/OPS.md                       # the ship actions, and who owns each step
  Read <your-repo>/docs/runbooks/app-deploy.md                # deploying, and the failure modes it has
  Read <your-repo>/docs/runbooks/observability.md             # which console you can and cannot paste into
  Read <your-repo>/docs/runbooks/service-user-hardening.md    # identity, sudoers, break-glass

NOTE: \`grep docs/runbooks/\` does NOT count — it proves you scanned for a word, not that you read the section.`);
  }
}

if (/#\s*ROOT-CAUSE-NA:\s*\S/.test(text)) allow();

const FAULT_RE = new RegExp([
  '\\b(?:blocked|failed|failing|red|broken|error|rejected|stuck|regress\\w*|drift\\w*|stale|out of date)\\b',
  '\\b(?:404|500|502|503|504)\\b',
  '\\b(?:went red|turned red|still red|all red|flagged red)\\b',
  '\\b(?:crashed|blew up|died|hung|hanging|threw|throwing|refused|denied|wedged|jammed)\\b',
  '\\b(?:regression|drifted|expired|inconsistent|mismatch\\w*|anomal\\w*|off|cannot push|interrupted|lost|dropped out)\\b',
  '\\b(?:will not open|cannot connect|cannot reach|will not start|will not run|cannot get)\\b',
  '\\b(?:no output|not taking effect|no effect|no response|unresponsive|timed out|timeout|blank page|white screen)\\b',
].join('|'), 'i');
if (!FAULT_RE.test(text)) allow();

const hasMeasure = MEASURED_RE.test(text);
const hasRuledOut = RULED_OUT_RE.test(text);
if (hasMeasure && hasRuledOut) allow();

const missing = [
  hasMeasure ? null : '**one real measurement** (a quoted command / `rc=` / `file:line` / an ISO date / "measured" / "I ran")',
  hasRuledOut ? null : '**one exclusion** (a must-hit control / a different corpus / both legs / "ruled out" / "refuted" / "root cause")',
].filter(Boolean).map((s) => '  · missing ' + s).join('\n');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
`BLOCKED: this question describes a FAULT, and the body shows no root cause

${missing}

Do these three first; they are almost always cheaper than asking:
  1. run it again — separate a one-off flake from a stable reproduction. Two readings have to agree before it counts as reproduced.
  2. change the CORPUS, not the person running the command — take the same command to the other end (another branch, the main checkout, another project).
  3. compare the two ends WITH a must-hit control — if the subject and the control give the same number (0 or 1), suspect the control first.

NOTE: a gate's message is not a diagnosis. It is usually a hardcoded string and prints the same sentence whatever triggered it.
Exemption: genuinely not a fault, or already diagnosed ⇒ add one line to the body: \`# ROOT-CAUSE-NA: <reason>\`.`,
  },
}));
process.exit(0);
