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
want_not(){ if printf '%s' "$2" | grep -qF -- "$3"; then FAIL=$((FAIL+1)); FAILURES+=("$1: must NOT contain '$3'"); else PASS=$((PASS+1)); fi; }

export FAKE_GH_OPEN_JSON='[]'

export FAKE_GH_MERGED_JSON='[{"number":910,"headRefName":"feat/zz-short","title":"feat(ci): wire dark suite (R-assoc-title-tok)","mergedAt":"2026-07-17T00:00:00Z"}]'
printf '### [QUEUED] R-assoc-title-tok · P3\n- aliases: r-assoc-title-tok\n- log:\n  - registered\n' > "$T"
want "title-token exact -> hard drift" "$(run)" '[B unacked-merge]'

export FAKE_GH_MERGED_JSON='[{"number":911,"headRefName":"feat/r-zzz-unrelated","title":"docs: guard thing, no token","mergedAt":"2026-07-17T00:00:00Z"}]'
printf '### [IN-DEV] R-assoc-invisible · P3\n- aliases: r-assoc-invisible\n- log:\n  - 2026-07-18 · lead-direct-apply complete + PR #911 @deadbeef\n' > "$T"
want "own-log PR #N merged -> hard drift" "$(run)" '[B unacked-merge·log]'

printf '### [QUEUED] R-assoc-bare · P3\n- aliases: r-assoc-bare\n- log:\n  - prerequisite #911 merged, the premise is cleared\n' > "$T"
OUT3="$(run)"
want_not "bare #N cross-ref -> no drift" "$OUT3" 'DRIFT'
want "bare #N cross-ref -> clean" "$OUT3" '✅ no drift'

printf '### [QUEUED] R-assoc-gatetok · P3 · [gate = blocked-by=overlap:pr#911]\n- aliases: r-assoc-gatetok\n- log:\n  - registered\n' > "$T"
want_not "lowercase pr#N gate token -> no drift" "$(run)" 'DRIFT'

export FAKE_GH_MERGED_JSON='[{"number":912,"headRefName":"feat/r-r05-dark-guard","title":"feat: no token here","mergedAt":"2026-07-17T00:00:00Z"}]'
printf '### [QUEUED] R-tests-r05-dark-guard · P3\n- aliases: r-tests-r05-dark-guard\n- log:\n  - registered\n' > "$T"
want "unambiguous fuzzy -> hard drift" "$(run)" '[B unacked-merge·fuzzy]'

export FAKE_GH_MERGED_JSON='[{"number":913,"headRefName":"feat/r-cal-lottery","title":"feat: no token","mergedAt":"2026-07-17T00:00:00Z"}]'
printf '### [QUEUED] R-cal-lottery-fanout · P3\n- aliases: r-cal-lottery-fanout\n- log:\n  - registered\n\n### [QUEUED] R-cal-lottery-dup · P3\n- aliases: r-cal-lottery-dup\n- log:\n  - registered\n' > "$T"
OUT5="$(run)"
want "ambiguous fuzzy -> soft verify" "$OUT5" '[B? naming]'
want_not "ambiguous fuzzy -> not hard drift" "$OUT5" '[B unacked-merge·fuzzy]'

export FAKE_GH_MERGED_JSON='[{"number":914,"headRefName":"docs/r-docs-prefix-case","title":"docs: no token","mergedAt":"2026-07-17T00:00:00Z"}]'
printf '### [QUEUED] R-docs-prefix-case · P3\n- aliases: r-docs-prefix-case\n- log:\n  - registered\n' > "$T"
want "docs/ prefix strip -> exact hard drift" "$(run)" '[B unacked-merge]'

export FAKE_GH_MERGED_JSON='[{"number":915,"headRefName":"feat/r-acked-card","title":"feat (R-acked-card)","mergedAt":"2026-07-17T00:00:00Z"}]'
printf '### [REVIEW] R-acked-card · P3 · MERGED #915 · DoD-GATED: observe-until 2099-01-01, waiting for the next cron cycle to observe\n- aliases: r-acked-card\n- log:\n  - MERGED #915 · gate-observed-at=2026-08-01T00:00:00Z\n' > "$T"
OUT7="$(run)"
want "acked+gated -> info not drift" "$OUT7" '[B merged·DoD-gated]'
want_not "acked+gated -> no unacked tier" "$OUT7" 'unacked-merge'

export FAKE_GH_MERGED_JSON='[]'
export FAKE_GH_OPEN_JSON='[{"number":916,"headRefName":"feat/r-zzz-divergent","title":"feat: no token","mergedAt":null}]'
printf '### [IN-DEV] R-assoc-stage · P3\n- aliases: r-assoc-stage\n- log:\n  - dev delivered + PR #916 open\n' > "$T"
want "own-log PR #N open + IN-DEV -> stage drift" "$(run)" '[C stage]'

fake_gh_stop
rm -f "$T"
summary
