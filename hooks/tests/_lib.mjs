process.env.AAL_GATE_DENIALS_OFF = '1';


export const TEST_ENV = { ...process.env, AAL_GATE_DENIALS_OFF: '1' };

import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function pinnedBoard(opts = {}) {
  const root = mkdtempSync(join(tmpdir(), 'pinboard-'));
  mkdirSync(join(root, '.claude'), { recursive: true });
  const board = root + '/.claude/SYNTH-BOARD.md';
  const parkedCard = '### [QUEUED] R-pinned-parked-card · design-scope: no · stage=new'
    + ' · blocked-by=user · asked-at=2026-08-19T00:00:00Z · **P0** · synthetic fixture\n'
    + '- problem: synthetic fixture, present only as a reachability control\n'
    + '- user-question: synthetic fixture\n';
  const noScopeCard = '### [QUEUED] R-pinned-no-scope-card · stage=arch-ok · **P2** · synthetic fixture\n'
    + '- problem: synthetic fixture whose header carries no design-scope token at all\n';
  writeFileSync(board, [
    '# BACKLOG', '', '## Active', '',
    '### [QUEUED] R-pinned-clean-card · design-scope: no · stage=new · **P2** · synthetic fixture',
    '- problem: synthetic fixture with no gate of any kind',
    '',
    opts.noScope ? noScopeCard : '',
    '',
    opts.parked ? parkedCard : '',
    '',
  ].join('\n'), 'utf8');
  const fwd = root.split(String.fromCharCode(92)).join('/');
  if (opts.asRepo) {
    writeFileSync(join(root, '.claude', 'BACKLOG.md'), readFileSync(board, 'utf8'), 'utf8');
    execFileSync('git', ['init', '-q'], { cwd: root, stdio: 'ignore' });
  }
  return { root: fwd, board };
}


export const envWithBoard = (pin) => ({ ...process.env, AAL_GATE_DENIALS_OFF: "1", AAL_BACKLOG: pin.board });
