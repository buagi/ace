#!/usr/bin/env bash
# eval-report.sh — HONEST reporting for the crew eval harness (Part F / F1, Edit 3).
#
# Reads a per-trial results TSV and prints the metrics that matter, each with its uncertainty AND the
# harness's own NOISE FLOOR — because at n≈12 tasks only large effects are real, and nobody should act on
# a 3-point wiggle. Pure computation (python stdlib) → fully deterministic + offline-testable.
#
# Results TSV (one row per TRIAL; header optional), tab-separated:
#   task_id trial pass(1/0) kind(replay|regress|mutant|trap) cost_usd wall_s mutant_survived(1/0/-) mode(stub|real)
# `mutant_survived` is 1 when a seeded bug reached commit (escaped), 0 when the gate caught it, - otherwise.
# `mode` is stub for a --stub eval, whose crew is a no-op that applies reference.patch → 100% pass by
# construction. Reporting that as a pass rate is a lie, so stub input is refused unless EVAL_ALLOW_STUB=1.
#
#   eval-report.sh <results.tsv>   → prints the report + writes .opencode/eval-report.md
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
RES="${1:-}"
[ -n "$RES" ] && [ -f "$RES" ] || { echo "usage: eval-report.sh <results.tsv>"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "eval-report: python3 required"; exit 1; }

OUT="$ROOT/.opencode/eval-report.md"; mkdir -p "$ROOT/.opencode" 2>/dev/null
# Captured, not `| tee`: on a REFUSAL the report must not be written at all — teeing would overwrite the last
# good eval-report.md with the refusal text, and `tee`'s own exit 0 would mask the refusal status.
REPORT="$(python3 - "$RES" "$OUT" <<'PY'
import sys, os, math, csv
from collections import defaultdict
res, out = sys.argv[1], sys.argv[2]

def wilson(k, n, z=1.96):
    if n == 0: return (0.0, 0.0, 0.0)
    p = k / n
    d = 1 + z*z/n
    c = (p + z*z/(2*n)) / d
    h = (z * math.sqrt(p*(1-p)/n + z*z/(4*n*n))) / d
    return (p, max(0.0, c-h), min(1.0, c+h))

rows = []
with open(res) as f:
    for r in csv.reader(f, delimiter='\t'):
        if not r or r[0].strip() in ('task_id', '') or r[0].startswith('#'): continue
        # task, trial, pass, kind, cost, wall, mutant_survived, mode
        r = (r + ['-']*8)[:8]
        rows.append(r)

# A stub run records the reference.patch being applied by a no-op crew: 100% pass, ~0 cost, by construction.
# Rendering that as pass@1 / pass^k would publish a number about NOTHING, so refuse unless asked explicitly.
modes = {str(r[7]).strip() or '-' for r in rows}
stub = 'stub' in modes
if stub and os.environ.get('EVAL_ALLOW_STUB') != '1':
    print(f"eval-report: REFUSING — `{res}` contains mode=stub rows (no-op crew applying reference.patch). "
          f"Those are a plumbing check, not a measurement. Re-run without --stub, or set EVAL_ALLOW_STUB=1.")
    sys.exit(3)

by_task = defaultdict(list)   # task -> list of pass(bool)
kind = {}; cost = defaultdict(list); wall = defaultdict(list); surv = {}
for task, trial, p, k, c, w, ms, _mode in rows:
    ok = str(p).strip() in ('1', 'pass', 'true', 'PASS')
    by_task[task].append(ok); kind[task] = k
    try: cost[task].append(float(c))
    except: pass
    try: wall[task].append(float(w))
    except: pass
    if str(ms).strip() in ('1', '0'): surv[(task, trial)] = (ms.strip() == '1')

tasks = sorted(by_task)
ntrials = sum(len(v) for v in by_task.values())
npass = sum(sum(v) for v in by_task.values())
# pass@1 = mean over ALL trials; pass^k reliability = fraction of TASKS where ALL k trials passed
p1, lo1, hi1 = wilson(npass, ntrials)
allk = sum(1 for t in tasks if all(by_task[t])); pk, lok, hik = wilson(allk, len(tasks))
# escaped-bug rate = mutant trials that SURVIVED to commit / mutant trials scored
mut = [v for (t, _), v in surv.items()]
esc_k = sum(1 for v in mut if v); esc_n = len(mut)
ep, elo, ehi = wilson(esc_k, esc_n) if esc_n else (0, 0, 0)
tot_cost = sum(sum(c) for c in cost.values())
# Minimum Detectable Effect at this n (two-proportion, 80% power, alpha .05) — the NOISE FLOOR.
def mde(n):
    if n < 2: return 1.0
    return min(1.0, (1.96 + 0.84) * math.sqrt(2 * 0.25 / n))   # worst-case p=.5

L = []
L.append(f"# Crew eval report\n")
L.append(f"_{len(tasks)} tasks · {ntrials} trials · results: `{res}`_\n")
if stub:
    L.append("> ⚠ **STUB DATA — NOT A MEASUREMENT.** The crew was a no-op that applied each task's "
             "reference.patch, so every number below is an artefact of the fixture, not of ACE.\n")
L.append("## Headline")
L.append(f"- **pass@1** (any single run): **{p1*100:.0f}%**  (Wilson 95% CI {lo1*100:.0f}–{hi1*100:.0f}%, n={ntrials} trials)")
L.append(f"- **pass^k reliability** (ALL k trials pass — the honest metric, ACE ships ONE PR): **{pk*100:.0f}%**  (CI {lok*100:.0f}–{hik*100:.0f}%, n={len(tasks)} tasks)")
if esc_n:
    L.append(f"- **escaped-bug rate** (seeded bug reached commit): **{ep*100:.0f}%**  (CI {elo*100:.0f}–{ehi*100:.0f}%, {esc_k}/{esc_n} mutant trials)")
L.append(f"- **cost**: ${tot_cost:.2f} total · ${tot_cost/max(1,len(tasks)):.3f}/task")
L.append("")
L.append("## ⚠ Noise floor (read before acting on any number)")
L.append(f"- At n={ntrials} trials, the smallest pass-rate difference this harness can distinguish is ~**{mde(ntrials)*100:.0f} pp** (80% power, α=.05, worst case).")
L.append(f"- The pass@1 CI is ±{(hi1-lo1)/2*100:.0f} pp. **Do not act on a delta smaller than the noise floor** — run more trials or accept 'indistinguishable'.")
L.append("")
L.append("## Per task")
L.append("| task | kind | pass@1 | all-k? | ~cost | ~wall |")
L.append("|---|---|--:|:--:|--:|--:|")
for t in tasks:
    v = by_task[t]; pr = sum(v)/len(v)
    ak = "✓" if all(v) else "✗"
    c = sum(cost[t])/len(cost[t]) if cost[t] else 0
    w = sum(wall[t])/len(wall[t]) if wall[t] else 0
    L.append(f"| {t} | {kind[t]} | {pr*100:.0f}% ({sum(v)}/{len(v)}) | {ak} | ${c:.3f} | {w:.0f}s |")
print("\n".join(L))
PY
)"; rc=$?
printf '%s\n' "$REPORT"
[ "$rc" -eq 0 ] || exit "$rc"
printf '%s\n' "$REPORT" > "$OUT"
echo
echo "eval-report: written → .opencode/eval-report.md"
