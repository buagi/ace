# Testing & release readiness

ACE's test strategy is three tiers by **cost and cadence** — cheap deterministic gates on every PR, model-in-the-loop goldens nightly, and full crew A/Bs on demand. House style: **bash + jq/python-stdlib only** — no promptfoo/npm/pytest frameworks. Nothing that needs credits ever runs per-PR.

## Tier 1 — per-PR gates (free, deterministic, milliseconds)

Run on every PR by `.github/workflows/ci.yml` (jobs **lint** + **tests**). Run them all locally before pushing:

```bash
for f in ace lib/*.sh tests/*.sh; do bash -n "$f"; done   # syntax — hard gate
shellcheck -S error -e SC1090,SC1091 ace lib/*.sh tests/*.sh
bash tests/profile-reader.sh        # profile.yaml parse + required fields + delivery coherence
bash tests/snapshot-generators.sh   # generated .gitignore / CI config snapshots stay locked
bash tests/supply-chain.sh          # pinned installs + SHA-pinned actions + allowlist
bash tests/prompt-contracts.sh      # 12 agents · valid opencode.json · every load-bearing prompt clause
bash tests/swarm-selftests.sh       # claim store · leasing · fencing · plan-lint · spec-lint/slice/rubric · RED-main
```

| Gate | Catches |
|------|---------|
| `bash -n` | any syntax break in `ace` / `lib/*.sh` / `tests/*.sh` |
| `shellcheck -S error` | real shell bugs (warnings are informational) |
| `prompt-contracts.sh` | a prompt edit that breaks an agent's output contract, a lost placeholder, the agent count drifting off 12, an MCP key dropping, a missing Part-H/debate clause (spec-template · AC-ids · SSRF · researcher + debater denies · dash wiring) |
| `swarm-selftests.sh` | coordination regressions + the Part H spec functions (`spec-lint`, `spec-slice`, `spec-rubric` default-off) |
| `profile-reader` · `snapshot-generators` · `supply-chain` | profile/scaffold/supply-chain drift |

## Tier 2 — nightly goldens (model-in-the-loop, needs keys)

`.github/workflows/agent-goldens.yml` (06:00 UTC + manual). The `--check`/`--calibrate` steps run on committed seeds (free); live `--capture` is staged behind the provider-key block. **Reproduce-twice** before any failure is actionable (flake guard).

```bash
bash tests/agent-goldens.sh              # critic verdict schema + behavioural invariants + the researcher golden
bash tests/spec-rubric-goldens.sh --calibrate   # rubric JSON schema + label agreement → GO/HOLD for SPEC_RUBRIC=1
bash tests/spec-debate-goldens.sh --calibrate    # cross-model debate verdict agreement → GO/HOLD for *_DEBATE=1
```

| Golden | Asserts |
|--------|---------|
| `agent-goldens` (critics) | never green-lights a seeded bug · never cries wolf on a clean diff · ux_reviewer doesn't invent findings on a backend diff · abstains (UNVERIFIED) when evidence is missing |
| `agent-goldens` (researcher) | the returned spec parses under `swarm_spec_lint` and cites only files that exist (no fabricated citations) |
| `spec-rubric-goldens` | rubric JSON schema (7 criteria 1-3 · verdict) + ≥90% agreement with human labels over ≥4 goldens → the go/no-go for enabling `SPEC_RUBRIC=1` |
| `spec-debate-goldens` | the cross-model debate's final verdict (FLAGGED/SOUND) schema + ≥90% agreement with human labels over ≥4 goldens → the go/no-go for enabling `SPEC_DEBATE=1` / `REVIEW_DEBATE=1` |

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
