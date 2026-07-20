# Testing & release readiness

ACE's test strategy is three tiers by **cost and cadence** — cheap deterministic gates on every PR, model-in-the-loop goldens nightly, and full crew A/Bs on demand. House style: **bash + jq/python-stdlib only** — no promptfoo/npm/pytest frameworks. Nothing that needs credits ever runs per-PR.

## Tier 1 — per-PR gates (free, deterministic, milliseconds)

Run on every PR by `.github/workflows/ci.yml` (jobs **lint** + **tests**). Run them all locally before pushing:

```bash
for f in ace lib/*.sh tests/*.sh scripts/*.sh; do bash -n "$f"; done   # syntax — hard gate
bash tests/bash-traps.sh            # static gate for the §A trap shapes + its own self-test
shellcheck -S error -e SC1090,SC1091 ace lib/*.sh tests/*.sh scripts/*.sh
bash tests/profile-reader.sh        # profile.yaml parse + required fields + delivery coherence
bash tests/snapshot-generators.sh   # generated .gitignore / CI config snapshots stay locked
bash tests/supply-chain.sh          # pinned installs + sha256-verified downloads + curl|sh allowlist
bash tests/prompt-contracts.sh      # 12 agents · valid opencode.json · every load-bearing prompt clause
bash tests/swarm-selftests.sh       # claim store · leasing · fencing · plan-lint · spec-lint/slice/rubric · RED-main
bash tests/approval-selftest.sh     # merge-approval: deny-by-default · undelivered request · token uniqueness
bash tests/cli-dispatch-selftest.sh # CLI dispatch ↔ help agreement
bash tests/autoloop-selftest.sh     # provider-cap detection · step budget · resume never commits to main
bash tests/killorder-selftest.sh    # B5 stop ORDER: loop leaders TERMed before their opencode trees
```

| Gate | Catches |
|------|---------|
| `bash -n` | any syntax break in `ace` / `lib/*.sh` / `tests/*.sh` / `scripts/*.sh` |
| `bash-traps.sh` | the mechanically-greppable [§A trap shapes](engineering-lessons.md#a-mechanical-traps) — **7 of them** (A1 · A2 · A4 · A5 · A6 · A8 · A11), see the coverage note below |
| `shellcheck -S error` | real shell bugs (warnings are informational) |
| `prompt-contracts.sh` | a prompt edit that breaks an agent's output contract, a lost placeholder, the agent count drifting off 12, an MCP key dropping, a missing Part-H/debate clause (spec-template · AC-ids · SSRF · researcher + debater denies · dash wiring) |
| `swarm-selftests.sh` | coordination regressions + the Part H spec functions (`spec-lint`, `spec-slice`, `spec-rubric` default-off) |
| `profile-reader` · `snapshot-generators` · `supply-chain` | profile/scaffold/supply-chain drift |
| `approval-selftest` · `cli-dispatch-selftest` · `autoloop-selftest` | merge-approval deny-by-default · a subcommand that dispatches but isn't in `--help` (or vice versa) · step-budget telemetry + resume-never-commits-to-main |
| `killorder-selftest` | a reordering of `_swarm_trap`'s two stop steps (`lib/swarm-run.sh:853`) — leaders must be TERMed **before** their opencode trees, or WIP is lost while the stop message still claims it was preserved |

### Why these gates exist — and what they can't catch

The 2026-07-18 audit (152 verified defects) found that **every defect was found by reproduction, never by reading**, and that three successive generations of *fixes* each re-introduced the class they were fixing. The durable write-up — the mechanical bash traps with their one-line fixes, the fix/review discipline, and the design defaults — is **[engineering-lessons.md](engineering-lessons.md)**. Read it before you write a fix, not after.

Two rules from it bind directly on this page:

- **A test that passes either way is worthless** (B1). Revert the fix in a temp copy and prove the test goes red. If you didn't, say so — "I did not verify" is acceptable, a false claim is not. `tests/autoloop-selftest.sh:69-85` is the model: it demonstrates the shell semantics (`read` returns 1 on an unterminated final line) *and then* asserts the writers and the reader.
- **A test that nothing runs is not a gate** (B2). Wire it into `.github/workflows/ci.yml` in the **same commit**. A suite once existed, passed locally against a dirty tree, and was in no workflow — main was red while CI was green.

> [!WARNING]
> **Not gates today.** `tests/hygiene-selftest.sh`, `tests/scorecard-selftest.sh` and `tests/reanalyze-selftest.sh` are present in `tests/` but appear in **no workflow**. Run them by hand until they're wired; don't read a green CI as covering them. Nightly `flake-check` does invoke all three, and since 2026-07-20 a stably-RED suite **fails** it (see [below](#flake-check--the-gate-that-watches-the-gates)) — so a permanently-broken suite is caught there even while it sits in no per-PR workflow.

### `bash-traps` — what the static gate does and does not cover

`tests/bash-traps.sh` **shipped** and is a hard step in `ci.yml`'s `lint` job (`.github/workflows/ci.yml:25-26`) — no `|| true`, no `continue-on-error`. It scans `ace` + `lib/*.sh` + `tests/*.sh` + `scripts/*.sh`, and refuses to report clean on fewer than 5 files in scope (`tests/bash-traps.sh:377-384`), so a scan from the wrong directory fails instead of passing trivially. Like `flake-check`, it self-tests every detector against known-bad *and* known-good fixtures on each run, so a pattern that silently stops matching turns CI red rather than reporting clean.

> [!IMPORTANT]
> **It covers 7 of the §A traps, not all 12** (`CHECKS=(A1 A2 A4 A5 A6 A8 A11)`, `tests/bash-traps.sh:197`). **A3** (`2>&1` folded into parsed data), **A7** (a file written without a trailing newline, then read with `read`), **A9** (EXIT-trap clobbering), **A10** (pidfile trust) and **A12** (state resolved inside a command substitution) are **not detected by anything** — they remain a reading checklist. Do not read a green `bash-traps` as "no §A traps in this diff".
>
> Two further narrowings, both deliberate and both costing false negatives: the **A4** detector matches only bounded-producer shapes (`cat` · `git diff/log/show/status` · `find` · `curl` · `wget`) piped into `grep -q` (`:146`) — a `printf "$var" | grep -q`, the shape that actually bit `prompt-contracts`, is **not** flagged (that class is caught empirically by `flake-check` instead). And **A8** coverage of `lib/*.sh` lives in `prompt-contracts.sh`, not here; `bash-traps.sh` asserts that other half still exists so coverage cannot be halved silently (`:287-295`).

The gate ships with a **BASELINE** of 10 pre-existing sites (`tests/bash-traps.sh:56-67`) — tab-delimited, because a `|` delimiter truncated the stored fragment mid-pipeline. These are **real defects awaiting a fix, not exemptions**, and every run says so. The register can only shrink: an entry whose check no longer fires is a hard failure that distinguishes *"the code was fixed — delete this entry"* from *"the detector regressed — fix the check"*. For a genuine exception, use a per-line `# bash-traps: allow <ID> — <reason>`; the reason is mandatory and an empty one fails the build (`:208-220`).

## Tier 2 — nightly goldens (model-in-the-loop, needs keys)

`.github/workflows/agent-goldens.yml` (06:00 UTC + manual). The `--check`/`--calibrate` steps run on committed seeds (free); live `--capture` is staged behind the provider-key block. **Reproduce-twice** before any failure is actionable (flake guard).

```bash
bash tests/agent-goldens.sh              # critic verdict schema + behavioural invariants + the researcher golden
bash tests/spec-rubric-goldens.sh --calibrate   # rubric JSON schema + label agreement → GO/HOLD for SPEC_RUBRIC=1
bash tests/spec-debate-goldens.sh --calibrate    # cross-model debate verdict agreement → GO/HOLD for *_DEBATE=1
bash tests/flake-check.sh --runs 10       # each suite N times (default 8); fails on any nondeterministic verdict
```

### `flake-check` — the gate that watches the gates

Tier 1 runs each suite **once**, so a suite that fails a few percent of the time merges green and then reds
somebody else's unrelated PR, where it reads as *"your change broke it"*. `flake-check` runs each suite N
times (default **8**) and fails any suite that doesn't decide the same way every time.

It distinguishes **flaky** (mixed exit codes) from **stable RED** (a real failure) in the *message*, because
conflating them sends people hunting a race that isn't there — but **both fail the gate**. That was not true
until 2026-07-20: a stably-RED suite printed `stable RED` and then `PASS`, exit 0, and the nightly job went
green with a suite failing every single run. The docs were corrected to admit that behaviour before the code
was fixed, which is the wrong order and is called out here so it isn't repeated.

It exists because it caught a real one: `prompt-contracts` shipped a `printf "$body" | grep -qF` under
`set -o pipefail`, which returns 141 when grep exits before printf finishes — **2 failures in 60 runs**,
invisible to single-run CI. Deliberately **empirical, not static**: the static rule for that shape measured
95 repo-wide hits (58 even when tightened), nearly all safe because the data sits far below the 64 KB pipe
buffer. An error-level gate at that false-positive rate gets switched off, and a switched-off gate protects
nothing.

`--runs` and `--suites` now require a value: `shift 2` with one argument left returns 1 *without shifting*,
so the arg loop spun forever with zero output and a scheduled run burned its entire ceiling in silence.

Run it by hand before merging anything that touches a test harness. Its own selftest asserts it fires on a
known-flaky fixture and does *not* misreport a stable-red one.

### `reanalyze-acceptance.sh` — judging a real run

`tests/reanalyze-acceptance.sh <repo> [run_id]` reads a finished run's durable artifacts and answers "did
this run go fine?" mechanically. It exists because three real runs were read as fine and were not: one spent
**50% of its wall-clock in a phase that appears in no metrics row**, and its report compared a 157-spec
population against a 10-spec gate.

Nine criteria: completion · no failmode · wall-clock attributed (≥85% in metric rows) · gate-scoped
population · debates converged-or-capped · research evidence (a cited source *or* an explicit
`UNVERIFIED`) · provenance written · no `*.progress.md` ledger polluting the gap count · transcripts from
earlier runs retained. It reads artifacts only, so it can be pointed at a run after the fact.


## Tier 3 — on-demand (full crew, credits, hours)

Never in CI. For evaluating a change's real quality/cost, or chaos-testing the swarm.

```bash
tests/eval-run.sh --stub                 # offline plumbing proof (applies reference.patch, no credits)
tests/eval-run.sh --k 5 --out A.tsv      # real crew over the sealed task corpus (needs opencode + keys)
tests/eval-ab.sh A.tsv B.tsv             # paired McNemar (quality) + bootstrap CI (cost) → adopt / don't / indistinguishable
tests/eval-ab-parth.sh --k 5             # H8: Part H pipeline OFF vs ON (knob-toggled, no branch switch)
tests/swarm-battle.sh                    # many-worker coordination under load
tests/swarm-fault.sh                     # fault injection (killed workers, RED main, abandon/reassign)
```

> [!IMPORTANT]
> **Stub rows are plumbing, not evidence — and the harness enforces that.** A `--stub` eval replaces the crew with a no-op that applies each task's `reference.patch`, so it scores **100% at ~zero cost by construction**. Every row it writes is tagged `mode=stub` (column 8, appended so existing 7-column readers keep working), and `eval-report.sh` / `eval-ab.sh` **refuse to hand you a verdict** on stub input unless you set `EVAL_ALLOW_STUB=1` to see the pipeline output anyway. When you do, the report is stamped as not-a-measurement.
>
> A **real** run refuses to start without `opencode` on `PATH` rather than degrading to the stub — a silent degrade produced a 100% pass rate that was indistinguishable, in the TSV, from a genuinely perfect crew. `--tasks` is resolved to an absolute path before any trial chdirs into its workdir (a relative path used to score every trial as a legitimate failure and exit `0`), and a trailing value-taking flag is rejected instead of looping forever.

Pre-registered experiments live in `tests/eval/experiments/` — fill the **minimum actionable effect BEFORE** running; report **quality AND cost**; say **"indistinguishable"** when the effect is within the noise floor.

## Pre-release readiness checklist

Automated verdict: **`ace status`** ends in a Readiness report (READY / NEEDS-SETUP with the fix / optional) — also printed at the end of `ace install`.

Before cutting a release or turning a fleet loose unattended:

- [ ] **Tier 1 green** — all per-PR gates pass locally + on the PR (lint + tests jobs).
- [ ] **`ace status` → READY** — tools · keys · `gh` · profile · (VPS if deploying) all satisfied.
- [ ] **Config regenerated** — `ace opencode` run since the last crew/model/MCP change (**12 agents** in `~/.config/opencode/opencode.json`).
- [ ] **Coder models intended** — implementer/test_engineer on `deepseek-v4-pro` (default) unless you've deliberately set `MODEL_<agent>` and measured it (Experiment C).
- [ ] **Firecrawl** — if research depends on it, `ace firecrawl status` shows it listening on loopback; else the gate falls back to webfetch (fine, just confirm the intent).
- [ ] **`SPEC_RUBRIC`** — stays `0` unless `spec-rubric-goldens.sh --calibrate` prints **GO** for your labeled set.
- [ ] **`SPEC_DEBATE` / `REVIEW_DEBATE`** — stay `0` unless `spec-debate-goldens.sh --calibrate` prints **GO**; enabling needs `OPENROUTER_API_KEY` + `DEBATE_MODEL_B`.
- [ ] **Merge/deploy policy** — `ace autorun --explain` shows the intended `merge_gate` · `auto_merge` · `deploy_kind` · caps.
- [ ] **Launch-readiness gate** — for a live-VPS promotion, the `launch_readiness_reviewer` has a GO (tested restore · rollback · secrets separation · spend caps).
- [ ] **Nightly goldens** — last run green (or seeds only, if capture isn't provisioned yet).
- [ ] **A dry sandbox pass** — `ace swarm sandbox` (zero-credit) or a single `MAX_FEATURES=1` autorun on a throwaway branch behaves as expected.

See also: [commands.md](commands.md) · [configuration.md](configuration.md) · [swarm.md](swarm.md) · `tests/eval/README.md`.
