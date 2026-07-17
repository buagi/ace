#!/usr/bin/env bash
# Runs the hermetic swarm selftests — the resilience logic that guards against duplicate work and
# broken merges: the claim store, path-disjoint leasing, the merge-time ownership fence, plan-lint,
# the RED-main circuit breaker, at-most-one-owner, and the conflict policy. Fast, no network, no
# credits (each uses a throwaway SWARM_DIR / temp repo). Any single failure fails CI.
#
# This closes the gap where swarm.sh had selftests that CI never ran — so a regression in the
# leasing / fencing / plan-lint logic now turns CI red instead of shipping silently.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SW="$ROOT/lib/swarm.sh"

tests="selftest sched-selftest policy-selftest redmain-selftest abandon-selftest owns-selftest plan-lint-selftest spec-lint-selftest spec-slice-selftest spec-rubric-selftest debate-selftest scorecard-selftest reanalyze-selftest mergiraf-selftest"
fail=0
for t in $tests; do
  if out="$(bash "$SW" "$t" 2>&1)"; then
    printf '  \033[0;32m✓\033[0m %s\n' "$t"
  else
    printf '  \033[0;31m✗ %s\033[0m\n' "$t"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=1
  fi
done

if [ "$fail" = 0 ]; then
  echo "[swarm-selftests] all passed ✓"
else
  echo "[swarm-selftests] FAILURES ✗" >&2
  exit 1
fi
