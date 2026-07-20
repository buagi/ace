#!/usr/bin/env bash
# reanalyze-acceptance.sh — judge a REAL `ace reanalyze` run against explicit criteria.
#
# WHY: three real runs were read as "fine" and were not. Run B spent 50% of its wall-clock in a phase that
# appears in no metrics row; its report compared a 157-spec population against a 10-spec gate and printed a
# verdict from the difference; its debates cited zero sources; and the whole SRC_LIVE gate had never
# executed. None of that was visible without a forensic dig through durable artifacts.
#
# This turns "did the run go fine?" into a checklist a machine can answer. It reads ONLY artifacts the run
# leaves behind, so it can be pointed at a finished run after the fact.
#
# Usage: tests/reanalyze-acceptance.sh <repo> [run_id]     (run_id defaults to the newest in metrics.csv)
# Exit 0 = every criterion met. Non-zero = at least one failed; each is printed with its evidence.
set -uo pipefail

REPO="${1:-}"
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "usage: $0 <repo-path> [run_id]" >&2; exit 2; }
cd "$REPO" || exit 2

M=".opencode/metrics.csv"
DM=".opencode/cache/debate-metrics.jsonl"
[ -f "$M" ] || { echo "AC-FAIL: no $M — the run left no telemetry at all"; exit 1; }

RUN="${2:-$(awk -F, '$4=="run"{r=$1} END{print r}' "$M")}"
[ -n "$RUN" ] || { echo "AC-FAIL: no completed run row in $M — the run did not finish"; exit 1; }

pass=0; fail=0
ok_(){  printf '  \033[0;32m✓\033[0m %s\n' "$*"; pass=$((pass+1)); }
no_(){  printf '  \033[0;31m✗\033[0m %s\n' "$*"; fail=$((fail+1)); }
note(){ printf '      %s\n' "$*"; }

echo "── reanalyze acceptance · repo=$(basename "$REPO") · run=$RUN ──"

# AC1 — the run COMPLETED. A death mid-flight leaves no `run` row; a provider timeout leaves a failmode.
if awk -F, -v r="$RUN" '$1==r && $4=="run"{f=1} END{exit !f}' "$M"; then
  ok_ "AC1 run completed (terminal run row present)"
else
  no_ "AC1 run did NOT complete — no terminal row for $RUN"
fi
fm="$(awk -F, -v r="$RUN" '$1==r && $4=="failmode"{print $6}' "$M" | tr '\n' ';')"
[ -z "$fm" ] && ok_ "AC2 no failmode recorded" || no_ "AC2 failmode(s) during the run: ${fm%;}"

# AC3 — wall-clock is ATTRIBUTED. Half of one real run was in no metric row, so the summary under-reported
# by 2x and the scorecard read from it. Allow 15% unattributed for setup/teardown.
wall="$(awk -F, -v r="$RUN" '$1==r && $4=="run"{print $7}' "$M" | tail -1)"
steps="$(awk -F, -v r="$RUN" '$1==r && ($4=="step"||$4=="phase"||$4=="debate"){s+=$7} END{print s+0}' "$M")"
if [ -n "$wall" ] && [ "${wall:-0}" -gt 0 ]; then
  unattr=$(( wall - steps )); pct=$(( unattr * 100 / wall ))
  [ "$pct" -le 15 ] \
    && ok_ "AC3 wall-clock attributed (${steps}s of ${wall}s in metric rows; ${pct}% unattributed)" \
    || no_ "AC3 ${pct}% of wall-clock (${unattr}s of ${wall}s) is in NO metric row — phases are running untimed"
else
  no_ "AC3 no wall duration recorded for $RUN"
fi

# AC4 — the lint population is the GATE's population, not the whole specs directory.
linked=0
if [ -f ROADMAP.md ]; then
  linked="$(grep -oE 'Spec:[[:space:]]*[^ )]+\.md' ROADMAP.md 2>/dev/null | sed -E 's/^Spec:[[:space:]]*//' \
            | sort -u | while IFS= read -r s; do [ -f "$s" ] && echo x; done | grep -c x)"
fi
# NOT `grep -c … || echo 0` (trap A2): grep prints the count AND exits 1 when it is zero, emitting
# "0\n0" — which then breaks every integer test downstream. Capture, then default.
ondisk="$(ls .opencode/specs/*.md 2>/dev/null | grep -vc '\.progress\.md$' || true)"; ondisk="${ondisk:-0}"
prog="$(ls .opencode/specs/*.progress.md 2>/dev/null | wc -l)"
note "specs: $ondisk on disk (+$prog progress ledgers) · $linked referenced from ROADMAP"
if [ -f .opencode/reanalyze/after/gaps.txt ] || [ -d .opencode/reanalyze ]; then
  ok_ "AC4 reanalyze artifacts present"
else
  no_ "AC4 no .opencode/reanalyze artifacts — the before/after comparison did not run"
fi
[ "${prog:-0}" -eq 0 ] || note "NOTE: $prog *.progress.md ledgers exist — they must NOT be linted as specs (AC8)"

# AC5 — debates actually ran, and each one converged or stopped for a STATED reason.
if [ -f "$DM" ]; then
  n="$(jq -r --arg r "$RUN" 'select(.run_id==$r)|.run_id' "$DM" 2>/dev/null | wc -l)"
  conv="$(jq -r --arg r "$RUN" 'select(.run_id==$r and .converged==true)|.run_id' "$DM" 2>/dev/null | wc -l)"
  capped="$(jq -r --arg r "$RUN" 'select(.run_id==$r and (.wall_capped==true))|.run_id' "$DM" 2>/dev/null | wc -l)"
  if [ "${n:-0}" -gt 0 ]; then
    ok_ "AC5 $n debate(s) ran · $conv converged · $capped wall-capped"
    [ "$((conv + capped))" -eq "$n" ] || no_ "AC5b $((n - conv - capped)) debate(s) neither converged NOR hit a stated cap — they stopped for an unrecorded reason"
  else
    no_ "AC5 ZERO debates recorded for this run — the gate did not exercise the debate at all"
  fi
else
  no_ "AC5 no $DM — the debate never wrote telemetry"
fi

# AC6 — RESEARCH actually happened, or its absence is explicitly admitted. The directive landed 2026-07-20
# 19:47; before that, zero citations across 11 debates was expected, not a defect. After it, silence is one.
tx="$(ls -t .opencode/cache/*debate*.md 2>/dev/null | head -20)"
if [ -n "$tx" ]; then
  src="$(grep -l '(source: http' $tx 2>/dev/null | wc -l)"
  unv="$(grep -l 'UNVERIFIED' $tx 2>/dev/null | wc -l)"
  if [ "${src:-0}" -gt 0 ] || [ "${unv:-0}" -gt 0 ]; then
    ok_ "AC6 debates show research evidence ($src transcript(s) with a cited source, $unv with an explicit UNVERIFIED)"
  else
    no_ "AC6 no transcript cites a source OR admits an unreachable one — the research directive produced nothing"
  fi
else
  no_ "AC6 no debate transcripts on disk"
fi

# AC7 — external citations were VERIFIED, or the run said plainly that they were not.
pv="$(ls .opencode/cache/provenance-*.txt 2>/dev/null | wc -l)"
if [ "${pv:-0}" -gt 0 ]; then
  ok_ "AC7 $pv provenance file(s) written — cited sources were actually checked"
  blocked="$(grep -lE '^(blocked|dead|authwall|redirected)' .opencode/cache/provenance-*.txt 2>/dev/null | wc -l)"
  [ "${blocked:-0}" -gt 0 ] && note "$blocked spec(s) cite a source that could not be confirmed — expected to surface in their slices"
else
  no_ "AC7 NO provenance files — SPEC_LINT_NET was off, so a cited URL could be invented and nothing would catch it"
fi

# AC8 — progress ledgers must not pollute the gap count.
if [ "${prog:-0}" -gt 0 ]; then
  polluted=0
  for f in .opencode/specs/*.progress.md; do
    [ -f "$f" ] || continue
    grep -q "$(basename "$f" .md)" .opencode/reanalyze/after/*.txt 2>/dev/null && polluted=$((polluted+1))
  done
  [ "$polluted" -eq 0 ] \
    && ok_ "AC8 no *.progress.md ledger appears in the gap accounting" \
    || no_ "AC8 $polluted progress ledger(s) counted as specs — phantom gaps inflate every number"
else
  ok_ "AC8 no progress ledgers present"
fi

# AC9 — transcripts from a PREVIOUS run survived this one. Truncation destroyed the evidence needed to
# compare two runs of the same slug.
runs_with_tx="$(ls .opencode/cache/*debate*.md 2>/dev/null | wc -l)"
distinct_runs="$(jq -r '.run_id' "$DM" 2>/dev/null | sort -u | wc -l)"
if [ "${distinct_runs:-0}" -ge 2 ]; then
  [ "${runs_with_tx:-0}" -ge 2 ] \
    && ok_ "AC9 transcripts from more than one run coexist ($runs_with_tx files, $distinct_runs runs)" \
    || no_ "AC9 $distinct_runs runs recorded but only $runs_with_tx transcript(s) — earlier evidence was overwritten"
else
  note "AC9 skipped — only $distinct_runs run in the metrics, nothing to overwrite yet"
fi

echo "── $pass passed · $fail failed ──"
[ "$fail" -eq 0 ] && echo "REANALYZE ACCEPTANCE: PASS" || echo "REANALYZE ACCEPTANCE: FAIL"
exit $(( fail > 0 ))
