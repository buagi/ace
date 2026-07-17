# The swarm — parallel loops

The swarm runs ACE's autonomous loop as N feature-streams at once. Each worker takes one ROADMAP item, works it in its own git worktree, and self-merges to `main`, coordinated so two workers never edit the same files. It is the same loop as [autorun](autorun.md), fanned out.

At a glance:

| | |
|---|---|
| **Run it** | `ace autorun` (pick 2+) · `ace swarm start` · `ace swarm sandbox` (free) |
| **Watch it** | `ace swarm dash` |
| **Stop it** | `ace swarm drain` (finish then stop) · `ace swarm stop` (now, WIP preserved) |
| **Bounded by** | path-disjointness (items sharing a file can't run in parallel) and your model quota (N workers burn it ~N× faster) |

> [!TIP]
> Reach for the swarm when you have more ROADMAP items than you want to wait through serially. On a tight quota, run parallelism `2` rather than the ceiling — N agents reach your usage cap ~N× faster than a single loop.

## Topology

```mermaid
flowchart LR
  R["ROADMAP.md<br/>(path-disjoint)"] -->|leases| C{coordinator}
  C -->|lease A| W1["worker 1 · worktree"]
  C -->|lease B| W2["worker 2 · worktree"]
  C -->|lease C| W3["worker 3 · worktree"]
  W1 --> L1["item A → 12-agent loop → gate → self-merge"]
  W2 --> L2["item B → 12-agent loop → gate → self-merge"]
  W3 --> L3["item C → 12-agent loop → gate → self-merge"]
  L1 --> M["main"]
  L2 --> M
  L3 --> M
  C -.->|ticks ROADMAP · reaps stalls| M
```

| Node | Role |
|---|---|
| `ROADMAP.md` | source of work; items carry `Files:` hints so the coordinator can lease their true scope |
| coordinator | hands out path-disjoint leases, ticks `ROADMAP.md` after each merge, reaps stalled workers |
| worker N | takes one item, runs the full loop in its own git worktree, self-merges its PR |
| `main` | every worker merges here — but workers never deploy |

## How it works

| Property | Detail |
|---|---|
| **Path-disjoint leasing** | the coordinator only hands a worker an item whose files don't overlap another in-flight item, so merges stay clean. See [conflict-policy](conflict-policy.md). |
| **Self-merge on a local gate** | each worker runs the full [12-agent loop](agents.md) and merges its own PR when `./ci.sh --container` is green (`MERGE_GATE=local`) — no waiting on remote CI |
| **Live cockpit** | `ace swarm dash` shows every worker's stage, active agent, and live feed on one screen |

## Run it

### Through `ace autorun` (recommended)

`ace autorun` asks for parallelism up front:

```
Parallel flows — SWARM (1 = single loop · 2-5 = parallel workers, path-disjoint + self-merging) [1]:
```

| Choice | Result |
|---|---|
| `1` | the classic single-flow [autorun loop](autorun.md) |
| `2`+ | a swarm of that many workers |

The choice is **sticky** — it's saved to `SWARM_MAX` in `~/.config/ace/config.env`, so the next run defaults to it. When you pick ≥2, ACE starts the detached coordinator and drops you into the dashboard.

```bash
ace autorun                     # pick parallelism at the prompt
SWARM_MAX=4 ace autorun --yes   # headless: 4 workers, no prompts
```

> [!NOTE]
> The coordinator clamps the worker count to `SWARM_CEIL` (default **5**) and logs any clamp — 3–5 is the evidence-backed maximum; past that, coordination and the serialized merge step dominate without a matching speed-up. Raise `SWARM_CEIL` to override.

### `ace swarm start` (explicit)

```bash
ace swarm start        # detached coordinator (LIVE) + opens the dashboard
ace swarm start fg     # run in the foreground (logs to the terminal, no detach)
```

`start` is **LIVE** — it spends model credits on the real loop. It reads `SWARM_MAX` for the worker count. Set `ACE_NO_DASH=1` to start without auto-opening the dashboard.

### Pre-run preflight — know before you spend

Before a live `start` launches, ACE prints a **DECISION · SETUP · STATE** table and (in an interactive terminal) asks for one final confirm — so you see exactly what's about to happen before any credits are spent:

```text
┏━ swarm preflight · you/project ━━━━━━━━━━━━━━━━━━━
┃ DECISION  workers 2/5 · overseer …opus-4-8 · merge_gate local · auto_merge on · deploy OFF · live 1
┃ SETUP     repo you/project · branch main · remote you/project · container ✓ · github ✓ · key ✓
┃ STATE     ROADMAP open 77 · objectives open 39 · main@8faa1be · ~5 parallelizable now
┃           plan-lint: 960 collision(s) · 0 oversize
┃           ⚠ heavily file-serialized — early passes will re-slice before real parallelism
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Start this LIVE run now? spends model credits [Y/n] ▸
```

- **DECISION** = the resolved delivery policy (workers, overseer model, merge gate, auto-merge, deploy, feature cap).
- **SETUP** = repo / branch / remote and the tool checks (container runtime, GitHub auth, model key).
- **STATE** = ROADMAP + objectives counts, `main` tip, and the **plan-lint** verdict — how many tasks will collide (serialize) and how many are oversized, so you're warned about a cluttered ROADMAP *before* the run spends time re-slicing it.

**Headless / cron runs never block** — with no TTY (or `ACE_YES=1`) the table is still printed for the record and the run proceeds automatically. Preview it any time without starting a run: `ace swarm preflight`. Disable entirely with `SWARM_PREFLIGHT=0`.

### `ace swarm sandbox` (try it free)

```bash
ace swarm sandbox      # DRY run: simulated edits on a throwaway repo — zero credits
```

The sandbox exercises the whole coordination substrate — leases, worktrees, merges, the dashboard, conflict resolution — with simulated edits instead of real agent calls, so you can see how the swarm behaves without spending anything.

> [!IMPORTANT]
> `sandbox` is `DRY_RUN=1`, the default everywhere. `swarm-run.sh` refuses to run the real loop unless `SWARM_LIVE=1 DRY_RUN=0` — a guard against accidentally spending credits. `ace swarm start` and `ace autorun` set both for you; `sandbox` and `selftest` are always DRY.

## Commands

| Command | Does |
|---|---|
| `ace swarm start [fg]` | start the coordinator (LIVE). `fg` = foreground; otherwise detached + opens the dash |
| `ace swarm stop` | stop now — workers claim nothing new, in-flight WIP is committed to their branches |
| `ace swarm dash` | open the live cockpit (alias: `watch`) |
| `ace swarm split` | the cockpit across tmux columns (falls back to `dash` if tmux is absent) |
| `ace swarm pause` | pause all workers — they idle until you resume |
| `ace swarm resume` | clear pause and drain |
| `ace swarm drain` | finish + stop — workers complete the current item, claim no new work, then the swarm stops |
| `ace swarm kill wN` | kill worker N (its in-flight WIP is preserved as a commit) |
| `ace swarm status` | active claims (the MCP `status` tool returns the one-line form) |
| `ace swarm stats` | per-run outcome tally (merged / conflict / gate-red / stopped / incomplete), **main health**, and the path-disjoint plan |
| `ace swarm tail [N]` | tail the last N (default 40) coordination events |
| `ace swarm sandbox` | DRY-run demo — zero credits |
| `ace swarm selftest` | run the coordination unit tests (leasing, disjointness, wait) |
| `ace swarm policy` | print the effective conflict-policy table (see [conflict-policy](conflict-policy.md)) |
| `ace swarm wire [check\|apply]` | inspect / apply the per-project swarm wiring (`.gitattributes`, AGENTS protocol) |

## The dashboard — `ace swarm dash`

A self-contained TUI, no tmux required. It reads only the shared store, so you can attach, detach, and re-attach freely, and run several viewers at once.

| Element | Shows |
|---|---|
| status bar | two lines — **run** (id · live workers · peak · a `◈ spend ~$X · N tok · overseer %` chip · pause/drain) and **progress** (live `done/total (%)` from `origin/main` · the done/in-flight/remaining bar · a **⇡ merge-pulse** sparkline with "last N ago" · an **ETA** from the recent merge rate · a `⚠ N serializing` chip when the ROADMAP is collision-heavy) |
| worker box | one per live worker — its feature, the pipeline, the agents strip, wall/budget/lease, and its live loop feed |
| pipeline | `PLAN · BUILD · GATE · REVIEW · MERGE` with the current stage lit `▸…◂`, inferred live from the worker's log so it advances through all stages |
| agents strip | all 9 subagents — `✓` once run, `▸active◂` now, dim while pending (`plan·impl·test·gate·rev·ux·std·algn·rslv`) |
| ⚙ agent | the subagent working right now (reviewer / verifier / implementer …) |
| BUS | cross-worker milestones (claimed · gate · merged · main-adv · conflict · gate-red · red-main · standby · abandoned · reaped) — a provider cap surfaces as `standby` |

### Keys

| Key | Action |
|---|---|
| `p` | pause all workers |
| `r` | resume (clears pause **and** drain) |
| `d` | finish + stop — workers complete the current item, claim no new work, then the swarm stops |
| `k` | kill a worker (prompts for `wN`) |
| `x` | **KILL ACE + quit** — SIGTERM the whole swarm (coordinator + workers + opencode), then quit the dash. Prompts `y/N`; in-flight WIP is still committed as WIP on the worker branches |
| `g` | toggle **STACKED** ↔ **PANEL** (a side-by-side grid of worker cells) |
| `+` / `-` | grow / shrink the inline feed height |
| `q` | quit the dashboard — the swarm keeps running (use `d` to stop the swarm) |

> [!NOTE]
> `ace swarm split` lays the cockpit across real tmux columns if you have tmux. Without it, the single-process `dash` gives you the same side-by-side worker cells via the `g` panel layout.

## Graceful control

| You want to… | Do this |
|---|---|
| Pause everything (resumable) | `p` in the dash, or `ace swarm pause` → `ace swarm resume` |
| Wind down — finish in-flight work, then stop | `d` in the dash, or `ace swarm drain` |
| Stop now (preserve WIP) | `ace swarm stop` |
| Kill one stuck worker | `k` in the dash, or `ace swarm kill w3` |
| Kill the whole swarm from the dash | `x` in the dash (prompts `y/N`) |

Every stop path preserves in-flight work: a worker's uncommitted changes are committed to its own `swarm/…` branch (never `main`) with a `WIP:` message, so nothing is lost and a later run can resume it. When all workers finish, the coordinator shuts down cleanly and the dash flips to "no swarm running."

## Per-run archives

Each `ace swarm start` rotates the **previous** run's terminal output — every `wN.log`, the event bus, and the coordinator log — into a datetime-stamped folder, keeping the last `SWARM_ARCHIVE_KEEP` (default 5):

```
~/.config/ace/swarm/<project>/archive/<start-datetime>/
```

These live outside your repo and are never committed — raw material for reviewing a run or improving prompts.

## Rate limits — it waits, never downgrades

If a worker or the coordinator's planning step hits a Claude/OpenAI usage cap, the loop waits for the limit to reset on your chosen model rather than silently swapping to a weaker one — a weaker overseer gives worse plans and reviews. The dash shows `⏳ … usage limit — WAITING for reset`. It rides through a reset window (default 6h), then stops for review; it never auto-downgrades.

> [!TIP]
> To keep going on a weaker model instead of waiting, opt into a DeepSeek fallback per-run with `ON_CLAUDE_LIMIT=deepseek`.

## Safety

| Guarantee | How |
|---|---|
| **Zero-credit by default** | the real loop refuses to run without `SWARM_LIVE=1`; `sandbox` / `selftest` are always DRY |
| **Workers never deploy** | they run with `DEPLOY=0`, so they merge to `main` but never ship. Deploy stays milestone-gated (`DEPLOY_GATE`, see [deploy](deploy.md)) |
| **Full review on auto-merge** | with `auto_merge: true` on a public/customer/enterprise project, the orchestrator's safety rail treats every change as high-risk — the full 4-critic panel plus the security gate — so nothing merges to `main` on a weak review |
| **Predictable conflicts handled up front** | path-disjoint leases plus the [conflict policy](conflict-policy.md) resolve version, changelog, lockfile, and manifest collisions before they happen |
| **Broke-together caught at the gate** | before a worker lands, the merge queue rebases its branch onto the freshest `main` and re-runs `./ci.sh --container` on the combined tree — a green-alone / broken-together integration break surfaces at the gate, not on `main` |
| **RED-main circuit breaker** | if `main` does go RED, one worker is elected to fix it while the rest stand down and rebase onto the recovered tip once it's GREEN — no dogpiling a break none of them caused (`ace swarm stats` → *main health*; hold tuned by `SWARM_REDMAIN_WAIT`) |
| **At-most-one-owner** | if a stuck/silent worker's claim is re-assigned, that worker is TERMINATED (its WIP committed first) before another starts — never two workers on one item, no wasted duplicate cycle. Emits an `abandoned` bus event |
| **Merge-time ownership fence** | a straggler re-checks it still owns its claim (`swarm owns`) at the last moment under the merge lock; if it was reassigned while building — even if the abandon signal hadn't reached it — it yields instead of double-merging |
| **Plan-lint before dispatch** | the OPEN roadmap items are linted against the runtime footprint model: two items sharing a file (COLLIDE), an over-wide item (OVERSIZE, >`PLAN_MAX_FILES`), or a file named by ≥`HOTFILE_MIN` items (HOTFILE cluster) are flagged and, when `SWARM_RESLICE` is on, re-sliced before workers claim — collisions → disjoint files or `deps:`, oversized → decomposed, **hot-file clusters → chained onto one ordered track** so they never contend across workers |
| **Bounded oversized items** | a step that overruns the base budget is treated as oversized: it retries as a single shippable *slice* at the base budget (`BIGTASK_SLICE_RETRIES`), never an escalating 90/135-min re-attempt of the whole thing |
| **Throughput floor** | if `main` stops advancing for `SWARM_DRAIN_AFTER` while workers hold active claims, the run auto-drains instead of churning (the clock pauses during cap / RED-main holds) — see `SWARM_AUTODRAIN` |
| **Provider-cap → cheap wait** | a Claude/Opus usage-cap `429` is detected mid-step (~`CAP_DETECT_AFTER`s) and the whole fleet HOLDS for the reset (`provider-capped`) instead of each worker burning its escalating budget; the *same* step resumes on reset — wall-clock, not credits |
| **Resume, don't re-implement** | a re-claimed item builds on the prior attempt's committed WIP branch, so the loop doesn't re-pay the (Opus-heavy) orchestration from scratch |
| **Parallelism ceiling made visible** | when the ROADMAP is file-serialized, the planner warns (`needs-attention`) that throughput is capped near N workers regardless of `SWARM_MAX` — reshape into disjoint vertical slices (`ace swarm stats` shows the plan) |

> [!NOTE]
> **Semantic conflicts** — two disjoint-but-interacting merges (green alone, broken together) — are handled in two layers. The **tentative-merge gate** re-runs the full container CI on each branch *after* rebasing it onto the freshest `main`, so an integration break is caught before it lands. If a break still reaches `main`, the **RED-main circuit breaker** elects a single fixer and stands the rest down until `main` is GREEN again (watch it with `ace swarm stats` → *main health*). Starting a real-money project at parallelism `2` and watching the first run is still the prudent default.

## Config knobs

All optional — the defaults are tuned. Set them in the environment or `~/.config/ace/config.env`.

| Knob | Default | What it does |
|---|---|---|
| `SWARM_MAX` | `2` | requested worker count (the `ace autorun` prompt sets this; clamped to `SWARM_CEIL`) |
| `SWARM_CEIL` | `5` | hard ceiling on workers; a higher `SWARM_MAX` is clamped down and logged (3–5 is the evidence-backed max) |
| `SWARM_LIVE` | `0` | `1` = spend credits on the real loop (set by `ace swarm start` / `autorun`) |
| `SWARM_PREFLIGHT` | `1` | show the DECISION·SETUP·STATE table + final confirm before a live start. `0` disables it. |
| `ACE_YES` | `0` | `1` = skip the preflight confirm prompt (proceed automatically); the table is still printed. |
| `DRY_RUN` | `1` | `1` = simulated edits, zero credits (sandbox); `0` = real |
| `SWARM_SYNC` | `1` | run the OBJECTIVES→ROADMAP planning sync at start; `0` to skip |
| `SWARM_ARCHIVE_KEEP` | `5` | how many past runs' logs to retain under `archive/` |
| `SWARM_MAX_TRIES` | `3` | park an item after this many failed attempts |
| `SWARM_LEASE_TTL` | `900` | seconds a silent worker holds its lease before it's reclaimed |
| `SWARM_BEAT` | `30` | worker heartbeat interval (seconds) |
| `SWARM_WATCH` | `0` | `1` = surface waiting / blocked / conflict events to Hermes / Telegram |
| `SWARM_MAIN` | `main` | the branch workers merge into |
| `SWARM_REDMAIN_WAIT` | `120` | if `main` goes RED, how many 5-second ticks a non-fixer worker holds for GREEN before exiting cleanly (≈10 min) |
| `CAP_DETECT_AFTER` | `150` | seconds into a step with a provider usage-cap / `429` signal and no credited progress before the worker declares a cap hang, kills the step, and enters the fleet-wide cheap wait (`provider-capped`) instead of burning budget |
| `SWARM_AUTODRAIN` | `1` | coordinator throughput floor: if `origin/main` doesn't advance (no merge lands) for `SWARM_DRAIN_AFTER` while ≥1 worker holds an active claim, trip `control.drain` so the run stops instead of churning unproductively. `0` disables. The clock pauses during provider-cap / RED-main holds (those aren't churn). |
| `SWARM_DRAIN_AFTER` | `9000` | seconds of no merge-to-main (with work in flight) before auto-drain fires (≈2.5 h). Must exceed the longest task a step may legitimately take — with a 2 h `OPENCODE_TIMEOUT`, this lets a genuinely large feature complete + merge before the throughput floor drains the run. |
| `SWARM_RESLICE` | `1` | when plan-lint flags colliding / oversized OPEN items, run one targeted re-slice planning pass and land it before dispatch. `0` = warn only (no re-slice). |
| `RESLICE_MAX` | `30` | max flagged items fed to a single re-slice pass — a cluttered ROADMAP can flag hundreds of pairs; the worst are fixed first and the rest on the next plan-sync's re-lint, so the planner prompt stays sane. |
| `PLAN_MAX_FILES` | `5` | plan-lint flags an OPEN item whose `Files:` hint names more than this many concrete files as OVERSIZE (BIG-TASK-timeout risk). |
| `HOTFILE_MIN` | `3` | plan-lint flags a file named by ≥ this many OPEN items as a HOTFILE cluster → the re-slice chains those items onto one ordered track (kills cross-worker contention on that file). |
| `BIGTASK_SLICE_RETRIES` | `1` | after a step overruns the base budget, how many single-slice retries (each at the *base* budget, not escalating) before the item stops and parks/requeues. |
| `HANG_WARN` | `300` | seconds of zero opencode output (stdout + tool log, nothing building) before an early one-shot warning + bus event, ahead of the hang-restart at `HANG_AFTER` (≈480s). |
| `DASH_COST` | `1` | show the dash `◈ spend` chip (this-run cost + tokens + overseer share). `0` hides it. |
| `COST_TTL` | `600` | how often (seconds) the spend chip re-queries the opencode DBs — cached in between, so it's never on the per-frame path (≈10 min). |
| `SWARM_REPO` | *cwd repo* | the project repo (defaults to the current git root) |
| `SWARM_DIR` | `~/.config/ace/swarm/<slug>` | the coordination store (state, logs, worktrees, archives) |
| `SWARM_META_FREE` | *ROADMAP / OBJECTIVES / …* | files never leased per-item (coordinator-ticked / union-merged) |
| `SWARM_SIM_DELAY` | `0` | sandbox-only: hold each lease this long so concurrency is visible |
| `ACE_NO_DASH` | `0` | `1` = don't auto-open the dashboard after `start` |
| `CREDIT_REVIEW` | `1` | credit review / reconcile / merge time off the per-item budget (like builds); `0` to charge it |

See [configuration](configuration.md) for the loop-wide knobs (`MERGE_GATE`, `AUTOMERGE`, `DEPLOY`, timeouts) that apply to each worker too.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "swarm already running" | a coordinator for *this* project is live — `ace swarm stop`, then start. It's scoped per-project, so it won't block a different repo |
| dash shows 0 workers but a worker is running | the store self-heals a corrupt `state.json`; the dash also falls back to `status/*.stat`. If it persists, `ace swarm stop && ace swarm start` |
| pipeline stuck on BUILD | fixed — the stage is inferred from the live log. Make sure `scripts/auto-loop.sh` is the current thin wrapper (`ace upgrade`, or re-scaffold) |
| all workers grabbed the same item | a symptom of a corrupt store (now auto-repaired). Stop + start to reset |
| `ace swarm split` opens the single dash | tmux isn't installed — the single-process `dash` + `g` panel is the no-tmux equivalent |
| burning quota too fast | drop parallelism (`ace autorun` → `2`), let it wait on the cap (default), or opt into `ON_CLAUDE_LIMIT=deepseek` |

## See also

- [observability.md](observability.md) — reading the logs: the bus events, the log/artifact map, and `jq` recipes for what happened / why
- [autorun.md](autorun.md) — the single-flow loop the swarm fans out
- [agents.md](agents.md) — the 12-agent crew each worker runs
- [conflict-policy.md](conflict-policy.md) — how predictable merge conflicts are handled
- [deferred-decisions.md](deferred-decisions.md) — the serialized-merge re-gate, and why it's deferred
