#!/usr/bin/env node
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let payload = {};
try { payload = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

if ((payload.tool_name || "") !== "Bash") process.exit(0);
const cmd = (payload.tool_input && payload.tool_input.command) || "";
if (!cmd) process.exit(0);

// Two classes, and keeping them apart is what stops the false positives.
// STRONG_OP names the operation itself — reaching the host IS the server op, wherever it appears.
// SCRIPT_OP names a SCRIPT, and a script name is only an operation when it sits in an EXECUTION
// context. `shellcheck --shell=bash scripts/provision/<your-deploy-script>` mentions the script and
// runs nothing; matching it denies a lint.
const STRONG_OP = [
  /\bssh\s+(?:[\w.-]+@)?<your-host>\b/,
  /\bscp\b[^\n]*\b<your-host>\b/,
];
const SCRIPT_OP = [
  /<your-deploy-script>/,
  /<your-ingest-cli>/,
  /<your-publish-command>/,
];
const RUNNER_KEYWORD = /\b(?:sudo|bash|corepack|pnpm|npm|node|ssh|exec)\b|(?<![.\w])sh\b/;
const SCRIPT_IN_RUN_POSITION =
  /(?:^|[;&|]\s*|\s\.?\/[\w./-]*\/?|\s\/[\w./-]*\/)(?:<your-deploy-script>|<your-ingest-cli>|<your-publish-command>)/;
function hasExecCtx(c) { return RUNNER_KEYWORD.test(c) || SCRIPT_IN_RUN_POSITION.test(c); }

// Quoted spans, heredoc bodies and --flag=values are DATA, not command text. Strip them before
// asking whether a script name is being run, so a name inside a commit message or a heredoc cannot
// trigger the gate.
const stripData = (c) => c
  .replace(/<<-?\s*["']?\w+["']?[\s\S]*$/, " <<HEREDOC-DATA")
  .replace(/(--[\w-]+)=\S+/g, "$1=OPT-DATA")
  .replace(/'(?:[^'\\]|\\.)*'/g, "'DATA'")
  .replace(/"(?:[^"\\]|\\.)*"/g, '"DATA"');
const cmdStripped = stripData(cmd);

const isProdOp =
  STRONG_OP.some((re) => re.test(cmd)) ||
  (SCRIPT_OP.some((re) => re.test(cmdStripped)) && hasExecCtx(cmdStripped));
if (!isProdOp) process.exit(0);

const RECEIPT = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), ".server-op-runbook-read");
const FRESH_MS = 4 * 60 * 60 * 1000;
function receiptFresh() {
  try { return Date.now() - statSync(RECEIPT).mtimeMs < FRESH_MS; } catch { return false; }
}

const RUNBOOK_PATH = /(?:[\/\\](?:runbooks?|walks)[\/\\])|runbook/i;
function transcriptHasRecentRunbookRead(sessionId) {
  if (!sessionId) return null;
  const projects = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), "projects");
  let file = null;
  try {
    for (const d of readdirSync(projects)) {
      const cand = join(projects, d, sessionId + ".jsonl");
      if (existsSync(cand)) { file = cand; break; }
    }
  } catch { return null; }
  if (!file) return null;
  let text = "";
  try { text = readFileSync(file, "utf8"); } catch { return null; }
  const lines = text.split("\n");
  const tail = lines.slice(Math.max(0, lines.length - 900));
  const now = Date.now();
  for (let i = tail.length - 1; i >= 0; i--) {
    const ln = tail[i];
    if (!ln) continue;
    if (!/"name"\s*:\s*"Read"/.test(ln)) continue;
    if (!RUNBOOK_PATH.test(ln)) continue;
    const m = ln.match(/"timestamp"\s*:\s*"([^"]+)"/);
    if (m) { const t = Date.parse(m[1]); if (!Number.isNaN(t) && now - t > FRESH_MS) continue; }
    return true;
  }
  return false;
}

const verdict = transcriptHasRecentRunbookRead(payload.session_id);
if (verdict === true) process.exit(0);
if (verdict === null && receiptFresh()) process.exit(0);

const reason =
  "SERVER-OP GATE: this is a server/prod operation but NO recent runbook/walk Read was found in the " +
  "session transcript. READ the relevant runbook FIRST, then rerun. The runbook documents HOW the op " +
  "runs (env/secret injection, sudo, file paths) + its known footguns — ad-hoc probing reverse-engineers " +
  "it blindly and gets the premise wrong. " +
  (verdict === null
    ? "[transcript could not be resolved] If you HAVE read the runbook, record it: " +
      `\`printf '%s' '<runbook-path>' > ${RECEIPT}\` then rerun.`
    : "");

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));
process.exit(0);
