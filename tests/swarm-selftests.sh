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

tests="selftest waittest sched-selftest policy-selftest redmain-selftest abandon-selftest owns-selftest plan-lint-selftest spec-lint-selftest spec-slice-selftest spec-rubric-selftest debate-selftest scorecard-selftest reanalyze-selftest hygiene-selftest mergiraf-selftest"
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

# Kill-safety lives in the COORDINATOR (lib/swarm-run.sh), not lib/swarm.sh, so it needs its own entry
# point — but it belongs in the same gate: it guards the stop/Ctrl-C path (deferred-trap ordering, so
# in-flight WIP is really committed and not just claimed; process-TREE kill; coordinator.pid + control.*
# cleanup). Hermetic and fast: throwaway SWARM_DIR, a fake worker, no network, no credits.
SR="$ROOT/lib/swarm-run.sh"
for t in killsafety-selftest; do
  if out="$(bash "$SR" "$t" 2>&1)"; then
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
