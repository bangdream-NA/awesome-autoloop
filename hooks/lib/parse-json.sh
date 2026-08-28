#!/usr/bin/env bash

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
    let v = obj['$field'];
    if ((v === undefined || v === null) && obj.tool_input && typeof obj.tool_input === 'object') {
      v = obj.tool_input['$field'];
    }
    if (v === undefined || v === null) { console.log(''); return; }
    if (typeof v === 'boolean') { console.log(v ? 'true' : ''); return; }
    console.log(String(v));
  } catch (_) {  }
});
" 2>/dev/null
}
