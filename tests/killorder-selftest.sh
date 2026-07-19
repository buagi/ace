#!/usr/bin/env bash
# killorder-selftest — pins the B5 load-bearing ORDER inside _swarm_trap.
#
# THE GUARANTEE UNDER TEST (lib/swarm-run.sh, "B5: THE ORDER BELOW IS LOAD-BEARING"):
#   step 1 — TERM the auto-loop LEADERS, arming each loop's deferred cleanup()
#   step 2 — only THEN kill the workers' opencode trees, which unblocks that cleanup
# Bash defers a trap handler while a foreground command runs, so a loop sitting in
# `opencode run … | tee` cannot run cleanup() until its opencode returns. Reversing these two steps does not
# merely reorder signals: an un-signalled loop reacts to a dead opencode by starting a NEW one, and the
# in-flight WIP is never committed while the stop message still claims "WIP preserved".
#
# WHY THIS TEST LOOKS THE WAY IT DOES — three earlier attempts failed, all the same way:
# they observed signal RECEIPT (handlers in fake processes appending to a log). That races on handler
# scheduling: the trap can send the signals in the correct order and still see the receipts land reversed,
# because delivery-to-handler-execution is asynchronous. The result was a test that failed a few percent of
# the time for a reason unrelated to the property, which is worse than no test.
#
# What the guarantee is actually about is the order the trap SENDS signals. So this test intercepts the
# SENDS: `kill` and `_swarm_killtree` are redefined as shell functions (a function shadows the builtin) that
# append to an order log and deliver nothing. No signals, no processes to schedule, no race — the assertion
# is a pure function of the code path. Deterministic by construction.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

fail=0
bad(){ echo "FAIL: $*"; fail=1; }

# Runs _swarm_trap against a fixture with `kill`/`_swarm_killtree` stubbed, and prints the resulting order
# log. $1 = path to the swarm-run.sh to exercise (so the negative control can point at a mutated copy).
probe_order(){
  local lib="$1" d out
  d="$(mktemp -d)" || return 1
  mkdir -p "$d/swarm" "$d/wt/w1/.opencode"
  # Real-looking pids: _swarm_pidof runs them through _swarm_pid_ok, which rejects junk and low pids.
  echo 4242 > "$d/swarm/w1.loop.pid"
  echo 4343 > "$d/wt/w1/.opencode/.oppid"

  out="$(
    # `set --` is LOAD-BEARING, and its absence is what defeated three earlier attempts at this test.
    # A command substitution inside a function inherits that FUNCTION's positional parameters, so $1 here
    # was "lib/swarm-run.sh". Both swarm-run.sh and swarm.sh end in a `case "${1:-}"` CLI dispatcher whose
    # `*)` branch prints usage and `exit 2`s -- so sourcing the lib killed the subshell before a single line
    # of the probe ran. With stderr sent to /dev/null it left no trace: the probe just returned empty, which
    # reads exactly like "the trap sent no signals". Clear the positional params before sourcing.
    set --
    # shellcheck disable=SC1090
    source "$lib" >/dev/null 2>&1

    ORDER="$d/order.log"
    # Shadow the send primitives. Everything below records intent and delivers nothing.
    kill(){ printf 'kill %s\n' "$*" >> "$ORDER"; return 0; }
    _swarm_killtree(){ printf 'killtree %s %s\n' "${1:-}" "${2:-}" >> "$ORDER"; return 0; }
    # Identity checks pass (the fixture pids are not really an auto-loop), and nothing is ever alive, so the
    # grace poll and the SIGKILL escalation both fall straight through. Neither is under test here.
    _swarm_pid_is(){ return 0; }
    _swarm_alive(){ return 1; }

    SWARM_DIR="$d/swarm" WT_ROOT="$d/wt" SWARM_STOP_SWEEP=0 SWARM_STOP_GRACE=1
    export SWARM_DIR WT_ROOT SWARM_STOP_SWEEP SWARM_STOP_GRACE
    # _swarm_trap ends in `exit 130`; the subshell contains it.
    ( _swarm_trap ) >/dev/null 2>&1
    cat "$ORDER" 2>/dev/null
  )"
  rm -rf "$d"
  printf '%s' "$out"
}

# --- the assertion ------------------------------------------------------------------------------------
log="$(probe_order lib/swarm-run.sh)"

if [ -z "$log" ]; then
  # Fail CLOSED. An empty log means the trap never reached either step — a refactor moved the pidfile glob,
  # renamed a helper, or the fixture no longer matches. Reporting "ordering fine" off zero observations is
  # exactly the fail-open shape this repo keeps getting bitten by.
  bad "no signals were recorded at all — the fixture no longer drives _swarm_trap (glob or helper renamed?)"
else
  leader="$(grep -n '^kill -TERM 4242$'      <<<"$log" | head -1 | cut -d: -f1)"
  opencd="$(grep -n '^killtree 4343 TERM$'   <<<"$log" | head -1 | cut -d: -f1)"

  [ -n "$leader" ] || bad "step 1 never happened: the auto-loop leader (pid 4242) was never TERMed"$'\n'"$log"
  [ -n "$opencd" ] || bad "step 2 never happened: the opencode tree (pid 4343) was never killed"$'\n'"$log"

  if [ -n "$leader" ] && [ -n "$opencd" ]; then
    if [ "$leader" -lt "$opencd" ]; then
      echo "  ok  leader TERM (line $leader) precedes opencode tree kill (line $opencd)"
    else
      bad "B5 ORDER VIOLATED — opencode tree killed at line $opencd, BEFORE the loop leader TERM at line $leader."
      echo "     A loop whose opencode dies before it is signalled starts a NEW one; in-flight WIP is lost"
      echo "     while the stop message still claims it was preserved."
      printf '%s\n' "$log" | sed 's/^/     | /'
    fi
  fi
fi

# --- negative control (lesson B1: a test that cannot go red is decoration) -------------------------------
# Build a copy of swarm-run.sh with the two steps SWAPPED and assert this probe notices. Without this, a
# probe that silently stopped observing would keep printing ok forever.
ctl="$(mktemp -d)"
if cp lib/swarm-run.sh "$ctl/swap.sh" 2>/dev/null; then
  # Move the step-2 block (the .oppid loop) above the step-1 block (the .loop.pid TERM loop) using awk on the
  # two anchored ranges, so the control mutates the ORDER and nothing else.
  awk '
    /^  for f in "\$\{SWARM_DIR:-\/nonexistent\}"\/w\*\.loop\.pid/ && !seen1 { seen1=1; inblk=1 }
    inblk { blk1 = blk1 $0 "\n"; if ($0 ~ /^  done$/) { inblk=0 }; next }
    /^  for f in "\$\{WT_ROOT:-\/nonexistent\}"\/\*\/\.opencode\/\.oppid/ && !seen2 { seen2=1; inblk2=1 }
    inblk2 { blk2 = blk2 $0 "\n"; if ($0 ~ /^  done$/) { inblk2=0; printf "%s", blk2; printf "%s", blk1 }; next }
    { print }
  ' lib/swarm-run.sh > "$ctl/swap.sh" 2>/dev/null

  if bash -n "$ctl/swap.sh" 2>/dev/null && ! cmp -s lib/swarm-run.sh "$ctl/swap.sh"; then
    ctl_log="$(probe_order "$ctl/swap.sh")"
    cl="$(grep -n '^kill -TERM 4242$'    <<<"$ctl_log" | head -1 | cut -d: -f1)"
    co="$(grep -n '^killtree 4343 TERM$' <<<"$ctl_log" | head -1 | cut -d: -f1)"
    if [ -n "$cl" ] && [ -n "$co" ] && [ "$co" -lt "$cl" ]; then
      echo "  ok  negative control: with the steps swapped, the probe observes the reversed order"
    else
      bad "negative control did NOT reverse (leader=$cl opencode=$co) — the probe may not be observing the"$'\n'"     real ordering, so the ok above proves nothing. Do not trust this suite until fixed."
    fi
  else
    bad "negative control could not be built (awk swap produced no valid variant) — ordering claim unproven"
  fi
else
  bad "negative control could not be staged — ordering claim unproven"
fi
rm -rf "$ctl"

if [ "$fail" = 0 ]; then
  echo "killorder-selftest: PASS — B5 step order pinned, and revert-proved by a swapped-order control"
else
  echo "killorder-selftest: FAIL"
fi
exit "$fail"
