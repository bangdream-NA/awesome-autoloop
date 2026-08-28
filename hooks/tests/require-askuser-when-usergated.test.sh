#!/usr/bin/env bash
# require-askuser-when-usergated — while the person who makes a decision is HERE, parking that
# decision on the board spends the only window in which it can be made. The gate blocks the stop when
# a user-gated card is parked and the turn asked nothing, and separately when a sentence in the reply
# hands a judgement to them without ever putting the question.
source "$(dirname "$0")/_lib.sh"
# shellcheck disable=SC2034  # _lib.sh consumes $HOOK; shellcheck cannot follow `source`
HOOK="$(cd "$(dirname "$0")/.." && pwd)"/require-askuser-when-usergated.mjs

# --- portable activation context ---------------------------------------------------------------
AAL_TMP="$(mktemp -d)"
REPO="$AAL_TMP/repo"
mkdir -p "$REPO/.claude"
REPO_N="$(aal_mkrepo "$REPO")"
: > "$REPO/.claude/.autoloop"
AAL_TMP_N="$(aal_native "$AAL_TMP")"
aal_pin_project "$REPO_N"
# Naming the board through the seam also pins WHICH project's cards are read: without it the gate
# walks every project it knows about, which on an operator's machine is all of them.
export AAL_BACKLOG="$REPO_N/.claude/BACKLOG.md"
trap 'rm -rf "$AAL_TMP"' EXIT

GATE_KEY=blocked-by
gated_card() { printf '%s [%s] %s · %s=user · P1\n' '###' 'USER-GATED' "$1" "$GATE_KEY"; }
plain_card() { printf '%s [%s] %s · P1\n' '###' 'IN-DEV' "$1"; }
board() { printf '# Backlog\n\n%s\n' "$1" > "$REPO/.claude/BACKLOG.md"; }

# The transcript carries three things this gate reads: whether the user is present, whether the turn
# called AskUserQuestion, and what the last reply said. All three are written here rather than
# inherited — presence especially, since an ambient transcript would make the verdict depend on
# whether somebody typed into the operator's session in the last hour.
NOW="$(aal_date_rel '-1 minute' +%Y-%m-%dT%H:%M:%SZ)"
OLD="$(aal_date_rel '-5 hours' +%Y-%m-%dT%H:%M:%SZ)"
mktranscript() { # $1 = out, $2 = presence stamp, $3 = assistant text, $4 = "ask" to include an answered question
  node -e '
const fs = require("fs");
const [out, stamp, text, withAsk] = process.argv.slice(1);
const rows = [JSON.stringify({ type: "user", promptSource: "typed", timestamp: stamp, message: { role: "user", content: "go on" } })];
if (withAsk === "ask") {
  rows.push(JSON.stringify({ type: "assistant", message: { content: [ { type: "tool_use", name: "AskUserQuestion", input: { questions: [] } } ] } }));
  rows.push(JSON.stringify({ type: "user", message: { content: "Your questions have been answered" } }));
}
rows.push(JSON.stringify({ type: "assistant", message: { role: "assistant", content: [ { type: "text", text } ] } }));
fs.writeFileSync(out, rows.join("\n") + "\n");' -- "$1" "$2" "$3" "${4:-}"
}
p() { node -e 'process.stdout.write(JSON.stringify({session_id:"11111111-2222-3333-4444-555555555555",transcript_path:process.argv[1]}))' -- "$1"; }
NEUTRAL='The fixture is written and the branch is amended.'
# -----------------------------------------------------------------------------------------------

# --- FIRES: a parked user decision while they are here ------------------------------------------------
board "$(gated_card R-widget)"
mktranscript "$AAL_TMP/here.jsonl" "$NOW" "$NEUTRAL"
assert_fires "a parked card, nothing asked" "$(p "$AAL_TMP_N/here.jsonl")" 'ask in THIS turn'
assert_fires "…and it names the card"       "$(p "$AAL_TMP_N/here.jsonl")" 'R-widget'

# --- QUIET: the turn actually asked ---------------------------------------------------------------------
mktranscript "$AAL_TMP/asked.jsonl" "$NOW" "$NEUTRAL" ask
assert_quiet "the same board, with a question asked" "$(p "$AAL_TMP_N/asked.jsonl")"

# --- QUIET: they are not here ------------------------------------------------------------------------------
# Parking is the correct move when the room is empty; this gate is about the window, not about the card.
mktranscript "$AAL_TMP/away.jsonl" "$OLD" "$NEUTRAL"
assert_quiet "a parked card while they are away" "$(p "$AAL_TMP_N/away.jsonl")"

# --- QUIET: nothing is parked -------------------------------------------------------------------------------
board "$(plain_card R-widget)"
mktranscript "$AAL_TMP/here2.jsonl" "$NOW" "$NEUTRAL"
assert_quiet "no user-gated card" "$(p "$AAL_TMP_N/here2.jsonl")"

# --- FIRES: the prose limb — a judgement handed over without a question ---------------------------------------
# No card is parked here at all. The sentence alone is the offence: it records a decision as theirs
# while the turn ends without ever putting it to them.
mktranscript "$AAL_TMP/deleg.jsonl" "$NOW" 'That one is yours to decide, so I will leave it for now.'
assert_fires "a delegating sentence"  "$(p "$AAL_TMP_N/deleg.jsonl")" 'called YOURS without being asked'
mktranscript "$AAL_TMP/deleg2.jsonl" "$NOW" 'This needs your approval before I go further.'
assert_fires "…and another spelling"  "$(p "$AAL_TMP_N/deleg2.jsonl")" 'called YOURS without being asked'

# --- QUIET: sentences that report a decision already made -------------------------------------------------------
# The past tense is the discriminator, and it has to be, or writing down what they already ruled
# becomes impossible without being told to ask again.
mktranscript "$AAL_TMP/past.jsonl" "$NOW" 'You already ruled on this, so I built it that way.'
assert_quiet "a decision they already made" "$(p "$AAL_TMP_N/past.jsonl")"
mktranscript "$AAL_TMP/neutral.jsonl" "$NOW" "$NEUTRAL"
assert_quiet "an ordinary reply"            "$(p "$AAL_TMP_N/neutral.jsonl")"

# --- QUIET: nothing to read ----------------------------------------------------------------------------------------
assert_quiet "a transcript that is not there" "$(p "$AAL_TMP_N/missing.jsonl")"

summary
