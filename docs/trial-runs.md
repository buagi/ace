# Metered trial — verifying the recent pipeline across 3 runs

A concrete, **measurable** protocol to shake out the last ~3 days of work — the Part H spec pipeline (lint · slice · rubric), the autorun↔swarm unification, the dashboards, the goldens, and the **cross-model debate** — on real trading-portal features, then fix + optimise from the data. Every item has a **metric**, a **pass line**, and **where to read it**. Nothing here needs new code; it's a runbook.

## 0. Setup (once)

```bash
# keys + the challenger model (see configuration.md → Cross-model debate)
ace settings            # Providers & keys → OpenRouter  (writes OPENROUTER_API_KEY)
printf 'DEBATE_MODEL_B=openrouter/<your-slug>\n' >> ~/.config/ace/config

# pick the 5 features to trial the debate on — their spec SLUGS (basename of .opencode/specs/<slug>.md).
# DEBATE_ONLY scopes SPEC debates ONLY. The REVIEW (pre-merge) gate has its own REVIEW_DEBATE_ONLY,
# matched against the BRANCH name with `/` folded to `-`. Leave it unset to review every branch.
printf 'DEBATE_ONLY=slug1,slug2,slug3,slug4,slug5\n' >> ~/.config/ace/config

ace opencode            # regenerate config → 12 agents incl. debater + the openrouter provider block
ace status              # must end in READY
tests/spec-debate-goldens.sh --calibrate   # optional: only enable auto-gates once this prints GO
```

**Where the data lives** (per run, in the repo): `.opencode/cache/*-debate-*.md` (transcripts) · `.opencode/cache/debate-metrics.jsonl` (metrics) · `.opencode/metrics.csv` + `~/.config/ace/logs/` (loop/step timing) · `ace stats` (tokens/cost) · `ace quality` (critic FP/retry). Archive each run's `.opencode/cache/` between runs so you can compare.

---

## Run 1 — baseline pipeline, debate OFF

Goal: the core Part H pipeline + the unified flow + the dashboards behave, with **no** debate cost, so Run 2's delta is attributable to the debate.

```bash
SPEC_DEBATE=0 REVIEW_DEBATE=0 MAX_FEATURES=3 ace autorun --yes
```

| # | Check | Metric | Pass line | Read it |
|---|-------|--------|-----------|---------|
| 1 | Spec gate runs on `[value]` features | # specs written to `.opencode/specs/` | ≥1 per value feature | `ls .opencode/specs/` |
| 2 | Deterministic lint gates before dispatch | `SPECGAP` count trends ↓ across re-spec | 0 gaps at dispatch after the 2 re-spec rounds (the count is fixed by the pipeline, not a knob) | coordinator/loop log `planning: spec-lint …` |
| 3 | Per-increment **slice** reaches the implementer | slice files present | 1 per dispatched increment | `ls .opencode/cache/spec-slice.*.md` |
| 4 | **Solo == swarm** pipeline (unification) | same gate lines appear in a `par=1` run | present | run once with 1 flow, once with ≥2 |
| 5 | Dashboard **phase tags** live, never static | phase label changes across research→spec-gate→implement | tags observed, spinner animates | `ace dash` during the run |
| 6 | No stalls / hangs | longest silent gap | < `HANG_AFTER` (8m) without a kill | `ace loop stats` · dashboard beat |
| 7 | Merge gate holds | merges only on green | 0 red-main merges | PR history |
| 8 | Baseline cost/quality | $ + tokens per feature; retry rate | record as the baseline | `ace stats 1` · `ace quality` |

**Stop-ship if:** any feature dispatched with unresolved `[blocker]` spec gaps, a merge on red, or a silent hang that isn't caught.

---

## Run 2 — the debate trial (5 features), debate ON

Goal: measure the cross-model debate on exactly the 5 `DEBATE_ONLY` features — quality of the argument, convergence, cost — vs Run 1.

```bash
SPEC_DEBATE=1 REVIEW_DEBATE=0 MAX_FEATURES=5 ace autorun --yes
# … then:
ace debate report
```

| # | Check | Metric | Pass line | Read it |
|---|-------|--------|-----------|---------|
| 1 | Debate fires ONLY on the 5 slugs | # debates | = 5 (no others) | `ace debate report` (SLUG column) |
| 2 | Debates **converge** (not just hit the cap) | convergence rate | ≥ 60% converged (not wall-capped) | report: `converged` / `wall_capped` |
| 3 | Rounds are sane | avg rounds | 2–4 (only complex ones near 10) | report: `avg_rounds` |
| 4 | Arguments are **grounded** (anti-hallucination) | cited-vs-uncited points in transcript | every accepted issue cites spec/repo | read `.opencode/cache/spec-debate-<slug>.md` |
| 5 | Defender actually concedes AND defends | accepted vs disputed | both > 0 across the set (not all-concede / all-defend) | report: `total_accepted` / `total_disputed` |
| 6 | Agreed gaps drive a **re-spec** | `SPECGAP … DEBATE:` → fixed before dispatch | debate gaps resolved | loop log `re-spec flagged feature specs` |
| 7 | Cost is worth it | $ + tokens per feature vs Run 1 | Δcost justified by fewer review/fix rounds | `ace stats 1` vs Run 1 · `ace quality` retry rate |
| 8 | Wall discipline | any `wall_capped` | rare; if frequent, tune `DEBATE_MAX`/models | report: `wall_capped` |
| 9 | No sycophancy / no manufactured disagreement | spot-read 2 transcripts | real trade-offs, not rubber-stamping | the `.md` transcripts |

**Read every bit:** for each of the 5, open the transcript and confirm the challenger raised *real* issues, the defender's concessions/defences are *grounded*, and the synthesized `DEBATEISSUE` lines match what both actually agreed.

---

## Run 3 — swarm + REVIEW_DEBATE + edges

Goal: the parallel path + the pre-merge code debate + the failure modes.

```bash
SPEC_DEBATE=1 REVIEW_DEBATE=1 SWARM_MAX=3 ace autorun --yes    # (or: ace swarm start)
```

| # | Check | Metric | Pass line | Read it |
|---|-------|--------|-----------|---------|
| 1 | Swarm pre-dispatch panel names the phase | research/spec-gate/plan-gate labels | shown, beating | `ace swarm dash` / `ace dash` |
| 2 | REVIEW_DEBATE runs pre-merge, doesn't stall siblings | merge-lock hold time | debate runs BEFORE the lock; no sibling starvation | coordinator log + merge timing |
| 3 | Agreed blocker/major **holds** the merge | held PRs | held + surfaced on the bus for a fix | `review-debate: … held` in the log |
| 4 | Fail-open holds | kill a debate mid-run (drop the key) | the run PROCEEDS, no gaps, no crash | unset `DEBATE_MODEL_B` mid-run |
| 5 | Path-disjoint, no cross-worker collisions | merge conflicts | ~0 (plan-lint + hot-file chaining working) | swarm bus `needs-attention` |
| 6 | Goldens still green | nightly-style check | PASS | `bash tests/spec-debate-goldens.sh --calibrate` |
| 7 | Aggregate debate signal | full `ace debate report` | convergence ≥60%, sane rounds/cost across all runs | `ace debate report` (accumulates across runs) |

---

## Analyse → fix → optimise

**Start with `ace scorecard`** — one read-only rollup of the run across all 8 levels (research · feature-breakdown · subtask hit-rate/manageability · result quality · debate barter · logging completeness · anomalies · edge cases) + a top-line VERDICT (`--json` for machine use). It's the fastest way to see the whole picture; then drill into the specifics below.

After the 3 runs, with `ace scorecard` + `.opencode/cache/debate-metrics.jsonl` + the transcripts + `ace stats`/`ace quality`:

1. **`ace debate report`** — convergence rate, avg rounds, accepted/disputed, duration, wall-capped. Low convergence or frequent wall-caps ⇒ the challenger model or the round caps need tuning.
2. **Quality** — did the debate catch issues the deterministic lint + rubric missed? Cross-reference `DEBATEISSUE` lines against escaped bugs (`ace quality`). If it only restates lint findings, it isn't earning its cost.
3. **Cost** — Δ($/feature) Run 2 vs Run 1 against the drop in review/fix rounds. Tune: lower `DEBATE_MAX`, a cheaper `DEBATE_MODEL_B`, or narrow `DEBATE_ONLY`.
4. **Optimise knobs** — `DEBATE_MIN/MAX/HARD_MAX`, `DEBATE_TIMEOUT`, `DEBATE_WALL_MAX` from the observed round/timing distribution. Keep `SPEC_DEBATE`/`REVIEW_DEBATE` **off** by default until `--calibrate` says GO on a labelled set.
5. **File findings** — anything that misbehaved (a hallucinated-but-accepted issue, a stall, a mis-scoped debate) → a ROADMAP item; fix, then re-run the affected step.

> Keep each run's `.opencode/cache/` archived so Run 1↔2↔3 are comparable, and so the debate metrics aggregate cleanly in `ace debate report`.

---

## Measuring & improving the debate over time

The runs above measure *activity* (`ace debate report`). To know whether the debate is actually **effective** — and getting **better** as you tune it — score it against **ground truth**: the labeled sandbox at `tests/debate-sandbox/` (authored HIGH-risk specs, some seeded-flawed, some clean; answers in `labels.tsv`).

```bash
ace debate score --capture   # run the live debate over the labeled specs (needs OPENROUTER_API_KEY + DEBATE_MODEL_B)
ace debate score             # precision · recall · F1 · accuracy + append a trend point (offline on recorded outputs)
ace debate trend             # F1 over time + a conclusion: IMPROVING / REGRESSING / FLAT
```

**The improvement loop — manual first, then automatic:**

1. **Manual (periodically):** `ace debate diagnose` shows the **false positives** (over-flagged a clean spec = hallucination) and **false negatives** (missed a seeded flaw), with the transcripts + a tuning hint. Edit the debater prompt (`lib/install.sh`) or a knob → `ace debate score` → `ace debate trend`. Repeat until F1 plateaus.
2. **Automatic (opt-in, once trusted):** `ace debate autotune DEBATE_MAX=3` (or `DEBATE_MODEL_B=…`) A/B's the candidate knob on the sandbox and **keeps it only if F1 improves without cost rising** (the decision is the paired `eval-ab` on the labeled set). Debater **prompt** changes are never auto-applied — `ace debate autotune --propose-prompt` emits a suggested diff + a ROADMAP item for a normal human PR (prompts are load-bearing, gated by `prompt-contracts`).

**Draw the conclusion:** the debate is worth keeping/enabling when `ace debate score` is **GO** (F1 ≥ `DEBATE_F1_MIN`) *and* `ace debate trend` shows F1 flat-or-rising at acceptable cost. Grow the sandbox (`ace debate testproject` to watch live; add labeled `specs/*.md` + `labels.tsv` rows) so the metric stays honest as the debate improves.
