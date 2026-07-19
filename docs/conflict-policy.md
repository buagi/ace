# Conflict policy

How the swarm handles the merge conflicts it can predict, so workers never fight over the files every feature touches.

> [!NOTE]
> This is the merge-safety layer under the [swarm](swarm.md). If you're new to the parallel loop, read [swarm.md](swarm.md) first.

Some files are **predictably contended**: every feature edits them, so two concurrent workers collide there no matter how disjoint their real work is — version numbers, changelogs, lockfiles, a command registry. Asking the `conflict_resolver` to sort these out after the fact is backwards: the outcome is knowable up front, so it's decided up front.

`lib/swarm-policy.sh` turns three previously ad-hoc mechanisms — the `SWARM_META_FREE` list, the `.gitattributes` union driver, and the graph refresh — into one declarative table. Strategies are language-agnostic and defaults are auto-detected from which files exist, so most projects need zero configuration.

## Strategies

| Strategy | For | What happens |
|---|---|---|
| `union` | append-only files (changelog, lessons, release notes) | git `merge=union` keeps **both** sides — no entry is ever lost |
| `struct:json` `struct:toml` `struct:yaml` | structured manifests (`package.json`, `Cargo.toml`, `pyproject.toml`) | a 3-way **data** merge (`merge-structured.sh`): two workers adding *different* deps merge cleanly; a real clash (same key, different value) escalates to the resolver |
| `regenerate:<cmd>` | derived files (lockfiles) | at merge time the file takes `merge=ours` (one side wins, the merge never blocks); the coordinator then re-runs `<cmd>` post-merge and commits the result — lockfiles are never text-merged, because a union on hash lines produces a broken file |
| `assign` | monotonic / authoritative values (version) | **single writer by convention** — the glob is lease-free so no item ever claims it, and ACE cuts version as a release tag (`ace release --tag`) rather than a per-item edit. Nothing *blocks* a worker from writing the file; no merge driver is registered for it |
| `allocate` | sequential ids (migration numbers) | coordinator hands out the next value at dispatch. Not auto-applied yet — see [deferred-decisions.md](deferred-decisions.md) |
| `ignore` | files generated wholesale (`.gitnexus`) | never leased; no merge driver registered, so if a worker does change it git's ordinary 3-way merge applies |

Every strategy makes the file **lease-free**: no worker gets exclusive ownership, so items never falsely contend on it. This generalizes the old `SWARM_META_FREE` list.

### What the structured merge actually does

`merge-structured.sh` descends both sides against the base key by key. A key **absent** on a side is tracked as absent — deliberately distinct from a key present and set to `null` or `false`. That distinction is what makes two behaviours hold:

- a key one side **deleted** stays deleted, as long as the other side did not touch it (no resurrection of a removed dep);
- a key set to `false` or `null` keeps that value (an earlier `//null` descent silently rewrote `"strict": false` to `null`).

Both are covered by fixtures in `ace swarm policy-selftest`.

It needs `jq` for `struct:json`, and `yq` as well for `struct:toml` / `struct:yaml`. If a tool is missing, the input doesn't parse, or a genuine clash is found, the driver writes normal conflict markers and exits non-zero — git then escalates to the `conflict_resolver`. It never resolves silently on inputs it could not read.

## Where each strategy runs

| Phase | Runs in | When |
|---|---|---|
| lease-free stripping | `swarm_paths_for_item` (`swarm.sh`) | at claim time — policy globs are dropped so a claim never includes a contended file |
| `union` / `struct` merge drivers | `swarm_policy_apply` writes `.gitattributes` and registers the driver commands in `.git/config` | at swarm start; the merge itself resolves at merge time |
| `regenerate` | `swarm_policy_regenerate`, called from the coordinator's `_tick_roadmap` | post-merge, serialized under the merge lock, after an item merges — and only when the lockfile or its governing manifest actually changed in that merge |

`assign`, `allocate` and `ignore` have no runtime step at all: they are lease-free entries only. `swarm_policy_regenerate` acts on `regenerate:` rules and nothing else.

> [!NOTE]
> When the `mergiraf` binary is on `PATH`, `swarm_policy_apply` also registers a structural (AST) merge driver as a `* merge=mergiraf` front line, so two workers editing *different functions in the same file* resolve deterministically instead of hitting the LLM resolver. It is feature-gated and fail-open: if `mergiraf` is absent, nothing is registered and git's plain 3-way merge escalates to the `conflict_resolver` exactly as before.

## Defaults (auto-detected, no config)

Emitted only for files that actually exist in the repo, so the effective policy stays minimal:

| Files present | Strategy |
|---|---|
| lockfiles (see table below) | `regenerate` with the matching tool |
| `package.json`, `composer.json`, `tsconfig.json` | `struct:json` |
| `Cargo.toml`, `pyproject.toml` | `struct:toml` |
| *(no default)* | `struct:yaml` — the driver is registered, but nothing auto-detects into it; reach it via an override |
| `VERSION`, `version.txt` | `assign` |
| `CHANGELOG.md`, `HISTORY.md`, `NEWS.md`, `RELEASES.md`, `.opencode/lessons.md`, `.opencode/memory/changelog.md`, `.opencode/STANDARDS.md` | `union` |
| `.gitnexus/**` | `ignore` |

Lockfiles map to the tool that regenerates them:

| Lockfile | Regenerate command |
|---|---|
| `package-lock.json` | `npm install --package-lock-only --ignore-scripts` |
| `pnpm-lock.yaml` | `pnpm install --lockfile-only` |
| `yarn.lock` | `yarn install --mode=update-lockfile` |
| `go.sum` (emitted when `go.sum` **or** `go.mod` is present) | `go mod tidy` |
| `Cargo.lock` | `cargo generate-lockfile` |
| `poetry.lock` | `poetry lock --no-update` |
| `Gemfile.lock` | `bundle lock` |
| `composer.lock` | `composer update --lock` |

## Overriding per project

Drop a `.opencode/conflict-policy` file in the repo — one rule per line, `#` comments allowed:

```
# glob                strategy
VERSION               assign
internal/registry.go  union                 # append-only registrations
config/*.yaml         struct:yaml
db/schema.sql         regenerate:make schema-dump
```

Later lines override the defaults by glob.

> [!WARNING]
> A `regenerate:` command runs post-merge in the repo. Treat `.opencode/conflict-policy` as trusted, project-owned input — the same trust level as a Makefile.

## Inspect and test

| Command | What it does |
|---|---|
| `ace swarm policy` | print the effective policy table for the current repo |
| `ace swarm policy-selftest` | exercise the structured merge — disjoint adds merge, a true clash escalates |

The swarm applies the policy automatically at start (`ace swarm start` / `ace autorun`). You only need these commands to inspect what it inferred, or to debug a `.opencode/conflict-policy` override.

## See also

- [swarm.md](swarm.md) — the parallel loop this protects
- [deferred-decisions.md](deferred-decisions.md) — the `allocate` strategy and the serialized-merge re-gate, and why they're deferred
- [the-gate.md](the-gate.md) — the `ci.sh` gate each worker must pass before merging
