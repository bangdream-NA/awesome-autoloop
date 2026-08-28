#!/usr/bin/env node
import { readFileSync } from 'node:fs'

let input
try { input = JSON.parse(readFileSync(0, 'utf8')) } catch { process.exit(0) }
if ((input.tool_name || '') !== 'Bash') process.exit(0)
const cmd = input.tool_input && typeof input.tool_input.command === 'string' ? input.tool_input.command : ''
if (!cmd) process.exit(0)

const hasCommit = /\bgit\s+(commit|add)\b/.test(cmd)
const hasPush = /\bgit\s+push\b/.test(cmd) || /\bgh\s+pr\s+merge\b/.test(cmd)
const hasSeparator = /&&|;|\|/.test(cmd)

if (hasCommit && hasPush && hasSeparator) {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'PreToolUse',
      permissionDecision: 'deny',
      permissionDecisionReason:
        'whole-command-deny risk (pipeline-discipline §8): git push / gh pr merge is a gated op — ' +
        'if it is denied, the ENTIRE compound command fails and the earlier git add/git commit ' +
        'SILENTLY does not run (you will wrongly believe it committed). Split it: run `git add` / ' +
        '`git commit` as their OWN Bash call, then `git push` / `gh pr merge` as a SEPARATE atomic call. ' +
        '(Doc/op-log rows mentioning these phrases: write via the Edit/Write tool, which bypass Bash gates.)',
    },
  }))
  process.exit(0)
}
process.exit(0)
