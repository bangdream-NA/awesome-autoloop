#!/usr/bin/env bash
# block-truncate-existing-ledger — `>` clears a file before the first byte is written, so one
# redirect aimed at a ledger or an archive discards everything already in it. The gate denies the
# truncating forms when the target EXISTS, and leaves appends and new files alone.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-truncate-existing-ledger.sh

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ="$(mktemp -d)"
# 🔴 Two views of the same directory. This gate asks the FILESYSTEM whether the redirect target
# exists, and it asks from node — which on Windows resolves a `/tmp/...` path against the drive
# root rather than against the shell's temp dir. A fixture that hands node the shell's spelling
# gets "not found", the gate declines to fire, and every deny arm reports EXPECTED-DENY-BUT-ALLOWED
# while the gate is in fact working. `pwd -W` is a no-op elsewhere, so the fallback keeps this
# portable for adopters on Linux and macOS.
AAL_PROJ_N="$(cd "$AAL_PROJ" && pwd -W 2>/dev/null || pwd)"
mkdir -p "$AAL_PROJ/.claude/reviews"
: > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ_N"
trap 'rm -rf "$AAL_PROJ"' EXIT

# The gate's predicate is "protected NAME **and** the file is really there", so the fixture has to
# put real bytes on disk. Absolute paths only: the resolver also tries the CWD and $HOME, and a
# bare ledger name in an arm would then be answered by whatever checkout the suite is run from.
printf 'existing content\n' > "$AAL_PROJ/.claude/BACKLOG.md"
printf 'existing content\n' > "$AAL_PROJ/.claude/BACKLOG-archive-01.md"
printf 'existing content\n' > "$AAL_PROJ/.claude/autoloop-log-2026-08.md"
printf '{"pr":1}\n'         > "$AAL_PROJ/.claude/reviews/index.jsonl"
printf 'notes\n'            > "$AAL_PROJ/notes.md"
# -----------------------------------------------------------------------------------------------

p() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' -- "$1"; }

# --- DENY: a truncating redirect at something that already holds content -------------------------
assert_deny "> an existing board"        "$(p "echo hi > $AAL_PROJ_N/.claude/BACKLOG.md")"               'never discard ledger content'
assert_deny "> an existing archive"      "$(p "cat new.md > $AAL_PROJ_N/.claude/BACKLOG-archive-01.md")" 'never discard ledger content'
assert_deny "> an existing op-log"       "$(p "printf x > $AAL_PROJ_N/.claude/autoloop-log-2026-08.md")" 'never discard ledger content'
assert_deny "> the reviews index"        "$(p "echo {} > $AAL_PROJ_N/.claude/reviews/index.jsonl")"      'never discard ledger content'
assert_deny "PowerShell Out-File"        "$(p "powershell -Command \"'x' | Out-File $AAL_PROJ_N/.claude/BACKLOG.md\"")" 'never discard ledger content'
assert_deny "PowerShell Set-Content"     "$(p "powershell -Command \"Set-Content $AAL_PROJ_N/.claude/BACKLOG.md 'x'\"")" 'never discard ledger content'

# --- ALLOW: appending, which is what a ledger is for ---------------------------------------------
assert_allow ">> the board"              "$(p "echo hi >> $AAL_PROJ_N/.claude/BACKLOG.md")"
assert_allow ">> the reviews index"      "$(p "echo {} >> $AAL_PROJ_N/.claude/reviews/index.jsonl")"
assert_allow "Out-File -Append"          "$(p "powershell -Command \"'x' | Out-File -Append $AAL_PROJ_N/.claude/BACKLOG.md\"")"

# --- ALLOW: a name that is not there yet — the split recipe the denial itself prescribes ----------
assert_allow "> a NEW archive number"    "$(p "echo hi > $AAL_PROJ_N/.claude/BACKLOG-archive-02.md")"
assert_allow "> a tmp then mv"           "$(p "echo hi > $AAL_PROJ_N/.claude/BACKLOG.md.tmp && mv $AAL_PROJ_N/.claude/BACKLOG.md.tmp $AAL_PROJ_N/.claude/BACKLOG-archive-02.md")"

# --- ALLOW: an ordinary file, and reads of a protected one ---------------------------------------
assert_allow "> an unprotected file"     "$(p "echo hi > $AAL_PROJ_N/notes.md")"
assert_allow "reading the board"         "$(p "cat $AAL_PROJ_N/.claude/BACKLOG.md")"
assert_allow "a here-doc into a new file" "$(p "cat > $AAL_PROJ_N/scratch.md <<EOF")"

summary
