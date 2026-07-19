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
# Each results TSV is the eval-run.sh format (task, trial, pass, kind, cost, wall, mutant_survived[, mode]).
# Column 5 is whatever the PRODUCER measured — $ for eval-run.sh (header `cost_usd`), seconds for
# debate-effectiveness.sh (header `cost` = duration_s) — so the unit is read from the header, never assumed.
# Rows written by a --stub eval carry mode=stub; they are plumbing, not evidence, so a verdict is refused
# unless EVAL_ALLOW_STUB=1 says the caller only wants to prove the pipeline runs.
set -uo pipefail
A="${1:-}"; B="${2:-}"; SEED="${3:-1}"
[ -f "$A" ] && [ -f "$B" ] || { echo "usage: eval-ab.sh <A-results.tsv> <B-results.tsv> [seed]"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "eval-ab: python3 required"; exit 1; }

python3 - "$A" "$B" "$SEED" <<'PY'
import sys, os, math, csv, random
from collections import defaultdict
fa, fb, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])

# A single task (the default `tests/eval/tasks/` set holds exactly one) cannot support ANY inferential
# verdict: the paired bootstrap resamples one delta, so every replicate is that delta, the CI collapses to a
# point that excludes 0, and cost confidently "names a winner" on n=1. The quality path already guards this;
# the cost path must use the SAME floor or it overrides a correct INDISTINGUISHABLE.
MIN_N = int(os.environ.get('EVAL_AB_MIN_N', '5'))

def load(path):
    passes = defaultdict(list); cost = defaultdict(list); modes = set(); unit = None
    with open(path) as f:
        for r in csv.reader(f, delimiter='\t'):
            if not r or not r[0].strip() or r[0].startswith('#'): continue
            if r[0].strip() == 'task_id':                 # header: col 5 names the unit of the cost column
                unit = (r[4].strip() if len(r) > 4 else '') or None
                continue
            r = (r + ['-']*8)[:8]
            passes[r[0]].append(str(r[2]).strip() in ('1','pass','true','PASS'))
            modes.add(str(r[7]).strip() or '-')
            try: cost[r[0]].append(float(r[4]))
            except: pass
    # per-task binary outcome = majority of k trials pass; per-task mean cost
    task_pass = {t: (sum(v) > len(v)/2) for t, v in passes.items()}
    task_cost = {t: (sum(cost[t])/len(cost[t]) if cost[t] else 0.0) for t in passes}
    return task_pass, task_cost, modes, unit

pa, ca, ma, ua = load(fa); pb, cb, mb, ub = load(fb)

# Stub rows are the reference.patch applied by a no-op crew — 100% pass by construction. Comparing them
# measures nothing about A vs B, so refuse a verdict unless the caller explicitly wants the plumbing check.
stub_arms = [n for n, m in (('A', ma), ('B', mb)) if 'stub' in m]
if stub_arms and os.environ.get('EVAL_ALLOW_STUB') != '1':
    print(f"eval-ab: REFUSING — arm(s) {', '.join(stub_arms)} contain mode=stub rows (a no-op crew applying "
          f"reference.patch). That is plumbing, not evidence. Re-run without --stub, or set "
          f"EVAL_ALLOW_STUB=1 to see the pipeline output anyway.")
    sys.exit(3)

# col 5 carries $ only when the producer said so; debate-effectiveness.sh feeds it duration_s.
unit = ua if ua == ub else None
CUR, SUF = ('$', '') if unit == 'cost_usd' else (('', ' s') if unit == 'cost' else ('', ' (col-5 units)'))
def money(x, sign=False): return f"{CUR}{x:+.4f}{SUF}" if sign else f"{CUR}{x:.4f}{SUF}"

tasks = sorted(set(pa) & set(pb))
if not tasks:
    print("eval-ab: no shared tasks between A and B"); sys.exit(2)
# Tasks present in only ONE arm are NOT paired and are excluded from every statistic below. Silently dropping
# them hides a truncated/aborted arm behind a narrower but equally confident report — so name them.
only_a = sorted(set(pa) - set(pb)); only_b = sorted(set(pb) - set(pa))

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
if stub_arms:
    print(f"> ⚠ **STUB DATA ({', '.join(stub_arms)}) — NOT A MEASUREMENT.** A no-op crew applied each task's "
          f"reference.patch; the verdicts below only prove the pipeline runs.\n")
if only_a or only_b:
    print("> ⚠ **Unpaired tasks excluded from every statistic below** (they cannot form a pair, so the "
          "comparison is over fewer tasks than either arm ran — usually a truncated or aborted arm):")
    if only_a: print(f">   - in A only ({len(only_a)}): {', '.join(only_a)}")
    if only_b: print(f">   - in B only ({len(only_b)}): {', '.join(only_b)}")
    print()
print("## Quality (exact McNemar on discordant pairs)")
print(f"- A>B on {b} task(s); B>A on {c} task(s); tie {both+neither} (both {both} / neither {neither}).")
print(f"- discordant pairs = {n_disc}. **exact McNemar p = {p_mc:.3f}**.")
qual = "A better" if (p_mc < 0.05 and b > c) else ("B better" if (p_mc < 0.05 and c > b) else "INDISTINGUISHABLE")
print(f"- quality verdict: **{qual}**" + ("" if qual!="INDISTINGUISHABLE" else f"  (can't resolve a difference at n={len(tasks)}; MDE ≈ {mde*100:.0f} pp)"))
print("\n## Cost (paired bootstrap, B − A)")
print(f"- mean per-task cost delta: **{money(obs, True)}**  (95% CI {money(clo, True)} … {money(chi, True)})")
# min-n guard, mirroring quality: below MIN_N the bootstrap has too few distinct deltas to resample and its
# CI is an artefact of the sample size, not evidence of a cost difference.
cost_flat = (clo <= 0 <= chi) or len(tasks) < MIN_N
if len(tasks) < MIN_N:
    cost_v = f"INDISTINGUISHABLE (n={len(tasks)} < {MIN_N} paired tasks — the bootstrap CI is not meaningful here)"
else:
    cost_v = "indistinguishable (CI spans 0)" if (clo <= 0 <= chi) else ("B cheaper" if obs < 0 else "B costlier")
print(f"- cost verdict: **{cost_v}**")
print("\n## Combined verdict (quality AND cost)")
if qual == "INDISTINGUISHABLE" and cost_flat:
    print(f"- **INDISTINGUISHABLE at this n** — neither quality nor cost separates A and B (MDE ≈ {mde*100:.0f} pp). Do not switch on this evidence; add trials/tasks or accept parity.")
else:
    print(f"- quality: {qual} · cost: {cost_v}. Weigh both before switching — a quality tie with a real cost win favors the cheaper config; a cost tie with a real quality win favors quality.")
PY
