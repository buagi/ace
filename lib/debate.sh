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
_debate_turn(){ timeout "${DEBATE_TIMEOUT:-600}" opencode run --agent debater --model "$1" "$2" </dev/null 2>/dev/null || true; }

# _debate_converged <challenger-out> <defender-out> → prints "conv<TAB>needs" (1/0 each)
_debate_flags(){
  local conv=0 needs=0
  # require 'yes' RIGHT AFTER the colon (a line like "CONVERGED: no — answer yes/no on X" must NOT count as yes)
  printf '%s' "$1" | grep -iE '^CONVERGED:[[:space:]]*yes\b' >/dev/null \
    && printf '%s' "$2" | grep -iE '^CONVERGED:[[:space:]]*yes\b' >/dev/null && conv=1
  printf '%s\n%s' "$1" "$2" | grep -iE '^NEEDS-MORE:[[:space:]]*yes\b' >/dev/null && needs=1
  printf '%s\t%s' "$conv" "$needs"
}

# count the comma-separated ids on a "<LABEL>:" line of a turn (0 for 'none'/empty) — for the metrics log.
_debate_ids_count(){
  local line; line="$(printf '%s' "$1" | grep -iE "^$2:" | tail -1 | sed -E 's/^[^:]*:[[:space:]]*//')"
  printf '%s' "$line" | grep -qiE '^[[:space:]]*(none)?[[:space:]]*$' && { echo 0; return; }
  printf '%s' "$line" | tr ',' '\n' | grep -cE '[A-Za-z0-9]' || true
}

# excessive per-debate metrics → one JSONL record (fail-open; jq-gated; never blocks the debate).
_debate_log_metric(){
  command -v jq >/dev/null 2>&1 || return 0
  local mode="$1" slug="$2" A="$3" B="$4" rounds="$5" conv="$6" start="$7" issues="$8" trf="$9" tsv="${10}"
  local dur=$(( $(date +%s) - start )) capped=0
  grep -q 'wall-cap' "$trf" 2>/dev/null && capped=1
  local rj; rj="$(printf '%s' "$tsv" | jq -R -s 'split("\n")|map(select(length>0)|split("\t")|{round:(.[0]|tonumber),challenger_chars:(.[1]|tonumber),defender_chars:(.[2]|tonumber),accepted:(.[3]|tonumber),disputed:(.[4]|tonumber),converged:(.[5]|tonumber),needs_more:(.[6]|tonumber),challenger_secs:(.[7]|tonumber),defender_secs:(.[8]|tonumber)})' 2>/dev/null || echo '[]')"
  # run_id: this log is append-only and CUMULATIVE for the life of the project, so every consumer that wants to
  # report on "this run" (lib/scorecard.sh ⑤/⑧) needs a way to select one run's records. RUN_ID is exported by
  # autoloop.sh; a manual `ace debate spec` has none and records "" — consumers treat that as untagged.
  # KNOWN GAP (for the swarm owner): the swarm COORDINATOR also records "". Its run id lives in `RUNID`
  # (swarm-run.sh:684), which is never exported, and it invokes this file as a SEPARATE process
  # (swarm-run.sh:569) — so a `${RUNID:-}` fallback here would be inert across that boundary and would only
  # look like a fix. The real fix is to export a run id from swarm-run.sh. Until then scorecard's
  # _sc_debate_scope detects the untagged/interleaved shape and reports CUMULATIVE, explicitly labelled,
  # rather than reporting one worker's debates as the whole run.
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg mode "$mode" --arg slug "$slug" --arg a "$A" --arg b "$B" \
     --arg run "${RUN_ID:-}" \
     --argjson rounds "${rounds:-0}" --argjson conv "${conv:-0}" --argjson dur "$dur" \
     --argjson issues "${issues:-0}" --argjson capped "$capped" --arg trf "$trf" --argjson rj "${rj:-[]}" \
     '{ts:$ts,run_id:$run,mode:$mode,slug:$slug,model_a:$a,model_b:$b,rounds:$rounds,converged:($conv==1),wall_capped:($capped==1),duration_s:$dur,issues_emitted:$issues,transcript:$trf,per_round:$rj}' \
     >> "$(dirname "$trf")/debate-metrics.jsonl" 2>/dev/null || true
}

# _debate_spec_eligible <spec> — should this spec be debated? Debating every spec is real money, so the
# gate is a POLICY, not an accident of what was easy to grep.
#
# It used to be `risk: HIGH` alone. Measured on trading-portal that selected 2 of 9 roadmap-linked specs --
# both security specs, and the debate found blocker-severity bugs in both, so the targeting was good. But
# UX and design defects are exactly the kind a single model talks itself into, and they were all excluded:
# 8 of those 9 specs described a real user-facing surface.
#
# So a spec qualifies on EITHER axis:
#   * risk: HIGH                       -- the original signal (security/data/money)
#   * a populated "C3. UX flow"        -- the spec template's OWN marker for a user-facing surface
#                                         (`<!-- trigger: user-facing surface -->`). Reusing it means one
#                                         definition of "user-facing", not a second competing one.
# DEBATE_MIN_RISK=LOW (or DEBATE_ALL=1) widens to every spec, for a deliberate spend-everything pass.
#
# Every skip is NARRATED (C1). The silent `return 0` is how the old filter hid the fact that it was
# debating 2 specs out of 156 while the run looked fully covered.
_debate_spec_eligible() {
  local sp="$1" why="" c3
  case "${DEBATE_MIN_RISK:-}" in [Ll][Oo][Ww]|[Aa][Ll][Ll]) why="DEBATE_MIN_RISK=${DEBATE_MIN_RISK}" ;; esac
  [ -z "$why" ] && [ "${DEBATE_ALL:-0}" = 1 ] && why="DEBATE_ALL=1"
  [ -z "$why" ] && grep -qiE 'risk:[[:space:]]*HIGH' "$sp" 2>/dev/null && why="risk: HIGH"
  if [ -z "$why" ] && _debate_spec_is_ux "$sp"; then why="user-facing (C3 UX flow populated)"; fi
  if [ -n "$why" ]; then
    echo "debate: $(basename "$sp" .md) — eligible ($why)." >&2
    return 0
  fi
  echo "debate: $(basename "$sp" .md) — SKIPPED (not risk:HIGH, no user-facing C3 UX flow). Widen with DEBATE_MIN_RISK=LOW." >&2
  return 1
}

# _debate_spec_is_ux <spec> — true when the C3 UX flow section describes a real surface.
# Deliberately strict about what does NOT count, because a false positive here costs a paid debate on every
# run: an absent section, the unedited `<Key flow(s) ...>` placeholder, an explicit `N/A -- reason`, and a
# spec that states it is API-only all mean "no user-facing surface".
_debate_spec_is_ux() {
  local sp="$1" c3
  c3="$(awk '/^##[[:space:]]*C3\./{f=1;next} f&&/^##[[:space:]]/{exit} f' "$sp" 2>/dev/null \
        | grep -vE '^[[:space:]]*$|^[[:space:]]*<!--' | head -1)"
  [ -n "$c3" ] || return 1
  case "$c3" in
    [Nn]/[Aa]*|'<'*) return 1 ;;                       # explicit N/A, or the untouched template placeholder
  esac
  grep -qiE '^[[:space:]]*API-only' <<<"$c3" && return 1
  return 0
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
    _debate_spec_eligible "$artifact" || return 0
    art_text="$(cat "$artifact" 2>/dev/null)"; art_label="the feature spec at $artifact"
    [ -n "$slug" ] || slug="$(basename "$artifact" .md)"
  else
    local base="${artifact:-main}"
    art_text="$(git diff "$base"...HEAD 2>/dev/null | head -c "${DEBATE_DIFF_MAX:-150000}")"
    [ -n "$art_text" ] || return 0
    art_label="the code diff (git diff $base...HEAD)"
    [ -n "$slug" ] || slug="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '-')"; [ -n "$slug" ] || slug=diff
  fi

  # Trial scoping — SPEC mode and REVIEW mode have SEPARATE knobs ON PURPOSE. Their "slug" namespaces are
  # different: a spec slug is a FEATURE name (checkout, authz); a review slug is a BRANCH name (feat-checkout).
  # DEBATE_ONLY is documented (docs/configuration.md, docs/trial-runs.md Setup) as a list of SPEC slugs, but it
  # used to be applied to BOTH modes — so a branch name never matched the list and every review debate returned
  # here silently. Anyone who followed the trial-runs Setup and set DEBATE_ONLY thereby lost the entire
  # REVIEW_DEBATE pre-merge gate, fail-open, with no log line saying so. Keep these two arms distinct:
  #   DEBATE_ONLY=checkout,authz,…          → limits SPEC debates   (spec slug = spec file basename)
  #   REVIEW_DEBATE_ONLY=feat-checkout,…    → limits REVIEW debates (review slug = branch, `/`→`-`)
  # Unset ⇒ every eligible artifact in that mode. Set either in ~/.config/ace/config or the environment.
  local _only
  if [ "$mode" = spec ]; then _only="${DEBATE_ONLY:-$(_dcfg DEBATE_ONLY)}"
  else                        _only="${REVIEW_DEBATE_ONLY:-$(_dcfg REVIEW_DEBATE_ONLY)}"; fi
  [ -z "$_only" ] || case ",$_only," in *",$slug,"*) : ;; *) printf 'debate: %s "%s" not in the %s scope list — skipping.\n' "$mode" "$slug" "$([ "$mode" = spec ] && echo DEBATE_ONLY || echo REVIEW_DEBATE_ONLY)" >&2; return 0 ;; esac

  local dir=".opencode/cache"; local trf="$dir/${mode}-debate-${slug}.md"; mkdir -p "$dir" 2>/dev/null   # NOTE: keep as two `local` statements — `local a=X b=$a` expands $a from the OUTER scope (unbound under set -u) BEFORE the same-line assignment lands
  printf '# %s debate · %s\n\n- defender (A): %s\n- challenger (B): %s\n- rounds: min %s · max %s · hard %s\n' \
    "$mode" "$slug" "$A" "$B" "${DEBATE_MIN:-2}" "${DEBATE_MAX:-4}" "${DEBATE_HARD_MAX:-10}" > "$trf"

  local transcript="" round=0 min="${DEBATE_MIN:-2}" max="${DEBATE_MAX:-4}" hard="${DEBATE_HARD_MAX:-10}"
  local _start _rtsv="" _t0 _cs=0 _ds=0 conv=0 needs=0; _start="$(date +%s)"   # wall-clock backstop + per-round timing/metrics (hoisted so they exist even if turn 1 dies)
  # `round` counts rounds ATTEMPTED; `_rdone` counts rounds that produced BOTH turns and therefore a _rtsv row.
  # They diverge exactly when a turn dies mid-round (fail-open break below), and the metrics record must log
  # _rdone: logging `round` there claimed a round that never happened and contradicted per_round|length inside
  # the same record — inflating avg_rounds in `ace debate report` / the scorecard.
  local _rdone=0
  while :; do
    round=$((round+1))
    conv=0; needs=0   # a round that dies mid-way must NOT inherit the previous round's converged/needs-more flags
    local cprompt cout
    cprompt="ROLE: CHALLENGER (turn $round). Pressure-test $art_label below — thorough, multi-layered, do not spare depth.$([ "$round" -gt 1 ] && printf ' Press still-DISPUTED points; DROP refuted ones; raise a NEW point only if the dialogue genuinely surfaced it.')
=== ARTIFACT ===
$art_text
=== DIALOGUE SO FAR ===
${transcript:-<none — this is the opening critique>}"
    printf '  debate %s · round %s/%s · CHALLENGER (%s) thinking…\n' "$slug" "$round" "$max" "$B" >&2
    _t0="$(date +%s)"; cout="$(_debate_turn "$B" "$cprompt")"; _cs=$(( $(date +%s) - _t0 ))
    printf '  debate %s · round %s · CHALLENGER replied in %ss (%s chars)\n' "$slug" "$round" "$_cs" "${#cout}" >&2
    [ -n "$cout" ] || { printf '  debate %s · challenger returned NOTHING — ending (fail-open)\n' "$slug" >&2; break; }
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
    printf '  debate %s · round %s/%s · DEFENDER (%s) thinking…\n' "$slug" "$round" "$max" "$A" >&2
    _t0="$(date +%s)"; dout="$(_debate_turn "$A" "$dprompt")"; _ds=$(( $(date +%s) - _t0 ))
    printf '  debate %s · round %s · DEFENDER replied in %ss (%s chars)\n' "$slug" "$round" "$_ds" "${#dout}" >&2
    [ -n "$dout" ] || { printf '  debate %s · defender returned NOTHING — ending (fail-open)\n' "$slug" >&2; break; }
    transcript="$transcript

── ROUND $round · DEFENDER (A) ──
$dout"
    printf '\n── ROUND %s · DEFENDER (A: %s) ──\n%s\n' "$round" "$A" "$dout" >> "$trf"

    IFS=$'\t' read -r conv needs < <(_debate_flags "$cout" "$dout")
    # per-round metrics row (tab-separated): round · challenger_chars · defender_chars · accepted · disputed · conv · needs · c_secs · d_secs
    _rtsv="${_rtsv}${round}	${#cout}	${#dout}	$(_debate_ids_count "$dout" ACCEPTED)	$(_debate_ids_count "$dout" DISPUTED)	${conv}	${needs}	${_cs}	${_ds}
"
    _rdone=$round   # both turns landed + a metrics row exists — this round really happened
    printf '  debate %s · round %s done — accepted %s · disputed %s · converged %s · needs-more %s\n' \
      "$slug" "$round" "$(_debate_ids_count "$dout" ACCEPTED)" "$(_debate_ids_count "$dout" DISPUTED)" "$conv" "$needs" >&2
    [ "$round" -ge "$min" ] && [ "$conv" = 1 ] && break               # both converged (after the min real exchange)
    if [ "$round" -ge "$max" ]; then { [ "$needs" = 1 ] && [ "$round" -lt "$hard" ]; } || break; fi
    [ "$round" -ge "$hard" ] && break
    # wall backstop: a non-converging pair that keeps flagging NEEDS-MORE could run rounds×2×DEBATE_TIMEOUT —
    # far too long for a synchronous planning gate. Cap total debate wall time (default 30m). Fail-open: proceed to synthesis with what we have.
    [ "$(( $(date +%s) - _start ))" -ge "${DEBATE_WALL_MAX:-1800}" ] && { printf '\n── debate wall-cap (%ss) reached at round %s — synthesizing what we have ──\n' "${DEBATE_WALL_MAX:-1800}" "$round" >> "$trf"; break; }
  done

  # synthesis — the defender distills ONLY the issues both sides accepted into machine lines.
  local sout
  printf '  debate %s · synthesizing agreed issues…\n' "$slug" >&2
  sout="$(_debate_turn "$A" "ROLE: SYNTHESIS. The debate is over. From the ACCEPTED points ONLY (issues BOTH sides agreed are real), output the final list — one per line, EXACTLY this shape and nothing else:
DEBATEISSUE <blocker|major|minor> · <short label> · <what to fix> · <cite>
If the artifact is sound (nothing was accepted), output exactly: SOUND
=== DIALOGUE ===
$transcript")"
  printf '\n── SYNTHESIS (agreed issues) ──\n%s\n' "${sout:-<none>}" >> "$trf"

  local issues _ic; issues="$(printf '%s\n' "$sout" | grep -iE '^DEBATEISSUE')"
  _ic="$(printf '%s\n' "$sout" | grep -icE '^DEBATEISSUE' || true)"; _ic="${_ic:-0}"
  # excessive metrics for later analysis — logged for EVERY debate (SOUND or FLAGGED), fail-open.
  _debate_log_metric "$mode" "$slug" "$A" "$B" "$_rdone" "$conv" "$_start" "$_ic" "$trf" "$_rtsv" 2>/dev/null || true
  [ -n "$issues" ] || return 0
  if [ "$mode" = spec ]; then
    printf '%s\n' "$issues" | sed -E "s|^DEBATEISSUE[[:space:]]*|SPECGAP $slug DEBATE:|"
  else
    printf '%s\n' "$issues"
  fi
  return 0
}

# ace_debate_report — analyze the metrics log: a per-debate table + aggregates. The per_round detail lives in
# the JSONL for deeper analysis; the transcript (.md) has the full argument.
ace_debate_report(){
  local f="${1:-.opencode/cache/debate-metrics.jsonl}"
  [ -f "$f" ] || { echo "debate: no metrics yet at $f — run a debate (trial enabled) first."; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "debate: jq required for the report." >&2; return 1; }
  echo "── debate trial report · $f ──"; echo
  printf '  %-26s %-6s %-6s %-9s %-6s %-7s %s\n' SLUG MODE ROUNDS CONVERGED ISSUES DUR_s WALL_CAP
  jq -r '[.slug,.mode,(.rounds|tostring),(if .converged then "yes" else "no" end),(.issues_emitted|tostring),(.duration_s|tostring),(if .wall_capped then "capped" else "-" end)]|@tsv' "$f" \
    | awk -F'\t' '{printf "  %-26s %-6s %-6s %-9s %-6s %-7s %s\n",$1,$2,$3,$4,$5,$6,$7}'
  echo
  jq -s 'if length==0 then {} else {debates:length,
     converged:(map(select(.converged))|length),
     wall_capped:(map(select(.wall_capped))|length),
     avg_rounds:((map(.rounds)|add)/length*10|round/10),
     total_issues:(map(.issues_emitted)|add),
     avg_duration_s:((map(.duration_s)|add)/length|floor),
     total_accepted:(map(.per_round|map(.accepted)|add // 0)|add),
     total_disputed:(map(.per_round|map(.disputed)|add // 0)|add)} end' "$f" 2>/dev/null \
    | jq -r 'to_entries[]|"  \(.key): \(.value)"' 2>/dev/null || true
}

# ace_debate_trend — the over-time conclusion: is the debate getting MORE effective (F1↑) as you tune it, and
# at what cost? Reads the effectiveness-history log (appended by `ace debate score`).
ace_debate_trend(){
  local f="${1:-tests/debate-sandbox/effectiveness-history.jsonl}"
  [ -f "$f" ] || { echo "debate: no effectiveness history at $f — run 'ace debate score' first."; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "debate: jq required." >&2; return 1; }
  local n; n="$(jq -s 'length' "$f" 2>/dev/null || echo 0)"; [ "${n:-0}" -ge 1 ] || { echo "debate: empty history ($f)."; return 0; }
  echo "── debate effectiveness over time · $f · $n review(s) ──"; echo
  printf '  %-12s %-26s %-6s %-6s %-6s %-6s %-7s\n' DATE MODEL_B F1 PREC REC CONV AVGCOST
  jq -r '[(.ts|split("T")[0]),.model_b,(.f1|tostring),(.precision|tostring),(.recall|tostring),(.convergence_pct|tostring),(.avg_cost_s|tostring)]|@tsv' "$f" \
    | awk -F'\t' '{printf "  %-12s %-26s %-6s %-6s %-6s %-6s %-7s\n",$1,substr($2,1,26),$3,$4,$5,$6"%",$7"s"}'
  echo
  jq -s '(.[0].f1) as $first|(.[-1].f1) as $last|(if length>1 then .[-2].f1 else .[0].f1 end) as $prev|(.[-1].avg_cost_s-.[0].avg_cost_s) as $dc|
     {first:$first,last:$last,dall:(($last-$first)*1000|round/1000),drecent:(($last-$prev)*1000|round/1000),dcost:$dc}' "$f" 2>/dev/null \
    | jq -r '"  F1: \(.first) → \(.last)   (all-time \(if .dall>=0 then "+" else "" end)\(.dall) · since last \(if .drecent>=0 then "+" else "" end)\(.drecent))",
       "  cost: \(if .dcost>0 then "+\(.dcost)s (up)" elif .dcost<0 then "\(.dcost)s (down)" else "flat" end)",
       (if .drecent>0.02 then "  CONCLUSION: IMPROVING — the last change raised F1; keep this direction (see `ace debate diagnose` for what still fails)."
        elif .drecent<-0.02 then "  CONCLUSION: REGRESSING — the last change LOWERED F1; revert it or try another lever."
        else "  CONCLUSION: FLAT — no meaningful F1 move; change a lever (model / prompt / knob) then re-score. `ace debate diagnose` shows where it fails." end)' 2>/dev/null || true
}

# ace_debate_testproject [dir] — materialize the labeled sandbox into a runnable ACE project (specs →
# .opencode/specs, profile, ci.sh, OBJECTIVES, git init) so you can watch the debate fire in a real autorun.
ace_debate_testproject(){
  local dir="${1:-/tmp/ace-debate-sandbox}" src
  src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/tests/debate-sandbox"
  [ -d "$src/specs" ] || { echo "debate: sandbox template not found at $src" >&2; return 1; }
  mkdir -p "$dir/.opencode/specs" || { echo "debate: cannot create $dir" >&2; return 1; }
  cp "$src/specs/"*.md "$dir/.opencode/specs/" 2>/dev/null
  cp "$src/profile.yaml" "$dir/.opencode/profile.yaml" 2>/dev/null
  cp "$src/OBJECTIVES.md" "$src/labels.tsv" "$src/ci.sh" "$src/README.md" "$dir/" 2>/dev/null
  chmod +x "$dir/ci.sh" 2>/dev/null
  ( cd "$dir" && { [ -d .git ] || git init -q; } && git add -A \
      && git -c user.email=debate@ace -c user.name=debate commit -qm "debate sandbox" >/dev/null 2>&1 ) || true
  echo "debate: sandbox materialized → $dir"
  echo "  cd $dir  &&  SPEC_DEBATE=1 DEBATE_ONLY=authz-missing,webhook-nosig,vague-acs ace autorun --yes"
  echo "  (needs OPENROUTER_API_KEY + DEBATE_MODEL_B in ~/.config/ace/config; or just: ace debate score --capture)"
}

# no-network selftest: the guard + fail-open contract (never makes a call in these paths).
ace_debate_selftest(){
  local d ok=1 out rc; d="$(mktemp -d)" || return 1
  ( cd "$d"
    # HERMETIC: point ACE_CONFIG at an empty file so `_dcfg` never reads the user's real ~/.config/ace/config —
    # otherwise `DEBATE_MODEL_B=''` falls back (via `:-`) to a configured challenger and the "empty B / LOW-risk"
    # cases fire a live network debate (hangs). CI has no config so this only bit machines with DEBATE_MODEL_B set.
    : > empty-config; export ACE_CONFIG="$PWD/empty-config"
    printf '<!-- ace-spec-template v1 -->\n# Spec (slug: hi · risk: HIGH)\n## 3. Scope\n' > hi.md
    printf '# Spec (slug: lo · risk: LOW)\n' > lo.md
    out="$(DEBATE_MODEL_B='' ace_debate spec hi.md 2>/dev/null)"
    [ -z "$out" ] || { echo "[debate] no challenger model ⇒ must be silent (got: $out)"; ok=0; }
    out="$(DEBATE_MODEL_B=openrouter/x ace_debate spec lo.md 2>/dev/null)"
    [ -z "$out" ] || { echo "[debate] LOW-risk spec must be skipped (got: $out)"; ok=0; }
    # regression: a valid challenger + HIGH-risk spec must run PAST the transcript setup and write a transcript.
    # (Guards the set -u crash at `local dir=.. trf=$dir/..` — the two paths above both return BEFORE that line,
    # so this is the only test that reaches it.) Stub opencode so no model/network is needed.
    mkdir -p bin; printf '#!/usr/bin/env bash\necho "no blocking issues."\necho "CONVERGED: yes"\n' > bin/opencode; chmod +x bin/opencode
    # MIN=MAX=HARD_MAX=1 → exactly one round, guaranteed to terminate; TIMEOUT/WALL small so a future hang fails fast.
    out="$(PATH="$PWD/bin:$PATH" DEBATE_MODEL_A=stub DEBATE_MODEL_B=openrouter/stub DEBATE_MIN=1 DEBATE_MAX=1 DEBATE_HARD_MAX=1 DEBATE_TIMEOUT=3 DEBATE_WALL_MAX=10 ace_debate spec hi.md 2>&1)"
    printf '%s' "$out" | grep -q 'unbound variable' && { echo "[debate] transcript setup crashed under set -u: $out"; ok=0; }
    [ -f .opencode/cache/spec-debate-hi.md ] || { echo "[debate] no transcript written — debate never reached the round loop"; ok=0; }
    # bad mode ⇒ usage rc 2. This WAS `[ "$?" = 2 ] || true`, which asserted nothing: the trailing `|| true`
    # discarded the comparison and `ok` was never touched, so a regression in the usage path passed silently.
    # rc 2 is a real contract — `ace` dispatch distinguishes "bad usage" (2) from "debate failed" (1).
    # Stash $? in its own var before anything else runs, then fail the selftest properly.
    out="$(ace_debate bogus x 2>/dev/null)"; rc=$?
    [ "$rc" = 2 ] || { echo "[debate] bad mode must exit 2 (got rc=$rc, out: $out)"; ok=0; }

    # GATE REGRESSION: DEBATE_ONLY is a list of SPEC slugs. It must NOT gate REVIEW mode, whose slug is a
    # BRANCH name — that mismatch silently disabled the whole REVIEW_DEBATE pre-merge gate for every user who
    # followed docs/trial-runs.md Setup. Build a tiny 2-commit repo so review mode has a real diff, set
    # DEBATE_ONLY to spec slugs that can never match a branch, and require the review debate to STILL run.
    ( mkdir -p rv && cd rv
      git init -q 2>/dev/null; git checkout -q -b main 2>/dev/null
      printf 'a\n' > f.txt; git add -A 2>/dev/null
      git -c user.email=d@ace -c user.name=d -c commit.gpgsign=false commit -qm base --no-verify >/dev/null 2>&1
      git checkout -q -b feat/x 2>/dev/null; printf 'b\n' >> f.txt; git add -A 2>/dev/null
      git -c user.email=d@ace -c user.name=d -c commit.gpgsign=false commit -qm change --no-verify >/dev/null 2>&1
      PATH="$OLDPWD/bin:$PATH" DEBATE_MODEL_A=stub DEBATE_MODEL_B=openrouter/stub DEBATE_ONLY=authz,checkout \
        DEBATE_MIN=1 DEBATE_MAX=1 DEBATE_HARD_MAX=1 DEBATE_TIMEOUT=3 DEBATE_WALL_MAX=10 \
        ace_debate review main >/dev/null 2>&1
      [ -f .opencode/cache/review-debate-feat-x.md ] ) \
      || { echo "[debate] DEBATE_ONLY (spec slugs) must NOT disable the REVIEW_DEBATE gate — no review transcript written"; ok=0; }
    # …and the review-side knob must still be able to scope review debates.
    ( cd rv && rm -rf .opencode/cache
      PATH="$OLDPWD/bin:$PATH" DEBATE_MODEL_A=stub DEBATE_MODEL_B=openrouter/stub REVIEW_DEBATE_ONLY=other-branch \
        DEBATE_MIN=1 DEBATE_MAX=1 DEBATE_HARD_MAX=1 DEBATE_TIMEOUT=3 DEBATE_WALL_MAX=10 \
        ace_debate review main >/dev/null 2>&1
      [ ! -f .opencode/cache/review-debate-feat-x.md ] ) \
      || { echo "[debate] REVIEW_DEBATE_ONLY must scope review debates (non-matching branch still debated)"; ok=0; }

    # METRICS HONESTY: a debate whose round-2 challenger dies must log the rounds it actually COMPLETED —
    # `rounds` must equal per_round|length, and the flags must not be inherited from round 1.
    if command -v jq >/dev/null 2>&1; then
      printf '#!/usr/bin/env bash\nn=$(( $(cat "$STUBCNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUBCNT"\n[ "$n" -ge 3 ] && exit 0\necho "no blocking issues."\necho "CONVERGED: yes"\n' > bin/opencode
      chmod +x bin/opencode; rm -rf .opencode/cache; printf '0\n' > stub.cnt
      PATH="$PWD/bin:$PATH" STUBCNT="$PWD/stub.cnt" DEBATE_MODEL_A=stub DEBATE_MODEL_B=openrouter/stub \
        DEBATE_MIN=2 DEBATE_MAX=2 DEBATE_HARD_MAX=2 DEBATE_TIMEOUT=3 DEBATE_WALL_MAX=20 \
        ace_debate spec hi.md >/dev/null 2>&1
      out="$(jq -rs '.[-1]|"\(.rounds) \(.per_round|length)"' .opencode/cache/debate-metrics.jsonl 2>/dev/null)"
      [ "$out" = "1 1" ] || { echo "[debate] aborted round must not be counted: rounds/per_round = '$out' (want '1 1')"; ok=0; }
    fi
    [ "$ok" = 1 ] && echo "[debate] PASS ✓" || { echo "[debate] FAIL ✗"; exit 1; }
  ) || ok=0
  rm -rf "$d"; [ "$ok" = 1 ]
}

# CLI when executed directly (sourced: stays quiet).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    spec|review) ace_debate "$@" ;;
    report)      shift; ace_debate_report "$@" ;;
    trend)       shift; ace_debate_trend "$@" ;;
    testproject) shift; ace_debate_testproject "$@" ;;
    selftest)    ace_debate_selftest ;;
    *)           echo "usage: debate.sh {spec <file> [slug] | review [base] [slug] | report [jsonl] | trend [jsonl] | testproject [dir] | selftest}" >&2; exit 2 ;;
  esac
fi
