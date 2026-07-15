# The autorun loop

`ace autorun` (alias `autoloop`) chains the whole pipeline and runs unattended. It writes
`scripts/auto-loop.sh` and drives it.

```
OBJECTIVES.md ──(roadmap empty?)──▶ PLANNER breaks the top objective into ROADMAP tasks
     ▲                                          │
     │ progress                  next ROADMAP item
     └────────────────◀──────────────┘
                       ▼
        opencode builds it (10-agent loop)          ◄ fresh session per feature
                       ▼
        push PR ▸ gate ── 🔴 ─▶ pull failed log ─▶ opencode fixes ROOT cause ─▶ push ─▶ re-gate
                          └─ 🟢 ─▶ merge_if_ready ─▶ squash-merge · delete branch · pull main
                                       ▼ refresh code-map · deploy + healthcheck · next item
```

## The merge gate

What "🟢" means depends on the [profile](profile.md)'s `merge_gate` (env `MERGE_GATE` overrides):

- **`remote`** (default) — wait for GitHub Actions to be all-green, then merge.
- **`local`** — run `./ci.sh --container` (the VPS-parity build) and merge on **its** authority,
  without waiting on Actions. Skips *waiting on CI* — but the loop still pushes a branch and opens a PR,
  so it **still needs a GitHub `origin` remote** ("local gate" ≠ "no remote").
- **`both`** — require **both** a green `./ci.sh --container` AND green GitHub Actions before merging
  (strictest; on a blocked-Actions lap it stops rather than vouching local-only).

The loop **self-merges** only when `auto_merge`/`AUTOMERGE=1`. With `auto_merge:false`/`AUTOMERGE=0` it opens
**one** PR and **stops** for your review (it does not keep building on the un-merged branch). It never merges
a conflicting PR — the `conflict_resolver` agent reconciles both sides first. A remote `origin` is required
either way; `ace autorun` refuses up front with *"no 'origin' remote"* if there isn't one.

## Confirmations — when (and whether) it pauses

Launched **headless** — `ace autorun --yes`, or any non-TTY launch (the Hermes-over-Telegram case) —
the loop takes its whole policy from the environment, prints it, and **auto-starts with no prompts**
(`--yes` sets `ACE_YES=1`, which forces headless even under a pty). In that mode:

- **`AUTOMERGE` defaults from the profile's `auto_merge`** (env `AUTOMERGE` overrides) — when on, once a PR
  is all-green and mergeable the loop **self-merges it with no confirmation** and rolls to the next item;
  when off it opens one PR and stops. The merge is performed by the loop *script*
  (`merge_if_ready` → `gh pr merge --squash --delete-branch`), **never by the agent** — which is exactly
  why the agent prompt can say "never merge your own PR" while self-merge still works.
- **`MAX_FEATURES` defaults to `3`** headless, then it stops (a safety cap). Pass `MAX_FEATURES=0` for
  unlimited; the detached `ace loop` service defaults to `0`.
- It still **stops rather than merge** on anything unsafe: a conflicting PR with auto-resolve off, an
  empty ROADMAP after `MAX_PLANS`, or a billing-blocked Actions run (raise the limit, or set
  `LOCAL_CI_FALLBACK=1` / `merge_gate=local`).

**To require a human OK before each merge**, launch with **`MERGE_APPROVAL=hermes`** (the conductor's
"ask me before each merge" option): the loop pauses before every merge, pings your chat, and waits for
`ace approve <tok> yes` — deny / timeout / no-channel leaves the PR open and stops. This is the **only**
thing that inserts a mid-loop confirmation; everything else runs unattended.

> The Hermes **conductor** still echoes the assembled `ace … --yes` line and asks you to confirm it
> **once** before launching — that's the chat skill being deliberate, not ACE blocking. After that, the
> loop is unattended (unless you chose `MERGE_APPROVAL=hermes`).

## Key behaviors

- **Preflight** confirms the right repo + branch and refuses a stale/wrong PR (`EXPECT_REPO` hard-guard).
- **Thinks harder** — agents apply the **3 Whys** (root-need) and a **pre-mortem** ("assume it's live
  and broke — why?") at implement/review.
- **Won't rat-hole** — a silent step is judged by a cheap model and bounded; a confirmed rat-hole is
  auto-fixed a capped number of times, then it stops and files a note (see below).
- **Budgets active work** — container builds/installs/compiles pause the per-step clock; a hard wall
  ceiling still bounds a truly stuck step.

All knobs are in [configuration.md](configuration.md).

## Memory & self-improvement — how it stops re-deriving
The loop carries forward what it learns so it doesn't re-solve the same pitfall or re-derive the same facts.
It's **context memory** (files the agents read/append), not model weights, and it's **per-repo** by default:

- **`.opencode/lessons.md`** — durable decisions/gotchas. The orchestrator **reads it before planning** ("so you
  never re-learn the same thing") and **SCRIBEs after each task** — one terse, deduped line per lesson; if a
  critic gated the change, a line naming the critic + gist. `compact_lessons` caps it (`LESSONS_MAX_LINES`, 200)
  and archives the overflow, so it never bloats every agent prompt.
- **`.opencode/project-facts.md`** — stable facts (stack, key paths, the gate command, the GitNexus `repo:`
  scoping rule) seeded at bootstrap and appended as the loop learns, so agents don't rediscover them each task.
- **`~/.config/ace/host-lessons/<os>.md`** — **cross-project** lessons the rathole supervisor records (stall →
  cheap-model judge → capped fix-retry), so a host-level trap solved in one repo is avoided in the next.
- **Warning dedup** — CI warnings harvested into `ROADMAP.md` are fingerprinted (message only, timestamps/branch
  stripped), so the *same* warning is never re-queued.
- **`ace brain`** — optional bridge: files host + repo lessons into **gbrain** so they're searchable across
  everything (brain-first), the one built-in way lessons cross project boundaries.

The boundary of self-improvement: the loop improves its **decisions** via these notes, but it does **not** rewrite
its own source. Fixes to ACE itself come from the **self-triage / inception pass** below — it files a GitHub issue
for a human, never edits ACE.

## Metrics & post-mortem — what ran, how long

Every run is timed so you can see where the time goes and improve. Two artifacts in `.opencode/`:

- **`metrics.csv`** — one row per phase, tagged with a `run_id` so it's filterable per run:
  `run_id,ts,branch,event,agent,label,wall_s,active_s,build_s,rc`. Events: `run_start`, `step` (each
  agent turn — `wall_s` total, `active_s` thinking, `build_s` slow deterministic work), `gate` (CI
  authority, `rc`=green/red), `merge`, `deploy`, `verify`, `janitor`, and a closing `run` summary row.
- **`run-summary.txt`** — a human post-mortem appended at the end of **every** run (clean end *or* a
  chat/Ctrl-C stop): wall clock, outcome counts, **time-by-phase** (where the run actually went), and the
  **5 slowest steps**.

```bash
ace loop stats        # print the post-mortems + point at the CSV
column -ts, .opencode/metrics.csv | less -S          # browse raw rows
awk -F, '$1=="<run_id>" && $4=="step"' .opencode/metrics.csv   # one run's agent steps
```

A one-line digest also prints in the loop's run report, and `metrics.csv`/`run-summary.txt` are preserved
across `ace resume`. Use them to spot the expensive phase (slow builds vs. agent thinking vs. CI waits) and
tune the [knobs](configuration.md) — `CI_SCOPE`, `OPENCODE_TIMEOUT`, `merge_gate`, `JANITOR_EVERY`.

## ACE self-triage (the inception pass) — files an issue, never edits ACE

When the rat-hole supervisor can't fix a step, it files a note to `~/.config/ace/ace-fixme.log` —
something ACE *itself* (the loop driver) should improve. At the start of `ace autorun`, if such
notes exist, it offers to **triage ACE first** (`FIX_ACE=1`).

This pass is **bounded and READ-ONLY**: it diagnoses the root cause in `lib/*.sh` and **files a
GitHub issue** on ACE's repo (root cause + proposed fix), then archives the note. It **never** edits
ACE's code, branches, commits, pushes, or opens a PR — a human reads the issue and changes ACE's
`main`. The autonomous loop can improve your *project*, but it can't write to ACE itself.

> The normal project loop still opens PRs in *your* repo as usual — only ACE's self-triage is
> issue-only.
