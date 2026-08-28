#!/usr/bin/env bash
# protect-backlog — the board is the one file where a bad write costs history rather than a rerun.
# This is not a gate: it snapshots before the write and, if the file came back drastically shorter,
# puts the snapshot back. The arms below check the FILESYSTEM, because that is where its whole effect
# lands — a version that did nothing at all prints exactly what a working one prints.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR/protect-backlog.sh"

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
mkdir -p "$AAL_TMP/proj/.claude" "$AAL_TMP/config"
: > "$AAL_TMP/proj/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
export CLAUDE_PROJECT_DIR="$AAL_TMP_N/proj"
# 🔴 The registry of known boards lives under the configuration directory. Left at its default this
# fixture would append a temp path to the operator's own state file on every run, and those entries
# never expire — the tool would then keep snapshotting directories that had stopped existing.
export CLAUDE_CONFIG_DIR="$AAL_TMP_N/config"
trap 'rm -rf "$AAL_TMP"' EXIT

BOARD="$AAL_TMP/proj/.claude/BACKLOG.md"
BOARD_N="$AAL_TMP_N/proj/.claude/BACKLOG.md"
SNAPDIR="$AAL_TMP/proj/.claude/.backlog-snapshots"

# A board with enough bytes to be worth protecting: anything under a hundred is skipped, so a
# two-line fixture board would pass every arm while measuring nothing. The card header is assembled
# from parts, as everywhere else here, so this source does not read as a board to an installation.
big_board() {
  node -e 'const fs=require("fs");const H="#".repeat(3);let s="# Backlog\n\n";for(let i=0;i<40;i++){s+=H+" ["+"QUEUED] R-card-"+i+"\n"+"- "+"log: 2026-08-01T00:00:00Z · queued\n";}fs.writeFileSync(process.argv[1],s);' -- "$1"
}
size_of() { wc -c < "$1" | tr -d ' '; }
payload() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:process.argv[1],content:"x"}}))' -- "$1"; }
# -----------------------------------------------------------------------------------------------

big_board "$BOARD"
ORIGINAL="$(size_of "$BOARD")"

# --- the pre pass takes a snapshot -----------------------------------------------------------------
payload "$BOARD_N" | bash "$HOOK" pre >/dev/null 2>&1
if [ -d "$SNAPDIR" ] && [ "$(ls -1 "$SNAPDIR"/BACKLOG-*.md 2>/dev/null | wc -l)" -ge 1 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("PRE: no snapshot was taken for a board of $ORIGINAL bytes")
fi

# --- the post pass restores a board that came back nearly empty --------------------------------------
printf '# Backlog\n' > "$BOARD"
CLOBBERED="$(size_of "$BOARD")"
out="$(payload "$BOARD_N" | bash "$HOOK" post 2>&1)"
RESTORED="$(size_of "$BOARD")"
if [ "$RESTORED" = "$ORIGINAL" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("POST: the board was not restored ($CLOBBERED B -> $RESTORED B, expected $ORIGINAL B)")
fi
# …and it says so. A silent restore is its own trap: the next write starts from content the author
# does not know is back.
if printf '%s' "$out" | grep -q 'CLOBBER BLOCKED'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("POST: the restore printed no message (got: $(printf '%s' "$out" | head -c 120))")
fi

# --- a modest edit is left alone -----------------------------------------------------------------------
# The arm that carries the whole design: a tool that restored on ANY shrink would undo every archive
# cut, which is the routine operation that legitimately makes the board smaller.
payload "$BOARD_N" | bash "$HOOK" pre >/dev/null 2>&1
node -e 'const fs=require("fs");const p=process.argv[1];const s=fs.readFileSync(p,"utf8");fs.writeFileSync(p, s.slice(0, Math.floor(s.length*0.8)));' -- "$BOARD"
TRIMMED="$(size_of "$BOARD")"
payload "$BOARD_N" | bash "$HOOK" post >/dev/null 2>&1
AFTER="$(size_of "$BOARD")"
if [ "$AFTER" = "$TRIMMED" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("POST: a 20% trim was reverted ($TRIMMED B -> $AFTER B) — routine archiving would be undone")
fi

# --- a board that never grew past the floor is ignored ---------------------------------------------------
TINY="$AAL_TMP/proj/tiny/.claude"
mkdir -p "$TINY"
printf '# Backlog\n' > "$TINY/BACKLOG.md"
payload "$AAL_TMP_N/proj/tiny/.claude/BACKLOG.md" | bash "$HOOK" pre >/dev/null 2>&1
if [ ! -d "$TINY/.backlog-snapshots" ] || [ "$(ls -1 "$TINY/.backlog-snapshots"/BACKLOG-*.md 2>/dev/null | wc -l)" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("PRE: a board under the size floor was snapshotted anyway")
fi

# --- the state it keeps lands where it was pointed ------------------------------------------------------------
if [ -s "$AAL_TMP/config/hooks/.state/backlog-registry" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("REGISTRY: nothing was written to the sandbox registry, so the seam is not being honoured")
fi

# --- payloads that name no board are a no-op ------------------------------------------------------------------
out="$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"git status"}}))' | bash "$HOOK" post 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1)); FAILURES+=("NO-BOARD: rc=$rc out='$(printf '%s' "$out" | head -c 100)'")
fi

summary
