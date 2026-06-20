#!/usr/bin/env bash
# Shared JSON-parse helper for hooks.
# Uses node (always present where these hooks run) rather than python3, which
# may be absent or shadowed by a platform shim on some systems — making a
# `python3 -c` parse a silent no-op. node returns proper JSON-parse output.
#
# Usage:
#   source "$(dirname "$0")/lib/parse-json.sh"
#   COMMAND=$(json_get "$INPUT" command)
#   STOP_ACTIVE=$(json_get "$INPUT" stop_hook_active)
#
# Returns empty string if field missing or JSON invalid.

# Returns 0 if node is on PATH, 1 otherwise. No stdin consumed.
aal_have_node() { command -v node >/dev/null 2>&1; }

json_get() {
  local input="$1"
  local field="$2"
  echo "$input" | node -e "
let d='';
process.stdin.on('data', c => d += c);
process.stdin.on('end', () => {
  try {
    const obj = JSON.parse(d);
    // Try top-level first, then PreToolUse 'tool_input' envelope.
    // Claude Code PreToolUse hooks receive: {cwd, tool_input: {...actual params...}, tool_name, ...}
    let v = obj['$field'];
    if ((v === undefined || v === null) && obj.tool_input && typeof obj.tool_input === 'object') {
      v = obj.tool_input['$field'];
    }
    if (v === undefined || v === null) { console.log(''); return; }
    if (typeof v === 'boolean') { console.log(v ? 'true' : ''); return; }
    console.log(String(v));
  } catch (_) { /* silent */ }
});
" 2>/dev/null
}
