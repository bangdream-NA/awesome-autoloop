#!/usr/bin/env node
import { bumpTurnTick } from './lib/shutdown-ledger.mjs';

let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
  try {
    const sid = (JSON.parse(raw) || {}).session_id || '';
    bumpTurnTick(sid);
  } catch {  }
  process.exit(0);
});
process.stdin.on('error', () => process.exit(0));
