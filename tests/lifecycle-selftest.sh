#!/usr/bin/env bash
# lifecycle-selftest.sh — pins `ace start` / `ace stop`: the ONE front door for a run.
#
# WHY THIS EXISTS: the defaults `ace start` resolves (self-merge, both debates, cited-URL verification) are a
# POLICY the owner signed off on. They change spend and what reaches main unattended, so a silent drift in any
# of them is exactly the class of regression nobody notices until a run has already merged something. Each
# default is pinned here by value, not by "it is set to something".
#
# HOW IT TESTS THE REAL THING WITHOUT STARTING A SWARM: ace_start's last act is to exec lib/swarm-run.sh.
# We point ACE_DIR at a temp tree whose lib/swarm-run.sh only RECORDS the environment it was handed, so the
# assertions are made against the env the real code actually exports — not against a re-implementation of it.
# Nothing spawns, nothing merges, no tokens.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
fail=0
bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib" "$WORK/repo" "$WORK/swarmdir"
# the recorder: dumps its environment, then exits 0 as a real detached start would
cat > "$WORK/lib/swarm-run.sh" <<'REC'
#!/usr/bin/env bash
{ echo "ARGV=$*"; env | grep -E '^(AUTOMERGE|SPEC_DEBATE|REVIEW_DEBATE|SPEC_LINT_NET|MAX_FEATURES|DEPLOY|SWARM_MAX|MERGE_GATE|SWARM_LIVE|DRY_RUN)='; } >> "$REC_OUT"
# EXIT 0 EXPLICITLY. Without this the recorder's status is the trailing `grep`'s, which is 1 whenever nothing
# matched (the `stop` path exports none of those vars) -- so a stubbed swarm-stop reported FAILURE, ace_stop
# left `stopped=0`, its service branch ran regardless, and a sabotage of that branch could not be detected.
# The test was green for a reason that had nothing to do with the property it claimed to check.
exit "${REC_RC:-0}"
REC
( cd "$WORK/repo" && git init -q . && git commit -q --allow-empty -m x ) 2>/dev/null

# run_start <ENV=v ...> -- <args to ace_start> -> the narration PLUS the env the real handoff received.
# LIB is absolute: the subshell cds into the fixture repo, so a relative source would miss.
LIB="$PWD/lib/lifecycle.sh"
run_start() {
  local out="$WORK/rec.$$.$RANDOM"; : > "$out"
  local envs=() ; while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift || true
  # CAPTURE THE ARGS BEFORE THE SUBSHELL. `set --` below is there so sourcing lifecycle.sh cannot inherit
  # this script's positional parameters (trap A13) -- but it also CLEARS them, so an `ace_start "$@"` inside
  # the subshell saw NOTHING. Every `ace start solo` / `ace start 9` silently became the bare default, and the
  # assertions blamed the shipped code for a defect that was entirely in this harness.
  local a1="${1:-}" a2="${2:-}"
  ( set --
    cd "$WORK/repo" || exit 1
    export ACE_DIR="$WORK" REC_OUT="$out" ACE_NO_DASH=1 SWARM_DIR="$WORK/swarmdir"
    for e in ${envs+"${envs[@]}"}; do export "$e"; done
    err(){  printf 'ERR %s\n' "$*"; }; info(){ printf 'INFO %s\n' "$*"; }
    say(){  printf 'SAY %s\n' "$*"; }; ok(){   printf 'OK %s\n' "$*"; }
    warn(){ printf 'WARN %s\n' "$*"; }
    config_get(){ eval "printf '%s' \"\${CFG_$1:-}\""; }
    autoloop_run(){ printf 'AUTOLOOP_RAN\n'; }
    loop_ctl(){ printf 'LOOP_CTL %s\n' "$*"; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 1
    ace_start ${a1:+"$a1"} ${a2:+"$a2"}
  ) 2>&1
  cat "$out" 2>/dev/null
}
export LIB WORK

# --- 1. THE OWNER-CONFIRMED DEFAULTS. Pinned by VALUE — this is the policy, and it is the whole point. ----
out="$(run_start -- 2 2>&1)"
for kv in AUTOMERGE=1 SPEC_DEBATE=1 REVIEW_DEBATE=1 SPEC_LINT_NET=1 MAX_FEATURES=0 DEPLOY=0 MERGE_GATE=local; do
  grep -qx -- "$kv" <<<"$out" || bad "ace start did not hand $kv to the swarm (owner-confirmed default drifted). got: $(grep -E "^${kv%%=*}=" <<<"$out" || echo MISSING)"
done
grep -q 'ARGV=startd' <<<"$out" || bad "ace start did not reach the DETACHED swarm start (ARGV=startd)"
grep -qx 'SWARM_LIVE=1' <<<"$out" || bad "ace start did not set SWARM_LIVE=1 — the run would be a dry demo"
grep -qx 'DRY_RUN=0'    <<<"$out" || bad "ace start did not set DRY_RUN=0 — the run would not do real work"

# EXIT CODE. A detached start that succeeded must return 0 even with stdout redirected. It did not: the
# function ended in `[ -t 1 ] && ... && (dash)`, whose own false became the return value, so `ace start > log`,
# a cron entry, a systemd unit and any wrapper script all read a healthy swarm as a failed launch.
( set --; cd "$WORK/repo" || exit 1
  export ACE_DIR="$WORK" REC_OUT="$WORK/rc.rec" ACE_NO_DASH=0 SWARM_DIR="$WORK/swarmdir"
  err(){ :; }; info(){ :; }; say(){ :; }; ok(){ :; }; warn(){ :; }; config_get(){ :; }; autoloop_run(){ :; }
  # shellcheck disable=SC1090
  . "$LIB" || exit 9
  ace_start 2 >/dev/null 2>&1
) ; _rc=$?
[ "$_rc" = 0 ] || bad "a SUCCESSFUL detached 'ace start' returned rc=$_rc with stdout redirected — every wrapper reads it as a failed launch"

# --- 2. NARRATION. A default the user cannot see is a default the user did not choose. --------------------
for phrase in 'self-merge' 'spec debate' 'review debate' 'verify citations' 'workers' 'deploy' 'features'; do
  grep -qi -- "$phrase" <<<"$out" || bad "ace start never printed its resolved '$phrase' policy"
done
grep -q 'resolved policy' <<<"$out" || bad "ace start printed no policy header"

# --- 3. PRECEDENCE: env > config > default, for every policy key ------------------------------------------
# An explicit env value must beat both. This is what makes `AUTOMERGE=0 ace start` trustworthy.
out="$(run_start AUTOMERGE=0 SPEC_DEBATE=0 -- 2)"
grep -qx 'AUTOMERGE=0'   <<<"$out" || bad "env AUTOMERGE=0 was overridden — the per-run override does not work"
grep -qx 'SPEC_DEBATE=0' <<<"$out" || bad "env SPEC_DEBATE=0 was overridden"
grep -q  '\[env\]'       <<<"$out" || bad "narration does not say an env override was the SOURCE (user cannot tell why)"
# a stored config value must beat the default but lose to env
out="$(run_start CFG_AUTOMERGE=0 -- 2)"
grep -qx 'AUTOMERGE=0' <<<"$out" || bad "a stored config AUTOMERGE=0 (Settings toggle) was ignored by ace start"
grep -q '\[config\]'   <<<"$out" || bad "narration does not attribute a value to stored settings"
out="$(run_start AUTOMERGE=1 CFG_AUTOMERGE=0 -- 2)"
grep -qx 'AUTOMERGE=1' <<<"$out" || bad "env did NOT beat config — precedence is inverted"

# --- 4. WORKER RESOLUTION -------------------------------------------------------------------------------
grep -qx 'SWARM_MAX=2' <<<"$(run_start -- 2)"  || bad "'ace start 2' did not resolve 2 workers"
grep -qx 'SWARM_MAX=3' <<<"$(run_start -- )"   || bad "bare 'ace start' did not default to 3 workers"
grep -qx 'SWARM_MAX=4' <<<"$(run_start CFG_SWARM_MAX=4 -- )" || bad "stored SWARM_MAX was ignored by bare 'ace start'"
# `solo` must NOT reach the swarm at all — it is the single-flow loop
o="$(run_start -- solo)"
grep -q 'AUTOLOOP_RAN' <<<"$o" || bad "'ace start solo' did not run the single-flow loop"
grep -q 'ARGV='        <<<"$o" && bad "'ace start solo' still handed off to the SWARM — solo must be one flow"
# an absurd worker count is capped, not obeyed
o="$(run_start -- 9)"
grep -qx 'SWARM_MAX=5' <<<"$o" || bad "'ace start 9' was not capped to 5 workers"
grep -qi 'capping'     <<<"$o" || bad "'ace start 9' capped silently — the user still thinks they got 9"

# --- 5. DOUBLE-START REFUSAL ----------------------------------------------------------------------------
# Two coordinators over one repo = two workers on one item, two branches, a merge race. The second start
# must REFUSE, and must not reach the handoff.
printf '%s' "$$" > "$WORK/swarmdir/coordinator.pid"     # $$ is alive: this test process
o="$(run_start -- 2)"
grep -q 'ERR .*already running' <<<"$o" || bad "ace start did not refuse to start over a LIVE swarm"
grep -q 'ARGV='                 <<<"$o" && bad "ace start refused but STILL handed off to the swarm"
# ...and a STALE pidfile (trap A10) must NOT count as live, or ace start could never start again after a crash
printf '%s' '2147480000' > "$WORK/swarmdir/coordinator.pid"   # a pid that cannot exist
grep -q 'ARGV=startd' <<<"$(run_start -- 2)" || bad "a STALE coordinator.pid blocked ace start forever (pidfile trusted without kill -0)"
rm -f "$WORK/swarmdir/coordinator.pid"

# --- 6. FAIL-OPEN HONESTY: debate ON with no credential must SAY it will skip ----------------------------
o="$(run_start OPENROUTER_API_KEY= -- 2)"
grep -qi 'WARN.*debate is ON but' <<<"$o" || bad "debate ON without OPENROUTER_API_KEY did not warn it will fail OPEN — a gate that silently skips reads as a gate that passed"
o="$(run_start OPENROUTER_API_KEY=sk-x DEBATE_MODEL_B=openrouter/m -- 2)"
grep -qi 'WARN.*debate is ON but' <<<"$o" && bad "warned about a missing debate credential that WAS present (false alarm trains users to ignore it)"

# --- 7. ace stop ----------------------------------------------------------------------------------------
# _stop <live-swarm 0|1> <live-service 0|1>
# The liveness probes are stubbed through the ENVIRONMENT, not through positional parameters: `set --` clears
# `$1`, and a function definition cannot legally follow `&&` (`[ "$1" = 1 ] && f(){ ...; }` is a syntax error,
# which silently took the whole helper out of service and failed all seven stop assertions at once).
_stop(){ # <live-swarm 0|1> <live-service 0|1> [rc-of-the-stop-command]
  local sw="${1:-0}" sv="${2:-0}" rc="${3:-0}"     # read BEFORE the subshell: `set --` clears $1/$2 (same trap, twice)
  ( set --
    cd "$WORK/repo" || exit 1
    export ACE_DIR="$WORK" REC_OUT="$WORK/stop.rec" SWARM_DIR="$WORK/swarmdir" SW="$sw" SV="$sv" REC_RC="$rc"
    : > "$WORK/stop.rec"
    err(){ printf 'ERR %s\n' "$*"; }; info(){ printf 'INFO %s\n' "$*"; }
    say(){ printf 'SAY %s\n' "$*"; }; ok(){ printf 'OK %s\n' "$*"; }; warn(){ printf 'WARN %s\n' "$*"; }
    config_get(){ :; }; loop_ctl(){ printf 'LOOP_CTL %s\n' "$*"; }
    # shellcheck disable=SC1090
    . "$LIB" || exit 1
    _ace_swarm_live(){   [ "$SW" = 1 ]; }
    _ace_service_live(){ [ "$SV" = 1 ]; }
    ace_stop; printf 'RC=%s\n' "$?"
  ) 2>&1
}
o="$(_stop 0 0)"
grep -q 'nothing is running' <<<"$o" || bad "ace stop with nothing running did not say so"
grep -q 'RC=0'               <<<"$o" || bad "ace stop with nothing running must succeed, not error"
grep -qi 'foreground'        <<<"$o" || bad "ace stop did not name the one flow it CANNOT stop (a foreground loop in another terminal)"
o="$(_stop 1 0)"
grep -q 'ARGV=stop' <<<"$(cat "$WORK/stop.rec" 2>/dev/null)" || bad "ace stop did not stop a LIVE swarm"
o="$(_stop 0 1)"
grep -q 'LOOP_CTL stop' <<<"$o" || bad "ace stop did not stop the ace-loop SERVICE"
# BOTH at once: they are independent, and stopping only the first one found leaves a run still spending.
o="$(_stop 1 1)"
grep -q 'LOOP_CTL stop' <<<"$o" || bad "with BOTH a swarm and the service live, ace stop skipped the service"
grep -q 'ARGV=stop' <<<"$(cat "$WORK/stop.rec" 2>/dev/null)" || bad "with BOTH live, ace stop skipped the swarm"

# A STOP COMMAND THAT ERRORS IS A FAILURE, NOT AN ABSENCE. Gating `stopped` on the exit status meant a
# swarm-stop returning non-zero (a worker already gone, a cleanup step failing) fell through to the final
# branch and printed "nothing is running here" — directly after trying to stop a live swarm. The user is then
# told the opposite of the truth about a run that may still be spending.
o="$(_stop 1 0 1)"
grep -q 'nothing is running' <<<"$o" && bad "a FAILING swarm-stop made ace stop report 'nothing is running' — a failure must be reported as a failure, never as an absence"
grep -qi 'WARN' <<<"$o" || bad "a FAILING swarm-stop was not surfaced to the user at all"

# --- 8. the old verbs still work (this is an ADDITION, not a replacement) --------------------------------
grep -qE '^\s+autoloop\|autorun\|loop\|resume\)' ace || bad "the legacy run verbs were removed — old muscle memory and every doc reference break"
grep -qE '^\s+start\)' ace || bad "ace lost the 'start' dispatch arm"
grep -qE '^\s+stop\)'  ace || bad "ace lost the 'stop' dispatch arm"
grep -qE '^  ace start ' ace || bad "'ace start' is dispatched but absent from usage()"
grep -qE '^  ace stop '  ace || bad "'ace stop' is dispatched but absent from usage()"

[ "$fail" = 0 ] && echo "lifecycle-selftest: PASS — start defaults pinned (automerge/debate×2/net ON), precedence env>config>default, workers resolved+capped, double-start refused, stale pid ignored, stop covers swarm+service"
[ "$fail" = 0 ] || echo "lifecycle-selftest: FAIL — see above"
exit "$fail"
