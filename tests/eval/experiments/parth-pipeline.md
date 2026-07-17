# Experiment C — Part H spec pipeline OFF vs ON (end-to-end value of H)  [PRE-REGISTRATION]

**Hypothesis:** the research-first spec pipeline (one canonical spec → deterministic spec-lint gate → per-
increment slice) raises first-pass quality and does NOT raise spend per feature — the specs make the
implementer's job unambiguous, so fewer review/fix rounds offset the planning cost.

**Config (knob-toggled — applied ONLY in the harness, NO branch switch):**
- **A (OFF):** `SPEC_LINT=0 SPEC_SLICE=0 SPEC_RUBRIC=0` — plan straight to ROADMAP, no gate, no slice.
- **B (ON):** `SPEC_LINT=1 SPEC_SLICE=1 SPEC_RUBRIC=0` — the shipped defaults (rubric stays OFF until it
  passes `tests/spec-rubric-goldens.sh --calibrate`).

**Primary metric:** task **pass^k** (eval-ab's McNemar). **Secondary (the real thesis):** **spend per feature**
(paired bootstrap CI on cost) — H's bet is *quality holds or rises while cost does not*.
**Guardrail:** B must not raise mean per-task cost beyond the report's noise floor (a pipeline that gates well
but bills more is only worth it if quality clearly rises with it).
**Minimum actionable effect (pre-register BEFORE running):** pass^k +__ pp AND/OR cost −__%. At n≈12 only a
LARGE effect is real — say **INDISTINGUISHABLE** when it is.

**Watch (don't fool yourself):**
1. On the tiny F1 corpus, most tasks are single-increment — the SLICE win (frozen per-increment context) only
   shows on multi-increment features; weight the corpus toward those or the effect washes out.
2. The gate adds an up-front planning turn; on trivial tasks that's pure cost with no quality headroom →
   expect (and accept) B costlier on trivial tasks, and look for the win on the logic-dense ones.
3. Cache: B's frozen slice makes retries cheap (H7) — a fair cost read needs tasks that actually retry.

**Decision rule:** keep B (the shipped default) iff pass^k holds-or-rises AND cost does not rise beyond the
band. If cost rises without a quality gain, narrow the gate (e.g. `SPEC_LINT` only on `[value]` HIGH-risk).
This experiment MEASURES; the knobs already default ON — a negative result is the evidence to narrow them.

**Verdict:** _(run `tests/eval-ab-parth.sh --k 5`; record adopt-as-is / narrow / indistinguishable + CIs to
`.opencode/experiments/parth-pipeline.md`)_
