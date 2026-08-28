#!/usr/bin/env bash
set -euo pipefail
case ":${AAL_GATES:-commit-hygiene:pipeline-roles:merge-gates:ledger-hygiene:dod-walk:}:" in *":commit-hygiene:"*) ;; *) exit 0 ;; esac
source "$(dirname "$0")/lib/activation.sh"
aal_is_autoloop_project || exit 0
source "$(dirname "$0")/lib/parse-json.sh"
source "$(dirname "$0")/lib/log-denial.sh"

INPUT=$(cat)
COMMAND=$(json_get "$INPUT" command || echo "")
[ -z "$COMMAND" ] && exit 0

case "$COMMAND" in *'# CD-WRITE-OK:'*) exit 0;; esac
case "$COMMAND" in *'# VAR-PATH-OK:'*) exit 0;; esac
case "$COMMAND" in *'<<'*) exit 0;; esac

if grep -qiE '(scratchpad|[\\/]Temp[\\/]|AppData[\\/]Local[\\/]Temp|node_modules|[\\/]dist[\\/])' <<<"$COMMAND"; then
  exit 0
fi

emit_deny() {
  aal_log_denial "bash-cmd-quality-preflight" "block-cd-relative-write" "$2" || true
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' \
    "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  exit 0
}

VAR_SCAN=$(sed -E 's/>>?[[:space:]]*"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[^[:space:]"]*/ /g' <<<"$COMMAND")
VAR_SCAN=$(sed -E 's/\$\{?(TMP|TMPDIR|HOME|PWD|PATH|USERPROFILE)\}?/ /g' <<<"$VAR_SCAN")
VAR_SCAN=$(sed -E 's/\$\([^)]*\)/ /g' <<<"$VAR_SCAN")

if grep -qE '(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/|/"?'"'"'?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?)' <<<"$VAR_SCAN"; then
  emit_deny 'BLOCKED: VAR-IN-PATH. The command builds a path out of a variable expansion (`$X/…` or `…/"$X"`), so the path is not statically determinable and NOTHING can auto-approve it — every such command falls through to a manual confirmation, read-only ones included. NOTE: the harness message reuses the cd-compound wording and points at a `cd` you never wrote; do not go looking for the cd, the VARIABLE is what triggered this. FIX: list the candidates with one ordinary command first, then act using a LITERAL ABSOLUTE path. To run a tool in a directory use `git -C <abs>` / `node <abs>`. Exemption: append `# VAR-PATH-OK: <reason>`.' \
    'variable expansion used to build a path'
fi

ASSIGNED=$(grep -oE '(^|[;&|[:space:]])[A-Za-z_][A-Za-z0-9_]*=\$\(' <<<"$COMMAND" \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*=' | tr -d '=' || true)
for n in $ASSIGNED; do
  case "$n" in TMP|TMPDIR|HOME|PWD|PATH|USERPROFILE) continue;; esac
  if grep -qE "\\\$\\{?${n}\\}?" <<<"$VAR_SCAN"; then
    emit_deny 'BLOCKED: DYNAMIC-ARG. The command assigns a result to a variable (`X=$(…)`) and then expands it, so the classifier reports `Contains shell syntax (string) that cannot be statically analyzed` and NOTHING can auto-approve it — every such command falls through to a manual confirmation. FIX: split it in two — (1) run the read-only command and LOOK at the result; (2) write the second command with the LITERAL value. One extra round trip, in exchange for not making a person click every single one. Exemption: append `# VAR-PATH-OK: <reason>`.' \
      'command-substitution assigned then expanded'
  fi
done

LOOPVARS=$(grep -oE '(^|[;&|[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]' <<<"$COMMAND" \
  | grep -oE 'for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' | awk '{print $2}' || true)
WHILEVARS=$(grep -oE '\bwhile[[:space:]]+read[[:space:]]+(-r[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*' <<<"$COMMAND" \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*$' || true)
for n in $LOOPVARS $WHILEVARS; do
  if grep -qE "\\\$\\{?${n}\\}?" <<<"$COMMAND"; then
    emit_deny 'BLOCKED: LOOP-VAR. The command uses a `for … in` / `while read` loop and expands the loop variable in the body, so the classifier cannot statically expand the iteration and the WHOLE command falls through to a manual confirmation. NOTE: the reason it prints differs every time and often does not exist in the situation at hand (three measured: `simple_expansion` · `shell syntax … cannot be statically analyzed` · `Path traverses a Cygwin-emulated symlink` — and that last path contained zero symlinks). **Do not chase the wording; the SHAPE is the test.** FIX (measured: zero prompts): (1) run a READ-ONLY command first and look at the candidates; (2) then write them out as LITERALS, one per line. Exemption: append `# VAR-PATH-OK: <reason>`.' \
      'loop variable expanded in body'
  fi
done

grep -qE '(^|[;&|]|[[:space:]])cd[[:space:]]+[^[:space:]]' <<<"$COMMAND" || exit 0

WRITE_VERB='(rm|rmdir|mv|cp|mkdir|touch|truncate|tee|unlink|shred)'
if grep -qE "(^|[;&|]|[[:space:]])${WRITE_VERB}([[:space:]]+-[^[:space:]]+)*[[:space:]]+[^-/~[:space:]\"'\$][^:[:space:]]" <<<"$COMMAND"; then
  HIT=1
elif grep -qE "(^|[;&|]|[[:space:]])sed[[:space:]]+(-[^[:space:]]*i[^[:space:]]*)[[:space:]]" <<<"$COMMAND" \
  && grep -qE "[[:space:]][^-/~[:space:]\"'\$][^:[:space:]]*\.[a-zA-Z0-9]+[[:space:]]*(\$|[;&|])" <<<"$COMMAND"; then
  HIT=1
else
  HIT=0
fi
[ "$HIT" = 1 ] || exit 0

emit_deny 'BLOCKED: CD-RELATIVE-WRITE. A relative write (rm/mv/cp/mkdir/touch/tee/sed -i) after a `cd`. FIX: drop the `cd` and make the write target a literal absolute path; to run a tool in a directory use `git -C <abs>` / `node <abs>`. Exemption: append `# CD-WRITE-OK: <reason>`.' \
  'cd-compound with relative write target'
