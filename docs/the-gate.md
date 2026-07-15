# The gate — `ci.sh`

Every commit and push runs `ci.sh`, a tiered check that code must pass before it lands. A change that fails any check is rejected.

## Tiers

| Command | Tier | What it runs | When it runs |
|---------|------|--------------|--------------|
| `./ci.sh` | **fast** | typecheck / compile, affected tests, lint, env check, no-stubs | pre-commit hook · the `verifier` agent |
| `./ci.sh --container` | **full** | pinned-container build + full test suite (VPS parity) | pre-push hook · CI |

The **fast** tier is for quick pre-commit feedback and can scope tests to the change (`CI_SCOPE=affected`). The **full** tier is the authority: it runs the complete suite in the same pinned image CI uses, so a local pass means a CI pass.

> [!NOTE]
> Under the `merge_gate: local` policy, a green `./ci.sh --container` is what authorizes a self-merge — the loop never waits on remote CI. See [autorun.md](autorun.md).

## What blocks a commit

| Check | Fails when | Applies to |
|-------|-----------|------------|
| **Depth gate** | a stub, `TODO`, or `NotImplemented` marker is present | `.ts` `.tsx` `.js` · `.py` · `.go` |
| **Env integrity** | a `process.env.X` / `os.getenv` / `os.Getenv` is missing from `.env.example` | all stacks |
| **Code map** | `docs/architecture.md` is stale (not regenerated + committed) | CI `codemap` job |
| **Security** | a secret or high-severity vulnerability is found | CI `security` job — secret scan + `pnpm audit` / `pip-audit` / `govulncheck` |
| **Node** | `any` or `@ts-ignore` present (ESLint errors — the gate is `tsc`, not the bundler) | Node |
| **Go** | `gofmt`, `go vet`, or `staticcheck` fails | Go |

## Disk hygiene

The `--container` step builds with `--force-rm` and prunes its dangling layers afterward (`podman image prune -f`), so the parity gate never accumulates disk. The loop's janitor sweeps the rest each lap.

## See also

- [autorun.md](autorun.md) — how a green gate authorizes a merge
- [configuration.md](configuration.md) — `CI_SCOPE`, `merge_gate`, and related knobs
- [swarm.md](swarm.md) — the gate under parallel workers
