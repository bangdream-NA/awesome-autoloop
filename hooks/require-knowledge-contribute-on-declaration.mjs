#!/usr/bin/env node
import { readFileSync, existsSync, statSync, appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-knowledge-contribute-on-declaration');

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let payload = {};
try { payload = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

if ((payload.tool_name || "") !== "SendMessage") process.exit(0);

if (!process.env.CLAUDE_CODE_CHILD_SESSION) process.exit(0);

const ti = payload.tool_input || {};

const to = String(ti.to || "");
if (to !== "team-lead" && to !== "main") process.exit(0);

const m = ti.message;
let msg = "";
if (typeof m === "string") msg = m;
else if (m != null) { try { msg = JSON.stringify(m); } catch { msg = ""; } }
if (!msg) process.exit(0);

const DECL_RE = /KNOWLEDGE[- ]CONTRIBUTION\s*:\s*(committed|surfaced|none)\b/i;
if (DECL_RE.test(msg)) process.exit(0);

const FRAME_RE = /\b(i (?:discovered|found that|learned|realized|uncovered|spotted)|discovered that|turns out(?: that)?|root cause (?:was|is|turned out)|worth writing up|worth a knowledge|future waves? (?:should|must|will)|the real (?:bug|cause|mechanism) (?:was|is)|new (?:mechanism|gotcha|trap) (?:here|found|discovered))\b/i;
const frame = msg.match(FRAME_RE);
if (!frame) process.exit(0);


const WAIVER = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), ".knowledge-contribute-waived");
try { if (Date.now() - statSync(WAIVER).mtimeMs < 4 * 60 * 60 * 1000) process.exit(0); } catch {  }

const sink = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), ".knowledge-contribute-warns.log");
try {
  appendFileSync(sink, JSON.stringify({
    ts: new Date().toISOString(),
    session: process.env.CLAUDE_CODE_SESSION_ID || "",
    to,
    frame: frame[0].slice(0, 80),
  }) + "\n");
} catch {  }

const nudge =
  'KNOWLEDGE-CONTRIBUTION nudge (a suggestion; this does not block): the hand-off contains discovery-shaped wording ("' + frame[0].slice(0, 60) + '")' +
  'but no KNOWLEDGE-CONTRIBUTION line. Your own agent definition governs — that section is a CONDITIONAL, and writing nothing is a normal outcome.\n' +
  'The test: is this a durable mechanism a future agent on ANY wave would want, or a fact about THIS wave only? The second goes in the delivery report, not the knowledge base.\n' +
  'If you do write one, put it in your own role directory and declare one line: `KNOWLEDGE-CONTRIBUTION: committed <file>` / `surfaced — <one sentence>` / `none — <reason>`.\n' +
  'Exemption: `touch <config dir>/.knowledge-contribute-waived` (4h).';

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: nudge },
}));
process.exit(0);

