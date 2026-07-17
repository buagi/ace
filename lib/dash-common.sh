#!/usr/bin/env bash
# dash-common.sh — shared dashboard telemetry, used by BOTH the solo loop dash (dash.sh) and the swarm cockpit
# (swarm-dash.sh) so a run is NAMED identically in either surface. This is the "one flow" reflected in the UI:
# the two renderers stay (in-place solo vs worktree swarm), but the phase-inference + agent roster are one.
#
# dash_phase_from_log <logfile> → "human label<TAB>phasekey"
#   phasekey ∈ preflight|research|spec|specgate|plan|implement|verify|review|merge|paused|idle
#   Covers the FULL loop lifecycle: preflight → research → spec → spec-gate → plan → implement → verify →
#   review → merge. Keyword-matched from the log tail, most-specific / most-recent phase first. Best-effort +
#   never-blank: an unrecognized tail returns "working…". The gate/plan phases key on the loop's OWN
#   deterministic echoes (reliable); research/spec/work phases enrich from opencode's stream.
_DASH_ESC="$(printf '\033')"
dash_phase_from_log(){
  local lf="$1" l
  [ -f "$lf" ] || { printf 'idle\tidle'; return; }
  l="$(grep -avE 'jq:|parse error|Cannot index' "$lf" 2>/dev/null | grep -vE '^[[:space:]]*$' \
        | tail -n 40 | sed "s/${_DASH_ESC}\\[[0-9;:]*m//g" | tr 'A-Z' 'a-z')"
  case "$l" in
    *"usage limit"*|*"waiting for reset"*|*"limit — waiting"*|*"limit hasn't reset"*) printf '%s\t%s' "paused — overseer hit a usage limit; resumes automatically on reset" paused ;;
    *"loop ended"*|*"nothing to merge"*|*" merged"*|*"gh pr merge"*|*"merge (squash)"*|*"✔ merged"*) printf '%s\t%s' "merging — landing the PR + syncing main" merge ;;
    *"conflicting"*|*"conflict_resolver"*|*"conflict-resolver"*|*"resolve conflicts"*) printf '%s\t%s' "resolving a merge conflict — preserving both sides' intent" review ;;
    *"alignment"*|*"standards"*|*"ux_review"*|*"ux review"*|*"reviewer"*|*"approve"*|*"changes_requested"*) printf '%s\t%s' "reviewing — critics judging logic · scope · standards · mission" review ;;
    *"container gate"*|*"ci.sh"*|*"verifier"*|*"verifying"*) printf '%s\t%s' "verifying — running the ci.sh gate" verify ;;
    *"re-spec"*|*"spec-lint found"*|*"spec gap"*|*"spec-gate"*|*"spec-rubric"*) printf '%s\t%s' "spec-gate — linting + repairing the feature specs before any code is written" specgate ;;
    *"plan-lint"*|*"re-slic"*|*"colliding"*|*"oversize"*) printf '%s\t%s' "plan-gate — re-slicing colliding/oversized tasks so workers stay path-disjoint" specgate ;;
    *"webfetch"*|*"firecrawl"*|*"researching"*|*"research pass"*|*"comparable product"*|*"prior art"*|*"industry-standard"*) printf '%s\t%s' "researching — studying how comparable products build this before speccing" research ;;
    *"writing spec"*|*"opencode/specs"*|*"filling the template"*|*"spec-template"*) printf '%s\t%s' "speccing — writing the feature spec (scope · acceptance criteria · integration)" spec ;;
    *"test_engineer"*|*"test-engineer"*|*"adversarial test"*) printf '%s\t%s' "testing — authoring independent adversarial tests" implement ;;
    *"implementer"*|*"implement:"*|*"implementing"*) printf '%s\t%s' "implementing — building the increment to spec (tests included)" implement ;;
    *"syncing objectives"*|*"→ roadmap"*|*"read objectives"*|*"read roadmap"*|*"planning"*|*"chore/plan"*|*"plan:"*) printf '%s\t%s' "planning — decomposing OBJECTIVES into ROADMAP tasks (research → spec → tasks)" plan ;;
    *"preflight"*|*"consistency"*|*"reconcil"*) printf '%s\t%s' "preflight — reconciling repo state (git · gitnexus · opencode)" preflight ;;
    *) printf '%s\t%s' "working…" idle ;;
  esac
}

# Canonical agent roster (id|name|role|icon) — the 11 opencode agents in pipeline order. ONE source of truth
# for both dashes' agent grids so neither drifts from the generated config again (researcher #11 + the launch
# gate were missing from the solo grid before this). The `id` matches the keys agent_state() writes.
DASH_AGENTS=(
  "orchestrator|orchestrator|plans · delegates|✦"
  "researcher|researcher|research · spec draft|🔎"
  "implementer|implementer|builds to spec|▸"
  "test_engineer|test engineer|adversarial tests|▽"
  "verifier|verifier|ci.sh gate|✓"
  "reviewer|reviewer|logic & scope|▸"
  "ux_reviewer|ux reviewer|looks & flow|▸"
  "standards|standards|best practices|▸"
  "alignment|alignment|mission audit|▸"
  "conflict|conflict|merge reconciler|⚔"
  "launch|launch-readiness|go / no-go gate|⚑"
)
