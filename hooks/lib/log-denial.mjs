import { existsSync, statSync, mkdirSync, renameSync, appendFileSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';

const CAP = Number(process.env.AAL_GATE_DENIALS_CAP || 245760);

function resolveClaudeDir() {
  const env = process.env.CLAUDE_PROJECT_DIR;
  if (env && existsSync(join(env, '.claude'))) return join(env, '.claude');
  let d = process.cwd();
  for (let i = 0; i < 8; i++) {
    const c = join(d, '.claude');
    if (existsSync(c)) return c;
    const up = dirname(d);
    if (up === d) break;
    d = up;
  }
  return (process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'));
}

function stamp(now) {
  const p = (n, w = 2) => String(Math.abs(n)).padStart(w, '0');
  const off = -now.getTimezoneOffset();
  const sign = off < 0 ? '-' : '+';
  return `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}` +
    `T${p(now.getHours())}:${p(now.getMinutes())}:${p(now.getSeconds())}` +
    `${sign}${p(Math.floor(Math.abs(off) / 60))}${p(Math.abs(off) % 60)}`;
}

export function derivePatternId(reason) {
  const s = String(reason ?? '')
    .replace(/`[^`]*`|"[^"]*"|'[^']*'/g, ' ')
    .replace(/\b[0-9a-f]{7,40}\b/gi, ' ')
    .replace(/#\d+|\bPR\s*\d+\b/gi, ' ')
    .replace(/[A-Za-z]:[\\/][^\s]*|[\\/][^\s]*[\\/][^\s]*/g, ' ')
    .replace(/\d+/g, ' ')
    .toLowerCase()
    .replace(/[^a-z\s-]+/g, ' ')
    .trim()
    .split(/[\s-]+/)
    .filter(Boolean)
    .slice(0, 6)
    .join('-');
  return s || 'unclassified';
}

export function logDenial(hook, patternId, reason) {
  try {
    if (process.env.AAL_GATE_DENIALS_OFF) return;
    const dir = resolveClaudeDir();
    if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
    const log = join(dir, '.gate-denials');
    try {
      if (existsSync(log) && statSync(log).size > CAP) renameSync(log, `${log}.1`);
    } catch {  }
    const clean = String(reason ?? '').replace(/[\n\r|]/g, ' ').slice(0, 240);
    const pid = patternId || derivePatternId(reason);
    const ts = stamp(new Date());

    try {
      const tail = readFileSync(log, 'utf8').slice(-4096).split('\n').filter(Boolean);
      const last = tail[tail.length - 1] || '';
      const p = last.split('|').map((x) => x.trim());
      if (p.length >= 4 && p[0] === ts && p[2] === pid && p.slice(3).join(' | ') === clean) return;
    } catch {  }

    appendFileSync(log, `${ts} | ${hook || 'unknown'} | ${pid} | ${clean}\n`);
  } catch {  }
}

export function autoLogOnDeny(hookName, patternId = null) {
  const orig = process.stdout.write.bind(process.stdout);
  process.stdout.write = (chunk, ...rest) => {
    try {
      const s = typeof chunk === 'string' ? chunk : String(chunk);
      if (/permissionDecision["']?\s*:\s*["']deny|decision["']?\s*:\s*["']block/.test(s)) {
        const m = s.match(/permissionDecisionReason["']?\s*:\s*"((?:[^"\\]|\\.){0,400})/)
          || s.match(/reason["']?\s*:\s*"((?:[^"\\]|\\.){0,400})/);
        logDenial(hookName, patternId, m ? m[1].replace(/\\n/g, ' ') : s.slice(0, 240));
      }
    } catch {  }
    return orig(chunk, ...rest);
  };
}

export default logDenial;
