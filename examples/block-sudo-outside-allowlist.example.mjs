#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { logDenial } from './lib/log-denial.mjs';

const ALLOWED = [
  /^sudo\s+systemctl\s+(restart|stop|start|status)\s+<your-runner-service>(\.service)?(\s|$)/,
  /^sudo\s+journalctl\s+-u\s+\S+/,
  /^sudo\s+pkill\s+-u\s+ci-runner\b/,
];
const ACCEPTED_TEXT =
  'sudo systemctl restart|stop|start|status <your-runner-service>  ·  ' +
  'sudo journalctl -u <unit>  ·  sudo pkill -u ci-runner';

function allow() { process.stdout.write('{}'); process.exit(0); }

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch { allow(); }
let cmd = '';
try { cmd = String(JSON.parse(raw)?.tool_input?.command ?? ''); } catch { allow(); }
if (!cmd) allow();

if (/#\s*SUDO-ALLOWLIST-OK:/.test(cmd)) allow();

const noHeredoc = cmd.replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[\s\S]*?^\s*\2\s*$/gm, ' ');
const noQuoted = noHeredoc.replace(/'[^']*'|"[^"]*"/g, ' ');

const CMD_POS = /(?:^|\n|&&|\|\||;|\||\()\s*(sudo\s+[^\n&;|)]*)/g;
const SSH_POS = /\bssh\s+(?:-\S+\s+)*\S+\s+(sudo\s+[^\n&;|)]*)/g;
const WSL_POS = /\bwsl(?:\.exe)?\s+(?:-\S+(?:\s+(?!sudo\b)\S+)?\s+)*(sudo\s+[^\n&;|)]*)/g;
const found = [
  ...[...noQuoted.matchAll(CMD_POS)].map((m) => m[1]),
  ...[...noQuoted.matchAll(SSH_POS)].map((m) => m[1]),
  ...[...noQuoted.matchAll(WSL_POS)].map((m) => m[1]),
].map((s) => s.trim()).filter(Boolean);
if (found.length === 0) allow();

const normalise = (c) => c.replace(/^sudo\s+(?:-n|--non-interactive|-k)\s+/, 'sudo ');

const hasNonInteractive = (c) => /^sudo\s+(?:-n\b|--non-interactive\b)/.test(c);
const offenders = found.filter((c) => !hasNonInteractive(c) && !ALLOWED.some((re) => re.test(normalise(c))));
if (offenders.length === 0) allow();

const first = offenders[0].slice(0, 120);
const reason =
  `BLOCKED: \`${first}\` is not in the sudoers allowlist. It does not error - it hangs on the password prompt until it times out.\n\n` +
  `FIX, fastest: add \`-n\` => \`sudo -n <rest>\` (fails in milliseconds instead of waiting on a prompt).\n` +
  `Forms accepted without \`-n\` (only where the grant genuinely applies, e.g. over ssh): ${ACCEPTED_TEXT}\n` +
  `Three other exits: 1. use a read that needs no sudo - \`systemctl status <unit>\` does not.\n` +
  `  2. hand it to the user: ask them to type \`! <command>\` in this session.\n` +
  `  3. the gate is genuinely wrong => append \`# SUDO-ALLOWLIST-OK: <reason>\` to the command.`;

logDenial('block-sudo-outside-allowlist', 'sudo-outside-allowlist', first);
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason: reason,
  },
}));
process.exit(0);
