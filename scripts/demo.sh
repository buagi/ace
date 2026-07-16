#!/usr/bin/env bash
# ace demo — a paced, ZERO-CREDIT walkthrough of ACE's features, made for recording a demo video.
# Nothing is built, pushed, deployed, or spent: every step uses --dry-run / --explain / --demo / the DRY swarm
# sandbox / read-only status, or a throwaway demo repo this script creates and deletes. No API keys required.
#
#   ace demo                # normal pace, press ↵ between steps
#   DEMO_AUTO=1 ace demo    # hands-free (auto-advances) — what you record
#   DEMO_SPEED=slow|fast    # typing + pause speed
#   DEMO_SECTIONS=atlas,swarm ace demo   # only these sections (default: all)
#
# Record it (see docs/demo/RECORDING.md): asciinema rec → agg (gif) or svg-term, or `freeze`/`ansitoimg`.
set -uo pipefail

ACE="${ACE_BIN:-ace}"; command -v "$ACE" >/dev/null 2>&1 || ACE="$(dirname "$(readlink -f "$0")")/../ace"
SPEED="${DEMO_SPEED:-normal}"; AUTO="${DEMO_AUTO:-0}"
case "$SPEED" in slow) TYPE=0.045; PAUSE=3.0;; fast) TYPE=0.008; PAUSE=0.9;; *) TYPE=0.02; PAUSE=1.6;; esac
WANT="${DEMO_SECTIONS:-intro,status,scaffold,atlas,graph,policy,loop,swarm,stats,deploy,outro}"

# ---- pacing + presentation helpers ------------------------------------------------------------------
c(){ printf '\033[%sm' "$1"; }; R="$(c 0)"; VIOLET='1;38;5;170'; RUNE='38;5;99'; GREEN='38;5;114'; DIM='2;37'
want(){ case ",$WANT," in *",$1,"*) return 0;; *) return 1;; esac; }
hr(){ printf '%s%s%s\n' "$(c "$RUNE")" '──────────────────────────────────────────────────────────────' "$R"; }
title(){ clear 2>/dev/null || true; printf '\n%s  ⛧ %s%s\n' "$(c "$VIOLET")" "$*" "$R"; hr; printf '\n'; }
say(){ printf '   %s%s%s\n' "$(c "$DIM")" "$*" "$R"; }
pause(){ if [ "$AUTO" = 1 ]; then sleep "$PAUSE"; else printf '\n   %s… press ↵ to continue (q to quit)%s ' "$(c "$DIM")" "$R"
  local k; read -r k </dev/tty 2>/dev/null || { sleep "$PAUSE"; return; }; [ "$k" = q ] && { printf '\n'; exit 0; }; fi; }
run(){ # type the command out, then run it (errors are demo-safe)
  printf '   %s$%s ' "$(c "$GREEN")" "$R"; local i
  for ((i=0; i<${#1}; i++)); do printf '%s' "${1:$i:1}"; sleep "$TYPE"; done; printf '\n\n'
  ( eval "$1" ) 2>&1 | sed 's/^/   /' || true; }

# ---- a throwaway demo repo (so atlas/graph/loop have something real to show) -------------------------
DEMO_DIR=""
make_demo_repo(){
  DEMO_DIR="$(mktemp -d)/acedemo"; mkdir -p "$DEMO_DIR"/{apps,packages,services}/x 2>/dev/null
  ( cd "$DEMO_DIR" && git init -q && git config user.email demo@ace && git config user.name ace-demo
    printf '{"name":"acedemo","private":true,"workspaces":["apps/*","packages/*","services/*"]}\n' > package.json
    printf 'packages:\n  - "apps/*"\n  - "packages/*"\n  - "services/*"\n' > pnpm-workspace.yaml
    mkdir -p apps/web packages/core packages/ui services/api
    printf '{"name":"@acedemo/core"}\n'                                             > packages/core/package.json
    printf '{"name":"@acedemo/ui","dependencies":{"@acedemo/core":"*"}}\n'          > packages/ui/package.json
    printf '{"name":"@acedemo/api","dependencies":{"@acedemo/core":"*"}}\n'         > services/api/package.json
    printf '{"name":"@acedemo/web","dependencies":{"@acedemo/core":"*","@acedemo/ui":"*","@acedemo/api":"*"}}\n' > apps/web/package.json
    printf 'export const x=1\n' > packages/core/index.ts; printf "import '@acedemo/core'\n" > apps/web/index.ts
    printf '# acedemo\n\ndemo project for the ACE feature tour.\n' > README.md
    printf '# Roadmap\n- [x] scaffold core\n- [ ] add auth (Files: apps/web/auth.ts)\n- [ ] add billing (Files: services/api/billing.ts)\n' > ROADMAP.md
    git add -A && git commit -q -m "demo scaffold"       # commit FIRST so the atlas generator (git ls-files) sees the workspaces
    "$ACE" atlas >/dev/null 2>&1 || true                  # now generate the real dep-graph atlas
    git add -A && git commit -q -m "atlas" >/dev/null 2>&1 || true ) 2>/dev/null || true
}
cleanup(){ [ -n "$DEMO_DIR" ] && rm -rf "$(dirname "$DEMO_DIR")" 2>/dev/null; }
trap cleanup EXIT INT TERM

# =====================================================================================================
want intro && { title "ACE — the autonomous coding rig"
  say "A zero-credit tour: nothing is built, pushed, deployed, or spent."
  say "Everything here is --dry-run / --demo / a DRY sandbox / read-only."
  run "$ACE --version"; pause; }

want status && { title "1 · The rig — health at a glance"
  say "Host tools, keys, providers, GitHub, VPS, the 10-agent crew."
  run "$ACE status"; pause; }

want scaffold && { title "2 · Scaffold — a full project, previewed (nothing written)"
  say "ACE generates CI, the container gate, git hooks, the profile, the loop wiring."
  run "$ACE scaffold --name acedemo --stack node --yes --dry-run"; pause; }

if want atlas || want graph || want policy || want loop; then make_demo_repo; cd "$DEMO_DIR" 2>/dev/null || true; fi

want atlas && { title "3 · Architecture Atlas — the real dependency graph (deterministic, \$0)"
  say "ace atlas maps every workspace + its real internal deps — no LLM."
  run "sed -n '/## System map/,/## Data flow/p' docs/atlas.md 2>/dev/null | head -30"
  say "…rendered as a Mermaid diagram on the repo's README + docs/atlas.md."; pause; }

want graph && { title "4 · Code map — GitNexus + Serena (agent-facing)"
  if command -v npx >/dev/null 2>&1; then run "$ACE graph 2>&1 | tail -8"
  else say "(skipped — npx not installed; ace graph builds the GitNexus code graph)"; fi; pause; }

want policy && { title "5 · Delivery policy — resolved, no run"
  say "merge_gate · auto_merge · deploy_kind · caps — exactly how the loop will behave."
  run "$ACE autorun --explain 2>&1 | head -20"; pause; }

want loop && { title "6 · The autonomous loop — the live dashboard (scripted preview)"
  say "PLAN → BUILD → GATE → REVIEW → MERGE across the 10-agent crew."
  say "This is 'ace loop dash --demo' — a scripted cycle, not a live run."
  DEMO_AUTO=1 timeout 14 "$ACE" loop dash --demo 2>/dev/null || true; pause; }

cd / 2>/dev/null || true
want swarm && { title "7 · The swarm — N parallel workers, a DRY sandbox (\$0)"
  say "Path-disjoint leasing, worktrees, the serialized merge queue, the RED-main breaker —"
  say "all exercised with SIMULATED edits. Zero credits."
  run "timeout 60 $ACE swarm sandbox 2>&1 | tail -18"; pause; }

want stats && { title "8 · Swarm telemetry — outcomes + parallelism ceiling"
  say "Truthful per-run tally (merged/conflict/gate-red/…) + the disjoint plan."
  run "$ACE swarm stats 2>&1 | head -8 || true"
  say "(and 'ace swarm dash' is the live cockpit during a real run.)"; pause; }

want deploy && { title "9 · Deploy — VPS readiness, read-only"
  run "$ACE vps check 2>&1 | tail -12 || $ACE deploy --dry-run 2>&1 | tail -8"; pause; }

want outro && { title "That's ACE"
  say "Scaffold → autonomous loop → parallel swarm → deploy — hands-off, gate-guarded."
  say "Try it free:  ace loop dash --demo  ·  ace swarm sandbox  ·  --dry-run on anything."
  hr; }
