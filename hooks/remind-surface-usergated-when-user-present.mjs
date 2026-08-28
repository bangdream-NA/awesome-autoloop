#!/usr/bin/env node
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { liveBlocker } from "./lib/backlog-gate.mjs";
import { sessionProject, projectPaths } from './lib/is-autoloop-lead.mjs';

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let STDIN = {};
try { STDIN = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

const RECEIPT = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), ".usergated-reminder-shown");
const THROTTLE_MS = 30 * 60 * 1000;
try {
  if (Date.now() - statSync(RECEIPT).mtimeMs < THROTTLE_MS) process.exit(0);
} catch {  }

const SELF_REPO = sessionProject(STDIN) || projectPaths(STDIN)?.repo || '';
if (!SELF_REPO) process.exit(0);
const BOARDS = [join(SELF_REPO, ".claude", "BACKLOG.md")];
let total = 0;
const samples = [];
for (const b of BOARDS) {
  let txt = "";
  try { txt = readFileSync(b, "utf8"); } catch { continue; }
  for (const line of txt.split(/\r?\n/)) {
    if (!/^### \[/.test(line)) continue;
    const isUserGated = /^### \[USER-GATED\]/.test(line);
    const lb = String(liveBlocker(line) || '').toLowerCase();
    const NEGATED = /\b(?:not (?:yet )?(?:released|cleared|lifted)|still (?:blocked|gated)|awaiting release)\b/i;
    const RESOLVED_PROSE = (s) =>
      !NEGATED.test(s) &&
      (/\b(?:already|now)\b[^\n]{0,40}\b(?:released|cleared|lifted)\b/i.test(s) ||
        /\b(?:withdrawn|closed out|voided|retired|abolished|taken down|removed|no longer blocked by|RESOLVED|WITHDRAWN)\b/i.test(s));
    const ABOLISHED = /\[gate abolished|\[the original gate [^\]]* was taken down\]/i.test(line);
    const legacyUserPhrasing = /gate = \*\*user|user-decision|user-OQ/.test(line) &&
      !lb && !ABOLISHED && !RESOLVED_PROSE(line);
    const isQueuedUser = /^### \[QUEUED\]/.test(line) && (lb === 'user' || legacyUserPhrasing);
    if (isUserGated || isQueuedUser) {
      total++;
      const nm = (line.match(/^### \[[^\]]+\]\s+([A-Za-z0-9._-]+)/) || [])[1];
      const proj = b.replace(/\\/g, '/').replace(/\/\.claude\/BACKLOG\.md$/i, '').split('/').pop();
      if (nm && samples.length < 6) samples.push(proj ? `${proj}/${nm}` : nm);
    }
  }
}
if (total === 0) process.exit(0);

try { writeFileSync(RECEIPT, String(Date.now()), "utf8"); } catch {  }

const ctx =
  `USER-PRESENT ⇒ SURFACE THE USER-GATED CARDS: they are sending messages right now, and the board holds ${total} card(s) waiting on their ruling` +
  (samples.length ? ` (for example ${samples.join(', ')})` : '') +
  `. Parking is only legitimate when they are genuinely AFK. FIX: put them all through AskUserQuestion in one batch, with the full background INSIDE the dialog.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: ctx },
}));
process.exit(0);
