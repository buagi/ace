#!/usr/bin/env bash
# scorecard-selftest.sh — fabricate a run's artifacts (specs · swarm events · logs) and assert ace_scorecard
# renders each section with the right numbers, fail-soft on missing bits. No network, deterministic.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok=1; bad(){ echo "[scorecard] $*"; ok=0; }
command -v jq >/dev/null 2>&1 || { echo "[scorecard] SKIP (jq absent)"; exit 0; }

d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/.opencode/specs" "$d/sw"

# The two lint fixtures. These used to be `cp … 2>/dev/null || printf <two-line stub>` / `|| true`, which is
# fail-open twice over: rename or delete a fixture and the copy silently degrades to a stub (or to nothing),
# and because no assertion below inspected spec CONTENT, the suite still went green while ② FEATURE
# BREAKDOWN was scoring a file the test invented. A fixture that is not there is a broken test, not a
# degraded one — say so and stop, rather than reporting on a specimen we substituted ourselves.
for _f in strong-authz:authz vague-acs:vague; do
  _src="$ROOT/tests/debate-sandbox/specs/${_f%%:*}.md"; _dst="$d/.opencode/specs/${_f##*:}.md"
  [ -f "$_src" ] || { echo "[scorecard] FIXTURE MISSING: $_src — refusing to substitute a stub"; exit 1; }
  cp "$_src" "$_dst" || { echo "[scorecard] could not copy fixture $_src"; exit 1; }
  [ -s "$_dst" ] || { echo "[scorecard] fixture copied empty: $_dst"; exit 1; }
done

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

# ---- ② must be checked against the SPEC CONTENT, not merely against its own section header ----------------
# Independently lint the same fixtures the scorecard scores, then require ② to report those numbers. This
# covers the parsing layer (scorecard.sh:56-60 sed/grep the lint text) and it is what makes a swapped fixture
# visible: previously nothing here read the specs at all.
ref="$(REPO="$d" bash "$ROOT/lib/swarm.sh" spec-lint "$d"/.opencode/specs/*.md 2>/dev/null)"
[ -n "$ref" ] || bad "reference spec-lint produced no output — ② cannot be verified against anything"
ref_gaps="$(printf '%s\n' "$ref" | grep -c '^SPECGAP')"
ref_ears="$(printf '%s\n' "$ref" | grep -cE 'SPECGAP.*EARS')"
ref_skel="$(printf '%s\n' "$ref" | grep -cE 'SPECGAP.*(SECTIONS|CBLOCKS)')"
# CONTENT ANCHOR: strong-authz/vague-acs are COMPLETE, template-conforming specs — they carry a handful of
# semantic gaps and zero structural ones. The two-line stub this file used to fall back to lints to 7
# SECTIONS + 6 CBLOCKS gaps, so a nonzero count here is the signature of a stub or a mangled fixture.
[ "$ref_skel" = 0 ]     || bad "fixtures are not template-complete specs ($ref_skel SECTIONS/CBLOCKS gaps) — stubbed or wrong fixture"
[ "$ref_gaps" -gt 0 ]   || bad "fixtures lint totally clean — ② would then report nothing to check"
[ "$ref_ears" -gt 0 ]   || bad "expected at least one EARS gap from the vague-AC fixture"
printf '%s' "$out" | grep -qF "total spec-gaps $ref_gaps" \
  || { bad "② misread the lint: expected 'total spec-gaps $ref_gaps'"; printf '%s\n' "$out" | grep -i 'spec-gaps'; }
printf '%s' "$out" | grep -qF "EARS $ref_ears)" \
  || { bad "② EARS tally does not match the lint (expected $ref_ears)"; printf '%s\n' "$out" | grep -i 'spec-gaps'; }
# ① reads citations out of the spec bodies — another content-derived number that nothing asserted
printf '%s' "$out" | grep -qE 'citations [1-9]' \
  || { bad "① counted no citations, but both fixtures carry a (source: …) line"; printf '%s\n' "$out" | grep -i citations; }
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
printf '%s' "$js" | jq -e --arg g "$ref_gaps" '.hit_rate_pct=="50" and .debates==2 and (.anomalies>=1) and .spec_gaps==$g' \
  >/dev/null 2>&1 || { bad "--json wrong/invalid (spec_gaps must equal the lint's $ref_gaps)"; printf '%s\n' "$js"; }

# fail-soft: no swarm dir at all → subtasks degrades, no crash
out2="$(SC_REPO="$d" SC_SWARM="/nonexistent" bash -c 'source "'"$ROOT"'/lib/scorecard.sh"; ace_scorecard' 2>&1)" || bad "scorecard crashed on missing swarm dir"
printf '%s' "$out2" | grep -q 'no swarm events'          || bad "missing-swarm not fail-soft"

[ "$ok" = 1 ] && echo "[scorecard] PASS ✓" || { echo "[scorecard] FAIL ✗"; exit 1; }
