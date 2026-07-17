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
  local hit=$(( nd*100/tot ))
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

ace_scorecard(){
  local json=0 a
  for a in "$@"; do case "$a" in --json) json=1 ;; --repo=*) SC_REPO="${a#*=}" ;; --swarm-dir=*) SC_SWARM="${a#*=}" ;; esac; done
  _sc_resolve
  printf '%s══ ace scorecard · %s ══%s\n' "${C_BOLD:-}" "$(basename "$SC_REPO")" "${C_RESET:-}"
  printf '   project %s · swarm %s\n' "$SC_OC" "$([ -f "$SC_SWARM/events.jsonl" ] && echo "$SC_SWARM" || echo '(none — solo)')"
  _sc_research; _sc_features; _sc_subtasks; _sc_results
  # ⑤–⑧ + --json + VERDICT land in the next change
  [ "$json" = 1 ] && echo && echo '{"note":"--json output lands with sections 5-8 (next PR)"}'
  return 0
}

# standalone CLI (sourced: quiet)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then ace_scorecard "$@"; fi
