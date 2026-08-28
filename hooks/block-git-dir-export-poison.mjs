
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { autoLogOnDeny } from './lib/log-denial.mjs';
autoLogOnDeny('block-git-dir-export-poison');

const SELFTEST = process.argv.includes('--self-test');
const IS_ENTRYPOINT = (() => {
  try {
    return import.meta.url === pathToFileURL(process.argv[1] || '').href;
  } catch {
    return false;
  }
})();

const stripQuotes = (s) =>
  String(s).replace(/'[^']*'/g, "'…'").replace(/"(?:[^"\\]|\\.)*"/g, '"…"');

const EXPORT_RE =
  /(?:^|[;&|({\s])export\s+(?:[A-Z_]+=\S*\s+)*(?:GIT_DIR|GIT_WORK_TREE)\b/;

const PREFIX_RE =
  /(?:^|[;&|({\s])(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*GIT_(?:DIR|WORK_TREE)=\S*(?:\s+[A-Za-z_][A-Za-z0-9_]*=\S*)*\s+(\S+)/g;

const HATCH = /#\s*GIT-DIR-EXPORT-OK:\s*\S/;

const prefixIntoNonGit = (bare) => {
  PREFIX_RE.lastIndex = 0;
  let m;
  while ((m = PREFIX_RE.exec(bare)) !== null) {
    const word = m[1].replace(/["']/g, '');
    if (!/^(?:\S*[\\/])?git(?:\.exe)?$/.test(word)) return word;
  }
  return null;
};

export function verdict(cmd) {
  const raw = String(cmd || '');
  if (HATCH.test(raw)) return null;
  const bare = stripQuotes(raw);
  const viaPrefix = EXPORT_RE.test(bare) ? null : prefixIntoNonGit(bare);
  if (!EXPORT_RE.test(bare) && viaPrefix === null) return null;
  return (
    'BLOCKED: GIT_DIR / GIT_WORK_TREE must not be exported\n\n' +
    'Once exported, **every** bare git call in that shell — including the ones inside scripts it calls — is redirected. ' +
    'Measured: even `git -C` does not protect you (the exported GIT_DIR overrides it), so a bare `git init` / `git config` ' +
    'inside a test script wrote a foreign path into the MAIN repository config, and every git command in the main checkout returned rc=128.\n\n' +
    'Safe forms:\n' +
    '  · read-only work: `git -C <worktree> <cmd>`, exporting nothing\n' +
    '  · a script that creates a repo: `unset GIT_DIR GIT_WORK_TREE` at the top, then `git -C "$fixture" …` throughout\n\n' +
    'Genuinely safe ⇒ append `# GIT-DIR-EXPORT-OK: <reason>` to the same command and re-run. That covers: ' +
    'a sandbox reproduction inside a throwaway clone · **writing documentation or a knowledge fragment in a heredoc** ' +
    '(this gate does not parse heredoc bodies, so it will false-positive there) · **an unquoted search** ' +
    '(`grep -rn GIT_DIR=…`; quoting the pattern also works). False positives are fail-safe — add the token, do not reword.'
  );
}

function main() {
  let payload = {};
  try {
    payload = JSON.parse(readFileSync(0, 'utf8'));
  } catch {
    process.exit(0);
  }
  if ((payload.tool_name || '') !== 'Bash') process.exit(0);
  const reason = verdict((payload.tool_input || {}).command);
  if (!reason) process.exit(0);
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'deny',
        permissionDecisionReason: reason,
      },
    }),
  );
  process.exit(0);
}

if (SELFTEST) {
  let pass = 0;
  let fail = 0;
  const arm = (label, cmd, wantDeny) => {
    const got = verdict(cmd) !== null;
    if (got === wantDeny) {
      console.log(`PASS  [${label}] want=${wantDeny ? 'deny' : 'allow'}`);
      pass++;
    } else {
      console.log(`FAIL  [${label}] want=${wantDeny ? 'deny' : 'allow'} got=${got ? 'deny' : 'allow'}`);
      fail++;
    }
  };

  arm(
    'the production incident recipe, verbatim',
    'export GIT_DIR=/mnt/z/my-project/.git/worktrees/verifystate \\\n       GIT_WORK_TREE=/mnt/z/wt/verifystate\ngit status',
    true,
  );
  arm('GIT_WORK_TREE exported on its own', 'export GIT_WORK_TREE=/mnt/z/wt/x && bash t.sh', true);
  arm('export mid-command, after a cd', 'cd /tmp && export GIT_DIR=/tmp/y/.git && git init', true);
  arm('assign-then-export', 'GIT_DIR=/mnt/z/x/.git; export GIT_DIR; git log', true);
  arm('several vars on one export line, with another between them', 'export FOO=1 GIT_DIR=/mnt/x GIT_WORK_TREE=/mnt/y', true);

  arm('an ordinary git command', 'git -C Z:/wt/foo status --porcelain', false);
  arm('incidental: quoted data (grep)', "grep -rn 'export GIT_DIR=' docs/", false);
  arm('incidental: a double-quoted echo', 'echo "never export GIT_DIR=/mnt/... under WSL" >> notes.md', false);
  arm('the exemption comment', 'export GIT_DIR=/tmp/sandbox-clone/.git # GIT-DIR-EXPORT-OK: isolated sandbox must-red arm, throwaway clone', false);
  arm('env prefix -> git itself (one-shot; git consumes it)', 'GIT_DIR=/tmp/x/.git git rev-parse --git-dir', false);
  arm('an unrelated export', 'export PYTHONIOENCODING=utf-8 && python x.py', false);

  arm('env prefix -> a bash script (the poisoning shape a reviewer measured)', 'GIT_DIR=/mnt/z/my-project/.git/worktrees/x bash scripts/provision/__tests__/guard.sh', true);
  arm('env prefix -> sh, two vars', 'GIT_DIR=/tmp/x GIT_WORK_TREE=/tmp/y sh run.sh', true);
  arm('env prefix -> git at an absolute path (still git itself)', 'GIT_DIR=/tmp/x/.git /usr/bin/git log -1', false);
  arm('the env -u cleansing form (the prescribed fix; no equals sign to reach)', 'env -u GIT_DIR -u GIT_WORK_TREE git -C /tmp/f status', false);

  arm('PINNED false positive: heredoc bodies are not parsed (writing docs trips it; the way out is the token)', "cat > frag.md <<'EOF'\nGIT_DIR=/mnt/z/x/.git bash guard.sh\nEOF", true);
  arm('PINNED false positive: an unquoted search (the way out is quoting, or the token)', 'grep -rn GIT_DIR=/mnt docs/', true);

  console.log(`\nARMS  ${pass + fail} (pass ${pass} · fail ${fail})`);
  process.exit(fail === 0 ? 0 : 1);
} else if (IS_ENTRYPOINT) {
  main();
}
