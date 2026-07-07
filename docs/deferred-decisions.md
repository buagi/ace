# Deferred decisions & known trade-offs

Things intentionally NOT built yet — with enough context to pick them up later.
Revisit an entry when its "trigger to revisit" actually happens in a real run.

---

## Swarm: serialized merge + re-gate for semantic conflicts

**Status:** deferred (2026-07-04). Revisit only if concurrent merges actually break `main`.

**Context.** In the live swarm, workers **self-merge** their own PRs concurrently
(`_do_work` runs the auto-loop with `AUTOMERGE=1 MERGE_GATE=local`, which owns the whole
implement → PR → local-gate → `gh pr merge` cycle). There is **no serialized merge lock**
on the live feature-merge path — `with_merge_lock` is currently used only for the DRY
`_merge_dry` and the coordinator `_tick_roadmap`, not for live merges.

**What's already mitigating conflicts (why this is low-priority):**
- **Path-disjoint leases** (`_overlap` in `swarm.sh`) — two workers can't hold overlapping
  files, so code changes land on disjoint files → clean merges by construction.
- **Meta files** (`SWARM_META_FREE`: ROADMAP/OBJECTIVES/AGENTS/CLAUDE/docs/lessons/changelog/
  STANDARDS) are stripped from leases → coordinator-ticked or union-merged, never fought over.
- **Textual conflicts** at merge time are handled per-worker: the auto-loop detects
  `CONFLICTING` and runs the built-in **`conflict_resolver`** subagent (merge `origin/main`
  in, preserve BOTH intents, reviewer confirms nothing lost, re-gate, re-merge). See
  `RESOLVE_INSTR` + the CONFLICTING branches in `autoloop.sh`.
- **Tightened test gate** (`go test -timeout 120s -count=2` in the `--container` gate).

**The gap.** No **re-gate against the combined state**. Two workers merging concurrently
with disjoint-but-*interacting* changes (each green alone, broken together — e.g. both add a
`case` to `main.go` dispatch, or touch a shared type) could produce a **semantic** break on
`main` that neither branch's local gate caught. The resolver handles *textual* conflicts, not
*semantic* ones.

**The fix (when we want it airtight).** Restore the old `_merge_real` design on the live
path: before a worker merges, take `with_merge_lock` → `git rebase origin/main` (onto the
freshly-updated main) → re-run `./ci.sh --container` → only then `gh pr merge`. This gates
every merge against the *actual* post-rebase combined state, so a semantic break surfaces RED
**before** it reaches main.
- **Where:** `lib/swarm-run.sh` — `_do_work` LIVE + `run_worker` (both `_merge_real` and
  `with_merge_lock` already exist; wire them into the live feature merge instead of the
  auto-loop self-merge, or add a coordinator-side rebase+re-gate before confirming the merge).
- **Cost:** merges serialize (one worker merges at a time) instead of concurrent. Implement
  work still parallelizes fully; only the final merge step is queued.

**Trigger to revisit:** a swarm run where `main` goes RED right after a merge despite green
branches, or any observed breakage traced to two concurrent merges interacting.

**Update (2026-07-04):** the declarative **conflict policy** now ships (`docs/conflict-policy.md`,
`lib/swarm-policy.sh`) — union / structured-data merge / post-merge regenerate / assign, all
lease-free. That kills the *predictable, structural* conflicts up front. What remains deferred
below is the *semantic* re-gate and the code-convention changes a tool can't auto-apply.

**Update (2026-07-07): the serialized rebase-before-merge queue SHIPPED.** `merge_if_ready`
(`lib/autoloop.sh`) now, in a swarm (`SWARM_WORKER` set; `SWARM_MERGE_QUEUE=0` disables), takes a
`flock` on `$SWARM_DIR/.merge.lock` across the whole rebase→merge, `git merge origin/main` onto the
freshest main, pushes, re-checks mergeability, then merges — fail-safe (rebase-conflict → `return 3`
→ `conflict_resolver`). This closes the "merge stale-based branch" gap (Design B + Design A's rebase
step, without rearchitecting to `_merge_real`, which is now redundant — see next-round #9). **Still
open: the semantic RE-GATE after rebase** (the queue rebases but does NOT re-run `./ci.sh --container`
on the combined state, so a disjoint-but-interacting semantic break can still reach main). That's
next-round #2 below.

---

## Smarter conflict handling — the parts a policy table can't auto-apply

**Status:** deferred (2026-07-04). The mechanical policy (above) is shipped; these are the
structural/convention wins that need per-project code changes or a new coordinator step.

1. **Registry-as-directory (eliminate the shared mutation point).** The single biggest source of
   *append* conflicts is a central list every feature edits: a `switch cmd {}` in `main.go`, a
   `routes.ts`, a `plugins/__init__.py`, a DI container, an enum. Union-merge makes them *textually*
   clean but can still break compilation (duplicate case, ordering, a shared type). The real fix is
   to **remove the shared file**: one file per entry in a directory + auto-discovery — Go `init()`
   self-registration, Python entry-points/decorators, JS `import.meta.glob`, a generated barrel.
   Two workers adding two commands then touch two *different* files → zero conflict *by construction*.
   This is universal but it's a **code convention**, so it belongs to `standards_keeper` /
   `STANDARDS.md` to recommend + enforce per project, not to the merge layer.
   *Pick up:* add a STANDARDS.md rule + an orchestrator nudge ("new command/route/plugin ⇒ add a
   file under `<dir>/`, never edit the central list").

2. **Post-merge semantic re-gate scoped to policy hotspots.** The serialized re-gate in the entry
   above is expensive if applied to *every* merge. Cheaper trigger: only re-gate (rebase onto fresh
   main + re-run `./ci.sh --container`) when the merge touched a `union`/registry file that another
   concurrent merge *also* touched — that's exactly the disjoint-but-interacting case. The policy
   table already knows which files those are, so the coordinator can gate selectively.

3. **`allocate` for sequential ids (migration numbers).** Not built — design-cli has no DB yet.
   Two options when it does: (a) coordinator hands out the next number at *dispatch* via the
   existing `messages.jsonl` request bus (worker asks, coordinator answers, serialized); or (b)
   sidestep monotonicity entirely — recommend **timestamp/UUID-prefixed** ids (Rails-style
   `20260704120000_*.sql`) so two workers essentially never collide. (b) is a convention (cheaper,
   universal); (a) is airtight. *Trigger:* the project gains migrations or any auto-increment id file.

4. **Structured merge for arrays.** `merge-structured.sh` conservatively *escalates* when both sides
   change an array differently (it only auto-merges object key additions). Fine for dep maps
   (objects), but a manifest that stores deps as an *array* (rare) will escalate more than necessary.
   *Pick up if* array-valued manifests show up as frequent escalations — add order-insensitive
   set-union for arrays of scalars, keep escalating arrays of objects.

**Trigger to revisit any of these:** repeated conflicts/escalations on a registry file (→ #1/#2),
the project gaining migrations (→ #3), or array-manifest escalations (→ #4).

---

## Swarm: next fixing round (2026-07-07) — from the deep validation

Context: a 14h trading-portal run made ~2 PRs. Deep validation (3 audits + reproduction) found the
"5/5 conflicts" was mostly a **bookkeeping bug** (fixed, PR #7), plus **no rebase-before-merge**
(fixed, PR #8) and a **RED-main freeze** from a wall-clock golden (hermetic-test mandate, PR #7). The
prior GitNexus-impact scope work was largely misaimed and is now **off by default + bounded**.
Remaining backlog, ranked:

1. **Batch / disjoint planning (biggest throughput lever).** The coordinator runs the ~14-min Opus
   `OBJECTIVES→ROADMAP` sync too often (every reboot) and it BLOCKS dispatch. Plan a BATCH of
   **path-disjoint** items → workers drain → re-plan only when < N open remain. Prevents collisions
   by construction + cuts planning overhead. *Where:* the `sync OBJECTIVES → ROADMAP` drive in
   `autoloop.sh` + a "remaining disjoint items" counter in the coordinator. ~1 day.
2. **Semantic re-gate after rebase** (the open half of the merge queue). The queue rebases but does
   NOT re-run `./ci.sh --container` on the combined state → a disjoint-but-interacting break can reach
   main. Add optional re-gate, ideally scoped to when the rebase pulled in a shared/union/registry
   file (the policy table already knows which). `SWARM_REQUEUE_GATE=1`.
3. **Decouple workers from a globally-RED main** (~77% of the lost run). Detect "main was RED BEFORE
   my change" → route it to ONE designated fixer while the others rebase onto the last-GREEN sha and
   keep shipping; quarantine/skip a known-poison test so it can't block ALL flows. The hermetic-test
   mandate (shipped) prevents the *cause*; this is the *runtime resilience*.
4. **Single-owner hot files** — conflict-policy `assign` for files many items touch (goldens, shared
   test infra, DI/registry). Complements #1 (registry-as-directory).
5. **`ace swarm stats` + truthful conflict telemetry.** Classify events: merge-conflict vs gate-RED
   (pre-existing) vs not-yet-merged; per-run PRs merged / real conflicts / gate-RED time / worker
   utilization. The broken merged-check corrupted the dashboard/state — this makes regressions visible.
6. **`swarm_touch` must re-apply meta-free/lease-free on lease GROWTH** — the growth path adds raw
   paths (e.g. `.opencode/STANDARDS.md`) bypassing the filters `swarm_paths_for_item` applies, so a
   meta file re-enters a lease mid-flight. Filter on growth too.
7. **Tighten the base path-scrape** (`swarm_paths_for_item`): never lease bare **directories** (prefix
   overlap on a dir locks a whole subtree → the observed `apps/portal/lib/` deadlock), and require an
   extension or an existing path so prose fragments (`sentiment/ratings/…`) stop becoming phantom leases.
8. **"main advanced" bus notification** (the one safe pub/sub use). Coordinator broadcasts
   `main advanced → <sha>` on the bus; a worker can rebase its WORKING branch early. Notification →
   deterministic rebase, NOT agents reasoning over the bus. (Avoid mid-flight rebase while an agent is
   editing — the merge-time rebase already covers the critical case.)
9. **Remove the dead `_merge_real`** (or make it canonical). Now that `merge_if_ready` has the rebase
   queue, `_merge_real` in `swarm-run.sh` is redundant dead code — delete to avoid the two-designs
   confusion that caused this whole thread.
10. **Lighter overseer option for cost** — Opus is orchestrator-only (correct); offer Sonnet/DeepSeek
    overseer for cheap long runs (`ace keys`). The ~35-min implement floor is Opus coordinating; a
    lighter overseer lifts it.

**Before the next big feature push:** live-validate PR #7 + #8 on ONE real swarm run — first re-plan
trading-portal's 74 pre-fix items for disjointness, then run measured (watch the new merged-check
status + the merge-queue rebase logs). Confirm the bookkeeping fix + rebase queue land before building
#1–#3 on top.

**Reality check (honest):** even fully fixed, 6 workers hit ~⅕ the throughput of ONE sequential loop
in this run; the merge-lock + shared gate cap the ceiling. The swarm wins only when features are
genuinely independent AND the gate is fast + hermetic. Measure swarm-vs-single before investing more
in swarm complexity.
