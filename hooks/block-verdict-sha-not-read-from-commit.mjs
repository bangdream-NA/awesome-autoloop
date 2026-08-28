#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-verdict-sha-not-read-from-commit');

import { resolveRepo, repoRoots } from './lib/is-autoloop-lead.mjs';

const SPEC_DIR = 'docs/product-specs';

const VERDICT_SHA = /(ARCH_APPROVED|PLAN_APPROVED|architecture spec|spec)\s*[^\n]{0,80}?@\s*`?([0-9a-f]{7,40})`?/gi;

const git = (cwd, args) => {
  try {
    return execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 * 1024 * 1024 });
  } catch { return null; }
};

const readStdin = () => { try { return readFileSync(0, 'utf8'); } catch { return ''; } };

const allow = () => process.exit(0);
const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};

let input;
try { input = JSON.parse(readStdin() || '{}'); } catch { allow(); }
const ti = (input && input.tool_input) || {};
const target = String(ti.file_path || '');
if (!/BACKLOG\.md$/i.test(target) && !/\.claude[\\/]reviews[\\/]/i.test(target)) allow();

const added = String(ti.content || ti.new_string || '');
if (!added) allow();

const hits = [...added.matchAll(VERDICT_SHA)].map((m) => m[2].toLowerCase());
if (hits.length === 0) allow();

const REPO = resolveRepo(input, target);
const roots = repoRoots(REPO);
if (!roots.length) {
  process.stderr.write(`[verdict-sha] FAIL-OPEN: cannot tell which repo ${target} belongs to\n`);
  allow();
}

const diffsFromDisk = (root, sha, pathspec) => {
  const specs = Array.isArray(pathspec) ? pathspec : [pathspec];
  try {
    execFileSync('git', ['-C', root, 'diff', '--quiet', sha, '--', ...specs], { stdio: 'ignore' });
    return false;
  } catch (e) {
    if (e && e.status === 1) return true;
    return null;
  }
};

for (const sha of [...new Set(hits)]) {
  let resolvedAnywhere = false;
  let matchedSomewhere = false;
  const mismatches = [];
  for (const root of roots) {
    if (git(root, ['cat-file', '-e', `${sha}^{commit}`]) === null) continue;
    let isAncestor = false;
    try { execFileSync('git', ['-C', root, 'merge-base', '--is-ancestor', sha, 'HEAD'], { stdio: 'ignore' }); isAncestor = true; }
    catch (e) { if (!e || e.status !== 1) { process.stderr.write(`[verdict-sha] ancestor probe unusable in ${root}\n`); } }
    if (!isAncestor) continue;
    const dir = join(root, ...SPEC_DIR.split('/'));
    if (!existsSync(dir)) continue;
    resolvedAnywhere = true;
    const own = (git(root, ['show', '--name-only', '--format=', sha, '--', SPEC_DIR]) || '')
      .split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    const pathspec = own.length ? own : [SPEC_DIR];
    const differs = diffsFromDisk(root, sha, pathspec);
    if (differs === false) { matchedSomewhere = true; continue; }
    if (differs !== true) continue;
    const names = git(root, ['diff', '--name-only', sha, '--', ...pathspec]) || '';
    const rel = names.split(/\r?\n/).filter(Boolean)[0] || `${SPEC_DIR}/*`;
    const at = git(root, ['show', `${sha}:${rel}`]);
    let disk = null; try { disk = readFileSync(join(root, rel), 'utf8'); } catch {  }
    const ln = (x) => {
      if (x == null) return '?';
      const s = x.replace(/\r\n/g, '\n');
      if (s === '') return 0;
      return s.replace(/\n$/, '').split('\n').length;
    };
    mismatches.push({ rel, root, la: ln(at), ld: ln(disk) });
  }
  if (!resolvedAnywhere) { process.stderr.write(`[verdict-sha] FAIL-OPEN: ${sha} unknown to every known root\n`); continue; }
  if (matchedSomewhere) continue;
  if (mismatches.length) {
    const m = mismatches[0];
    deny([
      `BLOCKED: the @${sha} a verdict cites matches no root on disk (closest: ${m.rel} @ ${m.root}, at-sha=${m.la} lines vs disk=${m.ld} lines).`,
      `(1) **Are there TWO approval tokens on the line?** (say \`PLAN_APPROVED @…\` and \`ARCH_APPROVED @…\`)`,
      `    This gate compares the **whole \`docs/product-specs\` directory**, not one file — so once later documents`,
      `    (architecture, design) land in that directory the EARLIER sha must mismatch, and re-reading cannot help.`,
      `    ⇒ The way out: **keep only the newest token**. The earlier approval lives in \`.claude/reviews/index.jsonl\`,`,
      `    which stores \`plan_sha\` and \`verdict\` per round and does not go stale when a card header is rewritten.`,
      `(2) **Did you really read the wrong one?** (a) cite what you actually read: git -C ${m.root} log --format=%H -1 -- ${m.rel}`,
      `    (b) or re-read at the cited sha and approve again: git -C ${m.root} show ${sha}:${m.rel}`,
      `NOTE: do not self-check with line counts or file size — they collide (one measured incident had 1238 lines on both sides). Compare CONTENT.`,
    ].join('\n'));
  }
}
allow();
