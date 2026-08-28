
const REMOTE = [
  // Configure AAL_PROD_HOSTS (comma-separated) to arm these two; the shipped default is inert
  // rather than a guess, so no adopter inherits somebody else's hostname.
  ...(process.env.AAL_PROD_HOSTS || '').split(',').map((h) => h.trim()).filter(Boolean).flatMap((h) => {
    const e = h.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    return [new RegExp('(?:^|[\\n;&|(]\\s*)\\s*ssh\\s+(?:[\\w.-]+@)?' + e + '\\b'),
      new RegExp('(?:^|[\\n;&|(]\\s*)\\s*scp\\b[^\\n]*\\b' + e + '\\b')];
  }),
];

const MUTATORS = [
  { re: /\bgpasswd\s+-[ad]\b/,                      what: 'group membership (gpasswd)' },
  { re: /\busermod\b/,                              what: 'user attributes (usermod)' },
  { re: /\binstall\s+-m\b/,                         what: 'a file installed into a system path (install -m)' },
  { re: /(?:>{1,2}\s*|tee\s+(?:-a\s+)?)\/etc\/sudoers|\b(?:install|cp|mv|rm)\b[^|]*\/etc\/sudoers|\bvisudo\b(?![^|;&]*\s-c\b)/,
    what: 'sudoers policy' },
  { re: /\bsystemctl\s+(?:enable|disable|mask|unmask|start|stop|restart)\b/, what: 'systemd unit state' },
  { re: /\bufw\s+(?:allow|deny|delete|enable|disable|reset)\b/, what: 'firewall rules (ufw)' },
  { re: /\b(?:rm|mv|cp)\s+[^|]*\/(?:opt|etc|srv)\//,  what: 'files under a system path (rm/mv/cp)' },
  { re: /\bchown\b|\bchmod\b/,                      what: 'ownership / permissions (chown/chmod)' },
  { re: /\bgit\s+-C\s+\/srv\/[^\s]*\s+(?:merge(?=\s|$)|pull|reset|checkout)\b/, what: 'git state of a server checkout' },
];

export function serverStateChange(cmd) {
  const s = String(cmd || '');
  if (!s) return { changed: false, what: [] };
  if (!REMOTE.some((r) => r.test(s))) return { changed: false, what: [] };
  const what = MUTATORS.filter((m) => m.re.test(s)).map((m) => m.what);
  return { changed: what.length > 0, what };
}


export const RUNBOOK_PREFIX = 'docs/runbooks/';
