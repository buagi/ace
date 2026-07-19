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

usage(){ echo "usage: eval-run.sh [--k N] [--tasks DIR] [--out FILE] [--task ID] [--stub]" >&2; }
# EVERY value-taking flag must be guarded. With $#=1 (a TRAILING `--k`) a bare `shift 2` shifts NOTHING and
# just returns 1 — and this script has no `set -e`, so the while loop spins on the same argument FOREVER.
# Rejecting a missing value (or a value that is itself a flag) is what turns that hang into a usage error.
need(){ # <flagname> [candidate-value]
  [ "$#" -ge 2 ] && [ -n "${2:-}" ] && case "$2" in --*) false ;; *) true ;; esac \
    || { echo "eval-run: $1 requires a value" >&2; usage; exit 1; }
}
while [ $# -gt 0 ]; do case "$1" in
  --k)     need --k     "${2:-}"; K="$2";     shift 2 ;;
  --tasks) need --tasks "${2:-}"; TASKS="$2"; shift 2 ;;
  --out)   need --out   "${2:-}"; OUT="$2";   shift 2 ;;
  --task)  need --task  "${2:-}"; ONLY="$2";  shift 2 ;;
  --stub)  STUB=1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) shift ;;
esac; done
case "$K" in ''|*[!0-9]*) echo "eval-run: --k must be a positive integer (got '$K')" >&2; exit 1 ;; esac
[ "$K" -ge 1 ] || { echo "eval-run: --k must be >= 1 (got '$K')" >&2; exit 1; }

# A REAL run needs the crew. Degrading to the stub here would apply each task's reference.patch and record a
# meaningless 100% pass rate that is indistinguishable, in the TSV, from a genuinely perfect crew. Refuse.
if [ "$STUB" = 1 ]; then MODE=stub; else
  MODE=real
  command -v opencode >/dev/null 2>&1 || {
    echo "eval-run: REFUSING to run — 'opencode' is not on PATH and this is not a --stub run." >&2
    echo "  Install opencode (+ provider keys) for a real measurement, or pass --stub for the OFFLINE" >&2
    echo "  plumbing check — stub rows are marked mode=stub and are NOT a measurement." >&2
    exit 1
  }
fi

# Resolve BEFORE anything chdirs: each trial runs from a mktemp workdir, and a RELATIVE --tasks would then
# dereference to a non-existent path — every expect.sh would fail to load and score as a legitimate 0% pass.
_tasks_abs="$(cd "$TASKS" 2>/dev/null && pwd)" \
  || { echo "eval-run: --tasks directory not found: $TASKS" >&2; exit 1; }
TASKS="$_tasks_abs"
mkdir -p "$(dirname "$OUT")" || { echo "eval-run: cannot create output directory for $OUT" >&2; exit 1; }
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
# `mode` (col 8) is appended, not inserted, so existing 7-column readers keep working. It is what lets
# eval-report.sh / eval-ab.sh refuse to hand a verdict to stub data.
printf 'task_id\ttrial\tpass\tkind\tcost_usd\twall\tmutant_survived\tmode\n' > "$OUT"

# a SEALED fresh repo containing ONLY the task's base tree (git archive of the base commit, or an embedded
# tree/ for self-contained tasks). No descendants, no remotes → the crew can't retrieve the answer.
# Returns non-zero when the seal cannot be built. That MUST abort the run rather than proceed: an empty or
# half-populated workdir fails expect.sh exactly like a crew that couldn't solve the task, so a broken fixture
# would be silently recorded as a legitimate task failure and quietly drag the measured pass rate down.
seal_repo(){ # <taskdir> <destdir>
  local td="$1" d="$2" id base sha n; id="$(basename "$td")"; mkdir -p "$d"
  if [ -s "$td/base" ]; then
    base="$(tr -d '[:space:]' < "$td/base")"
    git -C "$ACE_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
      || { echo "eval-run: task $id declares base '$base' but $ACE_ROOT is not a git repo" >&2; return 1; }
    # resolve FIRST: `git archive <unresolvable>` writes nothing and, piped into tar, loses its exit status
    sha="$(git -C "$ACE_ROOT" rev-parse --verify --quiet "${base}^{commit}")" \
      || { echo "eval-run: task $id base '$base' does not resolve to a commit in $ACE_ROOT" >&2; return 1; }
    git -C "$ACE_ROOT" archive "$sha" | tar -x -C "$d" \
      || { echo "eval-run: task $id — git archive/extract of $sha failed" >&2; return 1; }
  fi
  if [ -d "$td/tree" ]; then                                  # embedded fixture tree (self-contained tasks)
    cp -r "$td/tree/." "$d/" || { echo "eval-run: task $id — copying tree/ fixture failed" >&2; return 1; }
  fi
  ( cd "$d" && git init -q -b main && git add -A \
      && git -c user.email=eval@ace -c user.name=eval-harness commit -qm base ) >/dev/null 2>&1 \
    || { echo "eval-run: task $id — could not commit the sealed base" >&2; return 1; }
  # VERIFY the seal: a task with neither a resolvable base nor a tree/ yields an EMPTY repo.
  n="$(cd "$d" && git ls-files | wc -l)"
  [ "${n:-0}" -gt 0 ] || { echo "eval-run: task $id — sealed repo is EMPTY (no base/ tree/ content)" >&2; return 1; }
  return 0
}

run_crew(){ # <workdir> <taskdir>
  local d="$1" td="$2"
  # STUB ONLY. `opencode` missing is handled up front as a refusal — it must NEVER silently land here.
  if [ "$STUB" = 1 ]; then
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
    seal_repo "$td" "$d" || { rm -rf "$d"; echo "eval-run: ABORTING — cannot seal $id (see above). A broken fixture would be graded as a task failure, which is a LIE about the crew."; exit 1; }
    run_crew "$d" "$td"
    wall=$(( $(date +%s) - t0 ))
    if grade="$(cd "$d" && bash "$td/expect.sh" 2>&1)"; then p=1; else p=0; fi
    ms=-; [ "$kind" = mutant ] && { printf '%s' "$grade" | grep -qi survived && ms=1 || ms=0; }
    c="$(cost_since "$d" "$t0")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$k" "$p" "$kind" "${c:-0}" "$wall" "$ms" "$MODE" >> "$OUT"
    rm -rf "$d"
  done
  echo "ran $id (kind=$kind, k=$K)"; ran=$((ran+1))
done
[ "$ran" -gt 0 ] || { echo "eval-run: no tasks in $TASKS (each needs task.md + expect.sh [+ base|tree/ + reference.patch])"; exit 1; }
[ "$MODE" = stub ] && echo "eval-run: ⚠ STUB run — every row is mode=stub. This is a PLUMBING check, NOT a measurement."
echo "eval-run: $ran task(s) [mode=$MODE] → $OUT  ·  now: tests/eval-report.sh $OUT"
