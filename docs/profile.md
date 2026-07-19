# Project profile

The editable source of truth that captures what a project is and how it ships. The autorun loop and agents read it to ground their work.

Scaffolding a code project (Node, Python, or Go) — or running `ace profile` in any repo — opens an architecture-decision wizard whose two output files are:

| File | Role |
|------|------|
| `.opencode/profile.yaml` | structured, machine-read by the loop and agents |
| `ARCHITECTURE.md` | the human-readable prose face, regenerated from the profile |

It also seeds `OBJECTIVES.md` and points `AGENTS.md` at the profile on the same pass.

Edit either by hand, or re-run `ace profile` to update them. A re-run reads the existing values as defaults (pre-filled), preserves `created:`, and bumps `updated:`.

> [!NOTE]
> The Config stack skips the wizard — config-only projects are not loop targets. They keep flag- and default-driven values.

## The wizard, in order

Every prompt defaults to the existing value on a re-run, or to the seeded flag (e.g. `--shape`) on a fresh scaffold.

| # | Decision | Options / notes |
|---|----------|-----------------|
| 1 | `shape` | `api` · `cli` · `cli-web` · `worker` · `library` |
| 2 | `domain` | one-line description of what it does |
| 3 | `audience` | `internal` · `oss-public` · `end-customer` · `enterprise` |
| 4 | `throughput` | `low` · `medium` · `high` |
| 5 | `mission` | why this exists (one line) |
| 6 | `values` | comma-separated, e.g. `reliability, privacy` |
| 7 | `philosophy` | e.g. `fail-closed, boring tech, no dark patterns` |
| 8 | `git?` | use git at all |
| 9 | `ci_cd?` | GitHub Actions workflow (asked only if git) |
| 10 | `gitflow?` | main + conventional commits + guards (asked only if git) |
| 11 | `container?` | Containerfile + `./ci.sh --container` parity gate, or host-only |
| 12 | `merge_gate` | asked only if CI/CD is on; otherwise forced to `local` |
| 13 | `auto_merge` | loop self-merges on a green gate, or opens a PR and stops |
| 14 | `hardening` | **suggested** from audience (`oss-public`/`end-customer` → `strong`) |
| 15 | `targets` | build targets, **suggested** from shape |

Hardening and build targets come last because they are suggested from earlier answers. Every suggestion is a pre-filled default you can override.

## `.opencode/profile.yaml`

```yaml
schema: 1
name: <slug>
language: go            # go | node | python | config  (detected on a standalone `ace profile`)
# --- architecture ---
shape: api              # api | cli | cli-web | worker | library
domain: "<one-line description>"
audience: internal      # internal | oss-public | end-customer | enterprise
throughput: low         # low | medium | high
hardening: standard     # none | standard | strong   (the release path consumes this)
targets: [linux/amd64, linux/arm64]
# --- alignment (the alignment_reviewer agent reviews changes against these) ---
mission: "<why this exists>"
values: [reliability, privacy]
philosophy: "<e.g. fail-closed, boring tech, no dark patterns>"
# --- delivery / git policy ---
git: true               # use git at all
ci_cd: github-actions   # github-actions | none
container: true         # true = Containerfile + container parity gate | false = host-only
gitflow: true           # main + conventional commits + guards
merge_gate: remote      # remote (wait for Actions green) | local (merge on ./ci.sh --container green) | both
auto_merge: false       # auto-accept: loop self-merges when the gate is green (env AUTOMERGE overrides)
deploy_kind: service    # service | artifact | none — derived from shape
created: …
updated: …
```

> [!NOTE]
> Free-text fields (`domain`, `mission`, `values`, `philosophy`) are sanitized: quotes and backslashes are stripped, so a stray `"` can't break the YAML.

## Delivery policy → loop behavior

The loop reads these as **defaults**; the matching env var still overrides per run.

| Profile field | Drives | Override |
|---------------|--------|----------|
| `merge_gate: remote` | wait for GitHub Actions all-green before merging | `MERGE_GATE=remote` |
| `merge_gate: local` | merge as soon as `./ci.sh --container` is green (don't wait on Actions) | `MERGE_GATE=local` |
| `merge_gate: both` | require **both** a green `./ci.sh --container` and GitHub Actions all-green (strictest) | `MERGE_GATE=both` |
| `auto_merge: true` | loop self-merges when the gate is green | `AUTOMERGE=1` |
| `auto_merge: false` | loop opens ONE PR and stops for review (does not keep building) | `AUTOMERGE=0` |
| `ci_cd: none` | skip the GitHub Actions workflow; forces `merge_gate` off remote → `local` | — |
| `git: false` | skip git setup entirely | — |
| `gitflow: false` | at **scaffold** time: drop the gitflow guards, but still activate the local `./ci.sh` gate via `core.hooksPath` (`lib/scaffold.sh:164`). On `ace upgrade` (adopting an existing repo) activation is conditional — it is skipped, with a warning, if the repo has no `ci.sh` or already has its own `.git/hooks/pre-commit` (`lib/scaffold.sh:3510-3520`) | — |

> [!NOTE]
> `merge_gate: local` generalizes the loop's existing "local gate vouches when remote CI is blocked" path: the local VPS-parity container build becomes the merge authority by policy. The default stays `remote` so existing repos don't change behavior.

## Derived fields

`deploy_kind` is derived from `shape` — it decides what the loop does after a merge:

| `shape` | `deploy_kind` | After merge |
|---------|---------------|-------------|
| `api` · `worker` | `service` | deploy to the VPS |
| `cli` · `cli-web` | `artifact` | binaries ship on `v*` tags (`ace release`) |
| `library` | `none` | nothing to deploy |

Two overrides collapse a `service` to `none`:

- `container: false` — no image to deploy (use `ace release` for binaries).
- `--no-vps` at scaffold (`ACE_DEPLOY=none`) — persisted to the profile so the loop honors it.

## Alignment

`mission` · `values` · `audience` · `philosophy` are the source of truth for the **`alignment_reviewer`** agent (see [agents.md](agents.md)):

- The orchestrator reads the profile and routes work to serve the mission.
- On high-impact or user-facing changes, a dedicated critic checks the change against these fields.

This is the same pairing as `standards_keeper` ↔ `STANDARDS.md`.

## See also

- [autorun.md](autorun.md) — the loop that reads this profile
- [the-gate.md](the-gate.md) — `./ci.sh`, the gate `merge_gate` and `container` refer to
- [agents.md](agents.md) — `alignment_reviewer` and the other agents
- [configuration.md](configuration.md) — the env overrides in full
