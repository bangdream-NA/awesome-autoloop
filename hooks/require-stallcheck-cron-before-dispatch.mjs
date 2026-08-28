#!/usr/bin/env node
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let payload = {};
try { payload = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

if ((payload.tool_name || "") !== "Agent") process.exit(0);
const ti = payload.tool_input || {};

const role = String(ti.subagent_type || "").toLowerCase();
const name = String(ti.name || "");
const pipelineRoles = ["planner", "architect", "developer", "uiux-designer", "designer", "plan-reviewer", "code-reviewer"];
const looksPipeline = /^(planner|architect|developer|dev|designer|plan-?reviewer|code-?reviewer|arch|reviewer)[-_a-z0-9]*$/i.test(name);
if (!pipelineRoles.includes(role) && !looksPipeline) process.exit(0);

const RECEIPT = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), ".stallcheck-cron-created");
const FRESH_MS = 4 * 60 * 60 * 1000;
function receiptFresh() {
  try { return Date.now() - statSync(RECEIPT).mtimeMs < FRESH_MS; } catch { return false; }
}

function transcriptHasStallCron(sessionId) {
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
  for (const ln of text.split("\n")) {
    if (!ln) continue;
    if (!/"name"\s*:\s*"CronCreate"/.test(ln)) continue;
    if (!/stall[\s-]?check/i.test(ln)) continue;
    return true;
  }
  return false;
}

const verdict = transcriptHasStallCron(payload.session_id);
if (verdict === true) process.exit(0);
if (verdict === null && receiptFresh()) process.exit(0);

const reason =
  "🚫 STALL-CHECK CRON GATE (pipeline-discipline §1): pipeline-role dispatch but NO " +
  "CronCreate(STALL-CHECK) tool_use found in this session's transcript. An autonomous run MUST create " +
  "the recurring stall-check cron BEFORE its first dispatch — it covers the idle waits Stop hooks " +
  "cannot see, and crons are session-only so each new/rotated session re-creates it. CREATE IT NOW, " +
  "then re-dispatch: (ToolSearch 'select:CronCreate' first if not loaded) CronCreate({cron:'7,37 * * * *', " +
  "recurring:true, prompt:'STALL-CHECK (artifact-first, no-op-if-idle) — <project/wave>: check each " +
  "in-flight agent by ON-DISK artifact growth (git log/status in its worktree, verdict/ledger files); " +
  "growing WIP = alive, leave it alone; >30min zero-artifact AND silent = presumed dead, re-dispatch; " +
  "drive any landed-but-unprocessed deliverable to the next pipeline step; if all progressing or " +
  "nothing in flight: NO-OP, end turn silently.'})  " +
  "INTERACTIVE (non-autonomous) use: set AAL_STALLCHECK=off in your settings.json env to skip this gate " +
  "WITHOUT disabling the rest of the pipeline-roles group." +
  (verdict === null
    ? " [transcript could not be resolved for this session] If you HAVE created the cron, record it: " +
      `printf '%s' '<cron-job-id>' > ${RECEIPT}  then re-dispatch.`
    : "");

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));
process.exit(0);
