# The Go stack

`ace scaffold` → **Go** builds a Linux-first Go project that builds/tests in a container and ships
two ways: as a container **service** (VPS deploy + `/healthz`) and as **hardened standalone
binaries** you can run anywhere.

## What it scaffolds

- `cmd/<name>/main.go` — a `net/http` service: `GET /healthz` (200) + `GET /`, reads `PORT`
  (default 3000) so the existing VPS deploy + healthcheck works unchanged.
- `internal/server/` — handler + `httptest` test.
- Multi-stage `Containerfile`: `golang` build (`CGO_ENABLED=0 -trimpath -ldflags '-s -w'`) →
  `test` stage (`go vet && go test`) → final **`gcr.io/distroless/static:nonroot`** image (tiny,
  runs everywhere).
- Tiered `ci.sh`: fast host gate (`gofmt -l` · `go vet` · `staticcheck` · `go build` · `go test -race`
  + env-integrity + no-stubs) and `./ci.sh --container` (VPS parity via `podman --target test`).
- A project-scoped `opencode.json` adding the **gopls MCP** (below).
- `scripts/release.sh` — the hardened-binary path (below).
- The architecture **profile** — see [profile.md](profile.md).

## Shapes

The wizard's **shape** drives the skeleton, the deploy kind, and the CI:

| Shape | Skeleton | Deploy kind | CI jobs |
|-------|----------|-------------|---------|
| `api` | net/http service + `/healthz` | **service** (VPS) | build-test · security · codemap · deploy (HTTP health) · release |
| `cli` / `cli-web` | flag-based CLI + testable `run()` | **artifact** (binary) | build-test · security · codemap · release |
| `worker` | signal-graceful daemon (context + ticker) | **service** | build-test · security · codemap · deploy (liveness-only) · release |
| `library` | importable package (no `main`) | **none** | build-test · security · codemap |

`deploy_kind` is recorded in the profile and the autorun loop follows it: `service` deploys to the
VPS after a merge; `artifact` ships binaries on a `v*` tag (no per-merge deploy); `none` is a no-op.

To actually ship an `artifact` release, cut a tag — **`ace release --tag vX.Y.Z`** pushes a `v*` tag, which
is the trigger for the CI release job that builds + publishes the binaries. (`ace release` on its own only
builds into `dist/` locally.) The loop never auto-tags, so shipping a release is an explicit step.

## The official Go MCP (gopls)

The Go team ships an MCP server in **gopls v0.20+**. The scaffold writes a project `opencode.json`
that adds it, merged with the global gitnexus/serena/context7:

```json
{ "mcp": { "gopls": { "type": "local", "command": ["gopls", "mcp"], "enabled": true } } }
```

It exposes Go-native tools — `go_context`, `go_references`, `go_symbol_references`,
`go_diagnostics`, `go_package_api`, `go_rename_symbol`, **`go_vulncheck`** — so the agents navigate
and reason about Go with first-party tooling. `ace install` installs `gopls`.

> Note: this relies on opencode **deep-merging** the `mcp` block (its documented "merged, not
> replaced" behavior). If a Go project ever shows *only* gopls, opencode shallow-merged — inline the
> other servers into the project config.

## Hardened release binaries

`ace release` (alias for `scripts/release.sh`) cross-compiles fully-static binaries for the targets +
hardening recorded in the [profile](profile.md). It builds **inside a pinned `golang` container by
default** (reproducible, no host Go needed); `--host` builds on the host.

```bash
ace release                 # container build, profile-driven
ace release --host          # build on the host (needs Go + garble on PATH)
HARDENING=strong TARGETS="linux/amd64 linux/arm64" UPX=1 ace release   # env overrides
VERSION=v1.2.3 SIGN=minisign ace release                               # stamp + sign the checksums
```

Hardening ladder (set in the profile, or `HARDENING=…`):

| Level | What it does |
|-------|--------------|
| `none` | plain `go build` |
| `standard` | `-trimpath -ldflags '-s -w -buildid='` — strips symbols, DWARF, paths, build-id |
| `strong` | the above **plus [garble](https://github.com/burrowers/garble)** `-literals -tiny` — obfuscates identifiers + string literals |

Optional `UPX=1` packs the binary (smaller; mild extra obfuscation). Output lands in `dist/` with a
`SHA256SUMS`. Binaries are **version-stamped** (`-X main.version`, from `git describe`) and built
reproducibly (`SOURCE_DATE_EPOCH`); `strong` builds prefer the host when it already has `garble`
(otherwise the container caches the install), and `SIGN=minisign|cosign` signs the checksum manifest.

> **Honest caveat:** Go binaries carry rich runtime metadata and are inherently reversible. Stripping
> + garble raises the cost of reverse-engineering substantially, but nothing makes a Go binary
> RE-proof. Keep real secrets server-side, never in the binary.

### CI release job

The Go workflow gains a `release` job that triggers on **`v*` tags**: it installs garble, runs
`scripts/release.sh --host`, and publishes the binaries + `SHA256SUMS` to the GitHub Release.

```bash
git tag v0.1.0 && git push --tags     # → CI builds + attaches hardened binaries to the Release
```

## Toolchain (installed by `ace install`)

`go` (user-local tarball), `staticcheck`, `govulncheck`, `gopls`, `garble`, and a best-effort
user-local `upx`. All no-root, under `~/.local`.
