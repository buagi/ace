#!/usr/bin/env bash
# spec-debate-goldens.sh — goldens + CALIBRATION for the cross-model spec DEBATE (lib/debate.sh, spec mode).
# NIGHTLY/on-demand — the live debate needs two model providers, so this is NEVER per-PR (bash -n gates syntax).
#
# The debate (SPEC_DEBATE / REVIEW_DEBATE) is DEFAULT OFF. Before a project flips it on, it should be CALIBRATED
# like the rubric: does the debate's FINAL verdict (FLAGGED vs SOUND) agree with human judgment? >=90% agreement
# over >=4 labeled specs is the go/no-go. This harness IS that gate; it never enables the debate — it only
# measures whether enabling it would be trustworthy.
#
# Fixtures (tests/snapshots/debate/):
#   inputs/<name>.md   a HIGH-risk feature spec (the debate only runs on risk:HIGH specs)
#   <name>.label       the HUMAN verdict: FLAGGED (the spec has real issues) | SOUND
#   <name>.out         a RECORDED debate synthesis (DEBATEISSUE lines, or 'SOUND'); seeded here, captured nightly
#
#   spec-debate-goldens.sh              (--check)     validate each recorded output's SCHEMA + that its verdict
#                                                     matches the human label; print agreement %.
#   spec-debate-goldens.sh --calibrate               same, then a GO/HOLD verdict for enabling SPEC_DEBATE=1.
#   spec-debate-goldens.sh --capture                 run the LIVE debate over inputs/*.md → <name>.out
#                                                     (needs opencode + DEBATE_MODEL_B + OPENROUTER_API_KEY).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
DIR="tests/snapshots/debate"; INP="$DIR/inputs"
MODE=check; case "${1:-}" in --capture) MODE=capture ;; --calibrate) MODE=calibrate ;; esac
fail=0; bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }

# a recorded output is either 'SOUND' (verdict SOUND) or >=1 well-formed DEBATEISSUE line (verdict FLAGGED).
verdict_of(){ # <outfile>  → prints FLAGGED|SOUND|BAD
  local f="$1" n
  if grep -qiE '^DEBATEISSUE[[:space:]]+(blocker|major|minor)[[:space:]]' "$f" 2>/dev/null; then
    # every non-blank line must be a valid DEBATEISSUE (no stray prose in a synthesis output)
    n="$(grep -vE '^[[:space:]]*$' "$f" | grep -vcE '^DEBATEISSUE[[:space:]]+(blocker|major|minor)[[:space:]]' 2>/dev/null || true)"
    [ "${n:-0}" -eq 0 ] 2>/dev/null && echo FLAGGED || echo BAD
  elif grep -qiE '^[[:space:]]*SOUND[[:space:]]*$' "$f" 2>/dev/null; then echo SOUND
  else echo BAD; fi
}

if [ "$MODE" = capture ]; then
  { command -v opencode >/dev/null 2>&1 && [ -n "${DEBATE_MODEL_B:-}${OPENROUTER_API_KEY:-}" ]; } \
    || { echo "spec-debate-goldens: needs opencode + DEBATE_MODEL_B + OPENROUTER_API_KEY — live capture unavailable. SKIP."; exit 0; }
  ls "$INP"/*.md >/dev/null 2>&1 || { echo "spec-debate-goldens: no input specs in $INP. SKIP."; exit 0; }
  for s in "$INP"/*.md; do
    base="$(basename "$s" .md)"
    out="$(SPEC_DEBATE=1 bash "$ROOT/lib/debate.sh" spec "$s" 2>/dev/null | sed -E 's/^SPECGAP [^ ]+ DEBATE:/DEBATEISSUE /')"
    [ -n "$out" ] || out=SOUND
    printf '%s\n' "$out" > "$DIR/$base.out" && echo "captured $base.out"
  done
  echo "spec-debate-goldens: captured. Review each vs its .label, then commit $DIR/*.out."
  exit 0
fi

# --- check / calibrate ---
ls "$DIR"/*.out >/dev/null 2>&1 || { echo "spec-debate-goldens: no recorded debates yet — nightly '--capture' seeds them (needs keys). SKIP."; exit 0; }
n=0 agree=0
for f in "$DIR"/*.out; do
  base="$(basename "$f" .out)"; n=$((n+1))
  got="$(verdict_of "$f")"
  [ "$got" = BAD ] && { bad "$base: malformed synthesis output (want 'SOUND' or well-formed DEBATEISSUE lines)"; continue; }
  lbl="$(tr -d '[:space:]' < "$DIR/$base.label" 2>/dev/null)"
  [ -n "$lbl" ] || { bad "$base: no human label ($DIR/$base.label)"; continue; }
  # a MISS is a REGRESSION, not a note: the harness is the calibration gate, so disagreement with the human
  # label must make it exit non-zero. Printing only (the old behaviour) let agent-goldens.yml stay green at 0%.
  if [ "$got" = "$lbl" ]; then agree=$((agree+1)); else bad "$base: debate said $got, human label $lbl"; fi
done

pct=0; [ "$n" -gt 0 ] && pct=$(( agree * 100 / n ))
printf 'spec-debate-goldens: %d/%d agree with human labels (%d%%) over %d golden(s)\n' "$agree" "$n" "$pct" "$n"

if [ "$MODE" = calibrate ]; then
  if [ "$fail" = 0 ] && [ "$n" -ge 4 ] && [ "$pct" -ge "${DEBATE_CALIBRATION_MIN:-90}" ]; then
    echo "CALIBRATION: GO — >=${DEBATE_CALIBRATION_MIN:-90}% agreement over >=4 goldens. Enabling SPEC_DEBATE=1 / REVIEW_DEBATE=1 is defensible for this labeled set."
  else
    echo "CALIBRATION: HOLD — keep SPEC_DEBATE/REVIEW_DEBATE=0 (default). Need schema-clean + >=4 goldens + >=${DEBATE_CALIBRATION_MIN:-90}% agreement (have ${n} goldens, ${pct}%)."
    # A HOLD verdict is a FAILED calibration: exit non-zero so the nightly goes red. Otherwise deleting
    # the hard goldens shrinks the denominator, prints 100%, still says HOLD, and the job stays green --
    # the same fixture-erosion fail-open this harness fixes for MISS.
    fail=1
  fi
fi

[ "$fail" = 0 ] || { echo "spec-debate-goldens: FAIL — a debate golden's schema or label agreement regressed. Re-run to confirm (flake guard)."; exit 1; }
echo "spec-debate-goldens: PASS (schema + label agreement hold)"; exit 0
