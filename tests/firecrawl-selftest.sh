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
  local extra="$*"          # captured BEFORE any `set --` that would clear $@
  local d out; d="$(mktemp -d)" || return 1
  mkdir -p "$d/cfg/opencode"
  jq -n --argjson v "$initial" '{mcp:{firecrawl:{type:"local",enabled:$v}}}' > "$d/cfg/opencode/opencode.json"
  out="$(
    # HERMETIC: the developer's own FIRECRAWL_API_KEY lives in the ambient env, and it silently turned
    # every self-hosted case below into a CLOUD case. A test that inherits the machine it runs on is not a
    # test. Start from nothing; each case declares the mode it means.
    unset FIRECRAWL_API_KEY FIRECRAWL_API_URL
    [ -n "$extra" ] && eval "$extra"         # mode knobs must be live BEFORE firecrawl_mode is called
    set --                                   # A13: never let a sourced lib see our positional params
    . lib/ui.sh >/dev/null 2>&1; . lib/core.sh >/dev/null 2>&1
    . lib/consistency.sh >/dev/null 2>&1
    ACE_SECRETS=/nonexistent                 # AFTER core.sh, which sets it — else the real key leaks in
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
out="$(probe false up "export FIRECRAWL_API_URL=http://127.0.0.1:3002")"
grep -q '^FINAL true$'   <<<"$out" || bad "reachable + disabled: MCP was NOT enabled (this is the exact shipped defect)"$'\n'"$out"
grep -qi 'MCP ENABLED'   <<<"$out" || bad "reachable + disabled: enabling it was not narrated"$'\n'"$out"

# --- 2. already enabled → stays enabled, no churn -------------------------------------------------------
out="$(probe true up "export FIRECRAWL_API_URL=http://127.0.0.1:3002")"
grep -q '^FINAL true$'          <<<"$out" || bad "reachable + enabled: flag was clobbered"$'\n'"$out"
grep -qi 'already enabled'      <<<"$out" || bad "reachable + enabled: state not reported"$'\n'"$out"

# --- 3. opt-out honoured, and the degraded backend is NAMED --------------------------------------------
out="$(probe true down "export FIRECRAWL_API_URL=http://127.0.0.1:3002; export FIRECRAWL_AUTO=0")"
grep -q '^FINAL false$' <<<"$out" || bad "FIRECRAWL_AUTO=0 + down: stale enabled=true left in the config — opencode would try to start a dead MCP every launch"$'\n'"$out"
grep -qi 'webfetch'     <<<"$out" || bad "FIRECRAWL_AUTO=0: fell back WITHOUT naming the backend — the silent fallback is the bug"$'\n'"$out"

# --- 4. no compose dir → degrade, do not block, and say why --------------------------------------------
out="$(probe false down "export FIRECRAWL_API_URL=http://127.0.0.1:3002")"
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

# --- 7. the hooks are actually INVOKED (a function nothing calls is not a feature) ----------------------
# This assertion used to be a bare `grep -q 'firecrawl_ensure' <file>`. Both call sites are introduced by a
# COMMENT that names the function, so the token survived deleting the call: the whole feature could be
# removed and this suite still printed "MCP flag tracks reality". Reproduced. Strip comments -- BOTH
# full-line and trailing -- and require the name in command position after a `&&` or at the start of a
# statement, so a mention can never stand in for an invocation.
_code_only(){ sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -vE '^[[:space:]]*$'; }
# HERE-STRING, not a pipe: `_code_only … | grep -q` is trap A4. grep exits at the match (line ~642 of
# ~1700), sed takes SIGPIPE, and under `set -o pipefail` the pipeline returns 141 -- so this assertion
# failed against correct code while matching fine in isolation. Third time this trap has bitten today.
_invokes(){ grep -qE '(^|[;&|][[:space:]]*|&&[[:space:]]*)firecrawl_ensure([[:space:]]|$|\))' <<<"$(_code_only "$1")"; }
_invokes lib/autoloop.sh  || bad "firecrawl_ensure is never INVOKED in lib/autoloop.sh (a comment mentioning it does not count)"
_invokes lib/swarm-run.sh || bad "firecrawl_ensure is never INVOKED in lib/swarm-run.sh (a comment mentioning it does not count)"


# --- MODE RESOLUTION: cloud / self-hosted / none -------------------------------------------------------
# firecrawl_mode is the single source of truth three layers now share (config generation, run preflight,
# swarm preflight). Each mode is pinned here because they previously disagreed, which is how a running
# crawler coexisted with a disabled MCP.

# CLOUD: a key and no URL must enable the MCP WITHOUT probing or starting anything local.
out="$(probe false down export FIRECRAWL_API_KEY=fc-test)"
grep -q '^FINAL true$'  <<<"$out" || bad "CLOUD: MCP not enabled — a paid cloud key would sit unused"$'\n'"$out"
grep -qi 'CLOUD'        <<<"$out" || bad "CLOUD: mode not named in the narration"$'\n'"$out"
grep -qi 'starting it'  <<<"$out" && bad "CLOUD: tried to start a LOCAL container — pointless on cloud, and it emits a false 'falls back to webfetch'"

# EMPTY-BUT-SET URL must not shadow the cloud key. This was the live state of the author's machine:
# `export FIRECRAWL_API_URL=` present with an empty value while a cloud key was configured.
out="$(probe false down "export FIRECRAWL_API_KEY=fc-test; export FIRECRAWL_API_URL=")"
grep -q '^FINAL true$' <<<"$out" || bad "empty-but-set FIRECRAWL_API_URL shadowed the cloud key — mode must treat empty as unset"$'\n'"$out"

# SELF-HOSTED WINS when both are set (matches firecrawl-mcp), but it must be SAID so a paid key is never
# silently bypassed.
m="$(bash -c '. lib/core.sh >/dev/null 2>&1; ACE_SECRETS=/nonexistent; export FIRECRAWL_API_URL=http://127.0.0.1:3002 FIRECRAWL_API_KEY=fc-test; firecrawl_mode')"
[ "$m" = local ] || bad "with BOTH set, mode must be 'local' (firecrawl-mcp lets the URL win); got: $m"

# NONE: neither configured — disable and name the degraded backend.
out="$(probe true down "unset FIRECRAWL_API_KEY FIRECRAWL_API_URL")"
grep -q '^FINAL false$' <<<"$out" || bad "NONE: stale enabled=true left behind — opencode would spawn a dead MCP every launch"$'\n'"$out"
grep -qi 'webfetch'     <<<"$out" || bad "NONE: degraded backend not named"$'\n'"$out"

# --- DOWNSTREAM CONSUMERS (B5): every call site must actually resolve the helpers ----------------------
# firecrawl_ensure calls say() (ui.sh) and firecrawl_mode() (core.sh). The swarm preflight sourced ONLY
# consistency.sh, leaving both undefined, so `firecrawl_mode || echo none` reported NO research backend
# for the whole fleet even on a valid cloud key. Assert each call site loads what it needs.
# Match the SOURCE STATEMENT, not the bare filename: the comment above that code explains why core.sh is
# needed and therefore CONTAINS the string "core.sh", so a filename grep passed even with the source line
# deleted. Same scoping trap that made md_has pass while a lesson had left the heredoc.
grep -qF '. "$HERE/ui.sh"'   lib/swarm-run.sh || bad "swarm preflight does not SOURCE ui.sh — say() undefined, narration lost"
grep -qF '. "$HERE/core.sh"' lib/swarm-run.sh || bad "swarm preflight does not SOURCE core.sh — firecrawl_mode undefined ⇒ silent fleet-wide 'none'"
bash -c 'set --; . lib/ui.sh >/dev/null 2>&1; . lib/core.sh >/dev/null 2>&1; . lib/consistency.sh >/dev/null 2>&1; declare -F firecrawl_mode >/dev/null && declare -F say >/dev/null' \
  || bad "the swarm subshell recipe does not resolve firecrawl_mode + say"

# --- ace keys must be able to SET the key (a key you cannot set is not settable) -----------------------
grep -q 'FIRECRAWL_API_KEY' lib/install.sh || bad "ace keys does not handle FIRECRAWL_API_KEY"
grep -q 'ask_secret "Firecrawl CLOUD API key' lib/install.sh || bad "no interactive prompt for the Firecrawl cloud key"
grep -qE 'fck="\$\{FIRECRAWL_API_KEY:-\}"' lib/install.sh || bad "headless ace keys does not read FIRECRAWL_API_KEY from env"

# --- the debate must actually be told to research ------------------------------------------------------
grep -q 'RESEARCH (you have tools' lib/debate.sh || bad "challenger prompt lost its research directive"
grep -q 'UNVERIFIED — <claim> (source unreachable' lib/debate.sh || bad "challenger is not required to mark unreachable sources UNVERIFIED"
grep -q 'GROUNDING: defend a claim about a THIRD-PARTY' lib/debate.sh || bad "defender prompt lost its grounding rule"

if [ "$fail" = 0 ]; then
  echo "firecrawl-selftest: PASS — MCP flag tracks reality, every fallback names its backend, config never corrupted"
else
  echo "firecrawl-selftest: FAIL"
fi
exit "$fail"
