#!/usr/bin/env bash
# block-future-timestamp — an OBSERVATION stamp in the future was typed, not read off a clock, and
# every freshness computation downstream then runs on fiction. The gate denies a future value in
# the observation fields, and separately denies a `- log:` stamp without seconds, which no parser
# that reads that field can match.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/block-future-timestamp.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_PROJ=/tmp/aal-fx-block-future-timestamp
rm -rf "$AAL_PROJ"; mkdir -p "$AAL_PROJ/.claude"; : > "$AAL_PROJ/.claude/.autoloop"
export CLAUDE_PROJECT_DIR="$AAL_PROJ"
trap 'rm -rf "$AAL_PROJ"' EXIT
# -----------------------------------------------------------------------------------------------

# 🔴 Every stamp below is generated RELATIVE TO NOW. A hardcoded one would drift from "future" to
# "past" on its own — the fixture would keep running, keep printing arms, and silently stop
# asserting what its labels say. Time is a dimension the environment supplies, so it has to be
# taken from the clock at run time rather than baked in.
FUTURE="$(aal_date_rel '+1 day' +%Y-%m-%dT%H:%M:%SZ)"
NEAR_FUTURE="$(aal_date_rel '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)"
WITHIN_SKEW="$(aal_date_rel '+30 seconds' +%Y-%m-%dT%H:%M:%SZ)"
PAST="$(aal_date_rel '-1 day' +%Y-%m-%dT%H:%M:%SZ)"
PAST_REDACTED="$(aal_date_rel '-3 hours' +%Y-%m-%dT%H):0xZ"
FUTURE_REDACTED="$(aal_date_rel '+1 day' +%Y-%m-%dT%H):0xZ"
NOW_NO_SECONDS="$(aal_date_rel '-1 hour' +%Y-%m-%dT%H:%MZ)"

# 🔴 `--` is load-bearing. Almost every payload in this file starts with `- ` (a board row), and
# without the separator node reads that leading dash as one of ITS options and dies with "bad
# option" on stderr. The command substitution then yields an EMPTY payload, the gate sees nothing,
# and the arm reports EXPECTED-DENY-BUT-ALLOWED — a fixture failure that looks exactly like a gate
# with a hole in it.
w() { # $1 = file content
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Write",tool_input:{file_path:"/tmp/aal-fx-block-future-timestamp/BACKLOG.md",content:process.argv[1]}}))' -- "$1"
}
e() { # $1 = new_string
  node -e 'process.stdout.write(JSON.stringify({tool_name:"Edit",tool_input:{file_path:"/tmp/aal-fx-block-future-timestamp/BACKLOG.md",old_string:"x",new_string:process.argv[1]}}))' -- "$1"
}

# --- DENY: an observation field ahead of the clock ------------------------------------------------
assert_deny "gate-observed-at a day ahead"  "$(w "- log: gate-observed-at=$FUTURE")"        'NO-FABRICATED-TIMESTAMP'
assert_deny "dod-failed-at ten minutes ahead" "$(w "- dod-failed-at=$NEAR_FUTURE")"         'NO-FABRICATED-TIMESTAMP'
assert_deny "gate-extended-at ahead"        "$(w "- gate-extended-at=$FUTURE")"             'NO-FABRICATED-TIMESTAMP'
# 🔴 Built in an assignment, never as `\"` inside a `"$( … )"` substitution. This was the ONE arm
# of fifteen still red on macOS after the date classes were fixed, and it is the only arm here
# carrying escaped double quotes inside a command substitution — stock bash 3.2, which ci.yml
# forces onto the macOS lane and nowhere else, parses that construct differently. The `'…'"$V"'…'`
# form has no backslash, so every bash agrees on it.
TS_ROW='{"card":"r-widget","ts":"'"$FUTURE"'"}'
assert_deny "a reviews-jsonl ts ahead"      "$(w "$TS_ROW")"                                  'NO-FABRICATED-TIMESTAMP'
assert_deny "an Edit, not just a Write"     "$(e "- dod-failed-at=$FUTURE")"                'NO-FABRICATED-TIMESTAMP'
# Redaction is a courtesy for a stamp whose exact minute is not worth stating; it is not a way to
# make a future time acceptable. The gate resolves `x` to its EARLIEST reading, so a redacted
# stamp a day out is still a day out.
assert_deny "a redacted stamp that is still future" "$(w "- gate-observed-at=$FUTURE_REDACTED")" 'NO-FABRICATED-TIMESTAMP'

# --- DENY, on the other predicate: a `- log:` stamp without seconds -------------------------------
assert_deny "a log row missing its seconds" "$(w "- log: $NOW_NO_SECONDS · dispatched the developer")" 'must carry SECONDS'

# --- ALLOW: stamps that were actually read off a clock --------------------------------------------
assert_allow "a past observation"           "$(w "- gate-observed-at=$PAST")"
assert_allow "a past log row with seconds"  "$(w "- log: $PAST · dispatched the developer")"
# The 120s skew exists because the writer's clock and the gate's clock are not the same clock.
assert_allow "half a minute ahead, inside the skew" "$(w "- dod-failed-at=$WITHIN_SKEW")"
assert_allow "a redacted PAST stamp"        "$(w "- gate-observed-at=$PAST_REDACTED")"

# --- ALLOW: fields that are SUPPOSED to point forward ----------------------------------------------
# observe-until is a deadline, not an observation. Pinning this keeps a later "check every date"
# broadening from breaking the one vocabulary item whose whole job is to name a future day.
assert_allow "observe-until in the future"  "$(w "- DoD-GATED: observe-until $FUTURE")"
assert_allow "a future date in ordinary prose" "$(w "We will re-measure this on $FUTURE if the queue drains.")"

# --- ALLOW: not a write at all ---------------------------------------------------------------------
assert_allow "the same text through Bash" \
  "$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:"echo gate-observed-at="+process.argv[1]}}))' "$FUTURE")"
assert_allow "an empty edit"                "$(e "")"

summary
