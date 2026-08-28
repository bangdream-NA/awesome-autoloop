#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('require-mobile-desktop-pair-in-browser-walk');

const deny = (reason) => {
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'deny', permissionDecisionReason: reason },
  }));
  process.exit(0);
};
const allow = () => process.exit(0);

let stdin;
try { stdin = JSON.parse(readFileSync(0, 'utf8') || '{}'); } catch { allow(); }

const tool = String(stdin.tool_name || '');
const input = stdin.tool_input || {};

if (/browser_resize$/.test(tool)) {
  const w = Number(input.width || 0);
  if (w > 0 && w <= 500) {
    deny([
      '`browser_resize` to a phone width gives you a NARROW DESKTOP, not a mobile device.',
      'The UA is still desktop · `maxTouchPoints` is still 0 · `(pointer: coarse)` / `(hover: none)` do not match · the desktop scrollbar still takes layout.',
      '',
      'Use `browser_run_code_unsafe` instead: open a CDP session on the already-headed page and do **Mobile AND Desktop in the same call**, sending all five on the Mobile leg:',
      '  `setUserAgentOverride` (the UA string AND `userAgentMetadata.mobile` — both halves)',
      '  `setTouchEmulationEnabled`({enabled:true, maxTouchPoints:5})',
      '  `setEmulatedMedia`(pointer/any-pointer=coarse, hover/any-hover=none)',
      '  `setScrollbarsHidden` ({hidden:true})  <- without it the desktop scrollbar eats 15 CSS px, so a "390 wide" walk is really 375',
      '  `setDeviceMetricsOverride`({width:390, height:844, deviceScaleFactor:3, mobile:true})',
      'Then **reload**, and use ONE `evaluate` to return the emulation read-back together with the number under test (including `innerWidth - documentElement.clientWidth`; anything non-zero voids the observation).',
      'Full recipe -> `rules/common/pipeline-discipline.md` §3.',
    ].join('\n'));
  }
  allow();
}

if (!/browser_run_code_unsafe$/.test(tool)) allow();

const code = String(input.code || '') + '\n' + String(input.filename || '');

if (!/setDeviceMetricsOverride/.test(code)) allow();

let widths = [...code.matchAll(/\bwidth\s*:\s*(\d{2,4})/g)].map((m) => Number(m[1]));
let readVia = 'width: literal';
if (!widths.length) {
  widths = [...code.matchAll(/\b(\d{3,4})\b/g)].map((m) => Number(m[1]))
    .filter((n) => (n >= 300 && n <= 500) || (n >= 1024 && n <= 3840));
  readVia = 'bare numerals (parameterised call)';
}
const hasMobile = widths.some((w) => w > 0 && w <= 500);
const hasDesktop = widths.some((w) => w >= 1024);
const hasScrollbarFix = /setScrollbarsHidden/.test(code);

const missing = [];
if (!hasMobile) missing.push('the **Mobile** leg (`setDeviceMetricsOverride` with `width` <= 500, e.g. 390x844 or 375x812)');
if (!hasDesktop) missing.push('the **Desktop** leg (`width` >= 1024, e.g. 1280x900)');
if (hasMobile && !hasScrollbarFix) missing.push('**`setScrollbarsHidden({hidden:true})`** — the Mobile leg must carry it');

if (!missing.length) allow();

deny([
  'A browser walk can only take this shape: **Mobile and Desktop, one leg each, in the SAME call**.',
  '',
  'This call is missing:',
  ...missing.map((m) => '  ✗ ' + m),
  `  (widths read: ${widths.length ? widths.join(', ') : 'none'} · via: ${readVia})`,
  '',
  '**Leaving out `setScrollbarsHidden` does not make the walk "less rigorous", it MANUFACTURES PHANTOM DEFECTS.** The other four axes change what the PAGE sees; the scrollbar is drawn by the HOST platform. Measured, two legs of one call: `innerWidth - documentElement.clientWidth` went 15 -> 0, so a walk claiming 390 had a 375-wide content area, the top bar was clipped by the browser chrome, and that was reported upward as a mobile defect. It also INVERTS the swipe-affordance judgement — a horizontal scroller showing the edge of the next item is the required affordance, not a bug.',
  '',
  'The correct shape (one call, two legs, each with its own reload and its own read-back):',
  '  const emulate = async (m) => { await cdp.send("Emulation.setUserAgentOverride", …);',
  '    await cdp.send("Emulation.setTouchEmulationEnabled", …); await cdp.send("Emulation.setEmulatedMedia", …);',
  '    await cdp.send("Emulation.setScrollbarsHidden", { hidden: true });',
  '    await cdp.send("Emulation.setDeviceMetricsOverride", m ? {width:390,height:844,deviceScaleFactor:3,mobile:true}',
  '                                                           : {width:1280,height:900,deviceScaleFactor:1,mobile:false}); };',
  '  // mobile leg -> reload -> screenshot + evaluate;  desktop leg -> reload -> screenshot + evaluate',
  '',
  'Every leg has to print `innerWidth - documentElement.clientWidth` in its evidence; **non-zero voids that observation**. Full recipe -> `rules/common/pipeline-discipline.md` §3.',
  'NOTE: a purely desktop check (an OG image, a wide admin table) ⇒ do not set `setDeviceMetricsOverride` at all in that call and this gate stays out of the way. Set a viewport and you owe both legs.',
].join('\n'));
