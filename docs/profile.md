# The project profile

When you scaffold a Go project (or run `ace profile`), an **architecture-decision wizard** captures
what the project *is* and how it should ship, and writes an **editable** source of truth the autorun
loop reads to ground its work:

- **`.opencode/profile.yaml`** — structured (machine-read by the loop + agents).
- **`ARCHITECTURE.md`** — the human-readable prose face (regenerated from the profile).

Edit either by hand, or re-run `ace profile` to update them (it reads the existing values as
defaults and bumps `updated:`).

## The wizard, in order

`shape → domain/goal → audience → throughput → mission/values/philosophy → git? → ci_cd? → gitflow?
→ merge_gate → auto_merge → hardening → targets`

Hardening is **suggested** from the audience (public/customer-facing → `strong`); build targets come
**last** and are suggested from the shape. Every suggestion is a pre-filled default you can override.

## `.opencode/profile.yaml`

```yaml
schema: 1
name: <slug>
language: go
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
gitflow: true           # main + conventional commits + guards
merge_gate: remote      # remote (wait for Actions green) | local (merge on ./ci.sh --container green) | both (require both)
auto_merge: false       # auto-accept: loop self-merges when the gate is green
created: …
updated: …
```

Free-text fields are sanitized (quotes/backslashes stripped) so a stray `"` can't break the YAML.

## Delivery policy → loop behavior

The loop reads these as **defaults**; the matching env var still overrides per run.

| Profile field | Drives | Override |
|---------------|--------|----------|
| `merge_gate: remote` | wait for GitHub Actions all-green before merging | `MERGE_GATE=remote` |
| `merge_gate: local` | merge as soon as `./ci.sh --container` is GREEN (don't wait on Actions) | `MERGE_GATE=local` |
| `merge_gate: both` | require **both** a GREEN `./ci.sh --container` AND GitHub Actions all-green (strictest; never vouches local-only on a blocked-Actions lap) | `MERGE_GATE=both` |
| `auto_merge: true` | loop self-merges when the gate is green | `AUTOMERGE=1` |
| `auto_merge: false` | loop opens ONE PR and **stops** for review (does not keep building) | `AUTOMERGE=0` |
| `ci_cd: none` | skip the GitHub Actions workflow; forces `merge_gate` off remote → `local` | — |
| `git: false` | skip git setup entirely | — |
| `gitflow: false` | drops the gitflow guards (main-guard / conventional-commit), but **still activates the local `./ci.sh` gate** via `core.hooksPath` | — |

`merge_gate: local` generalizes the loop's existing "local gate vouches when remote CI is blocked"
path: the local VPS-parity container build becomes the merge authority by policy. Default stays
`remote` so existing repos don't change behavior.

## Alignment

`mission` / `values` / `audience` / `philosophy` are the source of truth for the **`alignment_reviewer`**
agent (see [agents.md](agents.md)): the orchestrator reads the profile and routes work to serve the
mission, and on high-impact/user-facing changes a dedicated critic checks the change against these
fields — the same pairing as `standards_keeper` ↔ `STANDARDS.md`.
