#!/usr/bin/env bash
# debate-autotune.sh — the AUTOMATIC (opt-in) half of debate self-improvement. A/B a candidate CONFIG KNOB on the
# labeled sandbox and KEEP it only if the debate gets MORE accurate without costing more. Debater PROMPT changes
# are never auto-applied — `--propose-prompt` emits a suggested diff + a ROADMAP item for a human PR (prompts are
# load-bearing, gated by prompt-contracts). Default OFF; this is the "then automatic" flip, run deliberately.
#
#   debate-autotune.sh [--stub] <KNOB>=<value>    # e.g. DEBATE_MODEL_B=openrouter/… · DEBATE_MAX=3
#   debate-autotune.sh --propose-prompt           # suggest a debater-prompt change from the recurring failures
#
# Live A/B needs keys (it captures fresh debates per arm). --stub proves the plumbing offline (both arms use the
# committed .out → identical → "indistinguishable" → keep baseline).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
HARNESS="$ROOT/tests/debate-effectiveness.sh"; AB="$ROOT/tests/eval-ab.sh"
STUB=""; PROPOSE=""; KV=""
while [ $# -gt 0 ]; do case "$1" in --stub) STUB=1 ;; --propose-prompt) PROPOSE=1 ;; *=*) KV="$1" ;; esac; shift; done
_cfg="${ACE_CONFIG:-$HOME/.config/ace/config}"

if [ -n "$PROPOSE" ]; then
  echo "── debate autotune · prompt PROPOSAL (human-gated) ──"
  diag="$(bash "$HARNESS" --diagnose 2>/dev/null)"
  if printf '%s' "$diag" | grep -q 'security lens'; then
    cat <<'P'
  Recurring SECURITY false-negatives detected. Proposed debater-prompt change (apply by hand in lib/install.sh,
  the `debater` agent's CHALLENGER paragraph — then `prompt-contracts` + a normal PR):

    + As CHALLENGER, ALWAYS run the security lens on a HIGH-risk spec: per-object authz (BOLA/IDOR),
    + webhook signature verification + dedupe, session rotation on password change, idempotency on money
    + paths, secrets never logged. A missing one on the relevant surface is at least [major].

P
    if [ -f "$ROOT/ROADMAP.md" ]; then
      grep -q 'debater prompt: strengthen the security lens' "$ROOT/ROADMAP.md" 2>/dev/null \
        || printf -- '- [ ] fix(debate): strengthen the debater prompt security lens (recurring FN on authz/webhook/session) — see `ace debate diagnose`\n' >> "$ROOT/ROADMAP.md"
      echo "  Filed a ROADMAP item."
    fi
  else
    echo "  No recurring pattern strong enough to propose a prompt change. Run \`ace debate diagnose\` to inspect."
  fi
  exit 0
fi

[ -n "$KV" ] || { echo "usage: debate-autotune.sh [--stub] <KNOB=value>  |  --propose-prompt" >&2; exit 2; }
knob="${KV%%=*}"; val="${KV#*=}"
case "$knob" in
  DEBATE_MODEL_A|DEBATE_MODEL_B|DEBATE_MIN|DEBATE_MAX|DEBATE_HARD_MAX|DEBATE_TIMEOUT) ;;
  *) echo "autotune: '$knob' is not a tunable debate KNOB (knobs only; prompt changes → --propose-prompt)." >&2; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo "autotune: python3 required (eval-ab)." >&2; exit 1; }

A="$(mktemp)"; B="$(mktemp)"; trap 'rm -f "$A" "$B"' EXIT
if [ -n "$STUB" ]; then
  bash "$HARNESS" --emit-tsv > "$A"; cp "$A" "$B"            # offline plumbing: identical arms
else
  { command -v opencode >/dev/null 2>&1 && [ -n "${DEBATE_MODEL_B:-}$(grep -E '^DEBATE_MODEL_B=' "$_cfg" 2>/dev/null)" ]; } \
    || { echo "autotune: live A/B needs opencode + DEBATE_MODEL_B (+ OPENROUTER_API_KEY). Use --stub for offline plumbing." >&2; exit 0; }
  bash "$HARNESS" --capture >/dev/null 2>&1; bash "$HARNESS" --emit-tsv > "$A"       # baseline
  env "$knob=$val" bash "$HARNESS" --capture >/dev/null 2>&1; env "$knob=$val" bash "$HARNESS" --emit-tsv > "$B"   # candidate
fi

echo "── debate autotune A/B · baseline vs $knob=$val ──"
bash "$AB" "$A" "$B" 2>&1 | sed 's/^/  /' || true

# DECISION (deterministic, not prose-parsed): mean accuracy + mean cost from the TSVs.
read -r accA costA nA < <(awk -F'\t' 'NR>1 && $1!~/^#/ {p+=$3; c+=$5; n++} END{printf "%d %d %d", (n?p*1000/n:0), (n?c/n:0), n}' "$A")
read -r accB costB _ < <(awk -F'\t' 'NR>1 && $1!~/^#/ {p+=$3; c+=$5; n++} END{printf "%d %d %d", (n?p*1000/n:0), (n?c/n:0), n}' "$B")
printf '  baseline: accuracy %d.%03d · avg-cost %ss   |   candidate: accuracy %d.%03d · avg-cost %ss   (n=%s)\n' \
  "$((accA/1000))" "$((accA%1000))" "$costA" "$((accB/1000))" "$((accB%1000))" "$costB" "$nA"

cost_ok=1; [ "$costB" -gt "$(( costA + costA/10 + 1 ))" ] && cost_ok=0    # candidate cost <= baseline +10%
if [ "$accB" -gt "$accA" ] && [ "$cost_ok" = 1 ]; then
  echo "  DECISION: KEEP $knob=$val — accuracy improved, cost within +10%."
  if [ -z "$STUB" ]; then
    tmp="$(mktemp)"; grep -v "^$knob=" "$_cfg" 2>/dev/null > "$tmp" || true; printf '%s=%s\n' "$knob" "$val" >> "$tmp"; mv "$tmp" "$_cfg"
    echo "  wrote $knob=$val to $_cfg — run \`ace opencode\` if it changed a provider. (Re-score to log the new trend point.)"
  else echo "  (--stub: not writing config.)"; fi
else
  echo "  DECISION: KEEP BASELINE — candidate did not clearly win (accuracy not up, or cost > +10%)."
fi
exit 0
