import { priorityOf, effectivePriorityMap, OPEN_STATUSES, isDodRemedyTrack, slugOf, statusOf } from './backlog-gate.mjs';
import { isGatedOrObserving } from './backlog-grammar.mjs';
import { cardBlockForBranch } from './backlog-pilot-core.mjs';

export function ladderRefusesBranch(branch, boardText) {
  if (!branch || !boardText) return false;
  let blk = '';
  try { blk = cardBlockForBranch(boardText, branch) || ''; } catch { return false; }
  if (!blk) return false;
  const hdr = blk.split('\n')[0];
  const cards = String(boardText).split(/^### \[/m).slice(1)
    .map((b) => ({ header: '### [' + b.split('\n')[0], block: '### [' + b }))
    .map((c) => ({ ...c, name: slugOf(c.header) || '', status: statusOf(c.header) || '' }));
  const me = cards.find((c) => c.name && hdr.includes(c.name));
  if (!me) return false;
  try { return !!priorityLadderReason(me, cards); } catch { return false; }
}

export function priorityLadderReason(card, cards) {
  const effMap = effectivePriorityMap(
    (Array.isArray(cards) ? cards : []).map((c) => ({ name: c.header, header: c.header })),
  );
  const prioOf = (block) => {
    const own = priorityOf(block);
    const eff = effMap.get(block);
    return eff != null && (own == null || eff < own) ? eff : own;
  };
  const myPrio = prioOf(card.header);
  if (myPrio === null) return null;
  if (isDodRemedyTrack(card.header, cards)) return null;
  const openable = cards.filter((c) => OPEN_STATUSES.includes(c.status)
    && !isGatedOrObserving(c.block) && prioOf(c.header) !== null);
  const highest = openable.reduce((min, c) => Math.min(min, prioOf(c.header)), 99);
  if (!(highest < 99 && myPrio > highest)) return null;
  const peers = openable.filter((c) => prioOf(c.header) === highest);
  return `WAVE PRIORITY ORDER: the card you are dispatching, "${card.name}", is P${myPrio}, but ${peers.length} openable P${highest} card(s) are ahead of it — open those first: ${peers.map((c) => c.name).slice(0, 6).join(', ')}
OPENABLE = QUEUED/IN-DEV/REVIEW whose header carries neither a live \`blocked-by=\` nor an unexpired \`DoD-GATED: observe-until <YYYY-MM-DD>\` (which needs \`gate-observed-at=<ISO Z>\`). A gated card holds no slot.
FIX: to work "${card.name}" first, raise its own P level on the board. No exceptions.`;
}
