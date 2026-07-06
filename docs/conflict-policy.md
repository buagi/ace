# Conflict policy — handling predictable merge conflicts in the swarm

> Part of the [swarm](swarm.md). New to the parallel loop? Read [swarm.md](swarm.md) first — this page
> is the merge-safety layer underneath it.

Some files are **predictably contended**: every feature touches them, so two concurrent
swarm workers will collide there no matter how disjoint their real work is. Version numbers,
changelogs, lockfiles, a command registry. Asking the `conflict_resolver` to sort these out
after the fact is backwards — the outcome is *knowable up front*, so we decide it up front.

`lib/swarm-policy.sh` turns three previously ad-hoc mechanisms (`SWARM_META_FREE`, the
`.gitattributes` union driver, the graph refresh) into **one declarative table**. It is
**universal** — strategies are language-agnostic and defaults are auto-detected by which files
exist, so most projects need zero configuration.

## Strategies

| Strategy | For | What happens |
|---|---|---|
| `union` | append-only (CHANGELOG, lessons, release notes) | git `merge=union` keeps **both** sides — no entry is ever lost |
| `struct:json` / `struct:toml` / `struct:yaml` | structured manifests (package.json, Cargo.toml, pyproject.toml) | a **3-way DATA merge** (`merge-structured.sh`): two workers adding *different* deps merge cleanly; a real clash (same key, different value) escalates to the resolver |
| `regenerate:<cmd>` | derived files (lockfiles: go.sum, package-lock.json, Cargo.lock…) | the coordinator **re-runs `<cmd>`** post-merge and commits the result — lockfiles are never text-merged (union on hash lines produces a *broken* file) |
| `assign` | monotonic/authoritative (version) | **single writer** — workers never touch it. ACE cuts version as a release tag (`ace release --tag`), not a per-item edit, so parallel bumps can't happen |
| `allocate` | sequential ids (migration numbers) | coordinator hands out the next value at dispatch (see `deferred-decisions.md` — not auto-applied yet) |
| `ignore` | generated wholesale (.gitnexus) | never leased, never merged |

**Every** strategy makes the file **lease-free**: no worker gets exclusive ownership, so items
never falsely contend on it (this generalizes the old `SWARM_META_FREE` list).

## Where each strategy runs

- **lease-free stripping** — `swarm_paths_for_item` (swarm.sh) drops policy globs so a claim never
  includes a contended file.
- **union / struct** — `.gitattributes` merge drivers, applied by `swarm_policy_apply` at swarm
  start (registers the driver commands in `.git/config`). Resolution happens at *merge time*.
- **regenerate / assign** — `swarm_policy_regenerate`, called from the coordinator's
  `_tick_roadmap` (serialized under the merge lock) *after* an item merges.

## Defaults (auto-detected, no config)

Emitted only for files that actually exist in the repo:
- Lockfiles → `regenerate` with the matching tool (`go mod tidy`, `npm install --package-lock-only`,
  `cargo generate-lockfile`, `poetry lock --no-update`, `bundle lock`, `composer update --lock`, …).
- `package.json` / `composer.json` / `tsconfig.json` → `struct:json`; `Cargo.toml` / `pyproject.toml` → `struct:toml`.
- `VERSION` / `version.txt` → `assign`.
- `CHANGELOG.md` / `HISTORY.md` / `NEWS.md` / `RELEASES.md` + lessons + changelog → `union`.
- `.gitnexus/**` → `ignore`.

## Overriding per project

Drop `.opencode/conflict-policy` in the repo — one rule per line, `#` comments allowed:

```
# glob                strategy
VERSION               assign
internal/registry.go  union                 # append-only registrations
config/*.yaml         struct:yaml
db/schema.sql         regenerate:make schema-dump
```

Later lines override defaults by glob. **The `regenerate:` command runs post-merge in the repo**,
so treat the policy file as trusted (project-owned, like a Makefile).

## Inspect / test

```bash
ace swarm policy            # print the effective policy table for the current repo
ace swarm policy-selftest   # exercise the structured merge (disjoint-add merges · true-clash escalates)
```

The swarm applies the policy automatically at start (`ace swarm start` / `ace autorun`) — you only need
these to inspect what it inferred, or to debug a `.opencode/conflict-policy` override.
