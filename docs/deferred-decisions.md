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
