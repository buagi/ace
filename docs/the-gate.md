# The gate — `ci.sh`

Every commit and push runs `ci.sh`, a tiered check that code must pass before it lands. A change that fails any check is rejected.

This page describes the gate in a **generated/adopted project** (the `ci.sh` + `.githooks/` + workflow that `ace scaffold` / `ace upgrade` write). The ACE repo itself is gated by its own `.github/workflows/ci.yml`, which is a different set of checks.

> [!NOTE]
> Two honest limits on "every commit and push":
> - The hooks only fire once `core.hooksPath` points at `.githooks/`. Scaffold auto-activates it, but `ace upgrade` **writes `.githooks/` and leaves your existing hooks active** if you already have `.git/hooks/pre-commit` or a custom `core.hooksPath` — it prints the command to enable ACE's gate rather than taking it over (`lib/scaffold.sh:3506-3527`).
> - `pre-push` runs the container gate under a **`PREPUSH_TIMEOUT` budget (default 100s)**. RED still blocks, but a gate that runs out of budget is **deferred to CI and the push is allowed** (`lib/scaffold.sh:226-234`). `PREPUSH_TIMEOUT=0` runs it to completion. So a push is not proof the parity gate passed locally.

## Tiers

| Command | Tier | What it runs | When it runs |
|---------|------|--------------|--------------|
| `./ci.sh` | **fast** | typecheck / compile, affected tests, lint, env check, no-stubs | pre-commit hook · the `verifier` agent |
| `./ci.sh --container` | **full** | pinned-container build + full test suite (VPS parity) | pre-push hook · CI |

The **fast** tier is for quick pre-commit feedback and can scope tests to the change (`CI_SCOPE=affected` — Node/turbo only; the Python and Go `ci.sh` always run the full suite). The **full** tier is the authority: it runs the complete suite in the same pinned image CI uses, so a local pass means a CI pass. Both tiers run *all* the sections below; `--container` changes how step 1 builds and tests, and adds the parity-only checks.

> [!NOTE]
> Under the `merge_gate: local` policy — **the default under `ace start`** (`lib/lifecycle.sh`), opt-in under `ace autorun` where the default is `remote` — a green `./ci.sh --container` is what authorizes a self-merge — the loop never waits on remote CI. See [autorun.md](autorun.md).

## What blocks a commit

| Check | Fails when | Applies to |
|-------|-----------|------------|
| **Depth gate** | a stub, `TODO`, or `NotImplemented` marker is present | `.ts` `.tsx` `.js` · `.py` · `.go` |
| **Env integrity** | a `process.env.X` / `os.getenv` / `os.Getenv` is missing from `.env.example` | all stacks |
| **Code map** | `docs/architecture.md` is stale (not regenerated + committed) | CI `codemap` job |
| **Security** | a secret or high-severity vulnerability is found | CI `security` job — secret scan + `pnpm audit` / `pip-audit` / `govulncheck` |
| **Node** | `any` or `@ts-ignore` present (ESLint errors — the gate is `tsc`, not the bundler) | Node |
| **Go** | `gofmt` or `go vet` fails; `staticcheck` fails **locally** | Go |

This table is the headline subset. `ci.sh` runs 12–13 numbered sections per stack — the rest are RLS-per-table, client-bundle secret scan, LLM call-site guards, webhook handler integrity, auth/session edge cases, migration expand-contract safety, observability, supply chain, and (parity/CI tier only) "new source needs tests". Read the generated `ci.sh` for the authoritative list; it is the file that decides.

> [!WARNING]
> Three of these are weaker than they read, by design or by omission — do not treat a green tick as full coverage:
> - **`staticcheck` is not a uniform gate.** Local `ci.sh` fails on it *only if it is on PATH*; if it is missing the section prints "skipping" and the run can still be green (`lib/scaffold.sh:1725-1729`). In the generated Go workflow it runs with `|| true` — purely informational (`lib/scaffold.sh:3584`).
> - **The CI secret scan is a two-pattern grep**, not a scanner: PEM `PRIVATE KEY` blocks and `ghp_`-prefixed GitHub tokens. Any other credential shape passes clean (`lib/scaffold.sh:3592-3594`, repeated per stack at `:3617` and `:3645`).
> - **The `codemap` job regenerates with `|| true`** (`lib/scaffold.sh:3661`). If `scripts/graph-refresh.sh` itself fails, nothing is rewritten, the diff is empty, and the job reports "code map current" — a failed refresh is indistinguishable from an up-to-date map.

## Disk hygiene

The `--container` step builds with `--force-rm` and prunes its dangling layers afterward (`podman image prune -f`), so the parity gate never accumulates disk. The loop's janitor sweeps the rest each lap.

## See also

- [autorun.md](autorun.md) — how a green gate authorizes a merge
- [configuration.md](configuration.md) — `CI_SCOPE`, `merge_gate`, and related knobs
- [swarm.md](swarm.md) — the gate under parallel workers
