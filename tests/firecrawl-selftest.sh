#!/usr/bin/env bash
# firecrawl-selftest — pins firecrawl_ensure: the run-start research-backend decision.
#
# THE DEFECT IT PINS (observed live, not hypothesised): `mcp.firecrawl.enabled` was decided once, at
# `ace opencode` time, by probing 127.0.0.1:3002. Running `ace firecrawl up` AFTER that left the crawler
# running and the MCP still disabled -- so a full re-analysis pass produced 16 citations, every one an
# in-repo file reference, ZERO web research, and nothing anywhere said so.
#
# Both halves are asserted: the config must be flipped to match reality, and every degraded path must SAY
# which backend the run actually got. A silent fallback is the bug; a loud fallback is the feature.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

fail=0
bad(){ echo "FAIL: $*"; fail=1; }
command -v jq >/dev/null 2>&1 || { echo "firecrawl-selftest: jq missing — INCONCLUSIVE, not clean"; exit 1; }

# Drive firecrawl_ensure against a throwaway HOME + config.
# $1 = initial enabled value, $2 = "up"|"down" (whether the probe answers), $3.. = extra env assignments.
probe(){
  local initial="$1" reachable="$2"; shift 2
  local d out; d="$(mktemp -d)" || return 1
  mkdir -p "$d/cfg/opencode"
  jq -n --argjson v "$initial" '{mcp:{firecrawl:{type:"local",enabled:$v}}}' > "$d/cfg/opencode/opencode.json"
  out="$(
    set --                                   # A13: never let a sourced lib see our positional params
    . lib/consistency.sh >/dev/null 2>&1
    say(){ printf 'SAY %s\n' "$*"; }         # capture the narration this feature exists to produce
    # Shadow the reachability probe rather than binding a real port: hermetic, and no listening socket.
    if [ "$reachable" = up ]; then curl(){ return 0; }; else curl(){ return 7; }; fi
    export XDG_CONFIG_HOME="$d/cfg" HOME="$d"
    "$@" 2>/dev/null
    firecrawl_ensure
    printf 'FINAL %s\n' "$(jq -r '.mcp.firecrawl.enabled' "$d/cfg/opencode/opencode.json" 2>/dev/null)"
  )"
  printf '%s' "$out"
  rm -rf "$d"
}

# --- 1. THE ACTUAL BUG: crawler reachable, MCP disabled → must be flipped ON, and said out loud ---------
out="$(probe false up)"
grep -q '^FINAL true$'   <<<"$out" || bad "reachable + disabled: MCP was NOT enabled (this is the exact shipped defect)"$'\n'"$out"
grep -qi 'MCP ENABLED'   <<<"$out" || bad "reachable + disabled: enabling it was not narrated"$'\n'"$out"

# --- 2. already enabled → stays enabled, no churn -------------------------------------------------------
out="$(probe true up)"
grep -q '^FINAL true$'          <<<"$out" || bad "reachable + enabled: flag was clobbered"$'\n'"$out"
grep -qi 'already enabled'      <<<"$out" || bad "reachable + enabled: state not reported"$'\n'"$out"

# --- 3. opt-out honoured, and the degraded backend is NAMED --------------------------------------------
out="$(probe true down env FIRECRAWL_AUTO=0)"
grep -q '^FINAL false$' <<<"$out" || bad "FIRECRAWL_AUTO=0 + down: stale enabled=true left in the config — opencode would try to start a dead MCP every launch"$'\n'"$out"
grep -qi 'webfetch'     <<<"$out" || bad "FIRECRAWL_AUTO=0: fell back WITHOUT naming the backend — the silent fallback is the bug"$'\n'"$out"

# --- 4. no compose dir → degrade, do not block, and say why --------------------------------------------
out="$(probe false down)"
grep -q '^FINAL false$' <<<"$out" || bad "no compose: config should stay false"$'\n'"$out"
grep -qi 'webfetch'     <<<"$out" || bad "no compose: fallback not narrated"$'\n'"$out"

# --- 5. an install WITHOUT the firecrawl MCP must be left completely alone ------------------------------
d="$(mktemp -d)"; mkdir -p "$d/cfg/opencode"
printf '{"mcp":{"serena":{"enabled":true}}}' > "$d/cfg/opencode/opencode.json"
before="$(cat "$d/cfg/opencode/opencode.json")"
( set --; . lib/consistency.sh >/dev/null 2>&1; say(){ :; }; curl(){ return 7; }
  export XDG_CONFIG_HOME="$d/cfg" HOME="$d"; firecrawl_ensure ) >/dev/null 2>&1
[ "$(cat "$d/cfg/opencode/opencode.json")" = "$before" ] || bad "an install with no firecrawl MCP had its config rewritten"
rm -rf "$d"

# --- 6. the config must NEVER be left unparseable -------------------------------------------------------
# _fce_set validates with `jq -e .` before mv. Feed it a config it cannot process and assert the original
# survives intact: a truncated opencode.json breaks every agent, far worse than the wrong research backend.
d="$(mktemp -d)"; mkdir -p "$d/cfg/opencode"
printf '{"mcp":{"firecrawl":{"enabled":false}}}' > "$d/cfg/opencode/opencode.json"
( set --; . lib/consistency.sh >/dev/null 2>&1
  jq(){ return 1; }                                    # every jq call fails mid-flight
  export XDG_CONFIG_HOME="$d/cfg" HOME="$d"; _fce_set true "$d/cfg/opencode/opencode.json" ) >/dev/null 2>&1
jq -e . "$d/cfg/opencode/opencode.json" >/dev/null 2>&1 || bad "config left UNPARSEABLE after a failed write — this would break every agent"
rm -rf "$d"

# --- 7. the hooks exist (a function nothing calls is not a feature) -------------------------------------
grep -q 'firecrawl_ensure' lib/autoloop.sh   || bad "firecrawl_ensure is not called from the autoloop preflight"
grep -q 'firecrawl_ensure' lib/swarm-run.sh  || bad "firecrawl_ensure is not called from swarm_preflight"

if [ "$fail" = 0 ]; then
  echo "firecrawl-selftest: PASS — MCP flag tracks reality, every fallback names its backend, config never corrupted"
else
  echo "firecrawl-selftest: FAIL"
fi
exit "$fail"
