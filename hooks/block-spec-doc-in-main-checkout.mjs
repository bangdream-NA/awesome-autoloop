#!/usr/bin/env node
// block-spec-doc-in-main-checkout.mjs
// PreToolUse(Write|Edit|MultiEdit): a wave spec doc (plan/architecture/design) under
// docs/product-specs/ MUST be written to the wave's WORKTREE, never the shared MAIN checkout.
// Writing to main dirties the shared tree (blocks clean-tree/prod gates) and strands the doc off
// the wave branch. No-ops unless AAL_MAIN_REPO is set (the shared main checkout path). Deny is
// fail-OPEN: a parse error or a non-spec path never blocks an unrelated write.
import { readFileSync } from 'node:fs';

const MAIN = String(process.env.AAL_MAIN_REPO || '').replace(/\\/g, '/').replace(/\/+$/, '');
if (!MAIN) process.exit(0);              // no main-checkout configured -> cannot judge -> no-op

let raw = '';
try { raw = readFileSync(0, 'utf8'); } catch { process.exit(0); }
let fp = '';
try {
  const j = JSON.parse(raw);
  fp = (j && j.tool_input && (j.tool_input.file_path || j.tool_input.path)) || '';
} catch { process.exit(0); }

const norm = String(fp).replace(/\\/g, '/').toLowerCase();
if (norm.startsWith((MAIN + '/docs/product-specs/').toLowerCase())) {
  const wtRoot = process.env.AAL_WORKTREE_ROOT || '<worktree-root>';
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        `WAVE SPEC DOC -> WORKTREE, NOT MAIN: a plan/architecture/design doc under docs/product-specs/ must be written to the wave WORKTREE (${wtRoot}/<wave>/docs/product-specs/...), NOT the shared main checkout (${MAIN}). Writing to main dirties the shared tree (blocks clean-tree/prod-mutation gates) and strands the doc off the wave branch. FIX: create the wave worktree (git worktree add ${wtRoot}/<wave> -b feat/<wave> origin/main) BEFORE dispatching the first pipeline agent, and write every doc UNDER that worktree. Re-issue this write with the ${wtRoot}/<wave>/docs/product-specs/... path.`,
    },
  }));
  process.exit(0);
}
process.exit(0);
