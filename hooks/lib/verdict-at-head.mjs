import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

export function loadVerdictIndex(repoDir) {
  const approvedAt = new Map();
  const verdictOf = new Map();
  try {
    const jl = readFileSync(`${repoDir}/.claude/reviews/index.jsonl`, 'utf8').split(/\r?\n/).filter(Boolean);
    const newest = new Map();
    for (const line of jl) {
      try {
        const r = JSON.parse(line);
        if (!r.pr) continue;
        const k = String(r.pr);
        const ts = Date.parse(r.ts || 0) || 0;
        if (!newest.has(k) || ts >= newest.get(k)) {
          newest.set(k, ts);
          approvedAt.set(k, String(r.head_sha || ''));
          verdictOf.set(k, String(r.verdict || '').toUpperCase());
        }
      } catch {  }
    }
  } catch {  }

  const rebinds = (() => {
    const m = new Map();
    try {
      for (const line of readFileSync(`${repoDir}/.claude/.gate-rebinds`, 'utf8').split(/\r?\n/)) {
        if (!line.trim()) continue;
        try {
          const r = JSON.parse(line);
          if (!r.pr || !r.to) continue;
          const k = String(r.pr);
          if (!m.has(k)) m.set(k, new Set());
          m.get(k).add(String(r.to));
        } catch {  }
      }
    } catch {  }
    return m;
  })();

  const patchIdIdentical = (lastSha, headOid) => {
    const g = (args) => {
      try { return execFileSync('git', args, { cwd: repoDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim(); }
      catch { return ''; }
    };
    if (!g(['cat-file', '-e', `${lastSha}^{commit}`]) && !g(['rev-parse', '--verify', `${lastSha}^{commit}`])) return false;
    const pid = (sha) => {
      try {
        const d = execFileSync('git', ['diff', '--no-ext-diff', '--binary', `origin/main...${sha}`],
          { cwd: repoDir, encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] });
        const out = execFileSync('git', ['patch-id', '--stable'],
          { cwd: repoDir, input: d, encoding: 'utf8', stdio: ['pipe', 'pipe', 'ignore'] });
        return out.split(' ')[0] || '';
      } catch { return ''; }
    };
    const a = pid(lastSha); const b = pid(headOid);
    if (!a || !b || a !== b) return false;
    const n = g(['rev-list', '--no-merges', '--count', `${lastSha}..${headOid}`, '^origin/main']);
    return n === '0';
  };

  const approvedAtHead = (num, headOid) => {
    const k = String(num);
    if (verdictOf.get(k) !== 'APPROVED') return false;
    const sha = approvedAt.get(k) || '';
    if (!sha || !headOid) return false;
    if (headOid.startsWith(sha) || sha.startsWith(headOid)) return true;
    if (rebinds.get(k) && rebinds.get(k).has(String(headOid))) return true;
    return patchIdIdentical(sha, headOid);
  };

  return { verdictOf, approvedAt, approvedAtHead };
}
