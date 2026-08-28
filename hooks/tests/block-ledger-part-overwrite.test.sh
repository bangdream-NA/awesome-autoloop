#!/usr/bin/env bash
# The gate only fires when the target part EXISTS on disk, so this fixture creates it rather
# than borrowing a file from whoever happens to be running the suite.
# _lib.sh is sourced for aal_pin_new_project only; the pass/fail bookkeeping below is this
# fixture's own (lowercase) and does not collide with the library's.
source "$(dirname "$0")/_lib.sh"
PARTDIR="$(mktemp -d)"
trap 'rm -rf "$PARTDIR"' EXIT
# 🔴 The part file is not enough. block-ledger-part-overwrite.sh calls aal_is_autoloop_project
# first, and outside an autoloop project it exits 0 = ALLOW — so on a fresh clone (CI, and every
# adopter) all ten must-BLOCK arms below reported want=BLOCK got=ALLOW while the gate was correct.
aal_pin_new_project "$PARTDIR" > /dev/null
PART="$PARTDIR/.claude/BACKLOG-archive-11.md"
printf 'frozen ledger part\n' > "$PART"
H="${HOOK_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)/block-ledger-part-overwrite.sh}"
pass=0; fail=0

t() {
  local desc="$1" want="$2" cmd="$3" out got
  out=$(python -c "import json,sys;print(json.dumps({'tool_input':{'command':sys.argv[1]}}))" "$cmd" | bash "$H" 2>&1)
  if printf '%s' "$out" | grep -q '"decision":"block"'; then got=BLOCK; else got=ALLOW; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  PASS [$want] $desc"
  else fail=$((fail+1)); echo "  FAIL want=$want got=$got :: $desc"; fi
}

echo "--- the 2026-07-26 false positive (fd duplication is not a write)"
t "read-only wc+tail with 2>&1"       ALLOW "cd $PARTDIR/.claude && wc -c $PART 2>&1; tail -c 400 $PART 2>&1"
t "grep with 2>&1"                    ALLOW "grep -n foo $PART 2>&1"
t "1>&2 fd dup"                       ALLOW "cat $PART 1>&2"
t ">&- close fd"                      ALLOW "wc -l $PART >&-"

echo "--- must STILL block"
t "truncating redirect"               BLOCK "echo x > $PART"
t "bash >& FILE both-streams trunc"   BLOCK "echo x >& $PART"
t "2> FILE stderr truncate"           BLOCK "somecmd 2> $PART"
t "&> FILE"                           BLOCK "somecmd &> $PART"
t "cp over part"                      BLOCK "cp foo.md $PART"
t "mv over part"                      BLOCK "mv foo.md $PART"
t "tee without -a"                    BLOCK "echo x | tee $PART"

echo "--- must stay allowed"
t "append >>"                         ALLOW "echo x >> $PART"
t "tee -a"                            ALLOW "echo x | tee -a $PART"
t "write to NEXT FREE index"          ALLOW "echo x > $PARTDIR/.claude/BACKLOG-archive-99.md"
t "arrow fn (2026-07-22 regression)"  ALLOW "node -e \"const f = (x) => x\" $PART"
t "PART-REWRITE-ACK escape hatch"     ALLOW "cp foo.md $PART  # PART-REWRITE-ACK"

echo "--- 2026-07-26 defect #2: writer must TARGET the part, not merely co-occur with it"
t "writes elsewhere, only NAMES part"  ALLOW "sed -E 's/x/y/' \$HOME/.claude/hooks/h.sh > /tmp/copy.sh; echo $PART"
t "reads part, writes elsewhere"       ALLOW "cat $PART > /tmp/other.md"
t "cp part AS SOURCE (the remedy!)"    ALLOW "cp $PART /tmp/aside.md"
t "part in a grep arg + unrelated >"   ALLOW "grep -c foo $PART; echo done > /tmp/flag"
t "tee -a part + unrelated truncate"   ALLOW "echo x | tee -a $PART > /tmp/sink"
echo "--- ...but aiming at it still blocks"
t "cp part AS DEST"                    BLOCK "cp /tmp/aside.md $PART"
t "mv part AS DEST"                    BLOCK "mv /tmp/aside.md $PART"
t "redirect to part after other write" BLOCK "echo a > /tmp/x; echo b > $PART"

echo
echo "RESULT: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
