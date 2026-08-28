import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const HOOKS_DIR = `${(process.env.CLAUDE_CONFIG_DIR || String(homedir()).replace(/\\/g, '/') + '/.claude').replace(/\\/g, '/')}/hooks/`;

const HOME_CLAUDE = `${(process.env.CLAUDE_CONFIG_DIR || String(homedir()).replace(/\\/g, '/') + '/.claude').replace(/\\/g, '/')}/`;
const EXCLUDED_DIR_RE = /\/(?:__tests__|knowledge|rules-archive|projects|teams|plugins|\.state|\.aal-state|shell-snapshots|todos)\//i;

// Quote-delimited, so the POSIX branch needs no lookbehind guard: the opening quote already says
// where the path starts.
const HOOK_PATH_RE = /["'`]((?:[A-Za-z]:[\\/]|\/)[^"'`\n]*?[\\/]\.claude[\\/][^"'`\n]+?\.(?:mjs|cjs|js|sh|json|md))["'`]/gi;

const WRITE_VERB_RE = new RegExp([
  'writeFileSync', 'appendFileSync', 'createWriteStream', 'fs\\.promises\\.writeFile',
  'io\\.open\\([^)]*[\'"]w', 'open\\([^)]*[\'"]w', '\\.write_text\\(', '\\.write\\(',
  'shutil\\.(?:copy|move)', 'os\\.replace\\(', 'os\\.rename\\(',
].join('|'), 'i');

const HOOK_PATH_SRC = '(?:[A-Za-z]:[\\\\/]|/)[^\\s"\'`|;&]*?[\\\\/]\\.claude[\\\\/][^\\s"\'`|;&]+?\\.(?:mjs|cjs|js|sh|json|md)';
const WRITE_TARGET_RES = [
  new RegExp('>>?\\s*["\']?(' + HOOK_PATH_SRC + ')', 'gi'),
  new RegExp('\\btee\\s+(?:-a\\s+)?["\']?(' + HOOK_PATH_SRC + ')', 'gi'),
  new RegExp('\\b(?:sed\\s+(?:-\\S+\\s+)*-i|cp|mv|install)\\b[^|;&\\n]*?["\']?(' + HOOK_PATH_SRC + ')["\']?\\s*(?:$|[|;&\\n])', 'gi'),
];

const isHookPath = (p) => String(p).replace(/\\/g, '/').toLowerCase().startsWith(HOOKS_DIR.toLowerCase());

const isJudgementPath = (p) => {
  const s = String(p).replace(/\\/g, '/');
  return s.toLowerCase().startsWith(HOME_CLAUDE.toLowerCase()) && !EXCLUDED_DIR_RE.test(s);
};


function hookPathsIn(text) {
  const out = new Set();
  for (const m of String(text || '').matchAll(HOOK_PATH_RE)) {
    const p = m[1].replace(/\\\\/g, '/').replace(/\\/g, '/');
    if (isJudgementPath(p)) out.add(p);
  }
  for (const m of String(text || '').matchAll(/((?:[A-Za-z]:[\\/]|(?<![\w.\-/:~])\/)[^\s"'`|;&)]*?[\\/]\.claude[\\/][^\s"'`|;&)]+?\.(?:mjs|cjs|js|sh|json|md))/gi)) {
    const p = m[1].replace(/\\/g, '/');
    if (isJudgementPath(p)) out.add(p);
  }
  return [...out];
}

export function hookFilesWrittenBy(payload) {
  const tool = String((payload && payload.tool_name) || '');
  const ti = (payload && payload.tool_input) || {};

  if (['Write', 'Edit', 'MultiEdit'].includes(tool)) {
    const fp = String(ti.file_path || ti.filePath || '').replace(/\\/g, '/');
    return isJudgementPath(fp) ? [fp] : [];
  }
  if (tool !== 'Bash') return [];

  const cmd = String(ti.command || '');
  const found = new Set();

  for (const m of cmd.matchAll(/\b(?:node|python3?|bun|deno(?:\s+run)?)\s+(?:--?\S+\s+)*["']?([^\s"'|;&]+\.(?:mjs|cjs|js|ts|py))["']?/g)) {
    const p = m[1].replace(/\\/g, '/');
    if (!/^[a-zA-Z]:|^\//.test(p)) continue;
    if (isHookPath(p)) continue;
    let body = '';
    try { body = readFileSync(p, 'utf8'); } catch { continue; }
    if (!WRITE_VERB_RE.test(body)) continue;
    for (const h of hookPathsIn(body)) found.add(h);
  }

  for (const re of WRITE_TARGET_RES) {
    re.lastIndex = 0;
    for (const m of cmd.matchAll(re)) {
      const p = m[1].replace(/\\/g, '/');
      if (isJudgementPath(p)) found.add(p);
    }
  }

  if (/<<-?\s*['"]?\w+['"]?/.test(cmd) && WRITE_VERB_RE.test(cmd)) {
    for (const h of hookPathsIn(cmd)) found.add(h);
  }

  if (/\bcd\s+["']?[^\s"'`|;&]*[\\/]\.claude[\\/]hooks[\\/]?["']?/i.test(cmd)) {
    const bare = /\b(?:sed\s+(?:-\S+\s+)*-i|cp|mv|install|tee)\b[^|;&\n]*?["']?([A-Za-z0-9._-]+\.(?:mjs|cjs|js|sh|json|md))["']?\s*(?:$|[|;&\n])/gi;
    for (const m of cmd.matchAll(bare)) found.add(`${HOOKS_DIR}${m[1]}`);
  }

  return [...found];
}
