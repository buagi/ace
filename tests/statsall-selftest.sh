#!/usr/bin/env bash
# statsall-selftest.sh — pins `ace stats` as the ONE reporting surface.
#
# TWO PROPERTIES, and the second matters more than the first:
#   1. bare `ace stats` prints all four sections, `ace stats <section>` prints one.
#   2. NOTHING THAT WORKED BEFORE STOPPED WORKING. `ace stats global|7|task|--by task` are documented forms
#      people have in scripts and muscle memory; a new section name silently swallowing one of them would be a
#      regression with no error message. The legacy args are asserted to arrive at the token table BYTE FOR
#      BYTE, not merely to "not crash".
#
# Sections are stubbed, so this is offline and free: the point is the routing and the isolation, not the
# content of reports that already have their own tests.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
fail=0
bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }
LIB="$PWD/lib/statsall.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# run <args...> — the real ace_stats_cmd with every section stubbed to name itself and echo its argv.
run() {
  local a1="${1:-}" a2="${2:-}" a3="${3:-}"
  ( set --
    cd "$WORK" || exit 1
    export ACE_DIR="$PWD"
    # shellcheck disable=SC1090
    . "$LIB" || exit 1
    _sa_libs(){ :; }                       # keep the stubs below; do not load the real libs over them
    ace_stats(){            printf 'TOKENS argv=[%s]\n' "$*"; }
    ace_quality(){          printf 'QUALITY\n'; }
    ace_scorecard(){        printf 'SCORECARD\n'; }
    ace_reanalyze_report(){ printf 'PLAN\n'; }
    ace_stats_cmd ${a1:+"$a1"} ${a2:+"$a2"} ${a3:+"$a3"}
  ) 2>&1
}

# --- 1. bare `ace stats` prints EVERY section ------------------------------------------------------------
out="$(run)"
for s in TOKENS QUALITY SCORECARD PLAN; do
  grep -q "$s" <<<"$out" || bad "bare 'ace stats' did not include the $s section"
done
for h in 'Tokens and cost' 'Quality' 'Run scorecard' 'Plan before/after'; do
  grep -qF -- "$h" <<<"$out" || bad "bare 'ace stats' printed no header for '$h'"
done
# ...and it must say HOW to narrow, or the full dump is the only thing anyone ever sees
grep -qF 'ace stats <section>' <<<"$out" || bad "bare 'ace stats' never mentions that a single section can be asked for"

# --- 2. one section prints ONLY that section -------------------------------------------------------------
o="$(run quality)"
grep -q QUALITY   <<<"$o" || bad "'ace stats quality' did not print the quality section"
grep -q SCORECARD <<<"$o" && bad "'ace stats quality' also printed the scorecard — a section filter that filters nothing"
grep -q TOKENS    <<<"$o" && bad "'ace stats quality' also printed the token table"
grep -q SCORECARD <<<"$(run scorecard)" || bad "'ace stats scorecard' did not print the scorecard"
grep -q PLAN      <<<"$(run plan)"      || bad "'ace stats plan' did not print the plan comparison"
grep -q TOKENS    <<<"$(run tokens)"    || bad "'ace stats tokens' did not print the token table"
# the aliases the old commands used must land on the same section
grep -q SCORECARD <<<"$(run measure)"   || bad "'ace stats measure' (the ace scorecard alias) did not route to the scorecard"
grep -q PLAN      <<<"$(run reanalyze)" || bad "'ace stats reanalyze' did not route to the plan comparison"

# --- 3. BACK-COMPAT: every legacy form reaches the token table with its ARGS INTACT -----------------------
# This is the assertion that matters. `ace stats global` must still mean "all projects", not "unknown section".
for legacy in global task 7 --global --days=7; do
  o="$(run "$legacy")"
  grep -qF "TOKENS argv=[$legacy]" <<<"$o" \
    || bad "legacy 'ace stats $legacy' did not reach the token table with its argument intact (got: $(grep -o 'TOKENS argv=\[[^]]*\]' <<<"$o" || echo NOTHING))"
  grep -q 'SCORECARD' <<<"$o" && bad "legacy 'ace stats $legacy' also printed the other sections — it must be a passthrough, not the full report"
done
# multi-arg legacy forms must keep BOTH arguments, in order
o="$(run --by task)"
grep -qF 'TOKENS argv=[--by task]' <<<"$o" || bad "'ace stats --by task' lost an argument on the way to the token table"

# --- 4. AN UNSET ARG MUST VANISH, NOT ARRIVE AS "" -------------------------------------------------------
# The old dispatch passed "${ACE_ARG:-}" unconditionally, so ace_stats always received three empty strings.
# If that shape survived here, bare `ace stats` would be indistinguishable from `ace stats ""` and could never
# route to the all-sections report.
grep -q 'SCORECARD' <<<"$(run)" || bad "bare 'ace stats' (no args) did not reach the all-sections report"
# ...and the DISPATCH LINE must use ${VAR:+"$VAR"}, not "${VAR:-}". This is only observable statically: the
# conversion happens in ./ace, above ace_stats_cmd, so no amount of calling the function can catch a
# regression there. With "${ACE_ARG:-}" the function receives three empty strings and `ace stats` can never
# be told from `ace stats ""` — the all-sections report becomes unreachable from the CLI.
grep -qF 'ace_stats_cmd ${ACE_ARG:+"$ACE_ARG"}' ace \
  || bad "./ace does not pass stats args with \${VAR:+...} — an unset arg would arrive as \"\" and bare 'ace stats' could never reach the all-sections report"

# --- 5. FAIL-SOFT: one broken section must not take down the report --------------------------------------
# A report that dies on its first missing artifact is a report nobody runs twice.
o="$( ( set --; cd "$WORK" || exit 1; export ACE_DIR="$PWD"
       # shellcheck disable=SC1090
       . "$LIB" || exit 1
       _sa_libs(){ :; }
       ace_stats(){ echo boom >&2; exit 3; }        # dies hard, mid-report
       ace_quality(){ printf 'QUALITY\n'; }
       ace_scorecard(){ cd /tmp || return; printf 'SCORECARD\n'; }   # wanders off
       ace_reanalyze_report(){ printf 'PLAN\n'; }
       ace_stats_all; printf 'RC=%s\n' "$?"
       printf 'CWD=%s\n' "$PWD" ) 2>&1 )"
grep -q QUALITY   <<<"$o" || bad "a section that exited 3 aborted the whole report — sections must be isolated"
grep -q PLAN      <<<"$o" || bad "the report did not reach the last section after an earlier one died"
grep -q 'RC=0'    <<<"$o" || bad "ace stats_all returned non-zero because a SECTION failed — the report itself succeeded"
grep -q "CWD=$WORK" <<<"$o" || bad "a section's 'cd' escaped its subshell and moved the caller ($(grep -o 'CWD=.*' <<<"$o")) — the next command would run in the wrong repo"

# --- 6. an EMPTY section says so rather than rendering blank ---------------------------------------------
o="$( ( set --; cd "$WORK" || exit 1; export ACE_DIR="$PWD"
       # shellcheck disable=SC1090
       . "$LIB" || exit 1
       _sa_libs(){ :; }
       ace_stats(){ printf '\n   \n'; }             # whitespace only — must NOT count as content
       ace_quality(){ printf 'QUALITY\n'; }; ace_scorecard(){ :; }; ace_reanalyze_report(){ :; }
       ace_stats_all ) 2>&1 )"
[ "$(grep -c 'no data yet' <<<"$o")" -ge 3 ] \
  || bad "a section with blank/no output did not say 'no data yet' — an empty section with no explanation reads as a broken report"

# --- 7. THE OLD COMMANDS STILL EXIST. This is an addition, not a migration. ------------------------------
grep -qE '^\s+quality\)' ace            || bad "'ace quality' was removed — folding a report in must not delete its command"
grep -qE '^\s+scorecard\|measure\)' ace || bad "'ace scorecard' was removed"
grep -qE '^\s+reanalyze\)' ace          || bad "'ace reanalyze' was removed"
# `ace report` must STILL mean "file an issue" — reusing that verb for the rollup is the thing we avoided
grep -qE '^\s+report\|triage\)' ace     || bad "'ace report' (file a GitHub issue) was clobbered — the rollup deliberately lives on 'ace stats' instead"
grep -q 'ace_report ' ace               || bad "'ace report' no longer calls ace_report — its meaning changed after all"
# and usage() must document the surface it now is
grep -qE '^  ace stats ' ace            || bad "'ace stats' is dispatched but absent from usage()"
grep -q 'ONE REPORT SURFACE' ace        || bad "usage() does not tell the user ace stats is now the one surface"

[ "$fail" = 0 ] && echo "statsall-selftest: PASS — 4 sections, single-section filter, legacy args intact byte-for-byte, sections isolated (exit/cd), empty sections explained, old commands untouched"
[ "$fail" = 0 ] || echo "statsall-selftest: FAIL — see above"
exit "$fail"
