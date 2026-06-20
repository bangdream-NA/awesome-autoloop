---
name: rotate
description: >
  Rotate the autoloop LEAD session. Refreshes the durable handoff
  (<project>/.claude/handoffs/current-session.md) as the source-of-truth, then launches a fresh
  session from the HOME cwd seeded with the RESUME-ROTATION sentinel. Invoke when context is high
  or per the lead-session-rotation protocol (per merged wave / every few hours / after several
  dispatch rounds / on SendMessage degradation). The new session reads the handoff and resumes the
  autoloop; the old session winds down.
---

# /rotate — autoloop lead-session rotation

Long lead sessions degrade (SendMessage loss, socket fails, context bloat). This skill hands the
autoloop to a FRESH session via the **durable handoff** (NOT live SendMessage). Run it at a CLEAN
checkpoint — ideally when in-flight waves are at a DURABLE state (committed branch / open PR /
logged code-review verdict), because in-process teammates are tied to THIS session and their live
SendMessages are LOST on rotation; the new session must pick them up from durable artifacts.

## Steps (perform in order)

### 1. Refresh the handoff SOT — `<project>/.claude/handoffs/current-session.md`
It MUST let a cold session resume with zero context. Verify/update it to contain:
- **GOAL** (verbatim — the new session runs `/goal` with it to re-arm the goal-completion driver).
- **OPERATING MODE** (autoloop autonomy, authorizations, trust-no-one, the project's DoD verification
  method, language preference, agents-local-only + isolated-worktrees, no `.claude/` in git).
- **DONE + LIVE** this session (PR#s + DoD status).
- **IN-FLIGHT** — for EACH, the DURABLE pickup point, NOT the in-process agent: open PR # + SHA,
  committed branch + worktree, or the logged `code-reviews.md` / `plan-reviews.md` verdict. (The new
  session can't receive the old session's agent SendMessages — it re-picks-up from these. A
  mid-coding dev with no commit yet → note "re-dispatch" or check its worktree.)
- **QUEUED** waves + **NEXT ACTIONS** + any LEAD-owed pre-merge tasks.
- **ENV FOOTGUNS** (server-op prefixes, verify-PUSHED-sha-not-worktree, ledger rotation, register-wave
  aliases, etc. — whatever your project's gates require).
- **STATE**: `main` HEAD sha, worktree count, team name, stall-cron note.

Edit large files (BACKLOG / op-log / code-reviews) via your shell's append (`cat >>`) or a string
replace — the Edit tool needs a prior Read that clears on compaction, and these ledgers are large.

### 2. Launch the fresh session
Launch a fresh `claude` session **from the HOME cwd** seeded with the single token `RESUME-ROTATION`.
HOME cwd is intentional: it loads the global `~/.claude/CLAUDE.md` + `~/.claude/rules/` + the
home-keyed auto-memory. (A project-cwd session would miss all of that.) The global config maps
`RESUME-ROTATION` to the STARTUP SEQUENCE: `/goal` (verbatim from the handoff) → `/effort` →
read the handoff → resume.

#### Platform-specific launch

**Windows (Windows-Terminal):** invoke `wt.exe` directly to open a new visible window:
```
wt.exe -d <HOME-cwd> claude RESUME-ROTATION
```
The `-d` dir is the HOME cwd so global config + memory load. `RESUME-ROTATION` is one space-free
token because `wt.exe` splits a multi-word prompt into separate args.

**Optional user-authored launcher.** Some setups wrap the launch in a small script (refresh the
handoff, then `Start-Process wt.exe …`) so `/rotate` is one command. That launcher is **yours to
write and configure** — this skill does not ship one and does not hardcode its path. If you have
one, run it; otherwise use the direct `wt.exe` form above. (Note: a global `PowerShell` deny rule or
the auto-mode classifier may block a `powershell …`-wrapped launcher invoked via Bash; `wt.exe` is a
distinct tool and is typically permitted. If the wrapped form is blocked, fall back to the direct
`wt.exe` form, or present the launcher for the USER to run via the `! ` prefix — their own action,
not the agent-Bash classifier.)

**macOS / Linux / no `wt.exe`:** open a fresh terminal in the HOME cwd and start `claude`, then
paste the single token `RESUME-ROTATION` as the first message. Any terminal that can run `claude`
from `$HOME` works — there is no Windows-Terminal dependency. (Graceful degrade: the protocol does
NOT require any launcher; a manually-started session that reads the handoff is equivalent.)

### 3. Confirm + wind down
- Confirm the new window opened (a launcher should print a "launched" line; otherwise eyeball it).
- The NEW window owns the autoloop now. The OLD (this) session: shut down any in-process teammates
  whose deliverables are durable (committed / PR'd / logged), then go idle — do NOT keep dispatching
  (two leads on one team collide). The new session re-picks-up in-flight work from the handoff's
  durable pointers.

## Notes
- `/goal` and `/effort` are RUNTIME slash commands run IN the new session (the CLI `--effort` flag
  may reject the highest tier); the `RESUME-ROTATION` sentinel + the handoff STARTUP SEQUENCE drive
  them. If they aren't self-invokable in the new window, ask the user to type them, then continue.
- A smoke-test variant launches the new window with `ROTATION-LAUNCHER-SMOKE-TEST` instead — the
  global config maps that to "reply `ROTATION-LAUNCHER-OK` and STOP" (verifies the launch path
  without starting the autoloop).
- Sibling: the lead-session-rotation protocol in your global rules / memory.
