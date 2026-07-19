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
_typc(){ case "$1" in done|acquired|ok) printf '%s' "$_GRN";; conflict|error|err|gate-red|red-main) printf '%s' "$_RED";;
  waiting|blocked|defer|needs-attention|reap|warn|stopped|incomplete|standby|abandoned) printf '%s' "$_GOLD";; claimed|merging|accent|fixer|main-adv) printf '%s' "$_PUR";; *) printf '%s' "$_FG";; esac; }
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

# swarm_plan_lint [ROADMAP] — P0.1: a deterministic pre-flight on the OPEN roadmap items the swarm
# will actually try to run, using the SAME footprint model (swarm_paths_for_item + _overlap) the
# runtime leases with. Two checks, mirroring the two failure modes from run 260716:
#   COLLIDE  — two OPEN items whose leased footprints overlap will SERIALIZE (only one runs at a
#              time). This is the hot-file starvation that pinned worker-2 in 260716 (access-control.ts
#              in 6 items, schema.prisma in 5). The fix is to re-slice into disjoint files or chain
#              them with `deps:` — reported so the planner can act on the SPECIFIC pairs.
#   OVERSIZE — an item whose Files: hint names > PLAN_MAX_FILES concrete files is a BIG-TASK-timeout
#              risk. Coarse by design (won't catch a 3-file rewrite — the BIGTASK_SLICE_RETRIES budget
#              cap is that backstop); it catches the obviously-too-wide items before they burn a run.
# Prints a report; exit 0 = clean, 1 = violation(s) found (a caller can trigger a bounded re-slice).
PLAN_MAX_FILES="${PLAN_MAX_FILES:-5}"
swarm_plan_lint() {
  local rm="${1:-ROADMAP.md}"; [ -f "$rm" ] || { echo "swarm: no $rm" >&2; return 2; }
  local -a items=() paths=()
  local line it p n i j over=0 coll=0 nf
  while IFS= read -r line; do
    it="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*- \[ \] //')"
    [ -z "$it" ] && continue
    case "$it" in *'add your first'*) continue ;; esac
    p="$(swarm_paths_for_item "$it" 2>/dev/null)"
    items+=("$it"); paths+=("$p")
  done < <(grep -E '^[[:space:]]*- \[ \] ' "$rm" 2>/dev/null)
  n=${#items[@]}
  for ((i=0; i<n; i++)); do
    # count distinct concrete files named in the item's Files: hint (not the expanded blast radius)
    nf="$(printf '%s' "${items[$i]}" | grep -oiE 'files?:.*' | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | sort -u | grep -c .)"
    if [ "${nf:-0}" -gt "$PLAN_MAX_FILES" ]; then
      over=$((over+1)); printf 'OVERSIZE  %s files · %s\n' "$nf" "$(_clip "${items[$i]}" 58)"
    fi
  done
  for ((i=0; i<n; i++)); do for ((j=i+1; j<n; j++)); do
    if _overlap "${paths[$i]}" "${paths[$j]}"; then
      coll=$((coll+1)); printf 'COLLIDE   %s  ⨯  %s\n' "$(_clip "${items[$i]}" 32)" "$(_clip "${items[$j]}" 32)"
    fi
  done; done
  # HOT-FILE CLUSTERS: a concrete file named by ≥HOTFILE_MIN OPEN items is a serialization bottleneck the
  # pairwise COLLIDE view understates. Report it (deterministically, from the Files: hints) so the re-slice
  # CHAINS that whole cluster onto ONE ordered track (deps a→b→c) — one owner, no cross-worker contention.
  local hot=0 f; declare -A _fc=()
  for ((i=0; i<n; i++)); do
    for f in $(printf '%s' "${items[$i]}" | grep -oiE 'files?:.*' | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | grep -E '/' | sort -u); do
      _fc["$f"]=$(( ${_fc["$f"]:-0} + 1 ))
    done
  done
  for f in "${!_fc[@]}"; do
    [ "${_fc[$f]}" -ge "${HOTFILE_MIN:-3}" ] && { hot=$((hot+1)); printf 'HOTFILE   %s · %s items\n' "$f" "${_fc[$f]}"; }
  done
  printf 'plan-lint: %d open item(s) · %d oversize · %d colliding pair(s) · %d hot-file cluster(s)\n' "$n" "$over" "$coll" "$hot"
  [ "$over" -eq 0 ] && [ "$coll" -eq 0 ] && [ "$hot" -eq 0 ]
}

# swarm_plan_lint_selftest — hermetic: builds a throwaway ROADMAP and asserts the lint flags a
# colliding pair + an oversized item, and passes a clean disjoint set. No network, no real repo files.
swarm_plan_lint_selftest() {
  local d ok=1 out
  d="$(mktemp -d)" || return 1
  ( cd "$d" && git init -q 2>/dev/null
    cat > ROADMAP.md <<'RM'
# Roadmap
## Next
- [ ] [value] feature A. Files: packages/alpha/a.ts, packages/alpha/a.test.ts
- [ ] [value] feature B. Files: packages/beta/b.ts, packages/beta/b.test.ts
- [ ] [value] hot X. Files: packages/shared/hot.ts, apps/x/x.ts
- [ ] [value] hot Y. Files: packages/shared/hot.ts, apps/y/y.ts
- [ ] [value] hot Z. Files: packages/shared/hot.ts, apps/z/z.ts
- [ ] [infra] wide item. Files: a/1.ts, a/2.ts, a/3.ts, a/4.ts, a/5.ts, a/6.ts, a/7.ts
RM
    out="$(REPO="$d" swarm_plan_lint ROADMAP.md 2>/dev/null)"; local rc=$?
    printf '%s\n' "$out" | grep -q 'COLLIDE' || { echo "[plan-lint] expected a COLLIDE (shared/hot.ts) — none"; ok=0; }
    printf '%s\n' "$out" | grep -q 'OVERSIZE' || { echo "[plan-lint] expected an OVERSIZE (7-file item) — none"; ok=0; }
    printf '%s\n' "$out" | grep -q 'HOTFILE.*shared/hot.ts' || { echo "[plan-lint] expected a HOTFILE (shared/hot.ts in 3 items) — none"; ok=0; }
    [ "$rc" -eq 1 ] || { echo "[plan-lint] expected exit 1 on violations, got $rc"; ok=0; }
    cat > clean.md <<'RM'
# Roadmap
## Next
- [ ] feature A. Files: packages/alpha/a.ts
- [ ] feature B. Files: packages/beta/b.ts
RM
    REPO="$d" swarm_plan_lint clean.md >/dev/null 2>&1 || { echo "[plan-lint] clean disjoint set should pass (exit 0)"; ok=0; }
    [ "$ok" = 1 ] && echo "[plan-lint] PASS ✓" || { echo "[plan-lint] FAIL ✗"; exit 1; }
  ) || ok=0
  rm -rf "$d"
  [ "$ok" = 1 ]
}

# swarm_spec_lint <spec.md>... — Part H/H5: deterministic, zero-token completeness gate on a feature spec
# (the artifact one level up from plan-lint's ROADMAP geometry). Proves STRUCTURE · GRAMMAR · GROUNDING against
# the fixed template markers (H1) — NOT whether the approach is good (that's the critics/rubric). Emits
# `SPECGAP <slug> <CHECK> <detail>` per violation + a summary; exit 0 clean / 1 gaps / 2 usage (plan-lint's
# contract). bash+coreutils only. Reads REPO for CITE_REAL existence checks (defaults to cwd).
swarm_spec_lint() {
  [ "$#" -ge 1 ] || { echo "usage: swarm_spec_lint <spec-file>..." >&2; return 2; }
  local f n=0 gaps=0 slug tier h _t line p
  _sec(){ awk -v H="## $1." 'index($0,H)==1{f=1;next} /^## /{f=0} f' "$2"; }   # body of section N
  _gap(){ printf 'SPECGAP %s %s %s\n' "$slug" "$1" "$2"; gaps=$((gaps+1)); }
  for f in "$@"; do
    slug="$(basename "$f" .md)"
    [ -f "$f" ] || { printf 'SPECGAP %s FILE spec file not found\n' "$slug"; gaps=$((gaps+1)); continue; }
    n=$((n+1))
    head -1 "$f" | grep -q 'ace-spec-template v1' || _gap VERSION "line 1 missing 'ace-spec-template v1' tag"
    # scan the whole TITLE BLOCK, not just 2 lines: real specs are `<!-- ace-spec-template v1 -->`, a BLANK
    # line, then the `# Spec: … (slug: … · risk: … · tier: …)` heading on line 3 — `head -2` could never see the
    # tier, so EVERY generated spec failed TIER (153/153 in one repo) and "first-pass clean" was unreachable.
    tier="$(head -6 "$f" | grep -oiE 'tier:[[:space:]]*(FULL|FAST)' | grep -oiE 'FULL|FAST' | head -1 | tr '[:lower:]' '[:upper:]')"
    [ -n "$tier" ] || { _gap TIER "spec heading must declare 'tier: FULL' or 'FAST'"; tier=FULL; }
    for h in 1 2 3 4 5 6 7; do grep -qE "^## $h\." "$f" || _gap SECTIONS "missing heading '## $h.'"; done
    if [ "$tier" = FULL ]; then
      _t="$(awk '/^### Out/{f=1;next} /^### |^## /{f=0} f && /^[[:space:]]*-[[:space:]]+[^[:space:]<]/{c++} END{print c+0}' "$f")"
      [ "${_t:-0}" -ge 1 ] || _gap SCOPE_OUT "§3 '### Out' has no bullet (the anti-drift wall is empty)"
    fi
    # §4 EARS: well-formed AC lines, unique ids, no free-form bullet
    _t="$(_sec 4 "$f" | grep -E '^[[:space:]]*- ' | grep -vE '^[[:space:]]*- <!--')"
    [ -n "$(printf '%s' "$_t" | grep -oE 'AC-E?[0-9]+' | head -1)" ] || _gap EARS "§4 has no AC- lines"
    printf '%s\n' "$_t" | grep -qE '^[[:space:]]*- ' && printf '%s\n' "$_t" | grep -E '^[[:space:]]*- ' \
      | grep -qvE 'AC-E?[0-9]+ (WHEN .+ THE SYSTEM SHALL .+|GIVEN .+ WHEN .+ THEN .+)' \
      && _gap EARS "§4 bullet not in 'AC-<n> WHEN … THE SYSTEM SHALL …' / GWT form"
    [ -n "$(printf '%s' "$_t" | grep -oE 'AC-E?[0-9]+' | sort | uniq -d | head -1)" ] && _gap EARS "§4 duplicate AC id"
    local ids4 ids6; ids4="$(printf '%s' "$_t" | grep -oE 'AC-E?[0-9]+' | sort -u)"
    # §6 increments: carry ACs, cover §4 exactly, name ≤PLAN_MAX_FILES files
    _t="$(_sec 6 "$f")"
    printf '%s\n' "$_t" | grep -qE '^[0-9]+\.' && printf '%s\n' "$_t" | grep -E '^[0-9]+\.' | grep -qvE 'ACs?:' \
      && _gap AC_COVER "§6 increment missing 'ACs:'"
    ids6="$(printf '%s' "$_t" | grep -oE 'AC-E?[0-9]+' | sort -u)"
    [ "$ids4" = "$ids6" ] || _gap AC_COVER "§6 AC ids ≠ §4 AC ids (coverage mismatch)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      local nf; nf="$(printf '%s' "$line" | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' | sort -u | grep -c .)"
      [ "${nf:-0}" -ge 1 ] || _gap INC_SIZE "§6 increment names no file: $(printf '%s' "$line" | cut -c1-36)"
      [ "${nf:-0}" -gt "${PLAN_MAX_FILES:-5}" ] && _gap INC_SIZE "§6 increment names $nf files (> ${PLAN_MAX_FILES:-5})"
    done < <(printf '%s\n' "$_t" | grep -E '^[0-9]+\.')
    # §5 CITED: any bullet naming a concrete file must carry a cite or UNVERIFIED
    while IFS= read -r line; do
      printf '%s' "$line" | grep -qE '[A-Za-z0-9_./-]+\.[A-Za-z]{1,6}([[:space:]:]|$)' || continue
      printf '%s' "$line" | grep -qE '\(cites [A-Za-z0-9_./-]+:L[0-9]+(-L[0-9]+)?\)|UNVERIFIED —' \
        || _gap CITED "§5 file claim without '(cites path:L..)' or 'UNVERIFIED —': $(printf '%s' "$line" | cut -c1-36)"
    done < <(_sec 5 "$f" | grep -E '^[[:space:]]*- ' | grep -vE '^[[:space:]]*- <!--')
    # §5 CITE_REAL: cited paths must exist in the worktree (invented-path guard; line-drift not checked)
    while IFS= read -r p; do
      [ -n "$p" ] && [ ! -e "${REPO:-.}/$p" ] && _gap CITE_REAL "§5 cites a path not in the worktree: $p"
    done < <(_sec 5 "$f" | grep -oE 'cites [A-Za-z0-9_./-]+:' | sed 's/^cites //; s/:$//' | sort -u)
    # C1-C6 present + content or a reasoned N/A
    for h in C1 C2 C3 C4 C5 C6; do
      grep -qE "^## $h\." "$f" || { _gap CBLOCKS "missing conditional block '## $h.'"; continue; }
      local cb; cb="$(_sec "$h" "$f" | grep -vE '^[[:space:]]*(<!--.*)?$')"
      [ -n "$cb" ] || { _gap CBLOCKS "§$h is empty (fill it or 'N/A — <reason>')"; continue; }
      printf '%s\n' "$cb" | grep -qE '^[[:space:]]*N/A[[:space:]]*—[[:space:]]*$' && _gap CBLOCKS "§$h 'N/A —' has no reason"
    done
    awk '/^## 1\./{f=1} /^## 7\./{f=0} f' "$f" | grep -qE '(^|[^A-Za-z])(TBD|TODO|FIXME|XXX)([^A-Za-z]|$)' \
      && _gap NO_TBD "TBD/TODO/FIXME/XXX inside §1-§6 (allowed only in §7)"
    _sec 2 "$f" | grep -qE '\(source:' || _gap SOURCED "§2 prior-art missing a '(source: …, …)' citation"
  done
  printf 'spec-lint: %d spec(s) · %d gap(s)\n' "$n" "$gaps"
  [ "$gaps" -eq 0 ]
}

# swarm_spec_lint_selftest — hermetic: a conforming FULL fixture must pass clean; a violating fixture must trip
# ≥1 gap per seeded class. No network, no repo files (the cited path is created in the temp worktree).
swarm_spec_lint_selftest() {
  local d ok=1 out; d="$(mktemp -d)" || return 1
  ( cd "$d" && mkdir -p .opencode/specs lib
    : > lib/widget.ts   # so CITE_REAL's existence check passes for the conforming fixture
    cat > .opencode/specs/good.md <<'SP'
<!-- ace-spec-template v1 -->

# Spec: Demo   (slug: good · risk: LOW · tier: FULL)

## 1. Problem
Users need a save button. Why now: launch.

## 2. Prior art & approach
- Product A autosaves (source: https://a.example/docs, 2026-07). DECISION: match — standard scope.

## 3. Scope
### In
- Add a save action to the widget.
### Out
- Do NOT add offline sync.

## 4. Acceptance criteria
- AC-1 WHEN the user clicks save THE SYSTEM SHALL persist within 200ms.
- AC-E1 WHEN the input is empty THE SYSTEM SHALL reject with a 400.

## 5. Integration (cited)
- Files to touch: lib/widget.ts — the save path (cites lib/widget.ts:L1-L5)
- Blast radius: two panel callers.

## 6. Increments
1. persist path — files: lib/widget.ts — ACs: AC-1 — deps: —
2. empty guard — files: lib/widget.ts — ACs: AC-E1 — deps: 1

## 7. Open questions / assumptions
- None.

## C1. Contract
N/A — no endpoint.
## C2. Data model
N/A — no schema change.
## C3. UX flow
Spinner then a success toast.
## C4. NFRs
Save p95 < 200ms.
## C5. Security
N/A — no auth surface.
## C6. Risk & rollback
Feature-flagged; revert the commit.
SP
    cat > .opencode/specs/bad.md <<'SP'
# Spec: Broken   (slug: bad)

## 1. Problem
TODO figure this out.

## 2. Prior art & approach
- Some product does it somehow.

## 3. Scope
### In
- thing
### Out

## 4. Acceptance criteria
- it should basically work fast

## 5. Integration (cited)
- Files to touch: lib/ghost.ts — the guts (cites lib/ghost.ts:L1-L9)
- Pattern: src/nope.js — mimic it

## 6. Increments
1. do everything — files: a.ts

## C1. Contract
## C5. Security
N/A —
SP
    REPO="$d" swarm_spec_lint .opencode/specs/good.md >/tmp/.sl_good 2>/dev/null; local rgood=$?
    REPO="$d" swarm_spec_lint .opencode/specs/bad.md  >/tmp/.sl_bad  2>/dev/null; local rbad=$?
    [ "$rgood" = 0 ] || { echo "[spec-lint] conforming fixture should pass (exit 0) — got $rgood:"; grep SPECGAP /tmp/.sl_good | sed 's/^/    /'; ok=0; }
    [ "$rbad" = 1 ]  || { echo "[spec-lint] violating fixture should fail (exit 1) — got $rbad"; ok=0; }
    for c in VERSION TIER SECTIONS SCOPE_OUT EARS AC_COVER CITED CITE_REAL CBLOCKS NO_TBD SOURCED; do
      grep -q " $c " /tmp/.sl_bad || { echo "[spec-lint] violating fixture missed a $c gap"; ok=0; }
    done
    rm -f /tmp/.sl_good /tmp/.sl_bad
    [ "$ok" = 1 ] && echo "[spec-lint] PASS ✓" || { echo "[spec-lint] FAIL ✗"; exit 1; }
  ) || ok=0
  rm -rf "$d"; [ "$ok" = 1 ]
}

# swarm_spec_slice <spec.md> <ac-csv> — Part H/H6 Edit 2: assemble the self-contained increment context a
# worker needs, so the RIGHT slice of the spec is in the prompt even when a worker economizes reads. Emits §3
# Scope (full — In AND Out is the anti-drift wall), §4 filtered to ONLY this increment's AC ids, and §C1/§C5
# iff they're not N/A, then the Definition-of-Done line. Capped at 120 lines (a bloated slice is a spec smell).
swarm_spec_slice() {
  local spec="$1" acs="${2:-}"
  [ -f "$spec" ] || { echo "swarm: no spec $spec" >&2; return 2; }
  _sec(){ awk -v H="## $1." 'index($0,H)==1{f=1;next} /^## /{f=0} f' "$spec"; }
  local acre; acre="$(printf '%s' "$acs" | tr ',' '\n' | sed 's/[[:blank:]]//g' | grep -E '^AC-E?[0-9]+$' | sed 's/$/ /' | paste -sd '|' -)"
  {
    printf '── SPEC SLICE · %s · ACs: %s ──\n' "$(basename "$spec")" "${acs:-<none>}"
    printf '\n## 3. Scope\n'; _sec 3 "$spec"
    printf '\n## 4. Acceptance criteria (THIS increment only)\n'
    if [ -n "$acre" ]; then _sec 4 "$spec" | grep -E "^[[:space:]]*- ($acre)" || true; else _sec 4 "$spec"; fi
    local c body
    for c in C1 C5; do
      body="$(_sec "$c" "$spec" | grep -vE '^[[:space:]]*(<!--.*)?$')"
      [ -n "$body" ] && ! printf '%s\n' "$body" | grep -qiE '^[[:space:]]*N/A' && { printf '\n## %s.\n%s\n' "$c" "$body"; }
    done
    printf '\nDefinition-of-Done = ACs %s. §3-Out bounds you (touching an Out item is scope-creep). Full spec: %s\n──\n' "${acs:-<none>}" "$spec"
  } | head -120
}

# swarm_spec_slice_selftest — a slice from a 2-AC spec must contain §3, ONLY the requested AC line, and be capped.
swarm_spec_slice_selftest() {
  local d ok=1 out; d="$(mktemp -d)" || return 1
  ( cd "$d"
    cat > s.md <<'SP'
<!-- ace-spec-template v1 -->
# Spec: Demo   (slug: s · risk: LOW · tier: FULL)
## 3. Scope
### In
- add save
### Out
- no offline sync
## 4. Acceptance criteria
- AC-1 WHEN save clicked THE SYSTEM SHALL persist in 200ms.
- AC-2 WHEN reload THE SYSTEM SHALL restore state.
- AC-E1 WHEN empty THE SYSTEM SHALL reject 400.
## 5. Integration (cited)
- x (cites a.ts:L1)
## 6. Increments
1. p — files: a.ts — ACs: AC-1
## C1. Contract
POST /save {id}
## C5. Security
N/A — none
SP
    out="$(swarm_spec_slice s.md 'AC-1,AC-E1')"
    printf '%s\n' "$out" | grep -q '## 3. Scope' || { echo "[spec-slice] missing §3 Scope"; ok=0; }
    printf '%s\n' "$out" | grep -q 'no offline sync' || { echo "[spec-slice] missing §3 Out"; ok=0; }
    printf '%s\n' "$out" | grep -q 'AC-1 WHEN save' || { echo "[spec-slice] missing requested AC-1"; ok=0; }
    printf '%s\n' "$out" | grep -q 'AC-E1 WHEN empty' || { echo "[spec-slice] missing requested AC-E1"; ok=0; }
    printf '%s\n' "$out" | grep -q 'AC-2 WHEN reload' && { echo "[spec-slice] leaked non-requested AC-2"; ok=0; }
    printf '%s\n' "$out" | grep -q 'POST /save' || { echo "[spec-slice] missing §C1 (not N/A)"; ok=0; }
    printf '%s\n' "$out" | grep -q '## C5' && { echo "[spec-slice] included §C5 which is N/A"; ok=0; }
    [ "$(printf '%s\n' "$out" | wc -l)" -le 120 ] || { echo "[spec-slice] not capped at 120 lines"; ok=0; }
    # AC-H7.1: the slice is DETERMINISTIC — a frozen spec ⇒ byte-identical bytes across dispatches, so the
    # worker-prompt prefix is cache-stable across a feature's increments/retries. Re-assemble and cmp.
    [ "$out" = "$(swarm_spec_slice s.md 'AC-1,AC-E1')" ] || { echo "[spec-slice] non-deterministic output (breaks prompt-cache prefix)"; ok=0; }
    [ "$ok" = 1 ] && echo "[spec-slice] PASS ✓" || { echo "[spec-slice] FAIL ✗"; exit 1; }
  ) || ok=0
  rm -rf "$d"; [ "$ok" = 1 ]
}

# swarm_spec_rubric <spec> — H5 Edit 5: OPTIONAL LLM spec rubric, DEFAULT OFF (SPEC_RUBRIC=1 to enable).
# Runs ONLY on a HIGH-risk spec (the caller only invokes it on lint-GREEN specs). ONE bounded, FAIL-OPEN model
# call — mirrors rathole_verdict's transport (hard-timed curl; any missing key / error / garble ⇒ ZERO output,
# spec passes). GAPS emit 'SPECGAP <basename-slug> RUBRIC:<criterion> <evidence>' into the SAME channel the
# deterministic lint uses, so the existing re-spec drive handles them — the rubric adds judgment, never a new
# code path. With SPEC_RUBRIC=0 (default) it makes ZERO calls (AC-H5.8). Model = SPEC_RUBRIC_MODEL (a seam;
# default deepseek-v4-pro, reached via the same DeepSeek endpoint the rathole judge uses).
# swarm_spec_rubric_json <spec> — the raw rubric PRIMITIVE: the ONE bounded, fail-open model call, returning the
# validated JSON verdict (or nothing). Guards on risk:HIGH + key + curl/jq, but NOT on SPEC_RUBRIC (that's the
# caller's enablement gate). Used by swarm_spec_rubric (→ SPECGAP) AND by the nightly rubric goldens (which record
# + calibrate the JSON). A missing key / error / non-JSON ⇒ empty output.
swarm_spec_rubric_json() {
  local spec="$1" body resp content
  [ -f "$spec" ] || return 0
  grep -qiE 'risk:[[:space:]]*HIGH' "$spec" || return 0     # HIGH-risk only — not worth a call otherwise
  { [ -n "${DEEPSEEK_API_KEY:-}" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; } || return 0
  body="$(jq -nc --arg m "${SPEC_RUBRIC_MODEL:-deepseek-v4-pro}" --arg c "Judge this feature spec on 7 criteria. Score 1-3 each (1 fail · 2 adequate · 3 strong) + one-line evidence: testable_acs · scope_tightness · contract_clarity · edge_coverage · grounded_integration · prior_art_justified · increments_shippable. Verdict: PASS if no criterion is 1, else GAPS + the criterion names. Output ONLY this JSON: {\"scores\":{},\"evidence\":{},\"verdict\":\"PASS|GAPS\",\"gaps\":[]}

SPEC:
$(cat "$spec" 2>/dev/null)" '{model:$m,stream:false,temperature:0,max_tokens:600,messages:[{role:"user",content:$c}]}' 2>/dev/null)" || return 0
  resp="$(curl -sS --max-time "${SPEC_RUBRIC_TIMEOUT:-90}" https://api.deepseek.com/chat/completions \
            -H "Authorization: Bearer $DEEPSEEK_API_KEY" -H 'Content-Type: application/json' -d "$body" 2>/dev/null)" || return 0
  content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null | grep -oE '\{.*\}' | head -1)"
  [ -n "$content" ] || return 0
  printf '%s' "$content" | jq -e . >/dev/null 2>&1 || return 0   # must be valid JSON
  printf '%s' "$content"
}

swarm_spec_rubric() {
  [ "${SPEC_RUBRIC:-0}" = 1 ] || return 0
  local spec="$1" slug content verdict
  content="$(swarm_spec_rubric_json "$spec")" || return 0
  [ -n "$content" ] || return 0
  verdict="$(printf '%s' "$content" | jq -r '.verdict // empty' 2>/dev/null)"
  [ "$verdict" = GAPS ] || return 0     # PASS / malformed ⇒ fail-open (no gaps)
  slug="$(basename "$spec" .md)"
  printf '%s' "$content" | jq -r --arg s "$slug" \
    '. as $r | (.gaps // [])[] | "SPECGAP \($s) RUBRIC:\(.) " + (($r.evidence[.] // "score 1") | tostring | gsub("\n";" "))' \
    2>/dev/null || true
}

# swarm_spec_rubric_selftest — AC-H5.8: default OFF ⇒ ZERO calls / ZERO output; and even enabled without a key
# it must fail-open silently (no network, no output). Deterministic, no-network.
swarm_spec_rubric_selftest() {
  local d ok=1 out; d="$(mktemp -d)" || return 1
  ( cd "$d"
    printf '<!-- ace-spec-template v1 -->\n# Spec (slug: r · risk: HIGH · tier: FULL)\n## 3. Scope\n' > r.md
    out="$(SPEC_RUBRIC=0 swarm_spec_rubric r.md)"
    [ -z "$out" ] || { echo "[spec-rubric] SPEC_RUBRIC=0 must produce NO output (got: $out)"; ok=0; }
    out="$(SPEC_RUBRIC=1 DEEPSEEK_API_KEY='' swarm_spec_rubric r.md)"
    [ -z "$out" ] || { echo "[spec-rubric] no key must fail-open with NO output (got: $out)"; ok=0; }
    printf '# not-high (slug: n · risk: LOW)\n' > n.md
    out="$(SPEC_RUBRIC=1 DEEPSEEK_API_KEY=x swarm_spec_rubric n.md)"
    [ -z "$out" ] || { echo "[spec-rubric] LOW-risk spec must be skipped (got: $out)"; ok=0; }
    [ "$ok" = 1 ] && echo "[spec-rubric] PASS ✓" || { echo "[spec-rubric] FAIL ✗"; exit 1; }
  ) || ok=0
  rm -rf "$d"; [ "$ok" = 1 ]
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
  # I1/I2 (#62): only the CURRENT owner may set an outcome. After a reap→re-assign, the item's worker is the
  # NEW claimant; a straggler releasing "its" hash would clobber the new owner's active claim. Worker="" is a
  # wildcard for coordinator-side calls that legitimately don't scope to a worker.
  _rel_txn() { local tmp; tmp="$(mktemp)"
    jq --arg h "$hash" --arg s "$status" --arg w "$worker" \
       'if (.claims[$h] and ($w=="" or (.claims[$h].worker // "")==$w)) then .claims[$h].status=$s else . end' "$STATE" > "$tmp" && _putstate "$tmp"; }
  _with_lock _rel_txn
}

# swarm_owns WORKER HASH — exit 0 iff HASH's claim is still ACTIVE and owned by WORKER; 1 if it was
# re-assigned or is no longer active (a straggler must NOT land); 2 if it can't be determined (no store →
# the caller fails OPEN and proceeds). The authoritative, store-read form of the abandon-flag fence (#62):
# a worker calls it at the LAST moment before landing, in case a reap→reassign happened and the abandon
# TERM hasn't reached it yet (it may be mid-merge, or racing its own watcher). Read-only — no swarm_init, so
# it never creates a store just to answer "who owns this".
swarm_owns() {
  local worker="$1" hash="$2" w st
  : "${STATE:=${SWARM_DIR:+$SWARM_DIR/state.json}}"
  [ -n "$STATE" ] && [ -f "$STATE" ] || return 2
  w="$(jq -r --arg h "$hash" '.claims[$h].worker // ""' "$STATE" 2>/dev/null)"
  st="$(jq -r --arg h "$hash" '.claims[$h].status // "none"' "$STATE" 2>/dev/null)"
  [ "$w" = "$worker" ] && [ "$st" = active ]
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
    local now h w it tries tmp; now="$(_now)"
    while IFS=$'\t' read -r h w it; do
      [ -z "$h" ] && continue
      # I2 (#62): the item is being re-assigned/parked, so its prior owner MUST stop — a hung/zombie worker
      # that keeps running would produce a concurrent duplicate. Signal it to abandon its in-flight step (the
      # worker's watcher TERMs the autoloop, whose cleanup trap commits WIP first). Harmless if that worker is
      # already gone. Flag is cleared by the worker on next claim, or by swarm_run's start-reset.
      [ -n "$w" ] && [ -n "${SWARM_DIR:-}" ] && : > "$SWARM_DIR/control.abandon-$w-$h" 2>/dev/null
      tries="$(jq -r --arg h "$h" '.claims[$h].tries // 1' "$STATE")"
      tmp="$(mktemp)"
      if [ "$tries" -ge "$MAX_TRIES" ]; then
        jq --arg h "$h" '.claims[$h].status="parked"' "$STATE" > "$tmp" && _putstate "$tmp"; echo "PARK	$h	$it"
      else
        jq --arg h "$h" '.claims[$h].status="orphaned"' "$STATE" > "$tmp" && _putstate "$tmp"; echo "REAP	$h	$it"
      fi
    done < <(jq -r --argjson now "$now" --argjson ttl "$ttl" \
      '.claims|to_entries[]|select(.value.status=="active" and ($now - (.value.hb // .value.ts)) > $ttl)|"\(.key)\t\(.value.worker)\t\(.value.item)"' "$STATE" 2>/dev/null)
  }
  _with_lock _reap_txn
}

# swarm_reconcile — on coordinator (re)start, any lease still "active" is a
# leftover from a crashed prior run → orphan it (requeue, keep tries). Prints the
# reclaimed hashes so the coordinator prunes their worktrees/branches.
swarm_reconcile() {
  _rec_txn() {
    local h w it tmp
    while IFS=$'\t' read -r h w it; do
      [ -z "$h" ] && continue
      # #62: a leftover "active" claim from a crashed/killed prior process — signal its (possibly-surviving)
      # worker to abandon before we re-assign the item, so a straggler can't double-work it.
      [ -n "$w" ] && [ -n "${SWARM_DIR:-}" ] && : > "$SWARM_DIR/control.abandon-$w-$h" 2>/dev/null
      tmp="$(mktemp)"; jq --arg h "$h" '.claims[$h].status="orphaned"' "$STATE" > "$tmp" && _putstate "$tmp"
      echo "RECLAIM	$h	$it"
    done < <(jq -r '.claims|to_entries[]|select(.value.status=="active")|"\(.key)\t\(.value.worker)\t\(.value.item)"' "$STATE" 2>/dev/null)
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
  local lvl=info; case "$type" in done|acquired) lvl=ok;; conflict|error|gate-red|red-main) lvl=err;; waiting|blocked|defer|needs-attention|reap|stopped|incomplete|standby|abandoned) lvl=warn;; claimed|merging|fixer|main-adv) lvl=accent;; esac
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
  # Must RETURN non-zero on failure like every sibling selftest: `ace swarm selftest` aggregates
  # exit codes, so merely PRINTING "FAIL ✗" here let a broken wait/notify path pass the whole gate.
  [ "$r" = ok ] && [ "$got" -ge 1 ] && echo "[waittest] PASS ✓" || { echo "[waittest] FAIL ✗"; return 1; }
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
  # item 3: current main health (RED-main circuit breaker)
  local _lg _rs _fx; _lg="$(swarm_green_get 2>/dev/null)"
  if _rs="$(swarm_main_red get 2>/dev/null)"; then _fx="$(cat "$SWARM_DIR/fixer" 2>/dev/null || echo '—')"
    printf '   %smain%s   %sRED%s (fixer=%s, bad=%.12s)\n' "${_MUT:-}" "${_R:-}" "${_RED:-}${_B:-}" "${_R:-}" "$_fx" "$_rs"
  elif [ -n "$_lg" ]; then
    printf '   %smain%s   %sGREEN%s (last-green %.12s)\n' "${_MUT:-}" "${_R:-}" "${_GRN:-}" "${_R:-}" "$_lg"
  fi
  local rm="${REPO:-$PWD}/ROADMAP.md"
  if [ -f "$rm" ]; then
    local plan par ser blk; plan="$(swarm_disjoint_plan "$rm" "${SWARM_CEIL:-5}" 2>/dev/null)"
    par="$(printf '%s\n' "$plan" | grep -c '^parallel')"; ser="$(printf '%s\n' "$plan" | grep -c '^serialize')"; blk="$(printf '%s\n' "$plan" | grep -c '^blocked')"
    printf '   %splan%s   %s%s parallel%s · %s serialized (share a file) · %s dep-blocked  (cap %s)\n' \
      "${_MUT:-}" "${_R:-}" "${_GRN:-}" "$par" "${_R:-}" "$ser" "$blk" "${SWARM_CEIL:-5}"
  fi
}

# ── item 3: RED-main circuit breaker ────────────────────────────────────────────────────────────────
# When a bad commit lands on main, EVERY in-flight worker's tentative merge is RED (the merge includes the
# break), so each would WRONGLY route to the conflict_resolver and churn credits on a phantom conflict. This
# breaks that: the FIRST worker to prove main is RED-on-its-own becomes the sole FIXER (repairs main); the
# rest STAND DOWN until main is GREEN again, then rebase onto the recovered main via the normal merge queue.
# State = tiny files in SWARM_DIR, created atomically via O_EXCL (noclobber) so no lock is needed for the
# create-once election. last-green: newest origin/main sha proven GREEN by a land (the safe rebase base) ·
# main-red: present ⟺ main believed RED, holds the offending sha · fixer: the wid that won the election.
swarm_green_set(){ swarm_init; [ -n "${1:-}" ] && printf '%s\n' "$1" > "$SWARM_DIR/last-green" 2>/dev/null || true; }
swarm_green_get(){ swarm_init; cat "$SWARM_DIR/last-green" 2>/dev/null || true; }
swarm_main_red(){
  swarm_init; local sub="${1:-get}" arg="${2:-}"
  case "$sub" in
    set)   ( set -o noclobber; printf '%s\n' "${arg:-unknown}" > "$SWARM_DIR/main-red" ) 2>/dev/null || true ;;  # FIRST sha sticks
    get)   [ -s "$SWARM_DIR/main-red" ] && { cat "$SWARM_DIR/main-red"; return 0; }; return 1 ;;
    clear) rm -f "$SWARM_DIR/main-red" "$SWARM_DIR/fixer" 2>/dev/null; return 0 ;;
    elect) [ -n "$arg" ] || { echo standby; return 0; }
           if ( set -o noclobber; printf '%s\n' "$arg" > "$SWARM_DIR/fixer" ) 2>/dev/null; then echo fixer   # won the O_EXCL create
           elif [ "$(cat "$SWARM_DIR/fixer" 2>/dev/null)" = "$arg" ]; then echo fixer                        # already the fixer (idempotent)
           else echo standby; fi ;;
    *)     return 2 ;;
  esac
}

# selftest for the RED-main breaker: last-green round-trip, first-sha-sticks, singleton election
# (incl. a real concurrent race), idempotency, and clear→re-elect.
swarm_redmain_selftest(){
  export SWARM_DIR; SWARM_DIR="$(mktemp -d)/s"; swarm_init
  local ok=1 r nf w
  swarm_green_set deadbeef; [ "$(swarm_green_get)" = deadbeef ] || { echo "[redmain] last-green FAIL"; ok=0; }
  swarm_main_red get >/dev/null 2>&1 && { echo "[redmain] expected-clear FAIL"; ok=0; }
  swarm_main_red set badsha1; swarm_main_red set badsha2
  [ "$(swarm_main_red get)" = badsha1 ] || { echo "[redmain] first-sha-sticks FAIL ($(swarm_main_red get))"; ok=0; }
  [ "$(swarm_main_red elect w1)" = fixer ]   || { echo "[redmain] first-elect FAIL"; ok=0; }
  [ "$(swarm_main_red elect w1)" = fixer ]   || { echo "[redmain] fixer-idempotent FAIL"; ok=0; }
  [ "$(swarm_main_red elect w2)" = standby ] || { echo "[redmain] non-fixer-standby FAIL"; ok=0; }
  swarm_main_red clear
  swarm_main_red get >/dev/null 2>&1 && { echo "[redmain] clear FAIL"; ok=0; }
  [ "$(swarm_main_red elect w2)" = fixer ]   || { echo "[redmain] re-elect-after-clear FAIL"; ok=0; }
  # real concurrent race: fork 12 contenders, EXACTLY one may win
  swarm_main_red clear; local d="$SWARM_DIR/elect.out"; : > "$d"
  for w in $(seq 1 12); do ( echo "$(swarm_main_red elect "c$w")" >> "$d" ) & done; wait
  nf="$(grep -c '^fixer$' "$d" 2>/dev/null)"
  [ "$nf" = 1 ] || { echo "[redmain] concurrent-elect FAIL (winners=$nf, expect 1)"; ok=0; }
  echo "[redmain] singleton under 12-way race: winners=$nf (expect 1)"
  rm -rf "$(dirname "$SWARM_DIR")"
  [ "$ok" = 1 ] && echo "[redmain-selftest] PASS ✓" || { echo "[redmain-selftest] FAIL ✗"; return 1; }
}

# selftest for #62 at-most-one-owner: reap→abandon-signal + status, the swarm_release worker-guard (a stale
# straggler cannot clobber the new owner's claim), and that the legit owner can still release.
swarm_abandon_selftest(){
  export SWARM_DIR; SWARM_DIR="$(mktemp -d)/s"; swarm_init
  local ok=1 h tmp
  swarm_try_claim w1 "item-X" "src/x.ts" >/dev/null
  h="$(printf '%s' "item-X" | cksum | cut -d' ' -f1)"
  tmp="$(mktemp)"; jq --arg h "$h" '.claims[$h].hb = 1' "$STATE" > "$tmp" && mv "$tmp" "$STATE"   # backdate hb → stale
  swarm_reap 1 >/dev/null
  [ -f "$SWARM_DIR/control.abandon-w1-$h" ] || { echo "[abandon] reap did NOT signal w1"; ok=0; }
  [ "$(jq -r --arg h "$h" '.claims[$h].status' "$STATE")" = orphaned ] || { echo "[abandon] not orphaned"; ok=0; }
  swarm_try_claim w2 "item-X" "src/x.ts" >/dev/null   # w2 re-claims (orphaned → retryable); now owns X
  swarm_release w1 "$h" abandoned                       # stale w1 tries to release — MUST be a no-op
  { [ "$(jq -r --arg h "$h" '.claims[$h].worker' "$STATE")" = w2 ] && [ "$(jq -r --arg h "$h" '.claims[$h].status' "$STATE")" = active ]; } \
    || { echo "[abandon] release-guard FAIL — w1 clobbered w2's active claim"; ok=0; }
  swarm_release w2 "$h" done                             # the real owner CAN release
  [ "$(jq -r --arg h "$h" '.claims[$h].status' "$STATE")" = done ] || { echo "[abandon] owner release FAIL"; ok=0; }
  echo "[abandon] reap→signal=ok · release-guard=ok · owner-release=ok"
  rm -rf "$(dirname "$SWARM_DIR")"
  [ "$ok" = 1 ] && echo "[abandon-selftest] PASS ✓" || { echo "[abandon-selftest] FAIL ✗"; return 1; }
}

# selftest for the P1 merge-time fence (swarm_owns): the owner is recognised, a non-owner / reassigned
# straggler / released claim is not, and a missing store fails OPEN (exit 2, caller proceeds).
swarm_owns_selftest(){
  export SWARM_DIR; SWARM_DIR="$(mktemp -d)/s"; swarm_init
  local ok=1 h rc
  swarm_try_claim w1 "item-Y" "src/y.ts" >/dev/null
  h="$(printf '%s' "item-Y" | cksum | cut -d' ' -f1)"
  swarm_owns w1 "$h"; [ $? -eq 0 ] || { echo "[owns] owner w1 not recognised"; ok=0; }
  swarm_owns w2 "$h"; [ $? -eq 1 ] || { echo "[owns] non-owner w2 should be 1"; ok=0; }
  # backdate + reap + reassign to w2 → w1 is no longer the owner
  local tmp; tmp="$(mktemp)"; jq --arg h "$h" '.claims[$h].hb = 1' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  swarm_reap 1 >/dev/null; swarm_try_claim w2 "item-Y" "src/y.ts" >/dev/null
  swarm_owns w1 "$h"; [ $? -eq 1 ] || { echo "[owns] reassigned-away w1 should be 1 (would-be double-merge)"; ok=0; }
  swarm_owns w2 "$h"; [ $? -eq 0 ] || { echo "[owns] new owner w2 not recognised"; ok=0; }
  swarm_release w2 "$h" done
  swarm_owns w2 "$h"; [ $? -eq 1 ] || { echo "[owns] released (non-active) claim should be 1"; ok=0; }
  ( SWARM_DIR="/nonexistent/nope" STATE="" swarm_owns w1 "$h" ); rc=$?
  [ "$rc" -eq 2 ] || { echo "[owns] missing store should fail OPEN (2), got $rc"; ok=0; }
  rm -rf "$(dirname "$SWARM_DIR")"
  [ "$ok" = 1 ] && echo "[owns-selftest] PASS ✓" || { echo "[owns-selftest] FAIL ✗"; return 1; }
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
    owns)     swarm_owns "${2:?worker}" "${3:?hash}" ;;
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
    redmain-selftest) swarm_redmain_selftest ;;
    abandon-selftest) swarm_abandon_selftest ;;
    owns-selftest)  swarm_owns_selftest ;;
    mergiraf-selftest) swarm_mergiraf_selftest ;;
    aggregate-lessons) swarm_aggregate_lessons "${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" ;;
    disjoint-batch) swarm_disjoint_batch "${2:-ROADMAP.md}" "${3:-${SWARM_CEIL:-5}}" ;;
    disjoint-plan)  swarm_disjoint_plan "${2:-ROADMAP.md}" "${3:-${SWARM_CEIL:-5}}" ;;
    plan-lint)      swarm_plan_lint "${2:-ROADMAP.md}" ;;
    plan-lint-selftest) swarm_plan_lint_selftest ;;
    spec-lint)      shift; swarm_spec_lint "$@" ;;
    spec-lint-selftest) swarm_spec_lint_selftest ;;
    spec-slice)     shift; swarm_spec_slice "$@" ;;
    spec-slice-selftest) swarm_spec_slice_selftest ;;
    spec-rubric)    shift; swarm_spec_rubric "$@" ;;
    spec-rubric-selftest) swarm_spec_rubric_selftest ;;
    debate-selftest) bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/debate.sh" selftest ;;
    scorecard-selftest) bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/scorecard-selftest.sh" ;;
    reanalyze-selftest) bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/reanalyze-selftest.sh" ;;
    hygiene-selftest) bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/hygiene-selftest.sh" ;;
    scope-stats)    swarm_scope_stats ;;
    stats)          swarm_stats ;;
    green-set)      swarm_green_set "${2:-}" ;;
    green-get)      swarm_green_get ;;
    main-red)       swarm_main_red "${2:-get}" "${3:-}" ;;
    *) echo "usage: swarm.sh {init|next|claim|release|owns|post|tail|status|paths|selftest|sched-selftest|policy|policy-selftest|mergiraf-selftest|aggregate-lessons|disjoint-batch|disjoint-plan|plan-lint|plan-lint-selftest|spec-lint|spec-lint-selftest|spec-slice|spec-slice-selftest|spec-rubric|spec-rubric-selftest|debate-selftest|scope-stats}" >&2; exit 2 ;;
  esac
fi
