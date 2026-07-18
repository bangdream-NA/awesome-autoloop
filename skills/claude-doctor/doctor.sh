#!/usr/bin/env bash
# claude-doctor — harness self-check for your ~/.claude.
# Reports: settings.json validity, hook mount↔disk consistency (orphans +
# dangling mounts), node (parse-json dep) on PATH, fixture-test result, and a
# mounted-hook registry. Read-only; safe to run anytime.
#
# Run: bash "${CLAUDE_PLUGIN_ROOT}/skills/claude-doctor/doctor.sh"
set -uo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOKS_DIR="$CLAUDE_DIR/hooks"
TESTS="$HOOKS_DIR/tests/run-all.sh"
TMPD="${TMPDIR:-/tmp}"
WARN=0; FAIL=0
say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; WARN=$((WARN+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }

say "== claude-doctor :: $CLAUDE_DIR =="

# 0. config-dir sanity — HOME mis-resolution guard. On Windows, a `bash` launched from
# PowerShell may resolve to WSL, where $HOME differs and ~/.claude is a DIFFERENT (often empty)
# dir than the Git-Bash one Claude Code actually uses → every check below would false-red.
# Detect the empty/missing config dir and point at a real one.
say ""
say "0. config dir sanity (HOME guard)"
HOOK_COUNT=$(ls "$HOOKS_DIR"/*.sh 2>/dev/null | wc -l | tr -d ' ')
if [ ! -f "$SETTINGS" ] || [ "${HOOK_COUNT:-0}" -eq 0 ]; then
  bad "config dir $CLAUDE_DIR has NO settings.json / NO hooks — likely the WRONG HOME (\$HOME=$HOME)"
  cand="$HOME/.claude"
  [ -f "$cand/settings.json" ] && say "    → real config looks like: $cand — re-run: CLAUDE_CONFIG_DIR='$cand' bash $0"
  say "    (If you launched bash from PowerShell and it resolved to WSL, use Git Bash instead, or set CLAUDE_CONFIG_DIR to your real .claude dir.)"
else
  ok "config dir $CLAUDE_DIR ($HOOK_COUNT .sh hooks present)"
fi

# 1. node on PATH (parse-json.sh dependency)
say ""
say "1. node (parse-json.sh dependency)"
if command -v node >/dev/null 2>&1; then HAVE_NODE=1; ok "node: $(node --version 2>/dev/null)"; else HAVE_NODE=0; bad "node NOT on PATH — every json_get hook is a silent no-op"; fi

# 2. settings.json valid JSON
say ""
say "2. settings.json"
if [ ! -f "$SETTINGS" ]; then bad "missing $SETTINGS";
elif [ "${HAVE_NODE:-0}" -ne 1 ]; then
  warn "node absent — cannot validate settings.json JSON (install node >=18 to enable this check)"
else
  # Pipe content via stdin (NOT a path arg): Windows node mis-reads MSYS /c/... paths.
  MOUNTED=$(cat "$SETTINGS" | node -e "
    let d='';process.stdin.on('data',c=>d+=c);process.stdin.on('end',()=>{
    try{const o=JSON.parse(d);
      const cmds=[]; for(const ev of Object.keys(o.hooks||{})){for(const g of (o.hooks[ev]||[])){for(const h of (g.hooks||[])){if(h.command)cmds.push(h.command);}}}
      console.error('OKJSON deny='+((o.permissions&&o.permissions.deny||[]).length)+' allow='+((o.permissions&&o.permissions.allow||[]).length)+' events='+Object.keys(o.hooks||{}).join(','));
      console.log(cmds.join('\n'));
    }catch(e){console.error('BADJSON '+e.message);process.exit(3);}
    });
  " 2>"$TMPD/aal-doctor-meta")
  META=$(cat "$TMPD/aal-doctor-meta" 2>/dev/null)
  case "$META" in
    OKJSON*) ok "valid JSON (${META#OKJSON })" ;;
    *) bad "invalid JSON: ${META#BADJSON } — a broken settings.json disables ALL settings" ;;
  esac
fi

# 3. Mounted hooks → script exists?
say ""
say "3. Mounted hook commands → script on disk"
if [ -n "${MOUNTED:-}" ]; then
  while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    # match bash/sh .sh AND node .mjs/.cjs hook scripts
    path=$(echo "$cmd" | grep -oE '[^ ]*\.(sh|mjs|cjs)' | head -1)
    rp="${path/#\~/$HOME}"
    if [ -f "$rp" ]; then ok "mounted: ${path}"; else bad "DANGLING MOUNT: '$cmd' → $rp not found"; fi
  done <<< "$MOUNTED"
fi

# 4. Orphan scripts (on disk, not mounted) — info, not failure
say ""
say "4. Hook scripts on disk NOT mounted in settings.json (orphans/utilities)"
# A check INVOKED BY stop-dispatcher.sh is mounted TRANSITIVELY: it won't appear in $MOUNTED
# (only the dispatcher does), so without this it would print 9 false `unmounted:` warns. The
# dispatcher's `# doctor-dispatched: <names>` registry comment is the source of truth.
DISPATCHED=""
DISP="$HOOKS_DIR/stop-dispatcher.sh"
if [ -f "$DISP" ] && echo "${MOUNTED:-}" | grep -q 'stop-dispatcher.sh'; then
  DISPATCHED=$(grep -m1 '^# doctor-dispatched:' "$DISP" | sed 's@^# doctor-dispatched:@@')
fi
for f in "$HOOKS_DIR"/*.sh; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  if echo "${MOUNTED:-}" | grep -q "$base"; then continue; fi
  if [ -n "$DISPATCHED" ] && echo " $DISPATCHED " | grep -q " ${base%.sh} "; then
    ok "dispatched: hooks/$base (via stop-dispatcher)"; continue
  fi
  warn "unmounted: hooks/$base"
done

# 5. Fixture tests
say ""
say "5. Hook fixture tests (run-all.sh)"
if [ -f "$TESTS" ]; then
  if bash "$TESTS" >"$TMPD/aal-doctor-tests" 2>&1; then ok "$(grep -E '^RESULT:' "$TMPD/aal-doctor-tests" || echo 'all passed')"; else bad "$(grep -E '^RESULT:' "$TMPD/aal-doctor-tests" || echo 'FAILED'); see $TMPD/aal-doctor-tests"; fi
else warn "no $TESTS"; fi

# Summary
say ""
say "== summary: $FAIL fail, $WARN warn =="
[ "$FAIL" -eq 0 ]
