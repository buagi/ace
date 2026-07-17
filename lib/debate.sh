#!/usr/bin/env bash
# debate.sh — the cross-model adversarial DEBATE engine. Two DIFFERENT LLMs pressure-test an artifact (a
# feature spec, or a code diff) over a bounded, grounded dialogue: the CHALLENGER (B, an OpenRouter model)
# finds real gaps, the DEFENDER (A, the overseer — your Claude, who owns the artifact) concedes or refutes with
# evidence, converging on the issues BOTH accept. A point becomes an emitted gap ONLY when the defender accepts
# it — so good arguments promote and hallucinated/weak ones are filtered by the other model. Cross-provider so
# they don't share blind spots; both run read-only (the `debater` agent) so they can fact-check each other
# against the ACTUAL repo (Serena/gitnexus) — the anti-hallucination lever.
#
# OPT-IN, HIGH-risk-only (spec mode), bounded rounds, per-turn timeout, FAIL-OPEN: any missing key / dead turn /
# error ⇒ zero gaps, the artifact passes. Mirrors the rubric's safety contract (swarm.sh swarm_spec_rubric).
#
#   bash lib/debate.sh spec   <spec-file> [slug]     → emits `SPECGAP <slug> DEBATE:<issue>` per agreed gap
#   bash lib/debate.sh review [<base-ref>] [slug]    → emits `DEBATEISSUE <sev> · …` per agreed finding
#   bash lib/debate.sh selftest                      → no-network guard/fail-open assertions
#
# Transcript (the full argument, for you to read) is saved to .opencode/cache/{spec,review}-debate-<slug>.md.
set -uo pipefail

_dcfg(){ grep -E "^$1=" "${ACE_CONFIG:-$HOME/.config/ace/config}" 2>/dev/null | tail -1 | cut -d= -f2-; }

# defender (A) = the overseer model (owns the artifact); challenger (B) = the OpenRouter cross-model.
_debate_model_a(){
  local m; m="${DEBATE_MODEL_A:-$(_dcfg DEBATE_MODEL_A)}"; [ -n "$m" ] && { printf '%s' "$m"; return; }
  m="$(_dcfg MODEL_orchestrator)"; [ -n "$m" ] && { printf '%s' "$m"; return; }
  case "$(_dcfg ORCH_PROVIDER)" in
    sonnet)   printf 'anthropic/claude-sonnet-4-6' ;;
    gpt)      printf 'openai/gpt-5' ;;
    deepseek) printf 'deepseek/deepseek-v4-pro' ;;
    *)        printf 'anthropic/claude-opus-4-8' ;;
  esac
}
_debate_model_b(){ local m; m="${DEBATE_MODEL_B:-$(_dcfg DEBATE_MODEL_B)}"; printf '%s' "$m"; }

# one bounded, fail-open turn: run the read-only `debater` agent on the given side model; empty on any failure.
_debate_turn(){ timeout "${DEBATE_TIMEOUT:-600}" opencode run --agent debater --model "$1" "$2" 2>/dev/null || true; }

# _debate_converged <challenger-out> <defender-out> → prints "conv<TAB>needs" (1/0 each)
_debate_flags(){
  local conv=0 needs=0
  # require 'yes' RIGHT AFTER the colon (a line like "CONVERGED: no — answer yes/no on X" must NOT count as yes)
  printf '%s' "$1" | grep -iE '^CONVERGED:[[:space:]]*yes\b' >/dev/null \
    && printf '%s' "$2" | grep -iE '^CONVERGED:[[:space:]]*yes\b' >/dev/null && conv=1
  printf '%s\n%s' "$1" "$2" | grep -iE '^NEEDS-MORE:[[:space:]]*yes\b' >/dev/null && needs=1
  printf '%s\t%s' "$conv" "$needs"
}

ace_debate(){
  local mode="${1:-}" artifact="${2:-}" slug="${3:-}"
  case "$mode" in spec|review) ;; *) echo "usage: debate.sh spec <file> [slug] | review [base] [slug]" >&2; return 2 ;; esac
  command -v opencode >/dev/null 2>&1 || return 0          # no crew transport ⇒ fail-open
  local A B; A="$(_debate_model_a)"; B="$(_debate_model_b)"
  [ -n "$B" ] || { echo "debate: DEBATE_MODEL_B (OpenRouter challenger) unset — skipping (set it + OPENROUTER_API_KEY)." >&2; return 0; }

  local art_text art_label
  if [ "$mode" = spec ]; then
    [ -f "$artifact" ] || return 0
    grep -qiE 'risk:[[:space:]]*HIGH' "$artifact" || return 0    # HIGH-risk only — not worth the spend otherwise
    art_text="$(cat "$artifact" 2>/dev/null)"; art_label="the feature spec at $artifact"
    [ -n "$slug" ] || slug="$(basename "$artifact" .md)"
  else
    local base="${artifact:-main}"
    art_text="$(git diff "$base"...HEAD 2>/dev/null | head -c "${DEBATE_DIFF_MAX:-150000}")"
    [ -n "$art_text" ] || return 0
    art_label="the code diff (git diff $base...HEAD)"
    [ -n "$slug" ] || slug="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"; [ -n "$slug" ] || slug=diff
  fi

  local dir=".opencode/cache" trf="$dir/${mode}-debate-${slug}.md"; mkdir -p "$dir" 2>/dev/null
  printf '# %s debate · %s\n\n- defender (A): %s\n- challenger (B): %s\n- rounds: min %s · max %s · hard %s\n' \
    "$mode" "$slug" "$A" "$B" "${DEBATE_MIN:-2}" "${DEBATE_MAX:-4}" "${DEBATE_HARD_MAX:-10}" > "$trf"

  local transcript="" round=0 min="${DEBATE_MIN:-2}" max="${DEBATE_MAX:-4}" hard="${DEBATE_HARD_MAX:-10}"
  local _start; _start="$(date +%s)"   # total wall-clock backstop: this gate runs SYNCHRONOUSLY in planning
  while :; do
    round=$((round+1))
    local cprompt cout
    cprompt="ROLE: CHALLENGER (turn $round). Pressure-test $art_label below — thorough, multi-layered, do not spare depth.$([ "$round" -gt 1 ] && printf ' Press still-DISPUTED points; DROP refuted ones; raise a NEW point only if the dialogue genuinely surfaced it.')
=== ARTIFACT ===
$art_text
=== DIALOGUE SO FAR ===
${transcript:-<none — this is the opening critique>}"
    cout="$(_debate_turn "$B" "$cprompt")"; [ -n "$cout" ] || break     # dead turn ⇒ fail-open end
    transcript="$transcript

── ROUND $round · CHALLENGER (B) ──
$cout"
    printf '\n── ROUND %s · CHALLENGER (B: %s) ──\n%s\n' "$round" "$B" "$cout" >> "$trf"

    local dprompt dout
    dprompt="ROLE: DEFENDER (turn $round). You OWN $art_label. Answer EVERY open point by id — CONCEDE / DEFEND (grounded) / CLARIFY. Concede what is genuinely right; refute what is wrong, with evidence.
=== ARTIFACT ===
$art_text
=== DIALOGUE SO FAR ===
$transcript"
    dout="$(_debate_turn "$A" "$dprompt")"; [ -n "$dout" ] || break
    transcript="$transcript

── ROUND $round · DEFENDER (A) ──
$dout"
    printf '\n── ROUND %s · DEFENDER (A: %s) ──\n%s\n' "$round" "$A" "$dout" >> "$trf"

    local conv needs; IFS=$'\t' read -r conv needs < <(_debate_flags "$cout" "$dout")
    [ "$round" -ge "$min" ] && [ "$conv" = 1 ] && break               # both converged (after the min real exchange)
    if [ "$round" -ge "$max" ]; then { [ "$needs" = 1 ] && [ "$round" -lt "$hard" ]; } || break; fi
    [ "$round" -ge "$hard" ] && break
    # wall backstop: a non-converging pair that keeps flagging NEEDS-MORE could run rounds×2×DEBATE_TIMEOUT —
    # far too long for a synchronous planning gate. Cap total debate wall time (default 30m). Fail-open: proceed to synthesis with what we have.
    [ "$(( $(date +%s) - _start ))" -ge "${DEBATE_WALL_MAX:-1800}" ] && { printf '\n── debate wall-cap (%ss) reached at round %s — synthesizing what we have ──\n' "${DEBATE_WALL_MAX:-1800}" "$round" >> "$trf"; break; }
  done

  # synthesis — the defender distills ONLY the issues both sides accepted into machine lines.
  local sout
  sout="$(_debate_turn "$A" "ROLE: SYNTHESIS. The debate is over. From the ACCEPTED points ONLY (issues BOTH sides agreed are real), output the final list — one per line, EXACTLY this shape and nothing else:
DEBATEISSUE <blocker|major|minor> · <short label> · <what to fix> · <cite>
If the artifact is sound (nothing was accepted), output exactly: SOUND
=== DIALOGUE ===
$transcript")"
  printf '\n── SYNTHESIS (agreed issues) ──\n%s\n' "${sout:-<none>}" >> "$trf"

  local issues; issues="$(printf '%s\n' "$sout" | grep -iE '^DEBATEISSUE')"
  [ -n "$issues" ] || return 0
  if [ "$mode" = spec ]; then
    printf '%s\n' "$issues" | sed -E "s|^DEBATEISSUE[[:space:]]*|SPECGAP $slug DEBATE:|"
  else
    printf '%s\n' "$issues"
  fi
  return 0
}

# no-network selftest: the guard + fail-open contract (never makes a call in these paths).
ace_debate_selftest(){
  local d ok=1 out; d="$(mktemp -d)" || return 1
  ( cd "$d"
    printf '<!-- ace-spec-template v1 -->\n# Spec (slug: hi · risk: HIGH)\n## 3. Scope\n' > hi.md
    printf '# Spec (slug: lo · risk: LOW)\n' > lo.md
    out="$(DEBATE_MODEL_B='' ace_debate spec hi.md 2>/dev/null)"
    [ -z "$out" ] || { echo "[debate] no challenger model ⇒ must be silent (got: $out)"; ok=0; }
    out="$(DEBATE_MODEL_B=openrouter/x ace_debate spec lo.md 2>/dev/null)"
    [ -z "$out" ] || { echo "[debate] LOW-risk spec must be skipped (got: $out)"; ok=0; }
    out="$(ace_debate bogus x 2>/dev/null)"; [ "$?" = 2 ] || true   # bad mode ⇒ usage rc 2 (not asserted on output)
    [ "$ok" = 1 ] && echo "[debate] PASS ✓" || { echo "[debate] FAIL ✗"; exit 1; }
  ) || ok=0
  rm -rf "$d"; [ "$ok" = 1 ]
}

# CLI when executed directly (sourced: stays quiet).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    spec|review) ace_debate "$@" ;;
    selftest)    ace_debate_selftest ;;
    *)           echo "usage: debate.sh {spec <file> [slug] | review [base] [slug] | selftest}" >&2; exit 2 ;;
  esac
fi
