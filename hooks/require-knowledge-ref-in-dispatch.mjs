#!/usr/bin/env node
import { readFileSync, existsSync, statSync } from "node:fs";
import { readTranscriptText } from "./lib/transcript-last-assistant.mjs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { autoLogOnDeny } from './lib/log-denial.mjs';
import { liveAgentNames, rosterFilteredHolders, liveAgentMembers, waveOfAgentName } from './lib/roster-live-agents.mjs';
import { projectPaths, worktreeParent } from './lib/is-autoloop-lead.mjs';

// The worktree-root marker an adopter uses; the generic `worktree` alternative below covers
// the common case, and this seam covers a project that names its root something else.
const WT_MARKER = (process.env.AAL_WORKTREE_MARKER || 'wt').replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const MAIN_EXAMPLE = projectPaths()?.repo || '<main-checkout>';
const WT_EXAMPLE = `${worktreeParent(projectPaths()?.repo) || '<worktree-parent-dir>'}/<wave>`;
// 🔴 Where the knowledge base is SEEDED from. The deny below tells an operator to read
// `~/.claude/knowledge/…`, and that path is right by design — the base accumulates across projects,
// so it lives in the operator's home and not in the read-only plugin cache. What was missing is the
// step that puts it there: the installer cannot, because its target follows the chosen install
// scope and under a project-scoped install it would seed `<project>/.claude/knowledge/`, which is
// not the directory this text names. So the seed step belongs in the text that blocks, and its
// SOURCE is resolved from this module rather than written as a literal — a hard-coded path in
// operator-facing text is exactly what goes stale the moment the seed directory moves.
// 🔴 …and it is emitted ONLY when it resolves. A gate whose hooks/ was copied somewhere without
// templates/ would otherwise print a `cp` from a directory that does not exist — the same defect
// one paragraph up, reintroduced by its own fix. Measured: the teeth harness's temp tree is exactly
// that shape (it copies hooks/ and bin/, never templates/).
const KNOWLEDGE_SEED = fileURLToPath(new URL('../templates/knowledge', import.meta.url)).replace(/\\/g, '/');
const KNOWLEDGE_SEED_LINE = existsSync(KNOWLEDGE_SEED)
  ? `First run — that directory is seeded from the plugin, not by the installer:\n  cp -r ${KNOWLEDGE_SEED}/. ~/.claude/knowledge/\n`
  : '';
autoLogOnDeny('require-knowledge-ref-in-dispatch');

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let payload = {};
try { payload = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

if ((payload.tool_name || "") !== "Agent") process.exit(0);
const ti = payload.tool_input || {};
const brief = String(ti.prompt || "");

const role = String(ti.subagent_type || "").toLowerCase();
const name = String(ti.name || "");
const pipelineRoles = ["planner", "architect", "developer", "uiux-designer", "designer", "plan-reviewer", "code-reviewer"];
const looksPipeline = /^(planner|architect|developer|dev|designer|plan-?reviewer|code-?reviewer|arch|reviewer)[-_a-z0-9]*$/i.test(name);
if (!pipelineRoles.includes(role) && !looksPipeline) process.exit(0);

{
  const wtPaths = [...brief.matchAll(new RegExp(`((?:[A-Za-z]:[\\/\\\\]|/)(?:${WT_MARKER}|[^\\s\`'"<>|]*worktree[^\\s\`'"<>|]*)[\\/\\\\][A-Za-z0-9._-]+)`, 'gi'))]
    .map((m) => m[1].replace(/\\/g, '/').toLowerCase());
  const wt = wtPaths.length ? wtPaths[0] : null;
  if (wt) {
    let t = '';
    try { t = readTranscriptText(payload.transcript_path || '').text; } catch { t = ''; }
    const wtBase = wt.split('/').filter(Boolean).pop() || '';
    const members = liveAgentMembers();
    const holders = new Set();
    if (Array.isArray(members)) {
      for (const m of members) {
        if (!m || !m.name || m.name === 'team-lead') continue;
        if (wtBase && waveOfAgentName(m.name) === wtBase) holders.add(m.name);
      }
    } else {
      for (const ln of t.split(/\r?\n/)) {
        if (!ln.toLowerCase().includes(wt)) continue;
        if (!/"name"\s*:\s*"Agent"/.test(ln)) continue;
        for (const m of ln.matchAll(/"name"\s*:\s*"((?:dev|arch|planner|planrev|designer|cr)[-_][A-Za-z0-9._-]+)"/g)) holders.add(m[1]);
      }
    }
    for (const h of [...holders]) {
      const alive = new RegExp('(?:Spawned successfully[\\s\\S]{0,200}|agent_id:\\s*|"from"\\s*:\\s*"|teammate_id="|"to"\\s*:\\s*")' + h.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
      if (!alive.test(t)) holders.delete(h);
    }
    const me = String((payload.tool_input || {}).name || '');
    holders.delete(me);
    const kept = rosterFilteredHolders([...holders], liveAgentNames());
    holders.clear();
    for (const h of kept) holders.add(h);
    if (holders.size) {
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny',
        permissionDecisionReason:
          'BLOCKED: this worktree already has a live holder\n\n' +
          '  worktree: `' + wt + '`\n' +
          '  agent(s) still holding it (dispatched, with no shutdown anywhere in the transcript): ' + [...holders].map((h) => '`' + h + '`').join(' · ') + '\n\n' +
          '**Why this is a hard denial**: two agents writing one tree means one of them destroys the other\u2019s work, and the symptom is SILENT.\n' +
          'Measured: a second developer had done nothing but read, and HEAD had already moved from one SHA to another. An earlier review\n' +
          'recorded the same collision in the same wave, and that time the cost was a working tree wiped by `git checkout --`.\n' +
          '`git status --porcelain` is an INSTANTANEOUS reading, not proof that there is no second writer.\n\n' +
          '**The way out (which is the rule anyway)**: one wave, one worktree, and the NEXT BATON INHERITS IT —\n' +
          '  1. send the previous baton a `shutdown_request` and **confirm it has left the roster**; 2. then dispatch the next one.\n' +
          'NOTE: "it went idle" does not count — idle is not finished. Only a completed shutdown ends a claim.',
      } }));
      process.exit(0);
    }
  }
}
{
  const hasWord = /worktree/i.test(brief);
  // The POSIX branch used to name four directories, so `/work/wt/<wave>` — the kit's own example
  // spelling — was not an absolute path to this gate. It now accepts any root, but only at the
  // start of a token: `~/.claude/knowledge/…` appears in nearly every correct brief and is not the
  // worktree the operator was asked to name.
  // 🔴 A widening fails by matching TOO MUCH, and this one did: `/dev/null`, `/tmp` and
  // `/usr/bin/env` appear in ordinary briefs, so "work in your worktree" plus a stderr redirect
  // read as a brief that NAMES one — the exact dispatch this gate exists to stop, arriving through
  // its own fix. Two conditions close it, and neither is a list that rots:
  //   · MORE THAN ONE SEGMENT — a bare `/tmp` is a directory reference, never a wave's worktree;
  //   · and the first segment is not a system root. That set is fixed by the filesystem layout,
  //     not by taste: nothing is ever dispatched to work in /dev, /proc, /sys, /run, /usr, /etc,
  //     /bin or /sbin. `/tmp/<dir>`, `/srv/…`, `/mnt/…` and `/opt/…` stay ALLOWED — a worktree can
  //     genuinely live in any of them, and excluding them would deny a correct brief.
  const ABS_PATH = /(?:[A-Za-z]:[\/\\]|(?:^|[\s"'`([])\/)[^\s`'"<>|]*[\/\\][^\s`'"<>|]+/g;
  const SYS_ROOT = /^\/(?:dev|proc|sys|run|usr|etc|bin|sbin)(?:\/|$)/i;
  const hasAbsPath = [...brief.matchAll(ABS_PATH)]
    .map((m) => m[0].replace(/^[\s"'`([]+/, ''))
    .some((p) => !SYS_ROOT.test(p));
  if (!hasWord || !hasAbsPath) {
    const missing = !hasWord && !hasAbsPath ? 'it contains neither the word `worktree` nor any absolute path'
      : !hasWord ? 'it has an absolute path, but never says that path IS a **worktree** (a path can be a mere reference)'
      : 'it mentions a worktree but **gives no concrete path** ("in your worktree" is not an instruction)';
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason:
          'BLOCKED: a dispatch has to NAME THE WORKTREE\n' +
          `This brief: ${missing}\n\n` +
          'FIX. Spell it out in the brief:\n' +
          `  Worktree — work ONLY here: \`${WT_EXAMPLE}\` on branch \`feat/r-<wave>\`. Use absolute paths for ` +
          `Read/Edit/Write, and drive git with \`git -C ${WT_EXAMPLE} …\`. Do not touch the main checkout \`${MAIN_EXAMPLE}\`.\n` +
          '  NOTE: a session launched from HOME must not call `EnterWorktree` on that path; absolute paths plus `git -C` are enough.\n' +
          'Verdicts and ledgers are the one exception: the per-verdict `.md` and `index.jsonl` resolve to the MAIN checkout\u2019s ' +
          '`.claude/reviews/` via `git rev-parse --path-format=absolute --git-common-dir`. ' +
          '**The working directory is the worktree; the verdict lands in the main checkout.** Two different things.',
      },
    }));
    process.exit(0);
  }
}

{
  const rootMatch = brief.match(/((?:[A-Za-z]:[\/\\]|\/)[^\n`'"]*?)[\/\\]\.claude[\/\\]BACKLOG\.md/i);
  const projRoot = rootMatch ? rootMatch[1].replace(/\\/g, "/") : "";
  let linked = [];
  if (projRoot) {
    try {
      const out = execFileSync("git", ["-C", projRoot, "worktree", "list", "--porcelain"], {
        encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10000,
      });
      linked = out.split(/\r?\n/)
        .filter((l) => l.startsWith("worktree "))
        .map((l) => l.slice(9).replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase())
        .slice(1);
    } catch { linked = []; }
  }
  if (linked.length) {
    const cited = [...new Set((brief.match(/(?:[A-Za-z]:[\/\\]|(?<![\w.\-/:~])\/)[^\s`'"<>|)\]]{3,}/g) || [])
      .map((p) => p.replace(/[.,;:]+$/, "").replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase()))];
    const hit = cited.some((p) => linked.some((w) => p === w || p.startsWith(w + "/")));
    if (!hit) {
      process.stdout.write(JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason:
            'BLOCKED: the WORKTREE the brief names does not exist.\n' +
            `**No** absolute path in this brief falls inside a registered linked worktree of \`${projRoot}\`.\n` +
            `Registered (excluding the main checkout, which belongs to the lead):\n  ${linked.join('\n  ') || '(none)'}\n\n` +
            '**The previous gate only proves you WROTE a path; it cannot prove the path EXISTS.** Dispatched into a directory ' +
            'that was never `git worktree add`-ed, an agent has no legal work surface — and the failure is silent. It looks exactly ' +
            'like a dispatch that never named a worktree at all: `dirty=0`, zero artifacts, which reads as "the agent died".\n\n' +
            'Measured: one developer was dispatched and, seven and a half hours later, the PR head still sat on the SHA the review ' +
            'had already sent back, `git worktree list` held no branch of its own, and the main checkout\u2019s porcelain was empty — ' +
            'four channels agreeing on zero artifacts. Pinging it returned `No agent named … is reachable`.\n\n' +
            `**Create it, then dispatch**: \`git -C <main-checkout> worktree add ${WT_EXAMPLE} <branch>\`, ` +
            `then write \`Worktree — work ONLY here: ${WT_EXAMPLE} on <branch>\` in the brief.\n` +
            'NOTE: pointing at the verdict location inside the main checkout (`…/.claude/reviews/…`) is CORRECT, but it is not a ' +
            'work surface — so naming only that does not clear this gate.',
        },
      }));
      process.exit(0);
    }
  }
}


const REF_RE = /agent-knowledge|[.\/\\~]claude[\/\\]knowledge|knowledge[\/\\]INDEX/i;
if (REF_RE.test(brief)) process.exit(0);

const WAIVER = join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude"), ".knowledge-ref-waived");
try { if (Date.now() - statSync(WAIVER).mtimeMs < 4 * 60 * 60 * 1000) process.exit(0); } catch {  }

const reason =
  'BLOCKED: the dispatch brief contains no pointer to the knowledge base\n\n' +
  'FIX. Add it to the brief, then dispatch:\n' +
  "  Read `~/.claude/knowledge/INDEX.md`, then `~/.claude/knowledge/<your-role>/INDEX.md` and the " +
  "files under `<your-role>/` + `common/` your task needs.\n" +
  KNOWLEDGE_SEED_LINE +
  'Role directories: planner · plan-reviewer · architect · uiux-designer · developer · code-reviewer.\n' +
  'NOTE: do not point at an in-repo `docs/agent-knowledge/` — that tree is gone.\n' +
  'Exemption: a dispatch that deliberately carries no pointer ⇒ `touch ~/.claude/.knowledge-ref-waived` (valid 4 hours), then dispatch.';

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));
process.exit(0);
