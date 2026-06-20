#!/usr/bin/env node
// PreToolUse(Bash) — block compounding `git commit`/`git add` with `git push`/`gh pr merge`
// in ONE command. The whole-command-deny trap (pipeline-discipline §8): when a gated op
// (git push / gh pr merge) in a compound `A && B && push` is denied by the auto-mode
// classifier or a merge gate, the ENTIRE command fails — so the earlier `git add`/`git commit`
// SILENTLY does NOT run, and you proceed believing it committed (then act on the false
// assumption). Fail LOUD here instead of letting the classifier deny the whole opaque blob.
// Stack-agnostic (pure git-command hygiene). FAIL-OPEN (footgun-preventer, not a security gate).
import { readFileSync } from 'node:fs'

let input
try { input = JSON.parse(readFileSync(0, 'utf8')) } catch { process.exit(0) }
if ((input.tool_name || '') !== 'Bash') process.exit(0)
const cmd = input.tool_input && typeof input.tool_input.command === 'string' ? input.tool_input.command : ''
if (!cmd) process.exit(0)

const hasCommit = /\bgit\s+(commit|add)\b/.test(cmd)
const hasPush = /\bgit\s+push\b/.test(cmd) || /\bgh\s+pr\s+merge\b/.test(cmd)
const hasSeparator = /&&|;|\|/.test(cmd) // sequencing/pipe joins more than one command

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
process.exit(0) // allow
