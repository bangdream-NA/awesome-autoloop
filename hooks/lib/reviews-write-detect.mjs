#!/usr/bin/env node
let s = '';
process.stdin.on('data', (c) => (s += c));
process.stdin.on('end', () => {
  let cmd = '';
  try { cmd = String(JSON.parse(s).tool_input?.command || ''); } catch { cmd = ''; }
  if (!cmd) { process.stdout.write(''); return; }
  cmd = cmd.replace(/<<-?[ \t]*['"]?(\w+)['"]?[ \t]*\r?\n[\s\S]*?^[ \t]*\1[ \t]*$/gm, ' ');
  cmd = cmd.replace(/'[^']*'/g, ' ').replace(/"[^"]*"/g, ' ');
  const re = /(>|>>)[ \t]*[^| \t]*\.claude\/reviews\/|tee[ \t]+[^| \t]*\.claude\/reviews\/|sed[ \t]+-i[^|]*\.claude\/reviews\/|(mv|cp)[ \t]+[^|]*[ \t][^| \t]*\.claude\/reviews\//;
  process.stdout.write(re.test(cmd) ? 'HIT' : '');
});
