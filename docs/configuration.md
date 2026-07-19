# Configuration

The knobs ACE reads: model and provider selection, the autorun loop's environment variables, the gates, appearance, and where settings are stored on disk. Anything not listed here is either internal or not read at all — if a variable name appears in a doc but not in this file, treat it as unsupported.

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

Both dials are stored as plain keys in `~/.config/ace/config` and can be set directly (or per-run as an env prefix) instead of going through the menu:

| Var | Default | What it does |
|-----|---------|--------------|
| `MODEL_PROFILE` | `max` | The profile above (`max` · `high` · `balanced`). Read when the agent config is written — change it, then re-run `ace opencode` to apply. |
| `ORCH_PROVIDER` | `opus` | The overseer brain alias above (`opus` · `sonnet` · `gpt` · `deepseek`), resolved to a model id. A `MODEL_orchestrator` override wins over it; with neither set the overseer is `anthropic/claude-opus-4-8`. |

### Providers & per-agent models (`ace settings`)

`ace settings → Models & agents` sets which model each of the 12 agents runs, independently or via a preset (`overseer-Claude` · `overseer-OpenAI` · `all-DeepSeek` · `mixed` · `cross-review`). Each choice is stored as `MODEL_<agent>` in `~/.config/ace/config`. An unset overseer defaults to Claude Opus; the 11 subagents default to DeepSeek — **the coders (implementer · test_engineer) run `deepseek-v4-pro`; `-flash` is used only for cheap/mechanical roles** (the rathole judge, opencode's `small_model`, and — under the `balanced`/`mixed` presets — the light checks verifier/standards/alignment). To put a coder on flash: `MODEL_implementer=deepseek/deepseek-v4-flash` (cheaper, weaker — measure with Experiment C before adopting).

**Any agent can run on any wired provider** — `MODEL_<agent>=<provider>/<model>` (e.g. `MODEL_reviewer=openrouter/anthropic/claude-opus-4.1`). The **cross-review** preset uses this to put the review panel (reviewer · ux_reviewer · standards_keeper · alignment_reviewer) on a **different provider than the implementer**, so review isn't same-model self-agreement — the same cross-model principle the debate engine uses (needs `OPENROUTER_API_KEY`). Re-run `ace opencode` after changing any `MODEL_<agent>`.

`ace settings → Providers & keys`:

| Provider | Default auth | Detail |
|----------|--------------|--------|
| DeepSeek | API key | `DEEPSEEK_API_KEY`. |
| Anthropic | Claude Pro/Max **subscription** | ACE installs the anthropic-auth plugin and runs `opencode auth login -p anthropic` (paste the token), so `anthropic/*` models bill your plan. |
| OpenAI | ChatGPT **subscription** | Or set `AUTH_openai=api` to use `OPENAI_API_KEY` instead. |
| OpenRouter | API key | `OPENROUTER_API_KEY`. Wires an OpenAI-compatible `openrouter` provider so any agent (or the debate challenger) can use `openrouter/<vendor/model>`. The provider block is emitted only when some model resolves to `openrouter/*`. |

> [!NOTE]
> Subscription is the default for Anthropic and OpenAI; an API key is used only if you set one explicitly. On apply, ACE writes `~/.config/opencode/package.json` and runs `bun install` for the needed plugins.

## Autorun environment variables

`ace autorun` prompts for the common ones, or set them raw: `AUTOMERGE=1 MAX_FEATURES=5 ace autorun`. A detached `ace loop start` reads them only from `.opencode/loop.env` — see [Detached service](#detached-service-ace-loop-start).

### Delivery & merge

| Var | Default | What it does |
|-----|---------|--------------|
| `AUTOMERGE` | profile `auto_merge` | `1` self-merges a PR once the gate is green and mergeable. `0` opens ONE PR and stops for review (does not keep building on the branch). |
| `MERGE_GATE` | profile `merge_gate` | What authorizes a merge: `remote` (wait for Actions green) · `local` (merge on `./ci.sh --container` green) · `both` (require both). |
| `MERGE_APPROVAL` | *(empty)* | `hermes` pauses before every merge and waits for a chat `ace approve <tok> yes`. **Deny-by-default** — see the note below. An explicit deny, a timeout, or an undeliverable request (no `hermes` binary, or a failed `hermes send`) leaves the PR open and stops the loop. Empty = self-merge per `AUTOMERGE`. |
| `APPROVAL_TIMEOUT` / `APPROVAL_POLL` | `3600` / `15` | How long the loop waits for a decision, and how often it re-checks `.opencode/approvals/`. Timeout is treated as a denial. |
| `DEPLOY` | `0` | `1` runs `ace deploy` after each merge. Needs `deploy_kind=service` + a configured VPS, else a no-op with a warning. |
| `DEPLOY_GATE` | `always` | `release` ships only when `origin/main` carries a new `v*` tag (milestone-gated); the last shipped tag is tracked as `DEPLOY_LAST_TAG` in `~/.config/ace/config`. Mark one with `ace release --tag vX.Y.Z`. |
| `DEPLOY_FORCE` | `0` | `1` (or `ace deploy --force`) bypasses `DEPLOY_GATE` for one on-demand deploy. |
| `LAUNCH_GATE` | `1` | Runs the project's `./ci.sh --launch` tier before promoting to the VPS (tested-restore evidence, rollback runbook, SLO/runbook presence). **Fail-closed** — a NO-GO blocks the deploy. If the project has no `--launch` tier the gate is skipped with a warning. `0` disables it. |
| `STOP_ON_DEPLOY_FAIL` | `1` | A failed in-loop deploy or health check halts the loop. `0` logs and continues. |
| `VERIFY` | `0` | `1` runs the `ace verify` agent after each deploy and triages live findings into `ROADMAP.md` (advisory — never halts). |
| `LOCAL_CI_FALLBACK` | `0` | `1` accepts a green local `./ci.sh --container` as the pass + merge when Actions is BLOCKED (a run that fails having executed 0 jobs). |
| `LOCAL_CI_TIMEOUT` | `1800` | Max seconds for the local container gate. |

> [!IMPORTANT]
> Every gate — including `local` — still pushes a branch and opens a PR, so the loop needs a GitHub `origin` remote. "Local gate" means "don't wait on Actions", not "no remote".

> [!NOTE]
> **`MERGE_APPROVAL=hermes` is deny-by-default on both sides.** The *recording* side (`ace approve`) merges only on an explicit approval word — `yes` `y` `approve` `approved` `ok` `1` `✅`, case-insensitive. Every other decision string, including an unrecognised or free-text reply, is recorded as a **deny** and warns that it was not understood so you can re-answer while the request is still pending; a *missing* decision (`ace approve <tok>`, or bare `ace approve`) is an error that records nothing. The *loop* side approves only on the literal `yes` it wrote, so a truncated decision file also denies, and it treats an explicit deny, a timeout, and an undeliverable request as stop conditions.
>
> `APPROVAL_TIMEOUT` bounds only a request that *was* delivered. The loop tests the `hermes send` and, if delivery fails, removes the request and returns "no usable chat channel" at once — it never spends an hour waiting for an answer to a message nobody received.

### Generated-project gates

These are read by the `ci.sh` and git hooks ACE **generates into your project**, not by the `ace` CLI itself — set them in the environment of the run (or the hook) you want to affect.

| Var | Default | What it does |
|-----|---------|--------------|
| `ACE_STRICT_SECURITY` | *(auto)* | Promotes `ci.sh`'s security `[major]` warnings to hard `[blocker]`s. Auto-**on** when the profile's `audience` is `oss-public`/`end-customer`/`enterprise` **and** `auto_merge` is on — an unattended public self-merge has no human to catch a security gap. `1` forces it on, `0` forces it off for a run (the escape hatch when a heuristic grep false-positives). |
| `PREPUSH_TIMEOUT` | `100` | Seconds the `pre-push` hook gives `./ci.sh --container` before **deferring** to CI (which runs the same gate on the PR) and allowing the push. A RED result still blocks regardless. `0` = no budget, run to completion. |

### Planning & caps

| Var | Default | What it does |
|-----|---------|--------------|
| `PLAN` | `1` | When the roadmap empties, plan the next OBJECTIVE into tasks. `0` stops instead. |
| `REANALYZE` | `0` | `1` = **re-assessment mode**: snapshot the current OPEN (uncompleted) ROADMAP items + specs, then re-derive their breakdown from scratch with the full planning pipeline — research → re-spec → spec-lint gate → cross-model debate (when `SPEC_DEBATE=1`) → bounded re-spec → re-slice — NOT skipping "already covered" (the point is to redo them better). **Implies plan-only** (nothing is implemented) and forces the solo path. Inspect `ace reanalyze report` and, if the new breakdown is better, run a normal loop to build it. The `ace reanalyze` command is the wrapper (defaults `SPEC_DEBATE=1`); the raw flag leaves `SPEC_DEBATE` to you. |
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

The human-facing project map — `docs/atlas.md` (system map · data flow · module map) plus an inline system-map block in the project `README.md`. Refreshed on cadence by the loop and on demand with `ace atlas`. Generated deterministically from the real workspace dependency graph (package.json); never regenerated in a swarm worker (avoids churning parallel PRs). **Full walkthrough — the three views, how it's built, and when it refreshes: [architecture-atlas.md](architecture-atlas.md).**

| Var | Default | What it does |
|-----|---------|--------------|
| `MAP_EVERY` | `3` | Refresh the atlas every N merged features in the loop (never per-commit, never in a swarm worker). |
| `ATLAS` | `1` | `0` disables atlas generation entirely (the generator exits immediately). |
| `ATLAS_NARRATIVE` | `0` | ⚠️ **Currently unsupported — a no-op.** It asks for a `cartographer` agent that is not in the shipped crew, so the pass fails silently and you get the deterministic skeleton either way. Leave it at `0` unless you have defined your own agent and pointed `ATLAS_AGENT` at it. |
| `ATLAS_FORCE` | `0` | `1` overrides the swarm-worker skip and the unchanged-signature skip (what `ace atlas` uses). |

### Per-step time budget

The clock counts active work; slow deterministic steps pause it (see `SLOW_STEPS`).

| Var | Default | What it does |
|-----|---------|--------------|
| `OPENCODE_TIMEOUT` | `7200` | Base per-step budget (s) = **2 h**. A real feature can take this long — big tasks aren't feared. **Progress resets the clock** (a new commit → the budget restarts), so a task that keeps committing runs up to `OPENCODE_WALL_MAX`; only a stuck step overruns → one bounded *slice* retry. A frozen step is caught far sooner by `HANG_AFTER`. |
| `BIGTASK_SLICE_RETRIES` | `1` | After a step overruns, how many single-slice retries (each at the base budget, **not** escalating) before it stops and the item parks/requeues. Replaced the old escalating `OPENCODE_RETRIES` / `OPENCODE_TIMEOUT_MAX`. |
| `HANG_WARN` | `300` | Seconds of zero opencode output (stdout + tool log, nothing building) before an early one-shot warning, ahead of the hang-restart at `HANG_AFTER` (≈480s). |
| `OPENCODE_WALL_MAX` | `16200` | Hard wall-clock ceiling per attempt (s) = 4.5 h — bounds a stuck step even while slow steps pause the budget clock. Accommodates a 2 h base + a slice retry. |
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
| `SWARM_MAX` | `2` | Worker count (the `ace autorun` prompt sets this; clamped to `SWARM_CEIL`, default 5). Sticky in `~/.config/ace/config`. |
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
| — | `ACE_FIGLET` | `auto` | Default is the block wordmark. `on` renders the `ACE` wordmark with `figlet`/`toilet` if they're installed. |
| — | `ACE_FIGFONT` | `future` / `slant` | Font for `ACE_FIGLET=on` (`future` for toilet, `slant` for figlet). |
| — | `ACE_VISUAL_EXTRAS` | `1` | `0` skips the `ace install` offer to add the optional enhancers. |
| — | `ACE_FORCE_COLOR` | `0` | `1` forces colour when stdout isn't a TTY (used by `ace snap`). |
| — | `ACE_ALT_SCREEN` | `1` | The menu (`ace`) opens the terminal's alternate-screen buffer so each screen replaces the previous one and the shell scroll-back is restored clean on exit. `0` keeps the old behaviour (screens scroll into history) — set it when recording a menu walkthrough that should stay in the capture. |

> [!NOTE]

### Demo tour (`ace demo`)

`ace demo` is a paced, **zero-credit** feature walkthrough built for recording (see [demo/RECORDING.md](demo/RECORDING.md)). Nothing is built, pushed, deployed, or spent — every step is `--dry-run` / `--explain` / `--demo` / the DRY swarm sandbox / read-only status, or a throwaway repo it creates and deletes.

| Env var | Default | What it does |
|---------|---------|--------------|
| `DEMO_AUTO` | `0` | `1` auto-advances between steps (hands-free) — record this. `0` waits for ↵ (`q` quits). |
| `DEMO_SPEED` | `normal` | `slow` / `normal` / `fast` — typing + pause cadence. `slow` suits voice-over. |
| `DEMO_SECTIONS` | *all* | comma list to trim the tour: `intro,status,scaffold,atlas,graph,policy,loop,swarm,stats,deploy,outro`. |

### Research crawler (Firecrawl — optional, local)

The planner researches `[value]` features (how comparable products build them + the industry-standard scope). With no crawler this runs on `webfetch` (single-URL). A **self-hosted Firecrawl** adds search + scrape + extract. **Security by design:** it runs on **your machine, bound to `127.0.0.1` (loopback) only**, with **no cloud key** — your code/prompts/secrets never leave the box; the only outbound is the container fetching the *public* pages an agent asks it to read, and the agents are held to an **SSRF rule** (AGENTS.md) that forbids fetching localhost/internal/cloud-metadata/`file://`.

`ace firecrawl up` starts it (prints the security notice + verifies the loopback binding); `down` stops it; `status` checks it. The MCP **auto-disables** when the instance is unreachable — a down crawler never bricks a run (research falls back to `webfetch`).

| Env var | Default | What it does |
|---------|---------|--------------|
| `FIRECRAWL_API_URL` | `http://127.0.0.1:3002` | the self-hosted endpoint the MCP + reachability gate use; unreachable ⇒ MCP disabled. |
| `FIRECRAWL_PORT` | `3002` | loopback port the local crawler listens on. |
| `FIRECRAWL_DIR` | `~/firecrawl` | where the Firecrawl compose lives (`ace firecrawl up` runs `compose up -d` there). |
| `ACE_RESEARCH_MAX_FETCHES` | `6` | shared search+scrape page budget per feature (keeps research bounded). Resolved **env > config > `6`** and **stamped into the generated prompts at generation time**, so a change only takes effect after `ace opencode` (or `ace install`) regenerates them — it is not read at run time. The researcher's own budget and the global `AGENTS.md` rule are stamped from the same value, so they cannot drift. A non-numeric or zero value falls back to `6`. |

> [!NOTE]
> There is **no** API-key knob. ACE talks to Firecrawl over plain loopback and never sends an auth header, so an instance configured to *require* auth is unreachable to ACE — the MCP auto-disables and research falls back to `webfetch`. Run the self-hosted instance without auth, the way `ace firecrawl up` sets it up.

### Feature-spec pipeline (Part H)

Every `[value]` feature is planned as **one canonical spec** (`.opencode/specs/<slug>.md`, filling `.opencode/spec-template.md`), gated by a deterministic bash lint **before** any LLM call, then sliced per increment at dispatch. **The single-flow loop (`ace autorun`, one worker) and the swarm run the identical gate + slice + rubric** — same knobs, same `swarm.sh` code, so a solo run is never a weaker pipeline than a parallel one. The knobs — all safe defaults, all fail-open:

| Var | Default | What it does |
|-----|---------|--------------|
| `SPEC_LINT` | `1` | Deterministic pre-dispatch spec gate (`swarm_spec_lint`, 11 checks). `0` disables. No-op on legacy ROADMAP items with no `Spec:` field. |
| `SPECFIX_MAX_LINES` | `40` | Cap on how many `SPECGAP` lines are handed to a re-spec round (a `head -N` on the lint report), so one very gappy spec can't flood the re-spec prompt. **Not** a round count — the number of re-spec rounds is fixed at **2** by the pipeline's structure (one after the deterministic lint, one after the debate/rubric layer) and is not configurable. |
| `SPEC_SLICE` | `1` | Assemble a focused, capped context slice per increment (`.opencode/cache/spec-slice.<slug>.md` — §3 Scope + only that increment's ACs + non-N/A contracts) the implementer reads first. `0` disables. |
| `SPEC_RUBRIC` | `0` | **Off by default.** An optional one-call LLM rubric that judges a lint-green spec on 7 criteria (only for HIGH-RISK `[value]` features). Enable per project only after calibrating against the goldens. |
| `SPEC_RUBRIC_MODEL` | `deepseek-v4-pro` | Which model the rubric runs on. It does **not** follow your overseer: the rubric is a direct `curl` to `https://api.deepseek.com/chat/completions` and needs `DEEPSEEK_API_KEY`, so this value must be a **DeepSeek** model id (bare, no provider prefix). Pointing it at a Claude/OpenAI slug will not route. |
| `SPEC_RUBRIC_TIMEOUT` | `90` | Wall-clock cap (s) on that single rubric call (`curl --max-time`). On timeout the rubric returns nothing and the pipeline proceeds (fail-open). |
| `SPEC_DEBATE` | `0` | **Off by default.** The heavier alternative to the rubric: a cross-model **debate** on each lint-green HIGH-risk spec (see below). When on, it *subsumes* `SPEC_RUBRIC`. Agreed gaps route into the re-spec channel. Resolves **env > config > `0`** — see below. |
| `REVIEW_DEBATE` | `0` | **Off by default.** A cross-model debate over the branch diff *before* a PR self-merges; agreed [blocker]/[major] findings hold the merge for a fix. Fail-open. Resolves **env > config > `0`** — see below. |
| `DEBATE_MODEL_A` | *(overseer)* | The **defender** (owns the artifact) — defaults to your overseer model (Claude via subscription, no API key). |
| `DEBATE_MODEL_B` | *(unset)* | The **challenger** — a **provider-prefixed** model slug. The prefix picks the route: `openrouter/vendor/model` (e.g. `openrouter/openai/gpt-5.5`, needs `OPENROUTER_API_KEY`) · `openai/model` (needs OpenAI auth) · `anthropic/model` (needs the Claude subscription login). **Required to enable** any debate; unset ⇒ silent no-op. A bare `gpt-5.5` (no prefix) won't route. |
| `DEBATE_MIN` / `DEBATE_MAX` / `DEBATE_HARD_MAX` | `2` / `4` / `10` | Debate rounds: at least MIN before it may converge, MAX by default, extend to HARD_MAX only while a side flags `NEEDS-MORE`. |
| `DEBATE_TIMEOUT` | `600` | Per-turn wall-clock cap (s). |
| `DEBATE_WALL_MAX` | `1800` | Total debate wall-clock backstop (s). A non-converging pair can't stall the synchronous planning gate past this — it stops and synthesizes what it has. |
| `DEBATE_ONLY` | *(unset)* | **Trial scoping for SPEC debates only.** A comma-list of **spec slugs** to limit the spec debate to (e.g. `checkout,authz,webhook`) — the simple, editable way to try it on a few features. Unset ⇒ every eligible spec. Scopes *nothing else*: it has no effect on the `REVIEW_DEBATE` pre-merge gate. Set in `~/.config/ace/config`. |
| `REVIEW_DEBATE_ONLY` | *(unset)* | **Trial scoping for REVIEW debates.** The separate comma-list for the pre-merge gate, matched against the **branch name** with `/` folded to `-` (a `feat/checkout` branch is the slug `feat-checkout`). Unset ⇒ every eligible branch. Kept distinct from `DEBATE_ONLY` on purpose: a single shared list was compared against spec slugs in one mode and branch names in the other, so setting spec slugs silently disabled the whole review gate — fail-open, with nothing in the log saying so. |
| `DEBATE_F1_MIN` | `750` | Effectiveness go/no-go (per-mille; 0.750). `ace debate score` prints GO iff F1 ≥ this on the labeled sandbox. |

### Cross-model debate

`SPEC_DEBATE` / `REVIEW_DEBATE` run a **grounded adversarial dialogue between two *different* LLMs** over an artifact (a spec, or a diff). The **defender** (`DEBATE_MODEL_A`, your overseer — Claude, who planned it) and the **challenger** (`DEBATE_MODEL_B`, an OpenRouter model) exchange citations, concede correct points, and refute weak ones, converging on the issues **both accept**. A point becomes a fix **only when the defender concedes it** — so a strong argument promotes it and a hallucinated one is refuted by the other model. Both run **read-only** (the `debater` agent) so they can fact-check each other against the actual repo — the anti-hallucination lever. The full transcript is saved to `.opencode/cache/{spec,review}-debate-<slug>.md` so you can read the argument, and one structured **metrics** record per debate (rounds · per-round accepted/disputed/converged/timing · duration · issues · wall-capped) is appended to `.opencode/cache/debate-metrics.jsonl` — analyze it with **`ace debate report`**. To trial it on just a few features, set `DEBATE_ONLY=slug1,slug2,…`. **Cost:** opt-in, HIGH-risk-only, hard round + per-turn + total-wall (`DEBATE_WALL_MAX`) caps. **Enable only after** `tests/spec-debate-goldens.sh --calibrate` prints **GO** on your labeled set. Standalone: `ace debate spec <file>` / `ace debate review [base]`.

All of these are settable in the UI — **`ace settings` → Cross-model debate**: the spec/review toggles, the defender/challenger models (with greyed per-provider format examples — `openrouter/vendor/model` · `openai/model` · `anthropic/model`), and the round/timeout/wall caps. No hand-editing `~/.config/ace/config` required.

**Precedence — `SPEC_DEBATE` / `REVIEW_DEBATE`.** Most specific wins:

```
environment variable   >   ~/.config/ace/config   >   the built-in default (0)
```

The `ace` entrypoint exports the stored config value once, before any flow is dispatched, so both the solo loop and the swarm coordinator (a child process) inherit it. An environment variable that is already set is left untouched — and when one is, the settings screen labels that toggle `[env … overrides this session]`, so the menu never claims to control a value the environment owns. An absent or empty config key exports nothing and the consumer's own default of `0` applies. The stored value is never coerced: the config holds `0`/`1`, and anything else reaches the consumers verbatim, where the `= 1` tests treat it as off.

This precedence is what makes the menu toggle real. Previously the screen persisted the toggle to config while every consumer read the environment only, so it could show **ON** while every run silently skipped the debate. If you toggled it on before this shipped, the next run genuinely will debate — and will spend credits accordingly.

> [!IMPORTANT]
> **Privacy:** the debate sends the spec (or the full branch **diff**) to your `DEBATE_MODEL_B` provider (OpenRouter). For a repo with sensitive code, that's your code leaving to a third party — the debaters are read-only (they can't act), but the artifact text itself is transmitted. Choose `DEBATE_MODEL_B` accordingly, and don't enable `REVIEW_DEBATE` on a repo whose diffs you can't share externally.

**Token economics — prompt-cache prefix discipline.** Prompt caching is *provider-side* (Anthropic / DeepSeek), keyed on a **stable prefix**. ACE can't turn it on — it only avoids breaking it. The worker prompt is assembled **stable-first, volatile-last**: system prompt (AGENTS.md-governed) → profile facts → the **frozen spec slice** → item text → run-specific state (attempt counters, bus notes). A byte-identical prefix across a feature's dispatches (the spec is frozen after the gate passes, so the slice is byte-identical — see the H7 determinism selftest) is what makes retries and multi-increment features cheap; a mutating prefix (a timestamp or attempt number above the slice) silently re-bills the whole context every call. This is why a gate-passed spec is **never** edited mid-implementation — scope changes go through a re-spec (re-gated) or a new increment.

## Where config lives

Global — machine-wide, loaded by opencode at launch:

| Path | Holds |
|------|-------|
| `~/.config/opencode/opencode.json` | 12 agents · DeepSeek workers · MCP · compaction (~80%). |
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

## Lessons stores

Durable gotchas the crew reads *before* planning and appends to *after* each task. Three scopes:

| Path | Scope | Notes |
|------|-------|-------|
| `.opencode/lessons.md` | one project | The loop appends one terse, deduped line per task (plus a line naming the critic if one gated the change). `compact_lessons` caps it at `LESSONS_MAX_LINES` and archives the overflow. In a swarm each worker appends only to its own `.opencode/lessons/<branch>.md` shard; the coordinator aggregates them into this canonical file on main (it is `merge=union`, so no entry is ever lost). |
| `~/.config/ace/host-lessons/<os>.md` | one machine, all projects | Host-level traps, so one solved in one repo is avoided in the next. **Author it by hand: no ACE code path writes this file.** Its only reference in the tree is a read in `ace brain` (`lib/scaffold.sh:2686-2687`). The rathole supervisor writes the rathole *queue* (`~/.config/ace/ace-fixme.log`, `lib/autoloop.sh:52`), not this. |
| `${ACE_CONFIG_DIR}/lessons.md` | one machine, all projects | The **shared lessons store** — cross-project lessons that aren't host/OS-specific. `ACE_CONFIG_DIR` resolves to `${XDG_CONFIG_HOME:-$HOME/.config}/ace` (`lib/core.sh:4`), so this is normally `~/.config/ace/lessons.md`. Both stores are read as **one merged view** by `lessons_view` (`lib/core.sh:265`, mirrored for the loop at `lib/autoloop.sh:536`); if the shared file exists but is unreadable the view says so explicitly rather than rendering as absent — an unknown global rule must not read as no global rule. |

| Variable | Default | Meaning |
|----------|---------|---------|
| `LESSONS_MAX_LINES` | `200` | Cap on `.opencode/lessons.md` before `compact_lessons` archives the overflow — the file is fed into agent prompts, so it is a standing token cost. |
| `ACE_LESSONS_SHARED` | `$ACE_CONFIG_DIR/lessons.md` | Path to the shared store (`lib/core.sh:186`). |
| `ACE_LESSONS_SHARED_MAX` | `60` | Its own cap, deliberately far below `LESSONS_MAX_LINES` — this file is read by *every* project on the host, so its bloat is paid N times (`lib/core.sh:191`). Also caps the rendered view, which states how many lines it hid rather than quietly showing a subset. |
| `ACE_LESSONS_SHARED_ARCHIVE` | `$ACE_CONFIG_DIR/lessons-archive.md` | Where shared-store overflow is archived (`lib/core.sh:187`). |

**Promotion into the shared store is manual, and stays manual.** The loop only ever *queues* candidates (`lessons_promote_candidates`, `lib/autoloop.sh:569` → `.opencode/lesson-promotions.md`); a human ticks `- [ ]` → `- [x]`, and only ticked lines are promoted. Nothing in ACE ticks that box. The reason is C2 (asymmetry of harm): lessons are **data, never instructions**, and a poisoned lesson that auto-promoted would become a standing rule injected into every prompt in every project on the host, whereas a wrong refusal costs one command.

`ace brain` files the host-lessons + the repo's `.opencode/lessons.md` into gbrain (when present) — the one built-in way lessons cross project boundaries into chat.

> [!NOTE]
> **Verification status.** All three stores are verified in the code. The shared store — which this page previously documented *from spec*, while it was still being built — has since **shipped** (`lib/core.sh:186-330`), so that caveat is gone.
>
> **One gap remains, and it is a gap rather than a design choice:** there is **no `ace` subcommand** for promotion. `lessons_promote_shared` (`lib/core.sh:303`) is a shell function with no CLI dispatch entry — the only lessons-related subcommand in `ace` is `ace brain`. To promote a ticked candidate today you must source `lib/core.sh` and call the function by hand. The *manual approval* is deliberate (above); the missing entry point is not.

The lessons worth reading before you change ACE *itself* are in [engineering-lessons.md](engineering-lessons.md).

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
- [engineering-lessons.md](engineering-lessons.md) — the audit lessons behind several of these defaults (fail-open, deny-by-default, narrate-long-operations)
