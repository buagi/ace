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
  # H6 Edit 2: if the claimed item carries 'Spec:' (+ 'AC:'), assemble a self-contained SLICE (§3 Scope + only
  # this increment's ACs + non-N/A C1/C5) into a gitignored cache file the implementer reads first — so the
  # right context is in the prompt even when the worker economizes reads. SPEC_SLICE=0 skips. Fail-open.
  if [ "${SPEC_SLICE:-1}" = 1 ]; then
    local _sp _ac _sl; _sp="$(printf '%s' "$item" | grep -oE 'Spec:[[:space:]]*[^ )]+\.md' | sed -E 's/^Spec:[[:space:]]*//')"
    _ac="$(printf '%s' "$item" | grep -oE 'AC:[[:space:]]*[A-Za-z0-9,-]+' | sed -E 's/^AC:[[:space:]]*//')"
    if [ -n "$_sp" ] && [ -f "$wt/$_sp" ]; then
      _sl="$wt/.opencode/cache/spec-slice.$(basename "$_sp" .md).md"; mkdir -p "$(dirname "$_sl")" 2>/dev/null
      swarm_spec_slice "$wt/$_sp" "$_ac" > "$_sl" 2>/dev/null || rm -f "$_sl"
    elif [ -n "$_sp" ]; then
      swarm_post "$wid" needs-attention "spec-slice: $_sp not in worktree — dispatching without a slice (fail-open)" "$item" 2>/dev/null || true
    fi
  fi
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
  local wid="w$1" res item hash paths branch wt base_ref _keep_branch _prior _resume
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
    branch="swarm/${RUNID:-r}-$wid-$hash"; wt="$WT_ROOT/$wid-$hash"; _keep_branch=0; _resume=0
    rm -rf "$wt"
    # Base the worktree on the FRESH remote tip, not stale local main — otherwise a
    # worker opens behind origin/main and its pre-commit changelog hook regenerates
    # from a shorter history, reverting main's entries (near-miss data loss in the run).
    git -C "$REPO" fetch -q origin "$MAIN" 2>/dev/null || true
    base_ref="$MAIN"; git -C "$REPO" rev-parse -q --verify "origin/$MAIN" >/dev/null 2>&1 && base_ref="origin/$MAIN"
    # #64: resume-on-reclaim — if a PRIOR attempt at THIS item (this run) left committed WIP on its swarm branch
    # (kept on an incomplete/abandoned outcome below), base this worktree on that WIP instead of fresh main, so the
    # autoloop builds on it rather than re-implementing from scratch (Opus is ~94% of cost). The merge queue still
    # rebases onto fresh main at land time, so a slightly-behind WIP base is safe.
    _prior="$(git -C "$REPO" for-each-ref --format='%(refname:short)' "refs/heads/swarm/${RUNID:-r}-*-$hash" 2>/dev/null | grep -vxF "$branch" | head -1)"
    if [ -n "$_prior" ] && [ "$(git -C "$REPO" rev-list --count "origin/$MAIN..$_prior" 2>/dev/null || echo 0)" -gt 0 ]; then
      base_ref="$_prior"; _resume=1
    fi
    if ! git -C "$REPO" worktree add -q -b "$branch" "$wt" "$base_ref" 2>/dev/null; then
      swarm_post "$wid" error "worktree add failed" "$item"; swarm_release "$wid" "$hash" error; continue
    fi
    if [ "$_resume" = 1 ]; then
      swarm_post "$wid" acquired "resuming prior WIP ($(git -C "$REPO" rev-list --count "origin/$MAIN..$_prior" 2>/dev/null || echo '?') commit(s)) for: $item" "$item"
      git -C "$REPO" branch -D "$_prior" 2>/dev/null   # superseded by our worktree's branch
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
      # #64: keep our WIP branch so the NEW owner resumes from it (the autoloop already committed WIP on TERM).
      [ "$DRY_RUN" != 1 ] && [ "$(git -C "$REPO" rev-list --count "origin/$MAIN..$branch" 2>/dev/null || echo 0)" -gt 0 ] && _keep_branch=1
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
        # #64: keep the branch if it has committed WIP so the re-claim resumes from it instead of re-implementing.
        [ "$DRY_RUN" != 1 ] && [ "$(git -C "$REPO" rev-list --count "origin/$MAIN..$branch" 2>/dev/null || echo 0)" -gt 0 ] && _keep_branch=1
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
    [ "${_keep_branch:-0}" = 1 ] || git -C "$REPO" branch -D "$branch" 2>/dev/null   # #64: keep the WIP branch so the next claimant resumes from it
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
# _land_plan_pr SLUG — land the coordinator-owned chore/plan PR and fast-forward the coordinator's main.
# The planner opens it but (per "never merge your own PR") leaves it open, and LOOP_SYNC_ONLY exits before
# the loop's merge step — so the COORDINATOR lands it here, else the decomposed tasks never reach main and
# workers have nothing to claim. --admin because the unattended swarm is the accepted operating mode for
# these coordinator-authored plan PRs (same as the OBJECTIVES→ROADMAP sync). Extracted so the re-slice pass
# reuses the identical path. Fail-open.
_land_plan_pr() {
  local slug="$1" ppr
  ppr="$(gh pr list --repo "$slug" --head chore/plan --state open --json number -q '.[0].number' 2>/dev/null)"
  if [ -n "$ppr" ]; then
    echo "  planning: merging plan PR #$ppr → main"
    gh pr merge "$ppr" --repo "$slug" --squash --admin --delete-branch >/dev/null 2>&1 \
      || gh pr merge "$ppr" --repo "$slug" --squash --delete-branch >/dev/null 2>&1 || true
  fi
  git -C "$REPO" fetch -q --prune origin "$MAIN" 2>/dev/null
  git -C "$REPO" checkout -q "$MAIN" 2>/dev/null && git -C "$REPO" reset -q --hard "origin/$MAIN" 2>/dev/null || true
}

_swarm_plan_sync() {
  echo "  planning: researching + decomposing OBJECTIVES → ROADMAP on your model — research → spec → tasks (waits on a limit; SWARM_SYNC=0 to skip)…"
  ( cd "$REPO" && LOOP_SYNC_ONLY=1 PLAN=1 AUTOMERGE=1 MERGE_GATE=local DEPLOY=0 \
      bash "$REPO/scripts/auto-loop.sh" ) >>"$SWARM_DIR/coordinator.log" 2>&1 \
    || echo "  planning: sync ended (see coordinator.log) — proceeding with the current ROADMAP"
  local _slug; _slug="$(cd "$REPO" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  _land_plan_pr "$_slug"
  # P0.1: with the ROADMAP now on main, LINT the OPEN items against the runtime footprint model
  # (swarm_plan_lint = swarm_paths_for_item + _overlap). If any COLLIDE (share a file → serialize) or are
  # OVERSIZE, run ONE targeted re-slice pass and land it BEFORE dispatch — turning #65's warning into an
  # actual fix. Bounded: at most one re-slice per plan-sync; SWARM_RESLICE=0 disables. Fail-open.
  local _lint _lrc
  _lint="$(swarm_plan_lint "$REPO/ROADMAP.md" 2>/dev/null)"; _lrc=$?
  if [ "$_lrc" -eq 1 ] && [ "${SWARM_RESLICE:-1}" != 0 ]; then
    # CAP the report fed to the planner: a cluttered ROADMAP can yield hundreds of colliding pairs, and a
    # 900-line directive is both an unwieldy Opus prompt and an unrealistic "fix everything at once" ask.
    # Feed only the worst RESLICE_MAX offenders — plan-lint re-runs each plan-sync, so the tail is fixed over
    # successive passes (the batch drains → re-plan → re-lint) rather than in one giant pass.
    local _report _ntot
    _ntot="$(printf '%s\n' "$_lint" | grep -cE '^(COLLIDE|OVERSIZE)')"
    _report="$(printf '%s\n' "$_lint" | grep -E '^(COLLIDE|OVERSIZE)' | head -"${RESLICE_MAX:-30}")"
    [ "$_ntot" -gt "${RESLICE_MAX:-30}" ] && _report="$_report
…and $((_ntot - ${RESLICE_MAX:-30})) more — this pass fixes the worst; the next plan-sync re-lints the rest."
    echo "  planning: plan-lint found $_ntot colliding/oversize item(s) — re-slicing the worst $(printf '%s\n' "$_report" | grep -cE '^(COLLIDE|OVERSIZE)') before dispatch"
    swarm_post coordinator needs-attention "plan-lint: re-slicing $_ntot colliding/oversize item(s) before dispatch (worst ${RESLICE_MAX:-30} this pass)" "" 2>/dev/null || true
    ( cd "$REPO" && RESLICE_REPORT="$_report" LOOP_SYNC_ONLY=1 PLAN=1 AUTOMERGE=1 MERGE_GATE=local DEPLOY=0 \
        bash "$REPO/scripts/auto-loop.sh" ) >>"$SWARM_DIR/coordinator.log" 2>&1 || true
    _land_plan_pr "$_slug"
  fi
  # Part H/H5: spec gate — same shape as the plan-lint re-slice above. Lint every spec a ROADMAP item points at
  # ('Spec: <path>'); gaps → ONE bounded re-spec pass (SPECLINT_REPORT) + land it, then re-lint. Fail-open: any
  # residual gaps surface as needs-attention and dispatch proceeds. SPEC_LINT=0 disables; items without a Spec:
  # (incl. all [infra]) pass untouched.
  if [ "${SPEC_LINT:-1}" = 1 ]; then
    local _specf _slint _sgn
    _specf() { grep -oE 'Spec:[[:space:]]*[^ )]+\.md' "$REPO/ROADMAP.md" 2>/dev/null | sed -E 's/^Spec:[[:space:]]*//' | sort -u \
                 | while IFS= read -r _s; do [ -n "$_s" ] && [ -f "$REPO/$_s" ] && printf '%s\n' "$REPO/$_s"; done; }
    if [ -n "$(_specf)" ]; then
      _slint="$(cd "$REPO" && REPO="$REPO" swarm_spec_lint $(_specf) 2>/dev/null)"
      # a bounded re-spec pass, reused twice: once for deterministic lint gaps, once for debate/rubric-agreed gaps.
      _respec() {  # $1 = SPECGAP report to feed the re-spec drive
        ( cd "$REPO" && SPECLINT_REPORT="$1" LOOP_SYNC_ONLY=1 PLAN=1 AUTOMERGE=1 MERGE_GATE=local DEPLOY=0 \
            bash "$REPO/scripts/auto-loop.sh" ) >>"$SWARM_DIR/coordinator.log" 2>&1 || true
        _land_plan_pr "$_slug"
        _slint="$(cd "$REPO" && REPO="$REPO" swarm_spec_lint $(_specf) 2>/dev/null)"
      }
      # 1) deterministic gaps → re-spec FIRST, so the quality layer below sees lint-CLEAN specs (a freshly re-derived
      # spec almost always starts with a gap; debating BEFORE this skipped every one → the debate never ran).
      if printf '%s\n' "$_slint" | grep -q '^SPECGAP' && [ "${SWARM_RESLICE:-1}" != 0 ]; then
        _sgn="$(printf '%s\n' "$_slint" | grep -c '^SPECGAP')"
        echo "  planning: spec-lint found $_sgn spec gap(s) — re-spec before the quality gate"
        swarm_post coordinator needs-attention "spec-lint: $_sgn spec gap(s) — re-spec before dispatch" "" 2>/dev/null || true
        _respec "$(printf '%s\n' "$_slint" | grep '^SPECGAP' | head -"${SPECFIX_MAX_LINES:-40}")"
      fi
      # 2) OPTIONAL quality layer on the now lint-GREEN specs, folding agreed GAPS into a SEPARATE report. Both
      # default OFF, fail-open. SPEC_DEBATE (cross-model dialogue) subsumes the single-shot SPEC_RUBRIC.
      local _extra=""
      if [ "${SPEC_DEBATE:-0}" = 1 ]; then
        echo "  planning: spec-debate — cross-model dialogue pressure-testing the feature spec(s) (SPEC_DEBATE=1)…"
        local _rsp _deb
        while IFS= read -r _rsp; do
          [ -n "$_rsp" ] || continue
          printf '%s\n' "$_slint" | grep -q "^SPECGAP $(basename "$_rsp" .md) " && continue   # still gappy after re-spec → skip
          _deb="$(cd "$REPO" && bash "$HERE/debate.sh" spec "$_rsp" 2>/dev/null)" || true
          [ -n "$_deb" ] && _extra="$(printf '%s\n%s' "$_extra" "$_deb")"
        done < <(_specf)
      elif [ "${SPEC_RUBRIC:-0}" = 1 ]; then
        echo "  planning: spec-rubric judging the feature spec(s) on your model (SPEC_RUBRIC=1)…"
        local _rsp _rub
        while IFS= read -r _rsp; do
          [ -n "$_rsp" ] || continue
          printf '%s\n' "$_slint" | grep -q "^SPECGAP $(basename "$_rsp" .md) " && continue
          _rub="$(cd "$REPO" && swarm_spec_rubric "$_rsp" 2>/dev/null)" || true
          [ -n "$_rub" ] && _extra="$(printf '%s\n%s' "$_extra" "$_rub")"
        done < <(_specf)
      fi
      # 3) debate/rubric-agreed gaps → one more re-spec
      if printf '%s\n' "$_extra" | grep -q '^SPECGAP' && [ "${SWARM_RESLICE:-1}" != 0 ]; then
        _sgn="$(printf '%s\n' "$_extra" | grep -c '^SPECGAP')"
        echo "  planning: spec-$([ "${SPEC_DEBATE:-0}" = 1 ] && echo debate || echo rubric) agreed $_sgn gap(s) — re-spec before dispatch"
        swarm_post coordinator needs-attention "spec-debate: $_sgn agreed gap(s) — re-spec before dispatch" "" 2>/dev/null || true
        _respec "$(printf '%s\n' "$_extra" | grep '^SPECGAP' | head -"${SPECFIX_MAX_LINES:-40}")"
      fi
      printf '%s\n' "$_slint" | grep -q '^SPECGAP' \
        && swarm_post coordinator needs-attention "spec-lint: $(printf '%s\n' "$_slint" | grep -c '^SPECGAP') gap(s) remain — dispatching (fail-open)" "" 2>/dev/null || true
      { printf '\n-- spec-lint --\n'; printf '%s\n' "$_slint"; } >> "$SWARM_DIR/batch-plan.txt" 2>/dev/null || true
    fi
  fi
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
  # P0.1: append the plan-lint verdict (SPECIFIC colliding pairs + OVERSIZE items) to the artifact + surface
  # the exact items on the bus — actionable where #65's parallel/serial counts are only a symptom. Telemetry
  # only: does NOT write ROADMAP.md (workers own its ticks) and does NOT merge anything. Fail-open.
  local _lint _lrc
  _lint="$(swarm_plan_lint "$REPO/ROADMAP.md" 2>/dev/null)"; _lrc=$?
  if [ "$_lrc" -eq 1 ]; then
    { printf '\n-- plan-lint --\n'; printf '%s\n' "$_lint"; } >> "$SWARM_DIR/batch-plan.txt" 2>/dev/null || true
    local _first; _first="$(printf '%s\n' "$_lint" | grep -E '^(COLLIDE|OVERSIZE)' | head -3 | tr '\n' ';')"
    [ -n "$_first" ] && swarm_post coordinator needs-attention "plan-lint: ${_first%;}" "" 2>/dev/null || true
  fi
  # #65: surface the PARALLELISM CEILING loudly (it was invisible until a run post-mortem). When the ROADMAP is
  # heavily file-serialized, extra workers can't help no matter how high SWARM_MAX is — the shape is the ceiling.
  if [ "$npar" -lt 3 ] && [ "$nser" -ge 3 ]; then
    printf '  \033[0;33m⚠ ROADMAP file-serialized: only %s item(s) parallelize while %s share files — throughput is capped near %s worker(s) regardless of SWARM_MAX. Prefer VERTICAL slices in disjoint files; give a shared HUB file to ONE item and `deps:` the rest.\033[0m\n' "$npar" "$nser" "$npar"
    swarm_post coordinator needs-attention "planner: $npar parallel / $nser serialized — parallelism capped near $npar; prefer disjoint vertical slices" "" 2>/dev/null || true
  fi
}

# _drain_watchdog — P2 throughput floor. While a generation's workers run, watch origin/MAIN: if it has NOT
# advanced (no merge landed) for SWARM_DRAIN_AFTER while ≥1 worker still holds an active claim, the run is in
# unproductive churn (the ~4h dead tail in run 260716 landed 1 PR) — trip control.drain so workers stop
# claiming new work and the generation ends cleanly instead of burning hours. Conservative: the clock PAUSES
# during legitimate holds (provider-cap reset wait, RED-main standby), and only trips with work in flight.
# Opt-out with SWARM_AUTODRAIN=0. The parent kills this when the generation's workers finish.
_drain_watchdog() {
  local after="${SWARM_DRAIN_AFTER:-9000}" last_adv now head lasthead nactive
  case "$after" in ''|*[!0-9]*) after=5400 ;; esac
  lasthead="$(git -C "$REPO" rev-parse "origin/$MAIN" 2>/dev/null || echo none)"; last_adv="$(date +%s)"
  while sleep "${DRAIN_POLL:-120}"; do
    [ -f "$SWARM_DIR/control.drain" ] && return 0
    # legitimate holds are NOT churn — reset the clock so a long cap reset / RED-main standby never auto-drains
    if [ -f "$SWARM_DIR/provider-capped" ] || [ -f "$SWARM_DIR/main-red" ]; then last_adv="$(date +%s)"; continue; fi
    git -C "$REPO" fetch -q origin "$MAIN" 2>/dev/null || true
    head="$(git -C "$REPO" rev-parse "origin/$MAIN" 2>/dev/null || echo none)"
    if [ "$head" != "$lasthead" ]; then lasthead="$head"; last_adv="$(date +%s)"; continue; fi
    now="$(date +%s)"
    nactive="$(jq -r '[.claims[]|select(.status=="active")]|length' "$SWARM_DIR/state.json" 2>/dev/null || echo 0)"
    case "$nactive" in ''|*[!0-9]*) nactive=0 ;; esac
    if [ "$((now - last_adv))" -ge "$after" ] && [ "$nactive" -ge 1 ]; then
      : > "$SWARM_DIR/control.drain"
      echo "  auto-drain: no merge to $MAIN in $((after/60))m while $nactive worker(s) active — draining (unproductive churn; SWARM_DRAIN_AFTER=$after · SWARM_AUTODRAIN=0 to disable)."
      swarm_post coordinator needs-attention "auto-drain: no merge in $((after/60))m with $nactive active — stopping the run; re-slice/park the stuck items (SWARM_AUTODRAIN=0 to disable)" "" 2>/dev/null || true
      return 0
    fi
  done
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
    _DWPID=""
    [ "${SWARM_AUTODRAIN:-1}" != 0 ] && [ "$DRY_RUN" != 1 ] && { _drain_watchdog & _DWPID=$!; }
    wait $_WPIDS 2>/dev/null
    [ -n "$_DWPID" ] && kill "$_DWPID" 2>/dev/null; _DWPID=""   # stop the throughput-floor watchdog once this generation's workers finish
    # another generation only if there's more work AND this one made progress: stop on drain, in dry mode,
    # or when the generation ticked NOTHING (remainder is parked/unclaimable → re-spawning would churn).
    [ "$DRY_RUN" = 1 ] && break
    [ -f "$SWARM_DIR/control.drain" ] && break
    _after="$(grep -cE '^[[:space:]]*- \[ \] ' "$REPO/ROADMAP.md" 2>/dev/null)"; _after="${_after:-0}"
    [ "$_after" -ge "$_before" ] 2>/dev/null && { echo "  batch $_gen made no progress — coordinator stopping"; break; }
  done
  kill "$_RPID" 2>/dev/null; [ -n "${_DWPID:-}" ] && kill "$_DWPID" 2>/dev/null
  # all workers have finished (ROADMAP exhausted, or the operator chose finish/drain) → shut the
  # coordinator DOWN cleanly: drop the pidfile + any control files so the dash flips to "no swarm
  # running" immediately and nothing stale blocks the next start.
  rm -f "$SWARM_DIR/coordinator.pid" "$SWARM_DIR"/control.* 2>/dev/null
  swarm_post coordinator idle "swarm stopped — all workers finished their current tasks" 2>/dev/null || true
  echo "swarm: all workers finished — coordinator stopped"; swarm_status
}
# ---- kill-safety helpers (stop / Ctrl-C path) --------------------------------
# KS-7: every pid we signal must be a REAL, positive pid. `kill 0` (which is what `kill "${_RPID:-0}"`
# degrades to when the reaper pid is unset) signals the ENTIRE PROCESS GROUP — under setsid that is the
# coordinator itself plus every worker and their opencode subtrees — pre-empting the ordered shutdown
# below with an unordered fleet-wide signal. pid 1 (init) is refused for the same class of reason.
_swarm_pid_ok() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ] 2>/dev/null; }
_swarm_alive()  { _swarm_pid_ok "${1:-}" && kill -0 "$1" 2>/dev/null; }
# KS-3: signal the process TREE, LEAVES FIRST. opencode spawns MCP servers, language servers and builds;
# the moment their leader dies they re-parent to init and survive, still holding the output pipe open.
# Walking children before the leader means nothing is re-parented out from under us mid-walk. Mirrors
# kill_tree() in lib/autoloop.sh:686 and _dash_killtree() in lib/dash.sh:18 — same job, same shape.
_swarm_killtree() {
  local p="${1:-}" s="${2:-TERM}" k
  _swarm_pid_ok "$p" || return 0
  for k in $(pgrep -P "$p" 2>/dev/null); do _swarm_killtree "$k" "$s"; done
  kill -"$s" "$p" 2>/dev/null || true
}
# read a pidfile, emit the pid only if it is plausible (so callers never branch on garbage)
# _swarm_pid_is <pid> <substring> — verify a pidfile-derived pid REALLY is the process we recorded, BEFORE
# signalling it. Pids get recycled: a stale wN.loop.pid or .oppid can name an unrelated live process, and
# because the stop path now kills TREE-WISE that would take an innocent bystander AND its children with it.
# The old name-matched `pkill -f` could not do that, so trusting a pidfile is strictly MORE blast radius and
# has to earn it. Refuse ONLY on positive evidence of a mismatch: if the cmdline cannot be read at all
# (no /proc, no ps, or the process already exited) we allow, so this can never silently skip a real kill.
_swarm_pid_is() {
  local p="${1:-}" want="${2:-}" cl=""
  [ -n "$p" ] && [ -n "$want" ] || return 1
  if [ -r "/proc/$p/cmdline" ]; then cl="$(tr "\0" " " < "/proc/$p/cmdline" 2>/dev/null)"
  else cl="$(ps -o args= -p "$p" 2>/dev/null)"; fi
  [ -n "$cl" ] || return 0
  case "$cl" in *"$want"*) return 0 ;; *) return 1 ;; esac
}

_swarm_pidof() { local p; p="$(cat "${1:-/nonexistent}" 2>/dev/null)"; _swarm_pid_ok "$p" && printf '%s' "$p"; }

_swarm_trap() {
  trap - INT TERM
  printf '\n%sswarm: stopping — workers preserving in-flight WIP on their branches, then terminating…%s\n' "${_GOLD:-}" "${_R:-}" >&2
  local sweep="${SWARM_STOP_SWEEP:-1}"        # 0 = skip the repo-wide pkill sweeps (used by the selftest, which must stay hermetic)
  _swarm_killtree "${_RPID:-}"  TERM          # reaper         (KS-7: never a bare `kill 0`)
  _swarm_killtree "${_DWPID:-}" TERM          # drain watchdog

  # ── B5: THE ORDER BELOW IS LOAD-BEARING — DO NOT REARRANGE ──────────────────────────────────────
  # Each worker's auto-loop sits in a FOREGROUND `opencode run … | tee` pipeline (lib/autoloop.sh:848).
  # Bash does not run a trap handler while a foreground command is running: it DEFERS the handler until
  # that command returns. So the loop's cleanup() — the thing that actually commits the in-flight WIP —
  # CANNOT run while its opencode is alive, no matter how many SIGTERMs it receives. The old code TERMed
  # the loops, slept 4s, then `pkill -KILL`ed them; SIGKILL is neither deferrable nor trappable, so
  # cleanup() never ran, the WIP commit never happened, and we printed "WIP preserved" anyway.
  # lib/dash.sh:229-235 documents and works around this exact bash behaviour for the solo loop.
  #
  # The fix is a two-step interleave and BOTH steps are required, in THIS order:
  #   1. TERM the loop LEADERS — the signal becomes pending, cleanup() is armed. Doing this AFTER step 2
  #      would be worse, not better: an un-signalled loop reacts to a dead opencode by starting a new one.
  #   2. Kill each worker's opencode TREE — the pipeline returns, and bash immediately runs the deferred
  #      cleanup(), which commits the WIP to the worker branch and tears down the rest of its subtree.
  local f p
  for f in "${SWARM_DIR:-/nonexistent}"/w*.loop.pid; do        # step 1 (nullglob is off → an unmatched glob arrives literally, hence the -f test)
    [ -f "$f" ] || continue
    p="$(_swarm_pidof "$f")"
    [ -n "$p" ] && _swarm_pid_is "$p" 'auto-loop.sh' && { kill -TERM "$p" 2>/dev/null || true; }
  done
  [ "$sweep" != 0 ] && { pkill -TERM -f 'scripts/auto-loop.sh' 2>/dev/null || true; }   # fallback: a loop whose pidfile write lost
  for f in "${WT_ROOT:-/nonexistent}"/*/.opencode/.oppid; do   # step 2 — unblock the deferred traps
    [ -f "$f" ] || continue
    p="$(_swarm_pidof "$f")"
    [ -n "$p" ] && _swarm_pid_is "$p" opencode && _swarm_killtree "$p" TERM   # TERM, not KILL: let opencode flush its session state
  done

  # Give those deferred cleanup traps time to FINISH the WIP commit. Poll rather than sleep a fixed 4s,
  # and escalate ONLY what is still alive — a loop that is mid-`git commit` must not be SIGKILLed just
  # because a hard-coded budget expired. cleanup() itself spends ~2s in sleeps before it commits.
  local grace="${SWARM_STOP_GRACE:-20}" waited=0 live
  case "$grace" in ''|*[!0-9]*) grace=20 ;; esac
  while [ "$waited" -lt "$grace" ]; do
    live=0
    for f in "${SWARM_DIR:-/nonexistent}"/w*.loop.pid; do
      [ -f "$f" ] || continue
      _swarm_alive "$(_swarm_pidof "$f")" && { live=1; break; }
    done
    [ "$live" = 0 ] && break
    sleep 1; waited=$((waited+1))
  done

  # escalate to SIGKILL — survivors only, tree-wise. `forced=1` means at least one loop outlived its
  # grace window, so its WIP is NOT guaranteed: say so instead of claiming preservation (the audit's
  # fail-open reporting theme — the stop message must describe what actually happened).
  local forced=0 w
  for f in "${SWARM_DIR:-/nonexistent}"/w*.loop.pid; do
    [ -f "$f" ] || continue
    p="$(_swarm_pidof "$f")"
    _swarm_alive "$p" && _swarm_pid_is "$p" 'auto-loop.sh' && { forced=1; _swarm_killtree "$p" KILL; }
  done
  for f in "${WT_ROOT:-/nonexistent}"/*/.opencode/.oppid; do
    [ -f "$f" ] || continue
    p="$(_swarm_pidof "$f")"
    _swarm_alive "$p" && _swarm_pid_is "$p" opencode && _swarm_killtree "$p" KILL
  done
  if [ "$sweep" != 0 ]; then
    pkill -KILL -f 'scripts/auto-loop.sh' 2>/dev/null || true
    pkill -KILL -f 'opencode run' 2>/dev/null || true
  fi
  for w in ${_WPIDS:-}; do _swarm_alive "$w" && _swarm_killtree "$w" KILL; done   # run_worker supervisor subshells

  # KS-6 / KS-5: this coordinator is about to exit — drop its pidfile and the operator control files.
  # dash_auto (lib/dash.sh:30) and _coord_up (lib/swarm-dash.sh:245) treat a coordinator.pid whose pid
  # answers `kill -0` as "a swarm is running", so a file left behind routes `ace dash` into the cockpit
  # of a long-dead swarm as soon as the pid is RECYCLED. Leftover control.{pause,drain,kill-wN} likewise
  # sabotage the next start. swarm_run's clean-exit tail (:637) already does exactly this; the Ctrl-C
  # path did not — that asymmetry WAS the bug. *.loop.pid go too: their owners are gone.
  [ -n "${SWARM_DIR:-}" ] && rm -f "$SWARM_DIR/coordinator.pid" "$SWARM_DIR"/control.* "$SWARM_DIR"/*.loop.pid 2>/dev/null
  if [ "$forced" = 1 ]; then
    echo "swarm: stopped — ⚠ at least one worker had to be force-killed after ${grace}s; its in-flight WIP may NOT have been committed." >&2
  else
    echo "swarm: stopped (in-flight WIP preserved as commits on the worker branches)." >&2
  fi
  exit 130
}

# ---- kill-safety selftest (hermetic, ~5s, no network, no credits) ------------
# Proves the four properties the Ctrl-C path silently lost. It stands up a FAKE worker whose "opencode"
# is a sleep tree and whose cleanup trap is armed behind a FOREGROUND pipeline — the exact bash shape
# that made the old trap's SIGKILL-first ordering skip the WIP commit — then fires _swarm_trap and
# asserts what actually happened rather than what the stop message claimed.
swarm_killsafety_selftest() {
  local d ok=1 lp op kid i
  d="$(mktemp -d)" || return 1
  SWARM_DIR="$d/state"; WT_ROOT="$d/wt"
  mkdir -p "$SWARM_DIR" "$WT_ROOT/w1-deadbeef/.opencode"

  # KS-7 unit assertions: the pid guard is what stops `kill 0` from signalling the whole process group.
  _swarm_pid_ok ""     && { echo "[killsafety] empty pid accepted (kill 0 → whole process group)"; ok=0; }
  _swarm_pid_ok 0      && { echo "[killsafety] pid 0 accepted (kill 0 → whole process group)"; ok=0; }
  _swarm_pid_ok 1      && { echo "[killsafety] pid 1 (init) accepted"; ok=0; }
  _swarm_pid_ok abc    && { echo "[killsafety] non-numeric pid accepted"; ok=0; }
  _swarm_pid_ok 4321   || { echo "[killsafety] a normal pid was rejected"; ok=0; }

  # stand-in for scripts/auto-loop.sh. Two properties are load-bearing and both mirror the real loop:
  #   1. cleanup() "preserves WIP"  (here: writes $WIPMARK)   — lib/autoloop.sh:687
  #   2. it is armed while the process blocks in a FOREGROUND pipeline, so bash DEFERS the handler until
  #      the pipeline returns — which only happens once the "opencode" tree dies. lib/autoloop.sh:848.
  # The "opencode" is a shell owning a grandchild sleep, so the test also covers tree-kill (KS-3): a bare
  # `kill $oppid` would leave the grandchild running.
  cat > "$d/auto-loop.sh" <<'FAKELOOP'
#!/usr/bin/env bash
cleanup(){ trap - INT TERM; printf 'trap\n' > "$WIPMARK"; exit 0; }
trap cleanup INT TERM
{ bash -c 'sleep 300 & printf "%s\n" "$!" > "$KIDF"; wait' & printf '%s\n' "$!" > "$OPPID"; wait "$!"; } 2>&1 | cat >/dev/null
# Reached ONLY when no signal was ever pending. Writing a DIFFERENT marker is what makes the ordering
# testable: bash runs a deferred handler the instant the foreground pipeline returns, so if the loop was
# TERMed first (correct) the marker says `trap`; if the opencode tree was killed with no signal pending
# (the reversed order) the loop falls through to here and the marker says `fallthrough`. The old fixture
# called cleanup() unconditionally on this line, so BOTH paths wrote the same value and the assertion
# could not tell them apart — the ordering, which is the entire substance of B5, was untested.
# Reached only when NO signal was pending when the pipeline returned. A REAL auto-loop does not exit here —
# it treats a dead opencode as "step finished" and starts the NEXT lap (a fresh opencode). Modelling that is
# what makes the ordering testable: killing the opencode tree BEFORE signalling the loop just makes the loop
# spawn another one, so the stop never converges. Record it and stay alive like the real loop would.
printf 'fallthrough\n' > "$WIPMARK"
printf 'restarted\n' >> "$RESTARTF"
bash -c 'sleep 300' & printf '%s\n' "$!" > "$OPPID"; wait "$!"
FAKELOOP

  ( export WIPMARK="$d/wip" RESTARTF="$d/restarts" KIDF="$d/kid" OPPID="$WT_ROOT/w1-deadbeef/.opencode/.oppid"
    exec bash "$d/auto-loop.sh" ) & lp=$!
  echo "$lp" > "$SWARM_DIR/w1.loop.pid"
  echo $$   > "$SWARM_DIR/coordinator.pid"          # KS-6 subject
  : > "$SWARM_DIR/control.pause"; : > "$SWARM_DIR/control.drain"; : > "$SWARM_DIR/control.kill-w1"   # KS-5 subjects

  for i in 1 2 3 4 5 6 7 8 9 10; do                 # wait for the fake tree to be fully up before signalling
    [ -s "$WT_ROOT/w1-deadbeef/.opencode/.oppid" ] && [ -s "$d/kid" ] && break; sleep 0.5
  done
  op="$(cat "$WT_ROOT/w1-deadbeef/.opencode/.oppid" 2>/dev/null)"; kid="$(cat "$d/kid" 2>/dev/null)"
  if ! _swarm_alive "$op" || ! _swarm_alive "$kid"; then
    echo "[killsafety] fixture failed to start (oppid='$op' child='$kid')"; kill -9 "$lp" 2>/dev/null; rm -rf "$d"; return 1
  fi

  # fire the trap in a subshell — it ends in `exit 130` by design. SWARM_STOP_SWEEP=0 keeps it hermetic
  # (no repo-wide pkill that could reach a developer's real loop); the pidfile/.oppid paths do the work.
  ( _RPID=""; _DWPID=""; _WPIDS=""; SWARM_STOP_SWEEP=0 SWARM_STOP_GRACE=10 _swarm_trap ) >/dev/null 2>&1
  wait "$lp" 2>/dev/null

  # (B5) the deferred cleanup trap actually ran → WIP was preserved, not just claimed
  # ORDER: a restart means the opencode tree was killed while no signal was pending — the reversed interleave.
  [ -s "$d/restarts" ] && { echo "[killsafety] B5: ORDER WRONG — loop was left un-signalled when its opencode died, so it started a NEW lap instead of stopping"; ok=0; }
  case "$(cat "$d/wip" 2>/dev/null)" in
    trap) : ;;
    fallthrough) echo "[killsafety] B5: ORDER WRONG — the opencode tree was killed with no signal pending, so the loop fell through instead of running its deferred cleanup trap"; ok=0 ;;
    *) echo "[killsafety] B5: the loop's deferred cleanup trap never ran — WIP was NOT committed"; ok=0 ;;
  esac
  # (a/KS-3) the whole child tree is gone, grandchild included
  _swarm_alive "$lp"  && { echo "[killsafety] loop leader $lp survived the stop"; ok=0; }
  _swarm_alive "$op"  && { echo "[killsafety] KS-3: 'opencode' $op survived the stop"; ok=0; }
  _swarm_alive "$kid" && { echo "[killsafety] KS-3: orphaned grandchild $kid survived the stop"; ok=0; }
  # (b/KS-6) coordinator.pid removed — else a recycled pid routes `ace dash` to a dead swarm
  [ -e "$SWARM_DIR/coordinator.pid" ] && { echo "[killsafety] KS-6: coordinator.pid left behind"; ok=0; }
  # (c/KS-5) control.* cleaned so the next start isn't sabotaged
  ls "$SWARM_DIR"/control.* >/dev/null 2>&1 && { echo "[killsafety] KS-5: control.* left behind"; ok=0; }
  ls "$SWARM_DIR"/*.loop.pid >/dev/null 2>&1 && { echo "[killsafety] stale worker pidfile left behind"; ok=0; }

  kill -9 "$kid" "$op" "$lp" 2>/dev/null   # belt-and-braces: never leak fixture processes out of a FAILED run
  rm -rf "$d"
  # ── scenario 2: a TERM-DEAF worker must be force-killed AND reported honestly ────────────────────
  # The fixture above always obeys TERM, so the grace/escalate branch — and the honest "WIP may NOT have
  # been committed" message that replaced the unconditional "WIP preserved" claim — had ZERO coverage.
  # That message is the audit's dominant theme (a gate reporting success it cannot vouch for), so it needs
  # its own proof: a worker that traps and IGNORES TERM, forcing the escalation path.
  local d2 out2 ok2=1
  d2="$(mktemp -d)" || return 1
  mkdir -p "$d2/sw" "$d2/wt/w1-deaf/.opencode"
  cat > "$d2/auto-loop.sh" <<'DEAF'
#!/usr/bin/env bash
trap '' INT TERM          # deliberately deaf: models a loop wedged mid-step
sleep 300
DEAF
  ( exec bash "$d2/auto-loop.sh" ) & local dp=$!
  disown "$dp" 2>/dev/null || true      # the shell's "Killed" job notice would otherwise pollute test output
  echo "$dp" > "$d2/sw/w1.loop.pid"
  sleep 0.3
  out2="$( ( _RPID=""; _DWPID=""; _WPIDS=""; SWARM_DIR="$d2/sw" WT_ROOT="$d2/wt" \
             SWARM_STOP_SWEEP=0 SWARM_STOP_GRACE=2 _swarm_trap ) 2>&1 )"
  _swarm_alive "$dp" && { echo "[killsafety] a TERM-deaf worker survived the stop (never escalated to KILL)"; ok2=0; kill -9 "$dp" 2>/dev/null; }
  case "$out2" in
    *"may NOT have been committed"*) : ;;
    *"WIP preserved"*) echo "[killsafety] FAIL-OPEN: a force-killed worker was reported as 'WIP preserved'"; ok2=0 ;;
    *) echo "[killsafety] force-kill path produced no honest stop message: $out2"; ok2=0 ;;
  esac
  rm -rf "$d2"
  [ "$ok2" = 1 ] || ok=0

  [ "$ok" = 1 ] && { echo "[killsafety] PASS ✓"; return 0; }
  echo "[killsafety] FAIL ✗" >&2; return 1
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

# swarm_preflight — before a LIVE run spends credits, print a DECISION · SETUP · STATE table and, when a
# TTY is present, ask for ONE final confirm. Headless / detached (no TTY) prints the table for the record
# and proceeds — it never blocks the autonomous flow (ACE_YES=1 also skips the prompt; SWARM_PREFLIGHT=0
# disables the whole thing). Returns non-zero ONLY on an interactive "no". Read-only: touches nothing.
swarm_preflight() {
  [ "${SWARM_PREFLIGHT:-1}" = 1 ] || return 0
  local repo="$REPO" prof="$REPO/.opencode/profile.yaml"
  local P="${_PUR:-}" G="${_GRN:-}" R="${_R:-}" B="${_B:-}" M="${_MUT:-}" Y="${_GOLD:-}"
  _pf(){ grep -iE "^[[:space:]]*$1[[:space:]]*:" "$prof" 2>/dev/null | head -1 | sed -E 's/^[^:]*:[[:space:]]*//; s/[[:space:]]*(#.*)?$//; s/^["'\'']//; s/["'\'']$//'; }
  # --- gather (all best-effort; a failure just shows a placeholder) ---
  local slug branch remote lastg rmopen objs npar ncoll nover lint ov mg am
  slug="$(cd "$repo" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || basename "$repo")"
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  remote="$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#' || echo none)"
  lastg="$(git -C "$repo" rev-parse --short "origin/$MAIN" 2>/dev/null || git -C "$repo" rev-parse --short "$MAIN" 2>/dev/null || echo '?')"
  rmopen="$(grep -cE '^[[:space:]]*- \[ \] ' "$repo/ROADMAP.md" 2>/dev/null)"; rmopen="${rmopen:-0}"     # no `|| echo 0`: grep -c prints 0 + exit 1 on no match → || would double-print "0\n0"
  objs="$(grep -cE '^[[:space:]]*- \[ \] ' "$repo/OBJECTIVES.md" 2>/dev/null)"; objs="${objs:-0}"
  npar="$(swarm_disjoint_batch "$repo/ROADMAP.md" "${SWARM_CEIL:-5}" 2>/dev/null || echo '?')"
  lint="$(swarm_plan_lint "$repo/ROADMAP.md" 2>/dev/null)"
  ncoll="$(printf '%s\n' "$lint" | grep -c '^COLLIDE')"; nover="$(printf '%s\n' "$lint" | grep -c '^OVERSIZE')"
  ov="${ORCH_MODEL_OVERRIDE:-$(jq -r '.agent.orchestrator.model // .agents.orchestrator.model // empty' "$HOME/.config/opencode/opencode.json" 2>/dev/null)}"; ov="${ov:-configured overseer}"
  mg="${MERGE_GATE:-$(_pf merge_gate)}"; mg="${mg:-remote}"
  case "${AUTOMERGE:-$(_pf auto_merge)}" in true|yes|1) am=on ;; *) am=off ;; esac
  local tcont tgh tkey
  { command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; } && tcont="✓" || tcont="✗ none"
  ( cd "$repo" && gh auth status >/dev/null 2>&1 ) && tgh="✓" || tgh="✗ not logged in"
  [ -n "${DEEPSEEK_API_KEY:-}${OPENROUTER_API_KEY:-}${ANTHROPIC_API_KEY:-}" ] && tkey="✓ (env)" || tkey="from config"
  # --- render ---
  local bar='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '\n%s%s┏━ swarm preflight · %s %s%s\n' "$B" "$P" "$slug" "${bar:0:$(( 30>${#slug}?30-${#slug}:2 ))}" "$R"
  printf '%s┃%s %sDECISION%s  workers %s%s%s/%s · overseer %s · merge_gate %s · auto_merge %s · deploy %s · live %s%s%s\n' \
    "$P" "$R" "$B" "$R" "$G" "$MAX" "$R" "${SWARM_CEIL:-5}" "$ov" "$mg" "$am" "$([ "${DEPLOY:-0}" = 1 ] && echo on || echo OFF)" "$G" "$LIVE" "$R"
  printf '%s┃%s %sSETUP   %s  repo %s · branch %s · remote %s · container %s · github %s · key %s\n' \
    "$P" "$R" "$B" "$R" "$slug" "$branch" "$remote" "$tcont" "$tgh" "$tkey"
  printf '%s┃%s %sSTATE   %s  ROADMAP open %s · objectives open %s · main@%s · ~%s parallelizable now\n' \
    "$P" "$R" "$B" "$R" "$rmopen" "$objs" "$lastg" "$npar"
  printf '%s┃%s           plan-lint: %s%s collision(s)%s · %s oversize\n' \
    "$P" "$R" "$([ "${ncoll:-0}" -gt 0 ] && echo "$Y" || echo "$G")" "${ncoll:-0}" "$R" "${nover:-0}"
  local _spgaps _nspec; _nspec="$(grep -oE 'Spec:[[:space:]]*[^ )]+\.md' "$repo/ROADMAP.md" 2>/dev/null | sort -u | grep -c . || true)"; _nspec="${_nspec:-0}"
  if [ "${SPEC_LINT:-1}" = 1 ] && [ "${_nspec:-0}" -gt 0 ]; then
    _spgaps="$(cd "$repo" && grep -oE 'Spec:[[:space:]]*[^ )]+\.md' ROADMAP.md 2>/dev/null | sed -E 's/^Spec:[[:space:]]*//' | sort -u | while IFS= read -r s; do [ -f "$s" ] && echo "$s"; done | xargs -r env REPO="$repo" bash "$HERE/swarm.sh" spec-lint 2>/dev/null | grep -c '^SPECGAP' || true)"; _spgaps="${_spgaps:-0}"
    printf '%s┃%s           spec-gate: %s%s spec gap(s)%s across %s spec(s) (SPEC_LINT=0 to disable)\n' \
      "$P" "$R" "$([ "${_spgaps:-0}" -gt 0 ] && echo "$Y" || echo "$G")" "${_spgaps:-0}" "$R" "${_nspec}"
  fi
  [ "${ncoll:-0}" -gt 50 ] && printf '%s┃%s           %s⚠ heavily file-serialized — early passes will re-slice before real parallelism (RESLICE_MAX/pass)%s\n' "$P" "$R" "$Y" "$R"
  printf '%s┗%s%s\n' "$P" "$bar" "$R"
  # --- confirm (interactive only; headless/ACE_YES proceed) ---
  if [ -t 0 ] && [ -t 1 ] && [ "${ACE_YES:-0}" != 1 ]; then
    printf '%sStart this LIVE run now?%s %sspends model credits%s %s[Y/n]%s ▸ ' "$B" "$R" "$M" "$R" "$M" "$R"
    local ans; read -r ans
    case "${ans:-Y}" in [Nn]*) printf '%saborted — nothing started.%s\n' "$M" "$R"; return 1 ;; esac
  else
    echo "  (headless — proceeding without a prompt · ACE_YES to silence)"
  fi
  return 0
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
  swarm_preflight || return 0                # DECISION · SETUP · STATE table + final confirm (headless auto-proceeds); a "no" stops here
  rm -f "$SWARM_DIR"/control.* "$SWARM_DIR/.cost-chip" 2>/dev/null   # drop leftover control.{pause,drain,kill-wN} + the prior run's cached spend chip so a fresh run doesn't inherit them
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
  preflight)  swarm_init; SWARM_PREFLIGHT=1 ACE_YES=1 swarm_preflight ;;   # preview the DECISION·SETUP·STATE table (no run)
  stop)       swarm_stopd ;;
  dash)       swarm_dash ;;             # THE dash: one self-contained TUI — cockpit + per-worker LIVE feeds inline (no tmux)
  split)      swarm_dash_split ;;       # OPTIONAL: real tmux panes (independent scrollback/mouse per worker) — needs tmux
  cockpit)    DASH_FEEDS=0 swarm_dash ;; # boxes-only cockpit (no inline feeds) — used inside the tmux split's top pane
  sandbox)    swarm_sandbox ;;
  killsafety-selftest) swarm_killsafety_selftest ;;   # hermetic proof of the stop/Ctrl-C kill path (run by tests/swarm-selftests.sh)
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
