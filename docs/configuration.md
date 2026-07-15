# Configuration

Every knob ACE reads: model and provider selection, the autorun loop's environment variables, appearance, and where settings are stored on disk.

## Precedence

Settings resolve the same way everywhere: an environment variable overrides stored config or the project profile, which overrides the built-in default.

- `ace keys` and `ace settings` write the stored config under `~/.config/ace/`.
- A per-run prefix (`VAR=… ace …`) overrides it for that run.
- The autorun loop's defaults come from `.opencode/profile.yaml` for a few keys (noted below).

See [Where config lives](#where-config-lives) for the full file map.

## Models, providers & keys

### Model profile (`ace keys`)

How deep every agent runs — a spend/quality dial.

| Profile | What it does |
|---------|--------------|
| `max` | **Default.** All agents run deepest. |
| `high` | High effort across the board. |
| `balanced` | Flash verifier — trims spend on the check step. |

### Orchestrator brain (`ace keys`)

Quick path to set just the overseer. For full per-agent control use `ace settings`.

| Brain | Notes |
|-------|-------|
| `opus` | **Default.** Deepest planning; needs a Claude plan. |
| `sonnet` | Best for long autoruns. |
| `gpt` | OpenAI GPT-5. |
| `deepseek` | No subscription required. |

### Providers & per-agent models (`ace settings`)

`ace settings → Models & agents` sets which model each of the 10 agents runs, independently or via a preset (`overseer-Claude` · `overseer-OpenAI` · `all-DeepSeek` · `mixed`). Each choice is stored as `MODEL_<agent>` in `~/.config/ace/config`. An unset overseer defaults to Claude Opus; the 8 workers default to DeepSeek.

`ace settings → Providers & keys`:

| Provider | Default auth | Detail |
|----------|--------------|--------|
| DeepSeek | API key | `DEEPSEEK_API_KEY`. |
| Anthropic | Claude Pro/Max **subscription** | ACE installs the anthropic-auth plugin and runs `opencode auth login -p anthropic` (paste the token), so `anthropic/*` models bill your plan. |
| OpenAI | ChatGPT **subscription** | Or set `AUTH_openai=api` to use `OPENAI_API_KEY` instead. |

> [!NOTE]
> Subscription is the default for Anthropic and OpenAI; an API key is used only if you set one explicitly. On apply, ACE writes `~/.config/opencode/package.json` and runs `bun install` for the needed plugins.

## Autorun environment variables

`ace autorun` prompts for the common ones, or set them raw: `AUTOMERGE=1 MAX_FEATURES=5 ace autorun`. A detached `ace loop start` reads them only from `.opencode/loop.env` — see [Detached service](#detached-service-ace-loop-start).

### Delivery & merge

| Var | Default | What it does |
|-----|---------|--------------|
| `AUTOMERGE` | profile `auto_merge` | `1` self-merges a PR once the gate is green and mergeable. `0` opens ONE PR and stops for review (does not keep building on the branch). |
| `MERGE_GATE` | profile `merge_gate` | What authorizes a merge: `remote` (wait for Actions green) · `local` (merge on `./ci.sh --container` green) · `both` (require both). |
| `MERGE_APPROVAL` | *(empty)* | `hermes` pauses before every merge and waits for a chat `ace approve <tok> yes`. Deny, timeout, or no channel leaves the PR open and stops. Empty = self-merge per `AUTOMERGE`. |
| `DEPLOY` | `0` | `1` runs `ace deploy` after each merge. Needs `deploy_kind=service` + a configured VPS, else a no-op with a warning. |
| `DEPLOY_GATE` | `always` | `release` ships only when `origin/main` carries a new `v*` tag (milestone-gated); the last shipped tag is tracked as `DEPLOY_LAST_TAG` in `~/.config/ace/config`. Mark one with `ace release --tag vX.Y.Z`. |
| `DEPLOY_FORCE` | `0` | `1` (or `ace deploy --force`) bypasses `DEPLOY_GATE` for one on-demand deploy. |
| `STOP_ON_DEPLOY_FAIL` | `1` | A failed in-loop deploy or health check halts the loop. `0` logs and continues. |
| `VERIFY` | `0` | `1` runs the `ace verify` agent after each deploy and triages live findings into `ROADMAP.md` (advisory — never halts). |
| `LOCAL_CI_FALLBACK` | `0` | `1` accepts a green local `./ci.sh --container` as the pass + merge when Actions is BLOCKED (a run that fails having executed 0 jobs). |
| `LOCAL_CI_TIMEOUT` | `1800` | Max seconds for the local container gate. |

> [!IMPORTANT]
> Every gate — including `local` — still pushes a branch and opens a PR, so the loop needs a GitHub `origin` remote. "Local gate" means "don't wait on Actions", not "no remote".

### Planning & caps

| Var | Default | What it does |
|-----|---------|--------------|
| `PLAN` | `1` | When the roadmap empties, plan the next OBJECTIVE into tasks. `0` stops instead. |
| `MAX_FIX` | `5` | CI auto-fix attempts per red before stopping. |
| `MAX_FEATURES` | `3` | Features to ship this run. `0` = unlimited. |
| `RESOLVE_CONFLICTS` | `1` | Auto-resolve a conflicting PR (preserving both intents) vs stop. |
| `MAX_CONFLICT` | `2` | Max conflict-resolution attempts per branch before stopping. |
| `SELF_IMPROVE` | `0` | `1` keeps improving toward `IMPROVE_GOAL` once all objectives are done; else the loop stops. |
| `IMPROVE_GOAL` | `generate income · solve real user problems · professional, reliable UX` | What self-improvement optimizes toward. |
| `HARVEST` | `1` | After each green merge, curate build WARNINGS the gate let through into `ROADMAP.md`. |
| `HARVEST_MAX` | `15` | Cap on candidate warning lines fed to the curator. |
| `CI_SCOPE` | `affected` | Fast-gate test scope: `affected` (`turbo --filter`) or `all`. The `--container` gate is always full. |
| `JANITOR_EVERY` | `3` | Run the per-lap consistency/disk janitor every Nth lap (`1` = every lap). |
| `VERSION_CACHE_TTL` | `604800` | LTS/EOL version-cache TTL in seconds (7 days). |
| `EXPECT_REPO` | *(empty)* | Preflight hard-guard: refuse to run if `origin` isn't `owner/name`. |
| `FIX_ACE` | `0` | `1` triages ACE first when rathole notes exist (read-only — files a GitHub issue for you to fix). |

### Architecture atlas

The human-facing project map — `docs/atlas.md` (system map · data flow · feature map) plus an inline system-map block in the project `README.md`. Refreshed on cadence by the loop and on demand with `ace atlas`. Generated deterministically from project structure; never regenerated in a swarm worker (avoids churning parallel PRs).

| Var | Default | What it does |
|-----|---------|--------------|
| `MAP_EVERY` | `3` | Refresh the atlas every N merged features in the loop (never per-commit, never in a swarm worker). |
| `ATLAS` | `1` | `0` disables atlas generation entirely (the generator exits immediately). |
| `ATLAS_NARRATIVE` | `0` | `1` adds a grounded feature-map narrative (read-only cartographer pass on `ATLAS_AGENT`). Off = deterministic skeleton only, zero tokens. |
| `ATLAS_FORCE` | `0` | `1` overrides the swarm-worker skip and the unchanged-signature skip (what `ace atlas` uses). |

### Per-step time budget

The clock counts active work; slow deterministic steps pause it (see `SLOW_STEPS`).

| Var | Default | What it does |
|-----|---------|--------------|
| `OPENCODE_TIMEOUT` | `2700` | Base per-run budget (s). On overrun the step is treated as a big task and retried with a larger budget, not failed. |
| `OPENCODE_TIMEOUT_MAX` | `8100` | Ceiling the escalating big-task budget grows to (s). |
| `OPENCODE_RETRIES` | `2` | Extra big-task attempts before stopping for review. |
| `OPENCODE_WALL_MAX` | `10800` | Hard wall-clock ceiling per attempt (s) — bounds a stuck step even while slow steps pause the budget clock. |
| `SLOW_STEPS` | build-tool list | Subprocess names whose run time is not charged to the task budget: `podman buildah docker pnpm npm yarn pip … cargo go … tsc turbo vite jest vitest pytest playwright cypress`. |
| `WATCH_POLL` | `10` | Seconds between activity samples (budget-accounting granularity). |
| `HEARTBEAT` | `60` | Seconds between live "still running" elapsed/remaining ticks. |

### Rathole supervisor

| Var | Default | What it does |
|-----|---------|--------------|
| `STALL_AFTER` | `900` | Seconds of zero new output (and no build running) before the supervisor judges the step. |
| `RATHOLE_JUDGE` | `deepseek-v4-flash` | Cheap model the driver curls (hard-timed, fail-open) for a stuck-vs-progress verdict. |
| `RATHOLE_RETRIES` | `2` | Max autonomous fix-and-retry attempts on a confirmed rathole before a hard stop. |
| `RATHOLE_MAXCHECKS` | `6` | Circuit-breaker: max supervisor checks per step before it stops re-checking (the wall cap takes over). |
| `ACE_FIXME` | `~/.config/ace/ace-fixme.log` | Queue where persistent ratholes are filed for the `FIX_ACE` inception pass. |

### Usage-limit policy (overseer)

Applies whenever the overseer is Claude Opus/Sonnet or OpenAI GPT — i.e. the default.

| Var | Default | What it does |
|-----|---------|--------------|
| `ON_CLAUDE_LIMIT` | `wait` | On a cap: `wait` polls for reset on your model and never downgrades · `deepseek` falls back to DeepSeek and keeps going · `cancel` stops. |
| `CLAUDE_POLL` | `120` | Poll interval while waiting (s) — resumes within about this long of a reset. |
| `CLAUDE_RESET_WAIT` | `21600` | Keep polling this long (6h — rides through a subscription reset), then stop for review. |
| `DEEPSEEK_OVERSEER` | `deepseek/deepseek-v4-pro` | Model used when the overseer is delegated to DeepSeek. |

### Chat / Hermes

All opt-in; no-op without `hermes` installed.

| Var | Default | What it does |
|-----|---------|--------------|
| `HERMES_NOTIFY` | `0` | `1` sends milestone pings to chat. |
| `HERMES_TO` | `telegram` | Channel. Any works: `telegram:<chat_id>` · `signal:+1…` · `discord:<id>` · `slack:#chan`. |
| `HERMES_SNAP` | `0` | `1` also attaches a CLI status snapshot to each ping. |
| `HERMES_KANBAN` | `0` | `1` mirrors `ROADMAP.md` onto a Hermes kanban board (one-way, visibility only). |

Each swarm worker also honors these loop-wide knobs (`MERGE_GATE`, `AUTOMERGE`, `DEPLOY`, the timeouts).

## Detached service (`ace loop start`)

The systemd user service inherits none of your shell environment — it reads only `.opencode/loop.env`. `ace loop start` writes that file once from the launch-time env.

> [!IMPORTANT]
> Set your knobs on the `ace loop start` command itself, e.g. `HERMES_KANBAN=1 MERGE_APPROVAL=hermes HERMES_TO=signal ace loop start`. To change them later, edit `.opencode/loop.env` and run `ace loop restart`. A foreground `ace autorun` inherits the env directly, so a prefix like `HERMES_KANBAN=1 ace autorun --yes` is enough there.

### Survives OOM / crash

The unit is generated with `Restart=on-abnormal` (+ `RestartSec=20`, `OOMPolicy=continue`):

- A loop killed by the kernel OOM-killer or a crash (terminated by a signal) is auto-restarted and resumes — it re-scans for in-flight work; metrics and state persist.
- `on-abnormal` restarts only on a signal or timeout, not on an exit code, so the loop's own deliberate halts (a clean finish, or an `exit 1` like "REFUSING to resume: WIP fails ci.sh") are respected, not flapped.
- `ace loop stop` never restarts. A genuine crash-loop stops after 6 restarts in 10 minutes (see `ace loop logs`).
- A foreground `ace autorun` has no supervisor — prefer `ace loop start` for unattended runs.

### OOM avoidance

User-session processes sit at `oom_score_adj≈100` (preferred OOM victims) and can't be given a protective negative score without root. But the memory cgroup controller is delegated to the user manager, so the unit ships `MemoryLow=1G` (`MemoryAccounting=yes`), shielding the loop's core RAM from reclaim so the kernel prefers other victims.

| Lever | Effect |
|-------|--------|
| `LOOP_MEMORY_LOW` | Tune the soft reservation: `2G` for more headroom, `0` to omit. Use `MemoryMin` for a hard reservation. |
| `choom -n 800 -p <pid>` | Make a hog (e.g. Steam) the preferred victim — unprivileged. |
| `sudo choom -n -500 -p <pid>` | Lower the loop's own score — needs root. |
| — | Don't run memory-heavy apps (games/Steam) alongside the loop's container/vitest gate. |

## Swarm

The most-used knobs; the full table with defaults is in [swarm.md](swarm.md#config-knobs).

| Var | Default | What it does |
|-----|---------|--------------|
| `SWARM_MAX` | `2` | Worker count (the `ace autorun` prompt sets this; clamped to `SWARM_CEIL`, default 5). Sticky in `config.env`. |
| `SWARM_LIVE` | *(off)* | `1` spends credits on the real loop (set for you by `ace swarm start` / `autorun`; the real loop refuses without it). |
| `DRY_RUN` | `1` | `1` = simulated edits, zero credits (the sandbox). `0` = real. |
| `SWARM_SYNC` | `1` | Run the OBJECTIVES → ROADMAP planning sync at start. `0` skips it. |
| `SWARM_ARCHIVE_KEEP` | `5` | Per-run log archives kept under `~/.config/ace/swarm/<slug>/archive/`. |
| `CREDIT_REVIEW` | `1` | `1` credits review/reconcile/merge time off each worker's budget (like builds — doesn't count against it). `0` charges it. |
| `ACE_NO_DASH` | `0` | `1` doesn't auto-open the cockpit after `ace swarm start`. |

## Go release (`ace release`)

| Var | Default | What it does |
|-----|---------|--------------|
| `HARDENING` | profile `hardening` (else `standard`) | Binary hardening level: `none` · `standard` · `strong`. |
| `TARGETS` | profile `targets` | Space-separated `os/arch` list, e.g. `linux/amd64 linux/arm64`. |
| `UPX` | `0` | `1` packs binaries with UPX after building (optional). |
| `GOIMAGE` | `golang:<detected>` | Container image for the default (container) build. |

`ace release --host` builds on the host instead of in a container.

## VPS & post-deploy health check

Configure with `ace vps` (prompts persist to `~/.config/ace/vps.env`), or set the vars raw. The health check runs after every `ace deploy`.

| Var | Default | What it does |
|-----|---------|--------------|
| `VPS_HEALTH_URL` | `http://127.0.0.1:3000/` | Endpoint probed on the VPS. Go workflows default to `/healthz`; a Python service publishes on `:8000` — point the URL there. |
| `VPS_HEALTH_TIMEOUT` | `90` | Seconds to become healthy. |
| `VPS_HEALTH_INTERVAL` | `3` | Seconds between probes. |
| `VPS_DEPLOY_DIR` | `$HOME/apps` | Parent dir on the VPS; each app deploys to `<VPS_DEPLOY_DIR>/<repo>`. |
| `VPS_SERVICE_UNIT` | *(blank)* | Blank = a podman container named after the repo (ACE's default deploy), which `ace verify` / `ace vps check` inspect. Set a unit name only if you run the app as a systemd service. |
| `VPS_DOMAIN` | *(blank)* | Public domain; enables the DNS + TLS-SAN checks in `ace vps check`. |

## Headless operation (driving ACE from chat)

ACE is fully non-interactive, so the Hermes agent can run any flow from Signal/Telegram step by step.

| Var | Default | What it does |
|-----|---------|--------------|
| `ACE_YES` (`--yes`) | `0` | Assume-yes: `confirm` returns its coded default, `ask`/`ask_path` return the default, `menu` needs `MENU_PICK`. Nothing blocks on a TTY. |
| `ACE_CONFIRM` (`--confirm`) | `0` | Unlocks the gated destructive commands (`deploy`, `uninstall`, `vps harden`), which otherwise refuse when headless. |
| `MENU_PICK` | *(empty)* | The menu selection to use when headless. |
| `ACE_PROJECTS_DIR` | `~/projects` | Default parent directory for `ace scaffold` (created on first use). Set it to wherever you keep code, e.g. `~/code`. |

> [!IMPORTANT]
> Secrets are never prompted, even under `--yes`. Pass them via env: `DEEPSEEK_API_KEY`, `CONTEXT7_API_KEY`.

At the `ace scaffold` path prompt, `ACE_PROJECTS_DIR` is the base: a relative entry, or an unwritable absolute path, resolves under it; a real home path or an existing writable dir is used as typed.

### Scaffold flags

Every infra choice is explicit — nothing is assumed. The default stop is scaffold + git init; publish, index, and VPS are opt-ins.

| Flag | Effect |
|------|--------|
| `--name` `--path` `--stack` `--shape` `--audience` `--throughput` `--domain` `--mission` | Project identity + profile fields (skip the wizard prompts). |
| `--no-git` | No git — implies no CI, VPS, or publish. |
| `--no-ci` | No CI workflows. |
| `--no-gitflow` | No git hooks. |
| `--no-container` | Host-only gate, no `Containerfile`. |
| `--no-vps` / `--deploy none` | No VPS deploy. |
| `--index` | Index the repo (GitNexus). |
| `--publish` | Create and push a GitHub `origin` remote. |

The profile field `container: true|false` gates the `Containerfile` + the `./ci.sh --container` parity gate.

### Snapshots

`ace snap [--to <target>] [--out <png>] [command…]` renders the real (themed) CLI to a PNG and sends it with `hermes send … "MEDIA:<png>"`. The renderer is `freeze` (native PNG) or `ansitoimg` (SVG → PNG via ImageMagick). `ACE_FORCE_COLOR=1` forces colour off-TTY (used internally by snap).

### Notifications

The channel-agnostic Hermes toggles (`HERMES_NOTIFY`, `HERMES_TO`, `HERMES_SNAP`, `HERMES_KANBAN`) are in [Chat / Hermes](#chat--hermes) above. Renderers install via `ace install`; `ACE_RENDER_TOOLS=0` skips that offer.

## Appearance (`ace settings → Appearance`)

Visual only — copy stays plain and technical. Stored in `~/.config/ace/config`; env vars override per run. Status colours are fixed regardless of theme: green ok · yellow warn · red fail. Everything degrades to clean plain text under `NO_COLOR` or when stdout isn't a TTY (safe for pipes and CI).

| Config key | Env var | Default | What it does |
|-----------|---------|---------|--------------|
| `THEME` | `ACE_THEME` | `warp` | `warp` (violet) · `blood` (crimson) · `void` (indigo-cyan, dark sci-fi). |
| `NO_ANIM` | `ACE_NO_ANIM` | *(off)* | `1` disables the one-time intro reveal. |
| `ART` | `ACE_ART` | `auto` | `auto` renders the `lib/art/ace-emblem.png` sprite at best fidelity (kitty → sixel → blocks) when `chafa` is installed, else a truecolor half-block emblem. `off` forces the half-block emblem. |
| — | `ACE_FIGLET` | `auto` | Default is the block wordmark. `on` renders the `ACE` wordmark with `figlet`/`toilet` if they're installed. |
| — | `ACE_FIGFONT` | `future` / `slant` | Font for `ACE_FIGLET=on` (`future` for toilet, `slant` for figlet). |
| — | `ACE_VISUAL_EXTRAS` | `1` | `0` skips the `ace install` offer to add the optional enhancers. |
| — | `ACE_FORCE_COLOR` | `0` | `1` forces colour when stdout isn't a TTY (used by `ace snap`). |

> [!NOTE]
> Optional enhancers are auto-detected if present: `chafa` (pixel art), `figlet`/`toilet` (wordmark). `ace install` offers to install them (confirm-gated, default no; skipped on immutable hosts — layer with `rpm-ostree install` or a toolbox). ACE uses them only when present.

## Where config lives

Global — machine-wide, loaded by opencode at launch:

| Path | Holds |
|------|-------|
| `~/.config/opencode/opencode.json` | 10 agents · DeepSeek workers · MCP · compaction (~80%). |
| `~/.config/opencode/AGENTS.md` | Grounding · navigation · Definition-of-Done · git · handover. |
| `~/.config/ace/secrets.env` | `DEEPSEEK_API_KEY` / `CONTEXT7_API_KEY` (chmod 600). |
| `~/.config/ace/vps.env` | Host · user · key · port · dir · os. |
| `~/.config/ace/config` | Model profile · per-agent models · appearance (`THEME`/`ART`/`NO_ANIM`). |
| `~/.config/ace/logs/` | Run logs. |
| `~/.bashrc` | Managed PATH block + sources secrets. |

Per-project — scaffold writes, upgrade backfills:

| Path | Holds |
|------|-------|
| `OBJECTIVES.md` · `ROADMAP.md` | North star + task board. |
| `.opencode/profile.yaml` · `ARCHITECTURE.md` | Project profile (Go) — see [profile.md](profile.md). |
| `opencode.json` | Project MCP (Go: gopls), merged with the global config. |
| `ci.sh` · `Containerfile` | Tiered gate + pinned VPS-parity image. |
| `.githooks/` · `.opencode/` · `docs/architecture.md` | Hooks · memory · specs · map snapshot. |
| `.opencode/metrics.csv` · `.opencode/run-summary.txt` | Per-run timing (see [autorun.md](autorun.md)) · `ace loop stats`. |
| `.github/workflows/` | build-test · security · codemap · deploy (gated) · release (Go). |
| `scripts/{auto-loop,graph-refresh,env-merge,deploy,release}.sh` | Generated loop + helper scripts. |

## Code intelligence (GitNexus / Serena)

The agents navigate code through two MCP servers configured in the global `opencode.json`.

- **GitNexus** (structure / impact / flows) is installed globally by `ace install` (`npm i -g gitnexus`) and launched as `gitnexus mcp`. It is *not* run as `npx gitnexus@latest`, which re-resolves the dist-tag on every spawn (slow + npm-11-flaky, #1939) and can lose the race with the orchestrator's first call, yielding "MCP server not connected". The MCP command falls back to `npx` if the global binary is missing.
- **Serena** (live symbols / references) runs via `uvx` against the current project (`--project .`).

> [!IMPORTANT]
> GitNexus keeps one shared local index (`~/.gitnexus/registry.json`) across all your repos. Once you've scaffolded more than one, every `gitnexus_*` call must pass `repo: "<this repo's name>"` or it errors `Multiple repositories indexed`.

ACE bakes that rule into each project's `.opencode/project-facts.md` (repo name filled in), `docs/architecture.md`, and the global `AGENTS.md`, so the agents get it first try. Prune stale indexes with `gitnexus remove <name>` — dropping to a single indexed repo removes the need for the param entirely. Loops bootstrapped before this rule shipped are self-healed: each `ace autorun` appends the `repo:` fact to an older `project-facts.md` that lacks it.

## Context handover

opencode auto-compacts at `compaction.maxContext`, set per overseer model (~80% of its context window). Agents keep `.opencode/HANDOVER.md` current so a handover or crash loses nothing.

| Overseer | `maxContext` |
|----------|-------------|
| Claude Opus (default) | `820000` |
| Claude Sonnet | `900000` |
| DeepSeek | `840000` |
| OpenAI GPT-5 | `360000` |

Seeing drift? Lower `maxContext` toward `600000` — an earlier handover is safer.

## See also

- [autorun.md](autorun.md) — the loop these env vars drive
- [swarm.md](swarm.md#config-knobs) — the full swarm config knobs
- [deploy.md](deploy.md) — `DEPLOY_GATE` and the release-gated deploy model
- [profile.md](profile.md) — the `.opencode/profile.yaml` fields several defaults come from
