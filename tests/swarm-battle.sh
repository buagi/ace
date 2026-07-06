#!/usr/bin/env bash
# swarm-battle.sh — run the swarm on swarm-lab and AUDIT it hard.
#
#   DRY (default): simulated edits + real worktrees + real merge queue, no credits.
#   Proves the COORDINATION survives an adversarial shared-file workload:
#     1. every feature merged           2. git integrity intact
#     3. SAFETY INVARIANT: no two features whose file-leases OVERLAP were ever
#        active at the same time (reconstructed from the message bus)
#     4. reports achieved parallelism + which hot files forced serialization
set -uo pipefail
LAB="${1:-$HOME/Desktop/code/swarm-lab}"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
. "$LIB/swarm.sh"
export SWARM_DIR="$HOME/.config/ace/swarm/$(basename "$LAB")"
MAX="${MAX:-4}"; SWARM_SIM_DELAY="${SWARM_SIM_DELAY:-2}"

echo "════════ SWARM BATTLE TEST ════════"
echo "lab=$LAB  MAX=$MAX  sim_delay=${SWARM_SIM_DELAY}s  store=$SWARM_DIR"
rm -rf "$SWARM_DIR"; git -C "$LAB" worktree prune 2>/dev/null || true
# reset lab main to the SCAFFOLD (root) commit so each run starts clean + repeatable
base="$(git -C "$LAB" rev-list --max-parents=0 main | tail -1)"
git -C "$LAB" checkout -q main; git -C "$LAB" reset -q --hard "$base"

echo; echo "── running swarm (DRY) ──"
SWARM_REPO="$LAB" SWARM_DIR="$SWARM_DIR" DRY_RUN=1 MAX="$MAX" SWARM_SIM_DELAY="$SWARM_SIM_DELAY" \
  bash "$LIB/swarm-run.sh" start 2>&1 | grep -vE "Deleted branch|Preparing|HEAD is now" | sed 's/^/  /'

MSG="$SWARM_DIR/messages.jsonl"
echo; echo "── AUDIT ──"

# 1) completeness + integrity
merged="$(git -C "$LAB" log --oneline | grep -c 'swarm(sim)')"
git -C "$LAB" fsck --full >/dev/null 2>&1 && integ=OK || integ=CORRUPT
echo "1) features merged: $merged/10   git integrity: $integ"

# 2) build per-feature active intervals from the bus
mapfile -t ITEMS < <(jq -rc 'select(.type=="claimed") | .item' "$MSG" | sort -u)
declare -A START END PATHS
for it in "${ITEMS[@]}"; do
  START["$it"]="$(jq -r --arg i "$it" 'select(.type=="claimed" and .item==$i) | .ts' "$MSG" | sort -n | head -1)"
  END["$it"]="$(jq -r --arg i "$it" 'select((.type=="done" or .type=="conflict") and .item==$i) | .ts' "$MSG" | sort -n | tail -1)"
  PATHS["$it"]="$(swarm_paths_for_item "$it")"
done

# 3) SAFETY INVARIANT — no overlapping-path pair had overlapping active intervals
violations=0; overlaps_checked=0
for ((a=0; a<${#ITEMS[@]}; a++)); do
  for ((b=a+1; b<${#ITEMS[@]}; b++)); do
    i="${ITEMS[a]}"; j="${ITEMS[b]}"
    if _overlap "${PATHS[$i]}" "${PATHS[$j]}"; then
      overlaps_checked=$((overlaps_checked+1))
      s1="${START[$i]}"; e1="${END[$i]:-$s1}"; s2="${START[$j]}"; e2="${END[$j]:-$s2}"
      # strict interval overlap (serialized items touch at a boundary → not a violation)
      if [ "$s1" -lt "$e2" ] && [ "$s2" -lt "$e1" ]; then
        violations=$((violations+1))
        echo "   ✗ VIOLATION: overlapping-path features ran concurrently:"
        echo "       A [$s1..$e1] ${i:0:45}"
        echo "       B [$s2..$e2] ${j:0:45}"
        echo "       shared ⟨$(comm -12 <(tr ' ' '\n' <<<"${PATHS[$i]}"|sort) <(tr ' ' '\n' <<<"${PATHS[$j]}"|sort)|tr '\n' ' ')⟩"
      fi
    fi
  done
done
echo "3) safety: $overlaps_checked overlapping-path pairs checked → $violations violations  (expect 0)"

# 4) achieved parallelism (max simultaneously-active features) via event sweep
maxpar="$(jq -rc 'select(.type=="claimed" or .type=="done" or .type=="conflict") | [.ts, (if .type=="claimed" then 1 else -1 end)] | @tsv' "$MSG" \
  | sort -n -k1 | awk '{c+=$2; if(c>m)m=c} END{print m+0}')"
echo "4) peak concurrency observed: $maxpar flows   (adversarial graph still parallelized)"

echo; echo "── serialization forced by hot files ──"
for hot in src/lib/money.ts src/api/routes.ts src/db/schema.ts src/orders/types.ts; do
  n="$(printf '%s\n' "${ITEMS[@]}" | grep -Fc "$hot")"
  echo "   $hot → $n features (ran one-at-a-time)"
done

echo; echo "════════ VERDICT ════════"
if [ "$merged" = 10 ] && [ "$integ" = OK ] && [ "$violations" = 0 ]; then
  echo "PASS ✓  all 10 merged · integrity OK · ZERO lease-overlap violations · peak $maxpar-way parallel"
else
  echo "FAIL ✗  merged=$merged integrity=$integ violations=$violations"; exit 1
fi
