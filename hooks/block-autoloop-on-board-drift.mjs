#!/usr/bin/env node
import { readFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { isDodRemedyTrack } from './lib/backlog-gate.mjs';
import { homeDir } from './lib/is-autoloop-lead.mjs';
autoLogOnDeny('block-autoloop-on-board-drift');

let payload = {};
try { payload = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { process.exit(0); }
if ((payload.tool_name || '') !== 'Agent') process.exit(0);
const ti = payload.tool_input || {};

const role = String(ti.subagent_type || '').toLowerCase();
const name = String(ti.name || '');
const pipelineRoles = ['planner', 'architect', 'developer', 'uiux-designer', 'designer', 'plan-reviewer', 'code-reviewer'];
const looksPipeline = /^(planner|architect|developer|dev|designer|plan-?reviewer|code-?reviewer|arch|reviewer)[-_a-z0-9]*$/i.test(name);
if (!pipelineRoles.includes(role) && !looksPipeline) process.exit(0);

const prompt = String(ti.prompt || '');
// A board path is absolute in either spelling — `X:/…` on Windows, `/…` on Linux and macOS — and
// Git Bash writes a Windows drive as a ONE-LETTER first segment (`/c/…`), which node cannot open.
// Accepting only those two drive shapes matched NO board at all on Linux or macOS: `boards` came
// back empty, the gate exited 0 in silence, and a dispatch onto a drifted board went through — the
// exact failure this kit exists to remove. The one-letter form is folded back to a drive on win32
// only: elsewhere one character is a convention, not a guarantee, and `/w/proj` is a real path.
// The lookbehind is what stops the widening from over-firing — without it the second slash of
// `https://host/x/.claude/BACKLOG.md` starts a match, and a URL is not a board.
const boards = new Set();
for (const m of prompt.matchAll(/(?<![\w.\-/:~])(?:[A-Za-z]:\/|\/)[^\s"'`)\]]*?\/\.claude\/BACKLOG\.md/g)) {
  let dir = m[0].replace(/\/BACKLOG\.md$/i, '');
  const drive = dir.match(/^([A-Za-z]):\//);
  if (drive) dir = `${drive[1].toUpperCase()}:/${dir.slice(3)}`;
  else if (process.platform === 'win32') dir = dir.replace(/^\/([A-Za-z])\//, (_m, d) => `${d.toUpperCase()}:/`);
  boards.add(dir);
}
if (!boards.size) process.exit(0);

const RECONCILE = `${homeDir()}/.claude/hooks/backlog-reconcile.mjs`;
const REVERIFY_MS = 10 * 60 * 1000;
const FRESH_MS = 12 * 60 * 60 * 1000;
for (const dir of boards) {
  const stateFile = `${dir}/.reconcile-state.json`;
  let mtime = 0;
  try { mtime = statSync(stateFile).mtimeMs; } catch { mtime = 0; }
  if (Date.now() - mtime > REVERIFY_MS) {
    try {
      const projDir = dir.replace(/\/\.claude$/i, '');
      const url = spawnSync('git', ['-C', projDir, 'remote', 'get-url', 'origin'], { encoding: 'utf8', timeout: 5000 }).stdout.trim();
      const rm = url.match(/github\.com[:/]([^/\s]+\/[^\s/]+?)(?:\.git)?\s*$/);
      if (rm) {
        spawnSync('node', [RECONCILE], {
          env: { ...process.env, CLAUDE_HOOK: '1', AAL_BACKLOG: `${dir}/BACKLOG.md`, AAL_REPO: rm[1] },
          encoding: 'utf8',
          timeout: 25000,
        });
      }
    } catch {  }
  }
  try {
    const out = spawnSync('node', [`${homeDir()}/.claude/hooks/backlog-pilot.mjs`, '--board', `${dir}/BACKLOG.md`, '--json'],
      { encoding: 'utf8', timeout: 45000 });
    const v = JSON.parse(out.stdout || '{}');
    let remedyExempt = false;
    let exemptSlug = '';
    try {
      const ti0 = payload.tool_input || {};
      const brief = `${ti0.prompt || ''}\n${ti0.description || ''}`;
      if (brief) {
        const lines2 = readFileSync(`${dir}/BACKLOG.md`, 'utf8').split(/\r?\n/);
        const cards2 = lines2.filter((l) => l.startsWith('### ')).map((h) => ({ header: h, block: h }));
        for (const m of brief.matchAll(/\bR-[A-Za-z0-9-]{10,}/g)) {
          const esc = m[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          const re2 = new RegExp('^###\\s*\\[[A-Za-z-]+\\]\\s*(?:[^·\\n]{0,40}·\\s*)?' + esc + '\\b');
          const hdr = lines2.find((l) => re2.test(l));
          if (hdr && isDodRemedyTrack(hdr, cards2)) { remedyExempt = true; exemptSlug = m[0]; break; }
        }
      }
    } catch { remedyExempt = false; }
    if (Array.isArray(v.owed) && v.owed.length && v.mergeSource !== 'UNAVAILABLE' && !remedyExempt) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: 'PreToolUse',
          permissionDecision: 'deny',
          permissionDecisionReason:
            `BLOCKED: OWED-DoD LOCK. ${dir}/BACKLOG.md has ${v.owed.length} unsettled DoD item(s), so this project **may not dispatch any pipeline role** until that list is empty.\nEach item's release condition is written on its own row (add the ack / land the DoD evidence / archive it / write a verifiable gate token). Prose does not release it, and archiving does not silence it.\nSelf-check: node <hooks>/backlog-pilot.mjs --board ${dir}/BACKLOG.md\n` +
            v.owed.map((o) => `  · [${o.kind}] ${o.card} [${o.status}] — ${String(o.detail || '').slice(0, 640)}`).join('\n') +
            (() => {
              try {
                const board = readFileSync(`${dir}/BACKLOG.md`, 'utf8').split(/\r?\n/);
                const tracks = new Set();
                for (const o of v.owed) {
                  const cre = new RegExp('^###\\s*\\[[A-Za-z-]+\\]\\s*(?:[^·\\n]{0,40}·\\s*)?' + String(o.card).replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b');
                  const ci = board.findIndex((l) => cre.test(l));
                  const m = ci >= 0 ? board[ci].match(/dod-remedy-tracks=([^\s·]+)/) : null;
                  if (m) for (const s of m[1].split(',')) if (s.trim()) tracks.add(s.trim());
                }
                if (!tracks.size) return '\n\nNOTE: NEITHER failed card carries `dod-remedy-tracks=`, so no track is named anywhere and there genuinely is nobody to dispatch.';
                const broken = [];
                for (const s of tracks) {
                  const re = new RegExp('^###\\s*\\[[A-Za-z-]+\\]\\s*(?:[^·\\n]{0,40}·\\s*)?' + s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\b');
                  const i = board.findIndex((l) => re.test(l));
                  if (i < 0) broken.push(`    MISSING: no such card on the board  ${s}`);
                  else if (!/dod-remedy-for=/.test(board[i])) broken.push(`    the card exists, but its own header LACKS \`dod-remedy-for=\`  ${s}`);
                }
                if (!broken.length) {
                  return `\n\n**Both link directions are complete** (all ${tracks.size} track(s) checked: each card is on the board, and each carries \`dod-remedy-for=\` on its own header).\n`
                    + '  ⇒ **a missing link is NOT what is blocking you.** Do not go and add fields, and do not change the gate on the strength of this. The reason for the lock is the sentence above: no new wave while a DoD is owed.';
                }
                return '\n\n**The OTHER side of the bidirectional link is broken — and that is the value the dispatch gate actually reads** (the list above is only the source-card side):\n'
                  + broken.join('\n')
                  + `\n  (the remaining ${tracks.size - broken.length} are complete and not listed.)\n\n`
                  + '  Fix: add `dod-remedy-for=<source card slug>` to that card\u2019s `### ` line, then dispatch.\n'
                  + '  NOTE: do not change the gate on the strength of this — in the source-card list above, a complete card and a card missing its link look identical.';
              } catch { return ''; }
            })(),
        },
      }));
      process.exit(0);
    }
  } catch {  }

  let st;
  try {
    if (Date.now() - statSync(stateFile).mtimeMs > FRESH_MS) continue;
    st = JSON.parse(readFileSync(stateFile, 'utf8'));
  } catch { continue; }
  if (!st || st.dirty !== true) continue;
  const refresh = `AAL_BACKLOG=${dir}/BACKLOG.md AAL_REPO=${st.repo || '<owner/repo>'} node <hooks>/backlog-reconcile.mjs`;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `BLOCKED: AUTOLOOP DRIFT LOCK. The board at ${dir}/BACKLOG.md has ${st.driftCount} unresolved DRIFT item(s) against machine truth — the whole autoloop for this project is LOCKED (no pipeline dispatch, no merge) until the board is reconciled. FIX each drift item on the board (archive with a MERGED #N ack / update the stage status), then refresh the verdict: ${refresh} — a clean run unlocks it automatically. Drift report:\n${String(st.report || '').slice(0, 1500)}`,
    },
  }));
  process.exit(0);
}
process.exit(0);
