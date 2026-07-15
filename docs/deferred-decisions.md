# Deferred decisions & known trade-offs

Maintainer reference for work ACE intentionally leaves unbuilt, with enough context on each to pick it up later.

> [!IMPORTANT]
> Revisit an entry only when its trigger actually fires in a real run — not before. Each entry is a dated snapshot; the swarm items below have evolved as pieces shipped.

## At a glance

| Decision | Why deferred | Trigger to revisit |
|----------|--------------|--------------------|
| Semantic re-gate on the combined post-rebase state | The merge queue already rebases before merging; re-running `./ci.sh --container` on *every* merge is expensive | `main` goes RED right after a merge despite green branches — scope the re-gate to union/registry hotspots (`SWARM_REQUEUE_GATE=1`) |
| Registry-as-directory convention | It is a per-project **code convention** for `standards_keeper` / `STANDARDS.md`, not a merge-layer change | Repeated conflicts/escalations on a central-list / registry file |
| `allocate` for sequential ids | design-cli has no DB yet | The project gains migrations or any auto-increment id file |
| Structured set-union for scalar arrays | `merge-structured.sh` only auto-merges object-key additions; array-valued manifests are rare | Array-manifest escalations become frequent |
| Swarm next-round backlog (10 ranked fixes) | Post-validation throughput/resilience work, ranked by lever | Ranked below under *Swarm: next fixing round* |
| Cross-family model for the launch gate | Blocked on the "prompts before models" model-routing deferral | The model-routing deferral lifts (Part D / D4) |
| Blue-green / canary + multi-region DR | ACE targets a single VPS | ACE promotes beyond one VPS, or needs zero-downtime deploys |

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

### The remaining gap: semantic re-gate

The queue rebases before merging but does **not** re-run `./ci.sh --container` on the combined state. So two workers with disjoint-but-*interacting* changes — each green alone, broken together — can still land a **semantic** break on `main`. Examples: both add a `case` to a `main.go` dispatch, or both touch a shared type. The `conflict_resolver` handles *textual* conflicts, not *semantic* ones.

This is the open half of the merge queue. It is tracked as next-round #2 (`SWARM_REQUEUE_GATE=1`), with a cheaper hotspot-scoped variant under *Smarter conflict handling* #2.

### The airtight fix

The target design gates every merge against the *actual* post-rebase combined state, so a semantic break surfaces RED before it reaches `main`. Before a worker merges:

1. Take `with_merge_lock`.
2. `git rebase origin/main` onto the freshly-updated main.
3. Re-run `./ci.sh --container`.
4. Only then `gh pr merge`.

- **Where:** `lib/swarm-run.sh`, the live `_do_work` / `run_worker` path. Either wire a rebase + re-gate into the live feature merge instead of the auto-loop self-merge, or add a coordinator-side rebase + re-gate before confirming the merge.
- **Cost:** merges serialize — one worker merges at a time. Implement work still parallelizes fully; only the final merge step queues.

The 2026-07-07 queue took the lighter path (Design B plus Design A's rebase step) and already does steps 1, 2 and 4 — leaving only the step-3 `--container` re-gate open. That lighter path is also why the old `_merge_real` design is now redundant (next-round #9).

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

| # | Fix | What it does | Where / knob |
|---|-----|--------------|--------------|
| 1 | Batch / disjoint planning | Biggest throughput lever. The coordinator runs the ~14-min Opus `OBJECTIVES → ROADMAP` sync too often (every reboot) and it BLOCKS dispatch. Plan a BATCH of path-disjoint items → workers drain → re-plan only when < N open remain. Prevents collisions by construction and cuts planning overhead. ~1 day. | `sync OBJECTIVES → ROADMAP` drive in `autoloop.sh` + a "remaining disjoint items" counter in the coordinator |
| 2 | Semantic re-gate after rebase | The open half of the merge queue. The queue rebases but does NOT re-run `./ci.sh --container` on the combined state, so a disjoint-but-interacting break can reach main. Add an optional re-gate, ideally scoped to when the rebase pulled in a shared/union/registry file (the policy table knows which). | `SWARM_REQUEUE_GATE=1` |
| 3 | Decouple workers from a globally-RED main | ~77% of the lost run. Detect "main was RED BEFORE my change" → route it to ONE designated fixer while the others rebase onto the last-GREEN sha and keep shipping; quarantine/skip a known-poison test so it can't block ALL flows. The hermetic-test mandate (shipped) prevents the *cause*; this is the *runtime resilience*. | — |
| 4 | Single-owner hot files | Conflict-policy `assign` for files many items touch (goldens, shared test infra, DI/registry). Complements #1 (registry-as-directory). | conflict-policy `assign` |
| 5 | `ace swarm stats` + truthful conflict telemetry | Classify events: merge-conflict vs gate-RED (pre-existing) vs not-yet-merged; per-run PRs merged / real conflicts / gate-RED time / worker utilization. The broken merged-check corrupted the dashboard/state — this makes regressions visible. | `ace swarm stats` |
| 6 | Re-apply meta-free/lease-free on lease GROWTH | `swarm_touch`'s growth path adds raw paths (e.g. `.opencode/STANDARDS.md`) bypassing the filters `swarm_paths_for_item` applies, so a meta file can re-enter a lease mid-flight. Filter on growth too. | `swarm_touch`, `swarm.sh` |
| 7 | Tighten the base path-scrape | Never lease bare **directories** (prefix overlap on a dir locks a whole subtree → the observed `apps/portal/lib/` deadlock), and require an extension or an existing path so prose fragments (`sentiment/ratings/…`) stop becoming phantom leases. | `swarm_paths_for_item` |
| 8 | "main advanced" bus notification | The one safe pub/sub use. Coordinator broadcasts `main advanced → <sha>` on the bus so a worker can rebase its WORKING branch early. Notification → deterministic rebase, NOT agents reasoning over the bus. Avoid mid-flight rebase while an agent is editing — the merge-time rebase already covers the critical case. | messages bus |
| 9 | Remove the dead `_merge_real` | Now that `merge_if_ready` has the rebase queue, `_merge_real` in `swarm-run.sh` is redundant dead code — delete it (or make it canonical) to avoid the two-designs confusion that caused this whole thread. | `swarm-run.sh` |
| 10 | Lighter overseer option for cost | Opus is orchestrator-only (correct); offer a Sonnet/DeepSeek overseer for cheap long runs. The ~35-min implement floor is Opus coordinating; a lighter overseer lifts it. | `ace keys` |

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

## See also

- [conflict-policy.md](conflict-policy.md) — the declarative conflict policy that shipped (union / structured / regenerate / assign)
- [swarm.md](swarm.md) — the parallel-worker swarm these trade-offs are about
- [autorun.md](autorun.md) — the auto-loop, `merge_if_ready`, and `MERGE_GATE=local`
- [the-gate.md](the-gate.md) — `./ci.sh --container` and `--launch`
