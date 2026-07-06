<div align="center">

```
   █████╗  ██████╗███████╗
  ██╔══██╗██╔════╝██╔════╝
███████║██║     █████╗
██╔══██║██║     ██╔══╝
  ██║  ██║╚██████╗███████╗
  ╚═╝  ╚═╝ ╚═════╝╚══════╝
⛧  Agentic Coding Environment  ⛧
```

### ⛧ jack into the loop · ship while you sleep ⛧

`OpenCode` + `DeepSeek V4` · 9-agent crew · self-healing CI · limit-resilient autonomous PR runner
**Fedora Silverblue / Arch** · Node · Python · **Go** · everything user-local · no root

✠ &nbsp; *the forge never sleeps · the loop is eternal* &nbsp; ✠

<img src="https://img.shields.io/badge/RITE-v0.0.1--alpha-8b0000?style=for-the-badge&labelColor=0b0b0b">
<img src="https://img.shields.io/badge/OMNISSIAH-OpenCode_%2B_DeepSeek_V4-b8860b?style=for-the-badge&labelColor=0b0b0b">
<img src="https://img.shields.io/badge/COHORT-9_agents-7c0a02?style=for-the-badge&labelColor=0b0b0b">

<img src="https://img.shields.io/badge/cant-bash-1c1c1c?style=for-the-badge&logo=gnubash&logoColor=b8860b&labelColor=0b0b0b">
<img src="https://img.shields.io/badge/forge-Silverblue_·_Arch-1c1c1c?style=for-the-badge&logo=linux&logoColor=b8860b&labelColor=0b0b0b">
<img src="https://img.shields.io/badge/parity-podman-1c1c1c?style=for-the-badge&logo=podman&logoColor=b8860b&labelColor=0b0b0b">
<img src="https://img.shields.io/badge/sanctity-no_root-556b2f?style=for-the-badge&labelColor=0b0b0b">

`▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓`

</div>

> ✠ *In the grim dark of the far-future shell, there is only the loop.* ✠
>
> You speak the mission. The cohort branches, builds, tests, **judges itself three ways**, exorcises its own
> broken CI from the logs, merges when the omens are green, deploys, and draws the next rite from the board —
> until the **objectives** are consecrated. You watch the neon litany scroll by.

<div align="center">

### ⛧ SEE THE RITE ⛧ — *the loop, in motion*

<img src="docs/demo/ace-demo.svg" alt="ACE autorun loop — live demo" width="900">

### ⛧ SEE THE SWARM ⛧ — *the cohort, in parallel*

[<img src="docs/demo/swarm-demo.svg" alt="ACE swarm — parallel workers, live cockpit" width="900">](docs/demo/swarm-full-recording.html)

*N feature-streams at once — each in its own worktree, self-merging. `ace autorun` → pick 2–8, or `ace swarm start`. Full guide: [docs/swarm.md](docs/swarm.md).*

</div>

<div align="center">────────────  ☩  ────────────</div>

## ◢ QUICKSTART ◣ — *the rite of activation*

```bash
# 1. clone + put it on the grid
git clone <this-repo> ace && cd ace
ln -s "$PWD/ace" ~/.local/bin/ace      # now `ace` works anywhere (clone wherever you like)

# 2. wire the rig (host tools + key + 9-agent config + GitHub login)
ace install

# 3a. NEW build →                 3b. EXISTING repo →
ace scaffold                      cd my-repo && ace upgrade

# 4. go hands-off
cd <project>
$EDITOR OBJECTIVES.md             # set the north-star goals
ace autorun                       # 🟢 the machine takes the wheel
```

`ace status` → confirm the rig is green. `ace --help` → the full deck. `--dry-run` → preview anything, change nothing.

> **already set up?** skip `ace install`. just `ace upgrade` your repo, edit `OBJECTIVES.md`, `ace autorun`.

<div align="center">────────────  ⚙  ────────────</div>

## ◢ THE CODEX ◣ — *the documentation*

The full guide lives in [`docs/`](docs/README.md), split by topic:

| Page | What's in it |
|------|--------------|
| [getting-started](docs/getting-started.md) | install · first project · choosing the overseer brain |
| [commands](docs/commands.md) | the full `ace` command deck |
| [stacks](docs/stacks.md) | Node · Python · Go · Config — **and how to add a new stack** |
| [go-stack](docs/go-stack.md) | the Go route: profile wizard · gopls MCP · hardened release binaries |
| [profile](docs/profile.md) | the editable project profile + delivery policy (merge gate / auto-accept) |
| [agents](docs/agents.md) | the 9-agent crew + risk-gated review + the alignment critic |
| [autorun](docs/autorun.md) | the autonomous loop + per-run metrics + the read-only ACE self-triage |
| [swarm](docs/swarm.md) | **parallel loops** — N workers, the live cockpit, finish+stop, per-run archives |
| [conflict-policy](docs/conflict-policy.md) | how the swarm resolves *predictable* merge conflicts (version · changelog · lockfiles · manifests) |
| [hermes](docs/hermes.md) | **drive ACE from chat** — notify · approve · schedule · ground · kanban · dashboard (any channel) |
| [remote-control](docs/remote-control.md) | the "fire ACE from your phone while away" runbook + the security model |
| [configuration](docs/configuration.md) | every env knob + where config lives |
| [scenarios](docs/scenarios.md) | runbooks for the jobs you'll actually run |
| [the-gate](docs/the-gate.md) | the tiered `ci.sh` gate |
| [deploy](docs/deploy.md) | **shipping to the VPS** — cadence · the milestone gate (`DEPLOY_GATE`) · manual deploy · where to check what's live |

<div align="center">────────────  ⚙  ────────────</div>

## ◢ WHAT IS THIS ◣

A one-command rig that installs a **self-driving build loop**:

```
 you ▸ "build X"
        │
        ▼
 ┌─────────────────────────────────────────────────────────────────────┐
 │ ORCHESTRATOR   plans · delegates · never touches code               │
 │   ├─ IMPLEMENTER   maps the graph → builds to spec → self-reviews   │
 │   ├─ TEST_ENGINEER  authors adversarial tests on high-risk paths    │
 │   ├─ VERIFIER      runs ./ci.sh ......................... PASS/FAIL │
 │   ├─ REVIEWER      principal-eng critic: logic·integration·scope    │
 │   ├─ UX_REVIEWER   end-user critic: looks·states·flow·a11y·DX       │
 │   ├─ STANDARDS_KEEPER  best-practices vs .opencode/STANDARDS.md     │
 │   └─ ALIGNMENT_REVIEWER  mission·values·audience vs profile.yaml    │
 │        commit ⇐ verifier PASS  AND  the risk-gated critics APPROVE  │
 │        push → PR  (never self-merges)                               │
 └─────────────────────────────────────────────────────────────────────┘
```

> The **9th agent** — **conflict_resolver** — wakes only when a PR conflicts with main, reconciling *both* sides (never `--ours/--theirs`, never reverting); a reviewer confirms nothing was lost. The **alignment_reviewer** (shown above) judges each high-impact change against the project's mission/values/audience (`.opencode/profile.yaml`). See [docs/agents.md](docs/agents.md).

Grounded by three MCP servers so it **never hallucinates structure**:
**GitNexus** (code-graph: impact / flows / connections) · **Serena** (live symbols / every usage) · **Context7** (live library docs).

…and grounded against the **live web** so it **never hallucinates versions**: the `standards_keeper` confirms the current runtime **LTS / end-of-life** and a framework's **latest stable + breaking changes** by `webfetch`-ing authoritative sources (`endoflife.date`, official release/changelog pages) — not from a model's stale memory — then flags anything >1 major behind or past-EOL with the exact bump. No new key required — and the loop **caches** the LTS/EOL facts to `.opencode/cache/versions.json` (TTL ~7d) so it reads a file instead of re-fetching on every review. It also **compacts `lessons.md`** (dedup + archive the oldest past `LESSONS_MAX_LINES`) so the durable-lessons file the agents read each task doesn't bloat every prompt.

<div align="center">────────────  ✠  ────────────</div>

## ◢ THE AUTORUN LOOP ◣ — *the eternal litany*

`ace autorun` chains the entire pipeline and runs unattended:

```
 OBJECTIVES.md  ──(roadmap empty?)──▶  PLANNER breaks the top objective
      ▲                                  into ROADMAP tasks + ticks progress 
      │ progress                                  │
      └──────────── next ROADMAP item ◀───────────┘
                          ▼
              opencode builds it (9-agent loop)        ◄ fresh session / feature
                          ▼
              push PR ▸ watch CI  ── 🔴 ─▶ pull failed log ─▶ opencode fixes ROOT cause ─▶ push ─▶ re-watch
                                   └─ 🟢 ─▶ merge_if_ready (ALL checks green + mergeable)
                                              ▼ squash-merge · delete branch · pull main
                                              ▼ refresh code-map
                                              ▼ deploy + health-check (CI job · or DEPLOY=1)
                                              ▼ next item ──────────┐
                                                                    │ until MAX_FEATURES
```

> Skim the **bold lead-ins** — each group is one theme. Every env knob is referenced in **SETTINGS / KNOBS** below.

### ⚖ Judgment — *how it decides what to ship*
- **Thinks harder** — agents apply **3 Whys** (root-need at design + acceptance-criteria validation) and a **Pre-mortem** ("assume it's live and broke — why?") at implement/review, for root-cause-correct, durable work.
- **Scales ceremony to risk** — the orchestrator classifies each change first: **low-risk** (docs/config/copy, a test-only change, a single non-security package) gets a **fast lane** — the verifier gate + the engineering reviewer; **high-risk** (auth · money/orders/webhooks · DB migrations · secrets · public APIs · multi-package) gets the **full panel** (all four critics — reviewer · ux_reviewer · standards_keeper · alignment_reviewer — + the security hard gate). When unsure it treats the change as high-risk. Small changes ship fast without weakening the bar where it matters.
- **Self-plans** — when the roadmap empties, it decomposes the next **objective** and refills the board.
- **Self-improves (optional)** — enable it at `ace autorun` launch and, once **every objective is done**, the loop keeps shipping one high-leverage improvement at a time, each chosen to advance an **end goal you set** (e.g. *generate income · solve real user problems · professional UX*) — extending a feature or building a new one. With a feature cap of `0` it runs until you stop it.

### 🛡 Safety — *`main` is never left broken*
- **Preflight** — before touching anything it confirms the **right repo + branch**, and that any pending PR really belongs to *this* `repo:branch` (refuses a stale/wrong PR rather than acting on it). Optional `EXPECT_REPO=owner/name` hard-guard.
- **Resolves conflicts (preserve both intents)** — if a PR conflicts with main, the `conflict_resolver` agent merges main in and reconciles **both** sides' changes (never `--ours/--theirs`, never reverts to old); a reviewer confirms nothing was lost, else it's sent back. Genuinely incompatible → escalates UNRESOLVABLE instead of guessing. `RESOLVE_CONFLICTS=0` to disable, `MAX_CONFLICT` to cap attempts.
- **Doesn't redo finished work** — before building, it checks for the item on a local branch or an open PR (a prior interrupted session may have already done it) and finishes *that* rather than duplicating it; and it keeps a change with the tests + `STANDARDS.md` it touches in **one** PR, so a split never strands `main` stale-RED.
- **Self-merges only when SAFE** — every check green **and** the PR is OPEN, its head is the current branch, and it's actually mergeable; otherwise it stops for you (the merge call retries a couple times since GitHub may still be recomputing mergeability after a fresh push). On success it squash-merges, **deletes the branch (remote + local)**, and returns to **main** to continue. The *script* merges; the *agent* never self-merges.
- **Skips already-shipped branches** — preflight checks whether the current branch's work is already merged (a `MERGED` PR for its head); if so it doesn't reprocess it — it switches to **main**, deletes the stale branch, and moves to the next item. No accidental re-merge of squash-merged work.

### 🔁 Resilience — *survives limits · stalls · crashes*
- **Self-heals CI** — fetches `gh run --log-failed`, feeds it to opencode, fixes the *root cause* (no band-aids, no `as any`, no skipped tests).
- **Tells a blocked CI from a broken one** — a GitHub Actions run that fails having executed **zero jobs** (Actions **billing/spend cap** or an infra outage) is *not* a code RED — no fix can make it green. The loop detects that (0 executed steps) instead of burning fix attempts on it. With **`LOCAL_CI_FALLBACK=1`** it then runs the **local VPS-parity gate** (`./ci.sh --container` — the *same* Containerfile CI uses) and, if that's GREEN, accepts it as the pass and merges (`--admin`) so work keeps flowing through the outage. Fail-closed: only triggers on a real block **and** a real local green. It also **caches** the last container-GREEN tree (`HEAD` + working-tree state), so it won't rebuild the *same* tree twice.
- **Rides out an overseer limit** — when the Claude/OpenAI overseer hits a **plan rate-limit** (or a credit / billing / overload / auth error), the loop doesn't die. Default `ON_CLAUDE_LIMIT=wait` **polls every `CLAUDE_POLL`=120s** and resumes within ~2 min of the reset **on the model you chose — never silently downgrading**; if it hasn't reset within `CLAUDE_RESET_WAIT` (6h) it **stops for review**. Opt into `ON_CLAUDE_LIMIT=deepseek` to **delegate the overseer to DeepSeek and keep going** instead; `cancel` saves and stops. Workers stay on DeepSeek throughout.
- **Resumes reliably** — `ace resume` (and every `autorun`) preflight-rescues finished work an interrupted run left uncommitted: passes `./ci.sh` → it's committed, pushed and PR'd; fails → the loop stops for you. Per-step state lands in `.opencode/loop-state.env`.
- **Stops cleanly** — **Ctrl-C** traps `INT`/`TERM` and tears down the *whole* subtree — the in-flight `opencode`, its MCP servers (Serena/gitnexus), any `podman` build, the watchdog — so nothing is left orphaned chewing CPU after you stop.
- **Fresh session per job, durable handover** — context never piles up; inside a job opencode auto-compacts/hands over at **~80%** of the 1M window, and agents keep `.opencode/HANDOVER.md` current so a compaction or crash never loses the thread. The loop prints the overseer's context-fill each step.
- **Times *active work*, not builds** — the per-step budget (`OPENCODE_TIMEOUT`) clocks the agent's *thinking*; a known-slow deterministic step (container build · dep install · compile · test run — see `SLOW_STEPS`) **pauses the clock**, so a 10-min `podman build` never trips a false *BIG TASK* timeout (and a real overrun still escalates: retried as a split task with a larger budget, not failed). The persistent **MCP/LSP servers** opencode keeps alive (Serena under `uv`/`uvx`, gitnexus/context7 under `npm`/`npx`) launch under slow-step names but run the *whole* session — they're **excluded** (`SERVER_PROCS`), so they can't freeze the budget clock and silently disable the timeout *and* the supervisor. A hard `OPENCODE_WALL_MAX` ceiling still kills a genuinely stuck step. The live heartbeat names **what's running right now** — the actual script, not a bare `node` — e.g. `… 38m wall (active 12m/45m · +26m builds) · now: node vitest`, or `⋯ thinking` when only idle helpers remain — so a long step is never a black box.
- **Parallel, and won't rat-hole** — independent units (separate files/modules, or several review findings) fan out to **parallel implementer subagents** in one turn, and the critics review in parallel; an implementer grinding past ~30m is **decomposed into smaller parallel units** rather than waited out, and value-routing caps consecutive infra/meta work so it keeps shipping user-facing items.
- **Self-heals a stuck step** — if a step goes **silent** (no new output for `STALL_AFTER`, no build running), a bounded **supervisor** asks a cheap model (DeepSeek, hard-timed + **fail-open**) *progress vs stuck*; a confirmed rathole is killed and **retried with the diagnosis as a corrective directive** (capped), then files an **ACE-fixme** note. Set **`FIX_ACE`** at the start of a run (or answer the prompt) and `ace autorun` will **fix ACE itself** from those notes first — a bounded, **PR-gated** *"inception"* session that edits `lib/*.sh` via a PR you merge (never its own running driver). The whole fixer is bounded + fail-open, so it can't rat-hole the rat-hole.

### 🧹 Upkeep — *observability · quality · housekeeping*
- **Shows where the time went** — every completed step appends a row to `.opencode/metrics.csv` (agent · label · wall · active-thinking · build seconds · rc). You can't tune what you can't measure; one `sort`/`awk` over that file tells you which steps and which agents are eating the run.
- **Verifies after deploy (optional)** — with `VERIFY=1` the loop runs the `ace verify` **agent** after each deploy: it probes the live VPS (reachability, TLS, service health, recent errors, integration status), then triages real errors + improvements straight into `ROADMAP.md`. Closed loop: deploy → verify → discover → enqueue → fix next pass.
- **Harvests build warnings (on by default)** — `HARVEST=1` scans every **green** build's CI log for the warnings the gate *let through* (`SecretsUsedInArgOrEnv`, deprecated APIs, peer-dep/engine mismatches, lint noise) and curates the **new** ones into `ROADMAP.md`, so the loop drives the build to **warning-free** instead of letting cruft accumulate. Cheap by design: a mechanical grep gates the model — a clean **or** unchanged build spends nothing — one capped agent pass dedups, harvested lines are remembered so the same warning is never re-queued, and the whole thing fails open (it can neither block nor rat-hole the loop).
- **Self-cleans each lap (throttled)** — a **janitor** reconciles drift + reclaims disk: local `main`↔`origin` sync, **prune of merged local branches** (whose upstream was deleted on merge — squash-merge + the web UI leave them dangling locally), GitNexus graph refresh + prune of deleted branches' graphs, opencode session-DB bound, dangling podman images cleared. It's housekeeping not correctness, so it runs every **`JANITOR_EVERY`** laps (default 3) rather than burning every lap. The same sweep on demand: `ace consistency [fix]`. Its external calls (git fetch · `gitnexus` analyze/status · `pnpm`/`npx`) run with **stdin from `/dev/null`** and **`timeout -k`**, so a tool that tries to prompt can't get TTY-stopped (`SIGTTIN`) and hang the loop — and a wedged one is always reapable.
- **Skips redundant graph re-analysis** — agents refresh the GitNexus map before *and* after every subtask; `scripts/graph-refresh.sh` now fingerprints the code (HEAD + uncommitted diff + untracked, minus its own outputs) and **skips the analyze when nothing changed** (`GRAPH_FORCE=1` overrides) — a single session had spent ~21 min re-analyzing unchanged trees.

Two-tier brain:
```
OBJECTIVES.md   north star (big goals + status)  ◄── YOU edit
     │ planner
ROADMAP.md      concrete task queue              ◄── loop fills & ticks
     │ each task
feat/* PR       built → CI → fixed → merged → deployed → progress marked back up the chain
```

<div align="center">────────────  ⛧  ────────────</div>

## ◢ REMOTE CONTROL ◣ — *drive it from your phone*

A running loop rarely needs babysitting — but when you want to watch or steer it, ACE bridges to
[**Hermes Agent**](https://hermes-agent.org/) so you can do it from **Signal / Telegram / Discord** (any
Hermes channel). Four layers, all opt-in and fail-soft (no `hermes` ⇒ silent no-op):

| layer | command | what you get |
|---|---|---|
| **Notify** (push) | `HERMES_NOTIFY=1 ace autorun` | milestone events — `started · merged · deployed · CI-red · rathole · stopped` — texted to you via `hermes send` (`HERMES_SNAP=1` attaches a CLI snapshot) |
| **Command-back** (pull) | `ace hermes` → *enable* | the bot runs commands on the host (locked to your id), so you text *"ace loop status"* / *"restart"* / *"tail the log"* |
| **Approve from chat** | `MERGE_APPROVAL=hermes` → `ace approve` | the loop **pauses before every merge** and waits for your `ace approve <tok> yes` — a fail-closed human gate |
| **Ground the agent** | `ace hermes mcp` | registers this repo's Serena/GitNexus so chat code questions are answered from *your* code, not guessed |
| **Events → chat** | `ace hermes webhook` | GitHub CI/PR events ping chat (get told when Actions finishes) |
| **Schedule** | `ace schedule '0 9 * * 1-5'` | a recurring autorun via Hermes cron, plus an idle-silent status digest |
| **Run as a service** | `ace loop start\|stop\|restart\|status\|logs\|stats\|update` | the loop as a detached **systemd user service** — a chat command starts/stops it cleanly, surviving terminal-close + sleep |
| **Watch live** | `ace loop dash` | a full-screen dashboard (wordmark · status · agent boxes · log) over the loop's files |
| **Stay reachable** | `ace awake on [4h]` | a `systemd-inhibit` lock so the laptop won't sleep before you can reach it |

Channel-agnostic + **Telegram-first** (`HERMES_TO=signal:+1… ` / `discord:<id>` / `slack:#chan` / …), all
opt-in and **fail-soft** (no `hermes` ⇒ silent no-op). Command-back gives the bot a **host shell**, so the
allowlist that locks it to *you* is mandatory — `ace hermes` sets it up.

→ **Full reference (every feature + env knob): [docs/hermes.md](docs/hermes.md)** · **the "fire ACE from
your phone while away" runbook + security model: [docs/remote-control.md](docs/remote-control.md)**

<div align="center">────────────  ⛧  ────────────</div>

## ◢ THE DECK ◣ — *every incantation*

The full command deck and the runbooks moved into the codex:
**[docs/commands.md](docs/commands.md)** — every `ace` subcommand (incl. remote-control: `ace loop` · `ace hermes` · `ace awake`) ·
**[docs/scenarios.md](docs/scenarios.md)** — runbooks for the jobs you'll actually run.

flags: `--dry-run` · `--watch` · `--version` · `--help`

> **Golden rule:** run `ace` from **inside the project repo** — that's how it resolves which repo / branch it acts on.

<div align="center">────────────  ⚜  ────────────</div>

## ◢ THE ICE ◣ — *the gate · nothing unclean passes*

Every commit hits a **tiered gate** (`ci.sh`):

```
./ci.sh              FAST   typecheck · affected tests · lint · env · no-stubs   (pre-commit · the verifier)
./ci.sh --container  FULL   pinned-container build + tests (VPS parity)          (pre-push · CI)
```

- **No `any`, no `@ts-ignore`** → ESLint errors (build fails). The gate is `tsc`, not the bundler.
- **No stubs / TODO / NotImplemented** → depth gate fails.
- **Undeclared `process.env.X`** → fails (must be in `.env.example`).
- **Stale code-map** → CI `codemap` job fails.
- **Secrets / high-sev vulns** → CI `security` job fails.
- **Self-cleaning** — the `--container` step builds with `--force-rm` and prunes its dangling layers after (`podman image prune -f`), so the parity gate never bloats your disk (the loop's janitor sweeps the rest each lap).

<div align="center">────────────  ☩  ────────────</div>

## ◢ SETTINGS / KNOBS ◣ — *what lives where · every env knob*

Config locations (global + per-project) and the full env-var reference moved to
**[docs/configuration.md](docs/configuration.md)**. Highlights: `AUTOMERGE` · `MERGE_GATE`
(remote/local) · `DEPLOY`/`DEPLOY_GATE` (per-merge vs milestone — see [deploy](docs/deploy.md)) · `MAX_FEATURES` · `SELF_IMPROVE` · the per-step budget · the rathole
supervisor · the Go release knobs (`HARDENING` / `TARGETS` / `UPX`) · the appearance knobs
(`ACE_THEME` warp/blood/void · `ACE_ART` · `ACE_NO_ANIM`, also under `ace settings → Appearance`).

<div align="center">────────────  ✠  ────────────</div>

## ◢ QUIRKS ◣ — *read these, save yourself an hour*

- 🧠 **Restart opencode** after any config/`AGENTS.md` change — it loads at launch, not live.
- 🐚 **New terminal** after `ace install` (the `~/.bashrc` block). `~/.local/bin` must be on `PATH` for the `ace` symlink.
- 🔑 **DeepSeek runs the crew** (V4 Pro/Flash) — implementer, verifier, reviewer, ux_reviewer, standards_keeper, alignment_reviewer, conflict_resolver. The **overseer** defaults to **Claude Opus** (your **Claude Pro/Max** plan) and is switchable via `ace keys` → *orchestrator brain*: `opus` (default) · `sonnet` · `gpt` (OpenAI GPT-5) · `deepseek`. Claude/OpenAI brains need `opencode auth login` (Anthropic or OpenAI; an **oauth** login bills your *plan*, an **API key** bills *credits*). The loop rides out plan rate-limits (waits on your model; opt-in DeepSeek fallback), but a subscription is still capped — prefer **Sonnet** for long runs, or **DeepSeek** for true 24/7 with no subscription.
- 🔐 **Secrets never go in git.** Real values live in the VPS `.env` (gitignored); `env-merge` adds *new* keys on deploy without clobbering yours. CI builds with dummies. Want them in git? encrypt (SOPS/age).
- 🛡️ **Branch protection needs GitHub Pro** on *private* repos — `ace protect` detects the 403 and tells you; local hooks (`main-guard`, the gate) enforce flow meanwhile.
- 🐳 **Container engine**: podman ships on Silverblue; on Arch `ace` offers `pacman -S podman`. The gate's `--container` step needs it.
- 🗺️ **Code-map** refreshes on commit + idle + per-subtask. If `impact`/`context` look a commit behind mid-session, restart so the GitNexus MCP reloads.
- 📦 **pnpm 11** wants explicit build-script decisions — scaffolds use `allowBuilds: { esbuild: true }` (not `onlyBuiltDependencies`, which it rejects).
- 🧱 **Brownfield** (`legacy/**`, `indicators-tradingview/**`) is reference-only — mapped but excluded from the gate. Port into `apps/`·`packages/`·`services/` with tests, then delete the copy.
- 🤖 **`gh` must be authed** (`ace git`) — push, PRs, CI-watch and autorun all run through it.

<div align="center">────────────  ⛧  ────────────</div>

## ◢ REQUIREMENTS ◣

`bash` · `git` · `curl` — everything else (`fnm`/node · `uv`/uvx · `bun` · `jq` · `opencode` · `gh`) is installed **user-local** by `ace install`. A **container engine** (podman/docker) for the parity gate. A **DeepSeek** API key (Context7 optional); the **default overseer is Claude Opus**, so a **Claude Pro/Max** subscription (`opencode auth login`) is needed unless you select the `deepseek` brain. Tested on **Fedora Silverblue/Kinoite** and **Arch**.
Optional terminal eye-candy — `chafa` (pixel-art sprite), `figlet`/`toilet` (wordmark) — is
auto-detected and offered by `ace install`; without it the banner uses a truecolor half-block emblem.

## ◢ DISCLAIMER ◣ — *use at your own risk*

> **⚠ ACE is an autonomous agent. It acts on your machines and accounts without asking.**
> It **runs shell commands, edits and deletes files, commits and `git push`es, opens PRs and merges
> them, builds and runs containers, deploys to remote servers over SSH, and spends money** (LLM API
> credits and any cloud/VPS/hosting you point it at). It can make mistakes, act on a flawed plan, ship
> a bug, break a deployment, leak a secret you left in reach, or incur cost — **autonomously and
> unattended.**

**By running ACE you accept full and sole responsibility for everything it does on your behalf.** The
software is provided **"AS IS", without warranty of any kind** (see [LICENSE](LICENSE)). To the maximum
extent permitted by law, **the author and contributors are not liable** for any damage, data loss,
downtime, security incident, financial cost, or other harm arising from its use — whether or not
foreseeable.

You are responsible for **where and how you run it**: keep **backups**, use a **sandbox / disposable
environment / non-production accounts** where possible, set **spend limits** on every paid API and host,
scope credentials to the **least privilege** needed, and **review what it ships**. Do not run ACE on
systems or data you cannot afford to have modified or lost. Running ACE against **third parties'**
systems, or using it in a way that breaks a provider's terms or the law, is entirely on you.

*This is not legal advice. If protection matters to you — especially before commercial use — have a
lawyer review your situation.*

## ◢ LICENSE ◣

[MIT](LICENSE) © 2026 buagi. Permissive: use, modify, and redistribute freely, provided the copyright
and permission notice travel with it. No warranty; no liability — see the **◢ DISCLAIMER ◣** section above.

<div align="center">────────────  ⚜  ────────────</div>

<div align="center">

`▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓`

```
   (◈)             (◈)             (◈)             (◈)              (◈)             (◈)             (◈)             (◈)             (◈)             (◈)
    ┃               ┃               ┃               ┃                ┃               ┃               ┃               ┃               ┃               ┃
   ╾┸╼             ╾┸╼             ╾┸╼             ╾┸╼              ╾┸╼             ╾┸╼             ╾┸╼             ╾┸╼             ╾┸╼             ╾┸╼
```

*the Omnissiah provides · the loop is eternal · go forth and ship*

**`set the objective · ace autorun · watch it ship`**

*built for the netrunner who'd rather review than retype.*

</div>
