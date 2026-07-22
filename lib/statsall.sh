#!/usr/bin/env bash
# statsall.sh — `ace stats` as the ONE reporting surface.
#
# WHY THIS EXISTS: four commands answered four different questions about the same run — `ace stats` (tokens
# and cost), `ace quality` (critic false-positive + retry rates), `ace scorecard` (the 8-level run report) and
# `ace reanalyze report` (plan before→after). Knowing which to run required knowing they all existed, so in
# practice a run was read through whichever one the user happened to remember.
#
# `ace report` was NOT reusable for this: it already means "file a GitHub issue" (`ace_report`/`ace_triage`),
# and quietly changing what an existing verb does is worse than the problem being solved. `ace stats` is the
# surface instead — it was already the one people reached for.
#
# NOTHING IS LOST AND NOTHING IS RENAMED. `ace quality`, `ace scorecard` and `ace reanalyze report` all still
# work exactly as before; the old `ace stats global|N|task|--flags` forms still route straight to the token
# table. Only the BARE `ace stats` changed: it now prints every section instead of just the first one.
#
# FAIL-SOFT BY CONSTRUCTION: each section runs in its own subshell with output captured, so a section that
# errors, `exit`s or `cd`s cannot take down the report or move the caller's shell. A section with no artifacts
# says so and the rest still print — a report that dies on its first missing file is a report nobody trusts.

# _sa_libs — source the four section owners once. Kept separate from the section runner so a lib that is
# missing (a partial checkout, a trimmed install) degrades to "section unavailable" rather than a hard error.
_sa_libs() {
  local d="${_ACE_LIB:-$ACE_DIR/lib}"
  # shellcheck disable=SC1090,SC1091
  for f in telemetry scorecard reanalyze; do [ -f "$d/$f.sh" ] && . "$d/$f.sh" 2>/dev/null; done
  return 0
}

# _sa_head <n> <title> <what it answers>
_sa_head() {
  printf '\n%s─── %s. %s %s\n' "${C_BOLD:-}" "$1" "$2" "${C_RESET:-}"
  printf '%s    %s%s\n' "${C_DIM:-}" "$3" "${C_RESET:-}"
}

# _sa_section <n> <title> <question> <fn> [args...]
# Runs ONE section. The command substitution is the isolation boundary: `exit` inside a section ends only the
# subshell, and a `cd` inside it cannot relocate the caller.
_sa_section() {
  local n="$1" title="$2" question="$3"; shift 3
  _sa_head "$n" "$title" "$question"
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '    — unavailable (%s is not loaded)\n' "$1"; return 0
  fi
  local out
  out="$( "$@" 2>&1 )"
  # STRIP BLANK-ONLY OUTPUT before deciding it is empty: several of these print a leading newline even when
  # they have nothing, which would otherwise read as content and leave an empty section with no explanation.
  if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
    printf '    — no data yet (nothing this section reads has been written for this repo)\n'
  else
    printf '%s\n' "$out" | sed 's/^/  /'
  fi
  return 0
}

# ace_stats_all — every section, in the order you would actually read them: what it cost, whether the work was
# any good, the full run report, then whether the PLAN improved.
ace_stats_all() {
  _sa_libs
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  printf '%sace stats — %s%s\n' "${C_BOLD:-}" "$(basename "$root")" "${C_RESET:-}"
  printf '%s(one surface; `ace stats <section>` for just one · the old `ace stats global|N|task` still works)%s\n' \
    "${C_DIM:-}" "${C_RESET:-}"
  _sa_section 1 "Tokens and cost"  "what the run spent, per subagent x worker"        ace_stats
  _sa_section 2 "Quality"          "critic false-positive rate, retries, escaped bugs" ace_quality
  _sa_section 3 "Run scorecard"    "the 8-level run report and its VERDICT"            ace_scorecard
  _sa_section 4 "Plan before/after" "did re-deriving the breakdown make it cleaner"    ace_reanalyze_report
  printf '\n'
  return 0
}

# ace_stats_cmd — the `ace stats` entry point.
#
# BACK-COMPAT IS THE DEFAULT BRANCH, NOT A SPECIAL CASE: anything this does not recognise as a section name
# falls through to ace_stats with the ORIGINAL arguments, so every documented form (`global`, a bare number of
# days, `task`, `--by`, `--days=N`) keeps working untouched. A new section name can never silently swallow an
# argument the token table used to understand, because the section list is closed and explicit.
ace_stats_cmd() {
  _sa_libs
  case "${1:-}" in
    ""|all|--all-sections)  ace_stats_all ;;
    tokens|cost)            _sa_section 1 "Tokens and cost"   "what the run spent, per subagent x worker"        ace_stats ;;
    quality)                _sa_section 2 "Quality"           "critic false-positive rate, retries, escaped bugs" ace_quality ;;
    scorecard|run|measure)  _sa_section 3 "Run scorecard"     "the 8-level run report and its VERDICT"            ace_scorecard ;;
    reanalyze|plan)         _sa_section 4 "Plan before/after" "did re-deriving the breakdown make it cleaner"     ace_reanalyze_report ;;
    sections|--list)        printf 'ace stats sections: tokens · quality · scorecard · plan   (bare `ace stats` prints all four)\n' ;;
    *)                      ace_stats "$@" ;;
  esac
}
