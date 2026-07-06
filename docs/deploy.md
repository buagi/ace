# Deploying — what ships, when, and how to check it

ACE deploys along three independent axes. Getting them straight is the difference between "why won't it
deploy" and "why is it deploying on every merge".

| Axis | Question | Set by |
|------|----------|--------|
| **What** | is there anything to deploy? | `deploy_kind` (profile) |
| **When** | how often does it ship? | `DEPLOY` + `DEPLOY_GATE` (env/config) |
| **How** | what pushes the bits? | in-loop `ace deploy` (SSH) **or** the CI deploy job (git) |

## What — `deploy_kind`
From `.opencode/profile.yaml` (derived from the project shape):
- **`service`** — a long-running app on a VPS (the deploy path below).
- **`artifact`** — binaries; they ship on a `v*` tag via the CI **release** job, not a VPS deploy.
- **`none`** — nothing deployable (a library).

## When — cadence
The loop's per-merge deploy is controlled by two knobs:

```bash
DEPLOY=1              # run `ace deploy` after each merge (needs deploy_kind=service + a configured VPS)
DEPLOY_GATE=release   # …but only actually ship when origin/main has a NEW v* tag (see below)
```

Three regimes:

- **Every merge** — `DEPLOY=1`, `DEPLOY_GATE` unset (or `always`). After each self-merge the loop runs a full
  VPS deploy + healthcheck. Simple, but every merge blocks the loop on a build+restart (this is usually what
  "it deploys too often / the loop feels slow" means).
- **Milestones only** — `DEPLOY=1` **and** `DEPLOY_GATE=release`. The loop still calls `ace deploy` every merge,
  but it **no-ops unless `origin/main` carries a `v*` tag it hasn't deployed yet** (the last shipped tag is
  recorded in `~/.config/ace/config` as `DEPLOY_LAST_TAG`). You decide the granularity by *when you tag* — a
  complete feature, a finished objective section, a major version. Mark one with:
  ```bash
  ace release --tag v1.2.0        # or: git tag v1.2.0 && git push --tags
  ```
  The next `ace deploy` sees the new tag, ships it, and records it. Deploy right now regardless of the gate:
  ```bash
  ace deploy --force              # or: DEPLOY_FORCE=1 ace deploy
  ```
  `DEPLOY_GATE` lives in global ACE config, so flipping it takes effect on the loop's **next** `ace deploy`
  call — no loop restart needed (the loop shells out to the global `ace` binary).
- **Off** — `DEPLOY=0`. The loop never deploys; you ship by hand (`ace deploy --force`) or via the CI job.

**On failure** — a failed in-loop `ace deploy` or its health-check **halts the loop** (`STOP_ON_DEPLOY_FAIL=1`,
the default) so it never keeps building features onto a broken live deploy. Fix the deploy, then `ace resume`.
Set `STOP_ON_DEPLOY_FAIL=0` to log the failure and keep going instead (e.g. long unattended runs where a
transient VPS blip shouldn't halt everything). The **verify** step (`VERIFY=1`) is advisory and never halts.

## How — two transports (and only one can break the loop)
1. **In-loop `ace deploy`** (SSH, synchronous). SSHes to the VPS, `git fetch && git reset --hard origin/main`,
   runs `scripts/deploy.sh` (install → build → migrate → restart), then a healthcheck. Runs from your machine
   / the loop host. Because it's synchronous, a failure here **halts the loop** by default (`STOP_ON_DEPLOY_FAIL=1`).
2. **CI deploy job** (`.github/workflows/ci.yml`, git-triggered, async). Runs in GitHub Actions **after** a
   push to `main`, gated by the `CI_DEPLOY` repo variable and the `VPS_HOST` / `VPS_USER` / `VPS_SSH_KEY`
   secrets. It's fully decoupled from the loop — **a failed CI deploy never breaks the loop**, it just leaves
   a red run + a stale VPS. Enable/disable:
   ```bash
   gh variable set CI_DEPLOY --body true     # enable   (unset/false = the job is skipped)
   gh secret set VPS_HOST … VPS_USER … VPS_SSH_KEY …
   ```
   Trigger is `push to main` by default; gate it to releases by switching the `if:` to
   `startsWith(github.ref, 'refs/tags/v')` (the newer scaffold generates this form).

> Pick **one** cadence source. Running in-loop per-merge deploy **and** the CI job on push-to-main means you
> deploy twice. The common setups: loop deploys at milestones (`DEPLOY_GATE=release`) **or** CI deploys on
> tags (`CI_DEPLOY=true` + tag trigger, `DEPLOY=0`).

## Where to check what's ACTUALLY live
The transports differ in what they record, which is a classic source of "I feel like nothing deployed in ages":

- **The VPS is ground truth.** `ace verify` (read-only: service state, restarts, TLS, health, errors), or by hand:
  ```bash
  ssh <vps> 'git -C /opt/<app> log -1 && systemctl status <app> && curl -s localhost:3000/api/system/status'
  ```
  Deploy dir is `${VPS_DEPLOY_DIR:-$HOME/apps}/<name>` unless you configured otherwise.
- **GitHub → Environments → production (Deployments tab) only records the CI job.** If `CI_DEPLOY` is off, that
  tab looks dead **even while in-loop deploys keep the VPS current** — it is *not* a record of what's running.
  Trust the VPS, not the tab, unless you deploy exclusively through CI.

## Post-deploy verification
- **Healthcheck** runs after every `ace deploy` — `VPS_HEALTH_URL` (default `http://127.0.0.1:3000/`, Go: `/healthz`),
  `VPS_HEALTH_TIMEOUT` (90s). It classifies failures (CONFIG vs RUNTIME vs CODE) so a bad probe URL isn't mistaken
  for a crash.
- **`VERIFY=1`** additionally runs the `ace verify` agent after a deploy: it collects live facts read-only and
  triages real problems + improvements into `ROADMAP.md`, so the loop fixes them next pass. (It still runs
  per-merge even when a deploy was gate-skipped — set `VERIFY=0` if you want it only on real deploys.)

## Knob reference
```bash
DEPLOY=1              # per-merge deploy on (needs deploy_kind=service + configured VPS)
DEPLOY_GATE=release   # gate in-loop deploys to new v* tags (default `always` = ship whenever called)
DEPLOY_FORCE=1        # one-shot bypass of the gate (same as `ace deploy --force`)
STOP_ON_DEPLOY_FAIL=1 # a failed in-loop deploy/health-check HALTS the loop (0 = log + continue)
VERIFY=1              # run `ace verify` (live triage → ROADMAP) after a deploy (advisory; never halts)
CI_DEPLOY=true        # (repo variable) enable the async CI deploy job
```
See also: [configuration.md](configuration.md) (all knobs · VPS config), [the-gate.md](the-gate.md) (what must be
green before a merge), [autorun.md](autorun.md) (the loop).
