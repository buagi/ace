# STANDARDS — Go

Enforceable best-practices for this stack. The standards_keeper reviews every change against this and
keeps it current; the gate (ci.sh) mechanizes what it can.

## Formatting & lint
- `gofmt` is mandatory (ci.sh fails on unformatted files). `go vet` and `staticcheck` must pass clean.
- Group imports (std / external / internal); no unused imports or variables.

## Errors
- Always check returned errors; never discard one with `_ =` without a why-comment.
- Wrap with context: `fmt.Errorf("doing X: %w", err)` — preserve the chain; inspect with `errors.Is/As`.
- Libraries return errors, never `panic` (panic only for unrecoverable programmer bugs).
- No naked returns in non-trivial functions.

## Context & concurrency
- Accept `context.Context` as the first arg on any blocking / I/O / request-scoped call; honor cancellation.
- Don't store a Context in a struct. Every goroutine has an owner and a way to stop — no leaks.
- Guard shared state (mutex/channel); `go test -race` must stay green (ci.sh runs it).

## HTTP / services (api shape)
- Set server timeouts (Read/Write/Idle) — never ship the zero-value `http.Server{}`.
- Validate and bound all input; return correct status codes; never leak internal errors to clients.
- Keep `/healthz` dependency-light (liveness); add `/readyz` if readiness gates on dependencies.

## Tests
- Pick the test TYPE per scenario (don't default to a couple of asserts):
  - branchy logic / boundaries → **table-driven** with `t.Run` subtests (happy + error + edge).
  - parser / serializer / encoder / math → **property + fuzz** (`testing/quick`, or `go test -fuzz`) — assert roundtrip & invariants.
  - generated output → **golden files** (an `-update` flag writing `testdata/*.golden`, compared on normal runs).
  - `http.Handler` → **`httptest`** + assert the status/header/body contract.
  - DB / external wiring → **integration** behind a `//go:build integration` tag against an ephemeral dependency; mocks hide real bugs.
  - money / orders / webhooks → **replay/idempotency** test + assert the audit record is written.
  - auth / ownership → **authz-DENY matrix** (role × resource); the deny cases are mandatory.
  - concurrency → `go test -race` + contention/interleave cases (ci.sh runs `-race`).
- Inject the clock/network — no real sleeps or sockets in unit tests. Reuse `internal/testutil` (FakeClock, factories, the `Golden` helper) and EXTEND it; never re-roll setup per test.
- Coverage is a signal, not a target: ci.sh writes `coverage.out` and prints the total — close gaps on the changed code, never write tests just to move the number. Mutation-test high-stakes packages (`scripts/mutation.sh`, gremlins) when unsure a suite is strong.
- Tests ship in the SAME PR as the code they cover — no test-only PRs.

## Dependencies & versions
- go.mod's `go` directive is the single source of the toolchain version (Containerfile + CI follow it).
- Keep deps current; the `govulncheck` CI job must be clean. Prefer the std lib over a thin dependency.

## Hardening (shipped binaries)
- Releases are fully-static (CGO_ENABLED=0), stripped; `strong` adds garble. Never embed secrets in a
  binary — they are recoverable. See ARCHITECTURE.md.
