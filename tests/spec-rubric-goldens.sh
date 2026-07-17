#!/usr/bin/env bash
# spec-rubric-goldens.sh — goldens + CALIBRATION for the optional LLM spec rubric (Part H / H5 Edit 5).
# NIGHTLY/on-demand — the live rubric needs a model call, so this is NEVER per-PR (bash -n keeps it syntax-gated).
#
# The rubric (swarm_spec_rubric) is DEFAULT OFF. Before any project flips SPEC_RUBRIC=1 it must be CALIBRATED:
# the plan's go/no-go is ">=90% agreement with human-labeled goldens" over >=4 specs. This harness IS that gate.
# It NEVER enables the rubric — it only measures whether enabling it would be trustworthy.
#
# Fixtures (tests/snapshots/rubric/):
#   inputs/<name>.md   a HIGH-risk feature spec (the rubric only judges risk:HIGH specs)
#   <name>.label       the HUMAN verdict for that spec: PASS | GAPS
#   <name>.json        a RECORDED rubric output (schema-checked; captured nightly, seeded here so --check runs)
#
#   spec-rubric-goldens.sh              (--check)     validate every recorded output's JSON SCHEMA + that its
#                                                     verdict matches the human label; print calibration %.
#   spec-rubric-goldens.sh --calibrate               same, then a GO/HOLD verdict for flipping SPEC_RUBRIC=1.
#   spec-rubric-goldens.sh --capture                 run the LIVE rubric over inputs/*.md → <name>.json
#                                                     (needs DEEPSEEK_API_KEY; SKIP clean without it).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
DIR="tests/snapshots/rubric"; INP="$DIR/inputs"
MODE=check; case "${1:-}" in --capture) MODE=capture ;; --calibrate) MODE=calibrate ;; esac
fail=0; bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }
CRITERIA='testable_acs scope_tightness contract_clarity edge_coverage grounded_integration prior_art_justified increments_shippable'

command -v jq >/dev/null 2>&1 || { echo "spec-rubric-goldens: jq not found — cannot validate rubric JSON. SKIP."; exit 0; }

# schema: verdict PASS|GAPS · all 7 criteria scored 1-3 · gaps is an array · PASS ⇒ no criterion is 1 · GAPS ⇒ >=1 gap
schema_ok(){ # <jsonfile> <base>
  local f="$1" base="$2" v
  jq -e . "$f" >/dev/null 2>&1 || { bad "$base: not valid JSON (rubric must emit strict JSON)"; return; }
  v="$(jq -r '.verdict // empty' "$f" 2>/dev/null)"
  case "$v" in PASS|GAPS) ;; *) bad "$base: verdict must be PASS|GAPS (got '$v')"; return ;; esac
  local c s
  for c in $CRITERIA; do
    s="$(jq -r --arg c "$c" '.scores[$c] // empty' "$f" 2>/dev/null)"
    case "$s" in 1|2|3) ;; *) bad "$base: criterion '$c' must score 1-3 (got '$s')" ;; esac
  done
  jq -e '.gaps | type == "array"' "$f" >/dev/null 2>&1 || bad "$base: .gaps must be an array"
  if [ "$v" = PASS ]; then
    jq -e "[.scores[]] | any(. == 1) | not" "$f" >/dev/null 2>&1 || bad "$base: verdict PASS but a criterion scored 1 (contradiction)"
  else
    jq -e '(.gaps | length) >= 1' "$f" >/dev/null 2>&1 || bad "$base: verdict GAPS but .gaps is empty"
  fi
}

if [ "$MODE" = capture ]; then
  { [ -n "${DEEPSEEK_API_KEY:-}" ] && command -v curl >/dev/null 2>&1; } || { echo "spec-rubric-goldens: no DEEPSEEK_API_KEY — live capture unavailable. SKIP."; exit 0; }
  . "$ROOT/lib/swarm.sh" 2>/dev/null || { echo "spec-rubric-goldens: cannot source swarm.sh. SKIP."; exit 0; }
  ls "$INP"/*.md >/dev/null 2>&1 || { echo "spec-rubric-goldens: no input specs in $INP. SKIP."; exit 0; }
  for s in "$INP"/*.md; do
    base="$(basename "$s" .md)"
    # the rubric only judges risk:HIGH specs; the JSON primitive emits the raw verdict (no SPEC_RUBRIC gate needed).
    out="$(swarm_spec_rubric_json "$s" 2>/dev/null)"
    [ -n "$out" ] && printf '%s\n' "$out" | jq . > "$DIR/$base.json" 2>/dev/null && echo "captured $base.json"
  done
  echo "spec-rubric-goldens: captured. Review each vs its .label, then commit $DIR/*.json."
  exit 0
fi

# --- check / calibrate ---
ls "$DIR"/*.json >/dev/null 2>&1 || { echo "spec-rubric-goldens: no recorded rubric outputs yet — nightly '--capture' seeds them (needs a key). SKIP."; exit 0; }
n=0 agree=0
for f in "$DIR"/*.json; do
  base="$(basename "$f" .json)"; n=$((n+1))
  schema_ok "$f" "$base"
  lbl="$(cat "$DIR/$base.label" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$lbl" ] || { bad "$base: no human label ($DIR/$base.label) to calibrate against"; continue; }
  got="$(jq -r '.verdict // empty' "$f" 2>/dev/null)"
  if [ "$got" = "$lbl" ]; then agree=$((agree+1)); else printf 'MISS: %s — rubric said %s, human label %s\n' "$base" "$got" "$lbl"; fi
done

pct=0; [ "$n" -gt 0 ] && pct=$(( agree * 100 / n ))
printf 'spec-rubric-goldens: %d/%d agree with human labels (%d%%) over %d golden(s)\n' "$agree" "$n" "$pct" "$n"

if [ "$MODE" = calibrate ]; then
  if [ "$fail" = 0 ] && [ "$n" -ge 4 ] && [ "$pct" -ge "${RUBRIC_CALIBRATION_MIN:-90}" ]; then
    echo "CALIBRATION: GO — >=${RUBRIC_CALIBRATION_MIN:-90}% agreement over >=4 goldens. Enabling SPEC_RUBRIC=1 is defensible for this labeled set."
  else
    echo "CALIBRATION: HOLD — keep SPEC_RUBRIC=0 (default). Need schema-clean + >=4 goldens + >=${RUBRIC_CALIBRATION_MIN:-90}% agreement (have ${n} goldens, ${pct}%)."
  fi
fi

[ "$fail" = 0 ] || { echo "spec-rubric-goldens: FAIL — a rubric golden's schema or label agreement regressed. Re-run to confirm (flake guard)."; exit 1; }
echo "spec-rubric-goldens: PASS (schema + label agreement hold)"; exit 0
