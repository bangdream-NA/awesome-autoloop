#!/usr/bin/env bash

set -euo pipefail

case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":pipeline-roles:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
MODE="${1:-pre}"
KEEP="${BACKLOG_SNAPSHOT_KEEP:-40}"
SHRINK_PCT="${BACKLOG_SHRINK_DENY_PCT:-40}"

INPUT=$(cat)

CANDS=$(printf '%s' "$INPUT" | node -e '
let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
  let o={}; try{o=JSON.parse(s)}catch{ process.stdout.write(""); return }
  const ti=o.tool_input||{};
  const hay=[ti.file_path||"", ti.command||"", ti.notebook_path||"", o.cwd||""].join("\n");
  const out=new Set();
  for (const m of hay.matchAll(/[A-Za-z]:[\\\/][^\s"'"'"'`;|&)]*BACKLOG\.md|\/[^\s"'"'"'`;|&)]*BACKLOG\.md/g)) {
    out.add(m[0].replace(/\\/g,"/"));
  }
  process.stdout.write([...out].join("\n"));
});' 2>/dev/null || echo "")

REG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
REG="$REG_DIR/backlog-registry"
mkdir -p "$REG_DIR" 2>/dev/null || true

if [ -n "$CANDS" ]; then
  while IFS= read -r F; do
    [ -z "$F" ] && continue
    [ -f "$F" ] || continue
    grep -qxF "$F" "$REG" 2>/dev/null || printf '%s\n' "$F" >> "$REG"
  done <<EOF
$CANDS
EOF
fi

if [ -f "$REG" ]; then
  CANDS=$(printf '%s\n%s' "$CANDS" "$(cat "$REG" 2>/dev/null)" | sed '/^$/d' | sort -u)
fi

[ -z "$CANDS" ] && exit 0

snapdir_for() {
  printf '%s/.backlog-snapshots' "$(dirname "$1")"
}

if [ "$MODE" = "pre" ]; then
  while IFS= read -r F; do
    [ -z "$F" ] && continue
    [ -f "$F" ] || continue
    SZ=$(wc -c < "$F" 2>/dev/null || echo 0)
    [ "$SZ" -lt 100 ] && continue
    D="$(snapdir_for "$F")"
    mkdir -p "$D" 2>/dev/null || continue
    NEWEST=$(ls -1t "$D"/BACKLOG-*.md 2>/dev/null | head -1 || true)
    if [ -n "$NEWEST" ] && cmp -s "$F" "$NEWEST"; then
      continue
    fi
    cp -f "$F" "$D/BACKLOG-$(date -u +%Y%m%dT%H%M%SZ)-$$.md" 2>/dev/null || true
    ls -1t "$D"/BACKLOG-*.md 2>/dev/null | tail -n +"$((KEEP+1))" | while IFS= read -r OLD; do
      rm -f "$OLD" 2>/dev/null || true
    done
  done <<EOF
$CANDS
EOF
  exit 0
fi

RESTORED=""
while IFS= read -r F; do
  [ -z "$F" ] && continue
  D="$(snapdir_for "$F")"
  [ -d "$D" ] || continue
  NEWEST=$(ls -1t "$D"/BACKLOG-*.md 2>/dev/null | head -1 || true)
  [ -z "$NEWEST" ] && continue
  PREV=$(wc -c < "$NEWEST" 2>/dev/null || echo 0)
  [ "$PREV" -lt 100 ] && continue
  NOW=0
  [ -f "$F" ] && NOW=$(wc -c < "$F" 2>/dev/null || echo 0)
  THRESH=$(( PREV * (100 - SHRINK_PCT) / 100 ))
  if [ "$NOW" -lt "$THRESH" ]; then
    cp -f "$NEWEST" "$F" 2>/dev/null && RESTORED="$F ($NOW B -> $PREV B, from $(basename "$NEWEST"))"
  fi
done <<EOF
$CANDS
EOF

if [ -n "$RESTORED" ]; then
  MSG="BACKLOG CLOBBER BLOCKED + RESTORED: $RESTORED. The write left the board empty or drastically shorter, so the pre-write snapshot was put back. Re-check what your last command did before re-running it -- the classic cause is open(path,'w') truncating the file and then failing inside write() (e.g. a UnicodeEncodeError), which destroys the old content without producing new content. Write to a temp file and os.replace() instead."
  printf '{"systemMessage":%s}\n' "$(printf '%s' "$MSG" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>process.stdout.write(JSON.stringify(s)))')"
fi
exit 0
