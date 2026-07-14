#!/usr/bin/env bash
# eval-ab.sh — PAIRED A/B comparison for the crew eval harness (Part F / F1, Edit 4).
#
# The instrument for the pending experiments (ponytail; thinking-mode). Same task set, both configs, then a
# verdict on QUALITY AND COST TOGETHER — never quality alone — that can, and usually should, say
# "indistinguishable at this n". Pure computation (python stdlib), deterministic, offline-testable.
#   - exact McNemar (binomial on the discordant pairs — correct at small n, few discordant pairs)
#   - paired bootstrap 95% CI on the per-task cost delta
#   - pre-register the primary metric + minimum actionable effect in the PR BODY before running (not enforced here)
#
#   eval-ab.sh <A-results.tsv> <B-results.tsv> [seed]
# Each results TSV is the eval-run.sh format (task, trial, pass, kind, cost, wall, mutant_survived).
set -uo pipefail
A="${1:-}"; B="${2:-}"; SEED="${3:-1}"
[ -f "$A" ] && [ -f "$B" ] || { echo "usage: eval-ab.sh <A-results.tsv> <B-results.tsv> [seed]"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "eval-ab: python3 required"; exit 1; }

python3 - "$A" "$B" "$SEED" <<'PY'
import sys, math, csv, random
from collections import defaultdict
fa, fb, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])

def load(path):
    passes = defaultdict(list); cost = defaultdict(list)
    with open(path) as f:
        for r in csv.reader(f, delimiter='\t'):
            if not r or r[0].strip() in ('task_id','') or r[0].startswith('#'): continue
            r = (r + ['-']*7)[:7]
            passes[r[0]].append(str(r[2]).strip() in ('1','pass','true','PASS'))
            try: cost[r[0]].append(float(r[4]))
            except: pass
    # per-task binary outcome = majority of k trials pass; per-task mean cost
    task_pass = {t: (sum(v) > len(v)/2) for t, v in passes.items()}
    task_cost = {t: (sum(cost[t])/len(cost[t]) if cost[t] else 0.0) for t in passes}
    return task_pass, task_cost

pa, ca = load(fa); pb, cb = load(fb)
tasks = sorted(set(pa) & set(pb))
if not tasks:
    print("eval-ab: no shared tasks between A and B"); sys.exit(2)

# --- McNemar exact on discordant pairs ---
b = sum(1 for t in tasks if pa[t] and not pb[t])   # A pass, B fail
c = sum(1 for t in tasks if not pa[t] and pb[t])   # A fail, B pass
both = sum(1 for t in tasks if pa[t] and pb[t]); neither = len(tasks) - both - b - c
n_disc = b + c
def binom_cdf(k, n, p=0.5):
    return sum(math.comb(n, i) * p**i * (1-p)**(n-i) for i in range(0, k+1))
if n_disc == 0:
    p_mc = 1.0
else:
    k = min(b, c); p_mc = min(1.0, 2 * binom_cdf(k, n_disc))   # two-sided exact

# --- paired bootstrap 95% CI on the mean per-task cost delta (B - A) ---
deltas = [cb.get(t,0) - ca.get(t,0) for t in tasks]
obs = sum(deltas)/len(deltas)
rng = random.Random(seed); boot = []
for _ in range(5000):
    s = [deltas[rng.randrange(len(deltas))] for _ in deltas]
    boot.append(sum(s)/len(s))
boot.sort(); clo, chi = boot[int(.025*len(boot))], boot[int(.975*len(boot))]

# --- noise floor ---
mde = min(1.0, (1.96+0.84)*math.sqrt(2*0.25/len(tasks)))

print(f"# Paired A/B — A=`{fa}`  B=`{fb}`\n")
print(f"_{len(tasks)} shared tasks · pass = majority of k trials_\n")
print("## Quality (exact McNemar on discordant pairs)")
print(f"- A>B on {b} task(s); B>A on {c} task(s); tie {both+neither} (both {both} / neither {neither}).")
print(f"- discordant pairs = {n_disc}. **exact McNemar p = {p_mc:.3f}**.")
qual = "A better" if (p_mc < 0.05 and b > c) else ("B better" if (p_mc < 0.05 and c > b) else "INDISTINGUISHABLE")
print(f"- quality verdict: **{qual}**" + ("" if qual!="INDISTINGUISHABLE" else f"  (can't resolve a difference at n={len(tasks)}; MDE ≈ {mde*100:.0f} pp)"))
print("\n## Cost (paired bootstrap, B − A)")
print(f"- mean per-task cost delta: **${obs:+.4f}**  (95% CI ${clo:+.4f} … ${chi:+.4f})")
cost_v = "indistinguishable (CI spans 0)" if (clo <= 0 <= chi) else ("B cheaper" if obs < 0 else "B costlier")
print(f"- cost verdict: **{cost_v}**")
print("\n## Combined verdict (quality AND cost)")
if qual == "INDISTINGUISHABLE" and (clo <= 0 <= chi):
    print(f"- **INDISTINGUISHABLE at this n** — neither quality nor cost separates A and B (MDE ≈ {mde*100:.0f} pp). Do not switch on this evidence; add trials/tasks or accept parity.")
else:
    print(f"- quality: {qual} · cost: {cost_v}. Weigh both before switching — a quality tie with a real cost win favors the cheaper config; a cost tie with a real quality win favors quality.")
PY
