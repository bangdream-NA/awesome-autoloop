---
name: no-paste-terminal
description: Playbook for operating from a console where you can't paste long commands (VPS web console, KVM-over-IP, mobile typing). Keep commands short, use curl|bash from raw.githubusercontent, avoid interactive prompts.
---

# No-Paste Terminal Playbook

Use this skill when the user is operating from a context where they can't paste long commands.

Trigger phrases (user mentions any of these):
- VPS console / web console / cloud console
- can't paste / no paste / mobile typing
- one-liner / short link
- iLO / IPMI / KVM-over-IP
- typing it in

## Rules when in no-paste mode

1. **Target <70 characters per command**
   - Web console terminals often wrap at 70-80 cols on mobile / cramped views
   - Long URLs / IDs break paste-less typing especially badly

2. **Use `curl | bash` from `raw.githubusercontent.com`**
   - `curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/<branch>/<path> | bash`
   - SHORTER than gist raw URLs (gist hashes are 40+ chars)
   - Don't use `https://gist.githubusercontent.com/...` — too long
   - Don't use `tinyurl` / `is.gd` — bot challenges fail silently in no-paste contexts

3. **Use short branch/path names**
   - `main/setup.sh` over `feature-branch-name-2026/scripts/setup.sh`
   - If a path is long, host the script at the repo root or a short subdir

4. **Set environment via `-e` not multiline**
   - `curl ... | TOKEN=xxx bash` rather than asking the user to export-then-run
   - But if TOKEN is long, instruct the user to fetch it from an on-machine file (`sudo grep ...`)

5. **Confirm the command works locally before sending**
   - `curl -sS <url> | head -3` first
   - Bug-fixing via a paste-less terminal is very expensive

6. **Avoid commands that prompt for confirmation**
   - `rm -rf` will prompt — pre-confirm via `-f` once the command is verified safe
   - `gh auth login` is interactive — pre-auth via a PAT export

7. **No JSON strings in chat as paste fodder**
   - Chat soft-wraps insert real newlines on paste, breaking JSON
   - Use sed / PowerShell one-liners to mutate config files in-place instead
   - Or have the user fetch a script that does the mutation
