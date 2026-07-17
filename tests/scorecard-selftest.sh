#!/usr/bin/env bash
# scorecard-selftest.sh — fabricate a run's artifacts (specs · swarm events · logs) and assert ace_scorecard
# renders each section with the right numbers, fail-soft on missing bits. No network, deterministic.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok=1; bad(){ echo "[scorecard] $*"; ok=0; }
command -v jq >/dev/null 2>&1 || { echo "[scorecard] SKIP (jq absent)"; exit 0; }

d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/.opencode/specs" "$d/sw"

# a CLEAN spec (should lint 0 gaps) — reuse the sandbox's strong-authz shape
cp "$ROOT/tests/debate-sandbox/specs/strong-authz.md" "$d/.opencode/specs/authz.md" 2>/dev/null || \
  printf '<!-- ace-spec-template v1 -->\n# Spec (slug: authz · risk: HIGH · tier: FULL)\n' > "$d/.opencode/specs/authz.md"
# a GAPPY spec (vague ACs → gaps)
cp "$ROOT/tests/debate-sandbox/specs/vague-acs.md" "$d/.opencode/specs/vague.md" 2>/dev/null || true

# swarm events: w1 done, w2 conflict, w3 claimed-then-done
{
  printf '{"ts":1,"worker":"w1","feat":"A","phase":"claimed"}\n'
  printf '{"ts":2,"worker":"w2","feat":"B","phase":"claimed"}\n'
  printf '{"ts":3,"worker":"w1","feat":"A","phase":"done"}\n'
  printf '{"ts":4,"worker":"w2","feat":"B","phase":"conflict"}\n'
  printf '{"ts":5,"worker":"coordinator","feat":"","phase":"needs-attention","msg":"spec-lint: 2 gaps"}\n'
} > "$d/sw/events.jsonl"
printf 'COLLIDE  A ⨯ B\nOVERSIZE 6 files · C\n' > "$d/sw/batch-plan.txt"
# a worker log with verifier + critic verdicts
printf 'PASS\nAPPROVE\nCHANGES_REQUESTED [blocker] x.ts:1 · [major] y.ts:2 · [minor] z.ts:3\nresearcher: drafting spec\n' > "$d/sw/w1.log"
printf 'features=1 ci_fixes=2\n' > "$d/.opencode/run-summary.txt"
: > "$d/.opencode/metrics.csv"
mkdir -p "$d/.opencode/cache"
printf '{"slug":"a","converged":true,"wall_capped":false,"rounds":3,"issues_emitted":1,"per_round":[{"accepted":2,"disputed":1}]}\n{"slug":"b","converged":false,"wall_capped":true,"rounds":4,"issues_emitted":1,"per_round":[{"accepted":1,"disputed":2}]}\n' > "$d/.opencode/cache/debate-metrics.jsonl"

# score it
export C_BOLD='' C_RESET='' C_YELLOW='' C_GREY=''
out="$(SC_REPO="$d" SC_SWARM="$d/sw" bash -c 'source "'"$ROOT"'/lib/scorecard.sh"; ace_scorecard' 2>&1)"

printf '%s' "$out" | grep -q '① RESEARCH'                 || bad "research section missing"
printf '%s' "$out" | grep -q '② FEATURE BREAKDOWN'         || bad "feature section missing"
printf '%s' "$out" | grep -q 'HIT RATE 50%'               || { bad "hit-rate should be 50% (1 done of 2 terminal)"; printf '%s\n' "$out" | grep -i 'hit rate'; }
printf '%s' "$out" | grep -q '1 collision'                || bad "collision count wrong"
printf '%s' "$out" | grep -q 'PASS 1'                     || bad "verifier PASS count wrong"
printf '%s' "$out" | grep -qE '\[blocker\] 1'             || bad "blocker tally wrong"
printf '%s' "$out" | grep -q 'CI-fix retries 2'          || bad "ci-fix retries not read from run-summary"
printf '%s' "$out" | grep -q '⑤ DEBATE'                  || bad "debate section missing"
printf '%s' "$out" | grep -q 'converged 1 (50%)'         || bad "debate convergence wrong"
printf '%s' "$out" | grep -q '⑥ LOGGING'                 || bad "logging section missing"
printf '%s' "$out" | grep -qE 'completeness: [0-9]+/[0-9]+' || bad "logging completeness missing"
printf '%s' "$out" | grep -q '⑦ ANOMALIES'               || bad "anomalies section missing"
printf '%s' "$out" | grep -q 'needs-attention: 1'        || bad "anomaly count wrong"
printf '%s' "$out" | grep -q '⑧ EDGE CASES'              || bad "edge section missing"
printf '%s' "$out" | grep -q '══ VERDICT ══'             || bad "verdict missing"

# --json parses + carries the headline metrics
js="$(SC_REPO="$d" SC_SWARM="$d/sw" bash -c 'source "'"$ROOT"'/lib/scorecard.sh"; ace_scorecard --json' 2>&1)"
printf '%s' "$js" | jq -e '.hit_rate_pct=="50" and .debates==2 and (.anomalies>=1)' >/dev/null 2>&1 || { bad "--json wrong/invalid"; printf '%s\n' "$js"; }

# fail-soft: no swarm dir at all → subtasks degrades, no crash
out2="$(SC_REPO="$d" SC_SWARM="/nonexistent" bash -c 'source "'"$ROOT"'/lib/scorecard.sh"; ace_scorecard' 2>&1)" || bad "scorecard crashed on missing swarm dir"
printf '%s' "$out2" | grep -q 'no swarm events'          || bad "missing-swarm not fail-soft"

[ "$ok" = 1 ] && echo "[scorecard] PASS ✓" || { echo "[scorecard] FAIL ✗"; exit 1; }
