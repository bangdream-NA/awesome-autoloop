
import { spawnSync } from 'node:child_process';
import { projectPaths } from './is-autoloop-lead.mjs';

export const WORKTREE_CAP = 12;
export const WORKTREE_REPO = projectPaths()?.repo || '';

export function worktreeCount(repo = WORKTREE_REPO) {
  const r = spawnSync('git', ['-C', repo, 'worktree', 'list'], { encoding: 'utf8' });
  if (r.status !== 0 || typeof r.stdout !== 'string') return null;
  // Linked worktrees only: `git worktree list` prints the MAIN checkout first, so the count
  // is every other entry. Matching a name marker instead would leak one project's layout
  // and would read 0 for anybody whose worktrees are named differently.
  const entries = r.stdout.split(/\r?\n/).filter((l) => l.trim());
  return Math.max(0, entries.length - 1);
}

export function atCap(count = worktreeCount(), cap = WORKTREE_CAP) {
  return count !== null && count >= cap;
}

export const WORKTREE_CAP_CEILING = 16;


export function inversion({ openable = 0, inFlightSameTier = 0 } = {}) {
  return (openable > 0 && inFlightSameTier === 0) ? openable : 0;
}


export function effectiveCap(ctx, base = WORKTREE_CAP) {
  return Math.min(base + inversion(ctx), WORKTREE_CAP_CEILING);
}

export function atCapFor(ctx, count = worktreeCount()) {
  if (count === null) return false;
  return count >= effectiveCap(ctx);
}


export function capNote(count = worktreeCount(), cap = WORKTREE_CAP) {
  if (count === null) return null;
  if (count < cap) return null;
  return `worktree ${count}/${cap} is FULL — opening a new wave needs a worktree, and every dispatch must name one, so the "open a card" prompt is silenced this turn. Owed DoD / red PRs / drift / idle-baton layers are unaffected and still speak. A slot is freed by landing a wave, never by removing a worktree that is in use.`;
}
