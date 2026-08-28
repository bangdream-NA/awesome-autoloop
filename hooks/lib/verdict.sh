#!/usr/bin/env bash

_VERDICT_REJECT_RE='(NOT[[:space:]]+APPROVED|CHANGES[_[:space:]-]+(REQUESTED|REQUIRED)|NEEDS[_[:space:]-]+(FIXES|REVISION)|\bWONTFIX\b|\bREJECTED\b)'
_VERDICT_AMBIG_RE='APPROVED[_[:space:]-]+WITH'
_VERDICT_APPROVE_RE='\bAPPROVED\b'

_VERDICT_FW_COLON=$(printf '\357\274\232')

decide_verdict() {
  local block line cline last="NONE" reason=""
  block=$(cat)
  while IFS= read -r line; do
    local is_marker=0 is_header=0
    printf '%s' "$line" | sed "s/$_VERDICT_FW_COLON/:/g" | grep -qiE 'verdict[*[:space:]]*:' && is_marker=1
    printf '%s' "$line" | grep -qE '^[[:space:]]*#{2,}[[:space:]]' && is_header=1
    [ "$is_marker" = 1 ] || [ "$is_header" = 1 ] || continue
    if [ "$is_header" = 1 ]; then
      cline=$(printf '%s' "$line" | sed -E 's/\([^)]*\)//g')
    else
      cline="$line"
    fi
    if printf '%s' "$cline" | grep -qiE "$_VERDICT_REJECT_RE"; then
      last="DENY"; reason=$(printf '%s' "$cline" | grep -oiE "$_VERDICT_REJECT_RE" | head -1)
    elif printf '%s' "$cline" | grep -qiE "$_VERDICT_AMBIG_RE"; then
      last="AMBIGUOUS"; reason="APPROVED_WITH_* qualifier (not an unambiguous approval)"
    elif printf '%s' "$cline" | grep -qiE "$_VERDICT_APPROVE_RE"; then
      last="APPROVED"; reason=""
    fi
  done <<< "$block"
  case "$last" in
    APPROVED)  echo "APPROVED" ;;
    DENY)      echo "DENY:${reason}" ;;
    AMBIGUOUS) echo "AMBIGUOUS:${reason}" ;;
    *)         echo "NONE" ;;
  esac
}

classify_jsonl_verdict() {
  case "$(printf '%s' "${1:-}" | tr 'a-z' 'A-Z')" in
    APPROVED) echo allow ;;
    CHANGES_REQUESTED|CHANGES-REQUESTED|CHANGES_REQUIRED|CHANGES-REQUIRED|NEEDS_FIXES|NEEDS-FIXES|NEEDS_REVISION|NEEDS-REVISION|WONTFIX|REJECTED) echo deny ;;
    *) echo fallthrough ;;
  esac
}

ship_decision() {
  local is_merge="${1:-0}" has_pr="${2:-0}" local_eq="${3:-1}"
  [ "$has_pr" = 1 ] || { echo allow; return; }
  [ "$is_merge" = 1 ] && { echo review; return; }
  [ "$local_eq" = 1 ] && { echo review; return; }
  echo allow
}
