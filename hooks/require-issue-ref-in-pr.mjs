#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-issue-ref-in-pr');

let payload = {};
try { payload = JSON.parse(readFileSync(0, "utf8") || "{}"); } catch { process.exit(0); }
if ((payload.tool_name || "") !== "Bash") process.exit(0);
const cmd = String(payload.tool_input?.command || "");
if (!cmd) process.exit(0);

if (!/(^|[;&|]\s*)gh\s+pr\s+create\b/m.test(cmd)) process.exit(0);

{
  const cwd0 = payload.cwd || process.cwd();
  let changed = [];
  try {
    const base = execFileSync("git", ["-C", cwd0, "merge-base", "origin/main", "HEAD"], { encoding: "utf8" }).trim();
    changed = execFileSync("git", ["-C", cwd0, "diff", "--name-only", `${base}..HEAD`], { encoding: "utf8" })
      .split(/\r?\n/).filter(Boolean);
  } catch { changed = []; }
  const isPlan = (f) => /^docs\/product-specs\/.*-plan\.md$/i.test(f);
  const isCompanion = (f) => /^docs\/agent-knowledge\//i.test(f);
  if (changed.length && changed.some(isPlan) && changed.every((f) => isPlan(f) || isCompanion(f))) {
    const plans = changed.filter(isPlan);
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          'BLOCKED: a planning wave does not open a PR\n' +
          `Against origin/main this branch changes ONLY plan documents: ${plans.join(', ')}` +
          (changed.length > plans.length ? ` (plus ${changed.length - plans.length} knowledge fragment(s), which does not change the verdict)` : '') +
          '\n\nFIX: dispatch a `plan-reviewer` (the card\u2019s `stage=` has to be `planning`) so the verdict lands in ' +
          '`.claude/reviews/index.jsonl` pinned to `plan_blob` (only a code wave pins `head_sha`).\n' +
          'The plan itself lands with the code, in the IMPLEMENTATION wave\u2019s PR.\n' +
          'A mixed PR (plan plus implementation) and a pure runbook-docs PR both pass — this gate only catches "nothing but a plan".',
      },
    }));
    process.exit(0);
  }
}

// ONE to five digits. Demanding two made a repository's first nine issues unreferenceable: the
// denial told the operator to take the number off the card, and taking it produced the same
// denial. The upper bound and the trailing \b are unchanged, so `#123456` is still out of range and
// `#1a2b3c` is still not a reference.
if (/#\d{1,5}\b/.test(cmd)) process.exit(0);
if (/--body-file\b|-F\b/.test(cmd)) process.exit(0);

const CWD = payload.cwd || process.cwd();
let root = "";
try { root = execFileSync("git", ["-C", CWD, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim(); } catch { process.exit(0); }

let board = "";
try { board = readFileSync(`${root}/.claude/BACKLOG.md`, "utf8"); } catch { process.exit(0); }

let slug = (cmd.match(/#\s*CARD:\s*([\w.-]+)/i) || [])[1] || "";
if (!slug) {
  try {
    const br = execFileSync("git", ["-C", CWD, "branch", "--show-current"], { encoding: "utf8" }).trim();
    slug = br.replace(/^(feat|fix|chore|docs)\//, "");
  } catch {  }
}
let hint = "";
if (slug) {
  const blocks = board.split(/^###\s+\[/m);
  const key = slug.replace(/^r-/i, "").toLowerCase();
  const hit = blocks.find((b) => b.toLowerCase().includes(key));
  const n = hit && (hit.match(/^\s*-?\s*issue:\s*#(\d+)\s*$/m) || [])[1];
  if (n) hint = `\n\nThis branch maps to card \`${slug}\` → its issue is **#${n}**. Add \`Refs #${n}\` (or \`Closes #${n}\` if this PR fully resolves the card) to the PR body.`;
  else hint = `\n\nCould not resolve an \`issue:\` line for \`${slug}\` on the board. Run the sync first: \`AAL_BACKLOG=${root}/.claude/BACKLOG.md AAL_REPO=<owner/repo> node <hooks>/backlog-issue-sync.mjs --apply\`, then read the card's \`issue: #N\`.`;
}

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      'BLOCKED: this `gh pr create` body references no issue\n' + hint +
      '\nFIX: take the number from the card\u2019s `issue: #N` line and put it in the PR body before opening. **Do not guess the number.**'
  },
}));
