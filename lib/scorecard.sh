#!/usr/bin/env bash
# scorecard.sh — `ace scorecard`: aggregate a FINISHED run's artifacts into a multi-level measurement report.
# Pure READ-ONLY over .opencode/ (project) + the swarm state dir. FAIL-SOFT: a missing artifact renders "—",
# never an error. No hot-loop instrumentation — a run behaves identically whether or not you score it.
# Sections: ① research ② feature-breakdown ③ subtasks ④ result-quality (⑤–⑧ debate/logging/anomalies/edge added
# alongside --json + the top-line VERDICT).

# number from a grep -c (grep prints "0" on no match but exits 1 — never use `|| echo 0`, it double-prints).
_gc(){ local n; n="$(grep -c "$@" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
# count OCCURRENCES (grep -c counts lines; a line with 3 [blocker]s should count 3).
_go(){ local n; n="$(grep -o "$@" 2>/dev/null | wc -l | tr -d ' ')"; printf '%s' "${n:-0}"; }
# the ACE install's lib dir (swarm.sh lives HERE, not in the scored project).
_SC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

_sc_resolve(){
  SC_REPO="${SC_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  SC_OC="$SC_REPO/.opencode"
  local slug d; slug="$(basename "$SC_REPO")"
  for d in "${SC_SWARM:-}" "$HOME/.config/ace/swarm/$slug/state" "$HOME/.config/ace/swarm/$slug"; do
    [ -n "$d" ] && [ -f "$d/events.jsonl" ] && { SC_SWARM="$d"; return; }
  done
  SC_SWARM="${SC_SWARM:-$HOME/.config/ace/swarm/$slug}"
}

# ① RESEARCH — was research done + used where it should be, and is it grounded?
_sc_research(){
  printf '\n%s① RESEARCH%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local nspec=0 cited=0 unver=0 s
  if [ -d "$SC_OC/specs" ]; then
    for s in "$SC_OC"/specs/*.md; do [ -f "$s" ] || continue; nspec=$((nspec+1))
      cited=$(( cited + $(_gc -F '(cites ' "$s") )); unver=$(( unver + $(_gc -i 'UNVERIFIED' "$s") )); done
  fi
  if [ "$nspec" = 0 ]; then printf '   — no specs at %s (no research artifacts)\n' "$SC_OC/specs/"; return; fi
  # researcher delegated? (log-grep, best-effort — the researcher runs inside opencode)
  local rlog=0 lg
  for lg in "$SC_OC/last-run.log" "$SC_SWARM/coordinator.log" "$SC_SWARM"/w*.log; do [ -f "$lg" ] && rlog=$(( rlog + $(_gc -iE 'researcher|research & design|comparable product' "$lg") )); done
  # residual grounding gaps from a lint pass
  local rgaps=0
  [ -f "$_SC_LIB/swarm.sh" ] && { rgaps="$(REPO="$SC_REPO" bash "$_SC_LIB/swarm.sh" spec-lint "$SC_OC"/specs/*.md 2>/dev/null | _gc -E 'SPECGAP.*(CITED|CITE_REAL|SOURCED)')"; }
  printf '   specs %s · citations %s (%s/spec) · UNVERIFIED %s · grounding-gaps %s\n' "$nspec" "$cited" "$(( cited / nspec ))" "$unver" "$rgaps"
  if [ "$rlog" = 0 ]; then printf '   %s⚠ researcher not seen in logs — confirm research was delegated for [value] features%s\n' "${C_YELLOW:-}" "${C_RESET:-}"
  else printf '   researcher activity in logs: %s reference(s)\n' "$rlog"; fi
  [ "$unver" -gt "$cited" ] && printf '   %s⚠ more UNVERIFIED than cited claims — research grounding is thin%s\n' "${C_YELLOW:-}" "${C_RESET:-}"
}

# ② FEATURE BREAKDOWN — spec quality: gaps, increments, AC coverage, oversize
_sc_features(){
  printf '\n%s② FEATURE BREAKDOWN (spec quality)%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  [ -d "$SC_OC/specs" ] && ls "$SC_OC"/specs/*.md >/dev/null 2>&1 || { printf '   — no specs\n'; return; }
  [ -f "$_SC_LIB/swarm.sh" ] || { printf '   — swarm.sh unavailable for lint\n'; return; }
  local lint; lint="$(REPO="$SC_REPO" bash "$_SC_LIB/swarm.sh" spec-lint "$SC_OC"/specs/*.md 2>/dev/null)"
  local nspec gaps accov incsz ears
  nspec=$(printf '%s\n' "$lint" | sed -n 's/^spec-lint: \([0-9]*\) spec.*/\1/p' | tail -1); nspec="${nspec:-$(ls "$SC_OC"/specs/*.md 2>/dev/null | wc -l)}"
  gaps=$(printf '%s\n' "$lint" | _gc '^SPECGAP'); accov=$(printf '%s\n' "$lint" | _gc -E 'SPECGAP.*AC_COVER')
  incsz=$(printf '%s\n' "$lint" | _gc -E 'SPECGAP.*INC_SIZE'); ears=$(printf '%s\n' "$lint" | _gc -E 'SPECGAP.*EARS')
  # increments per feature = §6 numbered lines
  local totinc=0 s n
  for s in "$SC_OC"/specs/*.md; do [ -f "$s" ] || continue
    n=$(awk '/^## 6\./{f=1;next} /^## /{f=0} f && /^[0-9]+\./{c++} END{print c+0}' "$s"); totinc=$(( totinc + n )); done
  SC_GAPS="$gaps"; SC_NSPEC="$nspec"
  printf '   specs %s · total spec-gaps %s (AC-coverage %s · oversize-increment %s · EARS %s)\n' "$nspec" "$gaps" "$accov" "$incsz" "$ears"
  [ "$nspec" -gt 0 ] && printf '   increments/feature: %s avg · first-pass clean: %s\n' "$(( totinc / (nspec>0?nspec:1) ))" "$([ "$gaps" = 0 ] && echo 'yes ✓' || echo "no ($gaps gap(s))")"
}

# ③ SUBTASKS — hit rate + manageability (from the swarm bus + plan-lint)
_sc_subtasks(){
  printf '\n%s③ SUBTASKS — hit rate + manageability%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local ev="$SC_SWARM/events.jsonl"
  [ -f "$ev" ] || { printf '   — no swarm events (solo run / no run at %s)\n' "$SC_SWARM"; return; }
  command -v jq >/dev/null 2>&1 || { printf '   — jq required\n'; return; }
  local red; red="$(jq -rc 'select(.phase=="done" or .phase=="conflict" or .phase=="gate-red" or .phase=="stopped" or .phase=="incomplete")|[.worker,.feat,.phase]|@tsv' "$ev" 2>/dev/null | awk -F'\t' '{o[$1 FS $2]=$3} END{for(k in o) print o[k]}')"
  local nd nc ng ns ni tot
  nd=$(printf '%s\n' "$red" | _gc '^done'); nc=$(printf '%s\n' "$red" | _gc '^conflict'); ng=$(printf '%s\n' "$red" | _gc '^gate-red')
  ns=$(printf '%s\n' "$red" | _gc '^stopped'); ni=$(printf '%s\n' "$red" | _gc '^incomplete'); tot=$(( nd+nc+ng+ns+ni ))
  if [ "$tot" = 0 ]; then printf '   — no terminal subtask events yet\n'; return; fi
  local hit=$(( nd*100/tot )); SC_HIT="$hit"; SC_ITEMS="$tot"; SC_DONE="$nd"
  local aband; aband=$(jq -rc 'select(.phase=="abandoned")|1' "$ev" 2>/dev/null | _gc '1')
  local bp="$SC_SWARM/batch-plan.txt" coll=0 over=0
  [ -f "$bp" ] && { coll=$(_gc '^COLLIDE' "$bp"); over=$(_gc '^OVERSIZE' "$bp"); }
  local peak; peak="$(jq -rc 'select(.phase=="claimed" or .phase=="done" or .phase=="conflict" or .phase=="error" or .phase=="idle")|[.ts,(if .phase=="claimed" then 1 else -1 end)]|@tsv' "$ev" 2>/dev/null | sort -n | awk '{c+=$2; if(c>m)m=c} END{print m+0}')"
  printf '   items %s · done %s · conflict %s · gate-red %s · stopped %s · incomplete %s\n' "$tot" "$nd" "$nc" "$ng" "$ns" "$ni"
  printf '   %sHIT RATE %s%%%s (done/total) · peak concurrency %s\n' "${C_BOLD:-}" "$hit" "${C_RESET:-}" "${peak:-?}"
  printf '   manageability: %s collision(s) · %s oversize task(s) · %s abandoned\n' "$coll" "$over" "$aband"
  [ "$hit" -lt 60 ] && printf '   %s⚠ low hit rate — inspect conflict/gate-red items (ace swarm tail · events.jsonl)%s\n' "${C_YELLOW:-}" "${C_RESET:-}"
}

# ④ RESULT QUALITY — verifier + critics + retries (from logs, best-effort; critic-FP CSV isn't populated live)
_sc_results(){
  printf '\n%s④ RESULT QUALITY%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local logs=() lg; [ -f "$SC_OC/last-run.log" ] && logs+=("$SC_OC/last-run.log")
  for lg in "$SC_SWARM"/w*.log; do [ -f "$lg" ] && logs+=("$lg"); done
  if [ "${#logs[@]}" = 0 ]; then printf '   — no run logs found\n'; return; fi
  local vpass=0 vfail=0 appr=0 chg=0 blk=0 maj=0 minr=0
  for lg in "${logs[@]}"; do
    vpass=$(( vpass + $(_gc -E '^PASS\b' "$lg") )); vfail=$(( vfail + $(_gc -E '^FAIL\b' "$lg") ))
    appr=$(( appr + $(_gc -F 'APPROVE' "$lg") )); chg=$(( chg + $(_gc -F 'CHANGES_REQUESTED' "$lg") ))
    blk=$(( blk + $(_go -F '[blocker]' "$lg") )); maj=$(( maj + $(_go -F '[major]' "$lg") )); minr=$(( minr + $(_go -F '[minor]' "$lg") ))
  done
  # CI-fix retries from the run summary / metrics
  local retries='—'
  [ -f "$SC_OC/run-summary.txt" ] && retries="$(grep -oE 'ci_fixes=[0-9]+' "$SC_OC/run-summary.txt" 2>/dev/null | tail -1 | cut -d= -f2)"
  [ -z "$retries" ] && retries='—'
  local escaped='—'; [ -f "$SC_OC/eval-report.md" ] && escaped="$(grep -iE 'escaped.bug' "$SC_OC/eval-report.md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"; [ -z "$escaped" ] && escaped='—'
  printf '   verifier: PASS %s · FAIL %s   |   critics: APPROVE %s · CHANGES_REQUESTED %s\n' "$vpass" "$vfail" "$appr" "$chg"
  printf '   findings: [blocker] %s · [major] %s · [minor] %s · CI-fix retries %s · escaped-bugs %s\n' "$blk" "$maj" "$minr" "$retries" "$escaped"
  printf '   %s(critic accept/reject rates need the DB/opencode seam — these are log-grep counts)%s\n' "${C_GREY:-}" "${C_RESET:-}"
}

# ⑤ DEBATE — the cross-model barter: convergence, accepted vs disputed, effectiveness
_sc_debate(){
  printf '\n%s⑤ DEBATE (cross-model barter)%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local dm="$SC_OC/cache/debate-metrics.jsonl"
  [ -f "$dm" ] && command -v jq >/dev/null 2>&1 || { printf '   — no debates this run (SPEC_DEBATE/REVIEW_DEBATE off, or none HIGH-risk)\n'; return; }
  local agg; agg="$(jq -s 'if length==0 then empty else {n:length,conv:(map(select(.converged))|length),capped:(map(select(.wall_capped))|length),rounds:((map(.rounds)|add)/length*10|round/10),acc:(map(.per_round|(map(.accepted)|add)//0)|add),disp:(map(.per_round|(map(.disputed)|add)//0)|add),issues:(map(.issues_emitted)|add)} end' "$dm" 2>/dev/null)"
  [ -n "$agg" ] || { printf '   — no debate records\n'; return; }
  local n conv capped rounds acc disp issues
  n=$(jq -r '.n' <<<"$agg"); conv=$(jq -r '.conv' <<<"$agg"); capped=$(jq -r '.capped' <<<"$agg"); rounds=$(jq -r '.rounds' <<<"$agg")
  acc=$(jq -r '.acc' <<<"$agg"); disp=$(jq -r '.disp' <<<"$agg"); issues=$(jq -r '.issues' <<<"$agg")
  local convpct=0; [ "$n" -gt 0 ] && convpct=$(( conv*100/n )); SC_CONVPCT="$convpct"; SC_NDEBATE="$n"
  printf '   debates %s · converged %s (%s%%) · wall-capped %s · avg rounds %s\n' "$n" "$conv" "$convpct" "$capped" "$rounds"
  printf '   accepted %s · disputed %s · issues emitted %s\n' "$acc" "$disp" "$issues"
  local hist="$_SC_LIB/../tests/debate-sandbox/effectiveness-history.jsonl"
  [ -f "$hist" ] && { SC_F1="$(jq -rs '.[-1].f1 // "—"' "$hist" 2>/dev/null)"; printf '   effectiveness (last score): F1 %s\n' "$SC_F1"; }
  [ "$n" -gt 0 ] && [ "$convpct" -lt 50 ] && printf '   %s⚠ low convergence — debaters not agreeing; check DEBATE_MAX / models (ace debate report)%s\n' "${C_YELLOW:-}" "${C_RESET:-}"
}

# ⑥ LOGGING COMPLETENESS — are the expected artifacts present + non-empty?
_sc_logging(){
  printf '\n%s⑥ LOGGING COMPLETENESS%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local present=0 total=0
  _chk(){ total=$((total+1)); if [ -s "$1" ]; then present=$((present+1)); printf '   ✓ %s\n' "$2"; elif [ -e "$1" ]; then printf '   ~ %s (empty)\n' "$2"; else printf '   ✗ %s (missing)\n' "$2"; fi; }
  _chk "$SC_OC/metrics.csv" "metrics.csv"; _chk "$SC_OC/run-summary.txt" "run-summary.txt"; _chk "$SC_OC/token-report.md" "token-report.md"
  total=$((total+1)); if ls "$SC_OC"/specs/*.md >/dev/null 2>&1; then present=$((present+1)); printf '   ✓ specs/ (%s)\n' "$(ls "$SC_OC"/specs/*.md | wc -l | tr -d ' ')"; else printf '   ✗ specs/ (missing)\n'; fi
  if [ -f "$SC_SWARM/events.jsonl" ]; then
    _chk "$SC_SWARM/events.jsonl" "events.jsonl"; _chk "$SC_SWARM/coordinator.log" "coordinator.log"; _chk "$SC_SWARM/batch-plan.txt" "batch-plan.txt"
    total=$((total+1)); if ls "$SC_SWARM"/w*.log >/dev/null 2>&1; then present=$((present+1)); printf '   ✓ worker logs (%s)\n' "$(ls "$SC_SWARM"/w*.log | wc -l | tr -d ' ')"; else printf '   ✗ worker logs (missing)\n'; fi
  fi
  [ -f "$SC_OC/cache/debate-metrics.jsonl" ] && _chk "$SC_OC/cache/debate-metrics.jsonl" "debate-metrics.jsonl"
  local pct=0; [ "$total" -gt 0 ] && pct=$(( present*100/total )); SC_LOGPCT="$pct"
  printf '   completeness: %s/%s (%s%%)\n' "$present" "$total" "$pct"
}

# ⑦ ANOMALIES — unexpected results surfaced during the run
_sc_anomalies(){
  printf '\n%s⑦ ANOMALIES (unexpected)%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local found=0 ev="$SC_SWARM/events.jsonl" lg
  if [ -f "$ev" ] && command -v jq >/dev/null 2>&1; then
    local na rm ab
    na=$(jq -rc 'select(.phase=="needs-attention")|1' "$ev" 2>/dev/null | _gc '1')
    rm=$(jq -rc 'select(.phase=="red-main" or .phase=="gate-red")|1' "$ev" 2>/dev/null | _gc '1')
    ab=$(jq -rc 'select(.phase=="abandoned" or .phase=="reap")|1' "$ev" 2>/dev/null | _gc '1')
    [ "$na" -gt 0 ] && { printf '   needs-attention: %s (ace swarm tail)\n' "$na"; found=$((found+na)); }
    [ "$rm" -gt 0 ] && { printf '   RED-main / gate-red: %s\n' "$rm"; found=$((found+rm)); }
    [ "$ab" -gt 0 ] && { printf '   abandoned / reap: %s\n' "$ab"; found=$((found+ab)); }
  fi
  local hang=0 rat=0 cap=0
  for lg in "$SC_OC/last-run.log" "$SC_SWARM/coordinator.log" "$SC_SWARM"/w*.log; do [ -f "$lg" ] && { hang=$(( hang + $(_gc -F '⛔ HANG' "$lg") )); rat=$(( rat + $(_gc -iF 'rathole' "$lg") )); cap=$(( cap + $(_gc -iF 'usage limit' "$lg") )); }; done
  [ "$hang" -gt 0 ] && { printf '   HANG kills: %s\n' "$hang"; found=$((found+hang)); }
  [ "$rat" -gt 0 ] && { printf '   rathole signals: %s\n' "$rat"; found=$((found+rat)); }
  [ "$cap" -gt 0 ] && { printf '   provider usage-limit pauses: %s\n' "$cap"; found=$((found+cap)); }
  SC_ANOM="$found"; [ "$found" = 0 ] && printf '   — none detected ✓\n'
}

# ⑧ EDGE CASES — did a fallback / rare path activate?
_sc_edge(){
  printf '\n%s⑧ EDGE CASES (did a fallback path fire?)%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  local any=0 lg fo=0 un=0
  for lg in "$SC_OC/last-run.log" "$SC_SWARM/coordinator.log" "$SC_SWARM"/w*.log; do [ -f "$lg" ] && { fo=$(( fo + $(_gc -F 'fail-open' "$lg") )); un=$(( un + $(_gc -F 'UNRESOLVABLE' "$lg") )); }; done
  [ "$fo" -gt 0 ] && { printf '   • fail-open fired %s× — a gate degraded gracefully; confirm it was intended\n' "$fo"; any=1; }
  [ "$un" -gt 0 ] && { printf '   • UNRESOLVABLE conflict %s× — needs a human\n' "$un"; any=1; }
  local feat=''; [ -f "$SC_OC/run-summary.txt" ] && feat="$(grep -oE 'features=[0-9]+' "$SC_OC/run-summary.txt" | tail -1 | cut -d= -f2)"; SC_FEAT="${feat:-—}"
  [ "${feat:-1}" = 0 ] && { printf '   • 0 features shipped this run — planning-only or stuck?\n'; any=1; }
  local dm="$SC_OC/cache/debate-metrics.jsonl"
  [ -f "$dm" ] && command -v jq >/dev/null 2>&1 && { local z; z=$(jq -s 'if length>=3 and ((map(.issues_emitted)|add)==0) then 1 else 0 end' "$dm" 2>/dev/null); [ "$z" = 1 ] && { printf '   • debate flagged 0 issues across ALL HIGH-risk specs — over-agreeable? (ace debate diagnose)\n'; any=1; }; }
  [ "$any" = 0 ] && printf '   — no edge paths activated ✓\n'
}

ace_scorecard(){
  local json=0 a; SC_GAPS=- SC_HIT=- SC_CONVPCT=- SC_LOGPCT=- SC_ANOM=0 SC_FEAT=- SC_NDEBATE=0 SC_F1=- SC_NSPEC=-
  for a in "$@"; do case "$a" in --json) json=1 ;; --repo=*) SC_REPO="${a#*=}" ;; --swarm-dir=*) SC_SWARM="${a#*=}" ;; esac; done
  _sc_resolve
  if [ "$json" = 1 ]; then
    { _sc_research; _sc_features; _sc_subtasks; _sc_results; _sc_debate; _sc_logging; _sc_anomalies; _sc_edge; } >/dev/null 2>&1
    command -v jq >/dev/null 2>&1 || { echo '{"error":"jq required for --json"}'; return 1; }
    jq -nc --arg repo "$(basename "$SC_REPO")" --arg feat "${SC_FEAT:-—}" --arg gaps "${SC_GAPS:-—}" \
       --arg hit "${SC_HIT:-—}" --arg conv "${SC_CONVPCT:-—}" --arg f1 "${SC_F1:-—}" \
       --argjson anom "${SC_ANOM:-0}" --arg logpct "${SC_LOGPCT:-—}" --argjson ndeb "${SC_NDEBATE:-0}" \
       '{repo:$repo,features:$feat,spec_gaps:$gaps,hit_rate_pct:$hit,debates:$ndeb,debate_converged_pct:$conv,debate_f1:$f1,anomalies:$anom,logging_pct:$logpct}'
    return 0
  fi
  printf '%s══ ace scorecard · %s ══%s\n' "${C_BOLD:-}" "$(basename "$SC_REPO")" "${C_RESET:-}"
  printf '   project %s · swarm %s\n' "$SC_OC" "$([ -f "$SC_SWARM/events.jsonl" ] && echo "$SC_SWARM" || echo '(none — solo)')"
  _sc_research; _sc_features; _sc_subtasks; _sc_results; _sc_debate; _sc_logging; _sc_anomalies; _sc_edge
  # top-line verdict
  printf '\n%s══ VERDICT ══%s\n' "${C_BOLD:-}" "${C_RESET:-}"
  printf '   features %s · subtask hit-rate %s%% · spec-gaps %s · debate conv %s%% (F1 %s) · anomalies %s · logging %s%%\n' \
    "${SC_FEAT}" "${SC_HIT}" "${SC_GAPS}" "${SC_CONVPCT}" "${SC_F1}" "${SC_ANOM}" "${SC_LOGPCT}"
  local health='healthy ✓' issues=''
  [ "${SC_HIT:-100}" != - ] && [ "${SC_HIT:-100}" -lt 60 ] 2>/dev/null && issues="$issues low-hit-rate;"
  [ "${SC_GAPS:-0}" != - ] && [ "${SC_GAPS:-0}" -gt 0 ] 2>/dev/null && issues="$issues spec-gaps;"
  [ "${SC_ANOM:-0}" -gt 0 ] 2>/dev/null && issues="$issues anomalies;"
  [ "${SC_LOGPCT:-100}" != - ] && [ "${SC_LOGPCT:-100}" -lt 80 ] 2>/dev/null && issues="$issues incomplete-logging;"
  [ -n "$issues" ] && health="needs attention:$issues"
  printf '   %s%s%s\n' "$([ -z "$issues" ] && echo "${C_GREEN:-}" || echo "${C_YELLOW:-}")" "$health" "${C_RESET:-}"
  return 0
}

# standalone CLI (sourced: quiet)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ace_scorecard "$@"; fi
