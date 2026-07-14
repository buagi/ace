#!/usr/bin/env bash
# eval-run.sh — the crew eval RUNNER (Part F / F1, Edit 2). NIGHTLY / on-demand — NEVER per-PR.
#
# For each task: build a SEALED isolated repo at the task base (the agent CANNOT retrieve the real fix — no
# descendant history, no remotes, no other branches), run the REAL loop (lib/autoloop.sh) k times, grade
# deterministically via the task's expect.sh, and append a per-trial results row. Cost comes from
# lib/telemetry.sh (the session DB) — nothing re-implemented. Feed the results to eval-report.sh / eval-ab.sh.
#
#   eval-run.sh [--k N] [--tasks DIR] [--out FILE] [--task ID] [--stub]
# --stub runs a no-op stand-in crew (applies the task's reference.patch if present) so the isolate→seal→
# grade→record pipeline is testable OFFLINE without credits; real runs omit it (needs opencode + keys).
set -uo pipefail
ACE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
K=5; TASKS="$ACE_ROOT/tests/eval/tasks"; OUT="$ACE_ROOT/.opencode/eval-results.tsv"; STUB=0; ONLY=""
while [ $# -gt 0 ]; do case "$1" in
  --k) K="${2:-5}"; shift 2 ;; --tasks) TASKS="${2:-}"; shift 2 ;; --out) OUT="${2:-}"; shift 2 ;;
  --task) ONLY="${2:-}"; shift 2 ;; --stub) STUB=1; shift ;; *) shift ;; esac; done
mkdir -p "$(dirname "$OUT")"
printf 'task_id\ttrial\tpass\tkind\tcost\twall\tmutant_survived\n' > "$OUT"

# a SEALED fresh repo containing ONLY the task's base tree (git archive of the base commit, or an embedded
# tree/ for self-contained tasks). No descendants, no remotes → the crew can't retrieve the answer.
seal_repo(){ # <taskdir> <destdir>
  local td="$1" d="$2"; mkdir -p "$d"
  if [ -s "$td/base" ] && git -C "$ACE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$ACE_ROOT" archive "$(cat "$td/base")" 2>/dev/null | tar -x -C "$d" 2>/dev/null
  fi
  [ -d "$td/tree" ] && cp -r "$td/tree/." "$d/" 2>/dev/null   # embedded fixture tree (self-contained tasks)
  ( cd "$d" && git init -q -b main && git add -A \
      && git -c user.email=eval@ace -c user.name=eval-harness commit -qm base ) 2>/dev/null
}

run_crew(){ # <workdir> <taskdir>
  local d="$1" td="$2"
  if [ "$STUB" = 1 ] || ! command -v opencode >/dev/null 2>&1; then
    [ -f "$td/reference.patch" ] && ( cd "$d" && git apply "$td/reference.patch" 2>/dev/null || patch -p1 <"$td/reference.patch" >/dev/null 2>&1 || true )
    return 0
  fi
  cp "$td/task.md" "$d/ROADMAP.md" 2>/dev/null || true
  ( cd "$d" && MAX_FEATURES=1 AUTOMERGE=0 DEPLOY=0 PLAN=1 GENERATE_IDEAS=0 \
       timeout "${EVAL_TASK_TIMEOUT:-1800}" bash "$ACE_ROOT/lib/autoloop.sh" >/dev/null 2>&1 || true )
}

cost_since(){ # <workdir> <since_epoch>  — reuse telemetry; never re-implement cost accounting
  # shellcheck source=/dev/null
  . "$ACE_ROOT/lib/telemetry.sh" 2>/dev/null || { echo 0; return; }
  local v   # pull the $ amount from the report's **TOTAL** row (rightmost = cost); empty offline → 0
  v="$(_telemetry_render "$(( ${2:-0} * 1000 ))" "$1" eval agent 2>/dev/null \
        | grep -F '**TOTAL**' | grep -oE '\$[0-9]+\.[0-9]+' | tail -1 | tr -d '$')"
  echo "${v:-0}"
}

ran=0
for td in "$TASKS"/*/; do
  [ -d "$td" ] || continue
  id="$(basename "$td")"; [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
  [ -f "$td/expect.sh" ] || { echo "skip $id (no expect.sh grader)"; continue; }
  kind="$(sed -n 's/^kind:[[:space:]]*//p' "$td/task.md" 2>/dev/null | head -1)"; kind="${kind:-replay}"
  for k in $(seq 1 "$K"); do
    d="$(mktemp -d)"; t0="$(date +%s)"
    seal_repo "$td" "$d"
    run_crew "$d" "$td"
    wall=$(( $(date +%s) - t0 ))
    if grade="$(cd "$d" && bash "$td/expect.sh" 2>&1)"; then p=1; else p=0; fi
    ms=-; [ "$kind" = mutant ] && { printf '%s' "$grade" | grep -qi survived && ms=1 || ms=0; }
    c="$(cost_since "$d" "$t0")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$k" "$p" "$kind" "${c:-0}" "$wall" "$ms" >> "$OUT"
    rm -rf "$d"
  done
  echo "ran $id (kind=$kind, k=$K)"; ran=$((ran+1))
done
[ "$ran" -gt 0 ] || { echo "eval-run: no tasks in $TASKS (each needs task.md + expect.sh [+ base|tree/ + reference.patch])"; exit 1; }
echo "eval-run: $ran task(s) → $OUT  ·  now: tests/eval-report.sh $OUT"
