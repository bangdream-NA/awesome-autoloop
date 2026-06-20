---
name: claude-doctor
description: Harness self-check for ~/.claude — validates settings.json, hook mount↔disk consistency (orphans + dangling mounts), and the node/parse-json dependency. Run when hooks/settings were edited, or periodically.
---

# claude-doctor

Run the diagnostic and report findings to the user:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/claude-doctor/doctor.sh"
```

It checks, read-only:
1. **node on PATH** — `parse-json.sh` (and every `json_get` hook) is a silent no-op without it.
2. **settings.json validity** — invalid JSON silently disables ALL settings; also prints deny/allow counts + hook events.
3. **Mounted hooks → script on disk** — flags `DANGLING MOUNT` (settings references a missing script).
4. **Orphan scripts** — `.sh` in `hooks/` not mounted in settings.json (utilities or stale; informational `warn`).

> **Plugin installs: an empty `~/.claude/hooks` is NORMAL — not a failure.** When you install awesome-autoloop as a plugin, the hooks run from the plugin cache, NOT from `~/.claude/hooks`. So your `~/.claude/hooks` may be empty (or hold only your own hooks), and that's expected. The doctor's step-0 "config dir has NO hooks" line is calibrated for a self-hosted `~/.claude` (hooks copied in by hand); for a plugin install, ignore it — your gates are live from the cache. Run the doctor against a directory where you DO keep hooks, or just disregard the step-0 finding on a clean plugin-only setup.

Interpreting output:
- `[FAIL]` → fix before relying on the harness (broken JSON / dangling mount / missing node) — EXCEPT the step-0 "no hooks" line on a plugin-only setup (see the note above).
- `[warn]` → review: an orphan may be an intentional utility OR a stale/should-be-mounted hook. Decide per-script.
- Exit 0 = no failures.

After any edit to your `~/.claude/hooks/*` or `~/.claude/settings.json`, run this before trusting the gates ("mounted ≠ works").
