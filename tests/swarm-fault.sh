#!/usr/bin/env bash
# swarm-fault.sh — prove self-healing: dead-worker lease reclaim, retry budget,
# poison-item parking, and reconcile-on-restart. No repo/credits needed.
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
SW="$LIB/swarm.sh"
export SWARM_DIR; SWARM_DIR="$(mktemp -d)/store"
export SWARM_MAX_TRIES=3
ST="$SWARM_DIR/state.json"
h(){ printf '%s' "$1" | cksum | cut -d' ' -f1; }
status(){ jq -r --arg h "$(h "$1")" '.claims[$h].status // "none"' "$ST"; }
tries(){ jq -r --arg h "$(h "$1")" '.claims[$h].tries // 0' "$ST"; }
P=0; ok(){ [ "$2" = "$3" ] && echo "  ✓ $1 ($2)" || { echo "  ✗ $1: got '$2' want '$3'"; P=1; }; }

echo "════════ SWARM FAULT-INJECTION ════════"
echo "── 1. dead-worker lease is reclaimed (not stuck forever) ──"
bash "$SW" claim w1 "feature-A" "src/a.ts" >/dev/null            # w1 grabs it, then "dies"
ok "claimed active" "$(status feature-A)" active
ok "tries=1" "$(tries feature-A)" 1
sleep 2; bash "$SW" reap 1 | sed 's/^/    reaped: /'              # TTL=1s, worker silent → reclaim
ok "reaped → orphaned (claimable again)" "$(status feature-A)" orphaned
ok "tries preserved" "$(tries feature-A)" 1

echo "── 2. a healthy worker re-claims the reclaimed item ──"
r="$(bash "$SW" claim w2 "feature-A" "src/a.ts")"
ok "re-claim ok" "$r" ok
ok "tries incremented" "$(tries feature-A)" 2

echo "── 3. poison item parks after MAX_TRIES (stops burning credits) ──"
sleep 2; bash "$SW" reap 1 >/dev/null                            # 2nd death → orphaned (tries 2 < 3)
ok "still retrying" "$(status feature-A)" orphaned
bash "$SW" claim w3 "feature-A" "src/a.ts" >/dev/null            # 3rd attempt (tries → 3)
sleep 2; out="$(bash "$SW" reap 1)"                              # 3rd death → PARK
echo "$out" | grep -q '^PARK' && echo "  ✓ reaper emitted PARK" || { echo "  ✗ no PARK"; P=1; }
ok "parked" "$(status feature-A)" parked
r="$(bash "$SW" claim w4 "feature-A" "src/a.ts")"
ok "parked item refuses re-claim" "$r" parked

echo "── 4. reconcile-on-restart reclaims a crashed run's active lease ──"
bash "$SW" claim w9 "feature-B" "src/b.ts" >/dev/null            # simulate an in-flight lease at crash
ok "active before restart" "$(status feature-B)" active
bash "$SW" reconcile | sed 's/^/    /'                           # coordinator restarts
ok "reconciled → orphaned (requeued)" "$(status feature-B)" orphaned

echo; echo "════════ VERDICT ════════"
[ "$P" = 0 ] && echo "PASS ✓  dead leases reclaimed · retries bounded · poison parked · restart reconciled" \
             || { echo "FAIL ✗"; exit 1; }
