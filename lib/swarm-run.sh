#!/usr/bin/env bash
# swarm-run.sh — coordinator + worker for ACE's parallel loop.
#
# Coordinator spawns up to SWARM_MAX resource-aware workers. Each worker:
#   swarm_next (claim a path-disjoint ROADMAP item) → git worktree off main →
#   run the item (DRY: simulated edit; LIVE: filtered-ROADMAP + MAX_FEATURES=1
#   auto-loop) → merge via the serialized merge queue → coordinator ticks the
#   REAL ROADMAP → release lease + drop worktree → next.
#
# Modes:
#   DRY_RUN=1 (default)  — simulated edits on a throwaway repo (`sandbox`), or a
#                          real repo without launching opencode. ZERO credits.
#   DRY_RUN=0 SWARM_LIVE=1 — the real loop (opencode + gh). Spends credits.
#                            Refuses unless SWARM_LIVE=1 (guard against accidents).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/swarm.sh"
. "$HERE/report.sh" 2>/dev/null || true   # ace_report — file parked items as triageable issues

REPO="${SWARM_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"
MAIN="${SWARM_MAIN:-main}"
# S3 worker ceiling (B4): 3–5 workers is the evidence-backed max — past that, coordination + the
# SERIAL merge step (Amdahl) dominate and integration risk climbs without proportional speedup. This
# is a hard, mechanical floor-of-safety (P8) even if a user forces SWARM_MAX high; NEVER 6+ workers.
SWARM_CEIL="${SWARM_CEIL:-5}"
MAX="${SWARM_MAX:-2}"; MAX="${MAX//[!0-9]/}"; [ -z "$MAX" ] && MAX=2   # default 2 workers; sanitize a non-numeric request
_SWARM_REQ="$MAX"                                                     # raw request, so swarm_run can log a ceiling clamp
[ "$MAX" -gt "$SWARM_CEIL" ] && MAX="$SWARM_CEIL"                     # cap at the ceiling
[ "$MAX" -lt 1 ] && MAX=1
DRY_RUN="${DRY_RUN:-1}"
LIVE="${SWARM_LIVE:-0}"
WT_ROOT="${SWARM_WT_ROOT:-}"
WATCH="${SWARM_WATCH:-0}"          # 1 = surface waiting/blocked/conflict to Telegram

# resource-aware worker cap: back off from MAX under CPU/mem pressure.
_allowed() {
  local n load avail a="$MAX"
  n="$(nproc 2>/dev/null || echo 4)"
  load="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)"
  avail="$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 8000000)"
  awk -v l="$load" -v n="$n" 'BEGIN{exit !(l > n*0.9)}' && a=$(( a>2 ? a-1 : a ))
  [ "$avail" -lt 2000000 ] && a=1
  [ "$a" -lt 1 ] && a=1; [ "$a" -gt "$MAX" ] && a="$MAX"
  echo "$a"
}

# ---- coexistence: make concurrent writes to shared tracked meta-files safe. ---
# lessons.md / changelog.md are append-only → union-merge auto-resolves. ROADMAP
# ticks are coordinator-owned (below), so flows never race on it.
swarm_apply_coexistence() {
  local repo="${1:-}"; [ -n "$repo" ] || repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  # the whole coexistence policy now lives in swarm-policy.sh (union + structured merge drivers,
  # lease-free stripping, post-merge regenerate) — one declarative table instead of hard-coded files.
  if command -v swarm_policy_apply >/dev/null 2>&1; then
    swarm_policy_apply "$repo"
  else   # fallback (policy module missing): the original union-only behavior
    local ga="$repo/.gitattributes"; touch "$ga"
    for f in ".opencode/lessons.md merge=union" ".opencode/memory/changelog.md merge=union"; do
      grep -qF "${f%% *}" "$ga" 2>/dev/null || echo "$f" >> "$ga"; done
    git -C "$repo" config merge.union.driver "git merge-file --union -L %O -L %A -L %B %A %O %B >/dev/null 2>&1 || cat %A %B > %A; true" 2>/dev/null || true
    echo "coexistence: union-merge on lessons.md + changelog.md; ROADMAP is coordinator-ticked"
  fi
}

# ---- work + merge -------------------------------------------------------------
_do_work() {
  local wt="$1" paths="$2" item="$3" wid="$4" hash="$5" p
  if [ "$DRY_RUN" = 1 ]; then
    for p in $paths; do [ "$p" = "." ] && p="SWARM_ROOT.txt"
      mkdir -p "$wt/$(dirname "$p")" 2>/dev/null
      printf 'swarm edit @%s :: %s\n' "$(_now)" "$item" >> "$wt/$p"
    done
    sleep "${SWARM_SIM_DELAY:-0}"   # hold the lease a measurable interval so a battle-test can audit concurrency
    git -C "$wt" add -A && git -C "$wt" commit -q -m "swarm(sim): $item" || true
    return 0
  fi
  # LIVE: hand auto-loop the CLAIMED item via SWARM_ITEM — no ROADMAP filtering, so
  # each flow ticks its OWN line (which merges cleanly with other flows' ticks).
  # MERGE_GATE=local → merge on ./ci.sh green (never wait on GitHub Actions, which
  # don't report on a private-no-Pro repo). AUTOMERGE=1 → auto-loop owns the full
  # implement→PR→gate→self-merge cycle; the swarm just coordinates leases + worktrees.
  # Flow identity (SWARM_WORKER/HASH/DIR) lets the opencode agents reach the swarm MCP.
  # short human slug for tagging telemetry ([w1·generate], events.jsonl feat=…)
  local feat; feat="$(printf '%s' "$item" | sed -E 's/^[0-9]+:[[:space:]]*- \[[ x]\] //; s/\*//g' | grep -oE '`[^`]+`' | head -1 | tr -d '`')"
  [ -n "$feat" ] || feat="$(printf '%s' "$item" | sed -E 's/^[0-9]+:[[:space:]]*- \[[ x]\] //; s/\*//g' | awk '{print $1, $2, $3}')"
  # #62: run the autoloop in the BACKGROUND with `exec` so $! is the autoloop's OWN pid — then the abandon
  # watcher (run_worker) can TERM exactly this process, whose cleanup trap commits WIP + kills opencode + exits.
  ( cd "$wt" && SWARM_WORKER="$wid" SWARM_HASH="$hash" SWARM_DIR="$SWARM_DIR" \
       SWARM_FEATURE="$feat" SWARM_RUNID="${RUNID:-}" \
       SWARM_ITEM="$item" MAX_FEATURES=1 AUTOMERGE=1 MERGE_GATE=local DEPLOY=0 \
       OPENCODE_DB="$SWARM_DIR/$wid.opencode.db" \
       exec bash "$REPO/scripts/auto-loop.sh" ) >>"$SWARM_DIR/$wid.log" 2>&1 &
  local _lp=$!; echo "$_lp" > "$SWARM_DIR/$wid.loop.pid" 2>/dev/null
  wait "$_lp" 2>/dev/null || true
  rm -f "$SWARM_DIR/$wid.loop.pid" 2>/dev/null
  # E4: each worker gets its OWN OpenCode session DB (OPENCODE_DB, verified present on 1.17.x) so concurrent
  # workers never write the SAME sqlite file (SQLITE_CORRUPT #14970/#14194 would poison E2's resume state).
  # Only the session DB is isolated — auth.json + config/plugins stay in the shared default dir, so no re-auth.
}

# _swarm_outcome_class LOG — why did a worker's item NOT land on main? Classify from the loop's log tail so
# the bus records the REAL reason (item 5) — a real merge conflict vs a RED gate vs a non-code stop — instead
# of the old blanket "conflict". Fail-open: an unreadable/ambiguous log → "incomplete" (honest: not-yet-merged).
_swarm_outcome_class() {
  local t; t="$(tail -n 80 "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
  case "$t" in
    *CONFLICT*|*"conflicts with main"*|*UNRESOLVABLE*|*conflict_resolver*)               echo conflict ;;
    *"reached without green"*|*"CI RED"*|*"LAUNCH RED"*|*"NO-GO"*|*"FAILS ./ci.sh"*)      echo gate-red ;;
    *"limit hasn't reset"*|*"usage limit"*|*"rathole persisted"*|*"stopping for review"*|*"STOPPING:"*) echo stopped ;;
    *) echo incomplete ;;
  esac
}

# DRY merge: local no-ff into main (clean by disjointness). For the sandbox.
_merge_dry() {
  git -C "$REPO" checkout -q "$MAIN" || return 2
  git -C "$REPO" merge --no-ff --no-edit -q "$1" && return 0
  git -C "$REPO" merge --abort 2>/dev/null; return 1
}

# coordinator-owned ROADMAP tick — flows never edit ROADMAP, so no race. Ticks
# the matching open item on the real main after its PR merged.
_tick_roadmap() {
  local item="$1" esc
  esc="$(printf '%s' "$item" | sed -e 's/[\/&]/\\&/g' -e 's/[][().*+?^$|]/\\&/g')"
  git -C "$REPO" fetch -q origin "$MAIN" && git -C "$REPO" checkout -q "$MAIN" && git -C "$REPO" pull -q --ff-only 2>/dev/null || true
  if grep -qE "^[[:space:]]*- \[ \] .*$esc" "$REPO/ROADMAP.md" 2>/dev/null; then
    sed -i -E "0,/^([[:space:]]*)- \[ \] (.*$esc)/s//\1- [x] \2/" "$REPO/ROADMAP.md"
    git -C "$REPO" commit -q -am "chore(swarm): tick '${item:0:50}'" && git -C "$REPO" push -q origin "$MAIN" || true
  fi
  # post-merge, serialized here (under the merge lock): regenerate any derived file (lockfiles)
  # whose manifest moved in the just-merged commit, so main stays coherent without text-merging it.
  command -v swarm_policy_regenerate >/dev/null 2>&1 && swarm_policy_regenerate "$REPO" "$MAIN" || true
  # fold the just-merged worker's per-branch lessons/<branch>.md shard into the canonical
  # .opencode/lessons.md on main (S6 one-file-per-worker), then publish it — the planner reads it.
  if command -v swarm_aggregate_lessons >/dev/null 2>&1; then
    swarm_aggregate_lessons "$REPO"
    if ! git -C "$REPO" diff --quiet -- .opencode/lessons.md 2>/dev/null; then
      git -C "$REPO" commit -q -m "chore(swarm): aggregate lessons after merge" -- .opencode/lessons.md 2>/dev/null \
        && git -C "$REPO" push -q origin "$MAIN" 2>/dev/null || true
    fi
  fi
}

run_worker() {
  local wid="w$1" res item hash paths branch wt base_ref
  while :; do
    # operator controls from `ace swarm dash` (or `ace swarm pause/drain/kill`):
    [ -f "$SWARM_DIR/control.kill-$wid" ] && { swarm_post "$wid" idle "killed by operator" ; rm -f "$SWARM_DIR/control.kill-$wid"; break; }
    [ -f "$SWARM_DIR/control.drain" ]     && { swarm_post "$wid" idle "drain — claiming no new work"; break; }
    while [ -f "$SWARM_DIR/control.pause" ]; do sleep 3; [ -f "$SWARM_DIR/control.kill-$wid" ] && break 2; done
    # #61: a peer detected the shared provider cap — HOLD at the claim boundary (don't start a fresh item that
    # would just hit the cap too) while the flag is FRESH. A stale flag (all cappers gone / reset) is ignored so
    # this can never wedge. The capped worker itself keeps waiting inside its autoloop (cheap poll, resumes).
    if [ -f "$SWARM_DIR/provider-capped" ]; then
      swarm_post "$wid" standby "provider capped — holding for reset" ""
      while [ -f "$SWARM_DIR/provider-capped" ]; do
        [ "$(( $(date +%s) - $(stat -c %Y "$SWARM_DIR/provider-capped" 2>/dev/null || echo 0) ))" -gt "$(( 3 * ${CLAUDE_POLL:-120} ))" ] && { rm -f "$SWARM_DIR/provider-capped" 2>/dev/null; break; }
        { [ -f "$SWARM_DIR/control.kill-$wid" ] || [ -f "$SWARM_DIR/control.drain" ]; } && break 2
        sleep "${CLAUDE_POLL:-120}"
      done
    fi
    # item 3: RED-main circuit breaker — don't claim new work onto a RED main. The elected FIXER keeps going to
    # repair it; every other worker HOLDS (bounded) for GREEN, then claims fresh work on the recovered main.
    # This is what "others rebase on last-green" reduces to under one shared main: hold, then the merge queue
    # rebases the next item onto the now-GREEN tip. Fail-safe: prolonged RED → the worker exits cleanly (no dogpile).
    if [ -f "$SWARM_DIR/main-red" ] && [ "$(cat "$SWARM_DIR/fixer" 2>/dev/null)" != "$wid" ]; then
      local _rw=0 _cap="${SWARM_REDMAIN_WAIT:-120}"
      swarm_post "$wid" standby "main is RED — holding for the fixer to restore GREEN" ""
      while [ -f "$SWARM_DIR/main-red" ] && [ "$(cat "$SWARM_DIR/fixer" 2>/dev/null)" != "$wid" ]; do
        { [ -f "$SWARM_DIR/control.kill-$wid" ] || [ -f "$SWARM_DIR/control.drain" ]; } && break
        _rw=$((_rw+1)); [ "$_rw" -ge "$_cap" ] && { swarm_post "$wid" idle "main RED > $((_cap*5))s — exiting; re-run once green"; break 2; }
        sleep 5
      done
      [ -f "$SWARM_DIR/main-red" ] || swarm_post "$wid" acquired "main GREEN again — resuming" ""
    fi
    res="$(swarm_next "$wid" "$REPO/ROADMAP.md")"
    [ -z "$res" ] && { swarm_post "$wid" idle "nothing claimable — exit"; break; }
    hash="${res%%$'\t'*}"; item="${res#*$'\t'}"
    paths="$(swarm_paths_for_item "$item")"
    swarm_post "$wid" claimed "$item ⟨$paths⟩" "$item"
    # RUNID makes the branch unique per run → it can NEVER collide with a leftover
    # swarm/* branch (which the auto-loop would mistake for a "pending PR to resume"
    # and burn a whole lap resolving — the junk-PR churn from the 10h run).
    branch="swarm/${RUNID:-r}-$wid-$hash"; wt="$WT_ROOT/$wid-$hash"
    rm -rf "$wt"
    # Base the worktree on the FRESH remote tip, not stale local main — otherwise a
    # worker opens behind origin/main and its pre-commit changelog hook regenerates
    # from a shorter history, reverting main's entries (near-miss data loss in the run).
    git -C "$REPO" fetch -q origin "$MAIN" 2>/dev/null || true
    base_ref="$MAIN"; git -C "$REPO" rev-parse -q --verify "origin/$MAIN" >/dev/null 2>&1 && base_ref="origin/$MAIN"
    if ! git -C "$REPO" worktree add -q -b "$branch" "$wt" "$base_ref" 2>/dev/null; then
      swarm_post "$wid" error "worktree add failed" "$item"; swarm_release "$wid" "$hash" error; continue
    fi
    rm -f "$SWARM_DIR/control.abandon-$wid-$hash" 2>/dev/null   # fresh claim — clear any stale abandon signal
    ( while :; do swarm_beat "$wid" "$hash"; sleep "${SWARM_BEAT:-30}"; done ) & local bpid=$!
    # #62: abandon-watcher — if the coordinator re-assigns this item (reap/reconcile wrote control.abandon-*),
    # TERM our autoloop so we stop working an item a new owner now holds (its cleanup trap commits WIP first).
    # Guarantees at-most-one-live-worker-per-item (I1). No-op in DRY (no loop.pid) and when never abandoned.
    ( while sleep 5; do
        [ -f "$SWARM_DIR/control.abandon-$wid-$hash" ] || continue
        alp="$(cat "$SWARM_DIR/$wid.loop.pid" 2>/dev/null)"; [ -n "$alp" ] && kill -TERM "$alp" 2>/dev/null; break
      done ) & local apid=$!
    _do_work "$wt" "$paths" "$item" "$wid" "$hash"
    kill "$apid" "$bpid" 2>/dev/null
    if [ -f "$SWARM_DIR/control.abandon-$wid-$hash" ]; then
      # re-assigned mid-flight → DROP: the new owner holds the claim now, so do NOT merge and do NOT release
      # (that would clobber the new owner's active claim — see swarm_release's worker-guard).
      swarm_post "$wid" abandoned "reassigned mid-flight — dropped: $item" "$item"
      rm -f "$SWARM_DIR/control.abandon-$wid-$hash" 2>/dev/null
    else
      swarm_post "$wid" merging "$item" "$item"
      local ok=1
      if [ "$DRY_RUN" = 1 ]; then
        with_merge_lock _merge_dry "$branch" || ok=0
      else
        # LIVE: the auto-loop opens + local-gates + SELF-MERGES a feat/<slug> PR (NOT this swarm/* worktree
        # branch), and ticks the item in ROADMAP.md inside that PR. So the robust merged-signal is: the item's
        # checkbox is now [x] on origin/main. (The old --head "$branch" check queried the never-PR'd swarm/*
        # branch → always empty → every merged item was mislabelled "conflict" and re-worked.)
        git -C "$REPO" fetch -q origin "$MAIN" 2>/dev/null || true
        if git -C "$REPO" show "origin/$MAIN:ROADMAP.md" 2>/dev/null | grep -Fq -- "$item" \
           && git -C "$REPO" show "origin/$MAIN:ROADMAP.md" 2>/dev/null | grep -F -- "$item" | grep -qE '^[[:space:]]*- \[[xX]\]'
        then ok=1; else ok=0; fi
      fi
      if [ "$ok" = 1 ]; then
        swarm_post "$wid" done "$item" "$item"; swarm_release "$wid" "$hash" done
        # Tick the REAL ROADMAP on main (serialized via the merge lock) so a merged
        # item is never re-selected — the root of the repeated VERIFY-ONLY no-ops.
        [ "$DRY_RUN" = 1 ] || with_merge_lock _tick_roadmap "$item"
      else
        local _oc; _oc="$(_swarm_outcome_class "$SWARM_DIR/$wid.log")"   # item 5: classify WHY it didn't land
        swarm_post "$wid" "$_oc" "$_oc → $([ "$_oc" = conflict ] && echo conflict_resolver || echo requeue): $item" "$item"
        swarm_release "$wid" "$hash" "$_oc"
      fi
    fi
    # Preserve this worker's run artefacts BEFORE `worktree remove` deletes .opencode/ — solo runs persist these,
    # but a swarm worker's metrics/post-mortems are worktree-local + gitignored and would vanish. CSVs are
    # concatenated (header-dedup, run-tagged rows); text post-mortems get an item banner. (subagent_report already
    # unions the per-worker DBs centrally, so this preserves the per-phase-timings + F4-quality half.)
    if [ -d "$wt/.opencode" ]; then
      local _wo="$SWARM_DIR/workers/$wid" _art; mkdir -p "$_wo" 2>/dev/null
      for _art in metrics.csv quality-metrics.csv; do
        [ -f "$wt/.opencode/$_art" ] || continue
        [ -f "$_wo/$_art" ] || head -1 "$wt/.opencode/$_art" > "$_wo/$_art" 2>/dev/null
        tail -n +2 "$wt/.opencode/$_art" >> "$_wo/$_art" 2>/dev/null || true
      done
      for _art in run-summary.txt token-report.md; do
        [ -f "$wt/.opencode/$_art" ] && { printf '\n===== %s =====\n' "$item"; cat "$wt/.opencode/$_art"; } >> "$_wo/$_art" 2>/dev/null || true
      done
    fi
    git -C "$REPO" worktree remove -f "$wt" 2>/dev/null
    git -C "$REPO" branch -D "$branch" 2>/dev/null
  done
}

# swarm_watch — surface the messages that need a human to Telegram (via hermes).
swarm_watch() {
  swarm_init; local last line typ
  # start at the CURRENT end of the bus — only alert on NEW events. Starting at 0 replayed the entire
  # message history to Telegram every time the watcher (re)started.
  last="$(wc -l < "$MSG" 2>/dev/null | tr -dc 0-9)"; last="${last:-0}"
  echo "swarm-watch: tailing bus → Telegram (waiting/blocked/conflict/needs-attention)"
  while :; do
    line="$(tail -n +$((last+1)) "$MSG" 2>/dev/null)"; [ -z "$line" ] && { sleep 5; continue; }
    while IFS= read -r m; do
      [ -z "$m" ] && continue; last=$((last+1))
      typ="$(printf '%s' "$m" | jq -r '.type' 2>/dev/null)"
      case "$typ" in waiting|blocked|conflict|needs-attention|defer)
        command -v hermes >/dev/null && \
          printf '🐝 swarm: %s\n' "$(printf '%s' "$m" | jq -r '"[\(.from)] \(.type): \(.body)"')" \
          | hermes send --to "${HERMES_TO:-telegram}" - >/dev/null 2>&1 || true ;;
      esac
    done <<< "$line"
    sleep 3
  done
}

# clean a reclaimed item's worktree + branch by hash (glob over worker ids).
_clean_hash() {
  local h="$1" w b
  for w in "$WT_ROOT/"*"-$h"; do [ -d "$w" ] && git -C "$REPO" worktree remove -f "$w" 2>/dev/null; done
  for b in $(git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/swarm/*-$h" 2>/dev/null); do
    git -C "$REPO" branch -D "$b" 2>/dev/null; done
}

# reaper — periodically reclaim leases whose worker went silent; clean their
# worktree; alert on PARK. Runs beside the workers; killed when they drain.
_reaper() {
  local R="${SWARM_REAP_INTERVAL:-60}" act h it
  while :; do
    sleep "$R"
    while IFS=$'\t' read -r act h it; do
      [ -z "$act" ] && continue
      _clean_hash "$h"
      if [ "$act" = PARK ]; then
        swarm_post reaper needs-attention "PARKED after $MAX_TRIES tries: $it" "$it"
        command -v hermes >/dev/null && printf '🐝 swarm PARKED (needs you): %s\n' "$it" | hermes send --to "${HERMES_TO:-telegram}" - >/dev/null 2>&1 || true
        # file it as a triageable issue (same channel as ratholes) so the ROOT
        # cause — bad spec, impossible acceptance, or a swarm/tooling bug — gets fixed
        command -v ace_report >/dev/null 2>&1 && \
          ace_report swarm-blocked repo "swarm parked: $it" "failed $MAX_TRIES flow attempts (crash/hang/merge) — likely a bad spec, unmet acceptance, or a coordination bug" || true
      else
        swarm_post reaper reap "reclaimed a dead flow's lease → requeued: $it" "$it"
      fi
    done < <(swarm_reap)
  done
}

# prune leftovers from prior runs: close junk resume PRs + delete every stale
# swarm/* branch (local+remote). Without this the auto-loop's resume logic finds
# old open PRs on colliding branch names and burns full conflict-resolution laps
# on corrupt-ROADMAP-stub junk (the biggest waste in the 10h run).
_prune_stale_swarm() {
  local slug b pr
  slug="$(cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || true
  git -C "$REPO" worktree prune 2>/dev/null || true
  for b in $(git -C "$REPO" for-each-ref --format='%(refname:short)' 'refs/heads/swarm/*' 2>/dev/null); do
    git -C "$REPO" branch -D "$b" >/dev/null 2>&1 && echo "  pruned local $b" >&2; done
  [ -n "$slug" ] || return 0
  command -v gh >/dev/null || return 0
  gh pr list --repo "$slug" --state open --json number,headRefName,title --limit 200 2>/dev/null \
    | jq -rc '.[] | select((.headRefName|startswith("swarm/")) or (.title|startswith("chore(resume)"))) | "\(.number)\t\(.headRefName)"' 2>/dev/null \
    | while IFS=$'\t' read -r pr b; do
        [ -n "$pr" ] && gh pr close "$pr" --repo "$slug" --delete-branch >/dev/null 2>&1 \
          && echo "  closed junk PR #$pr ($b)" >&2; done
  git -C "$REPO" ls-remote --heads origin 'swarm/*' 2>/dev/null | awk '{sub(/refs\/heads\//,"",$2); print $2}' \
    | while read -r b; do [ -n "$b" ] && git -C "$REPO" push -q origin --delete "$b" >/dev/null 2>&1 \
        && echo "  deleted stale remote $b" >&2; done
  # GC the auto-loop's own feat/* branches once MERGED into main (they pile up across a long run).
  git -C "$REPO" fetch -q origin "$MAIN" 2>/dev/null || true
  for b in $(git -C "$REPO" branch --merged "origin/$MAIN" --format='%(refname:short)' 2>/dev/null | grep -E '^feat/'); do
    git -C "$REPO" branch -D "$b" >/dev/null 2>&1 && echo "  gc'd merged local $b" >&2; done
  for b in $(git -C "$REPO" branch -r --merged "origin/$MAIN" --format='%(refname:short)' 2>/dev/null | sed 's,^origin/,,' | grep -E '^feat/'); do
    git -C "$REPO" push -q origin --delete "$b" >/dev/null 2>&1 && echo "  gc'd merged remote feat/$b" >&2; done
}

# ---- B2: batch → drain → re-plan (plan-time conflict-aware scheduling) ---------
# _swarm_plan_sync — the OBJECTIVES → ROADMAP planning pass, extracted so the batch loop can (re)invoke
# it between generations. Runs on YOUR model (no downgrade); if it hits a usage limit it WAITS for reset.
# SYNCHRONOUS by design: it runs with NO workers active, so it never races the coordinator's working tree
# against the workers' ROADMAP ticks. The inner sync_objectives is mtime-guarded, so a re-call once
# objectives are already covered is a fast no-op — safe to invoke each generation.
_swarm_plan_sync() {
  echo "  planning: syncing OBJECTIVES → ROADMAP on your model (waits on a limit; SWARM_SYNC=0 to skip)…"
  ( cd "$REPO" && LOOP_SYNC_ONLY=1 PLAN=1 AUTOMERGE=1 MERGE_GATE=local DEPLOY=0 \
      bash "$REPO/scripts/auto-loop.sh" ) >>"$SWARM_DIR/coordinator.log" 2>&1 \
    || echo "  planning: sync ended (see coordinator.log) — proceeding with the current ROADMAP"
  # the planner opens a chore/plan PR but (per "never merge your own PR") leaves it open, and
  # LOOP_SYNC_ONLY exits before the loop's merge step — so the COORDINATOR lands it here, else the
  # decomposed tasks never reach main and workers have nothing new to claim.
  local _slug _ppr; _slug="$(cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  _ppr="$(gh pr list --repo "$_slug" --head chore/plan --state open --json number -q '.[0].number' 2>/dev/null)"
  if [ -n "$_ppr" ]; then
    echo "  planning: merging plan PR #$_ppr (decomposed tasks → main)"
    gh pr merge "$_ppr" --repo "$_slug" --squash --admin --delete-branch >/dev/null 2>&1 \
      || gh pr merge "$_ppr" --repo "$_slug" --squash --delete-branch >/dev/null 2>&1 || true
  fi
  git -C "$REPO" fetch -q --prune origin "$MAIN" 2>/dev/null
  git -C "$REPO" checkout -q "$MAIN" 2>/dev/null && git -C "$REPO" reset -q --hard "origin/$MAIN" 2>/dev/null || true
}

# _swarm_should_plan GEN — should this generation (re)plan? Gen 1: yes, when sync is enabled and
# OBJECTIVES has open goals (the original single upfront pass). Gen > 1: only when the path-disjoint
# claimable batch has DRAINED below the re-plan floor (SWARM_REPLAN_MIN, default = the ceiling) — so a
# freshly-added objective or a deferred slice gets decomposed, but we do NOT re-run the ~14-min sync per
# item. Returns 0 (plan) / 1 (skip).
_swarm_should_plan() {
  local gen="$1" dj floor
  [ "$DRY_RUN" != 1 ] || return 1
  [ "${SWARM_SYNC:-1}" = 1 ] || return 1
  [ -f "$REPO/OBJECTIVES.md" ] || return 1
  grep -qE '^[[:space:]]*- \[ \] ' "$REPO/OBJECTIVES.md" 2>/dev/null || return 1
  [ "$gen" -le 1 ] && return 0
  dj="$(swarm_disjoint_batch "$REPO/ROADMAP.md" "${SWARM_CEIL:-5}" 2>/dev/null || echo 99)"
  case "$dj" in ''|*[!0-9]*) dj=99 ;; esac
  floor="${SWARM_REPLAN_MIN:-${SWARM_CEIL:-5}}"; case "$floor" in ''|*[!0-9]*) floor="${SWARM_CEIL:-5}" ;; esac
  [ "$dj" -lt "$floor" ]
}

# _swarm_emit_batch_plan CAP — state the plan-time conflict-aware batch plan (which items run in parallel,
# which SERIALIZE because they share a file, which are dep-BLOCKED) to the coordinator log + a run artifact
# BEFORE dispatch. This is the mechanical, race-free form of the planner prompt's "state the batch plan
# before dispatch": it does NOT write the tracked ROADMAP.md (workers own its ticks — writing it here would
# race them), so it is pure telemetry. Fail-open: any error is swallowed and dispatch proceeds.
_swarm_emit_batch_plan() {
  local cap="$1" plan npar nser nblk
  plan="$(swarm_disjoint_plan "$REPO/ROADMAP.md" "$cap" 2>/dev/null)" || return 0
  [ -n "$plan" ] || return 0
  { printf 'swarm batch plan @%s (cap=%s):\n' "$(date -u +%FT%TZ)" "$cap"; printf '%s\n' "$plan"; } \
    > "$SWARM_DIR/batch-plan.txt" 2>/dev/null || true
  npar="$(printf '%s\n' "$plan" | grep -c '^parallel')"
  nser="$(printf '%s\n' "$plan" | grep -c '^serialize')"
  nblk="$(printf '%s\n' "$plan" | grep -c '^blocked')"
  echo "  batch plan: $npar parallel · $nser serialized (share a file) · $nblk dep-blocked  (→ $SWARM_DIR/batch-plan.txt)"
}

swarm_run() {
  swarm_init; WT_ROOT="${WT_ROOT:-$SWARM_DIR/worktrees}"; mkdir -p "$WT_ROOT"
  # record the TRUE coordinator pid (== its process-group id under setsid) so the start-guard and
  # `ace swarm stop` are scoped to THIS project and can group-kill the whole tree. Not for dry runs.
  [ "$DRY_RUN" != 1 ] && [ -n "$SWARM_DIR" ] && echo $$ > "$SWARM_DIR/coordinator.pid"
  if [ "$DRY_RUN" != 1 ] && [ "$LIVE" != 1 ]; then
    echo "REFUSING live run: set SWARM_LIVE=1 to spend credits on the real loop." >&2; return 2
  fi
  RUNID="${SWARM_RUNID:-$(date +%y%m%d-%H%M%S)}"   # unique per run → branches never collide with leftovers
  [ "$DRY_RUN" != 1 ] && printf '%s\n' "$RUNID" > "$SWARM_DIR/.runid" 2>/dev/null || true   # so the NEXT run can archive this one by its start-datetime
  [ "$DRY_RUN" != 1 ] && swarm_apply_coexistence "$REPO" >&2
  [ "$DRY_RUN" != 1 ] && _prune_stale_swarm
  # self-heal on start: reclaim leftover leases from a crashed prior run + prune.
  while IFS=$'\t' read -r _ h it; do [ -n "$h" ] && { _clean_hash "$h"; echo "  reconcile: requeued '$it'"; }; done < <(swarm_reconcile)
  git -C "$REPO" worktree prune 2>/dev/null || true
  rm -f "$SWARM_DIR/main-red" "$SWARM_DIR/fixer" 2>/dev/null || true   # item 3: never inherit a prior run's RED-main standdown (a genuine RED main re-latches on the first merge)
  rm -f "$SWARM_DIR"/control.abandon-* "$SWARM_DIR"/*.loop.pid "$SWARM_DIR"/provider-capped 2>/dev/null || true   # #62/#61: never inherit stale abandon signals, worker pids, or a provider-cap hold from a prior run
  local allowed; allowed="$(_allowed)"
  printf '%s🐝 swarm%s %s%s/%s workers%s %s· live=%s dry=%s · %s · self-heal TTL=%ss tries=%s%s\n' \
    "${_B:-}${_PUR:-}" "${_R:-}" "${_GRN:-}" "$allowed" "$MAX" "${_R:-}" "${_MUT:-}" "$LIVE" "$DRY_RUN" "$(basename "$REPO")" "${LEASE_TTL}" "${MAX_TRIES}" "${_R:-}"
  echo "  watch: ace swarm dash  ·  columns: ace swarm split  ·  controls: pause|drain|kill wN"
  # Ctrl-C / TERM: stop the whole fleet cleanly. Backgrounded workers ignore terminal SIGINT (no job
  # control in a script), so we signal them explicitly: TERM the worker loops → each autoloop's cleanup
  # preserves in-flight WIP + kills its opencode subtree → wait → force-kill stragglers.
  [ "$WATCH" = 1 ] && { swarm_watch & echo "  watcher pid $!"; }
  trap _swarm_trap INT TERM
  _reaper & _RPID=$!
  _WPIDS=""
  # BATCH → DRAIN → RE-PLAN (B2 phase 2): each GENERATION (re)plans OBJECTIVES→ROADMAP only when warranted
  # (_swarm_should_plan — so the ~14-min Opus sync doesn't re-run per item), states the conflict-aware batch
  # plan, clamps workers to the PATH-DISJOINT claimable set (reusing swarm_disjoint_batch), spawns them, and
  # waits for the batch to DRAIN. Planning is synchronous (no workers active during it) so it never races
  # their ROADMAP ticks. Bounded by SWARM_MAX_BATCHES + a no-progress guard → for the common case
  # (objectives decomposed up front) it is exactly ONE generation (identical to the prior single-shot run).
  local _maxbatch="${SWARM_MAX_BATCHES:-6}" _gen=0 _dj _before _after
  case "$_maxbatch" in ''|*[!0-9]*) _maxbatch=6 ;; esac
  [ "$DRY_RUN" = 1 ] && _maxbatch=1                       # sandbox/dry: one generation over the fixed ROADMAP
  while [ "$_gen" -lt "$_maxbatch" ]; do
    _gen=$((_gen+1))
    if _swarm_should_plan "$_gen"; then
      [ "$_gen" -gt 1 ] && echo "  re-plan (batch $_gen): path-disjoint claimable set drained below floor — topping up ROADMAP"
      _swarm_plan_sync
    fi
    # S3 clamp: allowed = min(requested→ceiling, resource-aware, path-disjoint-claimable-now). Fail-open:
    # any error in the disjoint scan leaves `allowed` unchanged. Log the ceiling clamp once (gen 1).
    allowed="$(_allowed)"
    [ "$_gen" = 1 ] && [ "${_SWARM_REQ:-$MAX}" -gt "$SWARM_CEIL" ] 2>/dev/null && \
      echo "  clamp: requested ${_SWARM_REQ} worker(s) → capped at ceiling $SWARM_CEIL (S3: 3–5 is the max)"
    _dj="$(swarm_disjoint_batch "$REPO/ROADMAP.md" "$allowed" 2>/dev/null || echo "$allowed")"
    if [ -n "$_dj" ] && [ "$_dj" -ge 1 ] 2>/dev/null && [ "$_dj" -lt "$allowed" ]; then
      echo "  clamp: $allowed worker(s) → $_dj ($_dj path-disjoint item(s) claimable now; more would idle/contend)"
      allowed="$_dj"
    fi
    _swarm_emit_batch_plan "$allowed"                      # state the batch plan (telemetry) BEFORE dispatch
    if [ -z "$_dj" ] || ! [ "$_dj" -ge 1 ] 2>/dev/null; then
      echo "  no path-disjoint claimable item — nothing to dispatch (batch $_gen)"; break
    fi
    echo "  spawning $allowed worker(s) (batch $_gen) — watch: ace swarm dash"
    _before="$(grep -cE '^[[:space:]]*- \[ \] ' "$REPO/ROADMAP.md" 2>/dev/null)"; _before="${_before:-0}"
    _WPIDS=""
    for i in $(seq 1 "$allowed"); do run_worker "$i" & _WPIDS="$_WPIDS $!"; done
    wait $_WPIDS 2>/dev/null
    # another generation only if there's more work AND this one made progress: stop on drain, in dry mode,
    # or when the generation ticked NOTHING (remainder is parked/unclaimable → re-spawning would churn).
    [ "$DRY_RUN" = 1 ] && break
    [ -f "$SWARM_DIR/control.drain" ] && break
    _after="$(grep -cE '^[[:space:]]*- \[ \] ' "$REPO/ROADMAP.md" 2>/dev/null)"; _after="${_after:-0}"
    [ "$_after" -ge "$_before" ] 2>/dev/null && { echo "  batch $_gen made no progress — coordinator stopping"; break; }
  done
  kill "$_RPID" 2>/dev/null
  # all workers have finished (ROADMAP exhausted, or the operator chose finish/drain) → shut the
  # coordinator DOWN cleanly: drop the pidfile + any control files so the dash flips to "no swarm
  # running" immediately and nothing stale blocks the next start.
  rm -f "$SWARM_DIR/coordinator.pid" "$SWARM_DIR"/control.* 2>/dev/null
  swarm_post coordinator idle "swarm stopped — all workers finished their current tasks" 2>/dev/null || true
  echo "swarm: all workers finished — coordinator stopped"; swarm_status
}
_swarm_trap() {
  trap - INT TERM
  printf '\n%sswarm: stopping — workers preserving in-flight WIP on their branches, then terminating…%s\n' "${_GOLD:-}" "${_R:-}" >&2
  kill "${_RPID:-0}" 2>/dev/null                              # reaper
  pkill -TERM -f 'scripts/auto-loop.sh' 2>/dev/null || true   # worker loops → cleanup() commits WIP + kills opencode
  sleep 4                                                     # let those cleanup traps finish (the WIP commit)
  pkill -KILL -f 'scripts/auto-loop.sh' 2>/dev/null || true; pkill -KILL -f 'opencode run' 2>/dev/null || true
  local w; for w in ${_WPIDS:-}; do kill -KILL "$w" 2>/dev/null; done
  echo "swarm: stopped (in-flight WIP preserved as commits on the worker branches)." >&2
  exit 130
}

# ---- sandbox: full end-to-end proof on a throwaway repo, zero credits ---------
swarm_sandbox() {
  local d; d="$(mktemp -d)"
  export SWARM_DIR="$d/state"; export SWARM_REPO="$d/repo"; export SWARM_WT_ROOT="$d/wt"
  REPO="$SWARM_REPO"; WT_ROOT="$SWARM_WT_ROOT"; DRY_RUN=1; MAX="${MAX:-4}"
  git init -q -b main "$REPO"; cd "$REPO"
  git config user.email swarm@test; git config user.name swarm
  mkdir -p apps/portal/settings apps/portal/lib scripts packages/shared
  for f in apps/portal/settings/tls.ts apps/portal/lib/csrf.ts scripts/deploy.sh packages/shared/index.ts ci.sh; do
    mkdir -p "$(dirname "$f")"; echo "// $f" > "$f"; done
  cat > ROADMAP.md <<'EOF'
# ROADMAP
- [ ] owner-gate apps/portal/settings/tls.ts page
- [ ] harden scripts/deploy.sh env loading
- [ ] refactor packages/shared/index.ts exports
- [ ] ci.sh: ban destructive DB ops
- [ ] consolidate helpers in apps/portal/lib/csrf.ts
- [ ] add abort-controller to apps/portal/lib/csrf.ts mount-fetch
EOF
  git add -A && git commit -q -m init
  echo "=== sandbox repo: $REPO (6 items; two SHARE apps/portal/lib/csrf.ts) ==="
  SWARM_REPO="$REPO" SWARM_DIR="$SWARM_DIR" SWARM_WT_ROOT="$WT_ROOT" MAX="$MAX" swarm_run
  echo; echo "=== message bus ==="; swarm_tail 40
  echo; echo "=== assertions ==="
  local commits clean
  commits="$(git -C "$REPO" log --oneline | grep -c 'swarm(sim)')"
  echo "  merged sim-commits on main: $commits  (expect 6)"
  git -C "$REPO" fsck --full >/dev/null 2>&1 && clean=OK || clean=CORRUPT
  echo "  git integrity: $clean"
  [ "$commits" = 6 ] && [ "$clean" = OK ] && echo "  SANDBOX PASS ✓" || echo "  SANDBOX FAIL ✗"
  cd /
}

. "$HERE/swarm-dash.sh" 2>/dev/null || true   # dash renderer (guarded; won't auto-run when sourced)

# archive the PREVIOUS run's terminal output (per-worker feeds + bus + coordinator log) into a
# datetime-named folder, keep the last SWARM_ARCHIVE_KEEP (default 5), then start fresh. Lives under
# ~/.config/ace/swarm/<slug>/archive/ — OUTSIDE the repo, so it's never committed. Use these logs as
# raw material to improve each worker / the bus / ACE itself.
_archive_prev_run() {
  local keep="${SWARM_ARCHIVE_KEEP:-5}" runid adir
  # only archive if a prior run actually left output
  if [ -s "$SWARM_DIR/events.jsonl" ] || ls "$SWARM_DIR"/w*.log >/dev/null 2>&1; then
    runid="$(cat "$SWARM_DIR/.runid" 2>/dev/null)"
    [ -n "$runid" ] || runid="$(date -r "$SWARM_DIR/events.jsonl" +%y%m%d-%H%M%S 2>/dev/null)"
    [ -n "$runid" ] || runid="run-$(date +%y%m%d-%H%M%S)"
    adir="$SWARM_DIR/archive/$runid"; mkdir -p "$adir"
    cp -f "$SWARM_DIR"/coordinator.log "$SWARM_DIR"/events.jsonl "$SWARM_DIR"/messages.jsonl "$adir/" 2>/dev/null || true
    cp -f "$SWARM_DIR"/w*.log "$adir/" 2>/dev/null || true
    ( cd "$SWARM_DIR/archive" 2>/dev/null && ls -1dt -- */ 2>/dev/null | tail -n +"$((keep+1))" | tr -d '/' | xargs -r rm -rf ) || true
    echo "  archived previous run → $adir (keeping last $keep)"
  fi
  # fresh, per-run logs for the new run so each archive is exactly one run
  : > "$SWARM_DIR/events.jsonl" 2>/dev/null || true
  rm -f "$SWARM_DIR"/w*.log 2>/dev/null || true
}

# detached coordinator: background it, pidfile + log in the store; watch with `ace swarm dash`.
swarm_startd() {
  swarm_init
  # EXACTLY ONE coordinator PER PROJECT: key off THIS store's pidfile — NOT a global pgrep, which
  # matched every project's coordinator and falsely refused a start in a different repo (and, now
  # that a rate-limited coordinator waits alive for hours, lingered blocking new starts). Verify the
  # pid is actually our coordinator (guards a reused pid) and self-heal a stale pidfile.
  if [ -f "$SWARM_DIR/coordinator.pid" ]; then
    _cp="$(cat "$SWARM_DIR/coordinator.pid" 2>/dev/null)"
    if [ -n "$_cp" ] && kill -0 "$_cp" 2>/dev/null && grep -qa swarm-run "/proc/$_cp/cmdline" 2>/dev/null; then
      echo "swarm already running for this project (pid $_cp) — watch: ace swarm dash · to restart: ace swarm stop, then start"; return 0
    fi
    rm -f "$SWARM_DIR/coordinator.pid"   # stale (crashed) or reused pid → clear it and start clean
  fi
  rm -f "$SWARM_DIR"/control.* 2>/dev/null   # drop leftover control.{pause,drain,kill-wN} so they don't hit a fresh run
  _archive_prev_run                          # rotate the finished run's logs into archive/<datetime> (only now that we're really launching)
  : > "$SWARM_DIR/coordinator.log"   # fresh log per launch so a startup error is visible, not buried
  # setsid → the coordinator leads its OWN process group, so `ace swarm stop` can group-kill the
  # whole tree (reaper + workers + opencode). The coordinator writes its own (leader==pgid) pid on boot.
  setsid bash "$HERE/swarm-run.sh" start >>"$SWARM_DIR/coordinator.log" 2>&1 </dev/null &
  _cp=""; for _ in 1 2 3 4 5 6 7 8 9 10; do _cp="$(cat "$SWARM_DIR/coordinator.pid" 2>/dev/null)"; [ -n "$_cp" ] && break; sleep 0.3; done
  echo "swarm starting (detached) · pid ${_cp:-?} · log: $SWARM_DIR/coordinator.log"
  sleep 3   # give it a moment; if it died on startup, SHOW why instead of a silent 0-worker dash
  if [ -z "$_cp" ] || ! kill -0 "$_cp" 2>/dev/null; then
    echo "⚠ the coordinator exited during startup — last lines:"; tail -n 12 "$SWARM_DIR/coordinator.log" | sed 's/^/    /'
    return 1
  fi
  echo "swarm started · watch: ace swarm dash  ·  columns: ace swarm split  ·  stop: ace swarm stop"
}
swarm_stopd() {
  swarm_init
  systemctl --user stop ace-swarm.service 2>/dev/null || true
  rm -f "$SWARM_DIR"/control.* 2>/dev/null   # clear stale controls so a later start isn't sabotaged
  # graceful: TERM the coordinator's whole process GROUP (coordinator + reaper + workers + opencode)
  # so each autoloop cleanup preserves in-flight WIP + tears down its opencode subtree; wait a few
  # seconds; then force-KILL the group. -"$cp" targets the group (coordinator is a setsid leader).
  local cp; cp="$(cat "$SWARM_DIR/coordinator.pid" 2>/dev/null)"
  if [ -n "$cp" ] && kill -0 "$cp" 2>/dev/null; then
    kill -TERM -"$cp" 2>/dev/null || kill -TERM "$cp" 2>/dev/null
    sleep 4
    kill -KILL -"$cp" 2>/dev/null || kill -KILL "$cp" 2>/dev/null
  fi
  rm -f "$SWARM_DIR/coordinator.pid"
  # fallback sweep for anything the group-kill missed (a coordinator launched before setsid, or an
  # opencode that re-parented out of the group). Aggressive by design — `ace swarm stop` means stop.
  pkill -TERM -f "$HERE/swarm-run.sh start" 2>/dev/null || true
  pkill -TERM -f 'scripts/auto-loop.sh' 2>/dev/null || true
  sleep 2
  pkill -KILL -f 'scripts/auto-loop.sh' 2>/dev/null || true
  pkill -KILL -f 'opencode run' 2>/dev/null || true
  pkill -KILL -f "$HERE/swarm-run.sh start" 2>/dev/null || true
  echo "swarm stopped (in-flight WIP preserved as commits on the worker branches)"
}
# THE UNIFIED SCREEN: one tmux window — the forge COCKPIT (workflow boxes + stage pipeline)
# large on top, and a LIVE per-worker feed pane below each (the full coloured loop litany).
# Everything in one place: no more dash-here, tail-there. Falls back to the cockpit alone if
# tmux is missing.
swarm_dash_split() {
  swarm_init
  if ! command -v tmux >/dev/null 2>&1; then
    echo "tmux isn't installed — but you don't need it: 'ace swarm dash' already shows each" >&2
    echo "worker's live feed inline. Install tmux only if you want separate, independently-" >&2
    echo "scrollable OS panes per worker: sudo dnf install tmux  (Silverblue: use a toolbox)." >&2
    echo "Opening the unified dash instead…" >&2; sleep 2; swarm_dash; return
  fi
  local s="aceswarm" nmax i
  nmax="$(config_get SWARM_MAX 2>/dev/null || echo 2)"; nmax="${nmax//[!0-9]/}"; [ -z "$nmax" ] && nmax=2; [ "$nmax" -gt "${SWARM_CEIL:-5}" ] && nmax="${SWARM_CEIL:-5}"; [ "$nmax" -lt 1 ] && nmax=1   # match the S3 worker ceiling (no empty panes)
  tmux kill-session -t "$s" 2>/dev/null
  # pane 0 = the COCKPIT ONLY (boxes/pipeline/status; DASH_FEEDS=0 so feeds aren't doubled —
  # the live feeds live in the separate per-worker panes below).
  tmux new-session -d -s "$s" -n forge "DASH_FEEDS=0 SWARM_DIR='$SWARM_DIR' SWARM_REPO='$REPO' RUNID='${RUNID:-}' bash '$HERE/swarm-dash.sh' dash"
  # one live-feed pane per worker — tail -F follows even before the log file exists
  for i in $(seq 1 "$nmax"); do
    tmux split-window -t "$s" "printf '\033[1;35m⛧ swarm worker %s\033[0m  — live feed\n\033[2m(waiting for output…)\033[0m\n' '$i'; exec tail -F '$SWARM_DIR/w$i.log' 2>/dev/null"
  done
  tmux set-window-option -t "$s" main-pane-height 45% 2>/dev/null
  tmux select-layout -t "$s" main-horizontal   # cockpit big on top, worker feeds tiled below
  tmux select-pane -t "$s".0
  tmux set-option -t "$s" mouse on 2>/dev/null   # scroll/select panes with the mouse
  tmux attach -t "$s"
}

case "${1:-}" in
  start|run)  swarm_run ;;
  startd)     swarm_startd ;;
  stop)       swarm_stopd ;;
  dash)       swarm_dash ;;             # THE dash: one self-contained TUI — cockpit + per-worker LIVE feeds inline (no tmux)
  split)      swarm_dash_split ;;       # OPTIONAL: real tmux panes (independent scrollback/mouse per worker) — needs tmux
  cockpit)    DASH_FEEDS=0 swarm_dash ;; # boxes-only cockpit (no inline feeds) — used inside the tmux split's top pane
  sandbox)    swarm_sandbox ;;
  worker)     run_worker "${2:-1}" ;;
  watch)      swarm_watch ;;
  pause)      swarm_init; : > "$SWARM_DIR/control.pause"; echo "paused — workers hold before claiming (resume: ace swarm resume)" ;;
  resume)     swarm_init; rm -f "$SWARM_DIR/control.pause" "$SWARM_DIR/control.drain"; echo "resumed" ;;
  drain)      swarm_init; : > "$SWARM_DIR/control.drain"; echo "draining — workers finish the current item, then claim no new work" ;;
  kill)       swarm_init; : > "$SWARM_DIR/control.kill-${2:?usage: kill wN}"; echo "kill signal → ${2} (exits after its current item)" ;;
  stats)      swarm_stats ;;
  coexist)    swarm_apply_coexistence "${2:-$REPO}" ;;
  "" ) ;;
  *) echo "usage: swarm-run.sh {start|startd|stop|dash|split|sandbox|worker N|watch|coexist}" >&2; exit 2 ;;
esac
