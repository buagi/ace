# Stacks

`ace scaffold` generates a project for one **stack**. Stacks are defined in a single registry in
[`lib/scaffold.sh`](../lib/scaffold.sh) — the menu, dispatch, and shared CI jobs are all driven from it.

## Built-in stacks

| Stack | Generator | Gate (`ci.sh`) | Deploy kind |
|-------|-----------|----------------|-------------|
| **Node / TypeScript** | `gen_node` | pnpm + turbo, vitest, tsc/eslint; `--container` parity | service (podman → VPS) |
| **Python** | `gen_python` | pytest, py_compile; `--container` parity | service |
| **Config only** | `gen_configonly` | template `ci.sh` (fill in your own) | none |
| **Go** | `gen_go` (+ profile wizard) | gofmt/vet/staticcheck/test; `--container` parity | service + artifact (hardened binaries) |

Every stack gets the same shared machinery: git hooks, the `.opencode/` context, the autorun loop,
a tiered `ci.sh`, and — when CI/CD is on — a GitHub Actions workflow whose **codemap** job is identical
across stacks (emitted once, not copy-pasted). The **deploy** job is emitted only for a **service**
(`deploy_kind=service` — node/python default); config-only, `container:false`, and `deploy=none` projects
get no deploy job.

The Go stack is the most built-out — see [go-stack.md](go-stack.md).

## The stack registry

Near the top of `scaffold_project` in `lib/scaffold.sh`:

```bash
STACK_ORDER="node python config go"                       # menu order
declare -A STACK_LABEL=(  [node]="Node / TypeScript" … )  # menu label
declare -A STACK_HINT=(   [node]="pnpm + turbo …" … )     # menu hint
declare -A STACK_GEN=(    [node]="gen_node" … )           # generator function
declare -A STACK_DEPLOY=( [node]="service"  … )           # service | artifact | none
```

Everything keys on the **name** (`node`/`python`/`go`/…), never a menu number — so inserting a stack
never renumbers anything.

## How to add a new stack

Adding a stack (say, **Rust**) touches four places — all small:

1. **Register it** in the table above:
   ```bash
   STACK_ORDER="node python config go rust"
   STACK_LABEL[rust]="Rust";  STACK_HINT[rust]="cargo, clippy, tiered ci"
   STACK_GEN[rust]="gen_rust";  STACK_DEPLOY[rust]="service"
   ```

2. **Write `gen_rust "$name"`** — mirror `gen_node`/`gen_go`: emit the skeleton, `.gitignore`,
   `.env.example`, a multi-stage `Containerfile` (with a `test` target), a tiered `ci.sh`
   (fast host gate + `--container` parity, including the no-stubs depth gate for `.rs`), and call
   `gen_project_agents "$name" "<one-line stack description>"`.

3. **Add a CI case** in `gen_ci_workflow` — one `case` arm emitting the per-stack **build-test** +
   **security** jobs (e.g. `cargo build/test/clippy` + `cargo audit`). The shared `codemap`,
   `deploy`, and (Go-only) `release` jobs come from `_ci_codemap_job` / `_ci_deploy_job` /
   `_ci_release_job` — you don't touch them. If the app serves HTTP, set its health path
   (`hpath`) so the deploy healthcheck probes the right endpoint.

4. **Only if it deploys unusually** — add a branch in `gen_deploy_artifacts` (the `service` default
   builds a container image and runs it; an `artifact` stack would instead produce a release).

That's it. The menu entry, dispatch, and the shared CI jobs all follow from the registry.

### Deploy kinds

- **`service`** — a long-running container, deployed to the VPS and verified with an HTTP healthcheck
  (the default; Node/Python/Go-api).
- **`artifact`** — produces shippable binaries/packages rather than a running service (Go's hardened
  release path; see [go-stack.md](go-stack.md)).
- **`none`** — no deploy (config-only).

The autorun loop and `gen_deploy_artifacts` branch on the kind, so a non-service stack doesn't get a
VPS deploy job it can't use.
