#!/usr/bin/env bash
# posix-path-predicates — a gate that only recognises `X:/…` is dead on Linux and macOS, and its
# death is SILENT: it exits 0, says nothing, and reads exactly like a gate that decided not to fire.
# An adopter would never learn that half the kit stopped judging anything.
#
# Two kinds of arm, because neither is sufficient alone:
#   1. per-predicate, feeding the actual regex three inputs — a POSIX path (must match), a Windows
#      path (must STILL match) and a non-path (must NOT match). The third is the load-bearing one:
#      widening a matcher fails by over-matching, and a must-red arm is structurally blind to that.
#   2. a census over the shipped tree — no drive-letter anchor may ship without a POSIX alternative
#      on the same line — so a predicate added later cannot reintroduce the blindness unnoticed.
#
# Windows paths are written with a synthetic `Z:` throughout: a real drive letter in a fixture is
# the author's machine leaking into a public artifact, which bin/sanitize-check.sh fails the tree
# for. `Z:` exists nowhere and every arm here is textual, so nothing is resolved on disk.
source "$(dirname "$0")/_lib.sh"
HOOKS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 🔴 Git Bash rewrites any argument that LOOKS like a POSIX absolute path into a Windows one before
# a native binary sees it: `/work/proj` reaches node as `C:/Program Files/Git/work/proj`. Every arm
# below would then be testing a drive-letter string while claiming to test a POSIX one — and it
# fails in the reassuring direction, because the mangled value still matches the unfixed predicate.
# Both variables are no-ops outside Git Bash.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

AAL_TMP="$(mktemp -d)"
trap 'rm -rf "$AAL_TMP"' EXIT
AAL_TMP_N="$(aal_native "$AAL_TMP")"
# Every path handed to node goes in NATIVE spelling: with argument conversion switched off above,
# Git Bash spells this repo with a one-letter first segment, which node resolves against the current
# drive root instead of the drive that segment names, so every path handed to it would be missing.
HOOKS_DIR_N="$(aal_native "$HOOKS_DIR")"

WIN_DRIVE='Z:'

# --- 1. per-predicate: the regex itself, pulled out of the source it ships in --------------------
# The regex is located by an ANCHOR — a literal fragment of the line it lives on — and never by a
# line number, which every edit above it invalidates. An anchor that matches nothing, or matches
# twice, is a harness failure and not a pass: `no regex found` and `the regex accepted everything`
# produce the same green otherwise.
cat > "$AAL_TMP/probe.mjs" <<'PROBE'
import { readFileSync } from 'node:fs';
const [file, anchor, yes, no] = process.argv.slice(2);
let lines;
try { lines = readFileSync(file, 'utf8').split(/\r?\n/); }
catch (e) { console.log('CANNOT READ: ' + e.message); process.exit(0); }
const hits = lines.filter((l) => l.includes(anchor));
if (hits.length === 0) { console.log('ANCHOR NOT FOUND — the predicate moved or was renamed'); process.exit(0); }
if (hits.length > 1)   { console.log('ANCHOR AMBIGUOUS — ' + hits.length + ' lines carry it'); process.exit(0); }
const m = hits[0].match(/\/((?:\\.|\[(?:\\.|[^\]])*\]|[^/\\\n])+)\/([gimsuy]*)/);
if (!m) { console.log('NO REGEX LITERAL on the anchored line: ' + hits[0].trim().slice(0, 120)); process.exit(0); }
let re;
try { re = new RegExp(m[1], m[2].replace(/[gy]/g, '')); }
catch (e) { console.log('REGEX DID NOT COMPILE: ' + e.message); process.exit(0); }
if (!re.test(yes)) { console.log('DOES NOT MATCH the POSIX input ' + JSON.stringify(yes) + ' — ' + re); process.exit(0); }
if (no && re.test(no)) { console.log('OVER-MATCHES ' + JSON.stringify(no) + ' — ' + re); process.exit(0); }
console.log('OK');
PROBE

probe() { # $1 = desc, $2 = file, $3 = anchor, $4 = must-match, $5 = must-NOT-match
  local desc="$1" file="$2" anchor="$3" yes="$4" no="$5" out
  out="$(node "$AAL_TMP_N/probe.mjs" "$HOOKS_DIR_N/$file" "$anchor" "$yes" "$no" 2>&1)"
  case "$out" in
    OK) PASS=$((PASS+1)) ;;
    *)  FAIL=$((FAIL+1)); FAILURES+=("$desc [$file]: $(printf '%s' "$out" | head -c 200)") ;;
  esac
}

# normalizeRepo is the front door: every gate that asks "which project is this?" goes through it,
# and a null here makes the gate no-op.
probe "normalizeRepo accepts a POSIX repo" \
  lib/is-autoloop-lead.mjs '.test(clean)) return null' '/work/proj' 'proj/sub'
probe "the known-projects filter accepts one too" \
  lib/is-autoloop-lead.mjs 'cur = cur.filter' '/work/proj' 'proj/sub'

# The board named in a dispatch brief is how two separate gates find the project's ledger.
probe "premise-target reads a POSIX board path" \
  lib/premise-target.mjs 'const bm = String(ti.prompt' '/work/proj/.claude/BACKLOG.md' 'proj/.claude/NOTES.md'
probe "backlog-sop-validate reads one as well" \
  backlog-sop-validate.mjs 'const bm = String(prompt)' '/work/proj/.claude/BACKLOG.md' 'proj/.claude/NOTES.md'

# Which project a roster member belongs to is decided by the absolute paths in its brief.
probe "roster member paths can be POSIX" \
  lib/roster-live-agents.mjs 'const ABS_PATH_RE' '/work/wt/r-widget' 'and/or'
probe "…and so can a member-of-type path" \
  lib/roster-members-of-type.mjs 'const ABS_PATH ' '/work/wt/r-widget' 'and/or'

# The dispatch limb of the same drift lock finds the board in the brief, and it was the one path
# predicate this census did not cover — which is why it stayed red on ubuntu and macOS after the
# rest of the sweep went green. The must-NOT-match input is a URL rather than a relative path: this
# widening turns every slash into a possible path start, so a documentation link is the shape that
# gets caught, and a link is not a board.
probe "the dispatch gate reads a POSIX board path" \
  block-autoloop-on-board-drift.mjs 'prompt.matchAll' \
  '/work/proj/.claude/BACKLOG.md' 'https://example.invalid/repo/.claude/BACKLOG.md'

# The merge limb: a `cd <repo> && gh pr merge` whose repo is POSIX must still resolve.
probe "the merge command's repo may be POSIX" \
  stop-node-dispatcher.mjs 'const m = cmdVal.match' 'cd /work/proj && gh pr merge 12' 'cd here && gh pr merge 12'

# The board-drift gate parses the same `cd <repo>` shape out of a merge command, in sed rather than
# in node — a different language, the same blindness. Its own expression is lifted out of the file
# and run, so the arm judges the shipped parser rather than a copy of it that could drift.
#
# 🔴 The INTERPRETER FLAGS are lifted with the expression, off the same physical line. Lifting the
# expression alone makes this arm flag-blind: the gate's `\|` alternation is a GNU extension to BRE
# that BSD sed reads as a literal, and the fix is `-E`. With a hard-coded `sed -n` here, that fix
# would run a BRE interpreter over an ERE pattern and the arm would go red for a reason that is not
# the gate's — a correct fix scored as a regression.
DRIFT_ANCHOR="sed -n[A-Za-z]* 's#\^cd [^#]*#[^#]*#p'"
DRIFT_N="$(grep -cE "$DRIFT_ANCHOR" "$HOOKS_DIR/block-merge-on-board-drift.sh")"
DRIFT_CMD="$(grep -oE "$DRIFT_ANCHOR" "$HOOKS_DIR/block-merge-on-board-drift.sh")"
if [ "$DRIFT_N" != "1" ]; then
  FAIL=$((FAIL+1)); FAILURES+=("BOARD-DRIFT-ANCHOR: the cd-parser is not uniquely locatable in block-merge-on-board-drift.sh (matching lines: $DRIFT_N)")
else
  DRIFT_FLAGS="${DRIFT_CMD%% \'*}"
  DRIFT_EXPR="${DRIFT_CMD#* \'}"; DRIFT_EXPR="${DRIFT_EXPR%\'}"
  out="$(printf 'cd /work/proj && gh pr merge 12 --squash\n' | $DRIFT_FLAGS "$DRIFT_EXPR")"
  if [ "$out" = "/work/proj" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("BOARD-DRIFT-POSIX: a POSIX repo in the merge command did not parse (got: '$out', via '$DRIFT_FLAGS')"); fi
  out="$(printf 'cd %s/work/proj && gh pr merge 12 --squash\n' "$WIN_DRIVE" | $DRIFT_FLAGS "$DRIFT_EXPR")"
  if [ "$out" = "$WIN_DRIVE/work/proj" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("BOARD-DRIFT-WINDOWS: the drive-letter form REGRESSED (got: '$out', via '$DRIFT_FLAGS')"); fi
  out="$(printf 'echo not a cd at all\n' | $DRIFT_FLAGS "$DRIFT_EXPR")"
  if [ -z "$out" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILURES+=("BOARD-DRIFT-OVER: a line that is not a cd was parsed as a repo (got: '$out')"); fi
fi

# The same gate then NORMALISES a Git-Bash drive spelling (`/c/proj` -> `C:/proj`). One character in
# the first segment is a convention, not a guarantee: `/w/proj` is a legal POSIX repository, and
# rewriting it to `W:/proj` puts the gate back in the silence the arms above just removed. Two
# properties are read out of the shipped file, because no behavioural arm can reach them — the
# discriminating input would be a REAL directory whose first path segment is one character, and a
# fixture cannot create one (it would have to mkdir at the filesystem root).
DRIFT_SRC="$(cat "$HOOKS_DIR/block-merge-on-board-drift.sh")"
if printf '%s' "$DRIFT_SRC" | grep -qE 'if \[ -d "\$WINDIR" \]; then DIR="\$WINDIR"; fi'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("BOARD-DRIFT-DRIVE-UNCONDITIONAL: the /x/ -> X:/ rewrite is not gated on the drive form being a real directory, so a POSIX /w/proj resolves to W:/proj"); fi
if printf '%s' "$DRIFT_SRC" | grep -q 'U\\1'; then
  FAIL=$((FAIL+1)); FAILURES+=("BOARD-DRIFT-GNU-UPPER: sed's GNU-only \\U survives in the drive normalisation; BSD sed emits a literal U")
else PASS=$((PASS+1)); fi

# --- 2. per-predicate, behaviourally: the gates that can be driven end to end --------------------
# script-mediated-hook-writes decides whether a Bash command writes a hook by matching the path in
# the command text. CLAUDE_CONFIG_DIR is the module's own documented seam for where `.claude` lives.
# The driver lives in the sandbox, so a relative import would resolve against the sandbox. It is
# given a `file://` URL built from the real hooks directory instead — and Git Bash spells that
# directory `/c/…`, which node cannot open, so the drive letter is put back first.
printf 'import { hookFilesWrittenBy } from %s;\nprocess.stdout.write(hookFilesWrittenBy({ tool_name: "Bash", tool_input: { command: process.argv[2] } }).join(" "));\n' \
  "\"file:///$(printf '%s' "$HOOKS_DIR/lib/script-mediated-hook-writes.mjs" | sed 's#^/\([a-zA-Z]\)/#\1:/#')\"" \
  > "$AAL_TMP/smhw.mjs"

smhw() { # $1 = CLAUDE_CONFIG_DIR, $2 = command string  -> prints the hook paths it found
  CLAUDE_CONFIG_DIR="$1" node "$AAL_TMP_N/smhw.mjs" "$2" 2>&1
}
out="$(smhw '/work/home/.claude' 'printf x > "/work/home/.claude/hooks/gate.mjs"')"
if printf '%s' "$out" | grep -q '/work/home/.claude/hooks/gate.mjs'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("SMHW-REDIRECT: a POSIX redirect into .claude/hooks was not seen (got: $(printf '%s' "$out" | head -c 200))"); fi
out="$(smhw '/work/home/.claude' 'tee -a "/work/home/.claude/hooks/gate.sh"')"
if printf '%s' "$out" | grep -q '/work/home/.claude/hooks/gate.sh'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("SMHW-TEE: a POSIX tee into .claude/hooks was not seen (got: $(printf '%s' "$out" | head -c 200))"); fi
# The load-bearing arm: widening must not make it claim a write it cannot see.
out="$(smhw '/work/home/.claude' 'printf x > "/work/home/notes/gate.mjs"')"
if [ -z "$out" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("SMHW-OVER: a write OUTSIDE .claude was reported as a hook write (got: $(printf '%s' "$out" | head -c 200))"); fi
out="$(smhw "$WIN_DRIVE/home/.claude" "printf x > \"$WIN_DRIVE/home/.claude/hooks/gate.mjs\"")"
if printf '%s' "$out" | grep -q "$WIN_DRIVE/home/.claude/hooks/gate.mjs"; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("SMHW-WINDOWS: the drive-letter form REGRESSED (got: $(printf '%s' "$out" | head -c 200))"); fi

# require-knowledge-ref-in-dispatch demands the brief name a worktree by absolute path. On a POSIX
# host every correct brief would be denied, and the denial text would tell the operator to write the
# very path it just refused.
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$HOOKS_DIR_N/require-knowledge-ref-in-dispatch.mjs"
KB='Read the knowledge base under ~/.claude/knowledge/developer/ before you start.'
a() { node -e 'process.stdout.write(JSON.stringify({tool_name:"Agent",tool_input:{subagent_type:"developer",name:"dev-widget",prompt:process.argv[1]}}))' -- "$1"; }
assert_allow "a POSIX worktree brief is accepted" \
  "$(a "Worktree — work ONLY here: /work/wt/r-widget on branch feat/r-widget. Drive git with git -C /work/wt/r-widget. $KB")"
assert_allow "the drive-letter form still is" \
  "$(a "Worktree — work ONLY here: $WIN_DRIVE/wt/r-widget on branch feat/r-widget. Drive git with git -C $WIN_DRIVE/wt/r-widget. $KB")"
# Load-bearing: accepting POSIX paths must not turn "no path at all" into a pass.
assert_deny "a brief with no path at all" \
  "$(a "Implement the venue rendering. $KB")" 'has to NAME THE WORKTREE'
assert_deny "…and a relative path is not an absolute one" \
  "$(a "Worktree — work ONLY here: wt/r-widget. $KB")" 'has to NAME THE WORKTREE'
# Briefs write paths in backticks, so the POSIX branch has to start after one. The load-bearing
# neighbour is the arm above it: `~/.claude/knowledge/…` is in EVERY correct brief and must never
# count as the worktree the operator was told to name.
assert_allow "a POSIX worktree path inside backticks" \
  "$(a "Worktree — work ONLY here: \`/work/wt/r-widget\` on branch feat/r-widget. $KB")"

# --- 3. census: nothing may ship a drive-letter anchor without a POSIX alternative ---------------
# Per-predicate arms only cover the predicates somebody thought to list. This one covers the tree.
cat > "$AAL_TMP/census.mjs" <<'CENSUS'
import { readFileSync, readdirSync, statSync } from 'node:fs';
const root = process.argv[2];
// A line is BLIND when it anchors on a drive letter and offers no POSIX branch. The alternative is
// recognised by SHAPE — the literal spellings this kit uses — not by a comment claiming one exists.
const DRIVE = /\[[Aa]-[Zz]a?-?z?\]\s*:|\[A-Z\]:/;
const POSIX_ALT = [
  '|/',      // an alternative branch rooted at /
  '|\\/',    // …escaped, inside a regex literal
  '|^\\/',   // …anchored, as in /^[a-zA-Z]:|^\//
  '|[\\\\/]', // …as a character class, as in log-denial's path stripper
  '|(?<!',   // …guarded by a lookbehind so it cannot start mid-token
  '|(?:^',   // …guarded by a start-of-token alternation
  ':)?',     // the drive letter made OPTIONAL, as in block-wildcard-delete
  '/*|',     // a shell `case` arm listing /* before the drive arm
];
const files = [];
(function walk(p) {
  const st = statSync(p);
  if (st.isDirectory()) {
    if (/[\\/](tests|node_modules|\.state)$/.test(p)) return;
    for (const e of readdirSync(p).sort()) walk(p + '/' + e);
  } else if (/\.(mjs|sh)$/.test(p)) files.push(p);
})(root);
const blind = [];
for (const f of files) {
  const lines = readFileSync(f, 'utf8').split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    if (!DRIVE.test(lines[i])) continue;
    if (POSIX_ALT.some((s) => lines[i].includes(s))) continue;
    blind.push(f.slice(root.length + 1) + ':' + (i + 1));
  }
}
process.stdout.write(blind.join('\n'));
CENSUS
CENSUS_N="$AAL_TMP_N/census.mjs"
blind="$(node "$CENSUS_N" "$HOOKS_DIR_N" 2>&1)"
if [ -z "$blind" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("CENSUS: drive-letter anchor with no POSIX alternative at: $(printf '%s' "$blind" | tr '\n' ' ')"); fi
# 🔴 The census's own control. A scan that reaches nothing prints an empty list, which is
# byte-identical to a clean tree — so a planted blind line must come back.
PLANT="$AAL_TMP/plant"
mkdir -p "$PLANT"
PLANT_N="$(aal_native "$PLANT")"
printf '%s\n' 'const X = /^[A-Za-z]:\/only-windows$/;' > "$PLANT/planted.mjs"
control="$(node "$CENSUS_N" "$PLANT_N" 2>&1)"
if printf '%s' "$control" | grep -q 'planted.mjs:1'; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("CENSUS-CONTROL: a planted drive-only predicate was NOT flagged — the census reaches nothing (got: '$control')"); fi
# …and the other half of the control: a line that DOES carry a POSIX branch must stay unflagged,
# or the census would be satisfied by flagging everything.
printf '%s\n' 'const Y = /^(?:[A-Za-z]:\/|\/)both$/;' > "$PLANT/planted.mjs"
control="$(node "$CENSUS_N" "$PLANT_N" 2>&1)"
if [ -z "$control" ]; then PASS=$((PASS+1))
else FAIL=$((FAIL+1)); FAILURES+=("CENSUS-CONTROL-GREEN: a line WITH a POSIX branch was flagged anyway (got: '$control')"); fi

summary
