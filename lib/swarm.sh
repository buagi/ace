#!/usr/bin/env bash
# swarm.sh — coordination substrate for ACE's parallel loop ("swarm").
#
# Runs N feature-streams concurrently, each in its own git worktree, each taking
# ONE ROADMAP item. The hard problem is keeping two flows from editing the same
# files. This module is the shared, flock-guarded store that makes claiming
# atomic and PATH-DISJOINT, plus a lightweight append-only message bus so flows
# can talk (touching-X · needs-attention · blocked · done).
#
# No sqlite/redis dependency — a single JSON state file guarded by flock(1),
# manipulated with jq(1). All mutations go through _with_lock so concurrent
# workers (separate processes/worktrees) never corrupt or race the store.
#
# CLI:  bash lib/swarm.sh <init|next|release|post|tail|status|paths|selftest> ...
set -uo pipefail

# declarative conflict policy (lease-free set + merge drivers + post-merge regen).
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/swarm-policy.sh" 2>/dev/null || true

# --- location: runtime state lives OUTSIDE the repo (worktrees each carry their
# own tracked .opencode/, so coordination must be shared + untracked). ----------
swarm_slug() { git rev-parse --show-toplevel >/dev/null 2>&1 &&
  basename "$(git rev-parse --show-toplevel)" || echo "nogit"; }
_now() { date +%s; }

MAX_TRIES="${SWARM_MAX_TRIES:-3}"       # park an item after this many failed attempts
LEASE_TTL="${SWARM_LEASE_TTL:-900}"     # reclaim a lease whose worker hasn't beat in this long (s)

# --- colour: ONLY on a TTY (never when piped — e.g. the MCP server captures our
# stdout for the agent, where ANSI would corrupt its context). Each worker gets a
# STABLE colour so you can eye-track it across status · tail · logs. ------------
if [ -t 1 ] && [ -z "${SWARM_NOCOLOR:-}" ] && [ "${TERM:-}" != dumb ]; then
  _R=$'\033[0m'; _B=$'\033[1m'; _DIM=$'\033[2m'
  _PUR=$'\033[38;2;176;114;230m'; _GOLD=$'\033[38;2;212;160;74m'; _GRN=$'\033[38;2;63;185;106m'
  _CRIM=$'\033[38;2;208;80;70m'; _CYAN=$'\033[38;2;90;190;210m'; _BLU=$'\033[38;2;110;150;230m'
  _MUT=$'\033[38;2;122;110;142m'; _RED=$'\033[38;2;208;69;59m'; _FG=$'\033[38;2;216;207;230m'
else _R= _B= _DIM= _PUR= _GOLD= _GRN= _CRIM= _CYAN= _BLU= _MUT= _RED= _FG=; fi
# stable per-worker colour for ANY worker count. Worker colours must NOT collide with the
# semantic palette — red=error, gold=warn, green=ok — nor the theme accent (purple ~272°), or a
# worker's border reads as a status. So we draw ONLY from safe hue bands: cool 165–250°
# (teal·cyan·sky·blue·indigo) + warm 300–338° (magenta·pink). Curated, maximally-spread picks for
# w1–w6 (alternating cool/warm so neighbours never look alike); golden-angle WITHIN the safe bands
# for w7+ so every worker stays distinct yet never lands on a status/theme hue.
_wcol(){ [ -n "${_R:-}" ] || return 0     # colour off (piped/dumb/NOCOLOR) → emit nothing
  case "${1#w}" in
    1) printf '\033[38;2;45;212;191m'  ;;   # teal
    2) printf '\033[38;2;232;121;201m' ;;   # magenta
    3) printf '\033[38;2;56;189;248m'  ;;   # sky
    4) printf '\033[38;2;244;114;182m' ;;   # pink
    5) printf '\033[38;2;99;102;241m'  ;;   # indigo
    6) printf '\033[38;2;34;211;238m'  ;;   # cyan
    *) awk -v n="${1#w}" 'BEGIN{
         g=n*0.61803398875; g=g-int(g);            # golden-ratio frac in [0,1)
         A=85; B=38; pos=g*(A+B);                   # spread across the two safe bands
         if(pos<A) h=165+pos; else h=300+(pos-A);   # 165–250° (cool) or 300–338° (warm)
         s=0.62; v=0.96; c=v*s; hp=h/60;
         hh=hp-int(hp/2)*2; if(hh<0)hh+=2; x=c*(1-(hh>1?hh-1:1-hh)); m=v-c;
         if(hp<1){r=c;gg=x;b=0}else if(hp<2){r=x;gg=c;b=0}else if(hp<3){r=0;gg=c;b=x}
         else if(hp<4){r=0;gg=x;b=c}else if(hp<5){r=x;gg=0;b=c}else{r=c;gg=0;b=x}
         printf "\033[38;2;%d;%d;%dm",(r+m)*255,(gg+m)*255,(b+m)*255 }' ;;
  esac; }
# level → colour for bus/log lines
_typc(){ case "$1" in done|acquired|ok) printf '%s' "$_GRN";; conflict|error|err|gate-red) printf '%s' "$_RED";;
  waiting|blocked|defer|needs-attention|reap|warn|stopped|incomplete) printf '%s' "$_GOLD";; claimed|merging|accent) printf '%s' "$_PUR";; *) printf '%s' "$_FG";; esac; }
_clip(){ printf '%s' "$1" | sed -E 's/^[0-9]+:[[:space:]]*- \[[ xX]\] //; s/\*//g' | cut -c1-"${2:-40}"; }
_wname(){ case "$1" in w[0-9]*) printf 'worker %s' "${1#w}";; *) printf '%s' "$1";; esac; }  # w1 → "worker 1"; coordinator/reaper unchanged

# Store paths are recomputed from SWARM_DIR on every init so callers/tests can
# override SWARM_DIR (e.g. the sandbox) and get an isolated store.
swarm_init() {
  SWARM_DIR="${SWARM_DIR:-$HOME/.config/ace/swarm/$(swarm_slug)}"
  LOCK="$SWARM_DIR/.lock"; STATE="$SWARM_DIR/state.json"
  MSG="$SWARM_DIR/messages.jsonl"; MERGE_LOCK="$SWARM_DIR/.merge.lock"
  mkdir -p "$SWARM_DIR"
  [ -f "$STATE" ] || printf '{"seq":0,"claims":{},"workers":{}}\n' > "$STATE"
  [ -f "$MSG" ] || : > "$MSG"
  [ -f "$LOCK" ] || : > "$LOCK"
  [ -f "$MERGE_LOCK" ] || : > "$MERGE_LOCK"
}

# _putstate TMP — promote a transaction's temp file to STATE only if it is VALID JSON.
# A jq that erred (partial output) or a torn write is never mv'd over the store, so a
# single bad write can't corrupt state.json (the root of the "workers → 0" blackout).
_putstate() { jq -e . "$1" >/dev/null 2>&1 && mv -f "$1" "$STATE" || { rm -f "$1"; return 1; }; }

# _repair_state — if STATE won't parse, quarantine it and reinit (claims get rebuilt by
# swarm_reconcile on the next coordinator pass). Called under the lock so it can't race a writer.
_repair_state() {
  jq -e . "$STATE" >/dev/null 2>&1 && return 0
  [ -s "$STATE" ] && cp -f "$STATE" "$SWARM_DIR/state.corrupt.$(_now)" 2>/dev/null
  printf '{"seq":0,"claims":{},"workers":{}}\n' > "$STATE"
  return 1
}

# _with_lock CMD... — run a jq transform on STATE atomically. The function body
# reads STATE on stdin via jq and must print the new STATE; we write it back.
_with_lock() {
  swarm_init
  exec {fd}>"$LOCK"
  flock -w 10 "$fd" || { echo "swarm: lock timeout" >&2; return 3; }
  _repair_state    # heal a corrupt store under the lock, before the txn reads it
  "$@"
  local rc=$?
  flock -u "$fd"; exec {fd}>&-
  return $rc
}

# --- path leasing: derive the file/dir prefixes an item will touch. -----------
# v1 heuristic: pull concrete path-like tokens out of the item text (foo/bar,
# scripts/x.sh, ci.sh, apps/portal/...). If none are found the blast radius is
# unknown → lease "." (whole repo) so the item runs ALONE (fail-safe, never a
# silent overlap). Later phases refine this with GitNexus impact.
# Files the swarm must NOT lease per-item: coordinator-owned (ROADMAP/OBJECTIVES —
# ticked serially after merge), union-merged (lessons/changelog), or auto-regenerated
# every commit (GitNexus stat blocks in AGENTS/CLAUDE/docs/architecture). Leasing
# these made unrelated items falsely contend (the STANDARDS.md dual-create + the
# OBJECTIVES/main-meta deadlock-dance in the 10h run). Space-padded for substring test.
SWARM_META_FREE="${SWARM_META_FREE:- ROADMAP.md OBJECTIVES.md AGENTS.md CLAUDE.md docs/architecture.md .opencode/lessons.md .opencode/memory/changelog.md .opencode/STANDARDS.md }"

# Expand a base path set toward the change's TRUE blast radius, so items that WILL collide are detected as
# OVERLAPPING at claim time (→ serialized) instead of racing and growing into a conflict mid-flight (the #1
# cause of wasted swarm work — see the 5/5-conflict run). Two layers, BOTH fail-open (any error/timeout →
# input unchanged, i.e. current behavior):
#   1) test↔source pairing — deterministic, existence-checked (the dominant observed collision: N items all
#      grew into the same *.test.ts). Adds only files that actually exist; never phantom paths.
#   2) GitNexus impact() UPSTREAM (dependants) on symbols named in `backticks` in the item — the ripple a
#      signature change forces onto callers. OPT-IN (SWARM_IMPACT=1; off by default — it is index-gated and
#      needs bounding); files-only, --depth 1, hub-skip, cached, fail-open. Layer 1 always runs.
_swarm_scope_expand(){
  local base="$1" text="$2" repo="${REPO:-$PWD}" extra="" p d b e cand
  # (1) test↔source pairing — deterministic, existence-checked, both directions, broad suffix coverage.
  for p in $base; do
    case "$p" in
      *.test.*|*.spec.*|*_test.go|*_test.py|test_*.py)                              # test → its source
        cand="$(printf '%s' "$p" | sed -E 's#(^|/)__tests__/#\1#; s#(^|/)tests?/#\1#; s/\.(test|spec)\.([a-z]+)$/.\2/; s/_test\.(go|py)$/.\1/; s#(^|/)test_([^/]+\.py)$#\1\2#')"
        [ "$cand" != "$p" ] && [ -f "$repo/$cand" ] && extra="$extra $cand" ;;
      *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.go|*.py)                                  # source → its test(s)
        d="$(dirname "$p")"; b="$(basename "$p")"; e="${b##*.}"; b="${b%.*}"
        for cand in "$d/$b.test.$e" "$d/$b.spec.$e" "$d/__tests__/$b.test.$e" "$d/__tests__/$b.test.tsx" "$d/__tests__/$b.spec.$e" "$d/${b}_test.$e" "$d/test_$b.$e"; do
          [ -f "$repo/$cand" ] && extra="$extra $cand"
        done ;;
    esac
  done
  # (2) GitNexus impact — OPT-IN (SWARM_IMPACT=1); OFF by default because it's index-gated and, unbounded,
  # can over-lease. Hardened: only when base is non-empty (never narrow the run-alone fail-safe), --depth 1
  # (direct dependants), FILES-only via -f existence check (drops directory paths that would lock a subtree),
  # per-symbol hub-skip (>10 files → skip), ≤3 symbols, 8s timeout, atomic HEAD-scoped cache, fully fail-open.
  if [ "${SWARM_IMPACT:-0}" != 0 ] && [ -n "${base// /}" ]; then
    local runner=""
    { [ -f "$repo/.gitnexus/run.cjs" ] && command -v node >/dev/null 2>&1; } && runner="node $repo/.gitnexus/run.cjs"
    [ -z "$runner" ] && command -v gitnexus >/dev/null 2>&1 && runner="gitnexus"
    if [ -n "$runner" ]; then
      local cache="${SWARM_DIR:-/tmp/ace-scope}/scope" key sym rn head imp="" one nf n=0
      rn="$(basename "$repo")"; head="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo x)"
      mkdir -p "$cache" 2>/dev/null || true
      # (query,base-sha) cache — SHARED across ALL workers: claims run in the coordinator's main checkout,
      # so $head is the base main sha every worker sees at once, and $cache lives under the single
      # coordinator SWARM_DIR (outside any per-worktree dir). Compute the impact ONCE per (query,sha); the
      # rest read the slice. A new main sha → new key → automatic invalidation (old entries age out with
      # the run). Hit/miss appended to .stats so the shared-cache win is measurable (`swarm scope-stats`).
      key="$(printf '%s@%s' "$head" "$text" | cksum | cut -d' ' -f1)"
      if [ -s "$cache/$key" ]; then extra="$extra $(cat "$cache/$key" 2>/dev/null)"
        printf 'hit %s\n' "$key" >> "$cache/.stats" 2>/dev/null || true
      else
        printf 'miss %s\n' "$key" >> "$cache/.stats" 2>/dev/null || true
        for sym in $(printf '%s' "$text" | grep -oE '`[A-Za-z_][A-Za-z0-9_]{2,}`' | tr -d '`' | sort -u); do
          [ "$n" -ge 3 ] && break; n=$((n+1))
          one="$( (cd "$repo" 2>/dev/null && timeout 8 $runner impact "$sym" -r "$rn" -d upstream --depth 1 2>/dev/null) | grep -oE '"filePath"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"([^"]+)"$/\1/' | sort -u)"
          nf="$(printf '%s\n' "$one" | grep -c .)"; [ "$nf" -gt 10 ] && continue   # hub symbol → don't lease a huge set
          for cand in $one; do [ -f "$repo/$cand" ] && imp="$imp $cand"; done       # FILES only (no directories)
        done
        imp="$(printf '%s' "$imp" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
        { printf '%s' "$imp" > "$cache/.$key.$$" && mv -f "$cache/.$key.$$" "$cache/$key"; } 2>/dev/null || true  # atomic write
        extra="$extra $imp"
      fi
    fi
  fi
  printf '%s %s' "$base" "$extra"
}
# _swarm_leasable_only "a b c" — keep only paths a worker MAY hold: drop coordinator/union/regenerated META
# (SWARM_META_FREE) + policy LEASE-FREE globs (contended-by-design), then normalize + dedup. ONE filter behind
# BOTH the plan-time scrape AND a mid-flight lease grow (swarm_touch), so a raw path can't re-enter via a grow.
_swarm_leasable_only() {
  if [ -z "${_SWARM_LEASEFREE+x}" ]; then
    _SWARM_LEASEFREE=" $(command -v swarm_policy_leasefree >/dev/null 2>&1 && swarm_policy_leasefree "${REPO:-$PWD}" 2>/dev/null) "
  fi
  local _t _lf out=""
  for _t in $1; do
    [ -n "$_t" ] || continue
    case "$SWARM_META_FREE" in *" $_t "*) continue ;; esac
    for _lf in $_SWARM_LEASEFREE; do case "$_t" in ${_lf//\*\*/\*}) continue 2 ;; esac; done
    out="$out $_t"
  done
  printf '%s' "$out" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
}
swarm_paths_for_item() {
  local text="$1" tok paths="" lf
  # lease-free globs from the conflict policy (union/struct/regenerate/assign/allocate/ignore) —
  # computed once per process. These are contended-by-design and must never be leased per-item.
  if [ -z "${_SWARM_LEASEFREE+x}" ]; then
    _SWARM_LEASEFREE=" $(command -v swarm_policy_leasefree >/dev/null 2>&1 && swarm_policy_leasefree "${REPO:-$PWD}" 2>/dev/null) "
  fi
  # path-ish tokens: a/b, a/b.ts, ci.sh, scripts/, packages/x
  for tok in $(printf '%s\n' "$text" | grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*|[A-Za-z0-9_-]+\.(sh|ts|tsx|js|jsx|json|prisma|yaml|yml|md)' | sort -u); do
    tok="${tok%/}"                       # strip trailing slash
    tok="${tok#./}"
    case "$tok" in
      http*|*.com*|*@*) continue ;;      # skip urls/emails
    esac
    # phantom guard (item 7): never lease a BARE directory that doesn't exist — prose like
    # "sentiment/ratings/scores" would otherwise lock a whole subtree that no file in the item touches.
    # Keep a token only if it carries a real file extension (a concrete file, even a new one) OR it already
    # exists in the repo (a real dir/file). Dropping a token just narrows the lease; if ALL drop, the
    # fail-safe below leases "." (run alone) — safer than leasing a phantom subtree.
    case "$tok" in
      *.sh|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.prisma|*.yaml|*.yml|*.md|*.go|*.py|*.rs|*.rb|*.java|*.php|*.toml|*.css|*.scss|*.html|*.sql|*.txt) : ;;
      *) [ -e "${REPO:-$PWD}/$tok" ] || continue ;;   # no known extension + not a real path → phantom, drop
    esac
    case "$SWARM_META_FREE" in *" $tok "*) continue ;; esac   # never lease coordinator/union/regenerated meta files
    for lf in $_SWARM_LEASEFREE; do case "$tok" in ${lf//\*\*/\*}) continue 2 ;; esac; done  # policy lease-free (glob)
    paths="$paths $tok"
  done
  # fail-safe: no concrete path token → unknown blast radius → lease "." and run ALONE. Must come BEFORE
  # expansion so a symbol-only item can never be narrowed to a partial (silently-overlapping) scope.
  [ -z "${paths// /}" ] && { printf '.\n'; return; }
  # expand toward the true blast radius, then RE-FILTER the whole set through meta/lease-free so an added
  # test/impacted file that happens to be policy-managed is never leased. Overlapping items now serialize
  # at claim time instead of racing into a mid-flight conflict.
  local _raw; _raw="$(_swarm_scope_expand "$paths" "$text")"
  paths="$(_swarm_leasable_only "$_raw")"   # re-filter post-expansion (an added test/impacted file may be policy-managed)
  [ -n "${paths// /}" ] && printf '%s\n' "${paths# }" || printf '.\n'
}

# _overlap "a b" "c d" — 0 if ANY path in set1 is a prefix-relation of any in
# set2 (same dir subtree), else 1. "." (repo root) overlaps everything.
_overlap() {
  local a b
  for a in $1; do
    for b in $2; do
      [ "$a" = "." ] || [ "$b" = "." ] && return 0
      case "$b/" in "$a/"*) return 0 ;; esac
      case "$a/" in "$b/"*) return 0 ;; esac
    done
  done
  return 1
}

# swarm_try_claim WORKER ITEM PATHS — atomically claim ITEM iff PATHS are
# disjoint from every ACTIVE claim. Prints "ok" / "busy". Idempotent per item.
swarm_try_claim() {
  local worker="$1" item="$2" paths="$3"
  _claim_txn() {
    local active existing h st tries tmp
    h="$(printf '%s' "$item" | cksum | cut -d' ' -f1)"
    # idempotent: never re-claim an item already active/done/parked. Retryable
    # states (none/orphaned/conflict/error) MAY be re-claimed within budget.
    st="$(jq -r --arg h "$h" '.claims[$h].status // "none"' "$STATE" 2>/dev/null)"
    case "$st" in active|done|parked) echo "$st"; return 1 ;; esac
    # poison guard: too many failed attempts → PARK (stop churning credits).
    tries="$(jq -r --arg h "$h" '.claims[$h].tries // 0' "$STATE" 2>/dev/null)"
    if [ "$tries" -ge "$MAX_TRIES" ]; then
      tmp="$(mktemp)"; jq --arg h "$h" --arg it "$item" \
        '.claims[$h] = ((.claims[$h] // {item:$it}) + {status:"parked"})' "$STATE" > "$tmp" && _putstate "$tmp"
      echo parked; return 1
    fi
    # reject overlap with any other in-flight lease
    active="$(jq -r '.claims[] | select(.status=="active") | .paths' "$STATE" 2>/dev/null)"
    while IFS= read -r existing; do
      [ -z "$existing" ] && continue
      if _overlap "$paths" "$existing"; then echo busy; return 1; fi
    done <<< "$active"
    tmp="$(mktemp)"
    jq --arg h "$h" --arg it "$item" --arg w "$worker" --arg p "$paths" \
       --argjson t "$(_now)" --argjson tr "$((tries+1))" \
       '.seq += 1 | .claims[$h] = {item:$it, paths:$p, worker:$w, status:"active", ts:$t, hb:$t, tries:$tr}' \
       "$STATE" > "$tmp" && _putstate "$tmp"
    echo ok; return 0
  }
  _with_lock _claim_txn
}

# swarm_next WORKER [ROADMAP] — pick the first OPEN roadmap item whose paths are
# disjoint from active claims, claim it atomically, print "HASH<TAB>ITEM". Empty
# output = nothing claimable right now (all remaining items overlap in-flight).
# _deps_met ITEM ROADMAP — 0 if the item declares no deps, or ALL its declared
# deps are already ticked [x] in the roadmap. An item may add "deps: web, root"
# (comma/space-separated keywords) so a dependent (e.g. `generate` needs the web
# server + the command registry) is NOT claimed until its prerequisites merge.
_deps_met() {
  local item="$1" rm="$2" deps d
  deps="$(printf '%s' "$item" | grep -oiE 'deps:[[:space:]]*[a-z0-9 ,._/-]+' | sed -E 's/^deps:[[:space:]]*//I')"
  [ -n "$deps" ] || return 0
  for d in $(printf '%s' "$deps" | tr ',' ' '); do
    [ -n "$d" ] || continue
    # match the dep as a WHOLE token on a CHECKED line — not a bare substring, so "auth" does NOT
    # satisfy "authorization-page" — and regex-escape it so a dep like "v1.0" isn't read as a pattern.
    local dq; dq="$(printf '%s' "$d" | sed 's/[^[:alnum:]_]/\\&/g')"
    grep -qiE "^[[:space:]]*- \[[xX]\] (.*[^[:alnum:]_])?${dq}([^[:alnum:]_]|$)" "$rm" 2>/dev/null || return 1
  done
  return 0
}
swarm_next() {
  local worker="$1" roadmap="${2:-ROADMAP.md}"
  [ -f "$roadmap" ] || { echo "swarm: no $roadmap" >&2; return 2; }
  local line item paths
  while IFS= read -r line; do
    item="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[ \] //; s/[[:space:]]+$//')"
    [ -z "$item" ] && continue
    printf '%s' "$item" | grep -qi 'add your first' && continue
    _deps_met "$item" "$roadmap" || continue          # prerequisites not merged yet → try a later item
    paths="$(swarm_paths_for_item "$item")"
    if [ "$(swarm_try_claim "$worker" "$item" "$paths")" = "ok" ]; then
      printf '%s\t%s\n' "$(printf '%s' "$item" | cksum | cut -d' ' -f1)" "$item"
      return 0
    fi
  done < <(grep -E '^[[:space:]]*- \[ \] ' "$roadmap")   # NO -n: a line-number prefix ('N:') leaks past the
  return 0   # nothing claimable                          # ^-anchored sed above into $item, breaking run_worker's merged-checkbox detection
}

# swarm_disjoint_batch [ROADMAP] [CAP] — how many OPEN, deps-met roadmap items could run in PARALLEL
# right now: a greedy PATH-DISJOINT packing (an item is counted only if its leased paths don't overlap
# an already-counted item — the same overlap rule swarm_next claims by). READ-ONLY: claims nothing,
# mutates no state. Stops as soon as CAP items are found (default = SWARM_CEIL, fallback 5) so the scan
# is bounded by the worker ceiling, not the roadmap length. The coordinator uses this to clamp workers
# to min(requested, disjoint, ceiling) — spawning more workers than disjoint items just makes idlers that
# contend on the lease store (S3). Fail-open: any error still prints a number.
swarm_disjoint_batch() {
  local roadmap="${1:-ROADMAP.md}" cap="${2:-${SWARM_CEIL:-5}}"
  case "$cap" in *[!0-9]*|'') cap=5 ;; esac; [ "$cap" -lt 1 ] && cap=1
  [ -f "$roadmap" ] || { echo 0; return 0; }
  local line item paths n=0 i clash
  local -a sets=()
  while IFS= read -r line; do
    item="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[ \] //; s/[[:space:]]+$//')"
    [ -z "$item" ] && continue
    printf '%s' "$item" | grep -qi 'add your first' && continue
    _deps_met "$item" "$roadmap" || continue          # prerequisites not merged yet → not claimable now
    paths="$(swarm_paths_for_item "$item")"
    clash=0
    if [ "$n" -gt 0 ]; then
      for i in "${sets[@]}"; do _overlap "$paths" "$i" && { clash=1; break; }; done
    fi
    [ "$clash" = 1 ] && continue                        # overlaps an already-counted item → would serialize
    sets+=("$paths"); n=$((n+1))
    [ "$n" -ge "$cap" ] && break
  done < <(grep -E '^[[:space:]]*- \[ \] ' "$roadmap")   # NO -n: an 'N:' prefix would leak past the ^-anchored sed into $item
  echo "$n"
}

# swarm_disjoint_plan [ROADMAP] [CAP] — the PLAN-TIME conflict-aware SCHEDULE (B2). READ-ONLY: claims
# nothing, mutates no state. Walks OPEN roadmap items top-down and greedily packs a MAXIMAL PATH-DISJOINT
# batch using the SAME _overlap rule swarm_next/swarm_try_claim enforce at runtime, so the plan matches
# what workers will actually be able to claim. Each item's FOOTPRINT = swarm_paths_for_item (its leased
# edit set ∪ the test↔source pairing ∪ the bounded, OPT-IN SWARM_IMPACT blast radius — all fail-open).
# Classifies every item and prints TAB-separated "<tag>\t<paths>\t<item>":
#   parallel  — footprint disjoint from every already-picked item AND the batch isn't full → run NOW
#   serialize — footprint intersects a picked item (shares a file) OR the CAP is reached → a later lane
#   blocked   — declared deps: not yet merged ([x]) → not claimable until its prerequisites land
# The PARALLEL set is capped at CAP (default = SWARM_CEIL) so the plan never exceeds the worker ceiling
# (S3). The count of `parallel` lines equals swarm_disjoint_batch (same greedy packing). Deterministic +
# idempotent for a fixed (ROADMAP, base-main-sha): footprints are cache-keyed on the base sha inside
# _swarm_scope_expand, so re-running at the same sha re-uses them (no re-query). Fail-open: any error
# still yields a well-formed (possibly empty) plan — the coordinator never blocks dispatch on it.
swarm_disjoint_plan() {
  local roadmap="${1:-ROADMAP.md}" cap="${2:-${SWARM_CEIL:-5}}"
  case "$cap" in *[!0-9]*|'') cap=5 ;; esac; [ "$cap" -lt 1 ] && cap=1
  [ -f "$roadmap" ] || return 0
  local line item paths n=0 i clash tag
  local -a sets=()
  while IFS= read -r line; do
    item="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[ \] //; s/[[:space:]]+$//')"
    [ -z "$item" ] && continue
    printf '%s' "$item" | grep -qi 'add your first' && continue
    if ! _deps_met "$item" "$roadmap"; then
      printf 'blocked\t%s\t%s\n' '-' "$item"; continue
    fi
    paths="$(swarm_paths_for_item "$item")"
    clash=0
    if [ "$n" -gt 0 ]; then
      for i in "${sets[@]}"; do _overlap "$paths" "$i" && { clash=1; break; }; done
    fi
    if [ "$clash" = 1 ] || [ "$n" -ge "$cap" ]; then
      tag=serialize                                    # shares a file with a picked item, or batch full
    else
      tag=parallel; sets+=("$paths"); n=$((n+1))       # disjoint + room → this generation's parallel batch
    fi
    printf '%s\t%s\t%s\n' "$tag" "$paths" "$item"
  done < <(grep -E '^[[:space:]]*- \[ \] ' "$roadmap")   # NO -n: an 'N:' prefix would leak past the ^-anchored sed into $item
}

# swarm_scope_stats — print the shared impact-graph cache hit/miss tally (the SWARM_IMPACT=1 path).
# Proves the (query,base-sha) cache in _swarm_scope_expand is SHARED across workers: a query repeated at
# the same base main sha bills as a hit, not a re-query. Empty/absent → 0/0.
swarm_scope_stats() {
  local f="${SWARM_DIR:-/tmp/ace-scope}/scope/.stats" h m
  h="$(grep -c '^hit '  "$f" 2>/dev/null)"; [ -z "$h" ] && h=0
  m="$(grep -c '^miss ' "$f" 2>/dev/null)"; [ -z "$m" ] && m=0
  printf 'impact-graph cache: %s hit / %s miss  (%s)\n' "$h" "$m" "$f"
}

# swarm_touch WORKER HASH ADDPATHS — extend an ACTIVE claim mid-flight when a
# flow discovers it must edit more files. Succeeds iff ADDPATHS don't overlap
# ANOTHER worker's active lease (a flow's own lease can always grow). ok/busy.
swarm_touch() {
  local worker="$1" hash="$2" add
  add="$(_swarm_leasable_only "$3")"   # item 6: re-filter a mid-flight grow so a raw/policy-managed path can't re-enter a lease
  [ -n "${add// /}" ] || { echo ok; return 0; }   # nothing leasable to add → no-op success
  _touch_txn() {
    local other
    other="$(jq -r --arg h "$hash" '.claims|to_entries[]|select(.value.status=="active" and .key!=$h)|.value.paths' "$STATE" 2>/dev/null)"
    while IFS= read -r other; do [ -z "$other" ] && continue
      if _overlap "$add" "$other"; then echo busy; return 1; fi
    done <<< "$other"
    local tmp; tmp="$(mktemp)"
    jq --arg h "$hash" --arg p "$add" \
       '.claims[$h].paths = ((.claims[$h].paths // "") + " " + $p)' "$STATE" > "$tmp" && _putstate "$tmp"
    echo ok
  }
  _with_lock _touch_txn
}

# with_merge_lock CMD... — serialize merges into main. Only ONE flow merges at a
# time: it rebases onto freshly-updated main and re-runs the gate, so the merge
# is clean BY CONSTRUCTION (disjoint leases ⇒ no overlapping hunks) and any
# semantic break surfaces as a RED gate HERE, never on main.
with_merge_lock() {
  swarm_init
  exec {mfd}>"$MERGE_LOCK"
  flock -w 900 "$mfd" || { echo "swarm: merge-lock timeout" >&2; return 3; }
  "$@"; local rc=$?
  flock -u "$mfd"; exec {mfd}>&-
  return $rc
}

swarm_release() {
  local worker="$1" hash="$2" status="${3:-done}"
  _rel_txn() { local tmp; tmp="$(mktemp)"
    jq --arg h "$hash" --arg s "$status" \
       'if .claims[$h] then .claims[$h].status=$s else . end' "$STATE" > "$tmp" && _putstate "$tmp"; }
  _with_lock _rel_txn
}

# ---- self-healing: liveness + reclaim + reconcile ----------------------------
# swarm_beat WORKER HASH — a live worker refreshes its lease heartbeat.
swarm_beat() {
  local hash="$2"
  _beat_txn() { local tmp; tmp="$(mktemp)"
    jq --arg h "$hash" --argjson t "$(_now)" \
       'if (.claims[$h].status // "") == "active" then .claims[$h].hb = $t else . end' "$STATE" > "$tmp" && _putstate "$tmp"; }
  _with_lock _beat_txn
}

# swarm_reap [TTL] — reclaim leases whose worker went silent (crash/hang/OOM).
# Within retry budget → "orphaned" (item claimable again, tries kept); over
# budget → "parked". Prints one line per action: "REAP <hash> <item>" /
# "PARK <hash> <item>" so the coordinator can clean the worktree + alert.
swarm_reap() {
  local ttl="${1:-$LEASE_TTL}"
  _reap_txn() {
    local now h it tries tmp; now="$(_now)"
    while IFS=$'\t' read -r h it; do
      [ -z "$h" ] && continue
      tries="$(jq -r --arg h "$h" '.claims[$h].tries // 1' "$STATE")"
      tmp="$(mktemp)"
      if [ "$tries" -ge "$MAX_TRIES" ]; then
        jq --arg h "$h" '.claims[$h].status="parked"' "$STATE" > "$tmp" && _putstate "$tmp"; echo "PARK	$h	$it"
      else
        jq --arg h "$h" '.claims[$h].status="orphaned"' "$STATE" > "$tmp" && _putstate "$tmp"; echo "REAP	$h	$it"
      fi
    done < <(jq -r --argjson now "$now" --argjson ttl "$ttl" \
      '.claims|to_entries[]|select(.value.status=="active" and ($now - (.value.hb // .value.ts)) > $ttl)|"\(.key)\t\(.value.item)"' "$STATE" 2>/dev/null)
  }
  _with_lock _reap_txn
}

# swarm_reconcile — on coordinator (re)start, any lease still "active" is a
# leftover from a crashed prior run → orphan it (requeue, keep tries). Prints the
# reclaimed hashes so the coordinator prunes their worktrees/branches.
swarm_reconcile() {
  _rec_txn() {
    local h it tmp
    while IFS=$'\t' read -r h it; do
      [ -z "$h" ] && continue
      tmp="$(mktemp)"; jq --arg h "$h" '.claims[$h].status="orphaned"' "$STATE" > "$tmp" && _putstate "$tmp"
      echo "RECLAIM	$h	$it"
    done < <(jq -r '.claims|to_entries[]|select(.value.status=="active")|"\(.key)\t\(.value.item)"' "$STATE" 2>/dev/null)
  }
  _with_lock _rec_txn
}

# swarm_post FROM TYPE BODY [ITEM] [TO] [TOPIC] — append to the bus. TO=""
# broadcasts; TO=<worker> directs it to one flow's inbox. TOPIC is usually the
# contended path, so a holder can see who's waiting on what.
swarm_post() {
  swarm_init
  local from="$1" type="$2" body="$3" item="${4:-}" to="${5:-}" topic="${6:-}"
  exec {fd}>"$LOCK"; flock -w 10 "$fd" || return 3
  jq -cn --arg f "$from" --arg t "$type" --arg b "$body" --arg it "$item" \
         --arg to "$to" --arg tp "$topic" --argjson ts "$(_now)" \
     '{ts:$ts, from:$f, to:$to, type:$t, body:$b, item:$it, topic:$tp}' >> "$MSG"
  # mirror onto the unified event stream (dash + web read this): map bus type → level
  local lvl=info; case "$type" in done|acquired) lvl=ok;; conflict|error|gate-red) lvl=err;; waiting|blocked|defer|needs-attention|reap|stopped|incomplete) lvl=warn;; claimed|merging) lvl=accent;; esac
  jq -cn --arg w "$from" --arg t "$type" --arg b "$body" --arg it "$item" --arg l "$lvl" --argjson ts "$(_now)" \
     '{ts:$ts, run:"", worker:$w, feat:$it, hash:"", phase:$t, agent:"coordinator", level:$l, msg:$b}' >> "$SWARM_DIR/events.jsonl" 2>/dev/null || true
  flock -u "$fd"; exec {fd}>&-
}

# swarm_inbox WORKER [N] — messages addressed to WORKER or broadcast (to="").
swarm_inbox() {
  swarm_init
  jq -rc --arg w "$1" 'select((.to // "")=="" or (.to // "")==$w)
      | "\(.ts|todate[11:19]) [\(.from)\(if (.to//"")!="" then "→"+.to else "" end)] \(.type): \(.body)"' \
    "$MSG" 2>/dev/null | tail -n "${2:-20}"
}

# swarm_holder_of PATHS — print "worker<TAB>hash" of an ACTIVE claim whose lease
# overlaps PATHS (the flow currently blocking you), or nothing.
swarm_holder_of() {
  swarm_init
  local h w p
  while IFS=$'\t' read -r h w p; do
    [ -z "$h" ] && continue
    if _overlap "$1" "$p"; then printf '%s\t%s\n' "$w" "$h"; return 0; fi
  done < <(jq -r '.claims|to_entries[]|select(.value.status=="active")|"\(.key)\t\(.value.worker)\t\(.value.paths)"' "$STATE" 2>/dev/null)
  return 1
}

# swarm_wait WORKER HASH PATHS [TIMEOUT] [POLL] — a flow that ALREADY holds an
# item (HASH active) needs to EXTEND onto PATHS held by another flow. Tells the
# holder (directed "waiting" msg), then block-polls until free or TIMEOUT.
# Returns ok | timeout. On timeout the caller MUST defer (release + requeue) —
# it must never keep holding while blocked, or two such waits could deadlock.
swarm_wait() {
  local worker="$1" hash="$2" paths="$3" timeout="${4:-120}" poll="${5:-2}" waited=0 r holder
  r="$(swarm_touch "$worker" "$hash" "$paths")"
  [ "$r" = ok ] && { echo ok; return 0; }
  holder="$(swarm_holder_of "$paths" | cut -f1)"
  swarm_post "$worker" waiting "need ⟨$paths⟩ (held by ${holder:-?}) — release when you can" "" "${holder:-}" "$paths"
  while [ "$waited" -lt "$timeout" ]; do
    sleep "$poll"; waited=$((waited+poll))
    r="$(swarm_touch "$worker" "$hash" "$paths")"
    if [ "$r" = ok ]; then
      swarm_post "$worker" acquired "got ⟨$paths⟩ after ${waited}s" "" "" "$paths"; echo ok; return 0
    fi
  done
  swarm_post "$worker" defer "gave up on ⟨$paths⟩ after ${timeout}s — requeue item" "" "" "$paths"
  echo timeout; return 1
}

# swarm_waittest — prove wait/notify + directed inbox + deadlock-free release.
swarm_waittest() {
  export SWARM_DIR; SWARM_DIR="$(mktemp -d)/s"; swarm_init
  swarm_try_claim w1 item1 "apps/portal/lib/csrf.ts" >/dev/null   # w1 holds csrf.ts
  swarm_try_claim w2 item2 "apps/portal/other.ts"    >/dev/null   # w2 holds other.ts
  local h1 h2; h1="$(printf item1|cksum|cut -d' ' -f1)"; h2="$(printf item2|cksum|cut -d' ' -f1)"
  ( sleep 4; swarm_release w1 "$h1" done >/dev/null ) &            # w1 frees csrf.ts at ~4s
  local t0 t1 r; t0="$(_now)"
  r="$(swarm_wait w2 "$h2" "apps/portal/lib/csrf.ts" 20 1)"        # w2 needs csrf.ts → waits
  t1="$(_now)"
  local got; got="$(swarm_inbox w1 50 | grep -c waiting)"
  echo "[waittest] w2 wait -> $r after $((t1-t0))s  (expect ok, ~4s)"
  echo "[waittest] directed 'waiting' msg in w1 inbox: $got  (expect >=1)"
  [ "$r" = ok ] && [ "$got" -ge 1 ] && echo "[waittest] PASS ✓" || echo "[waittest] FAIL ✗"
}

# coloured, worker-tagged bus tail: [ts] [wN] type: body — type & worker colour-coded.
swarm_tail() {
  swarm_init
  tail -n "${1:-20}" "$MSG" 2>/dev/null | jq -rc '[(.ts|strftime("%H:%M:%S")), .from, .type, .body]|@tsv' 2>/dev/null \
    | while IFS=$'\t' read -r ts from typ body; do
        printf '%s%s%s %s[%s]%s %s%s%s %s\n' "$_DIM" "$ts" "$_R" "$(_wcol "$from")" "$(_wname "$from")" "$_R" "$(_typc "$typ")" "$typ:" "$_R" "$body"
      done
}

# swarm_statusline — ONE informative line (what the MCP `status` tool returns to the
# agent, so it never sees an empty "Unknown"). No ANSI (piped to the model).
swarm_statusline() {
  swarm_init
  local n rows; n=$(jq -r '[.claims[]|select(.status=="active")]|length' "$STATE" 2>/dev/null || echo 0)
  rows=$(jq -rc '.claims|to_entries[]|select(.value.status=="active")|"\(.value.worker):\(.value.item|gsub("^[0-9]+:[[:space:]]*- \\[[ xX]\\] ";"")|gsub("\\*";"")|.[0:20])"' "$STATE" 2>/dev/null | tr '\n' ' ')
  printf 'swarm: %s active claim(s) · seq %s%s\n' "$n" "$(jq -r '.seq' "$STATE" 2>/dev/null || echo '?')" "${rows:+ · ${rows% }}"
}

# swarm_status — the RICH terminal view (coloured, tagged). Piped/MCP callers get plain.
swarm_status() {
  swarm_init
  local n total seq
  n=$(jq -r '[.claims[]|select(.status=="active")]|length' "$STATE" 2>/dev/null || echo 0)
  total=$(jq -r '.claims|length' "$STATE" 2>/dev/null || echo 0)
  seq=$(jq -r '.seq' "$STATE" 2>/dev/null || echo 0)
  printf '%s🐝 swarm%s %s· %s%s\n' "$_B$_PUR" "$_R" "$_MUT" "$(basename "$SWARM_DIR")" "$_R"
  printf '   %sactive%s %s%s%s   %stotal%s %s   %sseq%s %s   %sstore%s %s%s%s\n' \
    "$_MUT" "$_R" "$_GRN$_B" "$n" "$_R" "$_MUT" "$_R" "$total" "$_MUT" "$_R" "$seq" "$_MUT" "$_R" "$_DIM" "$SWARM_DIR" "$_R"
  if [ "$n" = 0 ]; then printf '   %sno active workers (idle / drained)%s\n' "$_DIM" "$_R"; return; fi
  jq -rc '.claims|to_entries[]|select(.value.status=="active")|[.value.worker,.value.item,.value.paths]|@tsv' "$STATE" 2>/dev/null \
    | while IFS=$'\t' read -r w item paths; do
        local ph="" st="$SWARM_DIR/status/$w.stat"
        [ -f "$st" ] && ph="$(sed -n 's/^phase=//p' "$st")"
        printf '   %s●%s %s[%s]%s %s%s%s %s%s%s ⟨%s%s%s⟩\n' \
          "$(_wcol "$w")" "$_R" "$(_wcol "$w")$_B" "$(_wname "$w")" "$_R" "$_FG" "$(_clip "$item" 30)" "$_R" \
          "$_GOLD" "${ph:+·$ph}" "$_R" "$_DIM" "$(printf '%s' "$paths" | cut -c1-40)" "$_R"
      done
}

# swarm_stats — truthful outcome telemetry (item 5). Classifies how each claimed item ENDED from the event
# stream: merged (done) · conflict (a real merge conflict) · gate-red (the gate never went green) · stopped
# (a non-code halt: limit/rathole/review) · incomplete (not-yet-merged). The old dash called EVERY non-merge
# "conflict"; this makes the real failure mode visible so regressions are actionable. Also prints the current
# path-disjoint plan (how much parallelism the ROADMAP actually affords). Read-only; no credits.
swarm_stats() {
  swarm_init
  local ev="$SWARM_DIR/events.jsonl"
  printf '%s🐝 swarm stats%s %s· %s%s\n' "${_B:-}${_PUR:-}" "${_R:-}" "${_MUT:-}" "$(basename "$SWARM_DIR")" "${_R:-}"
  if [ -s "$ev" ] && command -v jq >/dev/null 2>&1; then
    # LAST terminal event per (worker,item) — a retried item is counted once, in its FINAL state.
    local rows; rows="$(jq -rc 'select(.phase|IN("done","conflict","gate-red","stopped","incomplete"))|[.worker,.feat,.phase]|@tsv' "$ev" 2>/dev/null \
      | awk -F'\t' '{o[$1 FS $2]=$3} END{for(k in o) print o[k]}')"
    local nd nc ng ns ni
    nd="$(printf '%s\n' "$rows" | grep -c '^done$')"; nc="$(printf '%s\n' "$rows" | grep -c '^conflict$')"
    ng="$(printf '%s\n' "$rows" | grep -c '^gate-red$')"; ns="$(printf '%s\n' "$rows" | grep -c '^stopped$')"
    ni="$(printf '%s\n' "$rows" | grep -c '^incomplete$')"
    printf '   %smerged%s %s%s%s   %sconflict%s %s%s%s   %sgate-red%s %s%s%s   %sstopped%s %s%s%s   %sincomplete%s %s%s%s\n' \
      "${_MUT:-}" "${_R:-}" "${_GRN:-}${_B:-}" "$nd" "${_R:-}" \
      "${_MUT:-}" "${_R:-}" "${_RED:-}" "$nc" "${_R:-}" \
      "${_MUT:-}" "${_R:-}" "${_RED:-}" "$ng" "${_R:-}" \
      "${_MUT:-}" "${_R:-}" "${_GOLD:-}" "$ns" "${_R:-}" \
      "${_MUT:-}" "${_R:-}" "${_GOLD:-}" "$ni" "${_R:-}"
  else printf '   %sno events yet (run: ace swarm start)%s\n' "${_DIM:-}" "${_R:-}"; fi
  local rm="${REPO:-$PWD}/ROADMAP.md"
  if [ -f "$rm" ]; then
    local plan par ser blk; plan="$(swarm_disjoint_plan "$rm" "${SWARM_CEIL:-5}" 2>/dev/null)"
    par="$(printf '%s\n' "$plan" | grep -c '^parallel')"; ser="$(printf '%s\n' "$plan" | grep -c '^serialize')"; blk="$(printf '%s\n' "$plan" | grep -c '^blocked')"
    printf '   %splan%s   %s%s parallel%s · %s serialized (share a file) · %s dep-blocked  (cap %s)\n' \
      "${_MUT:-}" "${_R:-}" "${_GRN:-}" "$par" "${_R:-}" "$ser" "$blk" "${SWARM_CEIL:-5}"
  fi
}

# --- self-test: prove concurrency safety + path-disjoint claiming. ------------
swarm_selftest() {
  export SWARM_DIR; SWARM_DIR="$(mktemp -d)/swarm"; LOCK="$SWARM_DIR/.lock"; STATE="$SWARM_DIR/state.json"; MSG="$SWARM_DIR/messages.jsonl"
  swarm_init
  echo "[selftest] store: $SWARM_DIR"
  # 1) two DISJOINT paths claimed concurrently → BOTH succeed
  local A B
  A="$(swarm_try_claim wA "item-A" "apps/portal/settings")"
  B="$(swarm_try_claim wB "item-B" "scripts/deploy.sh")"
  echo "[selftest] disjoint claims: A=$A B=$B  (expect ok ok)"
  # 2) OVERLAPPING path → second is rejected
  local C
  C="$(swarm_try_claim wC "item-C" "apps/portal/settings/tls")"
  echo "[selftest] overlapping claim: C=$C  (expect busy)"
  # 3) 8 concurrent claimers racing the SAME path → exactly ONE wins
  local dir; dir="$(dirname "$STATE")"
  : > "$dir/wins"
  for i in $(seq 1 8); do
    ( r="$(swarm_try_claim "w$i" "race-item" "packages/shared")"; [ "$r" = ok ] && echo win >> "$dir/wins" ) &
  done
  wait
  local wins; wins="$(wc -l < "$dir/wins" | tr -d ' ')"
  echo "[selftest] 8-way race on same path: winners=$wins  (expect 1)"
  # 4) release frees the lease → path claimable again
  swarm_release wA "$(printf '%s' "item-A" | cksum | cut -d' ' -f1)" done >/dev/null
  local D; D="$(swarm_try_claim wD "item-D" "apps/portal/settings")"
  echo "[selftest] reclaim after release: D=$D  (expect ok)"
  # 5) swarm_next emits a CLEAN item — no 'N:' line-number prefix, no '- [ ]' checkbox.
  #    Regression guard: grep -n used to leak 'N:' into $item, so run_worker's merged-checkbox
  #    detection (swarm-run.sh) never matched → every merged item mislabelled 'conflict' → parked.
  local rmn nitem nfield clean=1
  rmn="$(dirname "$STATE")/roadmap-next.md"
  printf '%s\n' '# Roadmap' '- [ ] owner-gate `services/reporting/export.ts` route' '- [x] already done' > "$rmn"
  nitem="$(swarm_next wNext "$rmn")"; nfield="${nitem#*$'\t'}"
  printf '%s' "$nfield" | grep -qE '^[0-9]+:' && clean=0
  printf '%s' "$nfield" | grep -qF -- '- [ ]' && clean=0
  [ -n "$nfield" ] || clean=0
  echo "[selftest] swarm_next clean item: '$nfield'  clean=$clean  (expect 1 — no 'N:'/'- [ ]')"
  # 6) phantom guard (item 7): a slash-token with no extension that isn't in the repo is NOT leased.
  local _ph nophantom=1; _ph="$(REPO="$(mktemp -d)" swarm_paths_for_item 'improve sentiment/ratings scoring in apps/x.ts')"
  printf '%s' "$_ph" | grep -q 'sentiment/ratings' && nophantom=0
  echo "[selftest] phantom bare-dir dropped: '$_ph'  nophantom=$nophantom  (expect 1 — keeps apps/x.ts, drops sentiment/ratings)"
  # 7) swarm_touch re-filter (item 6): a mid-flight grow onto a META file (ROADMAP.md) is filtered out.
  swarm_try_claim wT "touch-item" "apps/t.ts" >/dev/null
  local hT nofilt=1; hT="$(printf '%s' "touch-item" | cksum | cut -d' ' -f1)"
  swarm_touch wT "$hT" "ROADMAP.md apps/more.ts" >/dev/null
  local leaseT; leaseT="$(jq -r --arg h "$hT" '.claims[$h].paths' "$STATE" 2>/dev/null)"
  printf '%s' "$leaseT" | grep -q 'ROADMAP.md' && nofilt=0
  echo "[selftest] touch re-filters meta: '$leaseT'  nofilt=$nofilt  (expect 1 — no ROADMAP.md in the lease)"
  # verdict
  [ "$A" = ok ] && [ "$B" = ok ] && [ "$C" = busy ] && [ "$wins" = 1 ] && [ "$D" = ok ] && [ "$clean" = 1 ] \
    && [ "$nophantom" = 1 ] && [ "$nofilt" = 1 ] \
    && echo "[selftest] PASS ✓" || { echo "[selftest] FAIL ✗"; return 1; }
}

# swarm_sched_selftest — prove the B2 plan-time scheduler (swarm_disjoint_plan) is correct + deterministic
# on a synthetic ROADMAP with known footprints. HERMETIC: a scratch REPO with no real files, impact OFF,
# and the policy lease-free filter neutralized, so an item's footprint is exactly the path tokens in its
# text (no environment dependence). Asserts the core safety property (the parallel batch is pairwise
# path-disjoint — two items sharing a file are NEVER co-scheduled), plus classification, the worker-ceiling
# cap, agreement with swarm_disjoint_batch, and idempotency.
swarm_sched_selftest() {
  export SWARM_DIR; SWARM_DIR="$(mktemp -d)/swarm"; LOCK="$SWARM_DIR/.lock"; STATE="$SWARM_DIR/state.json"; MSG="$SWARM_DIR/messages.jsonl"
  swarm_init
  local d rm; d="$(mktemp -d)"; rm="$d/ROADMAP.md"
  export REPO="$d"; export SWARM_IMPACT=0; _SWARM_LEASEFREE=" "   # hermetic footprints: no repo, no impact, no policy filter
  cat > "$rm" <<'EOF'
# ROADMAP
## Next
- [ ] add `foo` endpoint  Files: apps/web/foo.ts
- [ ] add `bar` model  Files: apps/api/bar.ts
- [ ] restyle the foo page  Files: apps/web/foo.ts
- [ ] add `baz` util  Files: packages/util/baz.ts
- [ ] wire baz into the CLI  Files: scripts/cli.sh  deps: baz
EOF
  echo "[sched-selftest] store: $SWARM_DIR  roadmap: $rm"
  local plan; plan="$(swarm_disjoint_plan "$rm" 5)"
  printf '%s\n' "$plan" | sed 's/^/[sched-selftest]   /'
  # A) core safety: the PARALLEL batch is pairwise PATH-DISJOINT — no two co-scheduled items share a file.
  local -a psets=(); local tag paths _item dis=1 np i j
  while IFS=$'\t' read -r tag paths _item; do [ "$tag" = parallel ] && psets+=("$paths"); done <<< "$plan"
  np="${#psets[@]}"
  for ((i=0;i<np;i++)); do for ((j=i+1;j<np;j++)); do _overlap "${psets[i]}" "${psets[j]}" && dis=0; done; done
  # B) classification: foo/bar/baz are the 3 disjoint → parallel; the restyle shares foo.ts → serialize;
  #    the CLI task deps: on the still-OPEN baz → blocked.
  local n_par n_ser n_blk restyle_tag baz_dep_tag
  n_par="$(printf '%s\n' "$plan" | grep -c '^parallel')"
  n_ser="$(printf '%s\n' "$plan" | grep -c '^serialize')"
  n_blk="$(printf '%s\n' "$plan" | grep -c '^blocked')"
  restyle_tag="$(printf '%s\n' "$plan" | awk -F'\t' '/restyle the foo/{print $1}')"
  baz_dep_tag="$(printf '%s\n' "$plan" | awk -F'\t' '/wire baz into the CLI/{print $1}')"
  # C) worker-ceiling cap: CAP=2 → only two go parallel, the 3rd disjoint item serializes into a later lane.
  local n_par_cap2; n_par_cap2="$(swarm_disjoint_plan "$rm" 2 | grep -c '^parallel')"
  # D) the plan's parallel count agrees with swarm_disjoint_batch (both use the same greedy packing).
  local n_batch; n_batch="$(swarm_disjoint_batch "$rm" 5)"
  # E) idempotent — same (roadmap, sha) → byte-identical plan (footprints are cache-keyed on the base sha).
  local plan2 idem=0; plan2="$(swarm_disjoint_plan "$rm" 5)"; [ "$plan" = "$plan2" ] && idem=1
  echo "[sched-selftest] parallel=$n_par serialize=$n_ser blocked=$n_blk  pairwise-disjoint=$dis  (expect 3/1/1/1)"
  echo "[sched-selftest] restyle-foo=$restyle_tag (expect serialize)  baz-dependent=$baz_dep_tag (expect blocked)"
  echo "[sched-selftest] cap=2 → parallel=$n_par_cap2 (expect 2)  ·  disjoint_batch=$n_batch == parallel=$n_par  ·  idempotent=$idem"
  [ "$dis" = 1 ] && [ "$n_par" = 3 ] && [ "$restyle_tag" = serialize ] && [ "$baz_dep_tag" = blocked ] \
    && [ "$n_par_cap2" = 2 ] && [ "$n_batch" = "$n_par" ] && [ "$idem" = 1 ] \
    && echo "[sched-selftest] PASS ✓" || { echo "[sched-selftest] FAIL ✗"; return 1; }
}

# Only run the CLI when executed directly — stay quiet when sourced (swarm-run.sh).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    init)     swarm_init ;;
    next)     swarm_next "${2:-w0}" "${3:-ROADMAP.md}" ;;
    claim)    swarm_try_claim "${2:?worker}" "${3:?item}" "${4:?paths}" ;;
    touch)    swarm_touch "${2:?worker}" "${3:?hash}" "${4:?paths}" ;;
    release)  swarm_release "${2:?worker}" "${3:?hash}" "${4:-done}" ;;
    post)     swarm_post "${2:?from}" "${3:?type}" "${4:?body}" "${5:-}" "${6:-}" "${7:-}" ;;
    wait)     swarm_wait "${2:?worker}" "${3:?hash}" "${4:?paths}" "${5:-120}" "${6:-2}" ;;
    inbox)    swarm_inbox "${2:?worker}" "${3:-20}" ;;
    holder)   swarm_holder_of "${2:?paths}" ;;
    beat)     swarm_beat "${2:?worker}" "${3:?hash}" ;;
    reap)     swarm_reap "${2:-$LEASE_TTL}" ;;
    reconcile) swarm_reconcile ;;
    tail)     swarm_tail "${2:-20}" ;;
    waittest) swarm_waittest ;;
    status)   swarm_status ;;
    statusline) swarm_statusline ;;
    paths)    swarm_paths_for_item "${2:?item text}" ;;
    selftest) swarm_selftest ;;
    sched-selftest) swarm_sched_selftest ;;
    policy)         swarm_policy_table "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" ;;
    policy-selftest) swarm_policy_selftest ;;
    mergiraf-selftest) swarm_mergiraf_selftest ;;
    aggregate-lessons) swarm_aggregate_lessons "${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" ;;
    disjoint-batch) swarm_disjoint_batch "${2:-ROADMAP.md}" "${3:-${SWARM_CEIL:-5}}" ;;
    disjoint-plan)  swarm_disjoint_plan "${2:-ROADMAP.md}" "${3:-${SWARM_CEIL:-5}}" ;;
    scope-stats)    swarm_scope_stats ;;
    stats)          swarm_stats ;;
    *) echo "usage: swarm.sh {init|next|claim|release|post|tail|status|paths|selftest|sched-selftest|policy|policy-selftest|mergiraf-selftest|aggregate-lessons|disjoint-batch|disjoint-plan|scope-stats}" >&2; exit 2 ;;
  esac
fi
