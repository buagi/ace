# Scenarios — runbooks

Concrete command sequences for the jobs you'll actually run. Run `ace` from inside the project repo unless a step says otherwise.

| # | Scenario | Use when |
|---|----------|----------|
| 1 | [New project from a clean machine](#1-new-project--autonomous-from-a-clean-machine) | Nothing installed yet; greenfield. |
| 2 | [New Go service — container + hardened binaries](#2-new-go-service--ship-a-container-and-hardened-binaries) | Shipping a Go binary or service. |
| 3 | [Adopt an existing repo](#3-adopt-an-existing-repo-keep-all-code--history) | You have code and history to keep. |
| 4 | [Choose the overseer brain](#4-choose-the-overseer-brain-cost-vs-quality) | Trading cost against planning quality. |
| 5 | [Unattended overnight run](#5-unattended-overnight-run-cost-aware) | A long, hands-off, cost-aware run. |
| 6 | [Merge on the local gate](#6-merge-on-the-local-gate-skip-waiting-on-actions) | Skipping the wait on GitHub Actions. |
| 7 | [Resume after a stop / crash / limit](#7-resume-after-a-stop--crash--limit) | A run died with work in flight. |
| 8 | [Stand up + deploy to a fresh VPS](#8-stand-up--deploy-to-a-fresh-vps) | First deploy to a new server. |
| 9 | [Pull the latest ACE](#9-pull-the-latest-ace-without-losing-progress) | Updating the CLI + machinery. |

## 1. New project → autonomous, from a clean machine

1. Clone ACE and put it on your PATH: `git clone <this-repo> ace && cd ace && ln -s "$PWD/ace" ~/.local/bin/ace`
2. Install host tools, keys, the 12-agent config, gh login, and Serena: `ace install`
3. Scaffold a new Node / Python / Go / Config project with full machinery: `ace scaffold`
4. Write your goals: `cd <project> && $EDITOR OBJECTIVES.md`
5. Start the hands-off loop: `ace autorun`

## 2. New Go service → ship a container and hardened binaries

1. Scaffold and choose Go — the wizard captures architecture, delivery, and hardening: `ace scaffold`
2. `cd <project>`
3. Run the VPS-parity build (gofmt/vet/test inside the golang image): `./ci.sh --container`
4. Cross-compile hardened static binaries into `dist/` (+ `SHA256SUMS`): `ace release`
5. Tag and push — CI builds the binaries and attaches them to the GitHub Release: `git tag v0.1.0 && git push --tags`

See [go-stack.md](go-stack.md) for the Go toolchain and release details.

## 3. Adopt an existing repo (keep all code + history)

1. `cd my-repo`
2. Backfill the machinery — additive; never touches `src/`, history, or your VPS: `ace upgrade`
3. Set goals and start: `$EDITOR OBJECTIVES.md && ace autorun`

## 4. Choose the overseer brain (cost vs quality)

The 10 workers always stay on DeepSeek; only the overseer changes.

1. Pick the brain: `ace keys` — `opus` (default) · `sonnet` (long runs) · `gpt` (OpenAI) · `deepseek` (no subscription).
2. Rewrite the config, then restart opencode so it loads at launch: `ace opencode`

## 5. Unattended overnight run (cost-aware)

1. `cd <project>`
2. Trim spend with the balanced profile (flash verifier): `ace keys` → `balanced`
3. Launch: `AUTOMERGE=1 SELF_IMPROVE=1 MAX_FEATURES=0 ace autorun`

> [!TIP]
> On a Claude cap the loop waits for reset on your model and never downgrades. For a run that never stalls overnight, add `ON_CLAUDE_LIMIT=deepseek` to fall back to DeepSeek and keep going.

## 6. Merge on the local gate (skip waiting on Actions)

1. `cd <project>` — set the profile to `merge_gate: local`, or override it per run.
2. Merge on a green `./ci.sh --container`, with no Actions wait: `MERGE_GATE=local AUTOMERGE=1 ace autorun`

> [!IMPORTANT]
> `merge_gate: local` only skips *waiting on GitHub Actions*. The loop still pushes a branch and opens a PR, so it needs a GitHub `origin` remote — publish the repo with `ace scaffold --publish`, or `gh repo create --source=. --remote=origin`. "Local gate" is not "no remote".

## 7. Resume after a stop / crash / limit

1. Commit gate-green work a dead run left behind, skip already-merged branches, and continue: `ace resume`

## 8. Stand up + deploy to a fresh VPS

1. Configure, bootstrap (offers Harden), and provision git deploy: `ace vps`
2. Apply lockout-safe hardening, then get a readiness verdict: `ace vps harden && ace vps check`
3. Pull, rebuild, restart, and health-check: `ace deploy`

See [deploy.md](deploy.md) for the deploy model and health-check knobs.

## 9. Pull the latest ACE without losing progress

1. Update the CLI — it is the repo: `cd <your-ace-clone> && git pull --ff-only`
2. Refresh the global brain and restart opencode: `ace opencode`
3. Refresh project machinery: `cd <project> && ace upgrade`

## See also

- [getting-started.md](getting-started.md) — first-run walkthrough
- [commands.md](commands.md) — every `ace` subcommand
- [configuration.md](configuration.md) — the env vars these runbooks set
- [deploy.md](deploy.md) — the VPS and deploy model in depth
