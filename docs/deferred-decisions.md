# Deferred decisions & known trade-offs

Maintainer reference for work ACE intentionally leaves unbuilt, with enough context on each to pick it up later.

> [!IMPORTANT]
> Revisit an entry only when its trigger actually fires in a real run — not before. Each entry is a dated snapshot; the swarm items below have evolved as pieces shipped.

## At a glance

| Decision | Why deferred | Trigger to revisit |
|----------|--------------|--------------------|
| Semantic re-gate on the combined post-rebase state **— shipped 2026-07-15** | Now on by default: every swarm merge re-runs `./ci.sh --container` on the post-rebase tree (`_tentative_merge_ci_ok`); a RED `main` triggers the circuit breaker | *(done — see next-round #2 / #3)* |
| Registry-as-directory convention | It is a per-project **code convention** for `standards_keeper` / `STANDARDS.md`, not a merge-layer change | Repeated conflicts/escalations on a central-list / registry file |
| `allocate` for sequential ids | design-cli has no DB yet | The project gains migrations or any auto-increment id file |
| Structured set-union for scalar arrays | `merge-structured.sh` only auto-merges object-key additions; array-valued manifests are rare | Array-manifest escalations become frequent |
| Swarm next-round backlog (10 ranked fixes) | Post-validation throughput/resilience work, ranked by lever | Ranked below under *Swarm: next fixing round* |
| Cross-family model for the launch gate | Blocked on the "prompts before models" model-routing deferral | The model-routing deferral lifts (Part D / D4) |
| Blue-green / canary + multi-region DR | ACE targets a single VPS | ACE promotes beyond one VPS, or needs zero-downtime deploys |
| ~~Firecrawl auto-spin + startup presentation~~ **SHIPPED 2026-07-19** (`firecrawl_ensure`, lib/consistency.sh) — auto-starts at run start, flips the MCP flag to match reality, and always narrates which research backend the run got | ~~Firecrawl is manual and its MCP enable/disable is baked at `ace opencode` time~~ | A run needs richer research, or the `up`→`opencode` ordering trips a user |

## Swarm: serialized merge and the semantic re-gate

Deferred 2026-07-04. In the live swarm, workers self-merge their own PRs concurrently: `_do_work` runs the auto-loop with `AUTOMERGE=1 MERGE_GATE=local`, which owns the whole implement → PR → local-gate → `gh pr merge` cycle. Originally there was no serialized merge lock on the live feature-merge path — `with_merge_lock` guarded only the dry-run `_merge_dry` and the coordinator's `_tick_roadmap`. The concern: concurrent self-merges breaking `main`.

### What already prevents conflicts

| Mechanism | What it does | Where |
|-----------|--------------|-------|
| Path-disjoint leases | Two workers can't hold overlapping files, so code changes land on disjoint files and merge cleanly. | `_overlap`, `swarm.sh` |
| Meta-file exclusion | ROADMAP, OBJECTIVES, AGENTS, CLAUDE, `docs/architecture.md`, lessons, changelog, STANDARDS are stripped from leases, then coordinator-ticked or union-merged — never fought over. | `SWARM_META_FREE`, `swarm.sh` |
| Declarative conflict policy *(shipped 2026-07-04)* | Union / structured-data merge / post-merge regenerate / assign — all lease-free. Removes the predictable, structural conflicts up front. | `lib/swarm-policy.sh`, [conflict-policy.md](conflict-policy.md) |
| Per-worker textual resolve | The auto-loop detects `CONFLICTING` and runs the `conflict_resolver` subagent: merge `origin/main` in, preserve BOTH intents, reviewer confirms nothing was lost, re-gate, re-merge. | `RESOLVE_INSTR` + the CONFLICTING branches in `autoloop.sh` |
| Serialized rebase-before-merge queue *(shipped 2026-07-07)* | `merge_if_ready`, in a swarm (`SWARM_WORKER` set; `SWARM_MERGE_QUEUE=0` disables), takes a `flock` on `$SWARM_DIR/.merge.lock` across the whole rebase → merge: `git merge origin/main` onto the freshest main, push, re-check mergeability, merge. Fail-safe — a rebase conflict returns `3` and routes to `conflict_resolver`. Closes the "merge a stale-based branch" gap. | `merge_if_ready`, `lib/autoloop.sh` |
| Tightened test gate | `go test -timeout 120s -count=2` in the `--container` gate. | `ci.sh --container` |

### The semantic re-gate — shipped 2026-07-15

The queue rebases before merging **and now re-runs `./ci.sh --container` on the combined post-rebase tree** (`_tentative_merge_ci_ok` in `autoloop.sh`), landing only on green. Two workers with disjoint-but-*interacting* changes — each green alone, broken together — therefore surface RED **at the gate**, not on `main`. If a break still reaches `main` (an infra failure, a flake), the **RED-main circuit breaker** (next-round #3, shipped) elects one fixer and stands the rest down until `main` is GREEN. The `conflict_resolver` still handles *textual* conflicts, which are a separate case.

### The airtight fix

The target design gates every merge against the *actual* post-rebase combined state, so a semantic break surfaces RED before it reaches `main`. Before a worker merges:

1. Take `with_merge_lock`.
2. `git rebase origin/main` onto the freshly-updated main.
3. Re-run `./ci.sh --container`.
4. Only then `gh pr merge`.

- **Where:** `lib/swarm-run.sh`, the live `_do_work` / `run_worker` path. Either wire a rebase + re-gate into the live feature merge instead of the auto-loop self-merge, or add a coordinator-side rebase + re-gate before confirming the merge.
- **Cost:** merges serialize — one worker merges at a time. Implement work still parallelizes fully; only the final merge step queues.

The 2026-07-07 queue took the lighter path (Design B plus Design A's rebase step) and does steps 1, 2 and 4; the step-3 `--container` re-gate shipped 2026-07-15 (`_tentative_merge_ci_ok`), closing the design. That lighter path is also why the old `_merge_real` design is now redundant (next-round #9).

**Revisit when:** a swarm run where `main` goes RED right after a merge despite green branches, or any breakage traced to two concurrent merges interacting.

## Smarter conflict handling — beyond the policy table

Deferred 2026-07-04. The mechanical policy (above) is shipped; these are the structural/convention wins that need per-project code changes or a new coordinator step — the parts a policy table can't auto-apply.

### 1. Registry-as-directory (remove the shared mutation point)

The biggest source of *append* conflicts is a central list every feature edits: a `switch cmd {}` in `main.go`, a `routes.ts`, a `plugins/__init__.py`, a DI container, an enum. Union-merge makes these textually clean but can still break compilation — a duplicate `case`, ordering, a shared type.

The real fix is to remove the shared file: one file per entry in a directory, plus auto-discovery — Go `init()` self-registration, Python entry-points/decorators, JS `import.meta.glob`, a generated barrel. Two workers adding two commands then touch two *different* files, so there is zero conflict.

This is universal but it is a **code convention**, so it belongs to `standards_keeper` / `STANDARDS.md` to recommend and enforce per project, not to the merge layer.

*Pick up:* add a `STANDARDS.md` rule plus an orchestrator nudge — "new command/route/plugin ⇒ add a file under `<dir>/`, never edit the central list."

### 2. Post-merge semantic re-gate scoped to policy hotspots

The serialized re-gate above is expensive if applied to *every* merge. Cheaper trigger: only re-gate (rebase onto fresh main + re-run `./ci.sh --container`) when the merge touched a `union`/registry file that another concurrent merge *also* touched — exactly the disjoint-but-interacting case. The policy table already knows which files those are, so the coordinator can gate selectively.

### 3. `allocate` for sequential ids (migration numbers)

Not built — design-cli has no DB yet. Two options when it does:

- **(a) Coordinator hands out the next number at dispatch** via the existing `messages.jsonl` request bus (worker asks, coordinator answers, serialized). Airtight.
- **(b) Sidestep monotonicity** — recommend timestamp/UUID-prefixed ids (Rails-style `20260704120000_*.sql`) so two workers essentially never collide. A convention: cheaper and universal.

### 4. Structured merge for arrays

`merge-structured.sh` conservatively *escalates* when both sides change an array differently — it only auto-merges object-key additions. Fine for dep maps (objects), but a manifest that stores deps as an *array* (rare) will escalate more than necessary.

*Pick up if* array-valued manifests show up as frequent escalations: add order-insensitive set-union for arrays of scalars, keep escalating arrays of objects.

**Revisit when:** repeated conflicts/escalations on a registry file (→ #1 / #2), the project gains migrations (→ #3), or array-manifest escalations (→ #4).

## Swarm: next fixing round (2026-07-07)

> [!NOTE]
> From the deep validation. A 14h trading-portal run produced ~2 PRs. Three audits plus a reproduction found the "5/5 conflicts" was mostly a bookkeeping bug (fixed, PR #7), plus no rebase-before-merge (fixed, PR #8) and a RED-main freeze from a wall-clock golden (hermetic-test mandate, PR #7). The earlier GitNexus-impact scope work was largely misaimed and is now off by default and bounded.

Remaining backlog, ranked by lever:

> [!NOTE]
> **Status (2026-07-15): items 1–9 are shipped or already done.** #1 batch/disjoint planning, #2 semantic re-gate (`_tentative_merge_ci_ok`), and #4 single-owner hot files (`assign` policy) landed earlier; #6 + #7 lease-hygiene shipped in PR #56; #5 `ace swarm stats` + truthful outcome telemetry and #3 the RED-main circuit breaker shipped in PR #57; #8 the "main advanced" bus broadcast shipped 2026-07-15; #9 the dead `_merge_real` was already removed in PR #45. **#10 (lighter overseer option) was dropped 2026-07-19 — decided against, not deferred.** Nothing from this table remains open. Rows below are kept as design rationale.
>
> **Resilience round (2026-07-16), from a live-run post-mortem.** A separate batch of issues filed off the last two real runs is now closed: **#61** at-most-one-owner (a re-claimed item TERMs the zombie worker, WIP committed first — no duplicate concurrent claims); **#62** provider-cap → fleet-wide cheap wait (`CAP_DETECT_AFTER`, `provider-capped` bus event) so a Claude/Opus `429` no longer burns ~50% of wall-clock in escalating retries; **#64** resume-on-reclaim (a re-claim bases its worktree on the prior attempt's WIP branch rather than re-paying Opus orchestration from scratch); **#65** parallelism-ceiling warning (the planner posts `needs-attention` when the ROADMAP is file-serialized so throughput can't scale past ~N). See `docs/swarm.md` → *Safety*. **Nothing from this table remains open.**

| # | Fix | What it does | Where / knob |
|---|-----|--------------|--------------|
| 1 | Batch / disjoint planning | Biggest throughput lever. The coordinator runs the ~14-min Opus `OBJECTIVES → ROADMAP` sync too often (every reboot) and it BLOCKS dispatch. Plan a BATCH of path-disjoint items → workers drain → re-plan only when < N open remain. Prevents collisions by construction and cuts planning overhead. ~1 day. | `sync OBJECTIVES → ROADMAP` drive in `autoloop.sh` + a "remaining disjoint items" counter in the coordinator |
| 2 | Semantic re-gate after rebase | The open half of the merge queue. The queue rebases but does NOT re-run `./ci.sh --container` on the combined state, so a disjoint-but-interacting break can reach main. Add an optional re-gate, ideally scoped to when the rebase pulled in a shared/union/registry file (the policy table knows which). | shipped as `_tentative_merge_ci_ok`. **`SWARM_REQUEUE_GATE` never existed** — it was a proposed name in this row, not a knob; do not look for it |
| 3 | Decouple workers from a globally-RED main | ~77% of the lost run. Detect "main was RED BEFORE my change" → route it to ONE designated fixer while the others rebase onto the last-GREEN sha and keep shipping; quarantine/skip a known-poison test so it can't block ALL flows. The hermetic-test mandate (shipped) prevents the *cause*; this is the *runtime resilience*. | — |
| 4 | Single-owner hot files | Conflict-policy `assign` for files many items touch (goldens, shared test infra, DI/registry). Complements #1 (registry-as-directory). | conflict-policy `assign` |
| 5 | `ace swarm stats` + truthful conflict telemetry | Classify events: merge-conflict vs gate-RED (pre-existing) vs not-yet-merged; per-run PRs merged / real conflicts / gate-RED time / worker utilization. The broken merged-check corrupted the dashboard/state — this makes regressions visible. | `ace swarm stats` |
| 6 | Re-apply meta-free/lease-free on lease GROWTH | `swarm_touch`'s growth path adds raw paths (e.g. `.opencode/STANDARDS.md`) bypassing the filters `swarm_paths_for_item` applies, so a meta file can re-enter a lease mid-flight. Filter on growth too. | `swarm_touch`, `swarm.sh` |
| 7 | Tighten the base path-scrape | Never lease bare **directories** (prefix overlap on a dir locks a whole subtree → the observed `apps/portal/lib/` deadlock), and require an extension or an existing path so prose fragments (`sentiment/ratings/…`) stop becoming phantom leases. | `swarm_paths_for_item` |
| 8 | "main advanced" bus notification | The one safe pub/sub use. Coordinator broadcasts `main advanced → <sha>` on the bus so a worker can rebase its WORKING branch early. Notification → deterministic rebase, NOT agents reasoning over the bus. Avoid mid-flight rebase while an agent is editing — the merge-time rebase already covers the critical case. | messages bus |
| 9 | Remove the dead `_merge_real` | Now that `merge_if_ready` has the rebase queue, `_merge_real` in `swarm-run.sh` is redundant dead code — delete it (or make it canonical) to avoid the two-designs confusion that caused this whole thread. | `swarm-run.sh` |

> [!NOTE]
> **Before the next big feature push:** live-validate PR #7 + #8 on ONE real swarm run. First re-plan trading-portal's 74 pre-fix items for disjointness, then run measured — watch the new merged-check status and the merge-queue rebase logs. Confirm the bookkeeping fix and rebase queue land before building #1–#3 on top.

> [!IMPORTANT]
> **Reality check.** Even fully fixed, 6 workers hit ~⅕ the throughput of ONE sequential loop in this run; the merge-lock and shared gate cap the ceiling. The swarm wins only when features are genuinely independent AND the gate is fast and hermetic. Measure swarm-vs-single before investing further in swarm complexity.

## Launch-readiness gate (C6) — deferred extensions

Deferred 2026-07-14. The `launch_readiness_reviewer` agent, the `./ci.sh --launch` gate, and the `ops/` scaffolds shipped (Part C, C6). Two extensions are intentionally not built.

### 1. Cross-family model for the launch gate

The agent inherits the default worker model (per the "prompts before models" deferral). Running the decisive GO/NO-GO on a cross-family model (an Opus/GPT overseer) would break DeepSeek↔DeepSeek correlated blindness for the highest-stakes decision.

*Trigger to revisit:* when the model-routing deferral lifts (see the Part D / D4 stub) — wire it into the existing agent, don't add a new one.

### 2. Blue-green / canary + multi-region DR

The BLOCK items (tested restore, rollback, env separation, reconciliation, spend caps) are required regardless of scale. Heavier infra — blue-green/canary deploys, multi-region disaster recovery — stays a WARN because ACE targets a single VPS.

*Trigger to revisit:* if ACE ever promotes to more than one VPS or needs zero-downtime deploys — promote the relevant WARN items to BLOCK and add the deploy-strategy checks.

## CLI unification: one `ace start` / `stop` / `scaffold` / `dash` / `report` / `logs`

**Status: PARTIALLY SHIPPED (2026-07-22).** `ace start` / `ace stop` and the default flips are in
(`lib/lifecycle.sh`, pinned by `tests/lifecycle-selftest.sh`). The owner signed off on the policy change:
**automerge, spec debate, review debate and cited-URL verification all default ON** under `ace start`, with
`env > Settings > default` precedence and the resolved policy printed at run start.

**ALSO SHIPPED 2026-07-22:** the one report surface, as **`ace stats`** rather than `ace report`
(`lib/statsall.sh`, pinned by `tests/statsall-selftest.sh`). Owner's call: `ace report` already means "file a
GitHub issue", and quietly redefining a live verb is worse than the problem it solves. Bare `ace stats` prints
all four sections; `ace stats <section>` prints one; every legacy form (`global`/`N`/`task`/`--by`) still
routes to the token table, and `ace quality` / `ace scorecard` / `ace reanalyze report` are untouched.

STILL OPEN from the original ask: one `ace logs` surface, and making `scaffold` + first-run setup
materially quicker.

### The problem, measured today

There are FOUR names for the same run command. `ace:371` is one case arm:

```bash
autoloop|autorun|loop|resume)   *) autoloop_run ;;
```

`ace autoloop` ≡ `ace autorun` ≡ `ace loop` ≡ `ace resume` — byte-identical, no per-verb branch below.
Nothing is deprecated; they are simply redundant. On top of that:

- **Two doors to the swarm with DIFFERENT defaults.** `SWARM_MAX` defaults to **1** via `ace autorun`
  (`lib/scaffold.sh:3089`) and **2** via `ace swarm start` (`lib/swarm-run.sh:26`). `SWARM_MAX>=2` silently
  turns `autorun` into a detached swarm coordinator and `return 0`s (`scaffold.sh:3133`) — the "loop" the
  user started is a background swarm.
- **`MAX_FEATURES` is 3 direct but infinite under the systemd service** (`autoloop.sh:29` vs `scaffold.sh:2896`).
- **Worker env is hardcoded and silently overrides the caller**: `MAX_FEATURES=1 AUTOMERGE=1 MERGE_GATE=local
  DEPLOY=0` (`swarm-run.sh:103`), and the autorun->swarm handoff hardcodes `AUTOMERGE=1` (`scaffold.sh:3134`)
  — so answering "no self-merge" interactively and then choosing 3 workers self-merges anyway.
- **`ace loop start` != `ace loop`.** `start|stop|restart|status|logs|tail|stats|metrics|up|update` after ANY
  of the four run verbs routes to `loop_ctl` (systemd), not a run (`ace:373`).
- **Debate + net-verification default OFF** (`SPEC_DEBATE`/`REVIEW_DEBATE` = 0; `SPEC_LINT_NET` derived), so
  the quality gates a user assumes are on are not, unless they know the knobs.
- Setup friction: `scaffold` + first run needs an origin remote, a `ci.sh`, a clean tree, and a config pass
  before anything moves.

### The ask

ONE verb per job, with the prerequisites set for you:

| verb | does |
|---|---|
| `ace start` | run the swarm with sane prerequisites resolved automatically (workers, automerge ON by default, debate/net-verification on, plan gates, research backend) — no env archaeology |
| `ace stop` | stop whatever is running (solo, swarm, or service) — ~~today there is NO `ace stop` at all~~ **(SHIPPED 2026-07-22, PR #166)** — was: (`ace:457` -> unknown command) |
| `ace scaffold` | project setup, faster |
| `ace dash` | already unified (`dash_auto`, auto-routes swarm vs solo) — keep |
| ~~`ace report`~~ → **`ace stats`** | SHIPPED 2026-07-22 (PR #167) as `ace stats` with sections. `ace report` deliberately still means "file a GitHub issue" — redefining a live verb was rejected. |
| `ace logs` | one log surface |

Plus: **automerge ON by default**, and make **scaffold + first-run setup materially quicker**.

### Constraints for whoever picks this up

- The old verbs must keep working (or alias with a deprecation notice) — muscle memory and docs reference them.
- `usage()` and the dispatch arms are required to stay byte-identical (`ace:417-420`) — help/dispatch drift
  was a past bug. Any renaming touches both, in the same commit.
- `cli-dispatch-selftest` asserts dispatch<->help agreement; extend it rather than route around it.
- Defaults are a POLICY change (automerge on, debate on): they alter spend and what reaches main unattended.
  Confirm with the owner before flipping, and narrate the new defaults at run start.
- Deciding "one report surface" means reconciling four existing commands that answer different questions —
  scope that explicitly rather than merging them blindly.

## See also

- [conflict-policy.md](conflict-policy.md) — the declarative conflict policy that shipped (union / structured / regenerate / assign)
- [swarm.md](swarm.md) — the parallel-worker swarm these trade-offs are about
- [autorun.md](autorun.md) — the auto-loop, `merge_if_ready`, and `MERGE_GATE=local`
- [the-gate.md](the-gate.md) — `./ci.sh --container` and `--launch`

## Firecrawl: auto-spin + present its state at autorun/swarm start

Deferred 2026-07-17. The local research crawler (Part H / H4) works but its lifecycle is manual and its state is decided at the wrong moment + never shown to the user at run start.

**The three problems today**
1. **No auto-start on a run** — you must `ace firecrawl up` by hand; nothing brings it up for `ace autorun` / `ace swarm start`.
2. **Enable/disable is baked at `ace opencode` time**, not per-run: the reachability probe (`lib/install.sh:671-676`) flips `mcp.firecrawl.enabled` when the config is generated. So **`ace firecrawl up` must precede `ace opencode`** — start it *after* and the config still has it OFF for the whole run. Silent footgun.
3. **Nothing tells the user** at run start whether research will use Firecrawl or fall back to `webfetch`.

**To build (polish)**
- **Surface it in the preflight/START box** — `swarm_preflight` (`lib/swarm-run.sh`) STATE table and `autoloop_run` (`lib/scaffold.sh`) confirm box: `research: Firecrawl UP (loopback · MCP enabled)` vs `research: webfetch fallback (Firecrawl down — 'ace firecrawl up' + 'ace opencode' to enable)`.
- **Opt-in auto-spin** — `FIRECRAWL_AUTO=1` (or a preflight prompt) runs `ace firecrawl up` at the start of a run, waits for reachability, and — if it flipped up — re-runs the MCP-enable step so the just-generated config reflects it (avoid the stale-config trap). Default OFF, loopback-only, no cloud key (same security posture).
- **Consider moving the reachability→enable/disable to run-time** (a per-run MCP toggle) so the `up`→`opencode` ordering footgun disappears entirely.

**Trigger:** a run that depends on richer research (search+scrape, not single-URL webfetch), or the ordering trips a user. **Hooks:** `firecrawl_cmd` (`lib/install.sh:780`, the up/down/status), `swarm_preflight`/`_swarm_plan_sync` (`lib/swarm-run.sh`), `autoloop_run` (`lib/scaffold.sh`).
