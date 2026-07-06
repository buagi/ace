# Configuration — knobs & where things live

## Model profile (`ace keys`)
`max` *(default — all agents deepest)* · `high` · `balanced` *(flash verifier — trims spend)*.

## Orchestrator brain (`ace keys`)
`opus` *(**default** — deepest planning; needs a Claude plan)* · `sonnet` *(best for long autoruns)* ·
`gpt` *(OpenAI GPT-5)* · `deepseek` *(no subscription)*. Quick path for just the overseer; for full control
use **`ace settings`** below.

## Providers & per-agent models (`ace settings`)
`ace settings → Models & agents` sets **which model each of the 9 agents runs** (DeepSeek · Anthropic ·
OpenAI), independently or via a preset (overseer-Claude · overseer-OpenAI · all-DeepSeek · mixed). Stored as
`MODEL_<agent>` in `~/.config/ace/config` (an unset overseer ⇒ the **Claude Opus default**; the 8 workers ⇒
DeepSeek). `ace settings → Providers & keys`:
- **DeepSeek** — API key (`DEEPSEEK_API_KEY`).
- **Anthropic** — Claude Pro/Max **subscription** by default: ACE installs the anthropic-auth plugin and
  runs `opencode auth login -p anthropic` (paste the token), so `anthropic/*` models bill your plan.
- **OpenAI** — ChatGPT **subscription** by default (or flip `AUTH_openai=api` to use `OPENAI_API_KEY`).
- **Subscription is the default; API key only if you set it explicitly.** ACE writes
  `~/.config/opencode/package.json` + `bun install`s the needed plugins on apply.

## Appearance (`ace settings → Appearance`)
Visual only — copy stays plain/technical. Stored in `~/.config/ace/config`; env vars override per run.
- **Theme** `THEME=warp|blood|void` (env `ACE_THEME`) — violet *(default)* · crimson · indigo-cyan
  *(dark sci-fi)*. Status colours are fixed regardless of theme: **green** ok · **yellow** warn · **red** fail.
- **Animation** `NO_ANIM=1` (env `ACE_NO_ANIM=1`) — disables the one-time intro reveal.
- **Pixel art** `ART=auto|off` (env `ACE_ART`) — when **`chafa`** is installed, the banner renders the
  `lib/art/ace-emblem.png` sprite at the best fidelity the terminal supports (kitty → sixel → blocks);
  otherwise a truecolor half-block emblem. `off` forces the half-block emblem.
- **Wordmark font** — if **`figlet`/`toilet`** are installed the `ACE` wordmark uses them (`ACE_FIGFONT`
  picks a font; `ACE_FIGLET=off` disables); else a block wordmark.
- Degrades to clean plain text under `NO_COLOR` or when stdout isn't a TTY (safe for pipes/CI).
- Optional enhancers, auto-detected if present: `chafa` (pixel art), `figlet`/`toilet` (wordmark).
  `ace install` offers to install them (confirm-gated, default no; skipped on immutable hosts — layer
  with `rpm-ostree install`/a toolbox). `ACE_VISUAL_EXTRAS=0` skips the offer. ACE uses them only when present.

## Headless & Signal (drive ACE from chat)
ACE is fully non-interactive, so the Hermes agent can run any flow from Signal/Telegram step by step.
- **`ACE_YES=1`** (`--yes`) — assume-yes: `confirm` returns its coded default, `ask`/`ask_path` return the
  default, `menu` needs `MENU_PICK`; nothing blocks on a TTY. Secrets are never prompted — pass them via
  env (`DEEPSEEK_API_KEY`, `CONTEXT7_API_KEY`).
- **`ACE_CONFIRM=1`** (`--confirm`) — unlocks the **gated destructive** commands (`deploy`, `uninstall`,
  `vps harden`), which otherwise refuse when headless.
- **`ACE_PROJECTS_DIR`** — default parent directory for `ace scaffold` (where new projects are created).
  Defaults to `~/projects` (created on first use). Set it to wherever you keep code, e.g.
  `export ACE_PROJECTS_DIR=~/code`. A relative entry, or an unwritable absolute path, at the
  scaffold prompt resolves under this dir; a real home path or existing writable dir is used as typed.
- **Scaffold flags** → env (every infra choice is explicit — nothing assumed): `--name`/`--path`/`--stack`/
  `--shape`/`--audience`/`--throughput`/`--domain`/`--mission` · `--no-git` · `--no-ci` · `--no-gitflow` ·
  `--no-container` (host-only gate, no `Containerfile`) · `--no-vps`/`--deploy none` · `--index` · `--publish`.
  `--no-git` implies no CI/VPS/publish. New profile field **`container: true|false`** gates the
  `Containerfile` + `./ci.sh --container` parity gate. Default stop is *scaffold + git init*; publish/index/VPS are opt-ins.
- **Snapshots** — `ace snap [--to <target>] [--out <png>] [command…]` renders the real (themed) CLI to a
  PNG via **`freeze`** (native PNG) or **`ansitoimg`** (SVG → PNG via ImageMagick) and sends it with
  `hermes send … "MEDIA:<png>"`. `ACE_FORCE_COLOR=1` forces colour off-TTY (used internally by snap).
- **Notifications** — channel-agnostic, **Telegram-first**: `HERMES_TO` default = **`telegram`** (any
  channel works — `signal:+1…`, `discord:<id>`, `slack:#chan`, `telegram:<chat_id>`, …). `HERMES_NOTIFY=1`
  enables milestone pings; `HERMES_SNAP=1` also attaches a CLI status snapshot; `HERMES_KANBAN=1` mirrors
  `ROADMAP.md` onto a Hermes kanban board (one-way, visibility only). Renderers install via `ace install`
  (`ACE_RENDER_TOOLS=0` to skip).

## Autorun env vars
`ace autorun` prompts for the common ones, or set them raw (`AUTOMERGE=1 MAX_FEATURES=5 bash scripts/auto-loop.sh`).

```bash
# --- delivery / merge ---
AUTOMERGE=1     # self-merge a PR once the gate is green + mergeable (defaults from the profile's auto_merge).
                #   AUTOMERGE=0 ⇒ open ONE PR and STOP for review (does not keep building on the branch).
MERGE_GATE=remote  # remote = wait for Actions green | local = merge on ./ci.sh --container green | both = require both
                   #   (defaults from .opencode/profile.yaml: merge_gate; env overrides per run)
                   #   NB: every gate (incl. local) still pushes a branch + opens a PR → needs a GitHub origin remote.
MERGE_APPROVAL= # set to `hermes` to PAUSE before every merge and wait for a chat `ace approve <tok> yes`
                #   (deny/timeout/no-channel → leave the PR open and stop). Empty = self-merge per AUTOMERGE.
DEPLOY=1        # run `ace deploy` after each merge — needs deploy_kind=service + a configured VPS (else no-op + warning)
DEPLOY_GATE=release  # gate in-loop deploys to milestones: ship ONLY when origin/main has a NEW v* tag
                     #   (last shipped tag tracked as DEPLOY_LAST_TAG in ~/.config/ace/config). Mark one with
                     #   `ace release --tag vX.Y.Z`. default `always` = ship whenever called. One-shot bypass:
                     #   `ace deploy --force` / DEPLOY_FORCE=1. Full model → docs/deploy.md
STOP_ON_DEPLOY_FAIL=1  # a failed in-loop deploy/health-check HALTS the loop (don't build onto a broken deploy); 0 = log + continue
VERIFY=1        # after each deploy, run the `ace verify` agent → triage live findings into ROADMAP.md (advisory; never halts)
LOCAL_CI_FALLBACK=0  # if Actions is BLOCKED (a run that fails having executed 0 jobs), accept a GREEN
                     #   local ./ci.sh --container as the pass + merge
LOCAL_CI_TIMEOUT=1800 # max seconds for the local container gate
# --- planning / caps ---
PLAN=1          # when the roadmap empties, plan the next OBJECTIVE into tasks (default on)
MAX_FIX=5       # CI auto-fix attempts per red before stopping
MAX_FEATURES=3  # features to ship this run (0 = unlimited)
RESOLVE_CONFLICTS=1 ; MAX_CONFLICT=2   # auto-resolve a conflicting PR (preserve both intents) vs stop
SELF_IMPROVE=1  # when ALL objectives are done, keep improving toward IMPROVE_GOAL (else stop)
IMPROVE_GOAL="generate income · solve real user problems · professional, reliable UX"
HARVEST=1 ; HARVEST_MAX=15   # curate build WARNINGS the gate let through into ROADMAP.md
CI_SCOPE=affected   # fast-gate test scope: affected (turbo --filter) | all. --container is ALWAYS full
JANITOR_EVERY=3 ; VERSION_CACHE_TTL=604800   # per-lap janitor cadence · LTS/EOL cache TTL (7d)
EXPECT_REPO=owner/name   # preflight hard-guard: refuse to run if origin isn't this repo
FIX_ACE=0       # if rathole notes exist: 1 = triage ACE first (READ-ONLY → files a GitHub issue you fix)
# --- per-step time budget (clocks ACTIVE work; slow deterministic steps pause the clock) ---
OPENCODE_TIMEOUT=2700 ; OPENCODE_TIMEOUT_MAX=8100 ; OPENCODE_RETRIES=2
OPENCODE_WALL_MAX=10800   # HARD wall ceiling per step (s) — bounds a stuck step
SLOW_STEPS="podman buildah docker pnpm npm yarn pip cargo go make tsc turbo vite jest pytest …"
WATCH_POLL=10 ; HEARTBEAT=60
# --- rathole supervisor ---
STALL_AFTER=900 ; RATHOLE_JUDGE=deepseek-v4-flash ; RATHOLE_RETRIES=2 ; RATHOLE_MAXCHECKS=6
ACE_FIXME=~/.config/ace/ace-fixme.log   # where persistent ratholes queue for the FIX_ACE inception pass
# --- overseer usage-limit policy (applies whenever the overseer is Claude Opus/Sonnet or OpenAI GPT — i.e. the default) ---
# default `wait` = poll for reset on YOUR model, never downgrade; opt into `deepseek` to fall back + keep going.
ON_CLAUDE_LIMIT=wait ; CLAUDE_POLL=120 ; CLAUDE_RESET_WAIT=21600   # 21600s = 6h, then stop for review
DEEPSEEK_OVERSEER=deepseek/deepseek-v4-pro
# --- chat / Hermes (all opt-in; no-op without `hermes`) ---
HERMES_NOTIFY=1   # send milestone pings to chat   ·   HERMES_TO=telegram   # channel (telegram-first)
HERMES_KANBAN=1   # mirror ROADMAP → a Hermes kanban board (one-way)   ·   HERMES_SNAP=1  # attach a CLI snapshot
```

> **Detached service (`ace loop start`) note:** the systemd user service inherits **none** of your shell
> environment — it reads only `.opencode/loop.env`. `ace loop start` writes that file once from the
> **launch-time** env, so set your knobs on that command (`HERMES_KANBAN=1 MERGE_APPROVAL=hermes HERMES_TO=signal ace loop start`)
> or edit `.opencode/loop.env` afterwards and `ace loop restart`. A foreground `ace autorun` inherits the
> env directly, so a prefix like `HERMES_KANBAN=1 ace autorun --yes` is enough there.
>
> **Survives OOM/crash:** the service unit is generated with `Restart=on-abnormal` (+ `RestartSec=20`,
> `OOMPolicy=continue`), so a loop killed by the kernel OOM-killer or a crash (i.e. terminated by a **signal**)
> is **auto-restarted and resumes** (it re-scans for in-flight work; metrics/state persist). `on-abnormal` restarts
> only on a signal/timeout — **not** on an exit code — so the loop's own deliberate halts (a clean finish, or an
> `exit 1` like "REFUSING to resume: WIP fails ci.sh") are respected, not flapped. `ace loop stop` never restarts;
> a genuine crash-loop stops after 6 restarts in 10 min (see `ace loop logs`).
> A **foreground** `ace autorun` has no supervisor — for unattended runs prefer `ace loop start`.
>
> **OOM avoidance:** user-session processes sit at `oom_score_adj≈100` (preferred OOM victims) and **can't** be
> given a protective negative score without root. But the memory cgroup controller *is* delegated to the user
> manager, so the unit ships **`MemoryLow=1G`** (`MemoryAccounting=yes`) — shielding the loop's core RAM from
> reclaim so the kernel prefers other victims. Tune with `LOOP_MEMORY_LOW` (e.g. `2G` for more headroom, `0` to
> omit; use `MemoryMin` for a *hard* reservation). Other levers: make a hog the preferred victim **unprivileged**
> — `choom -n 800 -p <steam-pid>`; lower the loop's own score only **with root** — `sudo choom -n -500 -p <pid>`;
> and don't run memory-heavy apps (games/Steam) alongside the loop's container/vitest gate. Between `MemoryLow`
> and auto-restart, the loop both resists the kill and recovers from it.

## Swarm env vars (`ace swarm` / parallel autorun)

The most-used knobs — the **full table** (with defaults) is in [swarm.md](swarm.md#config-knobs).

```bash
SWARM_MAX=4          # worker count (the `ace autorun` prompt sets this; capped at 8). Sticky in config.env.
SWARM_LIVE=1         # spend credits on the real loop (set for you by `ace swarm start` / `autorun`)
DRY_RUN=1            # 1 = simulated edits, zero credits (the `sandbox`); 0 = real
SWARM_SYNC=1         # run the OBJECTIVES→ROADMAP planning sync at start (0 to skip)
SWARM_ARCHIVE_KEEP=5 # per-run log archives kept under ~/.config/ace/swarm/<slug>/archive/
CREDIT_REVIEW=1      # credit review/reconcile/merge time off each worker's budget (like builds); 0 to charge it
ACE_NO_DASH=1        # don't auto-open the cockpit after `ace swarm start`
```
Each worker also honors the loop-wide knobs above (`MERGE_GATE`, `AUTOMERGE`, `DEPLOY`, the timeouts).

## Go release knobs (`ace release`)
```bash
HARDENING=none|standard|strong   # default from .opencode/profile.yaml (hardening)
TARGETS="linux/amd64 linux/arm64"  # default from the profile (targets)
UPX=1                            # pack binaries after building (optional)
GOIMAGE=golang:1.23              # container image for the default (container) build
ace release --host               # build on the host instead of in a container
```

## Post-deploy healthcheck
`ace vps` → configure, or set raw in `~/.config/ace/vps.env`: `VPS_HEALTH_URL`
*(default `http://127.0.0.1:3000/`; Go workflows default to `/healthz`, and a **Python** service publishes on
`:8000` — point the URL there)* · `VPS_HEALTH_TIMEOUT` *(90s)* · `VPS_HEALTH_INTERVAL` *(3s)*. Runs after every `ace deploy`.

`VPS_DEPLOY_DIR` *(default `$HOME/apps`)* — the parent directory on the VPS where each app deploys
(`<VPS_DEPLOY_DIR>/<repo>`). `VPS_SERVICE_UNIT` / `VPS_DOMAIN` — **prompted by `ace vps configure` and
persisted**. A blank `VPS_SERVICE_UNIT` means a **podman container named after the repo** (ACE's default
deploy), which `ace verify` / `ace vps check` then inspect; set it to a unit name only if you run the app as
a systemd service. `VPS_DOMAIN` enables the DNS + TLS-SAN checks in `ace vps check`.

## Where config lives

```
GLOBAL  (machine-wide · loaded by opencode at launch)
  ~/.config/opencode/opencode.json   9 agents · DeepSeek workers · MCP · compaction ~80%
  ~/.config/opencode/AGENTS.md       grounding · navigation · Definition-of-Done · git · handover
  ~/.config/ace/secrets.env          DEEPSEEK_API_KEY / CONTEXT7_API_KEY  (chmod 600)
  ~/.config/ace/vps.env              host/user/key/port/dir/os
  ~/.config/ace/{config,logs/}       model profile · per-agent models · appearance (THEME/ART/NO_ANIM) · run logs
  ~/.bashrc                          managed PATH block + sources secrets

PER-PROJECT  (scaffold writes · upgrade backfills)
  OBJECTIVES.md  ROADMAP.md          ◄ north star + task board
  .opencode/profile.yaml  ARCHITECTURE.md   ◄ project profile (Go) — see profile.md
  opencode.json                      project MCP (Go: gopls), merged with the global config
  ci.sh  Containerfile               tiered gate + pinned VPS-parity image
  .githooks/  .opencode/  docs/architecture.md   hooks · memory · specs · map snapshot
  .opencode/metrics.csv  .opencode/run-summary.txt   ◄ per-run timing (see autorun.md) · `ace loop stats`
  .github/workflows/                 build-test · security · codemap · deploy(gated) [· release (Go)]
  scripts/{auto-loop,graph-refresh,env-merge,deploy[,release]}.sh
```

## Code intelligence (GitNexus / Serena)
The agents navigate code through two MCP servers (configured in the global `opencode.json`):
- **GitNexus** (structure / impact / flows) is **installed globally** by `ace install` (`npm i -g gitnexus`) and
  launched as `gitnexus mcp` — *not* `npx gitnexus@latest`, which re-resolves the dist-tag on every spawn
  (slow + npm-11-flaky, #1939) and can lose the race with the orchestrator's first call → *"MCP server not
  connected"*. The MCP command falls back to `npx` if the global binary is missing.
- GitNexus keeps **one shared local index** (`~/.gitnexus/registry.json`) across **all** your repos, so once
  you've scaffolded more than one, every `gitnexus_*` call **must pass `repo: "<this repo's name>"`** or it
  errors `Multiple repositories indexed`. ACE bakes this rule into each project's `.opencode/project-facts.md`
  (with the repo name filled in), `docs/architecture.md`, and the global AGENTS.md, so the agents do it first try.
  Prune stale indexes with `gitnexus remove <name>` — dropping to a **single** indexed repo removes the need
  for the param entirely (the error can't occur). Loops bootstrapped *before* this rule shipped are
  **self-healed**: each `ace autorun` appends the `repo:` fact to an older `project-facts.md` that lacks it,
  so a call that would otherwise error and silently fall back to whole-file reads gets scoped instead.
- **Serena** (live symbols / references) runs via `uvx` against the current project (`--project .`).

## Context handover
opencode auto-compacts at `compaction.maxContext ≈ 840000` (~80% of the 1M window); agents keep
`.opencode/HANDOVER.md` current so a handover or crash loses nothing. Drift? Lower `maxContext`
toward `600000` (earlier handover = safer).
