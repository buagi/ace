#!/usr/bin/env bash
# debate-effectiveness.sh — measure the cross-model debate's EFFECTIVENESS against ground truth, and log it over
# time so improvement is visible. The activity metrics (rounds/convergence/cost) live in debate-metrics.jsonl +
# `ace debate report`; THIS scores CORRECTNESS: did the debate flag the seeded-flawed specs (recall) and pass
# the clean ones (precision)?  NIGHTLY/on-demand — the live run needs keys; --score runs offline on recorded .out.
#
# Ground truth: the runnable sandbox at tests/debate-sandbox/ — authored specs, labeled in labels.tsv:
#   <slug><TAB>FLAGGED|SOUND<TAB>expected-issue-keyword('-' for SOUND)
# A FLAGGED spec is a TRUE POSITIVE only if the debate FLAGGED it AND (no keyword, or the verdict names it) —
# recall on the RIGHT issue, not just "flagged something".
#
#   debate-effectiveness.sh --capture   run the LIVE debate over each sandbox spec → tests/snapshots/debate-eval/<slug>.out
#   debate-effectiveness.sh             (--score) confusion matrix → precision·recall·F1·accuracy (+ convergence·
#                                        avg-cost from debate-metrics), append a timestamped row to the history,
#                                        print the scorecard + GO/HOLD (F1 >= DEBATE_F1_MIN).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
SB="tests/debate-sandbox"; SPECS="$SB/specs"; OUT="tests/snapshots/debate-eval"; LABELS="$SB/labels.tsv"
HIST="$SB/effectiveness-history.jsonl"
MODE=score; [ "${1:-}" = --capture ] && MODE=capture
_dcfg(){ grep -E "^$1=" "${ACE_CONFIG:-$HOME/.config/ace/config}" 2>/dev/null | tail -1 | cut -d= -f2-; }

[ -f "$LABELS" ] || { echo "debate-effectiveness: no $LABELS — the sandbox is missing. SKIP."; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "debate-effectiveness: jq required."; exit 1; }

verdict_of(){ # <outfile> → FLAGGED|SOUND|BAD
  local f="$1"
  grep -qiE '^DEBATEISSUE[[:space:]]+(blocker|major|minor)[[:space:]]' "$f" 2>/dev/null && { echo FLAGGED; return; }
  grep -qiE '^[[:space:]]*SOUND[[:space:]]*$' "$f" 2>/dev/null && { echo SOUND; return; }
  echo BAD
}

if [ "$MODE" = capture ]; then
  { command -v opencode >/dev/null 2>&1 && [ -n "${DEBATE_MODEL_B:-}$(_dcfg DEBATE_MODEL_B)" ]; } \
    || { echo "debate-effectiveness: needs opencode + DEBATE_MODEL_B (+ OPENROUTER_API_KEY) — live capture unavailable. SKIP."; exit 0; }
  mkdir -p "$OUT"
  while IFS=$'\t' read -r slug label kw; do
    [ -n "$slug" ] || continue; case "$slug" in \#*) continue ;; esac
    s="$SPECS/$slug.md"; [ -f "$s" ] || { echo "skip $slug (no $s)"; continue; }
    o="$(SPEC_DEBATE=1 bash "$ROOT/lib/debate.sh" spec "$s" 2>/dev/null | sed -E 's/^SPECGAP [^ ]+ DEBATE:/DEBATEISSUE /')"
    [ -n "$o" ] || o=SOUND
    printf '%s\n' "$o" > "$OUT/$slug.out" && echo "captured $slug.out"
  done < "$LABELS"
  echo "debate-effectiveness: captured. Review each vs its label, commit $OUT/*.out, then --score."
  exit 0
fi

# --- score ---
ls "$OUT"/*.out >/dev/null 2>&1 || { echo "debate-effectiveness: no recorded debates in $OUT — nightly '--capture' seeds them (needs keys). SKIP."; exit 0; }
tp=0 fp=0 fn=0 tn=0 n=0 bad=0
while IFS=$'\t' read -r slug label kw; do
  [ -n "$slug" ] || continue; case "$slug" in \#*) continue ;; esac
  o="$OUT/$slug.out"; [ -f "$o" ] || { echo "MISS-FIXTURE: $slug (no recorded .out)"; continue; }
  n=$((n+1)); v="$(verdict_of "$o")"
  if [ "$v" = BAD ]; then bad=$((bad+1)); echo "BAD: $slug — unparseable verdict"; continue; fi
  case "$label" in
    FLAGGED)
      if [ "$v" = FLAGGED ] && { [ "$kw" = "-" ] || grep -qi -- "$kw" "$o"; }; then tp=$((tp+1))
      else fn=$((fn+1)); printf 'FN: %s — expected FLAGGED(%s), got %s%s\n' "$slug" "$kw" "$v" "$([ "$v" = FLAGGED ] && echo ' (flagged, but not the seeded issue)')"; fi ;;
    SOUND)
      if [ "$v" = SOUND ]; then tn=$((tn+1)); else fp=$((fp+1)); printf 'FP: %s — expected SOUND, debate FLAGGED (over-flag / hallucination)\n' "$slug"; fi ;;
    *) echo "BAD-LABEL: $slug ($label)"; ;;
  esac
done < "$LABELS"

# precision/recall/F1/accuracy (integer math ×1000 → 3-dp)
_div(){ [ "$2" -gt 0 ] 2>/dev/null && echo $(( $1 * 1000 / $2 )) || echo 0; }   # returns per-mille
prec="$(_div "$tp" "$(( tp + fp ))")"; rec="$(_div "$tp" "$(( tp + fn ))")"
f1=0; [ "$(( prec + rec ))" -gt 0 ] && f1=$(( 2 * prec * rec / ( prec + rec ) ))
acc="$(_div "$(( tp + tn ))" "$n")"
_fmt(){ printf '%d.%03d' "$(( $1 / 1000 ))" "$(( $1 % 1000 ))"; }

# activity join from the per-debate metrics (if present) — convergence rate + avg cost(s)
conv_rate=0 avg_cost=0
if [ -f .opencode/cache/debate-metrics.jsonl ]; then
  conv_rate="$(jq -s 'if length==0 then 0 else (map(select(.converged))|length)*100/length|floor end' .opencode/cache/debate-metrics.jsonl 2>/dev/null || echo 0)"
  avg_cost="$(jq -s 'if length==0 then 0 else (map(.duration_s)|add)/length|floor end' .opencode/cache/debate-metrics.jsonl 2>/dev/null || echo 0)"
fi

# append a timestamped effectiveness record (config snapshot + scores) — the improvement-over-time log
mkdir -p "$SB"
jq -nc --arg ts "$(date -u +%FT%TZ)" \
   --arg a "${DEBATE_MODEL_A:-$(_dcfg DEBATE_MODEL_A)}" --arg b "${DEBATE_MODEL_B:-$(_dcfg DEBATE_MODEL_B)}" \
   --argjson min "${DEBATE_MIN:-2}" --argjson max "${DEBATE_MAX:-4}" --argjson hard "${DEBATE_HARD_MAX:-10}" \
   --argjson n "$n" --argjson tp "$tp" --argjson fp "$fp" --argjson fn "$fn" --argjson tn "$tn" \
   --argjson precision "$prec" --argjson recall "$rec" --argjson f1 "$f1" --argjson accuracy "$acc" \
   --argjson conv "$conv_rate" --argjson cost "$avg_cost" \
   '{ts:$ts,model_a:$a,model_b:$b,knobs:{min:$min,max:$max,hard:$hard},n:$n,tp:$tp,fp:$fp,fn:$fn,tn:$tn,
     precision:($precision/1000),recall:($recall/1000),f1:($f1/1000),accuracy:($accuracy/1000),
     convergence_pct:$conv,avg_cost_s:$cost}' >> "$HIST" 2>/dev/null || true

echo "── debate effectiveness · n=$n · TP=$tp FP=$fp FN=$fn TN=$tn ──"
printf '  precision %s · recall %s · F1 %s · accuracy %s' "$(_fmt "$prec")" "$(_fmt "$rec")" "$(_fmt "$f1")" "$(_fmt "$acc")"
[ "$avg_cost" -gt 0 ] 2>/dev/null && printf ' · convergence %s%% · avg-cost %ss' "$conv_rate" "$avg_cost"
echo; echo "  logged → $HIST"
if [ "$bad" -gt 0 ]; then echo "debate-effectiveness: $bad unparseable verdict(s) — FAIL"; exit 1; fi
f1min="${DEBATE_F1_MIN:-750}"   # per-mille (0.750)
if [ "$f1" -ge "$f1min" ]; then echo "  VERDICT: GO — F1 $(_fmt "$f1") >= $(_fmt "$f1min") on $n labeled specs."
else echo "  VERDICT: HOLD — F1 $(_fmt "$f1") < $(_fmt "$f1min"); review the FP/FN above (\`ace debate review\`) and tune before enabling."; fi
exit 0
