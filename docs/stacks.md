# Stacks

`ace scaffold` generates a project for one **stack**. Every stack is defined in a single registry in [`lib/scaffold.sh`](../lib/scaffold.sh) — the menu, dispatch, and shared CI jobs all read from it.

## Built-in stacks

| Stack | Generator | Gate (`ci.sh`) | Deploy kind |
|-------|-----------|----------------|-------------|
| Node / TypeScript | `gen_node` | pnpm + turbo, vitest, tsc/eslint; `--container` parity | `service` (podman → VPS) |
| Python | `gen_python` | pytest, `py_compile`; `--container` parity | `service` |
| Config only | `gen_configonly` | template `ci.sh` (fill in your own) | `none` |
| Go | `gen_go` (+ profile wizard) | gofmt/vet/staticcheck/test; `--container` parity | `service` + `artifact` (hardened binaries) |

The Go stack is the most built-out — see [go-stack.md](go-stack.md).

## Shared machinery

Every stack gets the same baseline, regardless of language:

| Piece | What it is |
|-------|-----------|
| Git hooks | pre-commit (fast `ci.sh`) and pre-push (`--container`) |
| `.opencode/` context | profile, standards, agents, memory |
| Autorun loop | the build/gate/merge/deploy loop |
| Tiered `ci.sh` | fast host gate + `--container` parity |
| GitHub Actions workflow | emitted when CI/CD is on |

The workflow's **codemap** job is identical across stacks — it is emitted once, not copy-pasted per language.

> [!NOTE]
> The **deploy** job is emitted only for a service (`deploy_kind=service`, the Node/Python default). Config-only projects, `container:false` projects, and `deploy=none` projects get no deploy job.

## The stack registry

Near the top of `scaffold_project` in `lib/scaffold.sh`:

```bash
STACK_ORDER="node python config go"                       # menu order
declare -A STACK_LABEL=(  [node]="Node / TypeScript" … )  # menu label
declare -A STACK_HINT=(   [node]="pnpm + turbo …" … )     # menu hint
declare -A STACK_GEN=(    [node]="gen_node" … )           # generator function
declare -A STACK_DEPLOY=( [node]="service"  … )           # service | artifact | none
```

Everything keys on the stack **name** (`node`/`python`/`go`/…), never a menu number, so inserting a stack never renumbers anything.

## How to add a new stack

Adding a stack (say, Rust) touches four places, all small.

### 1. Register it

Add the name to `STACK_ORDER` and give it a label, hint, generator, and deploy kind:

```bash
STACK_ORDER="node python config go rust"
STACK_LABEL[rust]="Rust";  STACK_HINT[rust]="cargo, clippy, tiered ci"
STACK_GEN[rust]="gen_rust";  STACK_DEPLOY[rust]="service"
```

### 2. Write `gen_rust "$name"`

Mirror `gen_node`/`gen_go`. Emit:

- the skeleton, `.gitignore`, and `.env.example`;
- a multi-stage `Containerfile` with a `test` target;
- a tiered `ci.sh` — fast host gate plus `--container` parity, including the no-stubs depth gate for `.rs`;
- a call to `gen_project_agents "$name" "<one-line stack description>"`.

### 3. Add a CI case in `gen_ci_workflow`

One `case` arm emits the per-stack **build-test** and **security** jobs — for Rust, `cargo build/test/clippy` plus `cargo audit`.

The shared jobs come from helpers you do not touch:

| Job | Helper |
|-----|--------|
| codemap | `_ci_codemap_job` |
| deploy | `_ci_deploy_job` |
| release (Go-only) | `_ci_release_job` |

> [!TIP]
> If the app serves HTTP, set its health path (`hpath`) so the deploy healthcheck probes the right endpoint.

### 4. Only if it deploys unusually

Add a branch in `gen_deploy_artifacts`. The `service` default builds a container image and runs it; an `artifact` stack would instead produce a release.

That's it — the menu entry, dispatch, and shared CI jobs all follow from the registry.

## Deploy kinds

`STACK_DEPLOY` (and, for Go, the shape) records one of three kinds. The autorun loop and `gen_deploy_artifacts` branch on it, so a non-service stack never gets a VPS deploy job it can't use.

| Kind | Meaning |
|------|---------|
| `service` | A long-running container, deployed to the VPS and verified with an HTTP healthcheck. The default (Node / Python / Go `api`). |
| `artifact` | Shippable binaries/packages rather than a running service (Go's hardened release path — see [go-stack.md](go-stack.md)). |
| `none` | No deploy (config-only). |

## See also

- [go-stack.md](go-stack.md) — the most built-out stack, end to end
- [deploy.md](deploy.md) — what `deploy_kind` means for shipping
- [the-gate.md](the-gate.md) — the tiered `ci.sh` every stack shares
