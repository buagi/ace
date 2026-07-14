# Experiment A — ponytail (anti-over-engineering)  [PRE-REGISTRATION]

**Hypothesis:** the ponytail skill reduces over-engineering → higher minimal-diff pass on trap tasks.
**Primary metric:** trap-task **minimal-diff pass rate** (F1's trap tasks exist for exactly this).
**Guardrail:** normal-task **pass^k must not drop** (pre-registered band: within the report's noise floor).
**Cost:** tokens/task from telemetry (`ace stats`).
**Minimum actionable effect (pre-register):** +__ pp trap-task pass (fill before running; at n≈12 expect the
report's noise floor ≈ 50–60 pp — so only a LARGE effect is real).

**The specific trap to watch — reasoning-model inversion:** ponytail's own benchmark notes its token win
**can invert on a reasoning model that spends thinking tokens deliberating the rungs** — and ACE's workers
are DeepSeek in thinking mode at max effort, *exactly that profile*. The less-code win may hold while the
cost win reverses. **Measure both; do not assume the vendor number transfers.**

**Decision rule:** adopt iff trap-task pass improves AND normal pass^k holds AND cost does not rise. If
quality improves but cost rises, prefer lifting only the **ladder** into the implementer/reviewer prompts
(which we control) over adding an always-on third-party plugin to the loop.

**Verdict:** _(run `eval-ab.sh base.tsv ponytail.tsv`; record adopt / don't-adopt / indistinguishable + CIs)_
