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

# ── RUN SCOPING · BUDGET · MEMO ────────────────────────────────────────────────────────────────────────────
# The cache dir, resolved once. _debate_log_metric used to derive it with `dirname "$trf"`, which was fine
# while the transcript sat directly in .opencode/cache — but D4 moves transcripts into a per-run subdirectory,
# and that would have scattered debate-metrics.jsonl into one file per run, silently breaking `ace debate
# report` and scorecard ⑤/⑧ (both read the single cumulative log). The metrics log and the transcripts have
# different lifetimes and must not share a path derivation.
_DEBATE_CACHE_DIR="${_DEBATE_CACHE_DIR:-.opencode/cache}"

# _debate_run_id — the id that scopes THIS run's transcripts and its wall budget. RUN_ID is exported by
# autoloop.sh. A manual `ace debate spec` has none, and must NOT then share a budget or a transcript path with
# every other manual invocation, so it gets a unique synthetic id (pid-qualified: two debates can start inside
# the same second). Sanitized because it becomes a directory name.
_debate_run_id(){
  local r="${RUN_ID:-}"
  [ -n "$r" ] || r="manual-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  printf '%s' "$r" | tr -c 'A-Za-z0-9._-' '_'
}

# D3 — THE LOOP BUDGET. DEBATE_WALL_MAX caps ONE debate (default 1800s); nothing capped the LOOP over specs.
# The caller (autoloop.sh spec_gate_solo) debates every eligible spec in sequence, so 10 specs x 1800s is a
# reachable 5-hour synchronous planning gate — and a measured real run spent 6263s (104 min, ~50% of the run)
# inside debates. DEBATE_WALL_TOTAL (default 3600s) bounds the whole loop.
#
# The loop lives in a file this module cannot see, and each debate is a SEPARATE process, so the budget cannot
# live in a shell variable — it is accumulated in a per-run state file. Consequences that matter: the budget is
# checked BEFORE a debate starts (never mid-dialogue, so the budget never leaves a half-written transcript),
# and it is enforced on the NEXT spec after an overrun, so the total can exceed the budget by at most one
# DEBATE_WALL_MAX. That is deliberate — killing a debate mid-flight would destroy the evidence D4 exists to
# preserve. DEBATE_WALL_TOTAL=0 disables the budget.
_debate_budget_state(){ printf '%s/debate-budget-%s.tsv' "$_DEBATE_CACHE_DIR" "$(_debate_run_id)"; }
_debate_budget_limit(){
  local w="${DEBATE_WALL_TOTAL:-$(_dcfg DEBATE_WALL_TOTAL)}"; w="${w:-3600}"
  case "$w" in ''|*[!0-9]*) w=3600 ;; esac          # never let an unvalidated knob reach the arithmetic below
  printf '%s' "$w"
}
_debate_budget_spent(){
  local n; n="$(grep -E "^spent$(printf '\t')" "$(_debate_budget_state)" 2>/dev/null | tail -1 | cut -f2)"
  case "${n:-}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$n" ;; esac
}
_debate_budget_add(){
  local f; f="$(_debate_budget_state)"; mkdir -p "$(dirname "$f")" 2>/dev/null
  printf 'spent\t%s\n' "$(( $(_debate_budget_spent) + ${1:-0} ))" >> "$f" 2>/dev/null || true
}
# every slug the budget turned away, so the line can NAME what went undebated rather than just stopping.
_debate_budget_skipped(){
  grep -E "^skip$(printf '\t')" "$(_debate_budget_state)" 2>/dev/null | cut -f2 | paste -sd, - 2>/dev/null
}

# D5 — the convergence MEMO. A spec that converged in run A was fully re-debated in run B after a re-spec that
# did not change it, and at GREATER cost (measured: 3 rounds/599s → 6 rounds/1467s) — the debate oscillates
# because nothing remembers that this exact content already converged. The memo is keyed on the artifact's
# CONTENT, not its name or mtime, so a genuine edit always re-debates and a no-op re-spec never does.
# Requires jq (the metrics log is JSONL); without it there is simply no memo. DEBATE_MEMO=0 disables.
_debate_artifact_sha(){ printf '%s' "${1:-}" | sha256sum 2>/dev/null | cut -c1-16; }

# _debate_memo_hit <mode> <slug> <sha> — 0 when the NEWEST record for this mode+slug converged on this exact
# content. Newest only: an older converged record must not veto a re-debate that a later run already decided
# was needed. A record with no artifact_sha (written before this change) can never match — absence is not a
# match, the same absent-vs-false trap the eligibility gate was already bitten by.
_debate_memo_hit(){
  local mode="$1" slug="$2" sha="$3" f="$_DEBATE_CACHE_DIR/debate-metrics.jsonl"
  [ "${DEBATE_MEMO:-1}" = 1 ] || return 1
  [ -n "$sha" ] && [ -f "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  local prev
  prev="$(jq -rs --arg m "$mode" --arg s "$slug" --arg h "$sha" \
    '[.[]|select(.mode==$m and .slug==$s)]|last as $p|if $p==null then "" else
       (if (($p.artifact_sha//"")==$h and $p.converged) then "HIT \($p.ts) rounds=\($p.rounds) \($p.duration_s)s" else "" end) end' \
    "$f" 2>/dev/null)"
  case "$prev" in "HIT "*) _DEBATE_MEMO_WHY="${prev#HIT }"; return 0 ;; esac
  return 1
}

# excessive per-debate metrics → one JSONL record (fail-open; jq-gated; never blocks the debate).
_debate_log_metric(){
  command -v jq >/dev/null 2>&1 || return 0
  local mode="$1" slug="$2" A="$3" B="$4" rounds="$5" conv="$6" start="$7" issues="$8" trf="$9" tsv="${10}" sha="${11:-}"
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
  # `transcript` records the RUN-SCOPED path (D4), not the convenience symlink: the symlink is rewritten by
  # the next debate of the same slug, so a record pointing at it would silently start describing a different
  # dialogue the moment that slug is debated again — the exact evidence loss D4 exists to fix, reintroduced
  # through the index. `artifact_sha` is what makes the D5 memo possible on a later run.
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg mode "$mode" --arg slug "$slug" --arg a "$A" --arg b "$B" \
     --arg run "${RUN_ID:-}" --arg sha "$sha" \
     --argjson rounds "${rounds:-0}" --argjson conv "${conv:-0}" --argjson dur "$dur" \
     --argjson issues "${issues:-0}" --argjson capped "$capped" --arg trf "$trf" --argjson rj "${rj:-[]}" \
     '{ts:$ts,run_id:$run,mode:$mode,slug:$slug,model_a:$a,model_b:$b,rounds:$rounds,converged:($conv==1),wall_capped:($capped==1),duration_s:$dur,issues_emitted:$issues,artifact_sha:$sha,transcript:$trf,per_round:$rj}' \
     >> "$_DEBATE_CACHE_DIR/debate-metrics.jsonl" 2>/dev/null || true
}

# _debate_spec_eligible <spec> — should this spec be debated?
#
# POLICY (inverted 2026-07-20, on the owner's call): debate EVERYTHING except the provably trivial. The
# previous rule was an allowlist -- `risk: HIGH`, later plus a user-facing C3 -- and an allowlist silently
# excludes whatever nobody thought to add. Measured on trading-portal it debated 2 specs of 9, and the
# categories it missed were not obscure: UX, and anything architectural. A cross-model challenger is most
# valuable exactly where one model quietly commits to a shape nobody questioned -- an endpoint contract, a
# data model, a migration -- which the old gate never looked at.
#
# So the question is no longer "did it qualify?" but "is there any reason NOT to?". A spec is debated
# unless it declares itself trivial, and triviality must be DECLARED, never inferred:
#
#     trivial  ==  risk: LOW  AND  tier: FAST  AND  every C1-C6 trigger section is dead
#
# The C-sections are the spec template's own conditional triggers, so this reuses the author's declaration
# rather than inventing a parallel taxonomy that would drift from it:
#     C1 Contract   -- endpoint / CLI / public function / event   ARCHITECTURE
#     C2 Data model -- persistence changes                        ARCHITECTURE
#     C3 UX flow    -- user-facing surface                        DESIGN
#     C4 NFRs       -- perf / scale / limits                      ARCHITECTURE
#     C5 Security   -- authz, money, secrets, PII, LLM calls      SECURITY
#     C6 Risk       -- touches a live path / deploy-visible       BLAST RADIUS
#
# A section counts as DEAD when it is absent, empty, an explicit `N/A`, the unedited `<...>` placeholder,
# or an `API-only` note (C3 only -- API-only is a real statement about UX, not about the other five).
#
# DEBATE_SCOPE overrides the default: all | nontrivial (default) | high (the old allowlist, kept so a
# cost-constrained run can go back to security-only without editing code).

# D6 — read the risk marker's ACTUAL value, and classify it. The gate used to test only `risk:[[:space:]]*HIGH`
# and let everything else fall through to the trivial path, which inverted severity: a spec declaring
# `risk: critical` was classified TRIVIAL and never debated, while `risk: HIGH` was debated. `risk: medium` is
# not hypothetical — compliance-legal-pages.md in the live repo carries it, written by ACE's own re-spec.
#
# Only an explicit LOW-end value counts as the low end. Everything else — including values nobody anticipated —
# resolves toward debating, the same rule the undeclared case already follows: a wasted debate costs money, a
# missed one ships the defect. A severity vocabulary is exactly the kind of thing that grows (`critical`,
# `severe`, `P0`, …), and an allowlist of "serious" words would silently exempt every word not yet added,
# which is the bug being fixed here — so the list that must be exhaustive is the SAFE one, not the risky one.
_debate_spec_risk(){
  grep -oiE 'risk:[[:space:]]*[A-Za-z][A-Za-z0-9-]*' "$1" 2>/dev/null | head -1 \
    | sed -E 's/^[^:]*:[[:space:]]*//' | tr '[:upper:]' '[:lower:]'
}
_debate_spec_tier(){
  grep -oiE 'tier:[[:space:]]*[A-Za-z][A-Za-z0-9-]*' "$1" 2>/dev/null | head -1 \
    | sed -E 's/^[^:]*:[[:space:]]*//' | tr '[:upper:]' '[:lower:]'
}
# absent | low | high | unknown.  `high` means "high or above" (what DEBATE_SCOPE=high restricts to);
# `unknown` is any declared-but-unrecognised value (medium, moderate, garbage) and is NOT trivial.
_debate_risk_class(){
  case "${1:-}" in
    '')                                          printf 'absent' ;;
    low|none|trivial|minimal|negligible|nil)     printf 'low' ;;
    high|critical|crit|severe|blocker|blocking)  printf 'high' ;;
    *)                                           printf 'unknown' ;;
  esac
}

_debate_spec_eligible() {
  local sp="$1" why="" sec scope="${DEBATE_SCOPE:-nontrivial}"
  local risk rclass tier
  risk="$(_debate_spec_risk "$sp")"; rclass="$(_debate_risk_class "$risk")"; tier="$(_debate_spec_tier "$sp")"

  # F9 — a knob whose only purpose is to RESTRICT spend must never fail open by widening it, and a knob that
  # does nothing must not do it silently. `DEBATE_SCOPE=hgih` used to fall through to `nontrivial` (wider than
  # the intended `high`) and `DEBATE_MIN_RISK=MEDIUM` was a no-op — in both cases the operator believed they
  # had capped cost and had not. Name the bad value, list the valid ones, state the default actually in use.
  case "${DEBATE_MIN_RISK:-}" in
    '')                                    : ;;
    [Ll][Oo][Ww]|[Aa][Ll][Ll])             scope=all ;;
    [Hh][Ii][Gg][Hh])                      scope=high ;;
    *) printf 'debate: DEBATE_MIN_RISK="%s" is not a recognised value (valid: low | all | high) — IGNORING it; scope stays "%s". This knob is NOT restricting anything.\n' \
         "$DEBATE_MIN_RISK" "$scope" >&2 ;;
  esac
  [ "${DEBATE_ALL:-0}" = 1 ] && scope=all
  case "$scope" in
    all|high|nontrivial) : ;;
    *) printf 'debate: DEBATE_SCOPE="%s" is not a recognised value (valid: all | nontrivial | high) — falling back to the DEFAULT "nontrivial". If you meant to RESTRICT spend, note that nontrivial is WIDER than "high".\n' \
         "$scope" >&2; scope=nontrivial ;;
  esac

  case "$scope" in
    all) why="DEBATE_SCOPE=all" ;;
    high)
      # "high or above": `critical` is more severe than `high`, so restricting to high must not exclude it.
      [ "$rclass" = high ] && why="risk: ${risk:-?} (high or above)"
      ;;
    *)  # nontrivial — the default. Any single live signal is enough.
      # Order matters for the NARRATION, not the verdict: check the substantive triggers before the blunt
      # `tier: FULL`, so the log says "architecture (C1 populated)" rather than a generic tier line. What
      # got a spec debated is the first thing you want to know when reading back a run.
      if [ "$rclass" = high ]; then why="risk: $risk"
      elif [ "$rclass" = unknown ]; then
        # declared, but not a value we recognise as the low end — debate it and SAY the value, so the reader
        # can either fix the spec's vocabulary or widen the recognised set deliberately.
        why="risk: $risk (declared, not recognised as low — unknown resolves toward debating)"
      else
        for sec in C1:architecture/contract C2:architecture/data-model C4:architecture/NFRs C5:security C3:user-facing C6:live-path/rollback; do
          if _debate_spec_section_live "$sp" "${sec%%:*}"; then why="${sec##*:} (${sec%%:*} populated)"; break; fi
        done
        [ -z "$why" ] && grep -qiE 'tier:[[:space:]]*FULL' "$sp" 2>/dev/null && why="tier: FULL (author did not mark it trivial)"
        # Triviality must be POSITIVELY DECLARED. A spec carrying neither `tier:` nor `risk:` is not a
        # trivial spec -- it is a spec that predates the template and declares nothing at all. Reading the
        # ABSENCE of a marker as a declaration of triviality is the same absent-vs-false trap that bit
        # merge-structured.sh and firecrawl_ensure, and here it silently exempted 147 of 156 real specs.
        # Unknown resolves toward debating: a wasted debate costs money, a missed one ships the defect.
        # No `^[^#]*` anchor: the declaration lives in the markdown H1 itself
        # (`# Spec: x   (slug: x · risk: LOW · tier: FAST)`), so excluding lines starting with # excluded
        # the only line that ever carries it -- and made EVERY spec look undeclared.
        # `rclass` is `absent` or `low` by the time we get here, so the risk half of this test is exactly
        # "no risk marker at all" — expressed through the classifier rather than a second, separately-drifting
        # regex (the old `risk:[[:space:]]*(LOW|HIGH)` spelling is what let `risk: medium` read as undeclared
        # AND as trivial at the same time).
        if [ -z "$why" ] && [ -z "$tier" ] && [ "$rclass" = absent ]; then
          why="undeclared (no tier:/risk: marker — pre-template spec, not provably trivial)"
        fi
      fi
      ;;
  esac

  if [ -n "$why" ]; then
    echo "debate: $(basename "$sp" .md) — eligible ($why)." >&2
    return 0
  fi
  # C1: never a silent skip. A run that debated almost nothing must not look like a fully-debated one.
  # D6: quote what the spec ACTUALLY says. This message used to print a hardcoded "risk: LOW, tier: FAST"
  # regardless of the file's contents, so someone reading the log to find out why a `risk: critical` spec was
  # skipped was told the spec said LOW. A skip reason that states a fact the artifact contradicts is worse
  # than no reason at all — it ends the investigation with a wrong answer instead of prompting one.
  echo "debate: $(basename "$sp" .md) — SKIPPED as trivial ($([ -n "$risk" ] && printf 'risk: %s' "$risk" || printf 'no risk marker'), $([ -n "$tier" ] && printf 'tier: %s' "$tier" || printf 'no tier marker'), no live C1-C6 section). Widen with DEBATE_SCOPE=all." >&2
  return 1
}

# _debate_spec_section_live <spec> <C1..C6> — true when that conditional section says something real.
# Strict about what does NOT count: a false positive bills a paid cross-model dialogue per spec per run,
# and the unedited template placeholder is the single most likely false positive.
_debate_spec_section_live() {
  local sp="$1" id="$2" body
  body="$(awk -v s="^##[[:space:]]*${id}\\\\." '$0 ~ s {f=1;next} f&&/^##[[:space:]]/{exit} f' "$sp" 2>/dev/null \
          | grep -vE '^[[:space:]]*$|^[[:space:]]*<!--' | head -1)"
  [ -n "$body" ] || return 1
  case "$body" in
    [Nn]/[Aa]*|'<'*) return 1 ;;
  esac
  # "API-only" is a statement about the UX surface specifically; it says nothing about contracts or data.
  [ "$id" = C3 ] && grep -qiE '^[[:space:]]*API-only' <<<"$body" && return 1
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

  # NOTE: keep these as separate `local` statements — `local a=X b=$a` expands $a from the OUTER scope
  # (unbound under set -u) BEFORE the same-line assignment lands.
  local dir=".opencode/cache"; mkdir -p "$dir" 2>/dev/null
  _DEBATE_CACHE_DIR="$dir"
  local rid; rid="$(_debate_run_id)"
  local sha; sha="$(_debate_artifact_sha "$art_text")"

  # D5 — MEMO: this exact content already converged, so re-debating it buys nothing. Checked before the budget
  # because a memo hit costs no wall time and must not consume the loop's allowance. NEVER silent: a run that
  # debated nothing because everything was memoized must not be indistinguishable from a run that debated
  # everything (the same C1 rule the trivial-skip narration follows).
  if _debate_memo_hit "$mode" "$slug" "$sha"; then
    printf 'debate: %s "%s" — SKIPPED, already CONVERGED on this exact content (sha %s, previously %s). Edit the %s to force a re-debate, or set DEBATE_MEMO=0.\n' \
      "$mode" "$slug" "$sha" "${_DEBATE_MEMO_WHY:-?}" "$([ "$mode" = spec ] && echo spec || echo diff)" >&2
    return 0
  fi

  # D3 — LOOP BUDGET: stop debating once this run has spent DEBATE_WALL_TOTAL seconds across ALL debates, and
  # say WHICH specs that cost. Checked here, before any turn, so an exhausted budget never leaves a partial
  # transcript behind.
  local _wtot _spent; _wtot="$(_debate_budget_limit)"; _spent="$(_debate_budget_spent)"
  if [ "$_wtot" -gt 0 ] 2>/dev/null && [ "$_spent" -ge "$_wtot" ] 2>/dev/null; then
    printf 'skip\t%s\n' "$slug" >> "$(_debate_budget_state)" 2>/dev/null || true
    printf 'debate: WALL BUDGET EXHAUSTED — %ss spent this run, DEBATE_WALL_TOTAL=%ss. SKIPPING %s "%s" UNDEBATED. Undebated so far: %s. Raise DEBATE_WALL_TOTAL (or set 0 for no limit) to debate these.\n' \
      "$_spent" "$_wtot" "$mode" "$slug" "$(_debate_budget_skipped)" >&2
    return 0
  fi

  # D4 — transcripts are RUN-SCOPED. This used to be a single `$dir/${mode}-debate-${slug}.md` opened with `>`,
  # so re-debating a slug TRUNCATED the previous run's transcript. The debate is the most expensive artifact
  # the pipeline produces (6263s in one measured run) and it was the only record of the argument — comparing
  # two runs of the same spec was simply impossible, which is how the D5 oscillation went unnoticed for so
  # long. Keep every run's transcript under debates/<run-id>/, and keep the old flat path working as a symlink
  # to the latest so existing docs, tooling and muscle memory still resolve.
  local rdir="$dir/debates/$rid"; mkdir -p "$rdir" 2>/dev/null
  local trf="$rdir/${mode}-debate-${slug}.md"
  local latest="$dir/${mode}-debate-${slug}.md"
  printf '# %s debate · %s\n\n- run: %s\n- defender (A): %s\n- challenger (B): %s\n- rounds: min %s · max %s · hard %s\n- artifact sha: %s\n' \
    "$mode" "$slug" "$rid" "$A" "$B" "${DEBATE_MIN:-2}" "${DEBATE_MAX:-4}" "${DEBATE_HARD_MAX:-10}" "$sha" > "$trf"
  # relative target so the cache dir stays relocatable; -n so an existing symlink is replaced, not followed
  # into (which would drop the new transcript INSIDE the previous run's directory).
  ln -sfn "debates/$rid/${mode}-debate-${slug}.md" "$latest" 2>/dev/null || true

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
    cprompt="ROLE: CHALLENGER (turn $round). Pressure-test $art_label below — thorough, multi-layered, do not spare depth.
RESEARCH (you have tools; USE them before asserting): for any claim about a THIRD-PARTY system — an external API contract, data-feed format, rate limit, auth flow, library behaviour, pricing, or version — verify it against a real source with firecrawl_search / firecrawl_scrape / webfetch rather than recalling it. Prefer official docs; ${ACE_DEBATE_RESEARCH_MAX:-3} lookups is plenty, keep them targeted. Cite what you actually fetched as (source: <url>).
If a source is UNREACHABLE (anti-bot, paywall, 404, timeout) you MUST say so as: UNVERIFIED — <claim> (source unreachable: <url>, <reason>). NEVER silently substitute recalled knowledge for a fetch that failed, and never present recalled knowledge in the shape of a citation. An admitted gap is useful; a confident invention is a defect that survives every gate this project has, because nothing downstream can check an external claim.
A spec that COMMITS to an external source you could not reach is itself a finding — raise it (the dependency may be the wrong choice).$([ "$round" -gt 1 ] && printf ' Press still-DISPUTED points; DROP refuted ones; raise a NEW point only if the dialogue genuinely surfaced it.')
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
    dprompt="ROLE: DEFENDER (turn $round). You OWN $art_label. Answer EVERY open point by id — CONCEDE / DEFEND (grounded) / CLARIFY.
GROUNDING: defend a claim about a THIRD-PARTY system only with a source you actually fetched (firecrawl_scrape / webfetch), cited as (source: <url>). If you cannot reach one, CONCEDE the point as UNVERIFIED rather than defending it from memory — an unsourced external claim is exactly the kind that ships wrong. Concede what is genuinely right; refute what is wrong, with evidence.
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
  _debate_log_metric "$mode" "$slug" "$A" "$B" "$_rdone" "$conv" "$_start" "$_ic" "$trf" "$_rtsv" "$sha" 2>/dev/null || true
  # D3: charge this debate's wall time to the run's budget. AFTER the debate, unconditionally — a debate that
  # died fail-open still consumed the wall clock, and not charging it would let a run of failing debates spend
  # unbounded time while the budget reads zero.
  _debate_budget_add "$(( $(date +%s) - _start ))" 2>/dev/null || true
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
    # ── D3 (loop budget) · D4 (transcript retention) · D5 (convergence memo) ──────────────────────────────
    # D4/D5 need no elapsed time, so they run on the FAST stub; only the D3 budget case swaps in a slow one
    # (below), which keeps this whole block a few seconds rather than a minute.
    printf '#!/usr/bin/env bash\necho "no blocking issues."\necho "CONVERGED: yes"\n' > bin/opencode
    chmod +x bin/opencode
    local sp
    for sp in aa bb cc; do
      printf '<!-- ace-spec-template v1 -->\n# Spec (slug: %s · risk: HIGH)\n## 3. Scope\n' "$sp" > "$sp.md"
    done
    # one place for the knobs every case below shares; a subshell so exports never leak between cases
    _dbg(){ ( export PATH="$PWD/bin:$PATH" DEBATE_MODEL_A=stub DEBATE_MODEL_B=openrouter/stub \
                DEBATE_MIN=1 DEBATE_MAX=1 DEBATE_HARD_MAX=1 DEBATE_TIMEOUT=10 DEBATE_WALL_MAX=30; "$@" ); }

    # D4: TRANSCRIPTS ARE EVIDENCE AND MUST SURVIVE. The path was a single flat file opened with `>`, so
    # re-debating a slug TRUNCATED the previous run's transcript — comparing two runs of the same spec was
    # impossible, which is exactly how the D5 oscillation went unnoticed. Two runs, same slug, both survive.
    rm -rf .opencode/cache
    ( export RUN_ID=r1 DEBATE_MEMO=0; _dbg ace_debate spec aa.md ) >/dev/null 2>&1
    ( export RUN_ID=r2 DEBATE_MEMO=0; _dbg ace_debate spec aa.md ) >/dev/null 2>&1
    { [ -f .opencode/cache/debates/r1/spec-debate-aa.md ] && [ -f .opencode/cache/debates/r2/spec-debate-aa.md ]; } \
      || { echo "[debate] D4: re-debating a slug did not leave BOTH run transcripts on disk"; ls -R .opencode/cache 2>/dev/null | sed 's/^/    /'; ok=0; }
    # the convenience path still resolves, and points at the LATEST run
    [ -f .opencode/cache/spec-debate-aa.md ] || { echo "[debate] D4: the stable convenience transcript path stopped resolving"; ok=0; }
    [ "$(readlink .opencode/cache/spec-debate-aa.md 2>/dev/null)" = "debates/r2/spec-debate-aa.md" ] \
      || { echo "[debate] D4: the convenience path does not point at the latest run (got '$(readlink .opencode/cache/spec-debate-aa.md 2>/dev/null)')"; ok=0; }
    # the metrics log stays in ONE cumulative file (it is derived from the cache dir, NOT from the transcript
    # path — deriving it from the transcript would scatter it one-per-run and break `ace debate report`)
    [ -f .opencode/cache/debate-metrics.jsonl ] \
      || { echo "[debate] D4: debate-metrics.jsonl left the cache root — ace debate report / scorecard read that path"; ok=0; }
    if command -v jq >/dev/null 2>&1; then
      # (c) the recorded transcript must resolve to the RUN-SCOPED file, so history is navigable. Pointing it
      # at the symlink would make every old record silently describe the newest dialogue.
      out="$(jq -rs '[.[]|select(.slug=="aa")]|last.transcript' .opencode/cache/debate-metrics.jsonl 2>/dev/null)"
      [ -f "$out" ] || { echo "[debate] D4: the JSONL transcript field does not resolve to a file: '$out'"; ok=0; }
      case "$out" in *debates/r2/*) ;; *) echo "[debate] D4: transcript field must record the run-scoped path, got '$out'"; ok=0 ;; esac
      out="$(jq -rs '[.[]|select(.slug=="aa")]|length' .opencode/cache/debate-metrics.jsonl 2>/dev/null)"
      [ "$out" = 2 ] || { echo "[debate] D4: expected 2 cumulative records for slug aa, got '$out'"; ok=0; }
    fi

    # D5: the CONVERGENCE MEMO. Same content + previously converged ⇒ skip, LOUDLY. A genuine edit ⇒ debate.
    # Both directions are load-bearing: a memo that never hits saves nothing, and one that never misses would
    # freeze a spec's review forever after its first convergence.
    if command -v jq >/dev/null 2>&1; then
      out="$( ( export RUN_ID=r3; _dbg ace_debate spec aa.md ) 2>&1 )"
      [ -f .opencode/cache/debates/r3/spec-debate-aa.md ] \
        && { echo "[debate] D5: unchanged, already-converged spec was RE-DEBATED (a full transcript was produced)"; ok=0; }
      grep -qi 'already CONVERGED' <<<"$out" \
        || { echo "[debate] D5: the memo skip was SILENT — a run that debated nothing must not look like one that debated everything: $out"; ok=0; }
      grep -qi 'DEBATE_MEMO=0' <<<"$out" || { echo "[debate] D5: the memo skip must say how to override it: $out"; ok=0; }
      # ...now a GENUINE edit must re-debate. This is the direction that would strand a spec if it regressed.
      printf '\n## C1. Contract\nPOST /api/aa returns {id} — a real change to the artifact.\n' >> aa.md
      ( export RUN_ID=r4; _dbg ace_debate spec aa.md ) >/dev/null 2>&1
      [ -f .opencode/cache/debates/r4/spec-debate-aa.md ] \
        || { echo "[debate] D5: an EDITED spec was memo-skipped — the memo must key on CONTENT, not on the slug"; ok=0; }
      # and the hash that makes that possible is actually recorded
      out="$(jq -rs '[.[]|select(.slug=="aa")]|last.artifact_sha' .opencode/cache/debate-metrics.jsonl 2>/dev/null)"
      case "${out:-}" in ''|null) echo "[debate] D5: artifact_sha missing from the metrics record — nothing can memoize without it"; ok=0 ;; esac
    fi

    # D3: the LOOP budget. DEBATE_WALL_MAX caps ONE debate; nothing capped the loop, so 10 specs x 1800s was a
    # reachable 5-hour synchronous planning gate (a measured run spent 6263s in debates). Budget of 2s: the
    # first spec spends ~3s, so every LATER spec must be refused — and must be NAMED, because a silently
    # shortened gate is indistinguishable from a fully-debated one. Now the SLOW stub (~1s/turn): the budget
    # must be tripped by genuine elapsed wall time, not by writing a number into its counter — the counter is
    # part of what is under test.
    printf '#!/usr/bin/env bash\nsleep 1\necho "no blocking issues."\necho "CONVERGED: yes"\n' > bin/opencode
    chmod +x bin/opencode
    rm -rf .opencode/cache
    ( export RUN_ID=bud DEBATE_MEMO=0 DEBATE_WALL_TOTAL=2; _dbg ace_debate spec aa.md ) >/dev/null 2>&1
    [ -f .opencode/cache/debates/bud/spec-debate-aa.md ] \
      || { echo "[debate] D3: the FIRST spec must debate normally — a budget must not refuse everything"; ok=0; }
    out="$( ( export RUN_ID=bud DEBATE_MEMO=0 DEBATE_WALL_TOTAL=2; _dbg ace_debate spec bb.md ) 2>&1 )"
    [ -f .opencode/cache/debates/bud/spec-debate-bb.md ] \
      && { echo "[debate] D3: the budget was exhausted but the next spec debated anyway — the loop is unbounded"; ok=0; }
    grep -qi 'BUDGET EXHAUSTED' <<<"$out" || { echo "[debate] D3: budget stop was SILENT: $out"; ok=0; }
    grep -qi 'bb' <<<"$out"               || { echo "[debate] D3: the budget stop must NAME the spec it skipped: $out"; ok=0; }
    grep -qi 'DEBATE_WALL_TOTAL' <<<"$out" || { echo "[debate] D3: the budget stop must name the knob that caused it: $out"; ok=0; }
    # ...and the list ACCUMULATES, so the last line names everything that went undebated, not just the newest
    out="$( ( export RUN_ID=bud DEBATE_MEMO=0 DEBATE_WALL_TOTAL=2; _dbg ace_debate spec cc.md ) 2>&1 )"
    grep -qi 'bb,cc' <<<"$out" \
      || { echo "[debate] D3: the undebated list must accumulate across the loop (want 'bb,cc'): $out"; ok=0; }
    # the budget is a KNOB, not a hard-coded cap: 0 disables it and the same spec debates
    out="$( ( export RUN_ID=bud DEBATE_MEMO=0 DEBATE_WALL_TOTAL=0; _dbg ace_debate spec cc.md ) 2>&1 )"
    [ -f .opencode/cache/debates/bud/spec-debate-cc.md ] \
      || { echo "[debate] D3: DEBATE_WALL_TOTAL=0 must disable the budget, not keep refusing: $out"; ok=0; }

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
