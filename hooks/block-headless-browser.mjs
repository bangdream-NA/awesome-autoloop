#!/usr/bin/env node
import { readFileSync } from "node:fs";
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-headless-browser');

function read(fd) { try { return readFileSync(fd, "utf8"); } catch { return ""; } }
let payload = {};
try { payload = JSON.parse(read(0) || "{}"); } catch { process.exit(0); }

const tool = String(payload.tool_name || "");
const ti = payload.tool_input || {};
let text = "";
if (tool === "Bash") text = String(ti.command || "");
else if (tool === "Write") text = String(ti.content || "");
else if (tool === "Edit" || tool === "MultiEdit") text = String(ti.new_string || "") + "\n" + JSON.stringify(ti.edits || "");
else process.exit(0);
if (!text.trim()) process.exit(0);

if (/#\s*HEADLESS-OK:/i.test(text)) process.exit(0);

const LAUNCHES = /(chromium|firefox|webkit|puppeteer|playwright)[\s\S]{0,80}?\.launch\s*\(|\.launch\s*\(\s*\{|browser_type\.launch|(?:^|[\n;&|(]\s*|\bnpx\s+|\bpnpm\s+(?:exec\s+)?|\byarn\s+)playwright\s+test\b|npx\s+playwright/i;
if (!LAUNCHES.test(text)) process.exit(0);

const HEADED_OK = /headless\s*:\s*false|--headed\b|PWDEBUG\s*=\s*1|headless\s*:\s*['"]?new['"]?\s*,?\s*\/\/\s*HEADED/i;
const EXPLICIT_HEADLESS = /headless\s*:\s*true|--headless\b/i;
if (HEADED_OK.test(text) && !EXPLICIT_HEADLESS.test(text)) process.exit(0);

const why = EXPLICIT_HEADLESS.test(text)
  ? "this launches the browser with headless explicitly TRUE"
  : "this calls .launch() without `headless: false` — headless is the DEFAULT in Playwright/Puppeteer, so it would run headless silently";

const reason =
  `BLOCKED: NO-HEADLESS GATE: ${why}. ` +
  `A headless browser renders differently from what the USER sees, so a headless walk can produce a ` +
  `confident WRONG verdict — on 2026-07-28 a headless goods walk showed blank thumbnails and the lead ` +
  `wrote it off as "a headless artifact, production is fine"; the headed re-run showed the SAME blank ` +
  `images and the images really were broken live. Fix: launch HEADED — ` +
  "`chromium.launch({ headless: false })`" + ` (or \`--headed\` / \`PWDEBUG=1\`). If a context genuinely ` +
  `has no display and headless is unavoidable, make it explicit and reviewable by adding ` +
  "`# HEADLESS-OK: <reason>`" + ` to the command — never let it be the silent default.`;

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));
process.exit(0);
