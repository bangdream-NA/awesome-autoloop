#!/usr/bin/env node
// EXAMPLE — not mounted; copy into your own ~/.claude/hooks/ + wire it in your settings.json.
//
// A server-op gate: a SERVER/PROD operation (ssh to your host, a deploy script, an ingest CLI,
// scp to prod) is DENIED unless the recent session transcript shows the lead READ a runbook/walk
// file first. Fail-closed: no runbook-Read evidence → deny. This forces "read the runbook before
// you touch prod" instead of reverse-engineering the box with ad-hoc probes.
//
// This is the SHAPE of a project-specific gate; replace the PROD_OP patterns below with your own
// server-op signatures (your host alias, your deploy script name, your ingest CLI, etc.).
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let payload = {};
try { payload = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

if ((payload.tool_name || "") !== "Bash") process.exit(0);
const cmd = (payload.tool_input && payload.tool_input.command) || "";
if (!cmd) process.exit(0);

// --- Is this a SERVER/PROD operation? Replace with YOUR server-op signatures. ---
const PROD_OP = [
  /\bssh\s+(?:[\w.-]+@)?<your-host>\b/,   // any ssh to your prod host (incl read-only recon)
  /\bscp\b[^\n]*\b<your-host>\b/,          // scp to/from your prod host
  /<your-deploy-script>/,                  // your deploy entry point
  /<your-ingest-cli>/,                     // your data-ingest CLI subcommand(s)
];
if (!PROD_OP.some((re) => re.test(cmd))) process.exit(0);

// --- Escape hatch: a fresh manual attestation receipt (only for transcript-resolution failure) ---
const RECEIPT = join(homedir(), ".claude", ".server-op-runbook-read");
const FRESH_MS = 4 * 60 * 60 * 1000; // 4h
function receiptFresh() {
  try { return Date.now() - statSync(RECEIPT).mtimeMs < FRESH_MS; } catch { return false; }
}

// --- Primary: did the recent transcript Read a runbook/walk file? ---
const RUNBOOK_PATH = /(?:[\/\\](?:runbooks?|walks)[\/\\])|runbook/i;
function transcriptHasRecentRunbookRead(sessionId) {
  if (!sessionId) return null; // can't resolve → null (distinct from false)
  const projects = join(homedir(), ".claude", "projects");
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
  const tail = lines.slice(Math.max(0, lines.length - 900)); // recent tail only
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
if (verdict === null && receiptFresh()) process.exit(0); // transcript unresolved + fresh receipt → allow

const reason =
  "SERVER-OP GATE: this is a server/prod operation but NO recent runbook/walk Read was found in the " +
  "session transcript. READ the relevant runbook FIRST, then rerun. The runbook documents HOW the op " +
  "runs (env/secret injection, sudo, file paths) + its known footguns — ad-hoc probing reverse-engineers " +
  "it blindly and gets the premise wrong. " +
  (verdict === null
    ? "[transcript could not be resolved] If you HAVE read the runbook, record it: " +
      "`printf '%s' '<runbook-path>' > ~/.claude/.server-op-runbook-read` then rerun."
    : "");

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));
process.exit(0);
