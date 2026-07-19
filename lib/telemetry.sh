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

# _telemetry_render <since_ms> <root_prefix> <scope_label> [by:agent|task]  — print the markdown report.
# rc 0 = report printed · 1 = unavailable (no python3/DB) · 2 = no sessions matched.
_telemetry_render(){
  local since="${1:-0}" root="${2:-}" scope="${3:-}" by="${4:-agent}" sdir="" d
  # Gather ALL relevant DBs: the default store + any per-worker SWARM DBs. E4 isolates each swarm worker's
  # opencode sessions into $SWARM_DIR/*.opencode.db (invisible to the default DB) — include them or swarm
  # cost is undercounted ~Nx. Worker sessions live under ~/.config/ace/swarm/<project>/worktrees/ (matched below).
  local dbs=(); local dflt="${OPENCODE_DB:-$HOME/.local/share/opencode/opencode.db}"; [ -f "$dflt" ] && dbs+=("$dflt")
  if [ -n "$root" ]; then
    sdir="$HOME/.config/ace/swarm/$(basename "$root")"
    for d in "$sdir"/*.opencode.db; do [ -f "$d" ] && dbs+=("$d"); done
  else
    for d in "$HOME"/.config/ace/swarm/*/*.opencode.db; do [ -f "$d" ] && dbs+=("$d"); done
  fi
  [ "${#dbs[@]}" -gt 0 ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$since" "$root" "$sdir" "$scope" "$by" "${RUN_ID:-?}" "${dbs[@]}" <<'PY'
import sqlite3, sys, re
from collections import defaultdict
since, root, sdir, scope, by, run_id = int(sys.argv[1] or 0), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
dbs = sys.argv[7:]
where, args = ["time_created >= ?"], [since]
def lk(s):
    # SQL LIKE metacharacters must be escaped in an interpolated PATH, or the scope filter silently widens:
    # `_` matches ANY single character, so a project at ~/code/my_app also matches ~/code/my-app, ~/code/myXapp
    # — foreign projects' sessions folded into this project's cost report. `%` (legal in a path) is worse: it
    # matches anything. Escape with a backslash and declare it via ESCAPE below.
    return (s or '').replace('\\', '\\\\').replace('_', '\\_').replace('%', '\\%')
if root:
    # a solo session's dir is under the project root; a swarm worker's is under ~/.config/ace/swarm/<proj>/worktrees/
    where.append("(directory = ? OR directory LIKE ? ESCAPE '\\' OR directory LIKE ? ESCAPE '\\')")
    args += [root, lk(root.rstrip('/')) + '/%', (lk(sdir.rstrip('/')) + '/%') if sdir else lk(root)]
W = " AND ".join(where)
def q(sql):   # UNION the query across every gathered DB (default + per-worker swarm DBs); fail-soft per DB
    out = []
    for db in dbs:
        try:
            con = sqlite3.connect(f'file:{db}?mode=ro', uri=True); con.execute('PRAGMA busy_timeout=2000')
            out += con.execute(sql, args).fetchall(); con.close()
        except Exception: pass
    return out
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
if by == 'task':
    rows = q("SELECT id, parent_id, COALESCE(NULLIF(agent,''),'(root)'), COALESCE(NULLIF(title,''),'(untitled)'), "
             "directory, tokens_input, tokens_cache_read, tokens_output, cost FROM session WHERE " + W)
else:
    # GROUP BY runs per-DB; the same (worker,agent,model) key across DBs is re-summed by the renderer below.
    rows = q("SELECT directory, COALESCE(NULLIF(agent,''),'(root)') ag, model, COUNT(*) n, "
             "SUM(tokens_input), SUM(tokens_cache_read), SUM(tokens_cache_write), "
             "SUM(tokens_output), SUM(tokens_reasoning), SUM(cost) "
             "FROM session WHERE " + W + " GROUP BY directory, ag, model")
if not rows:
    sys.exit(2)
print(f"# Token & cost report — {scope}")
print(f"\n_run `{run_id}` · source: opencode session DB (authoritative per-subagent)_\n")

if by == 'task':
    # roll every subagent session up to its ROOT task: walk parent_id to the top-most in-scope session,
    # whose title is the ROADMAP item the run was working. Answers "which task cost what, how many agents".
    sess = {r[0]: r for r in rows}
    def rootkey(sid):
        seen = set()
        while sid in sess and sess[sid][1] and sess[sid][1] in sess and sid not in seen:
            seen.add(sid); sid = sess[sid][1]
        r = sess.get(sid)
        return (worker(r[4]), r[3]) if r else ('main', '(untitled)')
    agg = defaultdict(lambda: [0, set(), 0, 0, 0, 0.0])   # sess, agents, in, cache_read, out, cost
    for r in rows:
        a = agg[rootkey(r[0])]
        a[0]+=1; a[1].add(r[2]); a[2]+=r[5] or 0; a[3]+=r[6] or 0; a[4]+=r[7] or 0; a[5]+=r[8] or 0.0
    T=[0,0,0,0,0.0]
    for a in agg.values():
        T[0]+=a[0]; T[1]+=a[2]; T[2]+=a[3]; T[3]+=a[4]; T[4]+=a[5]
    print("| task | worker | subagents | sess | input | cache_read | output | cost |")
    print("|---|---|--:|--:|--:|--:|--:|--:|")
    for k in sorted(agg, key=lambda k: -agg[k][5]):
        a=agg[k]
        print(f"| {k[1][:48]} | {k[0]} | {len(a[1])} | {a[0]} | {h(a[2])} | {h(a[3])} | {h(a[4])} | ${a[5]:.4f} |")
    print(f"| **TOTAL** | | | **{T[0]}** | **{h(T[1])}** | **{h(T[2])}** | **{h(T[3])}** | **${T[4]:.2f}** |")
    if agg:
        hog=max(agg, key=lambda k: agg[k][5]); hv=agg[hog][5]; share=int(hv*100/T[4]) if T[4] else 0
        print(f"\n**Costliest task:** `{hog[1][:60]}` on `{hog[0]}` — ${hv:.2f} ({share}% of the total, {len(agg[hog][1])} subagents).")
else:
    agg = defaultdict(lambda: [0,0,0,0,0,0,0.0]); models = defaultdict(set)
    for d,ag,mdl,n,tin,tcr,tcw,tout,treas,cost in rows:
        k=(worker(d),ag); a=agg[k]
        a[0]+=n; a[1]+=tin or 0; a[2]+=tcr or 0; a[3]+=tcw or 0; a[4]+=tout or 0; a[5]+=treas or 0; a[6]+=cost or 0.0
        # The GROUP BY key includes `model`, so one (worker,agent) legitimately spans several rows/models — an
        # agent whose model was overridden mid-run, or re-grouped per DB. Assigning a single name here was
        # last-write-wins: the totals were right but the row was LABELLED with whichever model the last row
        # happened to carry, so a multi-model agent was silently attributed to one model. Collect them all.
        models[k].add(modelname(mdl))
    def modelcol(k):
        ms = sorted(m for m in models.get(k, ()) if m)
        if not ms: return ''
        return ms[0] if len(ms) == 1 else f"{ms[0]} +{len(ms)-1}"
    T=[0,0,0,0,0,0,0.0]
    for a in agg.values():
        for i in range(6): T[i]+=a[i]
        T[6]+=a[6]
    print("| worker | subagent | model | sess | input | cache_read | cache% | output | cost |")
    print("|---|---|---|--:|--:|--:|--:|--:|--:|")
    for (wk,ag) in sorted(agg, key=lambda k: -agg[k][6]):
        a=agg[(wk,ag)]; pct=cachepct(a[1],a[2])
        print(f"| {wk} | {ag} | {modelcol((wk,ag))} | {a[0]} | {h(a[1])} | {h(a[2])} | {pct}% | {h(a[4])} | ${a[6]:.4f} |")
    tpct=cachepct(T[1],T[2])
    print(f"| **TOTAL** | | | **{T[0]}** | **{h(T[1])}** | **{h(T[2])}** | **{tpct}%** | **{h(T[4])}** | **${T[6]:.2f}** |")
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

# ace_stats — ON-DEMAND CLI: `ace stats [global] [N] [task]`. Prints the report to stdout for the
# current project (default: all time) or 'global' (every project); 'task' (or --by task) rolls up by
# ROADMAP task instead of the default per-subagent view; a bare number / --days N windows to N days.
ace_stats(){
  telemetry_on || { echo "telemetry is OFF (ACE_TELEMETRY=0) — nothing logged."; return 0; }
  local days="" all=1 global=0 since=0 root scope by=agent
  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="${2:-7}"; all=0; shift; [ $# -gt 0 ] && shift ;;
      --days=*) days="${1#*=}"; all=0; shift ;;
      --all|all) all=1; days=""; shift ;;
      --global|global) global=1; shift ;;
      --by) by="${2:-agent}"; shift; [ $# -gt 0 ] && shift ;;
      --by=*) by="${1#*=}"; shift ;;
      task|--task) by=task; shift ;;
      agent|--agent) by=agent; shift ;;
      [0-9]*) days="$1"; all=0; shift ;;      # bare number = last-N-days (fits `ace stats 7`)
      *) shift ;;
    esac
  done
  [ "$by" = task ] || by=agent   # normalize any unrecognized --by value
  if [ -n "$days" ]; then since=$(( ( $(date +%s) - days*86400 ) * 1000 )); fi
  if [ "$global" = 1 ]; then root=""; scope="ALL projects$([ -n "$days" ] && echo ", last ${days}d")$([ "$by" = task ] && echo " · by task")";
  else root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; scope="$(basename "$root")$([ -n "$days" ] && echo " · last ${days}d" || echo " · all time")$([ "$by" = task ] && echo " · by task")"; fi
  local rc; _telemetry_render "$since" "$root" "$scope" "$by"; rc=$?
  [ "$rc" = 1 ] && echo "no per-subagent telemetry available (needs python3 + opencode's session DB at ${OPENCODE_DB:-~/.local/share/opencode/opencode.db})."
  [ "$rc" = 2 ] && echo "no opencode sessions matched (scope: $scope). Run the loop first, or widen with --all / --global."
  return 0
}

# --- F4: QUALITY metrics — the leading indicators telemetry's COST view doesn't cover -------------------
# .opencode/quality-metrics.csv rows (type,agent,detail,outcome):
#   finding,<critic>,<severity>,accepted|rejected   a critic finding + whether the implementer accepted it
#   retry,<task>,<n>,                                CI-fix attempts for a task (catches a cheaper config
#                                                    that causes MORE retries — a false economy)
# The FALSE-POSITIVE rate is the most important missing metric: in an autonomous loop a wrong finding
# doesn't just annoy — it sends the implementer to "fix" a non-bug, burning a retry and sometimes creating
# a real defect. WIRING: the bash loop records the `retry` row at end-of-run (autoloop.sh — $fixes, the real
# CI-fix count). The per-critic `finding accepted|rejected` rows still need IN-OPENCODE capture (the 4 critics
# run INSIDE the orchestrator, not at a bash seam), so the FP table stays empty until that lands. quality_report renders.
# Gated by ACE_TELEMETRY; fail-soft.

quality_record(){ # <type> <agent> <detail> [outcome]  — append one quality row
  [ "${ACE_TELEMETRY:-1}" = 1 ] || return 0
  mkdir -p .opencode 2>/dev/null
  local f=.opencode/quality-metrics.csv
  [ -f "$f" ] || printf 'type,agent,detail,outcome\n' > "$f" 2>/dev/null
  printf '%s,%s,%s,%s\n' "$1" "${2:-?}" "$(printf '%s' "${3:-}" | tr ',\n' '; ')" "${4:-}" >> "$f" 2>/dev/null || true
}

quality_report(){ # aggregate -> .opencode/quality-report.md
  [ "${ACE_TELEMETRY:-1}" = 1 ] || return 0
  local f=.opencode/quality-metrics.csv out=.opencode/quality-report.md
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$f" ] || return 0
  # Render to a TEMP file and mv only on success — same pattern as subagent_report, for the same reason.
  # `python3 … > "$out" 2>/dev/null` TRUNCATES $out before python runs and swallows the traceback, so ONE
  # malformed CSV row (or any exception) destroyed the last good report and left a 0-byte file that
  # `ace quality` happily `cat`s: zero bytes, rc 0, no error anywhere. Now a failed render keeps the previous
  # report and says so.
  python3 - "$f" ".opencode/eval-report.md" <<'PY' > "$out.tmp" 2>/dev/null
import sys, csv, math
from collections import defaultdict
f, evalrep = sys.argv[1], sys.argv[2]
crit = defaultdict(lambda: [0,0])   # critic -> [total, rejected]
retries = []
with open(f) as fh:
    for r in csv.reader(fh):
        if not r or r[0] in ('type',''): continue
        r=(r+['','','',''])[:4]
        if r[0]=='finding':
            crit[r[1]][0]+=1
            if r[3].strip().lower()=='rejected': crit[r[1]][1]+=1
        elif r[0]=='retry':
            try: retries.append(int(r[2]))
            except: pass
def wilson(k,n,z=1.96):
    if n==0: return (0,0,0)
    p=k/n; d=1+z*z/n; c=(p+z*z/(2*n))/d; h=(z*math.sqrt(p*(1-p)/n+z*z/(4*n*n)))/d
    return (p,max(0,c-h),min(1,c+h))
print("# Quality report  (leading indicators — predict pass^k / escaped-bug that the nightly eval measures)\n")
print("## Critic false-positive rate  (rejected findings ÷ total — target <10%, <5% good, >20% = noise, prune it)")
if crit:
    print("| critic | findings | rejected | FP rate | flag |")
    print("|---|--:|--:|--:|:--|")
    for c in sorted(crit, key=lambda c:-(crit[c][1]/crit[c][0] if crit[c][0] else 0)):
        t,rej=crit[c]; p,lo,hi=wilson(rej,t)
        flag = "🔴 NOISE — prune/tighten" if p>0.20 else ("✅ good" if p<0.05 else "ok")
        print(f"| {c} | {t} | {rej} | {p*100:.0f}% (CI {lo*100:.0f}–{hi*100:.0f}%) | {flag} |")
else:
    print("_no critic findings recorded yet — the loop records them at the review→fix seam on live runs._")
print("\n## Retry / rework rate  (CI-fix attempts per task — a config causing MORE retries is a false economy)")
if retries:
    import statistics
    print(f"- tasks: {len(retries)} · mean fixes/task: **{statistics.mean(retries):.2f}** · max: {max(retries)} · zero-retry: {sum(1 for x in retries if x==0)}/{len(retries)}")
else:
    print("_no retry rows yet (loop logs `retry,<task>,<n>`); the run summary's ci_fixes counter is the live source._")
print("\n## Escaped-bug rate  (LAGGING — the honest measure of whether the verifier+critic panel earns its cost)")
esc="_run the nightly eval (tests/eval-run.sh → eval-report.sh) — it computes escaped-bug from the seeded-mutant tasks._"
try:
    for line in open(evalrep):
        if 'escaped-bug' in line.lower(): esc="- from the eval: "+line.strip().lstrip('- '); break
except: pass
print(esc)
print("\n_Leading (critic FP, retry, tokens/task via `ace stats`) move first and predict the lagging (pass^k, escaped-bug) the nightly eval measures._")
PY
  local rc=$?
  # rc 0 AND non-empty: python can exit 0 having printed nothing only if the script were gutted, but an empty
  # report is indistinguishable from a broken one to the reader — never publish it over a good previous one.
  if [ "$rc" = 0 ] && [ -s "$out.tmp" ]; then
    mv -f "$out.tmp" "$out"
    command -v say >/dev/null 2>&1 && say "quality report → .opencode/quality-report.md (per-critic FP rate + retry rate)"
    return 0
  fi
  rm -f "$out.tmp" 2>/dev/null
  printf 'quality_report: renderer failed (rc %s) — keeping the previous %s. Re-run with the 2>/dev/null removed to see the error.\n' "$rc" "$out" >&2
  return 0
}

# ace quality — on-demand quality report (per-critic FP rate, retry rate, escaped-bug)
ace_quality(){
  telemetry_on || { echo "telemetry is OFF (ACE_TELEMETRY=0) — nothing logged."; return 0; }
  quality_report
  [ -f .opencode/quality-report.md ] && cat .opencode/quality-report.md \
    || echo "no quality metrics yet — the loop records critic findings + resolutions (.opencode/quality-metrics.csv) as it runs."
}
