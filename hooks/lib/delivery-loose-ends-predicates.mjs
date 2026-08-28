const GRACE_MS = 5 * 60 * 1000;
const WINDOW_MS = 8 * 3600 * 1000;


export function shutdownMissing(row, shutdownsSeen, nowMs, rosterNames) {
  const name = String(row?.reviewer_name || '').trim();
  if (!name) return null;
  const ts = Date.parse(row?.ts || '');
  if (!Number.isFinite(ts)) return null;
  if (nowMs - ts < GRACE_MS) return null;
  if (nowMs - ts > WINDOW_MS) return null;
  const norm = (s) => String(s).replace(/-r\d+$/i, '');
  const seenNorm = (shutdownsSeen || []).map(norm);
  const shutdownSent = seenNorm.includes(norm(name));
  if (shutdownSent && !Array.isArray(rosterNames)) return null;

  if (Array.isArray(rosterNames)) {
    const ROLE_WORD = /^(cr|code|codereview|reviewer|plan|planner|dev|developer|arch|architect|team|lead|uiux|designer)$/;
    const toks = (s) => new Set(String(s).toLowerCase().split(/[^a-z0-9]+/)
      .filter((t) => t.length >= 4 && !ROLE_WORD.test(t)));
    const wanted = toks(name);
    if (!wanted.size) return null;
    const REVIEWER_ROLE = /(^|[^a-z])(cr|codereview|reviewer)([^a-z]|$)|-pr\d+-/i;
    const round = Number(row?.round);
    const roundOk = (rn) => !Number.isFinite(round) || new RegExp(`-r${round}$`, 'i').test(rn);
    const stillHere = rosterNames.some((rn) => {
      if (!REVIEWER_ROLE.test(rn)) return false;
      if (!roundOk(rn)) return false;
      for (const t of toks(rn)) if (wanted.has(t)) return true;
      return false;
    });
    if (!stillHere) return null;
  }
  return { name, ts: row.ts, verdict: row.verdict, shutdownSent };
}


export function nextBatonMissing(card, nowMs) {
  const files = card?.branchArchFiles || [];
  if (!files.length) return null;
  const stage = String(card?.stage || '');
  if (!/^(arch|arch-ok)$/.test(stage)) return null;
  const logs = card?.logs || [];
  if (logs.some((l) => /dispatch(ed)?\s*dev/i.test(l))) return null;
  const stamps = logs.map((l) => Date.parse((l.match(/(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/) || [])[1] || ''))
    .filter((n) => Number.isFinite(n));
  if (!stamps.length) return null;
  const latest = Math.max(...stamps);
  if (nowMs - latest < GRACE_MS) return null;
  if (nowMs - latest > WINDOW_MS) return null;
  return { files, stage, since: new Date(latest).toISOString() };
}

export function collectShutdownNames(text, into) {
  const names = into || new Set();
  for (const ln of String(text || '').split(/\r?\n/)) {
    if (!ln.includes('shutdown_request')) continue;
    for (const m of ln.matchAll(/"to"\s*:\s*"([^"]+)"/g)) names.add(m[1]);
    for (const m of ln.matchAll(/"target"\s*:\s*"@?([^"]+)"/g)) names.add(m[1]);
  }
  return names;
}

export function denialText(shutdowns, batons) {
  const out = [];
  if (shutdowns.length) {
    out.push('BLOCKED: **a delivery was accepted and the agent that wrote it was never shut down**');
    for (const s of shutdowns) out.push(s.shutdownSent
      ? `  · \`${s.name}\` filed ${s.verdict} at ${String(s.ts).slice(11, 19)}; the shutdown was **sent but never landed** — it is still on the roster`
      : `  · \`${s.name}\` filed ${s.verdict} at ${String(s.ts).slice(11, 19)} and has never received a shutdown_request`);
    if (shutdowns.some((s) => s.shutdownSent)) out.push('  => for the ones that did not land, use `TaskStop` (task_id = the agent name), then re-read the roster to confirm it left. Sending another shutdown degrades the same way.');
    if (shutdowns.some((s) => !s.shutdownSent)) out.push('  => for the ones never sent: send a real `shutdown_request` in THIS response, as an object, not as prose.');
  }
  if (batons.length) {
    if (out.length) out.push('');
    out.push('BLOCKED: **the architecture landed and the next baton was never dispatched** — the ledger carries no architect row, so no other gate can see this step');
    for (const b of batons) out.push(`  · ${b.files.map((f) => f.replace('docs/product-specs/', '')).join(' · ')} is on the branch (new against origin/main), the card sits at \`stage=${b.stage}\`, last activity ${String(b.since).slice(11, 19)}, and no dispatch of a developer was logged`);
    out.push('  => **dispatch the developer**, and record `- log: <ISO Z> · dispatched <who>` on the card in the SAME turn.');
  }
  return out.join('\n');
}
