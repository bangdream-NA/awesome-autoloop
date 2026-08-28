#!/usr/bin/env node
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { DOD_VERIFIED_RE } from './lib/backlog-grammar.mjs';
import { GATE_BLOCKER_TOKEN_RE, LEGACY_GATE_TOKEN_RE } from './lib/backlog-gate.mjs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { armLead, repoOfBoardPath } from './lib/is-autoloop-lead.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('backlog-guard');

const HOOKS = process.env.BG_HOOKS_DIR || `${homeDir()}/.claude/hooks`;

const DELEGATES = process.env.BG_DELEGATES ? process.env.BG_DELEGATES.split(',') : [
  'block-future-timestamp.mjs',
  'require-oplog-row-format.mjs',
  'require-landing-on-oplog-next.mjs',
  'backlog-gate-vocab.mjs',
  'backlog-ownership-token-required.mjs',
  'backlog-slug-matches-wave.mjs',
  'backlog-dod-anchor-required.mjs',
  'block-dod-failed-without-execution.mjs',
  'require-wave-doc-read-before-dod-token.mjs',
  'require-owes-cards-cleared-before-verified.mjs',
  'block-malformed-new-backlog-card.mjs',
  'require-user-question-with-user-gate.mjs',
  'block-backlog-status-drift.mjs',
  'block-dod-pending-archive.mjs',
  'require-ship-action-before-archive.mjs',
  // require-fulljourney-dod-on-archive is an EXAMPLE, not a mounted gate: its DATA_LAYER_ANCHOR
  // at :32 enumerates one project's data-pipeline module names, and an empty anchor set makes it
  // inert. See examples/require-fulljourney-dod-on-archive.example.mjs.
];

function read(fd) { try { return readFileSync(fd, 'utf8'); } catch { return ''; } }
const raw = read(0) || '{}';
let payload = {};
try { payload = JSON.parse(raw); } catch { process.stdout.write('{}'); process.exit(0); }

const LEDGER_LEAF = '(?:BACKLOG|autoloop-log)';
const BOARD_PATH_RE = new RegExp(`(?<=^|[\\s'"\`=(])(?:[^\\s'"\`]*[\\\\/])?\\.claude[\\\\/]${LEDGER_LEAF}[^\\s'"\`]*\\.md`);
const WRITES_RE = new RegExp([
  'writeFileSync', 'appendFileSync', 'createWriteStream', 'fs\\.(?:write|append)',
  `>>?\\s*["']?[^\\s"'|;]*${LEDGER_LEAF}`, '\\btee\\b', '\\bsed\\s+-i\\b',
  'io\\.open\\s*\\([^)]*["\']\\s*[wa]',
  '\\bopen\\s*\\([^)]*["\']\\s*[wa]',
  '\\.write_text\\s*\\(', '\\.write_bytes\\s*\\(',
  '\\bos\\.replace\\s*\\(', '\\bshutil\\.(?:copy|move)\\b',
].join('|'));

const toolName = String(payload.tool_name || '');
const tin = payload.tool_input || {};
const targetPath = String(tin.file_path || '').replace(/\\/g, '/');

if (String(payload.hook_event_name || '') === 'PostToolUse') {
  const cmdText = String(tin.command || '');
  const board = (process.env.BG_POST_BOARD
    || (BOARD_PATH_RE.test(cmdText) ? (cmdText.match(BOARD_PATH_RE) || [])[0] : '')).trim();
  if (!board) { process.stdout.write('{}'); process.exit(0); }
  if (/BACKLOG-archive/i.test(board.replace(/\\/g, '/').split('/').pop() || '')) {
    process.stdout.write('{}'); process.exit(0);
  }
  let boardText = '';
  try { boardText = readFileSync(board, 'utf8'); } catch { process.stdout.write('{}'); process.exit(0); }
  const STATE_ONLY = [
    'block-dod-verified-with-self-declared-gap.mjs',
    'require-owes-cards-cleared-before-verified.mjs',
    'block-backlog-status-drift.mjs',
    'block-dod-pending-archive.mjs',
    'backlog-gate-vocab.mjs',
  ];
  const asWrite = JSON.stringify({
    session_id: payload.session_id || '', cwd: payload.cwd || '',
    tool_name: 'Write',
    tool_input: { file_path: board.replace(/\\/g, '/'), content: boardText },
  });
  for (const d of STATE_ONLY) {
    const r = spawnSync(process.execPath, [HOOKS + '/' + d], { input: asWrite, encoding: 'utf8', timeout: 20000 });
    const out = ((r.stdout || '') + (r.stderr || '')).trim();
    const m = out.match(/"permissionDecisionReason"\s*:\s*("(?:[^"\\]|\\.)*")/);
    if (/"permissionDecision"\s*:\s*"deny"/.test(out)) {
      let reason;
      try { reason = m ? JSON.parse(m[1]) : out.slice(0, 900); } catch { reason = out.slice(0, 900); }
      process.stdout.write(JSON.stringify({
        decision: 'block',
        reason: 'BLOCKED: the board gate caught this AFTER THE WRITE (the real coverage for the Bash path, PostToolUse) — judged by ' + d + ':\n\n' + reason +
          '\n\nNOTE: this layer **cannot prevent the write**, only stop you afterwards ⇒ roll it back, or correct that card in this same turn.',
      }));
      process.exit(0);
    }
  }
  process.stdout.write('{}');
  process.exit(0);
}

const isDirectBoardWrite = ['Write', 'Edit', 'MultiEdit'].includes(toolName)
  && new RegExp(`/\\.claude/${LEDGER_LEAF}[^/]*\\.md$`, 'i').test(targetPath);

const armProjectLead = (target) => {
  try {
    const repo = repoOfBoardPath(target);
    if (!repo) return;
    armLead(String(payload.session_id || ''), repo);
  } catch {  }
};
if (isDirectBoardWrite) armProjectLead(targetPath);

const isHookSource = /\/\.claude\/hooks\//i.test(targetPath);

let raw2 = raw;
const scriptBodies = [];
const catBodies = [];
if (!isDirectBoardWrite && !isHookSource) {
  let text = '';
  if (toolName === 'Write') text = String(tin.content || '');
  else if (toolName === 'Edit') text = String(tin.new_string || '');
  else if (toolName === 'MultiEdit') text = (tin.edits || []).map((e) => String(e.new_string || '')).join('\n');
  else if (toolName === 'Bash') {
    text = String(tin.command || '');
    for (const m of text.matchAll(/\b(?:node|python3?|bun|deno(?:\s+run)?)\s+(?:--?\S+\s+)*["']?([^\s"'|;&]+\.(?:mjs|cjs|js|ts|py))["']?/g)) {
      try {
        const p = m[1].replace(/\\/g, '/');
        const abs = /^[a-zA-Z]:|^\//.test(p) ? p : null;
        if (!abs) continue;
        if (/\/\.claude\/hooks\//i.test(abs)) continue;
        const body = readFileSync(abs, 'utf8');
        scriptBodies.push(body);
        text += '\n' + body;
      } catch {  }
    }
    const vars = new Map();
    for (const v of text.matchAll(/\b([A-Za-z_]\w*)=["']?([^\s"';|&]+)["']?/g)) vars.set(v[1], v[2]);
    const expand = (p) => p.replace(/\$\{?([A-Za-z_]\w*)\}?/g, (s, n) => (vars.has(n) ? vars.get(n) : s));
    let catSawContent = false;
    let catSawOpaque = null;
    for (const m of text.matchAll(/\b(?:cat|type)\s+(?:--?\S+\s+)*["']?([^\s"'|;&<>]+)["']?\s*(?:>>?|\|)/g)) {
      const p = expand(m[1]).replace(/\\/g, '/');
      if (!/^[a-zA-Z]:|^\//.test(p)) { catSawOpaque = m[1]; continue; }
      try {
        const body = readFileSync(p, 'utf8');
        catBodies.push(body);
        text += '\n' + body;
        catSawContent = true;
      } catch { catSawOpaque = m[1]; }
    }
    if (catSawOpaque && !catSawContent
        && new RegExp(`(?:>>?|\\btee(?:\\s+-a)?\\s+)\\s*["']?[^\\s"'|;&]*\\.claude[\\\\/]${LEDGER_LEAF}`, 'i').test(text)) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            `BLOCKED: the content being appended to a ledger is INVISIBLE: the command appends \`${catSawOpaque}\` to a ledger, and that path` +
            `does not expand to an absolute path or cannot be read, so the format gate and the landing gate **receive no body at all** — ` +
            `they allow silently, which reads exactly like passing (that is the mechanism behind an over-long ledger row drawing zero warnings).\n\n` +
            'Three ways out: (1) use a heredoc (`cat <<\'EOF\' >> <ledger>` … the body is in the command, where the gates can see it); ' +
            '(2) write it with the Write/Edit tool; (3) give the SOURCE file as an ABSOLUTE LITERAL path (no variables), and the gates will read it themselves.',
        },
      }));
      process.exit(0);
    }
  }
  else { process.stdout.write('{}'); process.exit(0); }

  const board = text.match(BOARD_PATH_RE);
  if (!board) { process.stdout.write('{}'); process.exit(0); }

  let directTarget = null;
  let sedSegment = null;
  if (toolName === 'Bash') {
    const lit = text.match(new RegExp(`(?:>>?|\\btee(?:\\s+-a)?\\s+)\\s*["']?((?:[^\\s"'|;&]*[\\\\/])?\\.claude[\\\\/]${LEDGER_LEAF}[^\\s"'|;&]*\\.md)`, 'i'));
    if (lit) directTarget = lit[1];
    if (!directTarget) {
      for (const seg of text.split(/;|&&|\|\||\|/)) {
        if (!/\bsed\s+(?:-\S+\s+)*-i\b|\bsed\s+-i/.test(seg)) continue;
        const m2 = seg.match(new RegExp(`((?:[^\\s"'|;&]*[\\\\/])?\\.claude[\\\\/]${LEDGER_LEAF}[^\\s"'|;&]*\\.md)`));
        if (m2) { directTarget = m2[1]; sedSegment = seg; break; }
      }
    }
    if (!directTarget && scriptBodies.length) {
      for (const body of scriptBodies) {
        if (!WRITES_RE.test(body)) continue;
        const m2 = body.match(new RegExp(`((?:[^\\s"'|;&]*[\\\\/])?\\.claude[\\\\/]${LEDGER_LEAF}[^\\s"'|;&]*\\.md)`));
        if (m2) { directTarget = m2[1]; break; }
      }
    }
    if (!directTarget) {
      for (const m of text.matchAll(new RegExp(`\\b(\\w+)=["']?((?:[^\\s"'|;&]*[\\\\/])?\\.claude[\\\\/]${LEDGER_LEAF}[^\\s"'|;&]*\\.md)["']?`, 'g'))) {
        const varRe = new RegExp('(?:>>?|\\btee(?:\\s+-a)?\\s+)\\s*["\']?\\$\\{?' + m[1] + '\\}?\\b');
        if (varRe.test(text)) { directTarget = m[2]; break; }
      }
    }
  }
  if (!directTarget && !WRITES_RE.test(text)) { process.stdout.write('{}'); process.exit(0); }
  if (directTarget) armProjectLead(directTarget);

  const BOARDISH_LINE = /^\s*(?:###\s+\[[^\]]+\]\s+\S|-\s+\S+\s*:)/;
  const literalsOf = (src) => {
    const out = [];
    const re = /'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"|`((?:[^`\\]|\\.)*)`/g;
    let m;
    while ((m = re.exec(src)) !== null) {
      const body = (m[1] ?? m[2] ?? m[3] ?? '')
        .replace(/\\n/g, '\n').replace(/\\t/g, '\t').replace(/\\r/g, '')
        .replace(/\\(['"`\\])/g, '$1');
      if (body.split('\n').some((l) => BOARDISH_LINE.test(l))) out.push(body);
    }
    return out.join('\n');
  };
  const heredocBodies = [];
  for (const m of text.matchAll(/<<-?\s*(["']?)(\w+)\1[^\n]*\r?\n([\s\S]*?)\r?\n\s*\2(?=\r?\n|$)/g)) heredocBodies.push(m[3]);
  heredocBodies.push(...catBodies);
  const allLiteralsUnfiltered = (src) => {
    const out = [];
    const re = /'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)"|`((?:[^`\\]|\\.)*)`/g;
    let m;
    while ((m = re.exec(src)) !== null) {
      const body = (m[1] ?? m[2] ?? m[3] ?? '')
        .replace(/\\n/g, '\n').replace(/\\t/g, '\t').replace(/\\r/g, '')
        .replace(/\\(['"`\\])/g, '$1');
      if (!body.trim() || BOARD_PATH_RE.test(body)) continue;
      const plumbing = body.replace(/%[-#+ 0-9.]*[%sdqbxXofeg]|\$\{?\w+\}?|\\[ntr0]/g, '').trim();
      if (!plumbing) continue;
      out.push(body);
    }
    return out;
  };
  const sedWrittenText = (seg) => {
    const out = [];
    for (const m of seg.matchAll(/(?:^|['"\s;{])(\d*(?:,\d+)?)s([/|#,])((?:[^\\]|\\.)*?)\2((?:[^\\]|\\.)*?)\2[gimIp0-9]*/g)) {
      out.push(String(m[4] || '').replace(/\\([/|#,])/g, '$1'));
    }
    for (const m of seg.matchAll(/(?:^|['"\s;])\d*(?:,\d+)?([aic])\\?\s*((?:[^'"\\]|\\.)*)/g)) {
      out.push(String(m[2] || '').replace(/\\n/g, '\n'));
    }
    return out.filter(Boolean).join('\n');
  };

  const LOADBEARING = (s) =>
    DOD_VERIFIED_RE.test(s) || GATE_BLOCKER_TOKEN_RE.test(s) || LEGACY_GATE_TOKEN_RE.test(s);
  const boardishLiterals = (src) =>
    allLiteralsUnfiltered(src).filter(
      (body) => body.split('\n').some((l) => BOARDISH_LINE.test(l)) || LOADBEARING(body),
    );
  const targetIsBoard = /[\\/]BACKLOG[^\\/]*\.md$/i.test(directTarget || '');
  if (toolName === 'Bash' && !directTarget && heredocBodies.length) {
    for (const body of heredocBodies) {
      if (!WRITES_RE.test(body)) continue;
      const m2 = body.match(new RegExp(`((?:[^\\s"'|;&]*[\\\\/])?\\.claude[\\\\/]${LEDGER_LEAF}[^\\s"'|;&]*\\.md)`));
      if (m2) { directTarget = m2[1]; break; }
    }
  }
  const introducedBoardText = directTarget
    ? (sedSegment
        ? sedWrittenText(sedSegment)
        : [...heredocBodies, ...(targetIsBoard ? boardishLiterals(text) : allLiteralsUnfiltered(text))].join('\n'))
    : literalsOf(text);

  raw2 = JSON.stringify({
    ...payload,
    tool_name: 'Write',
    tool_input: { ...tin, file_path: (directTarget || board[0]).replace(/\\/g, '/'), content: introducedBoardText },
  });
}

for (const name of DELEGATES) {
  let r;
  try {
    r = spawnSync('node', [`${HOOKS}/${name}`], { input: raw2, encoding: 'utf8', timeout: 15000 });
  } catch { continue; }
  if (!r || r.status !== 0) continue;
  const out = (r.stdout || '').trim();
  if (!out || out === '{}') continue;
  if (/"permissionDecision"\s*:\s*"deny"|"decision"\s*:\s*"block"/.test(out)) {
    process.stdout.write(out);
    process.exit(0);
  }
  process.stdout.write(out);
  process.exit(0);
}

process.stdout.write('{}');
process.exit(0);
