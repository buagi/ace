#!/usr/bin/env bash
# eval-ab-parth.sh — the H8 end-to-end A/B: does the Part H research-first spec pipeline actually improve
# first-pass quality and/or lower spend per feature? It runs the SAME sealed task set twice through F1's
# harness — A: Part H OFF · B: Part H ON — then feeds both result TSVs to the paired comparator (eval-ab.sh:
# exact McNemar on quality + bootstrap CI on cost). Part H is knob-toggled (SPEC_LINT/SPEC_SLICE/SPEC_RUBRIC),
# so the two arms differ ONLY in the harness — NO branch switch, identical task set, paired by construction.
#
# NIGHTLY / on-demand — real runs need opencode + provider keys. `--stub` proves the plumbing OFFLINE (both
# arms apply the task's reference.patch, so they come out identical → a correct INDISTINGUISHABLE that
# validates the isolate→run→grade→compare pipeline without credits).
#
#   tests/eval-ab-parth.sh [--k N] [--stub] [--tasks DIR]
#
# Pre-registration + decision rule: tests/eval/experiments/parth-pipeline.md (fill the minimum actionable
# effect BEFORE a real run). Record the verdict + CIs to .opencode/experiments/parth-pipeline.md.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
K=5; STUB=""; TASKS=""
usage(){ echo "usage: eval-ab-parth.sh [--k N] [--stub] [--tasks DIR]" >&2; }
# Same trap as eval-run.sh: a TRAILING `--k`/`--tasks` leaves $#=1, `shift 2` shifts nothing and returns 1,
# and without `set -e` the loop re-reads the same argument FOREVER. Demand a value instead of hanging.
need(){ # <flagname> [candidate-value]
  [ "$#" -ge 2 ] && [ -n "${2:-}" ] && case "$2" in --*) false ;; *) true ;; esac \
    || { echo "eval-ab-parth: $1 requires a value" >&2; usage; exit 1; }
}
while [ $# -gt 0 ]; do case "$1" in
  --k)     need --k     "${2:-}"; K="$2";     shift 2 ;;
  --tasks) need --tasks "${2:-}"; TASKS="$2"; shift 2 ;;
  --stub)  STUB=--stub; shift ;;
  -h|--help) usage; exit 0 ;;
  *) shift ;;
esac; done
A="$ROOT/.opencode/eval-parth-A-off.tsv"; B="$ROOT/.opencode/eval-parth-B-on.tsv"
topt=(); [ -n "$TASKS" ] && topt=(--tasks "$TASKS")

echo "── H8 A/B · Part H spec pipeline OFF vs ON · k=$K ${STUB:+(stub — offline plumbing)} ──"
# An arm that ABORTS mid-run (refused real run, unsealable task) still leaves a partial TSV behind. Comparing
# those yields a narrower but equally confident report over whatever survived — so fail fast on a bad arm.
run_arm(){ # <label> <out> <env...>   — NOT piped: a `| tail -1` would run this in a subshell where `exit` is a no-op
  local label="$1" out="$2"; shift 2
  local log rc
  log="$(env "$@" bash "$ROOT/tests/eval-run.sh" ${STUB:+$STUB} --k "$K" "${topt[@]}" --out "$out" 2>&1)"; rc=$?
  printf '%s\n' "$log" | tail -1
  [ "$rc" -eq 0 ] || { printf '%s\n' "$log" >&2; echo "eval-ab-parth: arm $label FAILED (exit $rc) — refusing to compare a partial run." >&2; exit "$rc"; }
}
echo "A (Part H OFF): SPEC_LINT=0 SPEC_SLICE=0 SPEC_RUBRIC=0  → no deterministic spec gate, no slice"
run_arm A "$A" SPEC_LINT=0 SPEC_SLICE=0 SPEC_RUBRIC=0
echo "B (Part H ON):  SPEC_LINT=1 SPEC_SLICE=1 SPEC_RUBRIC=0  → gate + slice (rubric stays OFF until calibrated)"
run_arm B "$B" SPEC_LINT=1 SPEC_SLICE=1 SPEC_RUBRIC=0
echo
# --stub is the documented OFFLINE plumbing proof, so it opts into eval-ab's stub-row refusal on purpose.
EVAL_ALLOW_STUB="${STUB:+1}" bash "$ROOT/tests/eval-ab.sh" "$A" "$B"
echo
echo "── pre-registration + decision rule: tests/eval/experiments/parth-pipeline.md ──"
echo "   record the verdict + CIs to .opencode/experiments/parth-pipeline.md (experiments README)."
