#!/usr/bin/env node
import { readFileSync, existsSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { knownProjects, sessionProject, projectPaths } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('require-infra-change-planned');

function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }
let payload = {};
try { payload = JSON.parse(read(0) || '{}'); } catch { process.exit(0); }

const TOOL = String(payload.tool_name || '');
const TI = payload.tool_input || {};
const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit']);
if (TOOL !== 'Bash' && !WRITE_TOOLS.has(TOOL)) process.exit(0);
const cmd = String(TI.command || '');
if (TOOL === 'Bash' && !cmd.trim()) process.exit(0);

function tokenize(s) {
  const out = [];
  let cur = '', quote = null, had = false;
  const push = () => { if (had || cur) out.push({ raw: cur, quote }); cur = ''; quote = null; had = false; };
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quote) {
      if (c === quote) { quote = null; had = true; } else cur += c;
      continue;
    }
    if (c === "'" || c === '"') { quote = c; had = true; out.push({ raw: '', quote: c, _open: true }); out.pop(); const start = i + 1; let j = start; while (j < s.length && s[j] !== c) j++; cur += s.slice(start, j); i = j; out.push({ raw: cur, quote: c }); cur = ''; had = false; continue; }
    if (/\s/.test(c)) { push(); continue; }
    cur += c;
  }
  push();
  return out.filter((t) => t.raw !== '' || t.quote);
}

function segments(s) {
  const parts = [];
  let cur = '', quote = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quote) { cur += c; if (c === quote) quote = null; continue; }
    if (c === "'" || c === '"') { quote = c; cur += c; continue; }
    if (c === '\n' || c === ';') { parts.push(cur); cur = ''; continue; }
    if ((c === '&' && s[i + 1] === '&') || (c === '|' && s[i + 1] === '|')) { parts.push(cur); cur = ''; i++; continue; }
    if (c === '|') { parts.push(cur); cur = ''; continue; }
    cur += c;
  }
  parts.push(cur);
  return parts.map((p) => p.trim()).filter(Boolean);
}

const ALWAYS = new Map([
  ['visudo', 'visudo (edit sudoers)'],
  ['usermod', 'usermod'], ['useradd', 'useradd'], ['userdel', 'userdel'],
  ['adduser', 'adduser'], ['deluser', 'deluser'],
  ['groupmod', 'groupmod'], ['groupadd', 'groupadd'], ['groupdel', 'groupdel'],
  ['addgroup', 'addgroup'], ['delgroup', 'delgroup'],
  ['gpasswd', 'gpasswd'], ['chpasswd', 'chpasswd'],
  ['setfacl', 'setfacl (ACL mutation)'],
]);
const PROTECTED = /(\/etc\/sudoers(\.d)?\b|\/etc\/systemd\/|\/etc\/<your-project>\/|\.service\b|\.timer\b|\.socket\b)/;
const PATH_SCOPED = new Map([
  ['chown', 'chown on a protected path'], ['chmod', 'chmod on a protected path'],
  ['tee', 'write to a protected path'], ['cp', 'write to a protected path'],
  ['mv', 'write to a protected path'], ['rm', 'remove a protected path'],
  ['ln', 'link into a protected path'], ['install', 'install into a protected path'],
  ['truncate', 'truncate a protected path'],
]);
const SYSTEMCTL_MUT = /^(enable|disable|mask|unmask|set-property|link|revert)$/;
const WRAPPERS = new Set(['ssh', 'bash', 'sh', 'zsh', 'env', 'nohup', 'timeout', 'xargs']);

function stripPrefix(toks) {
  let i = 0;
  for (;;) {
    const t = toks[i];
    if (!t) break;
    if (!t.quote && /^[A-Za-z_][A-Za-z0-9_]*=/.test(t.raw)) { i++; continue; }
    if (!t.quote && (t.raw === 'sudo' || t.raw === 'doas')) {
      i++;
      while (toks[i] && !toks[i].quote && /^-/.test(toks[i].raw)) {
        const f = toks[i].raw; i++;
        if (/^-(u|g|p|C)$/.test(f)) i++;
      }
      continue;
    }
    break;
  }
  return toks.slice(i);
}

const SHELL_CMDS = new Set(['bash', 'sh', 'zsh', 'dash', 'ssh']);
const ownerIsShell = (owner) => stripPrefix(tokenize(owner))
  .some((t) => !t.quote && SHELL_CMDS.has(t.raw.replace(/^.*[\\/]/, '')));
function splitHeredocs(cmd) {
  const lines = cmd.split('\n');
  const kept = [];
  const bodies = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/);
    if (!m) { kept.push(lines[i]); continue; }
    const owner = lines[i].replace(/<<-?\s*(['"]?)[A-Za-z_][A-Za-z0-9_]*\1/, ' ');
    kept.push(owner);
    const body = [];
    let j = i + 1;
    for (; j < lines.length; j++) { if (lines[j].trim() === m[2]) break; body.push(lines[j]); }
    bodies.push({ owner, body: body.join('\n') });
    i = j;
  }
  return { stripped: kept.join('\n'), bodies };
}

function classify(command, depth) {
  if (depth > 3) return null;
  const { stripped, bodies } = splitHeredocs(command);
  for (const h of bodies) {
    if (!ownerIsShell(h.owner)) continue;
    const inner = classify(h.body, depth + 1);
    if (inner) return inner;
  }
  command = stripped;
  for (const seg of segments(command)) {
    const toks = stripPrefix(tokenize(seg));
    if (!toks.length) continue;
    const head = toks[0];
    if (head.quote) continue;
    const name = head.raw.replace(/^.*[\\/]/, '');
    const args = toks.slice(1);

    if (WRAPPERS.has(name)) {
      for (const a of args) {
        if (!a.quote) continue;
        const inner = classify(a.raw, depth + 1);
        if (inner) return inner;
      }
      if (name === 'ssh' && args.length >= 2) {
        const tail = args.slice(1).filter((a) => !a.quote).map((a) => a.raw).join(' ');
        if (tail) { const inner = classify(tail, depth + 1); if (inner) return inner; }
      }
      continue;
    }

    if (ALWAYS.has(name)) {
      if (name === 'passwd' && !args.length) continue;
      return ALWAYS.get(name);
    }
    if (name === 'passwd' && args.length) return 'passwd (set password)';
    if (name === 'systemctl' && args.some((a) => SYSTEMCTL_MUT.test(a.raw))) return 'systemctl enable/disable/mask';
    if (name === 'sed' && args.some((a) => !a.quote && /^-[a-z]*i/.test(a.raw))
        && args.some((a) => PROTECTED.test(a.raw))) return 'sed -i on a protected path';
    if (PATH_SCOPED.has(name) && args.some((a) => PROTECTED.test(a.raw))) return PATH_SCOPED.get(name);

    const rawToks = tokenize(seg);
    for (let i = 0; i < rawToks.length; i++) {
      const t = rawToks[i];
      if (t.quote) continue;
      const m = t.raw.match(/^>>?(.*)$/);
      if (!m) continue;
      const target = m[1] || (rawToks[i + 1] && !rawToks[i + 1].quote ? rawToks[i + 1].raw : '');
      if (target && PROTECTED.test(target)) return 'redirect into a protected path';
    }
  }
  return null;
}

if (WRITE_TOOLS.has(TOOL)) {
  const fp = String(TI.file_path || '');
  if (!fp || !PROTECTED.test(fp)) process.exit(0);
  const wReason =
    `🚫 INFRA-CHANGE-MUST-BE-PLANNED GATE (CLAUDE.md #12, USER LOCK 2026-07-28) — ` +
    `${TOOL} targets a protected path: ${fp}\n` +
    `FIX, one of two:\n` +
    '  1. this wave DID plan it => use the Bash channel and carry the token (the gate checks the plan document is on disk):\n' +
    '     sed -i \'<expr>\' <path>   # PLANNED:<wave-slug>\n' +
    '  2. it was not planned => this is a WAVE (planner -> architect -> plan-review), not a quick edit.\n' +
    'NOTE: this gate judges the PATH, never the CONTENT. Quoting /etc/sudoers.d/... or *.service inside a runbook or a spec does not trigger it.';
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: wReason },
  }));
  process.exit(0);
}

const STAGE_VERBS = new Set(['scp', 'rsync']);
const REMOTE_DEST_RE = /^[A-Za-z0-9._%-]{2,}(?:@[A-Za-z0-9._-]+)?:\S/;
const DRILL_RE = /#\s*ROLLBACK-DRILL(?:-N-A)?:\s*\S/i;

if (TOOL === 'Bash') for (const seg of segments(cmd)) {
  const toks = stripPrefix(tokenize(seg));
  if (!toks.length || toks[0].quote) continue;
  if (!STAGE_VERBS.has(toks[0].raw.replace(/^.*[\\/]/, ''))) continue;
  const args = toks.slice(1).filter((t) => !/^-/.test(t.raw.trim()));
  if (args.length < 2) continue;
  if (!REMOTE_DEST_RE.test(args[args.length - 1].raw.trim())) continue;
  const src = args[args.length - 2].raw.trim();
  if (!/\.sh$/i.test(src)) continue;
  let body = '';
  try { if (existsSync(src)) body = readFileSync(src, 'utf8'); } catch { body = ''; }
  if (!body) continue;
  if (!classify(body, 0)) continue;
  if (DRILL_RE.test(body)) continue;
  const sReason =
    `BLOCKED: this script changes infrastructure and declares no rollback drill: ${src}\n\n` +
    `What is required is a TESTED rollback, not a PREPARED one - "a backup exists" and "the restore actually runs" read identically.\n` +
    `It has to run inside the same privileged window: skipping it here costs another window later.\n\n` +
    `FIX, one of two, both one line in the script:\n` +
    `  1. # ROLLBACK-DRILL: restores <what> - must-red <which reading changes>\n` +
    `     in this same script: really reinstall the backup, verify it, prove one reading changed, then reinstall the new state\n` +
    `  2. # ROLLBACK-DRILL-N-A: <reason>\n\n` +
    `While you are here: after this window closes, which DoD items still need another window like it?`;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: sReason },
  }));
  process.exit(0);
}

const hit = classify(cmd, 0);
if (!hit) process.exit(0);

const m = cmd.match(/#\s*PLANNED:\s*([A-Za-z0-9._-]+)/);
if (m) {
  const slug = m[1].replace(/-plan$/, '');
  const selfRepo = sessionProject(payload) || projectPaths(payload)?.repo || '';
  for (const r of (selfRepo ? [selfRepo] : knownProjects())) {
    if (existsSync(`${r}/docs/product-specs/${slug}-plan.md`)) process.exit(0);
  }
}

const reason =
  `🚫 INFRA-CHANGE-MUST-BE-PLANNED GATE (CLAUDE.md #12, USER LOCK 2026-07-28): this command performs a ` +
  `high-risk infra mutation [${hit}] — service identity / sudoers / ACLs / systemd enable / prod-secret perms. ` +
  `Per #12 a NEW/complex/IRREVERSIBLE infra change with no runbook is a WAVE: it must be PLANNED ` +
  `(planner→architect→plan-review → docs/product-specs/<slug>-plan.md + a lead-execution runbook + a ` +
  `TESTED rollback) BEFORE any server op — the lead does NOT SSH in and design-on-the-fly. If this IS ` +
  `already planned (the plan doc exists on disk), re-run with a trailing ` + '`# PLANNED:<wave-slug>`' +
  ` naming that wave (the gate verifies docs/product-specs/<slug>-plan.md actually exists — a bare ` +
  `token won't pass). If a card says the lead must not execute it directly, that IS the 'plan it first' signal.\n` +
  `NOTE: this gate judges the COMMAND POSITION, not the whole payload. Quoting a mutating verb as TEXT ` +
  `(a verdict body, a commit message, an echo, a heredoc, a grep pattern) does not trigger it - so do NOT ` +
  `blur a finding to get past it. If you were blocked, this command's argv[0] really is a mutating command.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
}));
process.exit(0);
