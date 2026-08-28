import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const STATE = process.env.SHUTDOWN_LEDGER_STATE_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'hooks', '.state');
const ledgerPath = (sid) => join(STATE, `shutdown-ledger-${sid || 'nosid'}.json`);
const tickPath = (sid) => join(STATE, `shutdown-turn-tick-${sid || 'nosid'}.json`);

const readJson = (p, dflt) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return dflt; } };
const writeJson = (p, v) => {
  try { mkdirSync(STATE, { recursive: true }); writeFileSync(p, JSON.stringify(v)); return true; } catch { return false; }
};


export function bumpTurnTick(sid) {
  const next = { n: turnTick(sid) + 1 };
  writeJson(tickPath(sid), next);
  return next.n;
}


export function turnTick(sid) {
  return Number(readJson(tickPath(sid), { n: 0 }).n) || 0;
}


export function recordShutdownSent(sid, agent) {
  const name = String(agent || '');
  if (!name) return;
  const all = readJson(ledgerPath(sid), {});
  all[name] = { tick: turnTick(sid), at: new Date().toISOString() };
  writeJson(ledgerPath(sid), all);
}


function inboxPathFor(name, teamsDirOverride) {
  const base = teamsDirOverride || process.env.RLA_TEAMS_DIR || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'teams');
  let dirs;
  try { dirs = readdirSync(base); } catch { return null; }
  for (const d of dirs) {
    const p = join(base, d, 'inboxes', `${name}.json`);
    if (existsSync(p)) return p;
  }
  return null;
}

export function canTaskStop(sid, agent, teamsDirOverride) {
  const name = String(agent || '');
  if (!name) return { ok: false, why: 'the `task_id` is unrecognisable, so the shutdown cannot be checked.' };

  const rec = readJson(ledgerPath(sid), {})[name];
  if (!rec) return { ok: false, why: 'there is **no record** of a structured `shutdown_request` ever being sent to it — send that first.' };

  const delta = turnTick(sid) - (Number(rec.tick) || 0);
  if (delta < 2) return { ok: false, why: `only **${delta}** turn boundary/boundaries have passed since the shutdown was sent; the criterion is **two consecutive**. End the turn first.` };

  const inbox = inboxPathFor(name, teamsDirOverride);
  if (!inbox) return { ok: false, why: 'its inbox file was not found, so delivery of the shutdown cannot be shown.' };
  const pending = readJson(inbox, null);
  if (pending === null) return { ok: false, why: 'the inbox is unreadable, so delivery of the shutdown cannot be shown.' };
  if (Array.isArray(pending) && pending.length > 0) {
    return { ok: false, why: `**${pending.length}** undelivered message(s) are still queued in its inbox — the shutdown has not reached it yet.` };
  }

  return { ok: true, why: `a structured shutdown_request was sent · ${delta} turn boundaries have passed · the inbox has drained.` };
}
