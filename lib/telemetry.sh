#!/usr/bin/env bash
# telemetry.sh — run-scoped, PER-SUBAGENT token/cost logging from opencode's session DB.
#
# WHY the DB (not last-run.log): opencode records every subagent invocation as its OWN `session`
# row with a first-class `agent` column plus `model`, all five token counters
# (tokens_input/cache_read/cache_write/output/reasoning), `cost`, `directory` (the worktree →
# the swarm WORKER), and `time_created` (→ the RUN window). So we can attribute EXACTLY which
# SUBAGENT spent what, on which WORKER, for which TASK, in which RUN — none of which the
# aggregate last-run.log grep (capture_usage/token_report) can see, because the orchestrator
# fires ONE `opencode run` and the subagents live inside it.
#
# Toggle: ACE_TELEMETRY=0 disables ALL telemetry (max throughput). Default 1 (full logging).
# Everything here is READ-ONLY on the DB (never locks opencode) and FAIL-SOFT (no python3 / no DB /
# a query error just yields no report — never a crash, never a blocked run).

telemetry_on(){ [ "${ACE_TELEMETRY:-1}" = 1 ]; }

# path to opencode's session DB (honors a per-worker OPENCODE_DB; falls back to the default store)
_telemetry_db(){
  local d="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"
  [ -f "$d" ] && { printf '%s' "$d"; return 0; }
  printf '%s' "$HOME/.local/share/opencode/opencode.db"   # per-worker DB may not exist for a solo run
}

# _telemetry_render <since_ms> <root_prefix> <scope_label>  — print the markdown report to stdout.
# rc 0 = report printed · 1 = unavailable (no python3/DB) · 2 = no sessions matched.
_telemetry_render(){
  local db since="${1:-0}" root="${2:-}" scope="${3:-}"
  db="$(_telemetry_db)"
  [ -f "$db" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$db" "$since" "$root" "$scope" "${RUN_ID:-?}" <<'PY'
import sqlite3, sys, re
from collections import defaultdict
db, since, root, scope, run_id = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3], sys.argv[4], sys.argv[5]
try:
    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True); con.execute('PRAGMA busy_timeout=2000'); cur = con.cursor()
except Exception:
    sys.exit(1)
where, args = ["time_created >= ?"], [since]
if root:
    where.append("(directory = ? OR directory LIKE ?)"); args += [root, root.rstrip('/') + '/%']
try:
    rows = cur.execute(
        "SELECT directory, COALESCE(NULLIF(agent,''),'(root)') ag, model, COUNT(*) n, "
        "SUM(tokens_input), SUM(tokens_cache_read), SUM(tokens_cache_write), "
        "SUM(tokens_output), SUM(tokens_reasoning), SUM(cost) "
        "FROM session WHERE " + " AND ".join(where) + " GROUP BY directory, ag, model", args).fetchall()
except Exception:
    sys.exit(1)
if not rows:
    sys.exit(2)
def worker(d):
    m = re.search(r'worktrees/([^/]+)', d or ''); return m.group(1) if m else 'main'
def h(n):
    n = n or 0
    for u,s in ((1e9,'B'),(1e6,'M'),(1e3,'k')):
        if abs(n) >= u: return f"{n/u:.1f}{s}"
    return str(int(n))
def modelname(m):
    if not m: return ''
    try:
        import json as _j; return _j.loads(m).get('id', m)
    except Exception:
        return str(m).split('/')[-1]
def cachepct(inp, cr):
    # cache-hit% = cached input / TOTAL prompt (fresh input + cache_read); opencode's tokens_input is
    # the FRESH (uncached) portion only, so dividing by it alone yields nonsense >100%.
    t = (inp or 0) + (cr or 0); return int((cr or 0)*100/t) if t else 0
agg = defaultdict(lambda: [0,0,0,0,0,0,0.0]); model = {}
for d,ag,mdl,n,tin,tcr,tcw,tout,treas,cost in rows:
    k=(worker(d),ag); a=agg[k]
    a[0]+=n; a[1]+=tin or 0; a[2]+=tcr or 0; a[3]+=tcw or 0; a[4]+=tout or 0; a[5]+=treas or 0; a[6]+=cost or 0.0
    model[k]=modelname(mdl)
T=[0,0,0,0,0,0,0.0]
for a in agg.values():
    for i in range(6): T[i]+=a[i]
    T[6]+=a[6]
print(f"# Token & cost report — {scope}")
print(f"\n_run `{run_id}` · source: opencode session DB (authoritative per-subagent)_\n")
print("| worker | subagent | model | sess | input | cache_read | cache% | output | cost |")
print("|---|---|---|--:|--:|--:|--:|--:|--:|")
for (wk,ag) in sorted(agg, key=lambda k: -agg[k][6]):
    a=agg[(wk,ag)]; pct=cachepct(a[1],a[2])
    print(f"| {wk} | {ag} | {model.get((wk,ag),'')} | {a[0]} | {h(a[1])} | {h(a[2])} | {pct}% | {h(a[4])} | ${a[6]:.4f} |")
tpct=cachepct(T[1],T[2])
print(f"| **TOTAL** | | | **{T[0]}** | **{h(T[1])}** | **{h(T[2])}** | **{tpct}%** | **{h(T[4])}** | **${T[6]:.2f}** |")
# cost hog + cache efficiency — the two actionable signals
if agg:
    hog=max(agg, key=lambda k: agg[k][6]); hv=agg[hog][6]
    share=int(hv*100/T[6]) if T[6] else 0
    print(f"\n**Cost hog:** `{hog[1]}` on `{hog[0]}` — ${hv:.2f} ({share}% of the total). "
          f"If a single agent dominates it is usually the overseer holding context or the HIGH-risk critic panel at max effort — risk-tier the panel or shorten its prompt.")
    print(f"\n**Cache efficiency:** {tpct}% of input served from prefix cache "
          f"(target ≥60% Opus / ≥70% DeepSeek). cache_write={h(T[3])}, reasoning={h(T[5])} tokens.")
PY
}

# subagent_report — END-OF-RUN report (called by the loop). Scopes to THIS run (since RUN_T0) and
# THIS project (its git root + any swarm worktrees under it) → .opencode/token-report.md.
# Falls back to the legacy per-run aggregate (token_report) when the DB path is unavailable.
subagent_report(){
  telemetry_on || return 0
  local out=.opencode/token-report.md root since
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  since=$(( ${RUN_T0:-0} * 1000 ))
  mkdir -p .opencode 2>/dev/null
  if _telemetry_render "$since" "$root" "run since $(date -d "@${RUN_T0:-0}" '+%F %T' 2>/dev/null || echo start)" > "$out.tmp" 2>/dev/null; then
    mv -f "$out.tmp" "$out"
    command -v say >/dev/null 2>&1 && say "token report → .opencode/token-report.md (per-subagent × worker tokens/cost from the opencode DB)"
    return 0
  fi
  rm -f "$out.tmp" 2>/dev/null
  command -v token_report >/dev/null 2>&1 && token_report   # fallback: legacy metrics.csv aggregate
}

# ace_stats — ON-DEMAND CLI: `ace stats [--days N|--all|--global]`. Prints the same report to stdout
# for the current project (default: all time) or --global (every project).
ace_stats(){
  telemetry_on || { echo "telemetry is OFF (ACE_TELEMETRY=0) — nothing logged."; return 0; }
  local days="" all=1 global=0 since=0 root scope
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:-7}"; all=0; shift; [ $# -gt 0 ] && shift ;;
      --days=*) days="${1#*=}"; all=0; shift ;;
      --all|all) all=1; days=""; shift ;;
      --global|global) global=1; shift ;;
      [0-9]*) days="$1"; all=0; shift ;;      # bare number = last-N-days (fits `ace stats 7`)
      *) shift ;;
    esac
  done
  if [ -n "$days" ]; then since=$(( ( $(date +%s) - days*86400 ) * 1000 )); fi
  if [ "$global" = 1 ]; then root=""; scope="ALL projects$([ -n "$days" ] && echo ", last ${days}d")";
  else root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; scope="$(basename "$root")$([ -n "$days" ] && echo " · last ${days}d" || echo " · all time")"; fi
  local rc; _telemetry_render "$since" "$root" "$scope"; rc=$?
  [ "$rc" = 1 ] && echo "no per-subagent telemetry available (needs python3 + opencode's session DB at ${OPENCODE_DB:-~/.local/share/opencode/opencode.db})."
  [ "$rc" = 2 ] && echo "no opencode sessions matched (scope: $scope). Run the loop first, or widen with --all / --global."
  return 0
}
