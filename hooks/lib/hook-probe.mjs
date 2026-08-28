import { spawnSync } from 'node:child_process';
import { writeFileSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const TMP = mkdtempSync(join(tmpdir(), 'hookprobe-'));
let seq = 0;


export function payload(fields) {
  if (!fields || typeof fields !== 'object') throw new Error('payload(): need an object');
  const f = join(TMP, `p${seq++}.json`);
  writeFileSync(f, JSON.stringify(fields), 'utf8');
  return f;
}

export function probe(hookPath, fields) {
  if (!fields.cwd) {
    throw new Error(
      'probe(): `cwd` is required. A gate that resolves its project from cwd silently no-ops ' +
      'without it, and every arm then passes vacuously.',
    );
  }
  const json = JSON.stringify(fields);
  payload(fields);
  const runner = /\.mjs$|\.cjs$|\.js$/.test(hookPath) ? process.execPath : 'bash';
  const r = spawnSync(runner, [hookPath], { input: json, encoding: 'utf8' });
  let decision = 'ALLOW';
  try {
    const out = JSON.parse(r.stdout || '{}');
    if (out?.hookSpecificOutput?.permissionDecision === 'deny') decision = 'DENY';
    if (out?.decision === 'block') decision = 'DENY';
  } catch {  }
  const nonZeroExit = r.status !== 0;
  let delegate = false;
  if (decision === 'ALLOW' && nonZeroExit) {
    delegate = isDelegate(hookPath);
    if (!delegate) decision = 'DENY';
  }
  return { decision, stdout: r.stdout || '', stderr: r.stderr || '', status: r.status, nonZeroExit, delegate };
}

function isDelegate(hookPath) {
  const base = hookPath.replace(/\\/g, '/').split('/').pop();
  const dir = hookPath.replace(/\\/g, '/').split('/').slice(0, -1).join('/');
  for (const disp of ['backlog-guard.mjs', 'stop-node-dispatcher.mjs']) {
    try {
      const src = readFileSync(`${dir}/${disp}`, 'utf8');
      const m = src.match(/const\s+DELEGATES\s*=[\s\S]{0,4000}?\];/);
      if (m && m[0].includes(`'${base}'`)) return true;
    } catch {  }
  }
  return false;
}

export function runArms(hookPath, arms, common = {}) {
  let fail = 0;
  let denyPassed = 0;
  for (const a of arms) {
    const { decision, stdout } = probe(hookPath, {
      tool_name: a.tool_name || 'Bash',
      tool_input: a.tool_input || { command: a.command },
      ...common,
      ...(a.cwd ? { cwd: a.cwd } : {}),
    });
    const ok = decision === a.want;
    if (ok && a.want === 'DENY') denyPassed++;
    if (!ok) fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'} [want=${a.want}${ok ? '' : ` got=${decision}`}] ${a.why || a.command}`);
    if (!ok && stdout) console.log(`     stdout: ${stdout.slice(0, 200)}`);
    if (ok && a.want === 'DENY' && a.expectInReason && !new RegExp(a.expectInReason).test(stdout)) {
      fail++;
      console.log(`FAIL [denial message] missing /${a.expectInReason}/ — a denial that doesn't say what to do is half a gate`);
    }
  }
  if (denyPassed === 0) {
    fail++;
    console.log('FAIL [suite] no DENY arm passed — a suite that never goes red proves nothing about the gate');
  }
  console.log(fail ? `\n${fail} FAILED` : `\nall ${arms.length} arms PASS (${denyPassed} discriminating)`);
  return fail;
}
