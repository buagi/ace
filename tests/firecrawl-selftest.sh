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

# EMPTY-URL SCRUB — the firecrawl-mcp NPM process reads FIRECRAWL_API_URL raw; an empty-but-exported value
# becomes its API base URL and every call fails "Invalid URL" (measured: a whole reanalyze fell back to
# webfetch while the cloud key worked). firecrawl_ensure must UNSET an empty one so no MCP child inherits it.
grep -q 'unset FIRECRAWL_API_URL' <<<"$(_code_only lib/consistency.sh)" \
  || bad "firecrawl_ensure does not unset an empty FIRECRAWL_API_URL — the firecrawl MCP will fail every call with 'Invalid URL'"
# behaviour: empty is unset, a real self-hosted URL survives
_scrub(){ bash -c 'FIRECRAWL_API_URL="'"$1"'"; [ -n "${FIRECRAWL_API_URL+x}" ] && [ -z "$(printf %s "${FIRECRAWL_API_URL:-}" | tr -d "[:space:]")" ] && unset FIRECRAWL_API_URL; echo "${FIRECRAWL_API_URL-UNSET}"'; }
[ "$(_scrub '')" = UNSET ]     || bad "empty FIRECRAWL_API_URL not scrubbed"
[ "$(_scrub '   ')" = UNSET ]  || bad "whitespace-only FIRECRAWL_API_URL not scrubbed"
[ "$(_scrub 'http://127.0.0.1:3002')" = 'http://127.0.0.1:3002' ] || bad "a real self-hosted FIRECRAWL_API_URL was wrongly scrubbed"


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
m="$(bash -c '. lib/consistency.sh >/dev/null 2>&1; ACE_SECRETS=/nonexistent; export FIRECRAWL_API_URL=http://127.0.0.1:3002 FIRECRAWL_API_KEY=fc-test; firecrawl_mode')"
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

# THE AUTOLOOP CHILD — the context a REAL run exposed and every prior test missed. autoloop.sh runs as a
# child process (scripts/auto-loop.sh) that CANNOT source core.sh (core installs an EXIT trap), so when
# firecrawl_mode lived in core.sh, firecrawl_ensure and the SPEC_LINT_NET resolver both got `none` and the
# run DISABLED research on a valid cloud key. firecrawl_mode + firecrawl_secret now live in consistency.sh,
# which autoloop.sh:20 sources. Pin it: they must resolve after sourcing ONLY what the autoloop child does.
_autoloop_ctx="$(bash -c 'set --; . lib/consistency.sh >/dev/null 2>&1
  command -v firecrawl_mode >/dev/null 2>&1 && command -v firecrawl_secret >/dev/null 2>&1 && echo OK' 2>/dev/null)"
[ "$_autoloop_ctx" = OK ] \
  || bad "firecrawl_mode/firecrawl_secret are NOT defined after sourcing consistency.sh alone — the autoloop child (which cannot source core.sh) resolves 'none' and disables research on a valid key"
# And they must NOT be defined ONLY in core.sh (the regression): sourcing core without consistency is the
# menu/install path, which is fine, but the autoloop path is consistency-only and is the one that broke.
grep -qE '^firecrawl_mode\(\)' lib/consistency.sh \
  || bad "firecrawl_mode is not DEFINED in lib/consistency.sh — it must live where the autoloop child can reach it, not only in core.sh"

# --- ace keys must be able to SET the key (a key you cannot set is not settable) -----------------------
grep -q 'FIRECRAWL_API_KEY' lib/install.sh || bad "ace keys does not handle FIRECRAWL_API_KEY"
grep -q 'ask_secret "Firecrawl CLOUD API key' lib/install.sh || bad "no interactive prompt for the Firecrawl cloud key"
grep -qE 'fck="\$\{FIRECRAWL_API_KEY:-\}"' lib/install.sh || bad "headless ace keys does not read FIRECRAWL_API_KEY from env"

# --- the debate must actually be told to research ------------------------------------------------------
grep -q 'RESEARCH (you have tools' lib/debate.sh || bad "challenger prompt lost its research directive"
grep -q 'UNVERIFIED — <claim> (source unreachable' lib/debate.sh || bad "challenger is not required to mark unreachable sources UNVERIFIED"
grep -q 'GROUNDING: defend a claim about a THIRD-PARTY' lib/debate.sh || bad "defender prompt lost its grounding rule"

# ======================================================================================================
# D1 — the config write must be ATOMIC and must not re-permission the user's file.
#
# THE DEFECT (measured, not hypothesised): _fce_set used a bare `mktemp`, which lands in $TMPDIR. That is
# routinely a DIFFERENT filesystem from ~/.config, so `mv` was copy-then-unlink, NOT rename(2) — a crash
# or ENOSPC mid-copy leaves exactly the truncated opencode.json the function's own header promised it
# could never leave. And `mktemp` creates 0600, which `mv` then carried onto the destination: the user's
# 0644 opencode.json was silently tightened to 0600 on every single flip.
# ------------------------------------------------------------------------------------------------------

# D1(a)+(d): mode AND ownership survive a real flip. 644 is the case that regressed; 640 proves we clone
# the target's mode rather than hardcoding a new one.
for _m in 644 640; do
  d="$(mktemp -d)"; cfg="$d/opencode.json"
  printf '{"mcp":{"firecrawl":{"type":"local","enabled":false}}}' > "$cfg"; chmod "$_m" "$cfg"
  own_before="$(stat -c %U:%G "$cfg")"
  ( set --; . lib/consistency.sh >/dev/null 2>&1; _fce_set true "$cfg" ) >/dev/null 2>&1
  [ "$(stat -c %a "$cfg")" = "$_m" ] \
    || bad "D1: a flip changed the config's mode $_m -> $(stat -c %a "$cfg") — the write silently re-permissions the user's opencode.json"
  [ "$(stat -c %U:%G "$cfg")" = "$own_before" ] \
    || bad "D1: a flip changed the config's ownership $own_before -> $(stat -c %U:%G "$cfg")"
  [ "$(jq -r '.mcp.firecrawl.enabled' "$cfg" 2>/dev/null)" = true ] \
    || bad "D1: the mode-preserving write did not actually flip the flag (a write that preserves everything and changes nothing is not a fix)"
  rm -rf "$d"
done

# D1(b): the temp file must be a SIBLING of the target, so `mv` is a real rename(2) on one filesystem.
# Shadow mktemp and inspect the TEMPLATE it is handed: a bare `mktemp` passes no argument at all.
d="$(mktemp -d)"; cfg="$d/opencode.json"
printf '{"mcp":{"firecrawl":{"enabled":false}}}' > "$cfg"
targ="$( ( set --; . lib/consistency.sh >/dev/null 2>&1
           mktemp(){ printf 'MKTEMPARG[%s]\n' "$*" >&2; command mktemp "$@"; }
           _fce_set true "$cfg" ) 2>&1 )"
grep -qF "MKTEMPARG[$cfg." <<<"$targ" \
  || bad "D1: the temp file is NOT created next to the target — cross-filesystem 'mv' is copy+unlink, so a crash mid-write truncates opencode.json"$'\n'"$targ"
rm -rf "$d"

# D1(c): a failure mid-write leaves the ORIGINAL byte-identical (not merely 'still parseable'), and drops
# no temp litter beside it. This is the stronger form of case 6 above.
d="$(mktemp -d)"; cfg="$d/opencode.json"
printf '{"mcp":{"firecrawl":{"enabled":false}},"agent":{"builder":{"model":"x"}}}' > "$cfg"
md5_before="$(md5sum < "$cfg")"
( set --; . lib/consistency.sh >/dev/null 2>&1
  jq(){ return 1; }                                    # every jq call fails mid-flight
  _fce_set true "$cfg" ) >/dev/null 2>&1
[ "$(md5sum < "$cfg")" = "$md5_before" ] \
  || bad "D1: a failed write did NOT leave the original config byte-identical — this is the truncation the header promises cannot happen"
[ "$(ls -1 "$d" | grep -c .)" = 1 ] \
  || bad "D1: a failed write left temp litter beside the config: $(ls -1 "$d" | tr '\n' ' ')"
rm -rf "$d"

# D1: the SAME defect existed at two sites in lib/install.sh (write_opencode_config's firecrawl block).
# Assert against CODE, not comments — the comments there now EXPLAIN the bare-mktemp defect, so an
# un-stripped grep for 'mktemp' would match the explanation and pass over a reverted fix.
_fcw="$(grep -F 'mcp.firecrawl.enabled=false' <<<"$(_code_only lib/install.sh)")"
[ -n "$_fcw" ] || bad "D1: no firecrawl config-write found in lib/install.sh at all"
grep -qF '$(mktemp)' <<<"$_fcw" \
  && bad "D1: lib/install.sh still writes the firecrawl flag through a bare \$(mktemp) — same cross-filesystem truncation + 0600 re-permission"$'\n'"$_fcw"
grep -qF '_ace_json_edit' <<<"$_fcw" \
  || bad "D1: lib/install.sh's firecrawl writes do not go through the shared atomic writer _ace_json_edit"$'\n'"$_fcw"

# ======================================================================================================
# D2 — firecrawl_ensure and `ace firecrawl status` must probe the SAME endpoint.
#
# THE DEFECT (reproduced): _fc_up in lib/install.sh hardcoded http://127.0.0.1:$port and ignored
# FIRECRAWL_API_URL, while firecrawl_ensure honoured it. With a self-hosted crawler on a non-default
# endpoint, ensure enabled the MCP reporting UP and status reported DOWN — and ensure's own degraded-path
# message tells the user to "Check: ace firecrawl status", the one command guaranteed to contradict it.
# ------------------------------------------------------------------------------------------------------
d="$(mktemp -d)"; mkdir -p "$d/cfg/opencode"
jq -n '{mcp:{firecrawl:{type:"local",enabled:false}}}' > "$d/cfg/opencode/opencode.json"
agree="$(
  set --
  unset FIRECRAWL_API_KEY
  export FIRECRAWL_API_URL=http://10.0.0.5:9999 XDG_CONFIG_HOME="$d/cfg" HOME="$d"
  . lib/ui.sh >/dev/null 2>&1; . lib/core.sh >/dev/null 2>&1
  . lib/consistency.sh >/dev/null 2>&1; . lib/install.sh >/dev/null 2>&1
  ACE_SECRETS=/nonexistent
  say(){ :; }; info(){ :; }; err(){ :; }
  # ONLY the configured non-default endpoint answers. A probe aimed at the hardcoded loopback default
  # gets connection-refused, which is exactly how the two used to disagree.
  curl(){ local a; for a in "$@"; do case "$a" in *10.0.0.5:9999*) return 0 ;; esac; done; return 7; }
  firecrawl_ensure >/dev/null 2>&1
  printf 'ENSURE=%s ' "$(jq -r '.mcp.firecrawl.enabled' "$d/cfg/opencode/opencode.json" 2>/dev/null)"
  ok(){ printf 'STATUS=up'; }; warn(){ printf 'STATUS=down'; }
  firecrawl_cmd status
)"
[ "$agree" = "ENSURE=true STATUS=up" ] \
  || bad "D2: firecrawl_ensure and 'ace firecrawl status' DISAGREE on a non-default FIRECRAWL_API_URL — got [$agree], want [ENSURE=true STATUS=up]"
rm -rf "$d"

# D2: the endpoint may exist ONLY in secrets.env — a headless/systemd run never sources ~/.bashrc, so
# `ace firecrawl up` writes the URL there and nothing exports it. Both sides must still resolve it (this
# is what going through firecrawl_secret buys, and what a raw ${FIRECRAWL_API_URL:-…} expansion misses).
d="$(mktemp -d)"; mkdir -p "$d/cfg/opencode"
jq -n '{mcp:{firecrawl:{type:"local",enabled:false}}}' > "$d/cfg/opencode/opencode.json"
printf 'export FIRECRAWL_API_URL=http://10.0.0.7:8888\n' > "$d/secrets.env"
agree="$(
  set --
  unset FIRECRAWL_API_KEY FIRECRAWL_API_URL          # nothing in the ENV — only in secrets.env
  export XDG_CONFIG_HOME="$d/cfg" HOME="$d"
  . lib/ui.sh >/dev/null 2>&1; . lib/core.sh >/dev/null 2>&1
  . lib/consistency.sh >/dev/null 2>&1; . lib/install.sh >/dev/null 2>&1
  ACE_SECRETS="$d/secrets.env"                       # AFTER core.sh, which sets it
  say(){ :; }; info(){ :; }; err(){ :; }
  curl(){ local a; for a in "$@"; do case "$a" in *10.0.0.7:8888*) return 0 ;; esac; done; return 7; }
  firecrawl_ensure >/dev/null 2>&1
  printf 'ENSURE=%s ' "$(jq -r '.mcp.firecrawl.enabled' "$d/cfg/opencode/opencode.json" 2>/dev/null)"
  ok(){ printf 'STATUS=up'; }; warn(){ printf 'STATUS=down'; }
  firecrawl_cmd status
)"
[ "$agree" = "ENSURE=true STATUS=up" ] \
  || bad "D2: a FIRECRAWL_API_URL present only in secrets.env is not resolved by both sides — got [$agree], want [ENSURE=true STATUS=up]"
rm -rf "$d"

# D2: ONE probe implementation, not two. Code-only, for the same reason as above — the comment on _fc_up
# now describes the hardcoded loopback URL it used to contain.
_fcup="$(grep -E '_fc_up\(\)[[:space:]]*\{' <<<"$(_code_only lib/install.sh)")"
grep -qF 'firecrawl_probe' <<<"$_fcup" \
  || bad "D2: _fc_up in lib/install.sh does not delegate to the shared firecrawl_probe — a second probe implementation will drift again"$'\n'"$_fcup"
grep -qF '127.0.0.1' <<<"$_fcup" \
  && bad "D2: _fc_up hardcodes a loopback URL again — it must resolve the endpoint through firecrawl_url"$'\n'"$_fcup"

# ======================================================================================================
# D3 — mode-resolution regression table (firecrawl_mode lives in lib/core.sh and is NOT edited here; this
# pins the BEHAVIOUR firecrawl_ensure derives from it). Every row asserts BOTH the resulting MCP enabled
# flag AND that the narration NAMES the mode — a run that picks the right backend silently is the
# original defect in a new costume.
# ------------------------------------------------------------------------------------------------------
# row: <label>|<initial enabled>|<up|down>|<env>|<expected FINAL>|<narration regex the mode must match>
while IFS='|' read -r _lbl _init _rch _env _want _says; do
  [ -n "$_lbl" ] || continue
  out="$(probe "$_init" "$_rch" "$_env")"
  grep -q "^FINAL $_want\$" <<<"$out" \
    || bad "D3[$_lbl]: MCP enabled flag wrong — want $_want"$'\n'"$out"
  grep -qiE "$_says" <<<"$out" \
    || bad "D3[$_lbl]: narration does not name the resolved mode (want /$_says/)"$'\n'"$out"
done <<'ROWS'
cloud: key only|false|down|export FIRECRAWL_API_KEY=fc-test|true|Firecrawl CLOUD
cloud: URL set-but-EMPTY must not shadow the key|false|down|export FIRECRAWL_API_KEY=fc-test; export FIRECRAWL_API_URL=|true|Firecrawl CLOUD
cloud: whitespace-only URL is not a URL|false|down|export FIRECRAWL_API_KEY=fc-test; export FIRECRAWL_API_URL='   '|true|Firecrawl CLOUD
none: whitespace-only URL, no key|true|down|export FIRECRAWL_API_URL='   '|false|NO Firecrawl backend
none: neither configured|true|down|unset FIRECRAWL_API_KEY FIRECRAWL_API_URL|false|NO Firecrawl backend
local: URL only, reachable|false|up|export FIRECRAWL_API_URL=http://127.0.0.1:3002|true|Firecrawl LOCAL
local: BOTH set — URL wins|false|up|export FIRECRAWL_API_KEY=fc-test; export FIRECRAWL_API_URL=http://127.0.0.1:3002|true|Firecrawl LOCAL
ROWS

# D3: the both-set row must additionally SAY the cloud key is being bypassed — core.sh's firecrawl_mode
# header promises its callers narrate this, and a paid key silently ignored is a money-costing silence.
out="$(probe false up "export FIRECRAWL_API_KEY=fc-test; export FIRECRAWL_API_URL=http://127.0.0.1:3002")"
grep -qi 'URL WINS' <<<"$out" \
  || bad "D3: with BOTH a cloud key and a self-hosted URL set, the run does not say the URL wins — the paid key is silently bypassed"$'\n'"$out"
grep -qi 'cloud key is NOT used' <<<"$out" \
  || bad "D3: the both-set narration does not state the cloud key goes unused"$'\n'"$out"

if [ "$fail" = 0 ]; then
  echo "firecrawl-selftest: PASS — MCP flag tracks reality, every fallback names its backend, config never corrupted"
else
  echo "firecrawl-selftest: FAIL"
fi
exit "$fail"
