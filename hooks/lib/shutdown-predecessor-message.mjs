#!/usr/bin/env node
const [dispatched, name, pred, stale] = process.argv.slice(2);

const who = name ? `\`${name}\` (${dispatched})` : dispatched;

const msg = [
  `Use once and delete: you have just dispatched ${who}, and the predecessor \`${pred}\` is still on the roster: ${stale}.`,
  `=> send each of them a real \`shutdown_request\` in THIS response (an object, not prose — prose does not clear members, and one later SendMessage revives the agent). One wave, one worktree: a leftover predecessor means a second writer inside the new baton's tree. For corpses left by a rotation, clear the roster directly instead of messaging them.`,
].join('\n');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'PostToolUse', additionalContext: msg },
}));
