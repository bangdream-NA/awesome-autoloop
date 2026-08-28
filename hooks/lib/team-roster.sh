#!/usr/bin/env bash

TEAM_ROSTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && { pwd -W 2>/dev/null || pwd; })"

team_roster_cfg() {
  local payload="$1" teams_dir="$2" target sid owned_cfg
  [ -d "$teams_dir" ] || return 0
  target=$(printf '%s' "$payload" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(s);process.stdout.write(String((o.tool_input&&o.tool_input.team_name)||""))}catch{process.stdout.write("")}})' 2>/dev/null || echo "")
  sid=$(printf '%s' "$payload" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(s);process.stdout.write(String(o.session_id||""))}catch{process.stdout.write("")}})' 2>/dev/null || echo "")

  if [ -n "$target" ] && [ -f "$teams_dir/$target/config.json" ]; then
    printf '%s' "$teams_dir/$target/config.json"; return 0
  fi
  [ -n "$sid" ] || return 0
  owned_cfg=$(RLA_TEAMS_DIR="$teams_dir" node --input-type=module -e '
import { resolveTeamConfig } from "file:///'"$TEAM_ROSTER_LIB_DIR"'/roster-live-agents.mjs";
process.stdout.write(String(resolveTeamConfig(process.argv[1]) || ""));' "$sid" 2>/dev/null || echo "")
  [ -n "$owned_cfg" ] && printf '%s' "$owned_cfg"
  return 0
}

team_roster_names() {
  _team_roster_via_owner "$1" "$2" 'const n=m.liveAgentNames(sid);process.stdout.write(Array.isArray(n)?n.join(", "):"");'
}

team_roster_count() {
  local n
  n=$(_team_roster_via_owner "$1" "$2" 'const a=m.liveAgentMembers(sid);process.stdout.write(String(Array.isArray(a)?a.length:0));')
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  printf '%s' "$n"
}

team_roster_dirs() {
  _team_roster_via_owner "$1" "$2" 'const a=m.teamConfigsFor(sid);process.stdout.write((Array.isArray(a)?a:[]).join("\n"));'
}

_team_roster_via_owner() {
  local payload="$1" teams_dir="$2" body="$3" sid
  sid=$(printf '%s' "$payload" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{try{const o=JSON.parse(s);process.stdout.write(String(o.session_id||""))}catch{process.stdout.write("")}})' 2>/dev/null || echo "")
  [ -n "$sid" ] || return 0
  RLA_TEAMS_DIR="$teams_dir" node --input-type=module -e '
import * as m from "file:///'"$TEAM_ROSTER_LIB_DIR"'/roster-live-agents.mjs";
const sid=process.argv[1];
'"$body" "$sid" 2>/dev/null || true
}
