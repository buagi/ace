#!/usr/bin/env bash
# flake-check — run each suite N times and fail on any suite that does not decide the same way every time.
#
# WHY THIS EXISTS (it was written after being bitten, not speculatively):
# `tests/prompt-contracts.sh` shipped a `printf "$body" | grep -qF` under `set -o pipefail`. grep exits on the
# match while printf is still writing, printf takes SIGPIPE, the pipeline returns 141, and the guard reports a
# spurious FAIL -- measured at 2 runs in 60. Per-PR CI runs each suite ONCE, so a 3% flake is ~97% invisible at
# the gate and merges clean. It then reds someone else's unrelated PR, where it reads as "your change broke it".
#
# It is deliberately EMPIRICAL rather than static. The obvious static rule -- flag `printf "$var" | grep -q`
# under pipefail -- was prototyped and measured: 95 hits repo-wide, and the tightened "variable holds unbounded
# data" variant still hit 58, nearly all safe because the data is far below the 64K pipe buffer. An error-level
# gate with that false-positive rate gets switched off, and a switched-off gate protects nothing. Running the
# suites repeatedly costs minutes and catches the whole class -- SIGPIPE races, clock and timezone dependence,
# ordering, temp-path collisions, concurrency -- instead of one syntactic shape of it.
#
# NOT wired into per-PR CI: N x 12 suites is minutes, and the defect it catches is a merge-time hazard rather
# than a diff-time one. It runs nightly. Run it by hand before merging anything that touches a test harness.
#
# Usage: tests/flake-check.sh [--runs N] [--suites "a b"] [--selftest]
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

RUNS=8
SUITES="bash-traps prompt-contracts profile-reader supply-chain cli-dispatch-selftest approval-selftest
        autoloop-selftest snapshot-generators hygiene-selftest reanalyze-selftest scorecard-selftest killorder-selftest firecrawl-selftest debate-eligibility-selftest"
# swarm-selftests is intentionally excluded from the default set: it is a battery that shells out to the other
# suites, so N runs of it multiplies the wall clock while adding no coverage this file does not already have.

while [ $# -gt 0 ]; do
  case "$1" in
    --runs)     RUNS="${2:-8}"; shift 2 ;;
    --suites)   SUITES="${2:-}"; shift 2 ;;
    --selftest) SELFTEST=1; shift ;;
    *) echo "flake-check: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$RUNS" in ''|*[!0-9]*) echo "flake-check: --runs must be a positive integer, got: $RUNS" >&2; exit 2 ;; esac
[ "$RUNS" -ge 2 ] || { echo "flake-check: --runs must be >= 2 (one run cannot show a disagreement)" >&2; exit 2; }

fail=0
bad(){ echo "FAIL: $*"; fail=1; }

# --- the check itself -------------------------------------------------------------------------------------
# Returns the distinct exit codes a suite produced, in first-seen order. A suite is only healthy if it
# produced exactly ONE distinct code across every run -- 0 every time (green) or non-zero every time (a
# genuine, honest failure). Two different codes means the suite is deciding by coin flip.
flake_probe(){ # <path-to-suite> <runs> -> prints the distinct rcs, space separated
  local suite="$1" runs="$2" i rc seen=""
  for i in $(seq 1 "$runs"); do
    timeout 600 bash "$suite" >/dev/null 2>&1; rc=$?
    case " $seen " in *" $rc "*) ;; *) seen="${seen:+$seen }$rc" ;; esac
  done
  printf '%s' "$seen"
}

# --- selftest (lesson B1/C1: a checker that cannot prove it FIRES is decoration) --------------------------
# A gate whose detector has silently stopped matching reports "clean" -- the fail-open shape that dominated
# the audit. So: build a suite that is deliberately flaky and one that is deliberately stable, and assert
# this checker calls each correctly. Runs on every invocation, before the real scan.
selftest(){
  local d rcs st=0
  d="$(mktemp -d)" || { echo "flake-check: selftest could not mktemp -- INCONCLUSIVE, not clean" >&2; return 1; }

  # deterministic alternation, NOT $RANDOM: a random fixture makes the selftest itself flaky, which is the
  # exact defect under test. A counter file guarantees it fails on every other run and nothing else.
  # The counter path is BAKED IN rather than passed through the environment. The first attempt used
  # `FLAKE_COUNTER="$d/n" rcs="$(flake_probe ...)"`, which is not an env-prefixed command at all -- with an
  # assignment on the right-hand side there is no command word, so bash treats both as plain shell
  # assignments and never exports the first. The child `bash "$suite"` saw it unset, the fixture never
  # incremented, and it returned 0 every run: the selftest reported the detector broken when the detector
  # was fine. Caught only because the scan found a real flake in the same invocation.
  cat > "$d/flaky.sh" <<EOS
c="\$(cat '$d/n' 2>/dev/null || echo 0)"
echo \$((c+1)) > '$d/n'
[ \$((c % 2)) -eq 0 ] || exit 1
EOS
  printf 'exit 0\n'  > "$d/stable-green.sh"
  printf 'exit 1\n'  > "$d/stable-red.sh"

  rcs="$(flake_probe "$d/flaky.sh" 4)"
  case "$rcs" in
    *' '*) ;;  # two or more distinct codes -- correctly detected
    *) echo "FAIL: selftest -- flake_probe did NOT detect a known-flaky suite (saw only rc: $rcs)"; st=1 ;;
  esac

  rcs="$(flake_probe "$d/stable-green.sh" 3)"
  [ "$rcs" = "0" ] || { echo "FAIL: selftest -- a stable-green suite was misreported (rcs: $rcs)"; st=1; }

  # A consistently RED suite must NOT be called flaky. Conflating "broken" with "flaky" would send someone
  # hunting a race that does not exist while the real failure goes unread.
  rcs="$(flake_probe "$d/stable-red.sh" 3)"
  [ "$rcs" = "1" ] || { echo "FAIL: selftest -- a stable-red suite was misreported (rcs: $rcs)"; st=1; }

  rm -rf "$d"
  return $st
}

selftest || bad "flake-check selftest failed -- the detector is not trustworthy, so the scan below means nothing"
[ "${SELFTEST:-0}" = 1 ] && { [ "$fail" = 0 ] && echo "flake-check: selftest PASS"; exit "$fail"; }

# --- scan -------------------------------------------------------------------------------------------------
echo "flake-check: $RUNS runs per suite"
checked=0
for s in $SUITES; do
  suite="tests/$s.sh"
  # A missing suite is INCONCLUSIVE, never a silent pass: a renamed file would otherwise shrink coverage to
  # nothing while this still printed a clean summary.
  [ -f "$suite" ] || { bad "$s: no such suite at $suite -- cannot judge (renamed? deleted?)"; continue; }
  rcs="$(flake_probe "$suite" "$RUNS")"
  checked=$((checked+1))
  case "$rcs" in
    0)     printf '  stable green  %s\n' "$s" ;;
    *' '*) bad "$s is FLAKY -- $RUNS runs produced different exit codes: $rcs" ;;
    *)     printf '  stable RED    %s (rc=%s) -- a real failure, not a flake\n' "$s" "$rcs" ;;
  esac
done

# Zero suites checked would otherwise pass trivially and look clean (lesson: a scan that examined nothing
# must never report success).
[ "$checked" -gt 0 ] || bad "no suites were checked -- refusing to report clean"

if [ "$fail" = 0 ]; then
  echo "flake-check: PASS -- $checked suites, $RUNS runs each, every suite decided identically every time"
else
  echo "flake-check: FAIL -- see above. A flaky suite reds unrelated PRs; fix or quarantine it."
fi
exit "$fail"
