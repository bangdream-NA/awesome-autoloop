#!/usr/bin/env node
// awesome-autoloop installer — copies the user-owned framework templates
// (CLAUDE.md framework, rules/common/*, BACKLOG template) into the target .claude/,
// parameterized via {{VAR}} substitution. STAGED-ATOMIC: nothing is written until the
// fail-loud {{VAR}} check passes. Idempotent + non-destructive on re-run: replaces only the
// managed CLAUDE.md block, writes a <rule>.new sidecar when a rule template changed (your edited
// copy is kept), and NEVER touches an existing BACKLOG.md (your live board).
//
// Usage:
//   node install.mjs --plugin-root <dir> [--target <dir>] [options]
// Options:
//   --plugin-root <dir>     REQUIRED. The plugin root (templates/ lives under it).
//   --target <dir>          The .claude/ dir to write into (default: $HOME/.claude).
//   --project-dir <dir>     {{PROJECT_DIR}} (default: parent of --target).
//   --backlog-path <path>   {{BACKLOG_PATH}} (default: <target>/BACKLOG.md).
//   --worktree-root <slug>  {{WORKTREE_ROOT}} (omit / "none" → worktree blocks dropped).
//   --gates <list>          AAL_GATES colon/comma list (default = all 5 groups: commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk).
//   --notify-webhook <url>  {{NOTIFY_WEBHOOK}} (omit → none).
//   --notify-cmd <cmd>      {{NOTIFY_CMD}} (omit → none).
//   --dry-run               Print the plan and exit WITHOUT writing (AC-4 scripted path).
//   --apply | --yes         Write without an interactive confirm (the skill confirms in chat).
//
// Default (no --dry-run / --apply): prints the dry-run plan and exits 0 with status
// "PENDING-CONFIRM" so the calling skill can show it then re-invoke with --apply.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { homedir } from "node:os";

const KNOWN_GATES = ["commit-hygiene", "pipeline-roles", "merge-gates", "ledger-hygiene", "dod-walk"];

// Expand a leading ~ / ~/ to $HOME so a literal "~/.claude" arg lands in the real home.
function expandTilde(p) {
  return (p && (p === "~" || p.startsWith("~/"))) ? join(homedir(), p.slice(1)) : p;
}

// ---- arg parsing ----
function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--dry-run") a.dryRun = true;
    else if (k === "--apply" || k === "--yes") a.apply = true;
    else if (k.startsWith("--")) { a[k.slice(2)] = argv[i + 1]; i++; }
  }
  return a;
}
const args = parseArgs(process.argv.slice(2));

const pluginRoot = args["plugin-root"];
if (!pluginRoot) {
  console.error("ERROR: --plugin-root is required (the directory containing templates/).");
  process.exit(2);
}
const target = resolve(expandTilde(args.target) || join(homedir(), ".claude"));
const projectDir = expandTilde(args["project-dir"]) || dirname(target);
const backlogPath = expandTilde(args["backlog-path"]) || join(target, "BACKLOG.md");
let worktreeRoot = args["worktree-root"];
if (worktreeRoot === "none" || worktreeRoot === "") worktreeRoot = undefined;
const gates = (args.gates || "commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk").replace(/,/g, ":");
const unknownGates = gates.split(":").filter((t) => t && !KNOWN_GATES.includes(t));
if (unknownGates.length) {
  console.error(`ERROR: --gates has unknown group token(s): ${unknownGates.join(", ")}.`);
  console.error(`  A typo silently disables every gate in that group (each gate self-skips unless its group is listed).`);
  console.error(`  Known groups: ${KNOWN_GATES.join(" ")}.`);
  process.exit(2);
}
const notifyWebhook = args["notify-webhook"] && args["notify-webhook"] !== "none" ? args["notify-webhook"] : undefined;
const notifyCmd = args["notify-cmd"] && args["notify-cmd"] !== "none" ? args["notify-cmd"] : undefined;

const templatesDir = join(pluginRoot, "templates");

// ---- substitution map ----
const SUBS = {
  "{{PROJECT_DIR}}": projectDir,
  "{{BACKLOG_PATH}}": backlogPath,
  "{{WORKTREE_ROOT}}": worktreeRoot || "",
  "{{NOTIFY_WEBHOOK}}": notifyWebhook || "",
  "{{NOTIFY_CMD}}": notifyCmd || "",
};

// Strip <!-- aal:if WORKTREE_ROOT -->...<!-- aal:endif --> blocks when worktreeRoot is unset.
function applyConditionals(text) {
  const reBlock = /<!--\s*aal:if\s+WORKTREE_ROOT\s*-->([\s\S]*?)<!--\s*aal:endif\s*-->/g;
  if (worktreeRoot) {
    // keep the inner content, drop only the markers
    return text.replace(reBlock, (_m, inner) => inner);
  }
  // drop the whole block
  return text.replace(reBlock, "");
}

function substitute(text) {
  let out = applyConditionals(text);
  for (const [k, v] of Object.entries(SUBS)) {
    out = out.split(k).join(v);
  }
  return out;
}

// ---- the template files to copy (relative paths under templates/ → relative under target) ----
// policy: "skip-if-exists" (never touch a live file — the board) | "sidecar" (write <dst>.new
// when the on-disk copy differs from the shipped template, so a user edit is preserved).
const TEMPLATE_FILES = [
  { src: "rules/common/principles.md", dst: "rules/common/principles.md", policy: "sidecar" },
  { src: "rules/common/pipeline-discipline.md", dst: "rules/common/pipeline-discipline.md", policy: "sidecar" },
  { src: "BACKLOG.md", dst: "BACKLOG.md", policy: "skip-if-exists" },
  { src: "struggle-log.md", dst: "struggle-log.md", policy: "skip-if-exists" },
  { src: "code-reviews.md", dst: "code-reviews.md", policy: "skip-if-exists" },
  { src: "plan-reviews.md", dst: "plan-reviews.md", policy: "skip-if-exists" },
  { src: "reviews/index.jsonl", dst: "reviews/index.jsonl", policy: "skip-if-exists" },
  { src: "reviews/TEMPLATE.jsonl", dst: "reviews/TEMPLATE.jsonl", policy: "skip-if-exists" },
  { src: "walks/TEMPLATE.md", dst: "walks/TEMPLATE.md", policy: "skip-if-exists" },
  { src: "autoloop-log-TEMPLATE.md", dst: "autoloop-log-TEMPLATE.md", policy: "skip-if-exists" },
];
const CLAUDE_SRC = "CLAUDE.md";
const CLAUDE_DST = "CLAUDE.md";

const BEGIN = "<!-- BEGIN awesome-autoloop (managed block - do not edit between these markers; re-run the installer to update) -->";
const END = "<!-- END awesome-autoloop -->";

// ---- stage all substitutions in memory ----
const staged = []; // { absPath, content, status }
let aborted = null;

function stageFile(srcRel, dstRel, policy) {
  const srcAbs = join(templatesDir, srcRel);
  if (!existsSync(srcAbs)) {
    aborted = { reason: `template missing: templates/${srcRel}`, file: srcAbs };
    return;
  }
  const content = substitute(readFileSync(srcAbs, "utf8"));
  const dstAbs = join(target, dstRel);
  if (!existsSync(dstAbs)) {
    staged.push({ absPath: dstAbs, content, status: "create", dstRel });
    return;
  }
  if (policy === "skip-if-exists") {
    staged.push({ absPath: dstAbs, content, status: "skip-exists", dstRel });
    return;
  }
  // sidecar: identical on-disk → skip; differs → write <dst>.new beside the user's edited copy.
  const onDisk = readFileSync(dstAbs, "utf8");
  if (onDisk === content) {
    staged.push({ absPath: dstAbs, content, status: "skip-exists", dstRel });
    return;
  }
  staged.push({ absPath: dstAbs + ".new", content, status: "sidecar", dstRel: dstRel + ".new" });
}

for (const t of TEMPLATE_FILES) stageFile(t.src, t.dst, t.policy);

// ---- CLAUDE.md managed-block handling (create / append / replace-in-place) ----
const claudeSrcAbs = join(templatesDir, CLAUDE_SRC);
let claudePlan = null;
if (!existsSync(claudeSrcAbs)) {
  aborted = aborted || { reason: `template missing: templates/${CLAUDE_SRC}`, file: claudeSrcAbs };
} else {
  const blockBody = substitute(readFileSync(claudeSrcAbs, "utf8")).trim();
  const managedBlock = `${BEGIN}\n${blockBody}\n${END}\n`;
  const claudeDstAbs = join(target, CLAUDE_DST);
  if (!existsSync(claudeDstAbs)) {
    claudePlan = { absPath: claudeDstAbs, content: managedBlock, status: "create", dstRel: CLAUDE_DST };
  } else {
    const existing = readFileSync(claudeDstAbs, "utf8");
    const bIdx = existing.indexOf(BEGIN);
    // Anchor the END search AFTER this BEGIN, so an orphan/duplicate END before BEGIN can't mis-slice.
    const eIdx = bIdx === -1 ? -1 : existing.indexOf(END, bIdx + BEGIN.length);
    if (bIdx !== -1 && eIdx !== -1) {
      // replace in place — only the bytes between (and including) the markers
      const before = existing.slice(0, bIdx);
      const after = existing.slice(eIdx + END.length);
      const next = `${before}${BEGIN}\n${blockBody}\n${END}${after}`;
      claudePlan = { absPath: claudeDstAbs, content: next, status: "replace-in-place", dstRel: CLAUDE_DST };
    } else {
      // append after existing content
      const sep = existing.endsWith("\n") ? "\n" : "\n\n";
      const next = `${existing}${sep}${managedBlock}`;
      claudePlan = { absPath: claudeDstAbs, content: next, status: "append", dstRel: CLAUDE_DST };
    }
  }
  // C-11: the residual {{...}} scan must look ONLY at plugin-origin bytes (the managed block body),
  // never the user's pre-existing CLAUDE.md bytes embedded in `content`.
  if (claudePlan) claudePlan.residualCheck = blockBody;
}
if (claudePlan) staged.push(claudePlan);

// ---- fail-loud check (F-204): no residual {{...}} in any staged content ----
if (!aborted) {
  const reResidual = /\{\{[^}]+\}\}/;
  for (const s of staged) {
    // For CLAUDE.md, scan only the plugin-origin block body; for templates, content IS plugin-origin.
    const checkText = s.residualCheck ?? s.content;
    const m = checkText.match(reResidual);
    if (m) {
      // find line number
      const upto = checkText.slice(0, m.index);
      const line = upto.split("\n").length;
      aborted = {
        reason: "a template variable was not substituted",
        file: s.absPath,
        line,
        token: m[0],
        snippet: checkText.split("\n")[line - 1],
      };
      break;
    }
  }
}

// ---- output: dry-run plan ----
function printPlan() {
  const glyph = (st) =>
    st === "create" ? "+" : st === "skip-exists" ? "=" : "~";
  console.log("  ── Dry run (nothing written yet) ─────────────────────────────");
  console.log("");
  console.log(`  Target .claude/:  ${target}`);
  console.log("");
  console.log("  A. Files");
  for (const s of staged) {
    const label =
      s.status === "create" ? "create" :
      s.status === "append" ? "merge (existing file; append managed block)" :
      s.status === "replace-in-place" ? "update (existing managed block replaced in place)" :
      s.status === "sidecar" ? "update available (writes .new sidecar; your copy is untouched)" :
      "skip (already present; left untouched)";
    console.log(`    ${glyph(s.status)}  ${s.absPath}    ${label}`);
  }
  console.log("");
  console.log("  B. Variables substituted into the copied templates");
  console.log(`    {{PROJECT_DIR}}    -> ${projectDir}`);
  console.log(`    {{BACKLOG_PATH}}   -> ${backlogPath}`);
  console.log(`    {{WORKTREE_ROOT}}  -> ${worktreeRoot || "(none; single-tree — blocks referencing it are omitted)"}`);
  console.log(`    {{NOTIFY_WEBHOOK}} -> ${notifyWebhook || "(none)"}`);
  console.log(`    {{NOTIFY_CMD}}     -> ${notifyCmd || "(none)"}`);
  console.log("");
  console.log("  Gate groups + Agent-Teams flag (written into settings.json env on --apply):");
  console.log(`    AAL_GATES = ${gates}`);
  console.log("");
  console.log("  No {{...}} placeholders remain unsubstituted.   <- fail-loud check passed");
  console.log("  ──────────────────────────────────────────────────────────────");
}

function printAbort() {
  console.error("");
  console.error("  X Install aborted — " + aborted.reason + ".");
  console.error("");
  console.error(`    File:    ${aborted.file}`);
  if (aborted.line) {
    console.error(`    Line ${aborted.line}: ${aborted.snippet}`);
    console.error(`    Unsubstituted token: ${aborted.token}`);
  }
  console.error("");
  console.error("  This is a bug in the plugin's templates (a {{...}} placeholder had no");
  console.error("  value to fill). NOTHING was written; nothing on your machine changed.");
  console.error("");
  console.error("ABORTED");
}

if (aborted) {
  printAbort();
  process.exit(1);
}

if (args.dryRun) {
  printPlan();
  console.log("DRY-RUN (no files written)");
  process.exit(0);
}

if (!args.apply) {
  // default path: print the plan, exit PENDING-CONFIRM (skill shows it + re-invokes with --apply)
  printPlan();
  console.log("PENDING-CONFIRM (re-run with --apply to write)");
  process.exit(0);
}

// ---- apply: write staged files atomically (all-or-nothing already guaranteed by the
//      fail-loud check above; if we reach here, every staged content is clean) ----
let wrote = 0;
for (const s of staged) {
  if (s.status === "skip-exists") continue; // honor skip — never overwrite a live user file
  mkdirSync(dirname(s.absPath), { recursive: true });
  writeFileSync(s.absPath, s.content);
  wrote++;
}

console.log("WROTE " + wrote + " file(s).");

// Drop the activation marker (its EXISTENCE flags this project as autoloop-managed so the
// globally-mounted gate hooks enforce here). Unconditional + idempotent (empty file).
writeFileSync(join(target, ".autoloop"), "");

// R-8: drop the profiler-pending marker so SessionStart nudges the user to tailor (idempotent, empty).
writeFileSync(join(target, ".pending-profile"), "");

// --- merge AAL_* + AGENT_TEAMS into settings.json env (single parse→merge→write) ---
const settingsPath = join(target, "settings.json");
let settings = {};
if (existsSync(settingsPath)) {
  try { settings = JSON.parse(readFileSync(settingsPath, "utf8")); }
  catch (e) {
    // malformed existing JSON → FAIL LOUD, never silently drop the user's file
    console.error(`ERROR: ${settingsPath} is not valid JSON (${e.message}). Fix it by hand, then re-run --apply. Nothing was written to it.`);
    process.exit(1);
  }
}
settings.env = settings.env || {};
settings.env.AAL_GATES = gates;                                  // selected groups (the real fix)
settings.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";         // HARD prereq for Agent Teams
if (worktreeRoot) settings.env.AAL_WORKTREE_ROOT = worktreeRoot;
if (notifyWebhook) settings.env.AAL_NOTIFY_WEBHOOK = notifyWebhook;
if (notifyCmd) settings.env.AAL_NOTIFY_CMD = notifyCmd;
writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
console.log(`WROTE env (AAL_GATES + CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS) into ${settingsPath}`);

// --- turn on the engine: capability is installed, but nothing DRIVES the wave loop yet ---
console.log("");
console.log("  ── Next: put Claude into an autonomous posture ───────────────");
console.log("  The gate groups + the Agent-Teams flag above give the pipeline its");
console.log("  CAPABILITY — but nothing yet DRIVES the wave loop. The plugin cannot set");
console.log("  session-level permission or a standing goal, so this is a per-session");
console.log("  choice only you can make:");
console.log("    1. Give Claude a STANDING GOAL (the objective it should keep driving toward).");
console.log("    2. Run it in an UNATTENDED permission posture so dispatches / commits /");
console.log("       merges don't stop to prompt you each time.");
console.log("  Without both, you have a pipeline team that just sits idle — the gates");
console.log("  enforce discipline, but no loop runs. See the README for the activation model.");
console.log("  ──────────────────────────────────────────────────────────────");
console.log("");
console.log("  ── Tailor to THIS project ────────────────────────────────────");
console.log("  Run /awesome-autoloop:project-profiler to scan your stack and PROPOSE a");
console.log("  tailored setup (gate groups, what the live-verify walk means here, which");
console.log("  stack-rules to adopt). It proposes — nothing is written without your OK.");
console.log("  ──────────────────────────────────────────────────────────────");
console.log("DONE");
process.exit(0);
