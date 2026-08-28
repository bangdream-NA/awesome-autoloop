#!/usr/bin/env node
// posix-utility-flags — a GNU-only utility flag in a shipped .sh is a macOS failure that nothing
// reports as one. Two of them shipped as SILENT FAIL-OPEN in mounted gates (`stat -c` with no
// `stat -f` twin: the call fails, `2>/dev/null` eats it, the default wins, and the gate exits 0
// looking exactly like a clean verdict), and three fixture classes (`date -d`, `touch -d`, `sed -i`)
// made the macOS lane structurally unpassable while the local Git-Bash suite stayed green — Git Bash
// ships GNU coreutils, so it is blind to every one of them by construction.
//
// 🔴 THE LOAD-BEARING CONTROL HERE IS THE MUST-NOT-FLAG ONE. This census can only fail by
// over-flagging: a must-red arm asks "is a planted violation caught", which stays green no matter
// how many correct lines the predicate also condemns. So every class carries BOTH a planted
// violation that must be reported AND a correct line — same utility, twin on the same line — that
// must come back clean.
//
// The rule, in one sentence: a GNU-only flag may ship only if its BSD twin is on the SAME LINE.
// That is not a stylistic preference; it is the shape hooks/check-stale-agents.sh:51 already ships
// and the only shape a reader can verify without leaving the line.
//
// It is written as .test.mjs on purpose. The corpus it scans is `git ls-files '*.sh'`, so keeping
// the pattern vocabulary in a .mjs means the scanner is not inside its own subject — no
// self-exclusion, and therefore no hole where a scanner that excludes itself stops catching itself.

import { execFileSync } from 'node:child_process';
import { spawnSync } from 'node:child_process';
import { readFileSync, statSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const TESTS = dirname(fileURLToPath(import.meta.url));
const ROOT = dirname(dirname(TESTS));
const LIB = join(TESTS, '_lib.sh');

let PASS = 0;
const FAILURES = [];
const ok = () => { PASS += 1; };
const bad = (m) => { FAILURES.push(m); };

// --- the predicate ------------------------------------------------------------------------------
// Each class names the GNU-only spelling and the BSD twin that redeems it on the same line. `sed -i`
// has NO twin: GNU wants no argument and BSD requires a backup suffix, and each rejects the other's
// form, so there is no portable in-place spelling at all and the class is unconditional.
//
// `-i` counts only when what follows it is more flag letters and then whitespace. `sed -i)` — the
// spelling inside block-cd-relative-write.sh's own FIX text — is prose ABOUT the flag and can never
// be an invocation of it, so the closing paren is what separates the two without an exemption.
const CLASSES = [
  { name: 'stat -c',  gnu: /\bstat\s+(?:-[A-Za-z]+\s+)*-c\b/,               bsd: /\bstat\s+(?:-[A-Za-z]+\s+)*-f\b/ },
  { name: 'date -d',  gnu: /\bdate\s+(?:-[A-Za-z]+\s+)*(?:-d\b|--date\b)/,  bsd: /\bdate\s+(?:-[A-Za-z]+\s+)*(?:-r\b|-v)/ },
  { name: 'touch -d', gnu: /\btouch\s+(?:-[A-Za-z]+\s+)*-d\b/,              bsd: /\btouch\s+(?:-[A-Za-z]+\s+)*(?:-t\b|-r\b)/ },
  { name: 'sed -i',   gnu: /\bsed\s+(?:-[A-Za-z]+\s+)*-i[A-Za-z]*\s/,       bsd: null },
];

// A line whose first non-blank byte is `#` is a comment: it documents the flag, it never runs it.
const EXEMPT = '# PORTABLE-OK:';

function scan(text, label) {
  const out = [];
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*#/.test(line)) continue;
    if (line.includes(EXEMPT)) continue;
    for (const c of CLASSES) {
      if (!c.gnu.test(line)) continue;
      if (c.bsd && c.bsd.test(line)) continue;
      out.push(label + ':' + (i + 1) + ' [' + c.name + ']');
    }
  }
  return out;
}

// --- 1. the census over every tracked .sh --------------------------------------------------------
// `git ls-files` is the same corpus ci.yml's shellcheck step lints, so a file that ships is a file
// this sees. A working-tree walk would also sweep untracked scratch and would miss a deleted-but-
// staged file; neither is what "shipped" means.
let files = [];
try {
  files = execFileSync('git', ['-C', ROOT, 'ls-files', '*.sh'], { encoding: 'utf8' })
    .split(/\r?\n/).filter(Boolean);
} catch (e) {
  bad('CORPUS: git ls-files failed — ' + e.message);
}

// A census that reaches nothing prints an empty list, which is byte-identical to a clean tree.
if (files.length > 50) ok();
else bad('CORPUS-SIZE: only ' + files.length + ' tracked .sh reached; the scan is not covering the tree');

const violations = [];
for (const f of files) {
  let text;
  try { text = readFileSync(join(ROOT, f), 'utf8'); }
  catch (e) { bad('UNREADABLE: ' + f + ' — ' + e.message); continue; }
  violations.push(...scan(text, f));
}
if (violations.length === 0) ok();
else bad('CENSUS: GNU-only utility flag with no BSD twin on the same line at: ' + violations.join(' '));

// --- 2. controls, both directions, per class -----------------------------------------------------
// MUST-FLAG: the planted violation. Proves the predicate reaches and recognises each class.
const PLANT_BAD = {
  'stat -c':  'MT=$(stat -c %Y "$F" 2>/dev/null || echo 0)',
  'date -d':  'S="$(date -u -d \'-2 hours\' +%Y-%m-%dT%H:%M:%SZ)"',
  'touch -d': 'touch -d \'3 days ago\' "$F"',
  'sed -i':   'sed -i "s@a@b@" "$F"',
};
// MUST-NOT-FLAG: the same utility, done correctly, twin on the same line. This is the arm that
// fails when the predicate is widened past its subject, and it is why this fixture has teeth in the
// direction the class actually breaks.
const PLANT_GOOD = {
  'stat -c':  'MT=$(stat -c %Y "$F" 2>/dev/null || stat -f %m "$F" 2>/dev/null || echo 0)',
  'date -d':  'S="$(date -u -d "@$AT" +%Y 2>/dev/null || date -u -r "$AT" +%Y)"',
  'touch -d': 'touch -t 202601010000 "$F"',
  'sed -i':   'sed "s@a@b@" "$F" > "$F.tmp" && mv "$F.tmp" "$F"',
};
for (const c of CLASSES) {
  const hitBad = scan(PLANT_BAD[c.name], 'plant');
  if (hitBad.length === 1 && hitBad[0].includes('[' + c.name + ']')) ok();
  else bad('CONTROL-MUST-FLAG [' + c.name + ']: a planted violation was NOT reported (got: ' + JSON.stringify(hitBad) + ')');

  const hitGood = scan(PLANT_GOOD[c.name], 'plant');
  if (hitGood.length === 0) ok();
  else bad('CONTROL-MUST-NOT-FLAG [' + c.name + ']: a CORRECT line was condemned — the predicate over-reaches (got: ' + JSON.stringify(hitGood) + ')');
}

// The two exclusions are themselves holes if they are wider than stated, so each is pinned.
if (scan('# a comment mentioning stat -c and sed -i "x" here', 'plant').length === 0) ok();
else bad('CONTROL-COMMENT: a comment line was treated as an invocation');

// 🔴 The arm above is a payload I wrote, so it can only prove what I already believed. This one is
// fed the REAL line out of the shipped tree — the trickiest member of the class, a comment that
// names `sed -i` in order to explain why the file does NOT use it. If this census ever condemns
// that line, it is condemning the repository's own reasoning about the rule it enforces. Read from
// disk rather than pasted, so it follows the file; and the line has to still BE there, or the arm
// is vacuous rather than green.
//
// ⚠️ What this arm does NOT prove, measured rather than assumed: that line is spared by BOTH the
// comment rule AND the sed shape rule (its `-i` is followed by a backtick, not flag-letters and
// whitespace), so it cannot isolate either one. The arm ABOVE is what isolates the comment rule —
// its `stat -c` has no shape escape, so only the leading `#` can spare it. Keep both; deleting the
// synthetic one because "the real line covers it" would silently retire the only isolating arm.
{
  const src = readFileSync(join(ROOT, 'hooks/tests/sanitize-accept-patterns.test.sh'), 'utf8');
  const hits = src.split(/\r?\n/).filter((l) => /^\s*#/.test(l) && /\bsed\s+-i\b/.test(l));
  if (hits.length === 1) ok();
  else bad('CONTROL-REALCOMMENT-ANCHOR: expected exactly 1 commented `sed -i` line in sanitize-accept-patterns.test.sh, found ' + hits.length + ' — the arm below has no subject');
  if (hits.length && scan(hits[0], 'real').length === 0) ok();
  else bad('CONTROL-REALCOMMENT: the shipped comment explaining why `sed -i` is avoided was itself flagged (line: ' + JSON.stringify((hits[0] || '').trim()) + ')');
}
if (scan('MT=$(stat -c %Y "$F")   ' + EXEMPT + ' inert deny text', 'plant').length === 0) ok();
else bad('CONTROL-EXEMPTION: the ' + EXEMPT + ' token did not exempt its line');
// …and the exclusions must not be reachable by accident: a line that merely resembles them stays flagged.
if (scan('MT=$(stat -c %Y "$F")   # an ordinary comment, not the token', 'plant').length === 1) ok();
else bad('CONTROL-EXEMPTION-NARROW: an ordinary trailing comment exempted the line');
// The `sed -i)` carve-out earns its own pair, because it is a SHAPE rule rather than a token and a
// shape rule is the kind that silently swallows the real thing.
if (scan("emit_deny 'a relative write (rm/mv/cp/sed -i) after a cd'", 'plant').length === 0) ok();
else bad('CONTROL-SED-PROSE: the flag named inside a deny message was read as an invocation');
if (scan('sed -i -e "s@a@b@" "$F"', 'plant').length === 1) ok();
else bad('CONTROL-SED-REAL: a real in-place invocation with an extra flag was NOT caught');

// --- 3. the helpers actually produce a usable stamp ----------------------------------------------
// The census is textual; it cannot see a helper that returns an EMPTY string. That is the exact
// failure this wave is repairing — a fixture whose setup silently produced nothing and whose arms
// passed anyway — so the helpers are exercised for real, here, once, on whatever platform is
// running. On a BSD host these arms are what proves the fallback branch works at all.
const sh = (script) => spawnSync('bash', ['-c', script], { encoding: 'utf8', timeout: 20000 });

const stamp = sh('set -u; . "' + LIB + '"; aal_date_rel \'-2 hours\' \'+%Y-%m-%dT%H:%M:%SZ\'');
if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test((stamp.stdout || '').trim())) ok();
else bad('HELPER-DATE: aal_date_rel did not return an ISO stamp (stdout: ' + JSON.stringify((stamp.stdout || '').slice(0, 120)) + ', stderr: ' + JSON.stringify((stamp.stderr || '').slice(0, 200)) + ')');

// Direction matters as much as shape: a helper that ignores the sign returns a perfectly-formed
// stamp for the wrong instant, and every arm keyed on "older than N" would silently invert.
const back = sh('set -u; . "' + LIB + '"; aal_epoch_rel \'-2 hours\'; printf " "; date -u +%s');
const [thenS, nowS] = ((back.stdout || '').trim().split(/\s+/)).map(Number);
if (Number.isFinite(thenS) && Number.isFinite(nowS) && nowS - thenS >= 7195 && nowS - thenS <= 7205) ok();
else bad('HELPER-DIRECTION: aal_epoch_rel \'-2 hours\' is not 7200s in the past (got: ' + JSON.stringify((back.stdout || '').trim()) + ')');

const fwd = sh('set -u; . "' + LIB + '"; aal_epoch_rel \'+7 days\'; printf " "; date -u +%s');
const [futS, now2S] = ((fwd.stdout || '').trim().split(/\s+/)).map(Number);
if (Number.isFinite(futS) && Number.isFinite(now2S) && futS - now2S >= 604795 && futS - now2S <= 604805) ok();
else bad('HELPER-FORWARD: aal_epoch_rel \'+7 days\' is not 604800s ahead (got: ' + JSON.stringify((fwd.stdout || '').trim()) + ')');

// An unknown unit must fail loudly rather than return an empty string that a caller writes into a
// board — the whole class this fixture exists to close.
const badUnit = sh('set -u; . "' + LIB + '"; aal_date_rel \'-2 fortnights\' \'+%Y\'; echo "rc=$?"');
if (/rc=1/.test(badUnit.stdout || '') && /FIXTURE-SETUP-FAILED/.test(badUnit.stderr || '')) ok();
else bad('HELPER-UNKNOWN-UNIT: an unsupported unit did not fail loudly (stdout: ' + JSON.stringify((badUnit.stdout || '').trim()) + ', stderr: ' + JSON.stringify((badUnit.stderr || '').slice(0, 200)) + ')');

// aal_touch_rel end to end: the mtime it writes has to actually land, which is the half `touch -d`
// was failing silently. Read back through node's statSync, which is portable on every platform.
const td = mkdtempSync(join(tmpdir(), 'aal-putc-'));
const target = join(td, 'stamped.txt');
const touched = sh('set -u; . "' + LIB + '"; printf x > "' + target.split('\\').join('/') + '"; aal_touch_rel \'-3 days\' "' + target.split('\\').join('/') + '"');
try {
  const ageS = (Date.now() - statSync(target).mtimeMs) / 1000;
  if (ageS >= 259140 && ageS <= 259460) ok();
  else bad('HELPER-TOUCH: aal_touch_rel \'-3 days\' left an mtime ' + Math.round(ageS) + 's old, expected ~259200 (stderr: ' + JSON.stringify((touched.stderr || '').slice(0, 200)) + ')');
} catch (e) {
  bad('HELPER-TOUCH: the stamped file could not be read back — ' + e.message);
}

// --- summary -------------------------------------------------------------------------------------
const name = 'posix-utility-flags.test.mjs';
if (FAILURES.length === 0) {
  console.log('  ' + name + ': PASS (' + PASS + '/' + PASS + ')');
  process.exit(0);
}
console.log('  ' + name + ': FAIL (' + PASS + ' pass, ' + FAILURES.length + ' fail)');
for (const f of FAILURES) console.log('    - ' + f);
process.exit(1);
