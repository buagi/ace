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
while [ $# -gt 0 ]; do case "$1" in
  --k) K="${2:-5}"; shift 2 ;; --stub) STUB=--stub; shift ;; --tasks) TASKS="${2:-}"; shift 2 ;; *) shift ;;
esac; done
A="$ROOT/.opencode/eval-parth-A-off.tsv"; B="$ROOT/.opencode/eval-parth-B-on.tsv"
topt=(); [ -n "$TASKS" ] && topt=(--tasks "$TASKS")

echo "── H8 A/B · Part H spec pipeline OFF vs ON · k=$K ${STUB:+(stub — offline plumbing)} ──"
echo "A (Part H OFF): SPEC_LINT=0 SPEC_SLICE=0 SPEC_RUBRIC=0  → no deterministic spec gate, no slice"
SPEC_LINT=0 SPEC_SLICE=0 SPEC_RUBRIC=0 bash "$ROOT/tests/eval-run.sh" ${STUB:+$STUB} --k "$K" "${topt[@]}" --out "$A" | tail -1
echo "B (Part H ON):  SPEC_LINT=1 SPEC_SLICE=1 SPEC_RUBRIC=0  → gate + slice (rubric stays OFF until calibrated)"
SPEC_LINT=1 SPEC_SLICE=1 SPEC_RUBRIC=0 bash "$ROOT/tests/eval-run.sh" ${STUB:+$STUB} --k "$K" "${topt[@]}" --out "$B" | tail -1
echo
bash "$ROOT/tests/eval-ab.sh" "$A" "$B"
echo
echo "── pre-registration + decision rule: tests/eval/experiments/parth-pipeline.md ──"
echo "   record the verdict + CIs to .opencode/experiments/parth-pipeline.md (experiments README)."
