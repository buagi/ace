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
_typc(){ case "$1" in done|acquired|ok) printf '%s' "$_GRN";; conflict|error|err) printf '%s' "$_RED";;
  waiting|blocked|defer|needs-attention|reap|warn) printf '%s' "$_GOLD";; claimed|merging|accent) printf '%s' "$_PUR";; *) printf '%s' "$_FG";; esac; }
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
    case "$SWARM_META_FREE" in *" $tok "*) continue ;; esac   # never lease coordinator/union/regenerated meta files
    for lf in $_SWARM_LEASEFREE; do case "$tok" in ${lf//\*\*/\*}) continue 2 ;; esac; done  # policy lease-free (glob)
    paths="$paths $tok"
  done
  paths="$(printf '%s' "$paths" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"
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
  done < <(grep -nE '^[[:space:]]*- \[ \] ' "$roadmap")
  return 0   # nothing claimable
}

# swarm_touch WORKER HASH ADDPATHS — extend an ACTIVE claim mid-flight when a
# flow discovers it must edit more files. Succeeds iff ADDPATHS don't overlap
# ANOTHER worker's active lease (a flow's own lease can always grow). ok/busy.
swarm_touch() {
  local worker="$1" hash="$2" add="$3"
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
  local lvl=info; case "$type" in done|acquired) lvl=ok;; conflict|error) lvl=err;; waiting|blocked|defer|needs-attention|reap) lvl=warn;; claimed|merging) lvl=accent;; esac
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
  # verdict
  [ "$A" = ok ] && [ "$B" = ok ] && [ "$C" = busy ] && [ "$wins" = 1 ] && [ "$D" = ok ] \
    && echo "[selftest] PASS ✓" || { echo "[selftest] FAIL ✗"; return 1; }
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
    policy)         swarm_policy_table "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" ;;
    policy-selftest) swarm_policy_selftest ;;
    *) echo "usage: swarm.sh {init|next|claim|release|post|tail|status|paths|selftest|policy|policy-selftest}" >&2; exit 2 ;;
  esac
fi
