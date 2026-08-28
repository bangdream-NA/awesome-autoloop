#!/usr/bin/env bash
set -eu

case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":merge-gates:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
INPUT=$(cat 2>/dev/null || echo "")
CMD=$(printf '%s' "$INPUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);process.stdout.write(String((j.tool_input&&j.tool_input.command)||""))}catch{}})' 2>/dev/null || echo "")
[ -n "$CMD" ] || exit 0

printf '%s' "$CMD" | grep -qE 'worktree[[:space:]]+remove' || exit 0

if printf '%s' "$CMD" | grep -qE '#[[:space:]]*WORKTREE-REMOVE-OK:[[:space:]]*[^[:space:]]{8,}'; then exit 0; fi

REPO="<your-checkout>"
deny() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}' "$1"
  exit 0
}
J() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }

TARGETS=$(printf '%s' "$CMD" | grep -oiE '[/]?[A-Za-z][:/]?[/]<your-worktree-marker>[/][A-Za-z0-9._-]+' | sed 's#^\([A-Za-z]\):#/\1#' | sort -u)
[ -n "$TARGETS" ] || exit 0

for T in $TARGETS; do
  NAME=$(basename "$T")

  if command -v powershell.exe >/dev/null 2>&1; then
    WTPAT=$(printf '%s' "$NAME" | sed 's/[^A-Za-z0-9._-]//g')
    HOLDERS=$(powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { (\$_.CommandLine -like '*<your-worktree-marker>*${WTPAT}\\*' -or \$_.CommandLine -like '*<your-worktree-marker>*${WTPAT}/*') -and \$_.Name -notin @('bash.exe','sh.exe','cmd.exe','powershell.exe','pwsh.exe','conhost.exe') } | ForEach-Object { \$_.ProcessId.ToString() + ' ' + \$_.Name }" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+ ' || true)
    if [ -n "$HOLDERS" ]; then
      NHOLD=$(printf '%s\n' "$HOLDERS" | grep -c . || echo 0)
      deny "$(J "WORKTREE-REMOVE: $NAME is still held by $NHOLD process(es). Removing it now DEREGISTERS SUCCESSFULLY AND LEAVES THE DIRECTORY BEHIND.

Holders (PID · process name):
$(printf '%s\n' "$HOLDERS" | head -8 | sed 's/^/  · /')

Measured cost: the removal reported failure,
and **the registration had already been deleted** — the registry says it is gone, the disk says it is not. That is the trap the pipeline discipline records.
The only symptom is an rc=255, which reads byte-identically to 'git does not support this operation'.

These are usually orphans left by an agent running tests (\`next start\`, \`tsx\`, an esbuild daemon). **They do not exit when the agent shuts down.**

Reap first, then remove (one command; it kills only processes whose command line points into this tree):
  powershell.exe -NoProfile -Command \"Get-CimInstance Win32_Process | Where-Object { \\\$_.CommandLine -like '*<your-worktree-marker>*$WTPAT*' } | ForEach-Object { Stop-Process -Id \\\$_.ProcessId -Force }\"
Then re-run this remove, **and compare the registered count against the on-disk count** rather than trusting what the tool says.")"
    fi
  fi

  B=$(git -C "$T" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  if [ -z "$B" ] || [ "$B" = "HEAD" ]; then
    B=$(git -C "$REPO" worktree list --porcelain 2>/dev/null \
        | awk -v n="$NAME" '/^worktree /{w=$2} /^branch /{if (w ~ ("<your-worktree-marker>[/\\\\]" n "$")) {sub("refs/heads/","",$2); print $2}}' | head -1)
  fi
  [ -n "$B" ] || deny "$(J "WORKTREE-REMOVE: cannot read the branch name for $NAME, so this is refused fail-closed. Cleanup can wait; lost work cannot. Once you have confirmed there is no unmerged work, append '# WORKTREE-REMOVE-OK: <reason>' to the command.")"

  if git -C "$REPO" merge-base --is-ancestor "$B" origin/main 2>/dev/null; then continue; fi

  ST=$(gh pr list --repo "<your-owner>/<your-repo>" --head "$B" --state all --json state \
       --template '{{range .}}{{.state}} {{end}}' 2>/dev/null || true)
  case "$ST" in *MERGED*) continue ;; esac

  AHEAD=$(git -C "$REPO" rev-list --count "origin/main..$B" 2>/dev/null || echo "?")
  deny "$(J "WORKTREE-REMOVE: branch $B of $NAME carries work that is not in main ($AHEAD commit(s)), and it has no MERGED PR.

The test is NOT 'does it have a PR' and NOT 'how long since it moved' — **a planning or architecture wave has no PR by construction**, so absence of one has zero discriminating power. Measured cost: two waves that had not yet reached dev were deleted on exactly that reasoning (no work was lost; the branches survived and were restored).

There is only one safe test: **is this branch's content already in main?** This gate checked both legs:
  · git merge-base --is-ancestor $B origin/main  -> no
  · gh pr list --head $B --state all             -> ${ST:-no PR}

Three ways out:
  1. this wave really should be closed ⇒ deal with the BRANCH first (merge it, or abandon it explicitly and delete it), then remove the worktree;
  2. you only want the disk space ⇒ you do not need to delete a tree that has content. What IS safe to delete is UNREGISTERED physical residue, which the worktree-count-guard names in its ORPHAN-RESIDUE layer;
  3. you have checked each one and there is no unmerged work ⇒ append '# WORKTREE-REMOVE-OK: <reason, 8+ chars>' to the command.")"
done
exit 0
