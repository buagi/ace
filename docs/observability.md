# Watching a run & reading the logs

Everything a run does is observable at three zoom levels. Use the one that matches the question:

| Zoom | Use it to… | Command |
|------|-----------|---------|
| **Glance** | see what's happening *right now* | `ace swarm dash` (or `ace loop dash`) |
| **Summary** | see what a run *accomplished* + its cost | `ace swarm stats` · the `.opencode/*-report` files |
| **Forensics** | find out *why* something happened | the log files under the swarm store (below) |

You rarely need to open files by hand — the dashboard and `ace swarm stats` surface almost everything. The file map exists for post-mortems and for scripting your own checks.

---

## 1. The live cockpit — `ace swarm dash`

One screen, refreshed live. Full key reference is in [swarm.md → The dashboard](swarm.md#the-dashboard--ace-swarm-dash); the regions:

- **Status bar** — run id · live worker count · a ROADMAP **done / in-flight / remaining** bar · peak concurrency.
- **Worker cell** (one per worker) — its feature, the `PLAN · BUILD · GATE · REVIEW · MERGE` pipeline with the current stage lit, the 9-agent strip (which subagent is active), wall/budget/lease, and a live feed of its output.
- **BUS** — the cross-worker milestone stream (the same events that land in `events.jsonl`; legend below).

For a single (non-swarm) run, `ace loop dash` is the same idea for one worker.

> [!TIP]
> `ace swarm split` lays the cockpit across tmux columns (one worker per column). Without tmux, the single-process `dash` gives the same side-by-side view via its `g` panel layout.

---

## 2. The bus — what the milestones mean

The **bus** is the cross-worker milestone stream: it's shown live in the dash and written to `events.jsonl`. Each line is one event. These are the milestones you'll see and what each means:

| Event | Meaning |
|-------|---------|
| `claimed` | a worker leased a task (its files are now off-limits to others) |
| `PLAN · BUILD · GATE · REVIEW` | the worker's current pipeline stage (from its live log) |
| `merging` / `merged` | a branch is going through the merge queue / landed on `main` |
| `main-adv` | `main` advanced (someone else merged) — peers rebase onto it |
| `conflict` | a branch collided at merge; the conflict policy / resolver handles it |
| `gate-red` | the container gate failed on a branch — it goes to the fix path, not `main` |
| `red-main` | `main` itself is RED — one worker is elected fixer, the rest stand down |
| `standby` | a worker is holding: a provider rate-limit reset, or RED-main standdown |
| `abandoned` | a worker's task was reassigned; the straggler was terminated (no double-work) |
| `needs-attention` | something a human may care about — a park, a parallelism ceiling, a plan-lint finding, an auto-drain |
| `reap` | a silent worker's lease was reclaimed and its task requeued |

Semantic colour is consistent everywhere: <span title="ok">green ok</span> · <span title="warn">yellow warn</span> · <span title="fail">red fail</span>.

---

## 3. The file map — where everything is written

Two locations. The **coordination store** is durable and aggregated across the whole run; the **per-step reports** are the fine detail of the latest work.

### The coordination store — `~/.config/ace/swarm/<project>/`

(`<project>` is your repo's slug. `ace swarm status` prints the exact path — look for `store …`.)

| File | What it holds | Read it with |
|------|---------------|--------------|
| `events.jsonl` | **the bus** — every cross-worker milestone (JSON lines: `ts`, `worker`, `phase`, `agent`, `level`, `msg`) | `jq` (recipes below) |
| `w1.log`, `w2.log`, … | each worker's **full terminal output** — the whole story of what that worker did | `less` / `tail -f` |
| `coordinator.log` | planning passes, re-slices, reaps, batch decisions, auto-drain | `less` |
| `messages.jsonl` | the **internal coordination channel** — claim/lease negotiation (`claimed`/`merging`/`conflict`/`defer`/`waiting`/`needs-attention`) | `jq` |
| `state.json` | the **claim store** — who owns which task, its status (`active`/`done`/`parked`/`orphaned`/…) and try count | `jq` |
| `batch-plan.txt` | the **parallelism plan** — which tasks run in parallel vs serialize (share a file) vs are dep-blocked, plus the plan-lint verdict | `cat` |
| `status/wN.stat` | the per-worker snapshot the dashboard reads | (the dash) |
| `last-green` | the last sha where the gate was green | `cat` |
| `archive/` | the **previous** runs' logs, datetime-stamped (last `SWARM_ARCHIVE_KEEP`, default 5) | browse |
| `worktrees/` | each worker's isolated git worktree (its own checkout + `.opencode/`) | — |

### The per-step reports — `.opencode/` (in the working tree)

For a single loop these are in the repo root; for a swarm, each worker writes its own inside its worktree. `ace logs` tails the latest.

| File | What it holds |
|------|---------------|
| `last-run.log` | the **full output of the most recent agent step** — the first place to look when a step misbehaved |
| `ci-failure.log` | why the **last gate failed** (the container CI output) |
| `run-summary.txt` | post-mortem **time breakdown** by phase + the slowest steps |
| `token-report.md` | **per-agent token + cost** breakdown (per worker in a swarm) — who's spending |
| `quality-report.md` | per-critic **false-positive rate + retry rate** — is a reviewer being noisy |
| `metrics.csv` | one **row per step** (the raw telemetry the reports aggregate) |
| `loop-state.env` | the loop's current counters (laps, features, conflicts) |

---

## 3b. One-shot rollup — `ace scorecard`

Rather than reading the files below by hand, **`ace scorecard`** aggregates a finished run across 8 levels — research (used/grounded) · feature-breakdown (spec gaps) · subtask hit-rate + manageability · result quality · debate barter · logging completeness · anomalies · edge cases — into one report + a top-line VERDICT (`ace scorecard --json` for machine use). It's read-only and fail-soft (a missing artifact shows "—"). Use it first; drill into the raw files below when a number looks off.

## 4. Reading them — quick recipes

Point these at your project's store. Set it once:

```sh
SW=~/.config/ace/swarm/<project>          # e.g. ~/.config/ace/swarm/trading-portal
```

**Where did the run spend its activity? (stage histogram)** — the true merged/parked *outcome* tally is `ace swarm stats`; this shows what the workers were doing:
```sh
jq -r '.phase' "$SW/events.jsonl" | sort | uniq -c | sort -rn
```

**Per-task final state — who owns what, how many tries:**
```sh
jq -r '.claims|to_entries[]|"\(.value.status)\ttries=\(.value.tries)\t\(.value.worker)\t\(.value.item[0:60])"' "$SW/state.json" | sort
```

**Did we hit rate-limits / hangs / oversized items? (the wall-clock killers)**
```sh
jq -r 'select(.msg|test("usage limit|rate.?limit|HANG|BIG TASK";"i")).msg' "$SW/events.jsonl" | sort | uniq -c | sort -rn
```

**Why is only one worker busy? (the parallelism plan)**
```sh
cat "$SW/batch-plan.txt"        # 'parallel' lines run at once; 'serialize' share a file
```

**Lint the current ROADMAP for collisions before a run** (the same check the swarm runs):
```sh
REPO=/path/to/project bash /path/to/ace/lib/swarm.sh plan-lint /path/to/project/ROADMAP.md
```

**What merged, and when (on the project side):**
```sh
git -C /path/to/project log --oneline --since='6 hours ago' main
```

**Follow a single worker live:**
```sh
tail -f "$SW/w1.log"
```

---

## 5. Symptom → where to look

| You want to know… | Look at |
|-------------------|---------|
| what's happening right now | `ace swarm dash` |
| did the run get anything done, and what did it cost | `ace swarm stats`, then `.opencode/token-report.md` |
| why only one worker is busy | `batch-plan.txt` — most tasks share files → they serialize. Give tasks disjoint `Files:` hints (or let plan-lint re-slice) |
| why a step failed | `.opencode/last-run.log`, then `.opencode/ci-failure.log` if it was the gate |
| why a task never finished (parked) | `state.json` (its `tries`), then that worker's `wN.log` around the task |
| whether `main` is healthy | `ace swarm stats` → *main health*; a `red-main` event means a fixer was elected |
| why the run stopped | tail `coordinator.log` — look for `drain`, `auto-drain`, `no path-disjoint claimable item`, or `made no progress` |
| where the time/credits went | `.opencode/run-summary.txt` (time) + `.opencode/token-report.md` (cost) |

> [!NOTE]
> **A cluttered ROADMAP is the #1 thing that hides in these logs.** If tasks lack precise `Files:` hints they're treated as "touches everything" and forced to run one at a time — you'll see it as lots of `serialize` in `batch-plan.txt` and `defer`/`waiting` in `messages.jsonl`. Giving each task real, non-overlapping file hints is the biggest single lever on throughput.

---

## See also

- [swarm.md](swarm.md) — the dashboard keys, controls (pause/drain/kill), safety rails, and config knobs
- [commands.md](commands.md) — every `ace` subcommand
- [the-gate.md](the-gate.md) — what the container gate checks
- [conflict-policy.md](conflict-policy.md) — how merge collisions are resolved
