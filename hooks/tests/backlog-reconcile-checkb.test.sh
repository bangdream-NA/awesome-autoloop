#!/usr/bin/env bash
source "$(dirname "$0")/_lib.sh"
REC="$(cd "$(dirname "$0")/.." && pwd)"/backlog-reconcile.mjs
# 🔴 Scratch lives in a temp dir the fixture creates and removes — NEVER under the operator's
# config root. Every path below is handed to the tool explicitly, so nothing requires it to sit
# there; with CLAUDE_CONFIG_DIR unset (the default for an adopter) the old form dropped files
# into a real ~/.claude, and on a machine where that directory is read-only source it is worse
# than untidy.
T="$(mktemp -d)/board.md"
fake_gh_start

run(){ AAL_BACKLOG="$T" AAL_REPO="fixture-owner/fake" node "$REC" 2>&1; }
want(){ if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILURES+=("$1: want '$3' (got: $(printf '%s' "$2" | head -c200))"); fi; }

MERGED_JSON_TMPL='[{"number":900,"headRefName":"feat/r-checkb-fixture","title":"fixture","mergedAt":"__MERGED_AT__"}]'
export FAKE_GH_OPEN_JSON='[]'

CHECKB_FRESH="$(aal_date_rel '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
CHECKB_50H_AGO="$(aal_date_rel '-50 hours' +%Y-%m-%dT%H:%M:%SZ)"

export FAKE_GH_MERGED_JSON="${MERGED_JSON_TMPL/__MERGED_AT__/$CHECKB_FRESH}"
printf '### [QUEUED] R-checkb-verified · P3 · DoD-VERIFIED (verified first-hand)\n- aliases: r-checkb-verified\n- log:\n  - ✅ MERGED #900\n' > "$T"
want "VERIFIED-on-active -> drift (promoted)" "$(run)" '[B merged·DoD-done-unarchived]'

printf '### [QUEUED] R-checkb-overdue-date · P3 · observe-until 2020-01-01\n- aliases: r-checkb-overdue-date\n- log:\n  - ✅ MERGED #900\n' > "$T"
want "OVERDUE_DATE -> drift" "$(run)" 'has PASSED'

printf '### [QUEUED] R-checkb-gated-future · P3 · observe-until 2099-01-01\n- aliases: r-checkb-gated-future\n- log:\n  - ✅ MERGED #900 · gate-observed-at=2026-07-20T02:20:36Z\n' > "$T"
want "GATED (future date) -> info" "$(run)" '[B merged·DoD-gated]'

printf '### [QUEUED] R-checkb-gated-reason · P3 · DoD-GATED: needs a ruling from the user\n- aliases: r-checkb-gated-reason\n- log:\n  - ✅ MERGED #900 · gate-observed-at=2026-07-20T02:20:36Z\n' > "$T"
want "GATED (reason, undated) -> undated-gate drift" "$(run)" '[B merged·DoD-undated-gate]'

export FAKE_GH_MERGED_JSON="${MERGED_JSON_TMPL/__MERGED_AT__/2020-01-01T00:00:00Z}"
printf '### [QUEUED] R-checkb-gate-expired · P2 · DoD-GATED: needs a ruling from the user\n- aliases: r-checkb-gate-expired\n- log:\n  - ✅ MERGED #900\n' > "$T"
want "UNDATED gate past P-timer -> drift (gate-expired)" "$(run)" '[B gate-expired]'
export FAKE_GH_MERGED_JSON="${MERGED_JSON_TMPL/__MERGED_AT__/$CHECKB_50H_AGO}"

printf '### [QUEUED] R-checkb-gate-hdrp · 🟢 P3 · DoD-GATED: needs a ruling from the user\n- aliases: r-checkb-gate-hdrp\n- problem: this escalates to P0 if it is not fixed\n- log:\n  - ✅ MERGED #900 · gate-observed-at=2026-07-20T02:20:36Z\n' > "$T"
want "P-level anchored to header (body P0 prose ignored)" "$(run)" '[B merged·DoD-undated-gate]'

export FAKE_GH_MERGED_JSON="${MERGED_JSON_TMPL/__MERGED_AT__/2020-01-01T00:00:00Z}"
printf '### [QUEUED] R-checkb-overdue-pending · P3\n- aliases: r-checkb-overdue-pending\n- log:\n  - ✅ MERGED #900\n  - DoD pending walk\n' > "$T"
want "OVERDUE_PENDING (old merge, bare pending) -> drift" "$(run)" '[B dod-overdue]'

export FAKE_GH_MERGED_JSON="${MERGED_JSON_TMPL/__MERGED_AT__/$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
printf '### [QUEUED] R-checkb-pending · P3\n- aliases: r-checkb-pending\n- log:\n  - ✅ MERGED #900\n  - DoD pending walk\n' > "$T"
want "dateless pending on FRESH merge -> drift (strengthened)" "$(run)" '[B dod-overdue]'

printf '### [QUEUED] R-checkb-no-dod · P3\n- aliases: r-checkb-no-dod\n- log:\n  - ✅ MERGED #900\n' > "$T"
want "NO_DOD (bare ack) -> drift" "$(run)" '[B ack-no-dod]'

fake_gh_stop
rm -f "$T"
summary
