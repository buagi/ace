#!/usr/bin/env bash
# lifecycle.sh — ONE verb to start a run, ONE verb to stop it.
#
# WHY THIS EXISTS (all measured, see docs/deferred-decisions.md → "CLI unification"):
# There were FOUR names for the same run command (`autoloop|autorun|loop|resume` is a single case arm at
# `ace:371`, byte-identical), TWO doors to the swarm with DIFFERENT defaults (SWARM_MAX defaults 1 via
# autorun, 2 via `swarm start`), `ace loop start` meant something else entirely (systemd), and there was NO
# `ace stop` AT ALL — stopping meant knowing whether you were in a swarm, a service or a foreground loop and
# picking the matching incantation. Meanwhile the quality gates a user assumes are on (debate,
# net-verification) defaulted OFF, and the interactive answers were overridden by hardcoded worker env.
#
# `ace start` resolves the prerequisites itself and STATES the policy it resolved before spending anything.
# `ace stop` stops whatever is actually running, without you having to know which flow it was.
#
# NOTHING IS DEPRECATED. Every old verb still works and still does exactly what it did; these two are a
# front door, not a replacement. That is deliberate: muscle memory and the docs both reference the old names.

# ── policy resolution ─────────────────────────────────────────────────────────────────────────────────────
# PRECEDENCE, matching the one `autoloop.sh` already uses for SPEC_LINT_NET: an explicit env value wins, then
# a stored config value, then the `ace start` default. So `AUTOMERGE=0 ace start` and Settings → toggles both
# beat the default, and neither is silently reversed.
#
# NOTE the empty-vs-unset distinction: `${!k:-}` treats an explicitly-empty env var as unset, which is what we
# want — `AUTOMERGE= ace start` means "I didn't decide", not "off". Only a real value overrides.
# Sets $k in the ENVIRONMENT and reports where the value came from in $_ACE_POLICY_SRC.
#
# IT MUST NOT BE CALLED IN A COMMAND SUBSTITUTION, and it does not print its answer, because that is exactly
# how the first version of this failed: `src=$(_ace_policy AUTOMERGE 1)` ran the `export` inside the
# substitution's SUBSHELL, so every owner-confirmed default (self-merge, both debates, cited-URL verification)
# resolved to a value the parent never saw -- the narration printed "off [default]" for all four and the swarm
# was handed none of them. That is trap A12 (`VAR=x other=$(cmd)` never exports) wearing a different hat: any
# environment change made inside `$( )` is discarded. Hence an out-parameter, not stdout.
_ace_policy() {
  local k="$1" d="$2" v
  v="${!k:-}" ; _ACE_POLICY_SRC=env
  if [ -z "$v" ]; then v="$(config_get "$k" 2>/dev/null)"; _ACE_POLICY_SRC=config; fi
  if [ -z "$v" ]; then v="$d"; _ACE_POLICY_SRC=default; fi
  export "$k=$v"
}

# _ace_swarm_dir <root> — the swarm state dir for a repo. Same derivation dash.sh uses, so "is it live"
# agrees between `ace dash`, `ace start` and `ace stop` instead of each probing its own path.
_ace_swarm_dir() { printf '%s' "${SWARM_DIR:-$HOME/.config/ace/swarm/$(basename "${1:-$PWD}")}"; }

# _ace_swarm_live <root> — 0 when a coordinator is actually alive.
# `kill -0` ON TOP OF the pidfile, never the pidfile alone (trap A10): a stale pidfile after a crash would
# otherwise report a live swarm forever and `ace start` would refuse to ever start again.
_ace_swarm_live() {
  local cpid; cpid="$(cat "$(_ace_swarm_dir "${1:-$PWD}")/coordinator.pid" 2>/dev/null)"
  [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null
}

# _ace_service_live — 0 when the detached systemd loop service is active.
_ace_service_live() {
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl --user is-active --quiet ace-loop.service 2>/dev/null
}

# ── ace start ─────────────────────────────────────────────────────────────────────────────────────────────
# ace start [N|solo|fg]  — N workers (default 3), `solo` = the single-flow loop, `fg` = don't detach.
ace_start() {
  local root arg="${1:-}" arg2="${2:-}" n fg=0 src_am src_sd src_rd src_net
  root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  cd "$root" 2>/dev/null || { err "not a directory: $root"; return 1; }

  # REFUSE TO DOUBLE-START. Two coordinators over one repo means two workers claiming the same roadmap item,
  # two branches for one feature and a merge race — and the second start would look like it worked.
  if _ace_swarm_live "$root"; then
    err "a swarm is already running here — 'ace dash' to watch it, 'ace stop' to stop it."; return 1
  fi
  if _ace_service_live; then
    err "the ace-loop service is already running — 'ace dash' to watch it, 'ace stop' to stop it."; return 1
  fi

  # NORMALISE `fg` OUT OF BOTH SLOTS FIRST, then match what is left. The previous shape matched `fg` in the
  # `case` and reassigned `arg="$arg2"` -- but a `case` does not re-test after an arm runs, so `ace start fg 5`
  # fell straight through with n unset and silently used the DEFAULT worker count. The user asked for 5,
  # was told nothing, and got 3.
  [ "$arg"  = fg ] && { fg=1; arg="$arg2"; arg2=; }
  [ "${arg2:-}" = fg ] && { fg=1; arg2=; }
  case "$arg" in
    solo|1)      n=1 ;;
    [0-9]|[0-9][0-9]) n="$arg" ;;
    "")          : ;;
    *)           err "usage: ace start [N|solo] [fg]   (N = 1-5 parallel workers)"; return 1 ;;
  esac
  if [ -z "${n:-}" ]; then
    n="$(config_get SWARM_MAX 2>/dev/null)"; n="${n//[!0-9]/}"
    # DEFAULT 3, not the old 1-or-2. Grounded, not picked: on a real roadmap 78 of 91 items shared a file, so
    # the path-disjointness rule caps EFFECTIVE parallelism near 3 anyway — a higher default would just queue.
    [ -z "$n" ] && n=3
  fi
  [ "$n" -ge 1 ] 2>/dev/null || n=1
  [ "$n" -gt 5 ] && { warn "capping workers at 5 (path-disjointness makes more of them queue, not work)."; n=5; }

  # THE POLICY. Owner-confirmed defaults (2026-07-22): automerge, both debates and net-verification ON.
  # These alter spend and what reaches main unattended, so they are RESOLVED and PRINTED before anything runs
  # — a default the user cannot see is a default the user did not choose.
  _ace_policy AUTOMERGE     1; src_am="$_ACE_POLICY_SRC"
  _ace_policy SPEC_DEBATE   1; src_sd="$_ACE_POLICY_SRC"
  _ace_policy REVIEW_DEBATE 1; src_rd="$_ACE_POLICY_SRC"
  _ace_policy SPEC_LINT_NET 1; src_net="$_ACE_POLICY_SRC"
  _ace_policy MAX_FEATURES  0                # 0 = work the roadmap until it is empty or you stop it
  _ace_policy DEPLOY        0                # deploying is outward-facing: opt IN, never a default
  export MERGE_GATE="${MERGE_GATE:-local}"   # the container gate — GitHub Actions is not on the critical path

  local _onoff; _onoff(){ [ "${1:-0}" = 1 ] && printf 'ON' || printf 'off'; }
  say "ace start — resolved policy (env > settings > default):"
  info "  workers .............. $n $([ "$n" = 1 ] && echo '(single flow)' || echo '(parallel, path-disjoint)')"
  info "  self-merge ........... $(_onoff "$AUTOMERGE") [$src_am] — green PRs merge through the local container gate"
  info "  features ............. $([ "${MAX_FEATURES:-0}" = 0 ] && echo 'unlimited (until the roadmap is empty, or ace stop)' || echo "$MAX_FEATURES")"
  # NOT "HIGH-risk specs": that describes the PRE-inversion gate. _debate_spec_eligible defaults to
  # DEBATE_SCOPE=nontrivial, which debates every spec EXCEPT one that positively declares itself trivial
  # (risk: LOW AND tier: FAST AND no live section). Understating the scope here understates the SPEND, at the
  # one moment the user is deciding whether to accept it.
  info "  spec debate .......... $(_onoff "$SPEC_DEBATE") [$src_sd] — cross-model review of every non-trivial spec (DEBATE_SCOPE=high narrows it)"
  info "  review debate ........ $(_onoff "$REVIEW_DEBATE") [$src_rd] — cross-model pass over the diff before merge"
  info "  verify citations ..... $(_onoff "$SPEC_LINT_NET") [$src_net] — cited URLs are fetched and checked"
  info "  deploy ............... $(_onoff "${DEPLOY:-0}") — 'ace deploy' ships; a run never does it for you"

  # HONESTY ABOUT WHETHER A GATE CAN ACTUALLY RUN. The debate fails OPEN without a challenger credential, so
  # "SPEC_DEBATE=ON" with no key reads as a gate that is protecting you while it is silently skipping. Say so
  # here, at the one moment the user can still fix it, rather than leaving it to a log line nobody reads.
  if [ "${SPEC_DEBATE:-0}" = 1 ] || [ "${REVIEW_DEBATE:-0}" = 1 ]; then
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      warn "  debate is ON but OPENROUTER_API_KEY is unset — it will FAIL OPEN (skip, not block). Settings → Providers & keys."
    elif [ -z "${DEBATE_MODEL_B:-$(config_get DEBATE_MODEL_B 2>/dev/null)}" ]; then
      warn "  debate is ON but DEBATE_MODEL_B is unset — it will FAIL OPEN (skip, not block). Settings → Cross-model debate."
    fi
  fi

  if [ "$n" = 1 ]; then
    say "starting the single-flow loop — 'ace stop' or Ctrl-C to stop."
    SWARM_MAX=1 autoloop_run; return $?
  fi

  export SWARM_MAX="$n"
  if [ "$fg" = 1 ]; then
    ( cd "$root" && SWARM_LIVE=1 DRY_RUN=0 SWARM_REPO="$root" bash "$ACE_DIR/lib/swarm-run.sh" start )
  else
    ( cd "$root" && SWARM_LIVE=1 DRY_RUN=0 SWARM_REPO="$root" bash "$ACE_DIR/lib/swarm-run.sh" startd ) || return 1
    # 'ace stats', NOT 'ace report': `ace report` FILES A GITHUB ISSUE. Pointing at it here re-introduced
    # the exact confusion the statsall split existed to avoid, in a brand-new string.
    ok "swarm started — 'ace dash' to watch · 'ace stop' to stop · 'ace stats' when it's done."
    # AN `if`, NOT AN `&&` CHAIN. As the last command of the function, `[ -t 1 ] && ...` RETURNS ITS OWN
    # FALSE when stdout is not a terminal -- so a successful detached start exited 1 under any pipe, cron,
    # systemd unit or `ace start > log`, and every caller read a healthy swarm as a failed launch.
    if [ -t 1 ] && [ -t 0 ] && [ "${ACE_NO_DASH:-0}" != 1 ]; then
      ( cd "$root" && SWARM_REPO="$root" bash "$ACE_DIR/lib/swarm-run.sh" dash )
    fi
  fi
  return 0
}

# ── ace stop ──────────────────────────────────────────────────────────────────────────────────────────────
# Stops whatever is actually running. Checks EVERY flow rather than the first match: a swarm and the service
# can both be up (they are independent), and stopping only the one it happened to find first is how "I
# stopped it" turns into a run that is still spending.
ace_stop() {
  local root stopped=0
  root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

  # `stopped` records that something WAS RUNNING AND WE ACTED ON IT — not that the stop command returned 0.
  # Gating it on the exit status was wrong in a way that inverts the message: a swarm-stop that exits non-zero
  # (a worker already gone, a cleanup step failing) left stopped=0, so ace_stop went on to print "nothing is
  # running here" immediately after trying to stop a live swarm. A failure has to be reported AS a failure,
  # never as an absence.
  if _ace_swarm_live "$root"; then
    say "stopping the swarm coordinator + its workers…"
    stopped=1
    ( cd "$root" && SWARM_REPO="$root" bash "$ACE_DIR/lib/swarm-run.sh" stop ) \
      || warn "the swarm stop command reported an error — check 'ace dash' that the coordinator is really gone."
  fi
  if _ace_service_live; then
    say "stopping the ace-loop systemd service…"
    stopped=1
    loop_ctl stop || warn "systemctl reported an error stopping ace-loop.service — check 'ace loop status'."
  fi

  if [ "$stopped" = 0 ]; then
    info "nothing is running for $(basename "$root") — no swarm coordinator, no ace-loop service."
    # A FOREGROUND loop lives in a terminal this process cannot reach, and claiming "stopped everything"
    # while one is still running in another tab would be a lie. Name the one case this verb cannot cover.
    info "(a loop running in the FOREGROUND of another terminal is stopped there with Ctrl-C.)"
    return 0
  fi
  ok "stopped. 'ace stats' for what the run produced · 'ace start' to resume where it left off."
}
