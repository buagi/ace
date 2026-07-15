# The Go stack

`ace scaffold` → Go builds a Linux-first Go project that builds and tests in a container and ships two ways:

- as a container **service** — VPS deploy plus a `/healthz` check;
- as **hardened standalone binaries** you can run anywhere.

## What it scaffolds

| Path | What it is |
|------|-----------|
| `cmd/<name>/main.go` | a `net/http` service: `GET /healthz` (200) + `GET /`. Reads `PORT` (default 3000) so the existing VPS deploy + healthcheck work unchanged. |
| `internal/server/` | handler + `httptest` test |
| `Containerfile` | multi-stage: `golang` build (`CGO_ENABLED=0 -trimpath -ldflags '-s -w'`) → `test` stage (`go vet && go test`) → final `gcr.io/distroless/static:nonroot` (tiny, runs everywhere) |
| `ci.sh` | tiered: fast host gate (`gofmt -l` · `go vet` · `staticcheck` · `go build` · `go test -race` + env-integrity + no-stubs), and `./ci.sh --container` for VPS parity via `podman --target test` |
| `opencode.json` | project-scoped, adds the gopls MCP (below) |
| `scripts/release.sh` | the hardened-binary path (below) |
| `.opencode/profile.yaml` | the architecture profile — see [profile.md](profile.md) |

## Shapes

The wizard's **shape** drives the skeleton, the deploy kind, and the CI:

| Shape | Skeleton | Deploy kind | CI jobs |
|-------|----------|-------------|---------|
| `api` | net/http service + `/healthz` | `service` (VPS) | build-test · security · codemap · deploy (HTTP health) · release |
| `cli` / `cli-web` | flag-based CLI + testable `run()` | `artifact` (binary) | build-test · security · codemap · release |
| `worker` | signal-graceful daemon (context + ticker) | `service` | build-test · security · codemap · deploy (liveness-only) · release |
| `library` | importable package (no `main`) | `none` | build-test · security · codemap |

`deploy_kind` is recorded in the profile and the autorun loop follows it:

- `service` deploys to the VPS after a merge;
- `artifact` ships binaries on a `v*` tag (no per-merge deploy);
- `none` is a no-op.

To actually ship an `artifact` release, cut a tag with `ace release --tag vX.Y.Z`. That pushes a `v*` tag, which is the trigger for the CI release job that builds and publishes the binaries. (`ace release` on its own only builds into `dist/` locally.)

> [!NOTE]
> The loop never auto-tags, so shipping a release is always an explicit step.

## The gopls MCP

The Go team ships an MCP server in gopls v0.20+. The scaffold writes a project `opencode.json` that adds it, merged with the global gitnexus/serena/context7:

```json
{ "mcp": { "gopls": { "type": "local", "command": ["gopls", "mcp"], "enabled": true } } }
```

It exposes Go-native tools so the agents navigate and reason about Go with first-party tooling:

| Tool | Purpose |
|------|---------|
| `go_context` | package/symbol context for a query |
| `go_references` | find references to a symbol |
| `go_symbol_references` | references by symbol name |
| `go_diagnostics` | compiler / vet diagnostics |
| `go_package_api` | a package's public API |
| `go_rename_symbol` | call-graph-aware rename |
| `go_vulncheck` | vulnerability scan (govulncheck) |

`ace install` installs `gopls`.

> [!NOTE]
> This relies on opencode **deep-merging** the `mcp` block (its documented "merged, not replaced" behavior). If a Go project ever shows *only* gopls, opencode shallow-merged — inline the other servers into the project config.

## Hardened release binaries

`ace release` (an alias for `scripts/release.sh`) cross-compiles fully-static binaries for the targets and hardening recorded in the [profile](profile.md). It builds inside a pinned `golang` container by default (reproducible, no host Go needed); `--host` builds on the host.

```bash
ace release                 # container build, profile-driven
ace release --host          # build on the host (needs Go + garble on PATH)
HARDENING=strong TARGETS="linux/amd64 linux/arm64" UPX=1 ace release   # env overrides
VERSION=v1.2.3 SIGN=minisign ace release                               # stamp + sign the checksums
```

### Hardening ladder

Set in the profile, or override with `HARDENING=…`:

| Level | What it does |
|-------|--------------|
| `none` | plain `go build` |
| `standard` | `-trimpath -ldflags '-s -w -buildid='` — strips symbols, DWARF, paths, build-id |
| `strong` | the above plus [garble](https://github.com/burrowers/garble) `-literals -tiny` — obfuscates identifiers + string literals |

### Env overrides

| Env var | Values / example | Effect |
|---------|------------------|--------|
| `HARDENING` | `none` \| `standard` \| `strong` | hardening level (default: profile value, else `standard`) |
| `TARGETS` | `linux/amd64 linux/arm64` | build targets |
| `UPX` | `1` | pack the binary — smaller, mild extra obfuscation |
| `VERSION` | `v1.2.3` | version stamp (default: `git describe`) |
| `SIGN` | `minisign` \| `cosign` | sign the checksum manifest (minisign: `MINISIGN_SECRET_KEY` · cosign: `COSIGN_KEY`) |
| `GOIMAGE` | `golang:<v>` | pinned build image for the container path |

Output lands in `dist/` with a `SHA256SUMS`. Notes on the build:

- Binaries are version-stamped (`-X main.version`, from `git describe`) and built reproducibly (`SOURCE_DATE_EPOCH`).
- A `strong` build prefers the host when it already has `garble` (otherwise the container caches the install).
- `SIGN=minisign|cosign` signs the checksum manifest.

> [!WARNING]
> Go binaries carry rich runtime metadata and are inherently reversible. Stripping + garble raises the cost of reverse-engineering substantially, but nothing makes a Go binary RE-proof. Keep real secrets server-side, never in the binary.

### CI release job

The Go workflow gains a `release` job that triggers on `v*` tags. It installs garble, runs `scripts/release.sh --host`, and publishes the binaries + `SHA256SUMS` to the GitHub Release.

```bash
git tag v0.1.0 && git push --tags     # → CI builds + attaches hardened binaries to the Release
```

## Toolchain

Installed by `ace install`, all no-root under `~/.local`:

| Tool | Role |
|------|------|
| `go` | user-local tarball |
| `staticcheck` | linter (host gate) |
| `govulncheck` | vulnerability scanner |
| `gopls` | official Go MCP server + LSP |
| `garble` | obfuscator for `strong` hardened builds |
| `upx` | best-effort user-local release packer (optional) |

## See also

- [stacks.md](stacks.md) — the stack registry and how Go fits in
- [deploy.md](deploy.md) — how `deploy_kind` decides what ships
- [profile.md](profile.md) — the shape/hardening/targets profile
- [the-gate.md](the-gate.md) — the tiered `ci.sh`
