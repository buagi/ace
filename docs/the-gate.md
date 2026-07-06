# The gate — `ci.sh`

Every commit hits a **tiered gate**. Nothing unclean passes.

```
./ci.sh              FAST   typecheck/compile · affected tests · lint · env · no-stubs   (pre-commit · the verifier)
./ci.sh --container  FULL   pinned-container build + tests (VPS parity)                   (pre-push · CI)
```

## What blocks a commit

- **No stubs / TODO / NotImplemented** → the depth gate fails (per-language: `.ts/.tsx/.js`,
  `.py`, `.go`).
- **Undeclared env var** → fails (every `process.env.X` / `os.getenv` / `os.Getenv` must be in
  `.env.example`).
- **Stale code-map** → CI `codemap` job fails (`docs/architecture.md` must be regenerated + committed).
- **Secrets / high-sev vulns** → CI `security` job fails (secret scan + per-stack auditor:
  `pnpm audit` / `pip-audit` / `govulncheck`).
- **Stack-specific:** Node — no `any`, no `@ts-ignore` (ESLint errors; the gate is `tsc`, not the
  bundler). Go — `gofmt`, `go vet`, `staticcheck`.

## Self-cleaning

The `--container` step builds with `--force-rm` and prunes its dangling layers after
(`podman image prune -f`), so the parity gate never bloats your disk (the loop's janitor sweeps the
rest each lap).

## Tiering

The **fast** gate gives quick pre-commit feedback (and can scope tests to the change via
`CI_SCOPE=affected`). The **container** gate is the authority — it runs the full suite in the same
pinned image CI uses, so what passes locally passes in CI. For the `merge_gate: local` policy, a
green `./ci.sh --container` is what authorizes a merge (see [autorun.md](autorun.md)).
