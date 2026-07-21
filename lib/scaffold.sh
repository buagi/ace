#!/usr/bin/env bash
# scaffold.sh — create a new project wired into the agentic loop (per stack).

pin_image() {  # pin_image <tag>  -> "<tag>@sha256:…" if engine can pull, else "<tag>"
  local tag="$1" eng dg; eng="$(container_engine)"
  if [ -n "$eng" ] && [ "$ACE_DRY_RUN" != 1 ]; then
    $eng pull "$tag" >/dev/null 2>&1 && dg="$($eng inspect --format '{{index .RepoDigests 0}}' "$tag" 2>/dev/null)"
    [ -n "${dg:-}" ] && { echo "$dg"; return; }
  fi
  echo "$tag"
}

# ---------------------------------------------------------------- stack registry (single source of truth)
# TO ADD A STACK, touch only these places:
#   1. this table — add to STACK_ORDER (menu order) + STACK_LABEL/HINT/GEN/DEPLOY;
#   2. write gen_<name> (skeleton + ci.sh + Containerfile/build file + gen_project_agents);
#   3. gen_ci_workflow — add a build-test + security case (and a deploy health path if it serves HTTP);
#   4. only if it deploys unusually — a branch in gen_deploy_artifacts (else 'service' reuses the default).
# The menu, dispatch, and the shared CI jobs (codemap + deploy + release) are all driven from here.
STACK_ORDER="node python config go"
declare -A STACK_LABEL=( [node]="Node / TypeScript" [python]="Python" [config]="Config only" [go]="Go" )
declare -A STACK_HINT=(
  [node]="pnpm + turbo monorepo, vitest, tiered ci"
  [python]="pytest, tiered ci"
  [config]="hooks + AGENTS + ci template, no app code"
  [go]="net/http API, static binary, container ci"
)
declare -A STACK_GEN=( [node]="gen_node" [python]="gen_python" [config]="gen_configonly" [go]="gen_go" )
declare -A STACK_DEPLOY=( [node]="service" [python]="service" [config]="none" [go]="service" )  # service|artifact|none
ACE_GO_VERSION="${ACE_GO_VERSION:-1.23}"   # single source for Go: seeds go.mod + Containerfile; CI + release.sh read go.mod

# The architecture-decision wizard (git / ci_cd / merge_gate / shape / …) runs in scaffold_project
# for ALL code stacks (node, python, go) before the skeleton generator — not just Go. See scaffold_project.

# `ace stack` — list the registered stacks, or print the template to add a new one.
stack_list() {
  step "Registered stacks (lib/scaffold.sh registry)"
  local s
  for s in $STACK_ORDER; do printf '  %-8s %-26s gen=%-16s deploy=%s\n' "$s" "${STACK_LABEL[$s]}" "${STACK_GEN[$s]}" "${STACK_DEPLOY[$s]}"; done
  info "Add one with: ace stack add <name>   (full guide: docs/stacks.md)"
}
stack_add() {
  local n="${1:-}"; [ -n "$n" ] || { err "usage: ace stack add <name>   (e.g. rust)"; return 1; }
  [ -n "${STACK_GEN[$n]:-}" ] && { warn "stack '$n' is already registered."; return 1; }
  step "Add a '$n' stack — 4 steps (paste into lib/scaffold.sh)"
  box "1) Registry — the STACK_* table near scaffold_project" \
    "   STACK_ORDER=\"$STACK_ORDER $n\"" \
    "   STACK_LABEL[$n]=\"$n\";  STACK_HINT[$n]=\"<one-line menu hint>\"" \
    "   STACK_GEN[$n]=\"gen_$n\";  STACK_DEPLOY[$n]=\"service\"   # service | artifact | none"
  cat <<EOF

2) The generator — add and fill in:

gen_$n() {
  local name="\$1"
  # write: .gitignore, .env.example, the project skeleton, and a multi-stage Containerfile with a
  # 'test' target. Then a tiered ci.sh: fast host gate + './ci.sh --container' (podman build
  # --target test), including the no-stubs depth gate for this language's file extension. End with:
  gen_project_agents "\$name" "<one-line stack description>"
}

3) CI — in gen_ci_workflow add a case arm, and a build-test + security block in
   _ci_build_security_jobs. The shared codemap / deploy / release jobs are reused — don't touch them.
   If it serves HTTP, set its deploy health path; else leave it empty (liveness-only).

     $n) hpath='/healthz' ;;   # or: install='…'; build='…'; test='…'; typecheck='…'

4) (Optional) a branch in gen_deploy_artifacts only if it deploys unusually (the 'service' default
   builds the final image and runs it).

Then: tests/snapshot-generators.sh --update   (locks the new output in)
Full guide: docs/stacks.md
EOF
}

scaffold_project() {
  step "Scaffold a new project"
  unset PROFILE_SHAPE PROFILE_GIT PROFILE_CI_CD PROFILE_GITFLOW PROFILE_CONTAINER   # the wizard/flags set these
  # headless seeds: flags (--shape/--ci/--gitflow/--no-git/--no-container) pre-fill the profile
  [ -n "${ACE_SHAPE:-}" ]     && { PROFILE_SHAPE="$ACE_SHAPE"; export PROFILE_SHAPE; }
  [ -n "${ACE_CI:-}" ]        && { PROFILE_CI_CD="$ACE_CI"; export PROFILE_CI_CD; }
  [ -n "${ACE_GITFLOW:-}" ]   && { PROFILE_GITFLOW="$ACE_GITFLOW"; export PROFILE_GITFLOW; }
  [ -n "${ACE_GIT:-}" ]       && { PROFILE_GIT="$ACE_GIT"; export PROFILE_GIT; }
  [ -n "${ACE_CONTAINER:-}" ] && { PROFILE_CONTAINER="$ACE_CONTAINER"; export PROFILE_CONTAINER; }
  # coherence: no git ⇒ nothing to push to ⇒ no remote CI, no gitflow, no VPS deploy, no publish
  if [ "${PROFILE_GIT:-true}" = false ]; then
    PROFILE_CI_CD=none; PROFILE_GITFLOW=false; ACE_DEPLOY=none; ACE_PUBLISH=0
    export PROFILE_CI_CD PROFILE_GITFLOW ACE_DEPLOY ACE_PUBLISH
  fi
  local parent base="${ACE_PROJECTS_DIR:-$HOME/projects}"
  if [ -n "${ACE_PARENT:-}" ]; then parent="${ACE_PARENT/#\~/$HOME}"
  else
    ask_path "Install location — parent directory (Tab-completes)" "$base"; parent="$ASK_REPLY"
    # Anchor under the default base unless the user gave a USABLE absolute path (a home path, or an
    # existing writable dir). A relative entry — or an absolute path at an unwritable root like '/test-7'
    # (the common typo on an immutable OS where '/' is read-only) — lands UNDER the shown default instead
    # of at '/'. So "create here unless a real full path is typed."
    case "$parent" in
      "$HOME"|"$HOME"/*) : ;;
      /*) if [ -d "$parent" ] && [ -w "$parent" ]; then :; else info "not a writable path — placing under $base"; parent="$base/${parent#/}"; fi ;;
      *)  parent="$base/$parent"; info "relative path — placing under $base" ;;
    esac
  fi
  local name
  if [ -n "${ACE_NAME:-}" ]; then name="$ACE_NAME"
  else ask "Project name (slug)" "my-app"; name="$ASK_REPLY"; fi
  local dir="$parent/$name"
  box "Project will be created at" "  $dir"
  confirm "Use this path?" Y || { ask_path "Full project path" "$dir"; dir="$ASK_REPLY"; name="$(basename "$dir")"; }
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    confirm "$dir exists and is non-empty. Continue anyway?" N || { warn "Aborted."; return; }
  fi
  # Create the dir NOW and ABORT clearly if it fails — e.g. the parent is read-only (an absolute path at
  # '/' on an immutable/atomic OS) or not writable. Otherwise the old flow continued to the stack menu and
  # only died later at `cd`, which looked like a crash for what is really a bad/unwritable path.
  if ! run mkdir -p "$dir"; then
    err "can't create $dir — read-only filesystem or no write permission there."
    case "$dir" in
      "$HOME"/*) say "  Check permissions / free space, then re-run." ;;
      *)         say "  That path is outside your home; on this OS '/' is read-only. Use a path under \$HOME, e.g. ${C_BOLD}$base/$name${C_RESET}, then re-run." ;;
    esac
    return 1
  fi
  local stack
  if [ -n "${ACE_STACK:-}" ]; then
    case " $STACK_ORDER " in *" $ACE_STACK "*) stack="$ACE_STACK" ;; *) err "unknown --stack '$ACE_STACK' (have: $STACK_ORDER)"; return 1 ;; esac
  else
    local _opts=() s
    for s in $STACK_ORDER; do _opts+=("${STACK_LABEL[$s]}::${STACK_HINT[$s]}"); done
    menu "Stack" "${_opts[@]}" || return 1
    stack="$(printf '%s\n' $STACK_ORDER | sed -n "${MENU_CHOICE}p")"
  fi
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would scaffold a '$stack' project at $dir"; return; }

  cd "$dir" || { err "cannot cd $dir"; return 1; }
  # Architecture-decision wizard (git / ci_cd / merge_gate / shape / audience / …) for every CODE stack —
  # writes .opencode/profile.yaml + ARCHITECTURE.md and sets the PROFILE_* globals the steps below read.
  # config-only projects aren't loop targets, so they skip it (and keep flag/default-driven PROFILE_*).
  case "$stack" in node|python|go) PROFILE_LANG="$stack" profile_wizard "$name" ;; esac   # PROFILE_LANG → the profile's `language:` (not hardcoded go)
  "${STACK_GEN[$stack]}" "$name"
  if [ "${PROFILE_CONTAINER:-true}" = false ]; then rm -f Containerfile; info "container=false → host-only gate (no Containerfile; ./ci.sh --container runs the host gate)."; fi
  gen_hooks
  gen_opencode_local "$name"
  gen_autoloop "$dir"
  if [ "${PROFILE_CI_CD:-github-actions}" != none ]; then gen_ci_workflow "$stack"; else info "ci_cd=none → skipping the GitHub Actions workflow."; fi
  # DEPLOY KIND COMES FROM THE PROFILE, not the per-stack table. profile_wizard (above, for every code
  # stack) already derived deploy_kind from `shape` and wrote it to .opencode/profile.yaml, and
  # gen_ci_workflow reads it from there. The table's node/python entries hardcode 'service', so
  # `--stack node --shape cli` used to get a "Add a VPS deploy job?" prompt for a deploy the CI workflow
  # correctly refused to emit — two readers, two answers. One reader now; the table is only the fallback
  # for stacks that never run the wizard (config), and STACK_DEPLOY stays the registry's documentation.
  local _dk; _dk="$(_prof_get deploy_kind 2>/dev/null)"; _dk="${_dk:-${STACK_DEPLOY[$stack]:-service}}"
  [ "${ACE_DEPLOY:-}" = none ] && _dk=none
  [ "${PROFILE_CONTAINER:-true}" = false ] && [ "$_dk" = service ] && { _dk=none; info "container=false → no image to deploy; VPS service deploy off (use 'ace release' for binaries)."; }
  if [ "$_dk" = service ] && confirm "Add a VPS deploy job + scripts/deploy.sh template?" Y; then gen_deploy_artifacts "$name" "$stack"
  elif [ "$_dk" = artifact ]; then info "deploy kind = artifact → ship binaries via 'ace release' (no VPS service deploy)."; fi
  import_brownfield "$dir"
  if [ "${PROFILE_GIT:-true}" = true ]; then
    if [ "${PROFILE_GITFLOW:-true}" = true ]; then git_flow_apply "$dir"
    else
      # gitflow=false: no main-guard/conventional-commit guards, but STILL activate the local ./ci.sh
      # gate (gen_hooks wrote .githooks/*; core.hooksPath is what turns them on). --no-verify on the
      # scaffold commit so the fresh repo isn't blocked by its own gate before deps exist.
      ( cd "$dir" && git init -q 2>/dev/null; [ -d .githooks ] && git config core.hooksPath .githooks; git add -A && git commit --no-verify -qm "chore: scaffold $name" ) 2>/dev/null || true
      info "gitflow=false → plain git init + local ./ci.sh gate active (no gitflow guards)."
    fi
  else info "git=false → skipping git setup."; fi
  ok "Project scaffolded at $dir"

  if _optin ACE_INDEX "Index now with GitNexus + Serena?" Y; then index_project "$stack"; fi
  if [ "${PROFILE_GIT:-true}" = true ] && _optin ACE_PUBLISH "Create a private GitHub repo + push? (needed for the autorun loop to open PRs)" Y; then publish_repo "$name"; fi
  if git remote get-url origin >/dev/null 2>&1 && vps_configured; then
    _optin ACE_WIRE_VPS "Wire CI deploy secrets + provision this repo on the VPS now?" N && { vps_wire_ci; vps_provision; }
  fi
  say ""; ok "Done. Next: ${C_BOLD}cd $dir && opencode${C_RESET}  (lands on the orchestrator)"
  # We're still cd'd inside $dir here, so the loop resolves the right root. After scaffold exits,
  # the user's SHELL is back in the original dir — `ace autorun` there fails the ci.sh gate ("no
  # loop project"). So offer to start it now, and on decline say exactly how to start it later.
  if [ "${PROFILE_GIT:-true}" != true ]; then
    # The autorun loop hard-requires git + gh (push/PR/CI), so a git=false project CAN'T run it — don't
    # offer a dead-end "start the loop?" that immediately fails delivery_preflight with "profile git=false".
    warn "git=false → the autonomous loop is disabled here (it needs git + gh for push/PR/CI)."
    say  "    Enable it later: ${C_BOLD}cd $dir && ace profile${C_RESET} (set git: true), then ${C_BOLD}ace autorun${C_RESET}."
  elif ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    # git=true but no remote (publish declined): the loop pushes a branch + opens a PR, so it needs an
    # 'origin'. Don't offer a loop that delivery_preflight will refuse for "no 'origin' remote".
    warn "no GitHub remote → the autonomous loop can't run yet (it pushes a branch + opens a PR)."
    say  "    Publish first: ${C_BOLD}cd $dir && ace publish${C_RESET}  (creates+pushes the repo; re-runnable, handles a name that already exists), then ${C_BOLD}ace autorun${C_RESET}."
  elif _optin ACE_AUTORUN_AFTER "Start the autonomous loop now?" N; then
    ( cd "$dir" && autoloop_run )
  else
    warn "To start the loop later you must be IN the project first — your shell won't move there:"
    say  "    ${C_BOLD}cd $dir && ace autorun${C_RESET}"
    say  "    or run ACE, ${C_BOLD}cd $dir${C_RESET}, then: ${C_BOLD}Run the loop → Autorun${C_RESET}"
  fi
}

# ---------------------------------------------------------------- shared files
gen_hooks() {
  mkdir -p .githooks
  cat > .githooks/pre-commit <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
echo "[pre-commit] ./ci.sh (fast gate) …"
./ci.sh || { echo "[pre-commit] BLOCKED: gate RED."; exit 1; }
# Regenerate the changelog from git history and STAGE it, so it lands INSIDE the commit (traceable)
# and is never left dirty. The in-flight commit appears in the next commit's log; `git log` always has
# the latest. (A post-commit writer can't add to the commit it just made — that's what left it dirty.)
# Skip in a swarm flow: a branch's SHORTER history would REVERT main's changelog
# entries (near-miss data loss in the 10h run); changelog is coordinator/union-owned there.
if [ -z "${SWARM_WORKER:-}" ]; then
  mkdir -p .opencode/memory
  { printf '# Change log (most recent first)\n'; git log --pretty='- %h %s'; } > .opencode/memory/changelog.md
  git add .opencode/memory/changelog.md 2>/dev/null || true
fi
EOF
  cat > .githooks/pre-push <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
# The container/VPS-parity build can take minutes on a cold cache — longer than an agent's per-command
# timeout (opencode kills bash at ~120s) — which forced --no-verify pushes that skipped the gate
# entirely. So run it with a budget and DEFER to CI (which runs the SAME gate on the PR before merge)
# when it can't finish, instead of blocking the push. A RED result still blocks. PREPUSH_TIMEOUT=0 = run to completion.
to="${PREPUSH_TIMEOUT:-100}"
echo "[pre-push] ./ci.sh --container (VPS parity; ${to}s budget, CI is the backstop) …"
if [ "$to" = 0 ]; then
  ./ci.sh --container || { echo "[pre-push] BLOCKED: container gate RED."; exit 1; }
else
  timeout "$to" ./ci.sh --container; rc=$?
  if [ "$rc" = 124 ]; then echo "[pre-push] container gate over ${to}s budget — DEFERRING to CI (it runs on the PR). Push allowed."
  elif [ "$rc" != 0 ]; then echo "[pre-push] BLOCKED: container gate RED."; exit 1; fi
fi
exit 0   # reaching here = GREEN or deferred; exit explicitly so a falsy last-test never blocks a good push
EOF
  cat > .githooks/post-commit <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
# refresh the code map; loud (not silent) so staleness is visible. The changelog is handled by
# pre-commit (staged INTO the commit) — post-commit must not write tracked files or it leaves dirt.
# Skip during swarm flows: re-analysis rewrites the GitNexus stat blocks in
# AGENTS.md/CLAUDE.md every commit → churn + accidental sweep into parallel PRs.
if [ -z "${SWARM_WORKER:-}" ] && ! npx -y gitnexus@latest analyze >/tmp/gitnexus-analyze.log 2>&1; then
  echo "[post-commit] WARN: gitnexus analyze failed — code map is STALE (see /tmp/gitnexus-analyze.log)"
fi
EOF
  chmod +x .githooks/*
}

gen_opencode_local() {
  mkdir -p .opencode/memory .opencode/skill/run-ci
  # don't clobber an existing changelog (adopt/upgrade may run on a repo that already has one)
  [ -s .opencode/memory/changelog.md ] || printf '# Change log (most recent first)\n' > .opencode/memory/changelog.md
  cat > .opencode/hooks.yaml <<'EOF'
hooks:
  # After an editing burst settles, refresh the code map (GitNexus) then run the gate.
  - event: session.idle
    conditions: [hasCodeChange, isMainSession]
    actions:
      - bash: "npx -y gitnexus@latest analyze >/dev/null 2>&1 || true"
      - bash: "./ci.sh"
EOF
  cat > .opencode/skill/run-ci/SKILL.md <<'EOF'
---
name: run-ci
description: How to run the tiered verification gate. Use before committing/pushing.
---
# Run CI (tiered)
- `./ci.sh` — fast gate (tests + static + typecheck/compile). Used by pre-commit + the verifier.
- `./ci.sh --container` — full VPS-parity build in a container. Used by pre-push + CI.
Exit 0 = GREEN. Never commit/push on RED.
EOF
  ensure_graph_refresh
  ensure_atlas_refresh
  command -v gen_spec_template >/dev/null 2>&1 && gen_spec_template   # Part H/H1: the feature-spec template rides the project refresh train
}

# ---------------------------------------------------------------- Node stack
gen_node() {
  local name="$1" digest; digest="$(pin_image node:24-slim)"
  cat > .gitignore <<'EOF'
node_modules/
.next/
dist/
.turbo/
coverage/
*.tsbuildinfo
.env
.env.*
!.env.example
.DS_Store
# ── ACE loop transients — never commit (keeps `git status` clean so agents don't waste turns each step) ──
.serena/
.opencode/.agents
.opencode/.oppid
.opencode/.step-budget
.opencode/.timedout
.opencode/.rathole
.opencode/.container-green
.opencode/.harvested-warnings
.opencode/.objectives-synced
.opencode/last-run.log
.opencode/ci-failure.log
.opencode/ci-build.log
.opencode/loop-state.env
.opencode/metrics.csv
.opencode/run-summary.txt
.opencode/token-report.md
.opencode/.session-id
.opencode/.kanban-map
.opencode/approvals/
.opencode/HANDOVER.md
.opencode/vps-verify-report.md
.opencode/cache/
.opencode/reanalyze/
*.orig
*.rej
EOF
  cat > .env.example <<'EOF'
# Declared env vars (ci.sh checks process.env.X usage against this file).
NODE_ENV=development
EOF
  cat > pnpm-workspace.yaml <<'EOF'
packages:
  - "packages/*"
  - "apps/*"
# pnpm 11 wants explicit build-script decisions (booleans), not onlyBuiltDependencies.
allowBuilds:
  esbuild: true
EOF
  cat > package.json <<EOF
{
  "name": "$name",
  "private": true,
  "packageManager": "pnpm@11.7.0",
  "scripts": {
    "build": "turbo run build",
    "test": "turbo run test",
    "typecheck": "turbo run typecheck",
    "lint": "eslint ."
  },
  "devDependencies": {
    "turbo": "^2.5.0",
    "eslint": "^9.17.0",
    "@eslint/js": "^9.17.0",
    "typescript-eslint": "^8.20.0"
  }
}
EOF
  ensure_eslint   # flat config: as any / @ts-ignore / unused = HARD errors
  cat > turbo.json <<'EOF'
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**", ".next/**", "!.next/cache/**"] },
    "test": { "dependsOn": ["^build"] },
    "typecheck": {}
  }
}
EOF
  mkdir -p packages/core/src packages/core/test
  ensure_tsconfig_base   # shared base tsconfig (Bundler, strict) — packages extend it
  cat > packages/core/package.json <<EOF
{
  "name": "@$name/core",
  "version": "0.0.0",
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": { ".": "./src/index.ts" },
  "scripts": { "build": "tsc -p tsconfig.json", "test": "vitest run", "coverage": "vitest run --coverage", "typecheck": "tsc --noEmit" },
  "devDependencies": { "typescript": "^5.7.0", "vitest": "^2.1.0", "@vitest/coverage-v8": "^2.1.0" }
}
EOF
  cat > packages/core/tsconfig.json <<'EOF'
{ "extends": "../../tsconfig.base.json", "compilerOptions": { "outDir": "dist", "rootDir": "src" }, "include": ["src"], "exclude": ["dist", "node_modules", "test"] }
EOF
  printf 'export const add = (a: number, b: number): number => a + b;\n' > packages/core/src/index.ts
  cat > packages/core/test/add.test.ts <<'EOF'
import { describe, expect, it } from "vitest";
import { add } from "../src/index.js";
describe("add", () => { it("adds", () => expect(add(2, 3)).toBe(5)); });
EOF
  mkdir -p tests
  cat > tests/factories.ts <<'EOF'
// Test data factories — build domain objects with sane defaults; override per test via the argument.
// A schema change becomes a one-line edit HERE, not a sweep across every test. Replace ExampleRecord
// with your real models and add builders as you go; tests import from here instead of re-rolling setup.
export type Overrides<T> = Partial<T>;

export interface ExampleRecord {
  id: number;
  name: string;
  active: boolean;
}

export const makeRecord = (over: Overrides<ExampleRecord> = {}): ExampleRecord => ({
  id: 1,
  name: "example",
  active: true,
  ...over,
});
EOF
  cat > tests/helpers.ts <<'EOF'
// Shared test helpers — reuse instead of re-rolling setup.
//   Clock:  vi.useFakeTimers({ now: FIXED_NOW })  freezes time deterministically (vi.useRealTimers() after).
//   Golden: expect(value).toMatchSnapshot()  is vitest's built-in snapshot/golden primitive.
export const FIXED_NOW = new Date("2025-01-01T00:00:00Z");

/** Flush pending microtasks/timer callbacks — handy alongside fake timers. */
export const tick = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0));
EOF
  cat > .dockerignore <<'EOF'
node_modules
**/node_modules
.next
.turbo
dist
.git
# runtime config is injected by the deploy (--env-file), never baked into a layer
.env
.env.*
!.env.example
.serena
brownfield
EOF
  cat > Containerfile <<EOF
FROM $digest AS build
ENV CI=1
WORKDIR /app
RUN corepack enable
COPY . .
RUN pnpm install --frozen-lockfile
RUN pnpm build
FROM build AS test
RUN pnpm test
# --- runtime image (used only by 'ace deploy' for a service; the ./ci.sh gate builds --target test) ---
FROM build AS final
ENV NODE_ENV=production
EXPOSE 3000
# EDIT: your service's start command. This scaffold is a monorepo — add a root "start" script to
# package.json that runs your built app (e.g. "start": "node apps/server/dist/index.js").
CMD ["pnpm", "start"]
EOF
  cat > ci.sh <<'EOF'
#!/usr/bin/env bash
# Tiered: ./ci.sh = fast host gate; ./ci.sh --container = full VPS parity.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
MODE="fast"; { [ "${1:-}" = "--container" ] || [ "${CONTAINER:-}" = "1" ]; } && MODE="container"
[ "${1:-}" = "--launch" ] && MODE="launch"   # pre-promotion launch-readiness gate (see the launch_readiness_reviewer agent)
[ "$MODE" = container ] && [ ! -f Containerfile ] && { echo "[ci] no Containerfile — running the host gate."; MODE="fast"; }
# keep CI output as SIGNAL: silence tool update-notifier banners (Prisma / npm / generic update-notifier)
export PRISMA_HIDE_UPDATE_MESSAGE=1 CHECKPOINT_DISABLE=1 NO_UPDATE_NOTIFIER=1 npm_config_update_notifier=false CI=1
fail=0; section(){ printf '\n== %s ==\n' "$1"; }
# ── ONE exclusion list for EVERY recursive scan in this gate ────────────────────────────────────────
# Trees this project does not own: dependency installs (node_modules/, .venv/, vendor/), build output,
# and brownfield/ — code adopted by `ace import`, which PROMISES it is "excluded from the gate". It was
# not: the RLS, migration-safety and log-hygiene sections below scanned it anyway, emitted RED [blocker]
# and set fail=1, and .githooks/pre-commit then blocked EVERY commit over somebody else's legacy code.
# Add paths HERE, never inline, so the next section added to this file cannot forget one.
EXCL='/(node_modules|dist|build|\.next|out|vendor|\.git|\.serena|\.venv|venv|brownfield)/'
# grep -r has no regex-based --exclude-dir, so these two wrappers apply $EXCL to a recursive grep:
#   xgrep_l -> the matching FILE list minus excluded paths   ·   xgrep_q -> quiet test (true iff a match)
# Both force -l so the pipe filters PATHS, and both are judged on their TEXT, never on $?: grep returns 1
# for "no match" and xargs returns 123 if any batch did, neither of which means the check failed.
xgrep_l(){ grep -rIl "$@" 2>/dev/null | grep -vE "$EXCL"; }
xgrep_q(){ xgrep_l "$@" | grep -q .; }
# STRICT security gate: an unattended PUBLIC self-merge has no human to catch a "major" security gap, so the
# security [major] warnings below become HARD BLOCKERS (the orchestrator's AUTO-ACCEPT SAFETY RAIL, made
# mechanical). ON when the profile audience is public/customer/enterprise AND auto_merge is on; force either
# way with ACE_STRICT_SECURITY=1 / =0. (Heuristic greps → a false positive blocks a merge; that is the
# fail-closed trade for shipping to real users with no reviewer. Set ACE_STRICT_SECURITY=0 to opt a run out.)
_strict=0
_paud="$(sed -n 's/^[[:space:]]*audience:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
_pam="$(sed -n 's/^[[:space:]]*auto_merge:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
case "$_paud" in oss-public|end-customer|enterprise) case "$_pam" in true|yes|1) _strict=1 ;; esac ;; esac
case "${ACE_STRICT_SECURITY:-}" in 1) _strict=1 ;; 0) _strict=0 ;; esac
_secwarn(){ if [ "$_strict" = 1 ]; then echo "RED [blocker]: $* [strict: public + auto_merge, no human reviewer]"; fail=1; else echo "WARN [major]: $*"; fi; }
if [ "$MODE" = launch ]; then
  section "Launch-readiness (mechanical pre-promotion gate — the launch_readiness_reviewer agent does the judgment)"
  # Composition-aware (like the stack-conditional gates above): only require the DB restore-drill when the
  # project HAS a database, and rollback/SLO/runbook only for a deployed service (deploy_kind=service). A
  # no-DB CLI / library is not NO-GO'd for a backup it cannot have.
  _hasdb=0
  { [ -f package.json ] && grep -qiE '"(pg|postgres|prisma|@prisma/client|drizzle-orm|mysql2?|mongoose|mongodb|better-sqlite3|sqlite3|sequelize|typeorm|knex|kysely|pg-promise|@libsql/client|@neondatabase/serverless|@planetscale/database|@vercel/postgres)"' package.json; } && _hasdb=1
  { [ -f go.mod ] && grep -qiE 'lib/pq|jackc/pgx|jackc/pgconn|go-sql-driver|mattn/go-sqlite3|modernc\.org/sqlite|glebarez/sqlite|gorm\.io|entgo\.io/ent|uptrace/bun|jmoiron/sqlx|mongo-driver' go.mod; } && _hasdb=1
  grep -qiE 'psycopg|sqlalchemy|sqlmodel|asyncpg|pymysql|mysqlclient|mariadb|aiosqlite|pymongo|django|tortoise|peewee|alembic' requirements*.txt pyproject.toml 2>/dev/null && _hasdb=1
  { ls prisma/schema.prisma migrations/*.sql db/migrations/*.sql migrations/0*.py */migrations/0*.py alembic/versions/*.py 2>/dev/null | grep -q .; } && _hasdb=1
  _svc=0; [ "$(sed -n 's/^[[:space:]]*deploy_kind:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)" = service ] && _svc=1
  if [ "$_hasdb" = 1 ]; then
    if [ -f ops/restore-drill.result ] && grep -qiE 'rows_verified=[1-9]|status=(verified|pass|ok)' ops/restore-drill.result 2>/dev/null; then echo "tested restore: recorded"; else echo "NO-GO [blocker]: ops/restore-drill.result missing or shows no verified restore (needs rows_verified / RPO / RTO) — a backup is not done until a restore has been run: ./ops/restore-drill.sh"; fail=1; fi
  else echo "no database detected — restore-drill not required"; fi
  if [ "$_svc" = 1 ]; then
    [ -f ops/rollback.md ] && echo "present: ops/rollback.md" || { echo "NO-GO [blocker]: ops/rollback.md missing — document the tested revert for the last deploy"; fail=1; }
    for a in ops/runbook.md ops/slo.md LAUNCH-READINESS.md; do [ -f "$a" ] && echo "present: $a" || echo "WARN [major]: missing $a (scaffold it; track to verified in LAUNCH-READINESS.md)"; done
  else echo "deploy_kind != service (artifact/library/none) — rollback/SLO/runbook not required"; fi
  [ "$fail" = 0 ] && { echo -e "\nLAUNCH GREEN (mechanical checks pass — now run the launch_readiness_reviewer agent for the full GO/NO-GO)"; exit 0; } || { echo -e "\nLAUNCH RED — NO-GO (fix the [blocker] artifacts above)"; exit 1; }
fi
section "[1/13] Build + test ($MODE)"
if [ "$MODE" = container ]; then
  if podman build --force-rm --target test -t localhost/ci:dev -f Containerfile .; then _rc=0; else _rc=1; fi
  podman image prune -f >/dev/null 2>&1 || true  # reclaim this build's dangling layers (prevents disk bloat)
  [ "$_rc" = 0 ] || { echo RED; exit 1; }
else
  # FAST inner gate: test only the packages AFFECTED vs origin/main (turbo --filter) for quick feedback.
  # The container/CI gate above runs the FULL suite and is the authority that gates the merge, so any
  # cross-package regression the affected set might miss is still caught before anything lands.
  # CI_SCOPE=all forces the full suite; falls back to full on main, with no origin/main, or no turbo.
  base=""; git rev-parse --verify -q origin/main >/dev/null 2>&1 && base="origin/main"
  if [ "${CI_SCOPE:-affected}" = affected ] && [ -n "$base" ] \
     && [ "$(git rev-parse HEAD 2>/dev/null)" != "$(git rev-parse "$base" 2>/dev/null)" ] \
     && pnpm exec turbo --version >/dev/null 2>&1; then
    echo "[ci] fast: tests for packages affected vs $base (CI_SCOPE=all = full suite; the --container gate always runs ALL)"
    pnpm exec turbo run test --filter="...[$base]" || fail=1
  else
    pnpm test || fail=1
  fi
  # coverage is a SIGNAL not a gate (opt-in to keep the fast path fast): COVERAGE=1 ./ci.sh runs the
  # full suite under vitest --coverage (provider: @vitest/coverage-v8). No % threshold — gaps, not numbers.
  [ "${COVERAGE:-}" = 1 ] && { echo "[ci] coverage (vitest --coverage; informational)"; pnpm -r exec vitest run --coverage || true; }
fi
section "[2/13] Env integrity — process.env vars declared in .env.example"
declared=$(grep -oP '^[A-Z0-9_]+(?==)' .env.example 2>/dev/null | sort -u)
used=$(grep -rhoP 'process\.env\.\K[A-Z0-9_]+' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' apps packages 2>/dev/null | sort -u | grep -vE '^(NODE_ENV|NEXT_|__NEXT_|VERCEL|PORT)$')
miss=$(comm -23 <(printf '%s\n' "$used"|sed '/^$/d') <(printf '%s\n' "$declared"|sed '/^$/d'))
[ -n "$miss" ] && { echo "RED: undeclared env vars:"; echo "$miss"; fail=1; }
section "[3/13] Typecheck + lint (no any / no @ts-ignore / no unused)"
pnpm -r --if-present typecheck >/tmp/ci-tc.log 2>&1 || { echo "RED: typecheck"; tail -20 /tmp/ci-tc.log; fail=1; }
pnpm lint >/tmp/ci-lint.log 2>&1 || { echo "RED: lint (any / @ts-ignore / unused)"; tail -30 /tmp/ci-lint.log; fail=1; }
section "[4/13] No stubs / placeholders (depth gate)"
stub=$(grep -rInE '(TODO|FIXME|XXX)|not[ _]implemented|NotImplementedError' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' apps packages services src 2>/dev/null | grep -vE "$EXCL" | head -20)
[ -n "$stub" ] && { echo "RED: unfinished stubs/markers — complete them (or move real notes to .opencode/specs/):"; echo "$stub"; fail=1; }
section "[5/13] Client-bundle secret scan (leaked provider/service keys)"
# Scan the BUILT client bundle only (dist/build/.next/public) for shipped provider/service keys — never
# source, never server-only .env. Add literal substrings to .ci-secretignore to suppress false positives.
csec_dirs=""; for d in dist build .next public; do [ -d "$d" ] && csec_dirs="$csec_dirs $d"; done
if [ -n "$csec_dirs" ]; then
  csec_re='sk_live_|sk_test_|service_role|SUPABASE_SERVICE_ROLE|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{20,}|OPENAI_API_KEY|ANTHROPIC_API_KEY'
  csec_hits=$(grep -rInE "$csec_re" $csec_dirs 2>/dev/null || true)
  if [ -n "$csec_hits" ] && [ -s .ci-secretignore ]; then csec_hits=$(printf '%s\n' "$csec_hits" | grep -vFf <(grep -v '^$' .ci-secretignore) || true); fi
  if [ -n "$csec_hits" ]; then echo "RED [blocker]: secret/credential shipped in client bundle — move it to server-only env:"; printf '%s\n' "$csec_hits" | head -20; fail=1; else echo "(client bundle clean)"; fi
else echo "(no client bundle dir — skipping)"; fi
section "[6/13] Row-Level Security — RLS enabled per table (Postgres/Supabase)"
# Stack-conditional: runs only when SQL migrations declare CREATE TABLE; clean no-op otherwise.
# Resolve the OWNED .sql set once through $EXCL — a brownfield/ or vendored migration is not ours to
# police, and it used to RED-block every commit here. Every lookup below reuses this one list, and it is
# ALL owned .sql (not just the CREATE TABLE files) because RLS is usually enabled in a LATER migration.
sql_all=$(find . -name '*.sql' -type f 2>/dev/null | grep -vE "$EXCL" || true)
_sqlgrep(){ printf '%s\n' "$sql_all" | tr '\n' '\0' | xargs -0 -r grep "$@" 2>/dev/null; }   # judge the OUTPUT, never xargs' rc
if [ -n "$sql_all" ] && _sqlgrep -lIE 'CREATE TABLE' | grep -q .; then
  rls_tables=$(_sqlgrep -hoIE 'CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?[A-Za-z0-9_]+' | sed -E 's/.*CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?//; s/".*//' | sort -u)
  for t in $rls_tables; do
    if ! _sqlgrep -lIE "ALTER TABLE +(public\.)?\"?${t}\"? +ENABLE ROW LEVEL SECURITY" | grep -q .; then
      echo "RED [blocker]: table '${t}' created without ENABLE ROW LEVEL SECURITY"; fail=1
    elif ! _sqlgrep -lIE "CREATE POLICY .*ON +(public\.)?\"?${t}\"?" | grep -q .; then
      _secwarn "table '${t}' has RLS enabled but no CREATE POLICY (deny-all — usually unintended)"
    fi
  done
else echo "(no SQL CREATE TABLE — skipping RLS check)"; fi
section "[7/13] LLM call-site guards (cost / abuse)"
# Stack-conditional: runs only when an LLM SDK is a dependency; heuristic [major] warnings, never a hard fail.
if grep -rIqE 'openai|anthropic|langchain|@ai-sdk|llamaindex|@google/generative-ai' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null; then
  llm_calls=$(grep -rIlE '\.chat\.completions\.create|\.messages\.create|\.completions\.create|\.responses\.create|generateText|streamText|generateObject|\.GenerateContent' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null | grep -vE "$EXCL" | head -50 || true)
  if [ -n "$llm_calls" ]; then
    printf '%s\n' "$llm_calls" | xargs grep -lIE 'max_tokens|maxOutputTokens|max_output_tokens|maxTokens' 2>/dev/null | grep -q . || _secwarn "LLM call site(s) with no visible token cap (max_tokens/maxOutputTokens) — uncapped output is a cost + DoS risk"
    xgrep_q -iE 'budget|rate.?limit|max.?iteration|max.?step|max.?turn' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . || _secwarn "no visible per-user/session budget, rate-limit, or agent max-iteration cap near LLM calls"
  else echo "(LLM SDK present but no direct call site found — skipping)"; fi
else echo "(no LLM SDK dependency — skipping)"; fi
section "[8/13] Webhook handler integrity (payment/event webhooks)"
# Stack-conditional: runs only when a MONEY webhook handler is present; clean no-op otherwise.
wh_files=$( { grep -rIliE 'webhook|constructEvent|Stripe-Signature|whsec_' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f -iname '*webhook*' 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -50 )
money_wh=""; [ -n "$wh_files" ] && money_wh=$(printf '%s\n' "$wh_files" | xargs grep -lIiE 'stripe|paypal|braintree|paddle|lemonsqueez|razorpay|payment|charge|subscription|checkout|billing' 2>/dev/null || true)
if [ -n "$money_wh" ]; then
  wh_sig='constructEvent|verifyHeader|verifySignature|Stripe-Signature|X-Hub-Signature|createHmac|compare_digest|hmac\.new|ConstructEvent|ValidateSignature|WebhookSignature'
  if printf '%s\n' "$money_wh" | xargs grep -lIE "$wh_sig" 2>/dev/null | grep -q .; then
    echo "(webhook signature verification present)"
    wh_dedupe='event[._]?id|eventId|idempotenc|processed|dedup|on conflict|already|\bseen\b'
    printf '%s\n' "$money_wh" | xargs grep -lIiE "$wh_dedupe" 2>/dev/null | grep -q . || _secwarn "money webhook has no visible event-ID dedupe (at-least-once delivery + multi-day retries can double-process)"
  else
    echo "RED [blocker]: money webhook handler with NO signature verification — forgeable 'payment succeeded':"; printf '%s\n' "$money_wh" | head -10; fail=1
  fi
else echo "(no payment webhook handler — skipping)"; fi
section "[9/13] Auth & session edge cases (reset tokens / enumeration)"
# Stack-conditional: runs only when auth routes are present; heuristic [major] warnings, never a hard fail.
auth_files=$( { grep -rIliE 'password|reset[_-]?token|forgot|sign[_-]?in|next-auth|passport|lucia|bcrypt|argon2' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f \( -iname '*auth*' -o -iname '*login*' -o -iname '*password*' \) 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -80 )
if [ -n "$auth_files" ]; then
  if printf '%s\n' "$auth_files" | xargs grep -lIiE 'no such (user|account)|(email|user|account) not found|does ?n.?t exist|no account (with|found)' 2>/dev/null | grep -q .; then
    _secwarn "an auth response reveals whether an account exists (enumeration) — return a GENERIC message for existing AND non-existing accounts"
  fi
  reset_files=$(printf '%s\n' "$auth_files" | xargs grep -lIiE 'reset[_-]?token|password[_-]?reset|forgot' 2>/dev/null || true)
  if [ -n "$reset_files" ]; then
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'hash|bcrypt|argon2|scrypt|sha256|createhash|digest' 2>/dev/null | grep -q . || _secwarn "reset token may be stored in plaintext — store only its HASH and compare hashes"
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'expir|ttl|valid[_-]?until|used|consumed|redeemed|single[_-]?use' 2>/dev/null | grep -q . || _secwarn "reset token has no visible expiry or single-use flag — make it time-limited AND single-use"
  fi
else echo "(no auth routes — skipping)"; fi
section "[10/13] Migration safety (expand-contract)"
# Stack-conditional: runs only when SQL migration files are present; clean no-op otherwise.
mig_files=$(grep -rIlE 'ALTER TABLE|DROP TABLE|DROP COLUMN|CREATE TABLE|RENAME' --include='*.sql' . 2>/dev/null | grep -vE "$EXCL" | head -80 || true)
if [ -n "$mig_files" ]; then
  while IFS= read -r mf; do [ -n "$mf" ] || continue
    if grep -IiqE 'DROP (TABLE|COLUMN)|RENAME (TO|COLUMN)|ALTER COLUMN[^;]*DROP' "$mf" 2>/dev/null; then
      grep -IiqE -e '--[[:space:]]*down\b|irreversible[^a-z]{0,4}approved|expand.?contract' "$mf" 2>/dev/null || { echo "RED [blocker]: $mf — destructive schema op (DROP/RENAME) with no reverse. Use expand-contract (add new → backfill → switch reads → drop LATER, as SEPARATE changes); if intentional, add a '-- down' reverse (a SQL comment) or an '-- irreversible: approved' marker."; fail=1; }
    fi
    if grep -IiE 'ADD COLUMN[^;]*NOT NULL' "$mf" 2>/dev/null | grep -qviE 'DEFAULT|GENERATED'; then
      echo "RED [blocker]: $mf — ADD COLUMN ... NOT NULL without a DEFAULT will fail on existing rows; add a DEFAULT or backfill in phases."; fail=1
    fi
  done <<< "$mig_files"
else echo "(no SQL migrations — skipping)"; fi
section "[11/13] Observability (structured logs, health, log hygiene)"
# Log hygiene runs on any source (a secret VALUE in a log is a [blocker]); server checks gate on a server app.
loghy=$(grep -rIinE '(console\.(log|info|warn|error|debug)|logger?\.[a-zA-Z]+|log\.(Info|Print|Printf|Debug|Error|Warn|Fatal)|logging\.(info|debug|warning|error)|print|println|fmt\.Print[a-z]*)[[:space:]]*\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null | grep -vE "${EXCL}|\.(test|spec)\." | grep -IiE '\.(password|passwd|secret|token|authorization|ssn|cvv|api[_-]?key|credit[_-]?card)\b|[$][{][^}]*(password|passwd|secret|token|ssn|cvv)|[{][[:space:]]*(password|passwd|secret|token|ssn|cvv)[[:space:]]*[,}]|[(][[:space:]]*(password|passwd|secret|token|ssn)[[:space:]]*[),]' | head -20 || true)
[ -n "$loghy" ] && { echo "RED [blocker]: a secret/PII VALUE appears in a log statement — never log passwords/tokens/secrets/PII:"; printf '%s\n' "$loghy" | head -10; fail=1; }
if xgrep_q -E '\.listen\(|createServer|app\.run\(|http\.ListenAndServe|uvicorn|FastAPI|express\(|fastify\(|gin\.(New|Default)|Flask\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' .; then
  xgrep_q -iE '/health|/healthz|/ready|/readyz|actuator/health|livenessProbe' . || echo "WARN [major]: no /health or /ready endpoint found — add liveness/readiness probes for a server app"
  grep -rIqiE 'winston|pino|bunyan|structlog|loguru|zap|logrus|zerolog|log/slog|slog\.' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null || echo "WARN [major]: no structured logger detected — use a structured logger (not raw console.log/print) in request paths"
  xgrep_q -iE 'correlation|request[_-]?id|x-request-id|traceparent|trace[_-]?id' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . || echo "WARN [major]: no request/correlation-ID found — attach one to every log line for traceability"
else echo "(not a server app — health/correlation checks skipped; log hygiene ran)"; fi
section "[12/13] Supply chain (deterministic installs, SBOM, pinned actions)"
if [ -f Containerfile ] || [ -d .github/workflows ]; then
  ndi=$(grep -rIinE '(npm|pnpm|yarn) +install' Containerfile .github/workflows 2>/dev/null | grep -viE 'npm ci|--frozen-lockfile|--ignore-scripts' | head -10 || true)
  [ -n "$ndi" ] && { echo "WARN [major]: non-deterministic install in a build — use 'npm ci' / 'pnpm i --frozen-lockfile' / 'pip install --require-hashes':"; printf '%s\n' "$ndi" | head -5; }
  fl=$(grep -rInE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@' .github/workflows 2>/dev/null | grep -vE 'uses:[[:space:]]*actions/' | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' | head -10 || true)
  [ -n "$fl" ] && { echo "WARN [major]: third-party GitHub Action pinned to a floating tag — pin by full commit SHA (uses: org/action@<40-hex-sha> # vX):"; printf '%s\n' "$fl" | head -5; }
  grep -rIqiE 'cyclonedx|spdx|sbom|syft|trivy' package.json Containerfile .github/workflows 2>/dev/null || echo "WARN [major]: no SBOM (CycloneDX/SPDX) generated — emit one as a build artifact for dependency transparency"
else echo "(no Containerfile or CI workflow — skipping supply-chain checks)"; fi
section "[13/13] New source needs tests (parity/CI tier only — never blocks the fast pre-commit)"
if [ "$MODE" = container ]; then
  base="$(git merge-base origin/main HEAD 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || true)"
  if [ -n "$base" ]; then
    newsrc=$(git diff --name-only --diff-filter=A "$base" HEAD -- apps packages services src 2>/dev/null | grep -E '\.(ts|tsx)$' | grep -vE '\.(test|spec)\.|/(test|tests|__tests__)/|\.d\.ts$|/index\.ts$' || true)
    tests=$(git diff --name-only "$base" HEAD 2>/dev/null | grep -E '\.(test|spec)\.|/(test|tests|__tests__)/' || true)
    if [ -n "$newsrc" ] && [ -z "$tests" ]; then
      echo "RED: new source added with NO test added/updated on this branch — cover it:"; printf '%s\n' "$newsrc" | head -20; fail=1
    fi
  fi
fi
[ "$fail" = 0 ] && { echo -e "\nCI GREEN ($MODE)"; exit 0; } || { echo -e "\nCI RED ($MODE)"; exit 1; }
EOF
  chmod +x ci.sh
  gen_project_agents "$name" "Node/TypeScript (pnpm + turbo), vitest. Build/test in a pinned Node container."
  if confirm "Run 'pnpm install' now (needed for the gate)?" Y; then
    have pnpm && spin "pnpm install" pnpm install || warn "pnpm not on PATH yet — open a new shell, then 'pnpm install'."
  fi
}

# ---------------------------------------------------------------- Python stack
gen_python() {
  local name="$1" digest; digest="$(pin_image python:3.13-slim)"
  cat > .gitignore <<'EOF'
__pycache__/
*.pyc
.venv/
.pytest_cache/
.env
.env.*
!.env.example
.DS_Store
# ── ACE loop transients — never commit (keeps `git status` clean so agents don't waste turns each step) ──
.serena/
.opencode/.agents
.opencode/.oppid
.opencode/.step-budget
.opencode/.timedout
.opencode/.rathole
.opencode/.container-green
.opencode/.harvested-warnings
.opencode/.objectives-synced
.opencode/last-run.log
.opencode/ci-failure.log
.opencode/ci-build.log
.opencode/loop-state.env
.opencode/metrics.csv
.opencode/run-summary.txt
.opencode/token-report.md
.opencode/.session-id
.opencode/.kanban-map
.opencode/approvals/
.opencode/HANDOVER.md
.opencode/vps-verify-report.md
.opencode/cache/
.opencode/reanalyze/
*.orig
*.rej
EOF
  # The Containerfile below does `COPY . .`, so without this the image ships .git and the whole .venv
  # (node's and go's templates already have one; python's was missing entirely).
  cat > .dockerignore <<'EOF'
.git
.venv
venv
__pycache__
**/__pycache__
*.pyc
.pytest_cache
dist
build
.serena
brownfield
# runtime config is injected by the deploy (--env-file), never baked into a layer
.env
.env.*
!.env.example
EOF
  printf '# Declared env vars (ci.sh checks os.getenv usage).\nAPP_ENV=dev\n' > .env.example
  printf 'pytest==8.3.4\npytest-cov==6.0.0\n' > requirements.txt
  mkdir -p src tests
  printf 'def add(a: int, b: int) -> int:\n    return a + b\n' > src/core.py
  printf 'import os\n\n\ndef app_env() -> str:\n    return os.getenv("APP_ENV", "dev")\n' > src/config.py
  cat > tests/test_core.py <<'EOF'
from src.core import add
from src.config import app_env


def test_add():
    assert add(2, 3) == 5


def test_env_default():
    assert app_env() == "dev"
EOF
  cat > tests/conftest.py <<'EOF'
"""Shared pytest fixtures + factories — reuse these instead of re-rolling setup in each test.

`clock` injects a deterministic 'now'; `make_record` builds a domain object with sane defaults so a
schema change is a one-line edit here, not a sweep across every test. Replace with your real models.
For golden/snapshot tests add the `syrupy` plugin and use the `snapshot` fixture.
"""

import datetime as _dt

import pytest

FIXED_NOW = _dt.datetime(2025, 1, 1, tzinfo=_dt.timezone.utc)


@pytest.fixture
def clock():
    """Deterministic 'now' — inject instead of datetime.now() so tests don't depend on wall-clock."""
    return FIXED_NOW


@pytest.fixture
def make_record():
    """Factory: build a record with sane defaults; override any field via kwargs."""

    def _make(**over):
        base = {"id": 1, "name": "example", "active": True}
        base.update(over)
        return base

    return _make
EOF
  cat > Containerfile <<EOF
FROM $digest AS build
WORKDIR /src
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
FROM build AS test
RUN python -m pytest -q
# --- runtime image (used only by 'ace deploy' for a service; the ./ci.sh gate builds --target test) ---
FROM build AS final
EXPOSE 8000
# EDIT: your service's entrypoint. This scaffold is a library — point CMD at your app/server module,
# e.g. CMD ["python", "-m", "myservice"]  or  CMD ["uvicorn", "myservice.app:app", "--host", "0.0.0.0"].
CMD ["python", "-c", "raise SystemExit('set the CMD in the Containerfile final stage to run your service')"]
EOF
  cat > ci.sh <<'EOF'
#!/usr/bin/env bash
# Tiered: ./ci.sh = fast host gate; ./ci.sh --container = full VPS parity.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
MODE="fast"; { [ "${1:-}" = "--container" ] || [ "${CONTAINER:-}" = "1" ]; } && MODE="container"
[ "${1:-}" = "--launch" ] && MODE="launch"   # pre-promotion launch-readiness gate (see the launch_readiness_reviewer agent)
[ "$MODE" = container ] && [ ! -f Containerfile ] && { echo "[ci] no Containerfile — running the host gate."; MODE="fast"; }
# keep CI output as SIGNAL: silence tool update-notifier banners (Prisma / npm / generic update-notifier)
export PRISMA_HIDE_UPDATE_MESSAGE=1 CHECKPOINT_DISABLE=1 NO_UPDATE_NOTIFIER=1 npm_config_update_notifier=false CI=1
fail=0; section(){ printf '\n== %s ==\n' "$1"; }
# ── ONE exclusion list for EVERY recursive scan in this gate ────────────────────────────────────────
# Trees this project does not own: dependency installs (node_modules/, .venv/, vendor/), build output,
# and brownfield/ — code adopted by `ace import`, which PROMISES it is "excluded from the gate". It was
# not: the RLS, migration-safety and log-hygiene sections below scanned it anyway, emitted RED [blocker]
# and set fail=1, and .githooks/pre-commit then blocked EVERY commit over somebody else's legacy code.
# Add paths HERE, never inline, so the next section added to this file cannot forget one.
EXCL='/(node_modules|dist|build|\.next|out|vendor|\.git|\.serena|\.venv|venv|brownfield)/'
# grep -r has no regex-based --exclude-dir, so these two wrappers apply $EXCL to a recursive grep:
#   xgrep_l -> the matching FILE list minus excluded paths   ·   xgrep_q -> quiet test (true iff a match)
# Both force -l so the pipe filters PATHS, and both are judged on their TEXT, never on $?: grep returns 1
# for "no match" and xargs returns 123 if any batch did, neither of which means the check failed.
xgrep_l(){ grep -rIl "$@" 2>/dev/null | grep -vE "$EXCL"; }
xgrep_q(){ xgrep_l "$@" | grep -q .; }
# STRICT security gate: an unattended PUBLIC self-merge has no human to catch a "major" security gap, so the
# security [major] warnings below become HARD BLOCKERS (the orchestrator's AUTO-ACCEPT SAFETY RAIL, made
# mechanical). ON when the profile audience is public/customer/enterprise AND auto_merge is on; force either
# way with ACE_STRICT_SECURITY=1 / =0. (Heuristic greps → a false positive blocks a merge; that is the
# fail-closed trade for shipping to real users with no reviewer. Set ACE_STRICT_SECURITY=0 to opt a run out.)
_strict=0
_paud="$(sed -n 's/^[[:space:]]*audience:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
_pam="$(sed -n 's/^[[:space:]]*auto_merge:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
case "$_paud" in oss-public|end-customer|enterprise) case "$_pam" in true|yes|1) _strict=1 ;; esac ;; esac
case "${ACE_STRICT_SECURITY:-}" in 1) _strict=1 ;; 0) _strict=0 ;; esac
_secwarn(){ if [ "$_strict" = 1 ]; then echo "RED [blocker]: $* [strict: public + auto_merge, no human reviewer]"; fail=1; else echo "WARN [major]: $*"; fi; }
if [ "$MODE" = launch ]; then
  section "Launch-readiness (mechanical pre-promotion gate — the launch_readiness_reviewer agent does the judgment)"
  # Composition-aware (like the stack-conditional gates above): only require the DB restore-drill when the
  # project HAS a database, and rollback/SLO/runbook only for a deployed service (deploy_kind=service). A
  # no-DB CLI / library is not NO-GO'd for a backup it cannot have.
  _hasdb=0
  { [ -f package.json ] && grep -qiE '"(pg|postgres|prisma|@prisma/client|drizzle-orm|mysql2?|mongoose|mongodb|better-sqlite3|sqlite3|sequelize|typeorm|knex|kysely|pg-promise|@libsql/client|@neondatabase/serverless|@planetscale/database|@vercel/postgres)"' package.json; } && _hasdb=1
  { [ -f go.mod ] && grep -qiE 'lib/pq|jackc/pgx|jackc/pgconn|go-sql-driver|mattn/go-sqlite3|modernc\.org/sqlite|glebarez/sqlite|gorm\.io|entgo\.io/ent|uptrace/bun|jmoiron/sqlx|mongo-driver' go.mod; } && _hasdb=1
  grep -qiE 'psycopg|sqlalchemy|sqlmodel|asyncpg|pymysql|mysqlclient|mariadb|aiosqlite|pymongo|django|tortoise|peewee|alembic' requirements*.txt pyproject.toml 2>/dev/null && _hasdb=1
  { ls prisma/schema.prisma migrations/*.sql db/migrations/*.sql migrations/0*.py */migrations/0*.py alembic/versions/*.py 2>/dev/null | grep -q .; } && _hasdb=1
  _svc=0; [ "$(sed -n 's/^[[:space:]]*deploy_kind:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)" = service ] && _svc=1
  if [ "$_hasdb" = 1 ]; then
    if [ -f ops/restore-drill.result ] && grep -qiE 'rows_verified=[1-9]|status=(verified|pass|ok)' ops/restore-drill.result 2>/dev/null; then echo "tested restore: recorded"; else echo "NO-GO [blocker]: ops/restore-drill.result missing or shows no verified restore (needs rows_verified / RPO / RTO) — a backup is not done until a restore has been run: ./ops/restore-drill.sh"; fail=1; fi
  else echo "no database detected — restore-drill not required"; fi
  if [ "$_svc" = 1 ]; then
    [ -f ops/rollback.md ] && echo "present: ops/rollback.md" || { echo "NO-GO [blocker]: ops/rollback.md missing — document the tested revert for the last deploy"; fail=1; }
    for a in ops/runbook.md ops/slo.md LAUNCH-READINESS.md; do [ -f "$a" ] && echo "present: $a" || echo "WARN [major]: missing $a (scaffold it; track to verified in LAUNCH-READINESS.md)"; done
  else echo "deploy_kind != service (artifact/library/none) — rollback/SLO/runbook not required"; fi
  [ "$fail" = 0 ] && { echo -e "\nLAUNCH GREEN (mechanical checks pass — now run the launch_readiness_reviewer agent for the full GO/NO-GO)"; exit 0; } || { echo -e "\nLAUNCH RED — NO-GO (fix the [blocker] artifacts above)"; exit 1; }
fi
section "[1/12] Build + test ($MODE)"
if [ "$MODE" = container ]; then
  if podman build --force-rm --target test -t localhost/ci:dev -f Containerfile .; then _rc=0; else _rc=1; fi
  podman image prune -f >/dev/null 2>&1 || true  # reclaim this build's dangling layers (prevents disk bloat)
  [ "$_rc" = 0 ] || { echo RED; exit 1; }
else
  # coverage is a SIGNAL not a gate: add --cov when pytest-cov is installed (else plain), no % threshold.
  if python -c 'import pytest_cov' >/dev/null 2>&1; then python -m pytest -q --ignore=brownfield --cov=src --cov-report=term-missing:skip-covered || fail=1
  else python -m pytest -q --ignore=brownfield || fail=1; fi
fi
section "[2/12] Env integrity — os.getenv vars declared in .env.example"
declared=$(grep -oP '^[A-Z0-9_]+(?==)' .env.example 2>/dev/null | sort -u)
used=$(find . -name '*.py' -type f -print0 2>/dev/null | grep -zvE "$EXCL" | xargs -0 -r grep -hoP 'os\.(getenv|environ\.get)\("\K[A-Z0-9_]+' 2>/dev/null | sort -u)
miss=$(comm -23 <(printf '%s\n' "$used"|sed '/^$/d') <(printf '%s\n' "$declared"|sed '/^$/d'))
[ -n "$miss" ] && { echo "RED: undeclared env vars:"; echo "$miss"; fail=1; }
section "[3/12] Compile"
# -print0 | xargs -0: an unquoted $(find …) word-split every path containing a space into two bogus
# names, py_compile answered "[Errno 2] No such file", the gate went RED and .githooks/pre-commit then
# blocked EVERY commit. $EXCL also keeps .venv/ out — the .gitignore above declares it, and
# byte-compiling the dependency tree (one py2-era file in any package) pinned this gate red forever.
: > /tmp/ci-pc.log
find . -name '*.py' -type f -print0 2>/dev/null | grep -zvE "$EXCL" | xargs -0 -r python -m py_compile 2>/tmp/ci-pc.log
# Judged on the LOG, not the pipeline rc: `grep -zv` exits 1 when every .py was excluded (a
# brownfield-only repo), which is not a compile failure. py_compile always names the file it could
# not compile, so a non-empty log is the only honest signal here.
[ -s /tmp/ci-pc.log ] && { echo "RED: compile"; cat /tmp/ci-pc.log; fail=1; }
section "[4/12] No stubs / placeholders (depth gate)"
stub=$(grep -rInE '(TODO|FIXME|XXX)|not[ _]implemented|NotImplementedError' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' apps packages services src 2>/dev/null | grep -vE "$EXCL" | head -20)
[ -n "$stub" ] && { echo "RED: unfinished stubs/markers — complete them (or move real notes to .opencode/specs/):"; echo "$stub"; fail=1; }
section "[5/12] Client-bundle secret scan (leaked provider/service keys)"
# Scan the BUILT client bundle only (dist/build/.next/public) for shipped provider/service keys — never
# source, never server-only .env. Add literal substrings to .ci-secretignore to suppress false positives.
csec_dirs=""; for d in dist build .next public; do [ -d "$d" ] && csec_dirs="$csec_dirs $d"; done
if [ -n "$csec_dirs" ]; then
  csec_re='sk_live_|sk_test_|service_role|SUPABASE_SERVICE_ROLE|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{20,}|OPENAI_API_KEY|ANTHROPIC_API_KEY'
  csec_hits=$(grep -rInE "$csec_re" $csec_dirs 2>/dev/null || true)
  if [ -n "$csec_hits" ] && [ -s .ci-secretignore ]; then csec_hits=$(printf '%s\n' "$csec_hits" | grep -vFf <(grep -v '^$' .ci-secretignore) || true); fi
  if [ -n "$csec_hits" ]; then echo "RED [blocker]: secret/credential shipped in client bundle — move it to server-only env:"; printf '%s\n' "$csec_hits" | head -20; fail=1; else echo "(client bundle clean)"; fi
else echo "(no client bundle dir — skipping)"; fi
section "[6/12] Row-Level Security — RLS enabled per table (Postgres/Supabase)"
# Stack-conditional: runs only when SQL migrations declare CREATE TABLE; clean no-op otherwise.
# Resolve the OWNED .sql set once through $EXCL — a brownfield/ or vendored migration is not ours to
# police, and it used to RED-block every commit here. Every lookup below reuses this one list, and it is
# ALL owned .sql (not just the CREATE TABLE files) because RLS is usually enabled in a LATER migration.
sql_all=$(find . -name '*.sql' -type f 2>/dev/null | grep -vE "$EXCL" || true)
_sqlgrep(){ printf '%s\n' "$sql_all" | tr '\n' '\0' | xargs -0 -r grep "$@" 2>/dev/null; }   # judge the OUTPUT, never xargs' rc
if [ -n "$sql_all" ] && _sqlgrep -lIE 'CREATE TABLE' | grep -q .; then
  rls_tables=$(_sqlgrep -hoIE 'CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?[A-Za-z0-9_]+' | sed -E 's/.*CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?//; s/".*//' | sort -u)
  for t in $rls_tables; do
    if ! _sqlgrep -lIE "ALTER TABLE +(public\.)?\"?${t}\"? +ENABLE ROW LEVEL SECURITY" | grep -q .; then
      echo "RED [blocker]: table '${t}' created without ENABLE ROW LEVEL SECURITY"; fail=1
    elif ! _sqlgrep -lIE "CREATE POLICY .*ON +(public\.)?\"?${t}\"?" | grep -q .; then
      _secwarn "table '${t}' has RLS enabled but no CREATE POLICY (deny-all — usually unintended)"
    fi
  done
else echo "(no SQL CREATE TABLE — skipping RLS check)"; fi
section "[7/12] LLM call-site guards (cost / abuse)"
# Stack-conditional: runs only when an LLM SDK is a dependency; heuristic [major] warnings, never a hard fail.
if grep -rIqE 'openai|anthropic|langchain|@ai-sdk|llamaindex|@google/generative-ai' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null; then
  llm_calls=$(grep -rIlE '\.chat\.completions\.create|\.messages\.create|\.completions\.create|\.responses\.create|generateText|streamText|generateObject|\.GenerateContent' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null | grep -vE "$EXCL" | head -50 || true)
  if [ -n "$llm_calls" ]; then
    printf '%s\n' "$llm_calls" | xargs grep -lIE 'max_tokens|maxOutputTokens|max_output_tokens|maxTokens' 2>/dev/null | grep -q . || _secwarn "LLM call site(s) with no visible token cap (max_tokens/maxOutputTokens) — uncapped output is a cost + DoS risk"
    xgrep_q -iE 'budget|rate.?limit|max.?iteration|max.?step|max.?turn' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . || _secwarn "no visible per-user/session budget, rate-limit, or agent max-iteration cap near LLM calls"
  else echo "(LLM SDK present but no direct call site found — skipping)"; fi
else echo "(no LLM SDK dependency — skipping)"; fi
section "[8/12] Webhook handler integrity (payment/event webhooks)"
# Stack-conditional: runs only when a MONEY webhook handler is present; clean no-op otherwise.
wh_files=$( { grep -rIliE 'webhook|constructEvent|Stripe-Signature|whsec_' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f -iname '*webhook*' 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -50 )
money_wh=""; [ -n "$wh_files" ] && money_wh=$(printf '%s\n' "$wh_files" | xargs grep -lIiE 'stripe|paypal|braintree|paddle|lemonsqueez|razorpay|payment|charge|subscription|checkout|billing' 2>/dev/null || true)
if [ -n "$money_wh" ]; then
  wh_sig='constructEvent|verifyHeader|verifySignature|Stripe-Signature|X-Hub-Signature|createHmac|compare_digest|hmac\.new|ConstructEvent|ValidateSignature|WebhookSignature'
  if printf '%s\n' "$money_wh" | xargs grep -lIE "$wh_sig" 2>/dev/null | grep -q .; then
    echo "(webhook signature verification present)"
    wh_dedupe='event[._]?id|eventId|idempotenc|processed|dedup|on conflict|already|\bseen\b'
    printf '%s\n' "$money_wh" | xargs grep -lIiE "$wh_dedupe" 2>/dev/null | grep -q . || _secwarn "money webhook has no visible event-ID dedupe (at-least-once delivery + multi-day retries can double-process)"
  else
    echo "RED [blocker]: money webhook handler with NO signature verification — forgeable 'payment succeeded':"; printf '%s\n' "$money_wh" | head -10; fail=1
  fi
else echo "(no payment webhook handler — skipping)"; fi
section "[9/12] Auth & session edge cases (reset tokens / enumeration)"
# Stack-conditional: runs only when auth routes are present; heuristic [major] warnings, never a hard fail.
auth_files=$( { grep -rIliE 'password|reset[_-]?token|forgot|sign[_-]?in|next-auth|passport|lucia|bcrypt|argon2' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f \( -iname '*auth*' -o -iname '*login*' -o -iname '*password*' \) 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -80 )
if [ -n "$auth_files" ]; then
  if printf '%s\n' "$auth_files" | xargs grep -lIiE 'no such (user|account)|(email|user|account) not found|does ?n.?t exist|no account (with|found)' 2>/dev/null | grep -q .; then
    _secwarn "an auth response reveals whether an account exists (enumeration) — return a GENERIC message for existing AND non-existing accounts"
  fi
  reset_files=$(printf '%s\n' "$auth_files" | xargs grep -lIiE 'reset[_-]?token|password[_-]?reset|forgot' 2>/dev/null || true)
  if [ -n "$reset_files" ]; then
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'hash|bcrypt|argon2|scrypt|sha256|createhash|digest' 2>/dev/null | grep -q . || _secwarn "reset token may be stored in plaintext — store only its HASH and compare hashes"
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'expir|ttl|valid[_-]?until|used|consumed|redeemed|single[_-]?use' 2>/dev/null | grep -q . || _secwarn "reset token has no visible expiry or single-use flag — make it time-limited AND single-use"
  fi
else echo "(no auth routes — skipping)"; fi
section "[10/12] Migration safety (expand-contract)"
# Stack-conditional: runs only when SQL migration files are present; clean no-op otherwise.
mig_files=$(grep -rIlE 'ALTER TABLE|DROP TABLE|DROP COLUMN|CREATE TABLE|RENAME' --include='*.sql' . 2>/dev/null | grep -vE "$EXCL" | head -80 || true)
if [ -n "$mig_files" ]; then
  while IFS= read -r mf; do [ -n "$mf" ] || continue
    if grep -IiqE 'DROP (TABLE|COLUMN)|RENAME (TO|COLUMN)|ALTER COLUMN[^;]*DROP' "$mf" 2>/dev/null; then
      grep -IiqE -e '--[[:space:]]*down\b|irreversible[^a-z]{0,4}approved|expand.?contract' "$mf" 2>/dev/null || { echo "RED [blocker]: $mf — destructive schema op (DROP/RENAME) with no reverse. Use expand-contract (add new → backfill → switch reads → drop LATER, as SEPARATE changes); if intentional, add a '-- down' reverse (a SQL comment) or an '-- irreversible: approved' marker."; fail=1; }
    fi
    if grep -IiE 'ADD COLUMN[^;]*NOT NULL' "$mf" 2>/dev/null | grep -qviE 'DEFAULT|GENERATED'; then
      echo "RED [blocker]: $mf — ADD COLUMN ... NOT NULL without a DEFAULT will fail on existing rows; add a DEFAULT or backfill in phases."; fail=1
    fi
  done <<< "$mig_files"
else echo "(no SQL migrations — skipping)"; fi
section "[11/12] Observability (structured logs, health, log hygiene)"
# Log hygiene runs on any source (a secret VALUE in a log is a [blocker]); server checks gate on a server app.
loghy=$(grep -rIinE '(console\.(log|info|warn|error|debug)|logger?\.[a-zA-Z]+|log\.(Info|Print|Printf|Debug|Error|Warn|Fatal)|logging\.(info|debug|warning|error)|print|println|fmt\.Print[a-z]*)[[:space:]]*\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null | grep -vE "${EXCL}|\.(test|spec)\." | grep -IiE '\.(password|passwd|secret|token|authorization|ssn|cvv|api[_-]?key|credit[_-]?card)\b|[$][{][^}]*(password|passwd|secret|token|ssn|cvv)|[{][[:space:]]*(password|passwd|secret|token|ssn|cvv)[[:space:]]*[,}]|[(][[:space:]]*(password|passwd|secret|token|ssn)[[:space:]]*[),]' | head -20 || true)
[ -n "$loghy" ] && { echo "RED [blocker]: a secret/PII VALUE appears in a log statement — never log passwords/tokens/secrets/PII:"; printf '%s\n' "$loghy" | head -10; fail=1; }
if xgrep_q -E '\.listen\(|createServer|app\.run\(|http\.ListenAndServe|uvicorn|FastAPI|express\(|fastify\(|gin\.(New|Default)|Flask\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' .; then
  xgrep_q -iE '/health|/healthz|/ready|/readyz|actuator/health|livenessProbe' . || echo "WARN [major]: no /health or /ready endpoint found — add liveness/readiness probes for a server app"
  grep -rIqiE 'winston|pino|bunyan|structlog|loguru|zap|logrus|zerolog|log/slog|slog\.' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null || echo "WARN [major]: no structured logger detected — use a structured logger (not raw console.log/print) in request paths"
  xgrep_q -iE 'correlation|request[_-]?id|x-request-id|traceparent|trace[_-]?id' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . || echo "WARN [major]: no request/correlation-ID found — attach one to every log line for traceability"
else echo "(not a server app — health/correlation checks skipped; log hygiene ran)"; fi
section "[12/12] Supply chain (deterministic installs, SBOM, pinned actions)"
if [ -f Containerfile ] || [ -d .github/workflows ]; then
  ndi=$(grep -rIinE '(npm|pnpm|yarn) +install' Containerfile .github/workflows 2>/dev/null | grep -viE 'npm ci|--frozen-lockfile|--ignore-scripts' | head -10 || true)
  [ -n "$ndi" ] && { echo "WARN [major]: non-deterministic install in a build — use 'npm ci' / 'pnpm i --frozen-lockfile' / 'pip install --require-hashes':"; printf '%s\n' "$ndi" | head -5; }
  fl=$(grep -rInE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@' .github/workflows 2>/dev/null | grep -vE 'uses:[[:space:]]*actions/' | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' | head -10 || true)
  [ -n "$fl" ] && { echo "WARN [major]: third-party GitHub Action pinned to a floating tag — pin by full commit SHA (uses: org/action@<40-hex-sha> # vX):"; printf '%s\n' "$fl" | head -5; }
  grep -rIqiE 'cyclonedx|spdx|sbom|syft|trivy' package.json Containerfile .github/workflows 2>/dev/null || echo "WARN [major]: no SBOM (CycloneDX/SPDX) generated — emit one as a build artifact for dependency transparency"
else echo "(no Containerfile or CI workflow — skipping supply-chain checks)"; fi
[ "$fail" = 0 ] && { echo -e "\nCI GREEN ($MODE)"; exit 0; } || { echo -e "\nCI RED ($MODE)"; exit 1; }
EOF
  chmod +x ci.sh
  gen_project_agents "$name" "Python + pytest. Build/test in a pinned python:3.13-slim container."
}

gen_configonly() {
  local name="$1"
  printf '.env\n.env.*\n!.env.example\n.DS_Store\n# ACE loop transients (keep git status clean)\n.serena/\n.opencode/.agents\n.opencode/.oppid\n.opencode/.step-budget\n.opencode/.timedout\n.opencode/.rathole\n.opencode/.container-green\n.opencode/.harvested-warnings\n.opencode/.objectives-synced\n.opencode/last-run.log\n.opencode/ci-failure.log\n.opencode/ci-build.log\n.opencode/loop-state.env\n.opencode/metrics.csv\n.opencode/run-summary.txt\n.opencode/token-report.md\n.opencode/.session-id\n.opencode/.kanban-map\n.opencode/approvals/\n.opencode/HANDOVER.md\n.opencode/vps-verify-report.md\n.opencode/cache/\n.opencode/reanalyze/\n*.orig\n*.rej\n' > .gitignore
  printf '# Declared env vars\n' > .env.example
  cat > ci.sh <<'EOF'
#!/usr/bin/env bash
# Template gate — add your build/test here. ./ci.sh fast | ./ci.sh --container
set -uo pipefail
echo "TODO: wire your build + tests. Returning green so the loop can start."
echo "CI GREEN"
EOF
  chmod +x ci.sh
  gen_project_agents "$name" "Config-only scaffold — fill in ci.sh with your stack's build/test."
}

gen_project_agents() {
  cat > AGENTS.md <<EOF
# $1 — project rules

## Stack
$2

## Conventions
- Branch: feat/<slug>; commit only on green ./ci.sh; message "type(area): summary".
- Secrets in .env.local (gitignored); declare every env var in .env.example (ci.sh enforces this).

## How to verify
- ./ci.sh (fast) is the pre-commit gate; ./ci.sh --container (VPS parity) is the pre-push/CI gate.

## Test strategy — pick the type that would catch a WRONG implementation
Don't default to "a couple of asserts". Choose the test TYPE per what the code is:

| Code under test | Test type |
|---|---|
| Branchy logic, boundaries | Table-driven — happy + error + edge cases |
| Parser / serializer / encoder / math | Property + fuzz — roundtrip & invariants |
| Generated output (CLI text, templates, config) | Golden / snapshot |
| HTTP / RPC handler | In-process server (httptest / supertest) + a contract check vs the schema |
| DB / external wiring | Integration against an ephemeral dependency — mocks hide real bugs |
| Money / orders / webhooks | Replay / idempotency test + assert the audit record |
| Auth / ownership | Authz-DENY matrix (role x resource) |
| Concurrency | Race detector + contention / interleave cases |
| Critical user flow | One end-to-end test, sparingly |

- REUSE, don't re-roll setup: shared helpers live in the test-support module (Go: internal/testutil · Node: tests/ · Python: tests/conftest.py) — fake clock, factories/builders, fixtures, golden/ data. Extend them; never copy setup between tests.
- Coverage is a SIGNAL, not a target: where the stack reports it at all, ci.sh reports WHOLE-PROJECT coverage, never a changed-code number (Go: always · Node: only under COVERAGE=1 · Python: only if pytest-cov is installed). Do not read that total as a verdict on your diff — judge your change by whether its happy, error and edge paths are exercised. Close obvious gaps, never write tests just to move a %. Mutation-test high-stakes packages when unsure a suite is strong.
- Tests ship in the SAME commit/PR as the code they cover — never a test-only PR. On high-risk / logic-dense changes the loop adds an INDEPENDENT adversarial test_engineer pass.

## Decisions
<!-- the orchestrator appends notable decisions at feature end -->
EOF
}

# ---------------------------------------------------------------- project profile (architecture decision)
# Read a scalar from a profile.yaml (defaults to .opencode/profile.yaml). Strips quotes/comments.
_prof_get() {
  local file=".opencode/profile.yaml" key="$1"
  [ "$#" -ge 2 ] && { file="$1"; key="$2"; }
  grep -E "^[[:space:]]*${key}:[[:space:]]*" "$file" 2>/dev/null | head -1 \
    | sed -E "s/^[^:]*:[[:space:]]*\"([^\"]*)\".*$/\1/; t; s/^[^:]*:[[:space:]]*'([^']*)'.*$/\1/; t; s/^[^:]*:[[:space:]]*//; s/^#.*$//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//"
}

# Append an "## Architecture" pointer to AGENTS.md if not already present (idempotent).
ensure_agents_arch_pointer() {
  [ -f AGENTS.md ] || return 0
  grep -q '^## Architecture' AGENTS.md && return 0
  cat >> AGENTS.md <<'EOF'

## Architecture & mission
- The project profile is the source of truth: `.opencode/profile.yaml` (structured) + `ARCHITECTURE.md` (prose).
- Read it before planning: serve the stated mission, values, audience, and throughput target.
- Delivery policy (git / ci_cd / gitflow / merge_gate / auto_merge) is recorded there and drives the loop.
- `docs/atlas.md` is the GENERATED human atlas (system map · data flow · feature map) — do NOT hand-edit it; it is rebuilt by `scripts/atlas-refresh.sh` (`ace atlas`). `docs/architecture.md` is the agent-facing code map (GitNexus/Serena).
EOF
}

# choose <current> "<header>" "value::hint" ... -> CHOOSE_REPLY (the chosen VALUE).
# Marks <current> as "(current)"; pressing Enter keeps it. Used so `ace profile` re-runs pre-fill.
choose() {
  local cur="$1" header="$2"; shift 2
  local opts=("$@") i val hint
  if _noninteractive; then CHOOSE_REPLY="$cur"; return 0; fi   # headless: keep current/pre-filled value
  while true; do
    printf '\n%s\n\n' "${C_BOLD}$header${C_RESET}"
    for i in "${!opts[@]}"; do
      val="${opts[$i]%%::*}"; hint="${opts[$i]#*::}"; [ "$hint" = "${opts[$i]}" ] && hint=""
      printf '  %s%2d%s) %s%s%s' "${C_BOLD}${C_CYAN}" $((i+1)) "${C_RESET}" "$val" "${C_GREY}" "${hint:+   $hint}"
      [ "$val" = "$cur" ] && printf '  %s← current%s' "$C_GREEN" "$C_RESET"
      printf '%s\n' "$C_RESET"
    done
    if [ -n "$cur" ]; then printf '\n%s choose [1-%d] %s(Enter = keep %s)%s: ' "${C_BOLD}>${C_RESET}" "${#opts[@]}" "$C_GREY" "$cur" "$C_RESET"
    else printf '\n%s choose [1-%d]: ' "${C_BOLD}>${C_RESET}" "${#opts[@]}"; fi
    local r; read -r r
    [ -z "$r" ] && [ -n "$cur" ] && { CHOOSE_REPLY="$cur"; return 0; }
    if [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -ge 1 ] && [ "$r" -le "${#opts[@]}" ]; then CHOOSE_REPLY="${opts[$((r-1))]%%::*}"; return 0; fi
    warn "Pick 1-${#opts[@]}${cur:+, or Enter to keep $cur}."
  done
}

# Validate .opencode/profile.yaml: required fields present + enums valid. `ace profile --check`.
profile_check() {
  local f=".opencode/profile.yaml" bad=0 v
  [ -f "$f" ] || { err "no .opencode/profile.yaml here (run: ace profile)"; return 1; }
  step "Profile check — $f"
  _enum(){ local key="$1" val; val="$(_prof_get "$key")"; shift; case " $* " in *" $val "*) ok "$key = $val" ;; *) err "$key = '${val:-<empty>}' (expected: $*)"; bad=1 ;; esac; }
  _set(){ v="$(_prof_get "$1")"; [ -n "$v" ] && ok "$1 = $v" || { err "$1 is empty"; bad=1; }; }
  _set name; _set domain; _set mission
  _enum shape api cli cli-web worker library
  _enum audience internal oss-public end-customer enterprise
  _enum throughput low medium high
  _enum hardening none standard strong
  _enum git true false; _enum gitflow true false; _enum auto_merge true false
  _enum ci_cd github-actions none
  [ -n "$(_prof_get container)" ] && _enum container true false
  _enum merge_gate remote local both
  [ -n "$(_prof_get deploy_kind)" ] && _enum deploy_kind service artifact none
  v="$(_prof_get targets)"; case "$v" in \[*\]) ok "targets = $v" ;; *) err "targets = '${v:-<empty>}' (expected a [list])"; bad=1 ;; esac
  # coherence: a remote-watching merge gate (remote OR both) needs remote CI to wait on
  case "$(_prof_get merge_gate)" in
    remote|both) [ "$(_prof_get ci_cd)" != github-actions ] && { warn "merge_gate=$(_prof_get merge_gate) but ci_cd!=github-actions — no remote CI to wait on; set merge_gate: local."; bad=1; } ;;
  esac
  hr; [ "$bad" = 0 ] && ok "profile is valid." || { err "profile has problems — fix the ✗ lines (or re-run: ace profile)."; return 1; }
}

# Interactive architecture-decision wizard. Writes .opencode/profile.yaml + ARCHITECTURE.md, seeds
# OBJECTIVES.md, and sets PROFILE_* globals the scaffolder reads. Re-run (ace profile) reads the
# existing profile as defaults (pre-filled) and rewrites it (bumps updated:). Hardening is SUGGESTED
# from audience; build targets are chosen LAST and suggested from the shape.
profile_wizard() {
  # Operate in the CURRENT directory. During scaffold we're already in the new project dir (which is
  # NOT a git repo yet) — cd-ing to a git toplevel here would escape into an ENCLOSING repo and write
  # the whole project there. Standalone `ace profile` cd's to the repo root before calling this.
  local name="${1:-}"; [ -z "$name" ] && name="$(_prof_get name)"; [ -z "$name" ] && name="$(basename "$PWD")"
  step "Project profile — architecture & delivery decisions ($name)"
  box "This writes an EDITABLE profile the autorun loop reads to ground its work." \
    "  .opencode/profile.yaml  (structured)   •   ARCHITECTURE.md  (prose)" \
    "Re-run anytime with: ace profile"

  # --- architecture --- (every picker defaults to the existing value on re-run, else the seeded --shape flag)
  local d_shape; d_shape="$(_prof_get shape)"; [ -z "$d_shape" ] && d_shape="${PROFILE_SHAPE:-}"
  choose "$d_shape" "Architecture shape" \
    "api::HTTP/REST service (fully wired — container + VPS deploy + /healthz)" \
    "cli::command-line program" \
    "cli-web::CLI now, web UI later" \
    "worker::background processor / daemon" \
    "library::importable package"
  local shape="$CHOOSE_REPLY"

  local d_domain; d_domain="$(_prof_get domain)"; [ -z "$d_domain" ] && d_domain="${ACE_DOMAIN:-$name}"
  ask "Domain / one-line description of what this does" "$d_domain"; local domain="$ASK_REPLY"

  local d_aud; d_aud="$(_prof_get audience)"; [ -z "$d_aud" ] && d_aud="${ACE_AUDIENCE:-internal}"
  choose "$d_aud" "Target audience" \
    "internal::team/personal use" \
    "oss-public::open-source, distributed to the world" \
    "end-customer::shipped to paying/general users" \
    "enterprise::sold to organizations"
  local audience="$CHOOSE_REPLY"

  local d_thr; d_thr="$(_prof_get throughput)"; [ -z "$d_thr" ] && d_thr="${ACE_THROUGHPUT:-low}"
  choose "$d_thr" "Predicted initial throughput" \
    "low::occasional / dev-scale" "medium::steady production traffic" "high::heavy / latency-sensitive"
  local throughput="$CHOOSE_REPLY"

  # --- alignment (the alignment_reviewer agent reviews against these) ---
  local d_mission; d_mission="$(_prof_get mission)"; [ -z "$d_mission" ] && d_mission="${ACE_MISSION:-Ship $name.}"
  ask "Mission — why this exists (one line)" "$d_mission"; local mission="$ASK_REPLY"
  local d_values; d_values="$(_prof_get values | tr -d '[]')"
  ask "Core values (comma-separated, e.g. reliability, privacy)" "${d_values:-reliability, security}"; local values="$ASK_REPLY"
  ask "Engineering philosophy (e.g. boring tech, fail-closed, no dark patterns)" "$(_prof_get philosophy)"; local philosophy="$ASK_REPLY"
  [ -n "$philosophy" ] || philosophy="fail-closed, boring tech"

  # --- delivery / git policy --- (defaults: the existing profile on re-run, else the seeded flags)
  local d_git d_cicd d_flow d_am d_cont
  d_git="$(_prof_get git)";        [ -z "$d_git" ]  && d_git="${PROFILE_GIT:-}"
  d_cicd="$(_prof_get ci_cd)";     [ -z "$d_cicd" ] && d_cicd="${PROFILE_CI_CD:-}"
  d_flow="$(_prof_get gitflow)";   [ -z "$d_flow" ] && d_flow="${PROFILE_GITFLOW:-}"
  d_cont="$(_prof_get container)"; [ -z "$d_cont" ] && d_cont="${PROFILE_CONTAINER:-}"
  d_am="$(_prof_get auto_merge)"
  local use_git=true ci_cd=none gitflow=false container=true
  confirm "Use git for this project?" "$([ "$d_git" = false ] && echo N || echo Y)" && use_git=true || use_git=false
  if [ "$use_git" = true ]; then
    confirm "Set up GitHub CI/CD (Actions workflow)?" "$([ "$d_cicd" = none ] && echo N || echo Y)" && ci_cd=github-actions || ci_cd=none
    confirm "Apply gitflow (main + conventional commits + guards)?" "$([ "$d_flow" = false ] && echo N || echo Y)" && gitflow=true || gitflow=false
  fi
  confirm "Build/test in a container (Containerfile + ./ci.sh --container parity gate)? (No = host-only)" "$([ "$d_cont" = false ] && echo N || echo Y)" && container=true || container=false
  export PROFILE_CONTAINER="$container"

  # merge gate: local = merge on ./ci.sh --container green; remote = wait for Actions green.
  local merge_gate=remote
  if [ "$ci_cd" != github-actions ] || [ "$use_git" != true ]; then
    merge_gate=local; info "No remote CI → merge gate forced to 'local' (./ci.sh --container is the authority)."
  else
    local d_mg; d_mg="$(_prof_get merge_gate)"; [ -z "$d_mg" ] && d_mg=remote   # default so headless never leaves it empty
    choose "$d_mg" "Merge gate — when may the loop merge a green PR?" \
      "remote::wait for GitHub Actions all-green (recommended when CI/CD is on)" \
      "local::merge as soon as ./ci.sh --container is GREEN (don't wait on Actions)" \
      "both::require BOTH — local ./ci.sh --container GREEN *and* GitHub Actions all-green (strictest)"
    merge_gate="$CHOOSE_REPLY"
  fi

  local auto_merge=false
  confirm "Auto-accept: let the loop self-merge when the gate is GREEN? (else it opens a PR and stops)" "$([ "$d_am" = true ] && echo Y || echo N)" && auto_merge=true || auto_merge=false
  info "auto-accept is also settable per run: AUTOMERGE=1 ace autorun  (env overrides the profile)."

  # --- hardening (default = existing, else SUGGESTED from audience) ---
  local sugg_hard=standard; case "$audience" in oss-public|end-customer) sugg_hard=strong ;; esac
  local d_hard; d_hard="$(_prof_get hardening)"; [ -n "$d_hard" ] || d_hard="$sugg_hard"
  choose "$d_hard" "Hardening of shipped binaries (suggested from audience=$audience: $sugg_hard)" \
    "none::no stripping" "standard::strip symbols + trimpath" "strong::+ garble obfuscation"
  local hardening="$CHOOSE_REPLY"

  # --- build targets (LAST; default = existing, else suggested from shape) ---
  local d_tgt; d_tgt="$(_prof_get targets | tr -d '[]')"; [ -n "$d_tgt" ] || d_tgt="linux/amd64, linux/arm64"
  choose "$d_tgt" "Build targets" \
    "linux/amd64, linux/arm64::servers + ARM (recommended)" \
    "linux/amd64::single most common target" \
    "linux/amd64, linux/arm64, darwin/arm64, darwin/amd64::+ macOS"
  local targets="$CHOOSE_REPLY"

  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would write .opencode/profile.yaml + ARCHITECTURE.md (shape=$shape audience=$audience merge_gate=$merge_gate container=$container)"; PROFILE_SHAPE="$shape"; PROFILE_GIT="$use_git"; PROFILE_CI_CD="$ci_cd"; PROFILE_GITFLOW="$gitflow"; PROFILE_CONTAINER="$container"; return 0; }

  write_profile "$name" "$shape" "$domain" "$audience" "$throughput" "$mission" "$values" "$philosophy" "$use_git" "$ci_cd" "$gitflow" "$merge_gate" "$auto_merge" "$hardening" "$targets"
  write_architecture_md "$name" "$shape" "$domain" "$audience" "$throughput" "$mission" "$values" "$philosophy" "$use_git" "$ci_cd" "$gitflow" "$merge_gate" "$auto_merge" "$hardening" "$targets"
  seed_objectives "$name" "$domain" "$mission"
  ensure_agents_arch_pointer
  ok "Profile written: .opencode/profile.yaml + ARCHITECTURE.md"
  # surfaced to the scaffolder so it can gate git / ci_cd / gitflow / container steps
  PROFILE_SHAPE="$shape"; PROFILE_GIT="$use_git"; PROFILE_CI_CD="$ci_cd"; PROFILE_GITFLOW="$gitflow"; PROFILE_CONTAINER="$container"
}

# Detect a repo's stack from its files → node | python | go | config. Used to set the profile's `language:`
# when it isn't explicitly passed (a standalone `ace profile` on an existing repo), so a Node/Python web app
# is never mislabeled as Go. go.mod wins first; then a package.json = Node; then Python markers.
_detect_stack() {
  if [ -f go.mod ]; then echo go
  elif [ -f package.json ]; then echo node
  elif [ -f requirements.txt ] || [ -f pyproject.toml ] || ls ./*.py >/dev/null 2>&1; then echo python
  else echo config; fi
}
write_profile() {
  local name="$1" shape="$2" domain="$3" audience="$4" throughput="$5" mission="$6" values="$7" philosophy="$8" \
        use_git="$9" ci_cd="${10}" gitflow="${11}" merge_gate="${12}" auto_merge="${13}" hardening="${14}" targets="${15}"
  mkdir -p .opencode
  # YAML-safety: strip " and \ from free-text so a quote in the user's input can't break the file.
  domain="$(printf '%s' "$domain" | tr -d '"\\')"; mission="$(printf '%s' "$mission" | tr -d '"\\')"
  philosophy="$(printf '%s' "$philosophy" | tr -d '"\\')"; values="$(printf '%s' "$values" | tr -d '"\\')"
  local vals_yaml tgt_yaml now created deploy_kind container lang
  # language: fresh scaffold passes PROFILE_LANG=<stack>; an `ace profile` re-run preserves the existing
  # value (read BEFORE the heredoc truncates the file); else DETECT it from the repo — never mislabel a
  # Node/Python app as Go (standalone `ace profile` had no PROFILE_LANG + no profile, so it fell back to go).
  lang="${PROFILE_LANG:-$(_prof_get language)}"; [ -z "$lang" ] && lang="$(_detect_stack)"
  deploy_kind="$(_go_deploy_kind "$shape")"   # service | artifact | none — what the loop does after a merge
  container="${PROFILE_CONTAINER:-true}"       # true = Containerfile + container parity gate; false = host-only
  [ "$container" = false ] && [ "$deploy_kind" = service ] && deploy_kind=none   # no image ⇒ no container service deploy
  [ "${ACE_DEPLOY:-}" = none ] && deploy_kind=none   # --no-vps / --deploy none must PERSIST to the profile the loop reads (else it stays 'service')
  vals_yaml="[$(printf '%s' "$values" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]]*,[[:space:]]*/, /g')]"
  tgt_yaml="[$(printf '%s' "$targets" | sed -E 's/[[:space:]]*,[[:space:]]*/, /g')]"
  now="$(date -Is 2>/dev/null || date)"; created="$(_prof_get created)"; [ -z "$created" ] && created="$now"
  cat > .opencode/profile.yaml <<EOF
# ACE project profile — EDITABLE source of truth the autorun loop reads to ground its work.
# Edit by hand or re-run: ace profile
schema: 1
name: $name
language: $lang
# --- architecture ---
shape: $shape              # api | cli | cli-web | worker | library
domain: "$domain"
audience: $audience        # internal | oss-public | end-customer | enterprise
throughput: $throughput    # low | medium | high
hardening: $hardening      # none | standard | strong  (Phase 2 release.sh consumes; suggested from audience)
targets: $tgt_yaml         # build targets (Phase 2 release.sh consumes)
# --- alignment (the alignment_reviewer agent reviews changes against these) ---
mission: "$mission"
values: $vals_yaml
philosophy: "$philosophy"
# --- delivery / git policy ---
git: $use_git              # use git at all
ci_cd: $ci_cd              # github-actions | none
container: $container       # true = Containerfile + container parity gate (./ci.sh --container) | false = host-only
gitflow: $gitflow          # apply gitflow (main + conventional commits + guards)
merge_gate: $merge_gate    # remote (wait for Actions green) | local (merge on ./ci.sh --container green) | both (require local AND remote green)
auto_merge: $auto_merge    # auto-accept: loop self-merges when the gate is green (env AUTOMERGE overrides)
deploy_kind: $deploy_kind  # service (VPS deploy) | artifact (binaries ship on v* tags) | none — derived from shape
created: $created
updated: $now
EOF
}

write_architecture_md() {
  local name="$1" shape="$2" domain="$3" audience="$4" throughput="$5" mission="$6" values="$7" philosophy="$8" \
        use_git="$9" ci_cd="${10}" gitflow="${11}" merge_gate="${12}" auto_merge="${13}" hardening="${14}" targets="${15}"
  cat > ARCHITECTURE.md <<EOF
# $name — architecture

> Generated from \`.opencode/profile.yaml\`. Edit that file (or run \`ace profile\`) — this is its prose face.

## Domain
$domain

## Mission
$mission

## Values & philosophy
- Values: $values
- Philosophy: $philosophy

## Shape & scale
- Shape: **$shape**
- Audience: **$audience**
- Predicted initial throughput: **$throughput**

## Delivery policy
- git: \`$use_git\` · CI/CD: \`$ci_cd\` · gitflow: \`$gitflow\`
- Merge gate: **$merge_gate** ($(case "$merge_gate" in local) echo "merge on a GREEN ./ci.sh --container";; both) echo "require BOTH a GREEN ./ci.sh --container AND GitHub Actions all-green";; *) echo "wait for GitHub Actions all-green";; esac))
- Auto-accept (self-merge when green): \`$auto_merge\`  — override per run with \`AUTOMERGE=1 ace autorun\`.

## Hardening (shipped binaries)
- Level: **$hardening**. Build targets: $targets.
- Note: Go binaries carry rich runtime metadata and are inherently reversible. Stripping + garble raises
  the cost of reverse-engineering substantially but nothing makes a Go binary RE-proof — keep real
  secrets server-side, never in the binary. (The hardened release path lands in Phase 2.)

## North star
See [OBJECTIVES.md](OBJECTIVES.md) for the goal hierarchy the loop drives toward.
Run \`ace arch\` for a generated diagram.
EOF
}

# Seed OBJECTIVES.md from the profile (only if absent — gen_autoloop also no-clobbers it).
seed_objectives() {
  local name="$1" domain="$2" mission="$3"
  [ -f OBJECTIVES.md ] && return 0
  # shape-aware local-stack goals: an HTTP service gets health-endpoint + container goals; a
  # cli/worker/library gets entrypoint/API goals (it has no /healthz surface to serve).
  local _shape _l1 _l2; _shape="$(_prof_get shape 2>/dev/null)"; _shape="${_shape:-${PROFILE_SHAPE:-api}}"
  case "$_shape" in
    api|cli-web) _l1='- [ ] service builds + runs locally (./ci.sh GREEN, ./ci.sh --container GREEN)'
                 _l2='- [ ] /healthz returns 200 and the core path is exercised by a test' ;;
    *)           _l1='- [ ] builds + runs locally (./ci.sh GREEN)'
                 _l2='- [ ] the primary entrypoint / public API is exercised by an integration test' ;;
  esac
  cat > OBJECTIVES.md <<EOF
# Objectives — the north star. The loop breaks the current objective into ROADMAP.md tasks,
# implements them, and marks progress HERE. Edit freely.

## Mission
$mission

## Domain
$domain

## How it runs
- The loop implements ROADMAP.md items. When ROADMAP is empty it PLANS the next objective below
  into new ROADMAP tasks and updates the progress/status here.

## 1. Working, tested local stack
Goal: a fully working LOCAL build where every test runs green (unit + integration) against the app.
- status: not-started
$_l1
$_l2

## 2. Deliver the core domain value
Goal: implement the primary capability described in the Domain above, to a high bar.
- status: not-started

## 3. Roadmap & expansion planning
Goal: continuously plan high-value functionality and keep the roadmap full.
- status: ongoing

## Done
EOF
}

# scripts/release.sh — hardened, fully-static cross-compiled release binaries, driven by the profile.
# Defaults to building INSIDE a pinned golang container (reproducible, no host Go needed); --host builds
# on the host. Hardening (none|standard|strong) and targets come from .opencode/profile.yaml (env overrides).
gen_go_release() {
  mkdir -p scripts
  cat > scripts/release.sh <<'EOF'
#!/usr/bin/env bash
# Build hardened, fully-static release binaries for the targets + hardening in .opencode/profile.yaml.
# Default: builds INSIDE a pinned golang container (reproducible, runs everywhere). --host builds on the host.
# Env overrides: HARDENING=none|standard|strong  TARGETS="linux/amd64 linux/arm64"  UPX=1  GOIMAGE=golang:<v>
#                VERSION=<tag>  SIGN=minisign|cosign  (minisign: MINISIGN_SECRET_KEY · cosign: COSIGN_KEY)
#
# Hardening ladder (Go binaries are inherently reversible — this raises cost, not immunity; keep secrets server-side):
#   none     -> plain build (version-stamped)
#   standard -> -trimpath -ldflags '-s -w -buildid='   (strip symbols/DWARF/paths/build-id)
#   strong   -> garble -literals -tiny   (obfuscate identifiers + string literals) on top of the strip
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
GO_V="$(awk '/^go [0-9]/{print $2; exit}' go.mod 2>/dev/null)"; GO_V="${GO_V:-1.23}"  # single source: go.mod
GOIMAGE="${GOIMAGE:-golang:$GO_V}"

prof(){ grep -E "^[[:space:]]*$1:[[:space:]]*" .opencode/profile.yaml 2>/dev/null | head -1 | sed -E "s/^[^:]*:[[:space:]]*\"([^\"]*)\".*$/\1/; t; s/^[^:]*:[[:space:]]*'([^']*)'.*$/\1/; t; s/^[^:]*:[[:space:]]*//; s/^#.*$//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//"; }
APP="${APP:-$(prof name)}"; [ -n "$APP" ] || APP="$(basename "$ROOT")"
HARDENING="${HARDENING:-$(prof hardening)}"; [ -n "$HARDENING" ] || HARDENING=standard
if [ -z "${TARGETS:-}" ]; then TARGETS="$(prof targets | tr -d '[]' | tr ',' ' ')"; fi
[ -n "${TARGETS:-}" ] || TARGETS="linux/amd64 linux/arm64"
# version stamp + reproducibility (both overridable)
VERSION="${VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || date +%s)}"; export SOURCE_DATE_EPOCH

HOST=0; for a in "$@"; do [ "$a" = "--host" ] && HOST=1; done
# 'strong' needs garble; if the host already has go+garble, build on the host (skips a slow in-container install).
if [ "$HOST" != 1 ] && [ "${RELEASE_INSIDE:-0}" != 1 ] && [ "$HARDENING" = strong ] \
   && command -v go >/dev/null 2>&1 && command -v garble >/dev/null 2>&1; then
  echo "[release] strong hardening + host go+garble present — building on the host (faster than an in-container install)."; HOST=1
fi
if [ "$HOST" != 1 ] && [ "${RELEASE_INSIDE:-0}" != 1 ]; then
  command -v podman >/dev/null 2>&1 || { echo "[release] podman not found — use --host to build on the host."; exit 1; }
  echo "[release] building inside $GOIMAGE (use --host to build on the host)…"
  # persistent module + build caches make repeat releases (and the garble install) fast.
  exec podman run --rm -v "$ROOT":/src:Z -w /src \
    -v ace-go-mod:/go/pkg/mod -v ace-go-build:/root/.cache/go-build \
    -e RELEASE_INSIDE=1 -e HARDENING="$HARDENING" -e TARGETS="$TARGETS" -e UPX="${UPX:-0}" -e APP="$APP" \
    -e VERSION="$VERSION" -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" -e SIGN="${SIGN:-}" \
    "$GOIMAGE" bash scripts/release.sh --host
fi

# ---- host / inside-container: do the builds ----
export CGO_ENABLED=0 GOFLAGS=-buildvcs=false
export PATH="$(go env GOPATH 2>/dev/null)/bin:$PATH"
rm -rf dist; mkdir -p dist
LDFLAGS="-s -w -buildid= -X main.version=$VERSION"   # stripped + version-stamped

build_one(){ # <os> <arch>
  local os="$1" arch="$2" out="dist/${APP}_${os}_${arch}"; [ "$os" = windows ] && out="$out.exe"
  echo "[release] building $os/$arch  (hardening=$HARDENING, version=$VERSION)"
  case "$HARDENING" in
    none)
      GOOS="$os" GOARCH="$arch" go build -ldflags "-X main.version=$VERSION" -o "$out" ./cmd/"$APP" || return 1 ;;
    strong)
      command -v garble >/dev/null 2>&1 || { echo "[release] installing garble…"; go install mvdan.cc/garble@latest >/dev/null 2>&1 || true; }
      if command -v garble >/dev/null 2>&1; then
        GOOS="$os" GOARCH="$arch" garble -literals -tiny build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/"$APP" || return 1
      else
        echo "[release] WARN: garble unavailable — STRIPPED build (no obfuscation) for $os/$arch."
        GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/"$APP" || return 1
      fi ;;
    *) # standard
      GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags "$LDFLAGS" -o "$out" ./cmd/"$APP" || return 1 ;;
  esac
  if [ "${UPX:-0}" = 1 ]; then
    if command -v upx >/dev/null 2>&1; then upx --best --lzma "$out" >/dev/null 2>&1 || echo "[release] WARN: upx failed on $out";
    else echo "[release] WARN: UPX=1 but upx not installed — skipping packing for $out (upx is trivially reversible anyway)."; fi
  fi
  echo "[release]   -> $out"
}

rc=0
for t in $TARGETS; do
  os="${t%%/*}"; arch="${t#*/}"
  { [ -n "$os" ] && [ -n "$arch" ] && [ "$os" != "$t" ]; } || { echo "[release] bad target '$t' (want os/arch)"; rc=1; continue; }
  build_one "$os" "$arch" || { echo "[release] BUILD FAILED: $t"; rc=1; }
done
( cd dist && set -- $(ls 2>/dev/null | grep -v '^SHA256SUMS'); [ "$#" -gt 0 ] && { sha256sum "$@" 2>/dev/null || shasum -a 256 "$@" 2>/dev/null; } > SHA256SUMS ) 2>/dev/null || true
# optional signing of the checksum manifest (SIGN=minisign|cosign).
if [ -f dist/SHA256SUMS ] && [ -n "${SIGN:-}" ]; then
  case "$SIGN" in
    minisign) command -v minisign >/dev/null 2>&1 && minisign -Sm dist/SHA256SUMS ${MINISIGN_SECRET_KEY:+-s "$MINISIGN_SECRET_KEY"} >/dev/null 2>&1 \
                && echo "[release] signed dist/SHA256SUMS (minisign -> .minisig)" || echo "[release] WARN: minisign signing failed/unavailable." ;;
    cosign)   command -v cosign >/dev/null 2>&1 && cosign sign-blob --yes ${COSIGN_KEY:+--key "$COSIGN_KEY"} --output-signature dist/SHA256SUMS.sig dist/SHA256SUMS >/dev/null 2>&1 \
                && echo "[release] signed dist/SHA256SUMS (cosign -> SHA256SUMS.sig)" || echo "[release] WARN: cosign signing failed/unavailable." ;;
    *) echo "[release] WARN: unknown SIGN='$SIGN' (want minisign|cosign)." ;;
  esac
fi
echo "[release] artifacts:"; ls -lh dist 2>/dev/null | sed 's/^/  /'
echo "[release] hardening=$HARDENING  version=$VERSION  upx=${UPX:-0}  targets=$TARGETS"
{ [ "$HARDENING" = strong ] && ! command -v garble >/dev/null 2>&1; } && echo "[release] NOTE: 'strong' requested but garble missing — obfuscation was skipped; run 'ace install' or 'go install mvdan.cc/garble@latest'."
exit $rc
EOF
  chmod +x scripts/release.sh
}

# Seed .opencode/STANDARDS.md with enforceable Go best-practices (standards_keeper curates it after).
gen_go_standards() {
  mkdir -p .opencode
  [ -f .opencode/STANDARDS.md ] && return 0
  cat > .opencode/STANDARDS.md <<'EOF'
# STANDARDS — Go

Enforceable best-practices for this stack. The standards_keeper reviews every change against this and
keeps it current; the gate (ci.sh) mechanizes what it can.

## Formatting & lint
- `gofmt` is mandatory (ci.sh fails on unformatted files). `go vet` and `staticcheck` must pass clean.
- Group imports (std / external / internal); no unused imports or variables.

## Errors
- Always check returned errors; never discard one with `_ =` without a why-comment.
- Wrap with context: `fmt.Errorf("doing X: %w", err)` — preserve the chain; inspect with `errors.Is/As`.
- Libraries return errors, never `panic` (panic only for unrecoverable programmer bugs).
- No naked returns in non-trivial functions.

## Context & concurrency
- Accept `context.Context` as the first arg on any blocking / I/O / request-scoped call; honor cancellation.
- Don't store a Context in a struct. Every goroutine has an owner and a way to stop — no leaks.
- Guard shared state (mutex/channel); `go test -race` must stay green (ci.sh runs it).

## HTTP / services (api shape)
- Set server timeouts (Read/Write/Idle) — never ship the zero-value `http.Server{}`.
- Validate and bound all input; return correct status codes; never leak internal errors to clients.
- Keep `/healthz` dependency-light (liveness); add `/readyz` if readiness gates on dependencies.

## Tests
- Pick the test TYPE per scenario (don't default to a couple of asserts):
  - branchy logic / boundaries → **table-driven** with `t.Run` subtests (happy + error + edge).
  - parser / serializer / encoder / math → **property + fuzz** (`testing/quick`, or `go test -fuzz`) — assert roundtrip & invariants.
  - generated output → **golden files** (an `-update` flag writing `testdata/*.golden`, compared on normal runs).
  - `http.Handler` → **`httptest`** + assert the status/header/body contract.
  - DB / external wiring → **integration** behind a `//go:build integration` tag against an ephemeral dependency; mocks hide real bugs.
  - money / orders / webhooks → **replay/idempotency** test + assert the audit record is written.
  - auth / ownership → **authz-DENY matrix** (role × resource); the deny cases are mandatory.
  - concurrency → `go test -race` + contention/interleave cases (ci.sh runs `-race`).
- Inject the clock/network — no real sleeps or sockets in unit tests. Reuse `internal/testutil` (FakeClock, factories, the `Golden` helper) and EXTEND it; never re-roll setup per test.
- Coverage is a signal, not a target: ci.sh writes `coverage.out` and prints the total — close gaps on the changed code, never write tests just to move the number. Mutation-test high-stakes packages (`scripts/mutation.sh`, gremlins) when unsure a suite is strong.
- Tests ship in the SAME PR as the code they cover — no test-only PRs.

## Dependencies & versions
- go.mod's `go` directive is the single source of the toolchain version (Containerfile + CI follow it).
- Keep deps current; the `govulncheck` CI job must be clean. Prefer the std lib over a thin dependency.

## Hardening (shipped binaries)
- Releases are fully-static (CGO_ENABLED=0), stripped; `strong` adds garble. Never embed secrets in a
  binary — they are recoverable. See ARCHITECTURE.md.
EOF
}

# ---------------------------------------------------------------- Go stack (shape-aware)
# shape -> deploy kind (service|artifact|none) and whether it produces a binary.
_go_deploy_kind() { case "$1" in cli|cli-web) echo artifact ;; library) echo none ;; *) echo service ;; esac; }   # api,worker -> service
_go_binary_shape() { [ "$1" != library ]; }                                                                       # api/cli/worker build a binary
_go_pkgname() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }                                 # valid Go package identifier

# Seed internal/testutil — SHARED test helpers (fake clock + golden compare). Tests reuse + extend these
# instead of re-rolling setup; standards_keeper/test_engineer point here. Compiles under go build/vet.
gen_go_testutil() {
  mkdir -p internal/testutil
  cat > internal/testutil/testutil.go <<'EOF'
// Package testutil holds SHARED test helpers — reuse and extend these instead of re-rolling setup
// in each test (a fake clock, golden-file compare; add your factories/builders here too).
package testutil

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// FakeClock is a deterministic clock — inject its Now instead of time.Now so tests never sleep or flake.
type FakeClock struct{ T time.Time }

// NewFakeClock starts at a fixed instant; Advance to move it.
func NewFakeClock() *FakeClock { return &FakeClock{T: time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC)} }

// Now returns the current fake time.
func (c *FakeClock) Now() time.Time { return c.T }

// Advance moves the fake clock forward by d.
func (c *FakeClock) Advance(d time.Duration) { c.T = c.T.Add(d) }

// update lets `go test -run TestX -update` (re)write golden files after an INTENTIONAL output change.
var update = flag.Bool("update", false, "update golden files in testdata/")

// Golden compares got against testdata/<name>.golden; with -update it rewrites the file instead.
// Use for generated output (rendered text, configs, serialized payloads).
func Golden(t *testing.T, name string, got []byte) {
	t.Helper()
	path := filepath.Join("testdata", name+".golden")
	if *update {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatalf("mkdir testdata: %v", err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s (first run: go test -run %s -update): %v", path, t.Name(), err)
	}
	if !bytes.Equal(got, want) {
		t.Errorf("%s: output mismatch (run with -update to accept):\n got: %q\nwant: %q", name, got, want)
	}
}
EOF
  mkdir -p scripts
  cat > scripts/mutation.sh <<'EOF'
#!/usr/bin/env bash
# Opt-in mutation testing — measures whether tests actually CATCH bugs (a stronger signal than coverage).
# Run on high-stakes packages when unsure a suite is real. NOT part of ci.sh (slow). Needs 'gremlins':
#   go install github.com/go-gremlins/gremlins/cmd/gremlins@latest   (then add $(go env GOPATH)/bin to PATH)
# Usage: ./scripts/mutation.sh [./path/...]   (default: ./...)
set -uo pipefail
cd "$(dirname "$0")/.."
command -v gremlins >/dev/null 2>&1 || { echo "gremlins not installed — see the header of this script."; exit 127; }
exec gremlins unleash "${@:-./...}"
EOF
  chmod +x scripts/mutation.sh
}

gen_go() {
  local name="$1" shape="${PROFILE_SHAPE:-api}" digest; digest="$(pin_image "golang:$ACE_GO_VERSION")"
  cat > .gitignore <<'EOF'
/dist/
/bin/
*.test
*.out
coverage.*
.env
.env.*
!.env.example
.DS_Store
# ── ACE loop transients — never commit (keeps `git status` clean so agents don't waste turns each step) ──
.serena/
.opencode/.agents
.opencode/.oppid
.opencode/.step-budget
.opencode/.timedout
.opencode/.rathole
.opencode/.container-green
.opencode/.harvested-warnings
.opencode/.objectives-synced
.opencode/last-run.log
.opencode/ci-failure.log
.opencode/ci-build.log
.opencode/loop-state.env
.opencode/metrics.csv
.opencode/run-summary.txt
.opencode/token-report.md
.opencode/.session-id
.opencode/.kanban-map
.opencode/approvals/
.opencode/HANDOVER.md
.opencode/vps-verify-report.md
.opencode/cache/
.opencode/reanalyze/
*.orig
*.rej
EOF
  printf '/%s\n' "$name" >> .gitignore   # the built binary (go build ./cmd/<name> drops it at repo root)
  cat > go.mod <<EOF
module $name

go $ACE_GO_VERSION
EOF
  cat > .dockerignore <<'EOF'
.git
dist
bin
.serena
# runtime config is injected by the deploy (--env-file), never baked into a layer
.env
.env.*
!.env.example
brownfield
EOF
  case "$shape" in
    cli|cli-web) gen_go_skel_cli "$name" "$digest" ;;
    worker)      gen_go_skel_worker "$name" "$digest" ;;
    library)     gen_go_skel_library "$name" "$digest" ;;
    *)           gen_go_skel_api "$name" "$digest" ;;
  esac
  cat > ci.sh <<'EOF'
#!/usr/bin/env bash
# Tiered: ./ci.sh = fast host gate; ./ci.sh --container = full VPS parity.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
MODE="fast"; { [ "${1:-}" = "--container" ] || [ "${CONTAINER:-}" = "1" ]; } && MODE="container"
[ "${1:-}" = "--launch" ] && MODE="launch"   # pre-promotion launch-readiness gate (see the launch_readiness_reviewer agent)
[ "$MODE" = container ] && [ ! -f Containerfile ] && { echo "[ci] no Containerfile — running the host gate."; MODE="fast"; }
export CGO_ENABLED=0 CI=1
fail=0; section(){ printf '\n== %s ==\n' "$1"; }
# ── ONE exclusion list for EVERY recursive scan in this gate ────────────────────────────────────────
# Trees this project does not own: dependency installs (node_modules/, .venv/, vendor/), build output,
# and brownfield/ — code adopted by `ace import`, which PROMISES it is "excluded from the gate". It was
# not: the RLS, migration-safety and log-hygiene sections below scanned it anyway, emitted RED [blocker]
# and set fail=1, and .githooks/pre-commit then blocked EVERY commit over somebody else's legacy code.
# Add paths HERE, never inline, so the next section added to this file cannot forget one.
EXCL='/(node_modules|dist|build|\.next|out|vendor|\.git|\.serena|\.venv|venv|brownfield)/'
# grep -r has no regex-based --exclude-dir, so these two wrappers apply $EXCL to a recursive grep:
#   xgrep_l -> the matching FILE list minus excluded paths   ·   xgrep_q -> quiet test (true iff a match)
# Both force -l so the pipe filters PATHS, and both are judged on their TEXT, never on $?: grep returns 1
# for "no match" and xargs returns 123 if any batch did, neither of which means the check failed.
xgrep_l(){ grep -rIl "$@" 2>/dev/null | grep -vE "$EXCL"; }
xgrep_q(){ xgrep_l "$@" | grep -q .; }
# STRICT security gate: an unattended PUBLIC self-merge has no human to catch a "major" security gap, so the
# security [major] warnings below become HARD BLOCKERS (the orchestrator's AUTO-ACCEPT SAFETY RAIL, made
# mechanical). ON when the profile audience is public/customer/enterprise AND auto_merge is on; force either
# way with ACE_STRICT_SECURITY=1 / =0. (Heuristic greps → a false positive blocks a merge; that is the
# fail-closed trade for shipping to real users with no reviewer. Set ACE_STRICT_SECURITY=0 to opt a run out.)
_strict=0
_paud="$(sed -n 's/^[[:space:]]*audience:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
_pam="$(sed -n 's/^[[:space:]]*auto_merge:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
case "$_paud" in oss-public|end-customer|enterprise) case "$_pam" in true|yes|1) _strict=1 ;; esac ;; esac
case "${ACE_STRICT_SECURITY:-}" in 1) _strict=1 ;; 0) _strict=0 ;; esac
_secwarn(){ if [ "$_strict" = 1 ]; then echo "RED [blocker]: $* [strict: public + auto_merge, no human reviewer]"; fail=1; else echo "WARN [major]: $*"; fi; }
if [ "$MODE" = launch ]; then
  section "Launch-readiness (mechanical pre-promotion gate — the launch_readiness_reviewer agent does the judgment)"
  # Composition-aware (like the stack-conditional gates above): only require the DB restore-drill when the
  # project HAS a database, and rollback/SLO/runbook only for a deployed service (deploy_kind=service). A
  # no-DB CLI / library is not NO-GO'd for a backup it cannot have.
  _hasdb=0
  { [ -f package.json ] && grep -qiE '"(pg|postgres|prisma|@prisma/client|drizzle-orm|mysql2?|mongoose|mongodb|better-sqlite3|sqlite3|sequelize|typeorm|knex|kysely|pg-promise|@libsql/client|@neondatabase/serverless|@planetscale/database|@vercel/postgres)"' package.json; } && _hasdb=1
  { [ -f go.mod ] && grep -qiE 'lib/pq|jackc/pgx|jackc/pgconn|go-sql-driver|mattn/go-sqlite3|modernc\.org/sqlite|glebarez/sqlite|gorm\.io|entgo\.io/ent|uptrace/bun|jmoiron/sqlx|mongo-driver' go.mod; } && _hasdb=1
  grep -qiE 'psycopg|sqlalchemy|sqlmodel|asyncpg|pymysql|mysqlclient|mariadb|aiosqlite|pymongo|django|tortoise|peewee|alembic' requirements*.txt pyproject.toml 2>/dev/null && _hasdb=1
  { ls prisma/schema.prisma migrations/*.sql db/migrations/*.sql migrations/0*.py */migrations/0*.py alembic/versions/*.py 2>/dev/null | grep -q .; } && _hasdb=1
  _svc=0; [ "$(sed -n 's/^[[:space:]]*deploy_kind:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)" = service ] && _svc=1
  if [ "$_hasdb" = 1 ]; then
    if [ -f ops/restore-drill.result ] && grep -qiE 'rows_verified=[1-9]|status=(verified|pass|ok)' ops/restore-drill.result 2>/dev/null; then echo "tested restore: recorded"; else echo "NO-GO [blocker]: ops/restore-drill.result missing or shows no verified restore (needs rows_verified / RPO / RTO) — a backup is not done until a restore has been run: ./ops/restore-drill.sh"; fail=1; fi
  else echo "no database detected — restore-drill not required"; fi
  if [ "$_svc" = 1 ]; then
    [ -f ops/rollback.md ] && echo "present: ops/rollback.md" || { echo "NO-GO [blocker]: ops/rollback.md missing — document the tested revert for the last deploy"; fail=1; }
    for a in ops/runbook.md ops/slo.md LAUNCH-READINESS.md; do [ -f "$a" ] && echo "present: $a" || echo "WARN [major]: missing $a (scaffold it; track to verified in LAUNCH-READINESS.md)"; done
  else echo "deploy_kind != service (artifact/library/none) — rollback/SLO/runbook not required"; fi
  [ "$fail" = 0 ] && { echo -e "\nLAUNCH GREEN (mechanical checks pass — now run the launch_readiness_reviewer agent for the full GO/NO-GO)"; exit 0; } || { echo -e "\nLAUNCH RED — NO-GO (fix the [blocker] artifacts above)"; exit 1; }
fi
# The OWNED Go package list — `./...` would build/vet/test/staticcheck brownfield/ too, but `ace import`
# PROMISES imported code is excluded from the gate, and a legacy tree that does not compile made EVERY
# commit RED. Resolved once here and reused by sections [1] and [3]. Unquoted on use is deliberate and
# safe: a Go import path cannot contain whitespace. ($EXCL is for grep -r; go needs package paths.)
# `go list` FAILING and `go list` returning NOTHING are different facts and must be judged separately.
# This line used to be `go list ./... 2>/dev/null | …`: the rc was thrown away with the diagnostics, so a
# module that did not even parse (bad go.mod, unavailable toolchain, broken `replace`, run outside the
# module) produced an EMPTY list, took the "no packages — skipping" branch, and the gate printed CI GREEN
# on a tree that cannot compile. Keep the rc AND the stderr; an empty list is only believed when rc=0.
_golist_rc=0; : > /tmp/ci-golist.err
_golist_out=$(go list ./... 2>/tmp/ci-golist.err) || _golist_rc=$?
_gopkgs=$(printf '%s\n' "$_golist_out" | grep -v '/brownfield' || true)
section "[1/13] Build + test ($MODE)"
if [ "$_golist_rc" != 0 ]; then
  # Deliberately RED in container MODE too: the package list is unusable either way, and a module that
  # does not resolve is a real failure — not something to hand to the build and hope it notices.
  echo "RED: 'go list ./...' failed (rc=$_golist_rc) — the module does not resolve, so build/vet/test cannot be judged:"
  cat /tmp/ci-golist.err
  fail=1
elif [ "$MODE" = container ]; then
  if podman build --force-rm --target test -t localhost/ci:dev -f Containerfile .; then _rc=0; else _rc=1; fi
  podman image prune -f >/dev/null 2>&1 || true   # reclaim this build's dangling layers
  [ "$_rc" = 0 ] || { echo RED; exit 1; }
elif [ -z "$_gopkgs" ]; then
  echo "(no Go packages outside brownfield/ — skipping build/vet/test)"
else
  go build $_gopkgs || fail=1
  go vet $_gopkgs || fail=1
  # -race needs cgo, but builds are CGO_ENABLED=0 (fully static) — so enable cgo for the race test ONLY
  # when a C compiler is present (else 'go test -race' errors "requires cgo"); otherwise plain tests.
  # -timeout 120s: a deadlocked/flaky concurrency test surfaces as RED in 2min, not the 10-min default
  # (a scheduler-dependent hang once merged silently and poisoned every downstream branch). GO_TEST_COUNT>1
  # (set by the --container merge gate) re-runs to expose that flakiness before it can merge.
  _gtc="${GO_TEST_COUNT:-1}"
  if command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1; then CGO_ENABLED=1 go test $_gopkgs -race -timeout 120s -count="$_gtc" -coverprofile=coverage.out -covermode=atomic || fail=1
  else go test $_gopkgs -timeout 120s -count="$_gtc" -coverprofile=coverage.out || fail=1; fi
  # coverage is a SIGNAL, not a gate (no blanket % target — that just invites gaming): print the total.
  [ -f coverage.out ] && go tool cover -func=coverage.out 2>/dev/null | tail -1
fi
section "[2/13] Format — gofmt"
# -print0 | xargs -0: an unquoted $(find …) word-split spaced paths into bogus names. And gofmt's STDERR
# is KEPT: it was 2>/dev/null'd, so a gofmt that could not parse a file printed nothing to stdout and the
# section read "clean" — a real failure reported as a pass. gofmt -l exits 0 for merely-unformatted files,
# so a non-zero rc (or any stderr) means gofmt itself failed and must be RED.
: > /tmp/ci-gofmt.log
unf=$(find . -name '*.go' -type f -print0 2>/dev/null | grep -zvE "$EXCL" | xargs -0 -r gofmt -l 2>/tmp/ci-gofmt.log)
[ -n "$unf" ] && { echo "RED: gofmt — run 'gofmt -w .':"; echo "$unf"; fail=1; }
[ -s /tmp/ci-gofmt.log ] && { echo "RED: gofmt FAILED TO RUN (this used to be silent and read as clean):"; cat /tmp/ci-gofmt.log; fail=1; }
section "[3/13] staticcheck (if installed)"
if ! command -v staticcheck >/dev/null 2>&1; then echo "(staticcheck not on PATH — 'ace install' adds it; skipping)"
elif [ "$_golist_rc" != 0 ]; then echo "(skipped — 'go list ./...' failed; already RED in [1/13])"   # skip, but the run is NOT green
elif [ -z "$_gopkgs" ]; then echo "(no Go packages outside brownfield/ — skipping staticcheck)"
else staticcheck $_gopkgs || fail=1; fi
section "[4/13] Env integrity — os.Getenv vars declared in .env.example"
declared=$(grep -oP '^[A-Z0-9_]+(?==)' .env.example 2>/dev/null | sort -u)
used=$(find . -name '*.go' -type f -print0 2>/dev/null | grep -zvE "$EXCL" | xargs -0 -r grep -hoP 'os\.Getenv\("\K[A-Z0-9_]+' 2>/dev/null | sort -u)
miss=$(comm -23 <(printf '%s\n' "$used"|sed '/^$/d') <(printf '%s\n' "$declared"|sed '/^$/d'))
[ -n "$miss" ] && { echo "RED: undeclared env vars (add to .env.example):"; echo "$miss"; fail=1; }
section "[5/13] No stubs / placeholders (depth gate)"
stub=$(grep -rInE '(TODO|FIXME|XXX)|not[ _]implemented|panic\("?TODO' --include='*.go' cmd internal pkg 2>/dev/null | grep -vE "$EXCL" | head -20)
[ -n "$stub" ] && { echo "RED: unfinished stubs/markers — complete them (or move notes to .opencode/specs/):"; echo "$stub"; fail=1; }
section "[6/13] Client-bundle secret scan (leaked provider/service keys)"
# Scan the BUILT client bundle only (dist/build/.next/public) for shipped provider/service keys — never
# source, never server-only .env. Add literal substrings to .ci-secretignore to suppress false positives.
csec_dirs=""; for d in dist build .next public; do [ -d "$d" ] && csec_dirs="$csec_dirs $d"; done
if [ -n "$csec_dirs" ]; then
  csec_re='sk_live_|sk_test_|service_role|SUPABASE_SERVICE_ROLE|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9]{36}|sk-ant-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9_-]{20,}|OPENAI_API_KEY|ANTHROPIC_API_KEY'
  csec_hits=$(grep -rInE "$csec_re" $csec_dirs 2>/dev/null || true)
  if [ -n "$csec_hits" ] && [ -s .ci-secretignore ]; then csec_hits=$(printf '%s\n' "$csec_hits" | grep -vFf <(grep -v '^$' .ci-secretignore) || true); fi
  if [ -n "$csec_hits" ]; then echo "RED [blocker]: secret/credential shipped in client bundle — move it to server-only env:"; printf '%s\n' "$csec_hits" | head -20; fail=1; else echo "(client bundle clean)"; fi
else echo "(no client bundle dir — skipping)"; fi
section "[7/13] Row-Level Security — RLS enabled per table (Postgres/Supabase)"
# Stack-conditional: runs only when SQL migrations declare CREATE TABLE; clean no-op otherwise.
# Resolve the OWNED .sql set once through $EXCL — a brownfield/ or vendored migration is not ours to
# police, and it used to RED-block every commit here. Every lookup below reuses this one list, and it is
# ALL owned .sql (not just the CREATE TABLE files) because RLS is usually enabled in a LATER migration.
sql_all=$(find . -name '*.sql' -type f 2>/dev/null | grep -vE "$EXCL" || true)
_sqlgrep(){ printf '%s\n' "$sql_all" | tr '\n' '\0' | xargs -0 -r grep "$@" 2>/dev/null; }   # judge the OUTPUT, never xargs' rc
if [ -n "$sql_all" ] && _sqlgrep -lIE 'CREATE TABLE' | grep -q .; then
  rls_tables=$(_sqlgrep -hoIE 'CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?[A-Za-z0-9_]+' | sed -E 's/.*CREATE TABLE( IF NOT EXISTS)? +(public\.)?"?//; s/".*//' | sort -u)
  for t in $rls_tables; do
    if ! _sqlgrep -lIE "ALTER TABLE +(public\.)?\"?${t}\"? +ENABLE ROW LEVEL SECURITY" | grep -q .; then
      echo "RED [blocker]: table '${t}' created without ENABLE ROW LEVEL SECURITY"; fail=1
    elif ! _sqlgrep -lIE "CREATE POLICY .*ON +(public\.)?\"?${t}\"?" | grep -q .; then
      _secwarn "table '${t}' has RLS enabled but no CREATE POLICY (deny-all — usually unintended)"
    fi
  done
else echo "(no SQL CREATE TABLE — skipping RLS check)"; fi
section "[8/13] LLM call-site guards (cost / abuse)"
# Stack-conditional: runs only when an LLM SDK is a dependency; heuristic [major] warnings, never a hard fail.
if grep -rIqE 'openai|anthropic|langchain|@ai-sdk|llamaindex|@google/generative-ai' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null; then
  llm_calls=$(grep -rIlE '\.chat\.completions\.create|\.messages\.create|\.completions\.create|\.responses\.create|generateText|streamText|generateObject|\.GenerateContent|CreateChatCompletion|CreateMessage|CreateCompletion' --include='*.go' --include='*.ts' --include='*.js' . 2>/dev/null | grep -vE "$EXCL" | head -50 || true)
  if [ -n "$llm_calls" ]; then
    printf '%s\n' "$llm_calls" | xargs grep -lIE 'max_tokens|maxOutputTokens|max_output_tokens|maxTokens|MaxTokens' 2>/dev/null | grep -q . || _secwarn "LLM call site(s) with no visible token cap (max_tokens/maxOutputTokens) — uncapped output is a cost + DoS risk"
    xgrep_q -iE 'budget|rate.?limit|max.?iteration|max.?step|max.?turn' --include='*.go' --include='*.ts' --include='*.js' . || _secwarn "no visible per-user/session budget, rate-limit, or agent max-iteration cap near LLM calls"
  else echo "(LLM SDK present but no direct call site found — skipping)"; fi
else echo "(no LLM SDK dependency — skipping)"; fi
section "[9/13] Webhook handler integrity (payment/event webhooks)"
# Stack-conditional: runs only when a MONEY webhook handler is present; clean no-op otherwise.
wh_files=$( { grep -rIliE 'webhook|constructEvent|Stripe-Signature|whsec_' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f -iname '*webhook*' 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -50 )
money_wh=""; [ -n "$wh_files" ] && money_wh=$(printf '%s\n' "$wh_files" | xargs grep -lIiE 'stripe|paypal|braintree|paddle|lemonsqueez|razorpay|payment|charge|subscription|checkout|billing' 2>/dev/null || true)
if [ -n "$money_wh" ]; then
  wh_sig='constructEvent|verifyHeader|verifySignature|Stripe-Signature|X-Hub-Signature|createHmac|compare_digest|hmac\.new|ConstructEvent|ValidateSignature|WebhookSignature'
  if printf '%s\n' "$money_wh" | xargs grep -lIE "$wh_sig" 2>/dev/null | grep -q .; then
    echo "(webhook signature verification present)"
    wh_dedupe='event[._]?id|eventId|idempotenc|processed|dedup|on conflict|already|\bseen\b'
    printf '%s\n' "$money_wh" | xargs grep -lIiE "$wh_dedupe" 2>/dev/null | grep -q . || _secwarn "money webhook has no visible event-ID dedupe (at-least-once delivery + multi-day retries can double-process)"
  else
    echo "RED [blocker]: money webhook handler with NO signature verification — forgeable 'payment succeeded':"; printf '%s\n' "$money_wh" | head -10; fail=1
  fi
else echo "(no payment webhook handler — skipping)"; fi
section "[10/13] Auth & session edge cases (reset tokens / enumeration)"
# Stack-conditional: runs only when auth routes are present; heuristic [major] warnings, never a hard fail.
auth_files=$( { grep -rIliE 'password|reset[_-]?token|forgot|sign[_-]?in|next-auth|passport|lucia|bcrypt|argon2' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null; find . -type f \( -iname '*auth*' -o -iname '*login*' -o -iname '*password*' \) 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go)$'; } | grep -vE "$EXCL" | grep -vE '\.(test|spec)\.|/(__tests__|tests?)/' | sort -u | head -80 )
if [ -n "$auth_files" ]; then
  if printf '%s\n' "$auth_files" | xargs grep -lIiE 'no such (user|account)|(email|user|account) not found|does ?n.?t exist|no account (with|found)' 2>/dev/null | grep -q .; then
    _secwarn "an auth response reveals whether an account exists (enumeration) — return a GENERIC message for existing AND non-existing accounts"
  fi
  reset_files=$(printf '%s\n' "$auth_files" | xargs grep -lIiE 'reset[_-]?token|password[_-]?reset|forgot' 2>/dev/null || true)
  if [ -n "$reset_files" ]; then
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'hash|bcrypt|argon2|scrypt|sha256|createhash|digest' 2>/dev/null | grep -q . || _secwarn "reset token may be stored in plaintext — store only its HASH and compare hashes"
    printf '%s\n' "$reset_files" | xargs grep -lIiE 'expir|ttl|valid[_-]?until|used|consumed|redeemed|single[_-]?use' 2>/dev/null | grep -q . || _secwarn "reset token has no visible expiry or single-use flag — make it time-limited AND single-use"
  fi
else echo "(no auth routes — skipping)"; fi
section "[11/13] Migration safety (expand-contract)"
# Stack-conditional: runs only when SQL migration files are present; clean no-op otherwise.
mig_files=$(grep -rIlE 'ALTER TABLE|DROP TABLE|DROP COLUMN|CREATE TABLE|RENAME' --include='*.sql' . 2>/dev/null | grep -vE "$EXCL" | head -80 || true)
if [ -n "$mig_files" ]; then
  while IFS= read -r mf; do [ -n "$mf" ] || continue
    if grep -IiqE 'DROP (TABLE|COLUMN)|RENAME (TO|COLUMN)|ALTER COLUMN[^;]*DROP' "$mf" 2>/dev/null; then
      grep -IiqE -e '--[[:space:]]*down\b|irreversible[^a-z]{0,4}approved|expand.?contract' "$mf" 2>/dev/null || { echo "RED [blocker]: $mf — destructive schema op (DROP/RENAME) with no reverse. Use expand-contract (add new → backfill → switch reads → drop LATER, as SEPARATE changes); if intentional, add a '-- down' reverse (a SQL comment) or an '-- irreversible: approved' marker."; fail=1; }
    fi
    if grep -IiE 'ADD COLUMN[^;]*NOT NULL' "$mf" 2>/dev/null | grep -qviE 'DEFAULT|GENERATED'; then
      echo "RED [blocker]: $mf — ADD COLUMN ... NOT NULL without a DEFAULT will fail on existing rows; add a DEFAULT or backfill in phases."; fail=1
    fi
  done <<< "$mig_files"
else echo "(no SQL migrations — skipping)"; fi
section "[12/13] Observability (structured logs, health, log hygiene)"
# Log hygiene runs on any source (a secret VALUE in a log is a [blocker]); server checks gate on a server app.
loghy=$(grep -rIinE '(console\.(log|info|warn|error|debug)|logger?\.[a-zA-Z]+|log\.(Info|Print|Printf|Debug|Error|Warn|Fatal)|logging\.(info|debug|warning|error)|print|println|fmt\.Print[a-z]*)[[:space:]]*\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . 2>/dev/null | grep -vE "${EXCL}|\.(test|spec)\." | grep -IiE '\.(password|passwd|secret|token|authorization|ssn|cvv|api[_-]?key|credit[_-]?card)\b|[$][{][^}]*(password|passwd|secret|token|ssn|cvv)|[{][[:space:]]*(password|passwd|secret|token|ssn|cvv)[[:space:]]*[,}]|[(][[:space:]]*(password|passwd|secret|token|ssn)[[:space:]]*[),]' | head -20 || true)
[ -n "$loghy" ] && { echo "RED [blocker]: a secret/PII VALUE appears in a log statement — never log passwords/tokens/secrets/PII:"; printf '%s\n' "$loghy" | head -10; fail=1; }
if xgrep_q -E '\.listen\(|createServer|app\.run\(|http\.ListenAndServe|uvicorn|FastAPI|express\(|fastify\(|gin\.(New|Default)|Flask\(' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' .; then
  xgrep_q -iE '/health|/healthz|/ready|/readyz|actuator/health|livenessProbe' . || echo "WARN [major]: no /health or /ready endpoint found — add liveness/readiness probes for a server app"
  grep -rIqiE 'winston|pino|bunyan|structlog|loguru|zap|logrus|zerolog|log/slog|slog\.' package.json requirements.txt pyproject.toml go.mod go.sum 2>/dev/null || echo "WARN [major]: no structured logger detected — use a structured logger (not raw console.log/print) in request paths"
  xgrep_q -iE 'correlation|request[_-]?id|x-request-id|traceparent|trace[_-]?id' --include='*.ts' --include='*.tsx' --include='*.js' --include='*.mjs' --include='*.py' --include='*.go' . || echo "WARN [major]: no request/correlation-ID found — attach one to every log line for traceability"
else echo "(not a server app — health/correlation checks skipped; log hygiene ran)"; fi
section "[13/13] Supply chain (deterministic installs, SBOM, pinned actions)"
if [ -f Containerfile ] || [ -d .github/workflows ]; then
  ndi=$(grep -rIinE '(npm|pnpm|yarn) +install' Containerfile .github/workflows 2>/dev/null | grep -viE 'npm ci|--frozen-lockfile|--ignore-scripts' | head -10 || true)
  [ -n "$ndi" ] && { echo "WARN [major]: non-deterministic install in a build — use 'npm ci' / 'pnpm i --frozen-lockfile' / 'pip install --require-hashes':"; printf '%s\n' "$ndi" | head -5; }
  fl=$(grep -rInE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@' .github/workflows 2>/dev/null | grep -vE 'uses:[[:space:]]*actions/' | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' | head -10 || true)
  [ -n "$fl" ] && { echo "WARN [major]: third-party GitHub Action pinned to a floating tag — pin by full commit SHA (uses: org/action@<40-hex-sha> # vX):"; printf '%s\n' "$fl" | head -5; }
  grep -rIqiE 'cyclonedx|spdx|sbom|syft|trivy' package.json Containerfile .github/workflows 2>/dev/null || echo "WARN [major]: no SBOM (CycloneDX/SPDX) generated — emit one as a build artifact for dependency transparency"
else echo "(no Containerfile or CI workflow — skipping supply-chain checks)"; fi
[ "$fail" = 0 ] && { echo -e "\nCI GREEN ($MODE)"; exit 0; } || { echo -e "\nCI RED ($MODE)"; exit 1; }
EOF
  chmod +x ci.sh
  _go_binary_shape "$shape" && gen_go_release   # scripts/release.sh (hardened cross-compile) — binary shapes only
  # Project-scoped opencode config: add the OFFICIAL Go MCP (gopls, v0.20+) so the agents navigate Go
  # with go_context / go_references / go_diagnostics / go_vulncheck / go_rename_symbol. opencode MERGES
  # this with the global gitnexus/serena/context7 servers; it only loads in this (Go) project.
  cat > opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "gopls": { "type": "local", "command": ["gopls", "mcp"], "enabled": true }
  }
}
EOF
  local _shdesc
  case "$shape" in
    cli|cli-web) _shdesc="CLI tool (flag-based); ships a hardened static binary via 'ace release'." ;;
    worker)      _shdesc="Background worker/daemon (signal-graceful loop); runs as a container service." ;;
    library)     _shdesc="Importable Go module (no main); consumed by other code, no deploy." ;;
    *)           _shdesc="net/http API with /healthz; container-deployed + a hardened static binary." ;;
  esac
  gen_project_agents "$name" "Go ($shape). $_shdesc Fully-static (CGO_ENABLED=0); built/tested in a pinned golang container. Gate: ./ci.sh (host) and ./ci.sh --container (parity). Navigate Go via the OFFICIAL gopls MCP (go_context/go_references/go_diagnostics/go_vulncheck) + Serena. See .opencode/profile.yaml + ARCHITECTURE.md + .opencode/STANDARDS.md."
  ensure_agents_arch_pointer
  gen_go_standards
  gen_go_testutil
}

# ---- Go shape skeletons (each writes .env.example, the entrypoint/package, internal logic + test, Containerfile) ----
gen_go_skel_api() {
  local name="$1" digest="$2"
  printf '# Declared env vars (ci.sh checks os.Getenv usage against this file).\nPORT=3000\n' > .env.example
  mkdir -p "cmd/$name" internal/server
  cat > "cmd/$name/main.go" <<EOF
// Command $name starts the HTTP service.
package main

import (
	"log"
	"net/http"
	"os"

	"$name/internal/server"
)

// version is stamped at release time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "3000"
	}
	log.Printf("$name %s listening on :%s", version, port)
	if err := http.ListenAndServe(":"+port, server.New()); err != nil {
		log.Fatal(err)
	}
}
EOF
  cat > internal/server/server.go <<'EOF'
// Package server wires the service's HTTP handlers.
package server

import "net/http"

// New returns the application's HTTP handler.
func New() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("up\n"))
	})
	return mux
}
EOF
  cat > internal/server/server_test.go <<'EOF'
package server

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthz(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	New().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/healthz = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestRoot(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	New().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/ = %d, want %d", rec.Code, http.StatusOK)
	}
}
EOF
  cat > Containerfile <<EOF
# Multi-stage: build a fully-static binary, test it, ship it on distroless (runs everywhere).
FROM $digest AS build
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod ./
# COPY go.sum ./   # add once you have dependencies
RUN go mod download || true
COPY . .
RUN go build -trimpath -ldflags "-s -w" -o /out/app ./cmd/$name
FROM build AS test
RUN go vet ./... && go test ./... -timeout 120s -count=2
FROM gcr.io/distroless/static:nonroot AS final
WORKDIR /
COPY --from=build /out/app /app
EXPOSE 3000
ENTRYPOINT ["/app"]
EOF
}

gen_go_skel_cli() {
  local name="$1" digest="$2"
  printf '# Declared env vars (ci.sh checks os.Getenv usage against this file).\n' > .env.example
  mkdir -p "cmd/$name"
  cat > "cmd/$name/main.go" <<EOF
// Command $name is a command-line tool.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

// version is stamped at release time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	showVersion := flag.Bool("version", false, "print version and exit")
	name := flag.String("name", "world", "who to greet")
	flag.Parse()
	if *showVersion {
		fmt.Println("$name", version)
		return
	}
	if err := run(os.Stdout, *name); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// run holds the tool's logic, writing to w (testable without touching os.Stdout).
func run(w io.Writer, name string) error {
	_, err := fmt.Fprintf(w, "hello, %s\\n", name)
	return err
}
EOF
  cat > "cmd/$name/main_test.go" <<'EOF'
package main

import (
	"bytes"
	"testing"
)

func TestRun(t *testing.T) {
	var buf bytes.Buffer
	if err := run(&buf, "ace"); err != nil {
		t.Fatalf("run: %v", err)
	}
	if got, want := buf.String(), "hello, ace\n"; got != want {
		t.Fatalf("run() = %q, want %q", got, want)
	}
}
EOF
  cat > Containerfile <<EOF
# CLI: build + test in a pinned container (the shippable artifact is built by scripts/release.sh).
FROM $digest AS build
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN go build -trimpath -ldflags "-s -w" -o /out/app ./cmd/$name
FROM build AS test
RUN go vet ./... && go test ./... -timeout 120s -count=2
EOF
}

gen_go_skel_worker() {
  local name="$1" digest="$2"
  printf '# Declared env vars (ci.sh checks os.Getenv usage against this file).\n' > .env.example
  mkdir -p "cmd/$name" internal/worker
  cat > "cmd/$name/main.go" <<EOF
// Command $name runs the background worker until it receives SIGINT/SIGTERM.
package main

import (
	"context"
	"log"
	"os/signal"
	"syscall"
	"time"

	"$name/internal/worker"
)

// version is stamped at release time via -ldflags "-X main.version=...".
var version = "dev"

func main() {
	log.Printf("$name %s starting", version)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := worker.New().Run(ctx, 5*time.Second); err != nil {
		log.Fatal(err)
	}
	log.Printf("$name stopped cleanly")
}
EOF
  cat > internal/worker/worker.go <<'EOF'
// Package worker runs the background processing loop.
package worker

import (
	"context"
	"log"
	"time"
)

// Worker performs the service's background job on a fixed interval.
type Worker struct{}

// New returns a Worker.
func New() *Worker { return &Worker{} }

// Run ticks every interval until ctx is cancelled, then returns.
func (wk *Worker) Run(ctx context.Context, interval time.Duration) error {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
			if err := wk.tick(ctx); err != nil {
				log.Printf("tick: %v", err)
			}
		}
	}
}

// tick does one unit of work. Replace the body with the worker's real job.
func (wk *Worker) tick(_ context.Context) error {
	return nil
}
EOF
  cat > internal/worker/worker_test.go <<'EOF'
package worker

import (
	"context"
	"testing"
	"time"
)

func TestRunStopsOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := New().Run(ctx, time.Millisecond); err != nil {
		t.Fatalf("Run: %v", err)
	}
}
EOF
  cat > Containerfile <<EOF
# Worker: build a static binary, test it, run it on distroless (no HTTP port; liveness = container running).
FROM $digest AS build
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod ./
RUN go mod download || true
COPY . .
RUN go build -trimpath -ldflags "-s -w" -o /out/app ./cmd/$name
FROM build AS test
RUN go vet ./... && go test ./... -timeout 120s -count=2
FROM gcr.io/distroless/static:nonroot AS final
WORKDIR /
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
EOF
}

gen_go_skel_library() {
  local name="$1" digest="$2" pkg; pkg="$(_go_pkgname "$name")"
  printf '# Declared env vars (ci.sh checks os.Getenv usage against this file).\n' > .env.example
  mkdir -p "$pkg"
  cat > "$pkg/$pkg.go" <<EOF
// Package $pkg is the library's public API.
package $pkg

// Add returns a + b. Replace with the library's real surface.
func Add(a, b int) int {
	return a + b
}
EOF
  cat > "$pkg/${pkg}_test.go" <<EOF
package $pkg

import "testing"

func TestAdd(t *testing.T) {
	if got := Add(2, 3); got != 5 {
		t.Fatalf("Add(2,3) = %d, want 5", got)
	}
}
EOF
  cat > Containerfile <<EOF
# Library: build + test in a pinned container (no binary, no service).
FROM $digest AS build
WORKDIR /src
ENV CGO_ENABLED=0
COPY go.mod ./
RUN go mod download || true
COPY . .
FROM build AS test
RUN go vet ./... && go build ./... && go test ./... -timeout 120s -count=2
EOF
}

# ace release — build hardened static binaries locally, OR `ace release --tag vX.Y.Z` to actually SHIP them.
# Why --tag matters: the generated CI release job only fires on a pushed `v*` tag, and nothing else in ACE
# ever creates one — so without this, `deploy_kind: artifact` projects build to dist/ but never publish.
release_run() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$root" || return 1
  # `--tag` NEVER arrives positionally: ace:289 consumes it into ACE_RELEASE_TAG (exported) and shifts, and
  # both callers (ace:389 passes only $ACE_ARG/--host, menu.sh:329 passes nothing) can therefore never hand
  # us a literal "--tag". So the flag is detected purely through the env var.
  # Test whether the var is SET, not merely non-empty: `ace release --tag` with the value missing exports it
  # EMPTY, and the old -n test made that silently fall through to the LOCAL BUILD path — the user asked to
  # ship and got a dist/ build with no diagnostic. Set-but-empty must reach the usage error below.
  if [ -n "${ACE_RELEASE_TAG+x}" ]; then
    local tag="$ACE_RELEASE_TAG"
    [ -n "$tag" ] || { err "usage: ace release --tag vX.Y.Z   (pushes a v* tag → fires the CI release job that builds + publishes the binaries)"; return 1; }
    case "$tag" in v[0-9]*) : ;; *) err "tag must look like vX.Y.Z — the CI release job triggers on 'v*'. Got: $tag"; return 1 ;; esac
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { err "not a git repo here."; return 1; }
    git remote get-url origin >/dev/null 2>&1 || { err "no 'origin' remote — publish the repo first (ace scaffold --publish, or gh repo create)."; return 1; }
    [ -n "$(git status --porcelain 2>/dev/null)" ] && { err "working tree not clean — commit or stash before tagging a release."; return 1; }
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 && { err "tag $tag already exists."; return 1; }
    local br; br="$(git branch --show-current 2>/dev/null)"; { [ "$br" = main ] || [ "$br" = master ]; } || warn "tagging from '$br' (not the default branch) — releases usually tag main."
    step "Release — cutting tag $tag (fires the CI release job that builds + publishes the binaries)"
    confirm "Create and push tag $tag to origin?" Y || { info "aborted — no tag pushed."; return 1; }
    git tag -a "$tag" -m "release $tag" && git push origin "$tag" \
      && ok "pushed $tag — watch the release job:  gh run watch   ·   then  gh release view $tag" \
      || { err "tag/push failed."; return 1; }
    return 0
  fi
  [ -f scripts/release.sh ] || { err "no scripts/release.sh here — scaffold a Go project (ace scaffold → Go) or add it via ace upgrade."; return 1; }
  step "Release — hardened static binaries into dist/ (targets + hardening from .opencode/profile.yaml). To SHIP: ace release --tag vX.Y.Z"
  bash scripts/release.sh "$@"
}

# ---------------------------------------------------------------- index + publish
index_project() {
  # Prefer the project's own scripts/graph-refresh.sh — the scaffold writes it BEFORE this runs, and `ace graph`
  # uses it too. It invokes GitNexus + Serena with `CI=1 … </dev/null timeout 600` (non-interactive + patient),
  # so a COLD `npx gitnexus` first-run download can't surface as a scaffold error. Using it here makes scaffold-time
  # indexing identical to a manual `ace graph` refresh (which is why a manual refresh was green right after).
  if [ -x scripts/graph-refresh.sh ]; then
    spin "GitNexus + Serena (scripts/graph-refresh.sh)" bash scripts/graph-refresh.sh || warn "graph-refresh.sh failed — run 'ace graph' to retry."
    return 0
  fi
  # Fallback (no refresh script present): run npx/uvx the same robust way — CI=1, no stdin, generous timeout,
  # and one retry so a cold/slow npm cache doesn't make first-run indexing error.
  have npx && spin "GitNexus analyze (code graph)" sh -c 'CI=1 timeout -k 10 600 npx -y gitnexus@latest analyze </dev/null || { sleep 2; CI=1 timeout -k 10 600 npx -y gitnexus@latest analyze </dev/null; }' || warn "GitNexus analyze skipped — run 'ace graph' to retry."
  have uvx && spin_sh "Serena index (symbols)" "printf 'N\nN\nN\n' | CI=1 timeout -k 10 600 uvx --from git+https://github.com/oraios/serena serena project index" || warn "Serena index skipped"
}

# refresh the code map on demand (+ status); ace graph
graph_refresh() {
  banner; step "Refresh code map (GitNexus graph + Serena symbols)"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" || return 1
  info "Project: $root"
  if [ -x scripts/graph-refresh.sh ]; then spin "graph + docs/architecture.md" bash scripts/graph-refresh.sh
  else index_project; fi
  ok "Code map refreshed. Agents navigate via GitNexus (impact/context/query) + Serena."
}

# ace atlas — refresh the HUMAN architecture atlas (docs/atlas.md 3 views + the README system-map block).
# Companion to `ace graph` (which refreshes the AGENT-facing docs/architecture.md). Idempotently installs
# the generator first, so it also works on repos that predate the atlas.
atlas_refresh() {
  banner; step "Refresh the human Architecture Atlas (docs/atlas.md + README map)"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" || return 1
  info "Project: $root"
  ensure_atlas_refresh   # write the generator if this repo predates it (kept-if-present)
  if [ -x scripts/atlas-refresh.sh ]; then spin "atlas → docs/atlas.md + README block" env ATLAS_FORCE=1 bash scripts/atlas-refresh.sh
  else warn "no scripts/atlas-refresh.sh here"; fi
  ok "Atlas refreshed → docs/atlas.md (system map · data flow · feature map) + the README block."
}

# live-refresh the map as files change; ace graph --watch
graph_watch() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" || return 1
  step "Live code-map watch — refresh on change (Ctrl-C to stop)"
  if have watchexec; then
    watchexec -d 3000 -e ts,tsx,js,mjs,py,go,rs,cs,java -- "npx -y gitnexus@latest analyze"
  elif have inotifywait; then
    info "watching with inotifywait…"
    while inotifywait -qq -r -e modify,create,delete,move --exclude '(node_modules|\.git|\.next|dist|\.serena)' . ; do
      sleep 3; npx -y gitnexus@latest analyze >/dev/null 2>&1 && ok "map refreshed $(date +%T)"
    done
  else
    warn "Install 'watchexec' (or inotify-tools) for live watching. Doing one refresh instead."
    graph_refresh
  fi
}

# ace package <name> — add a correctly-wired TS workspace package (types resolve from source).
add_workspace_package() {
  banner; step "New workspace package"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" || return 1
  [ -f pnpm-workspace.yaml ] || { err "not a pnpm monorepo here (no pnpm-workspace.yaml)"; return 1; }
  local name="${1:-}"; [ -z "$name" ] && { ask "Package name (slug)" "feature"; name="$ASK_REPLY"; }
  name="$(printf '%s' "$name" | tr ' ' '-' | tr -cd '[:alnum:]._-')"
  local scope dir; scope="$(node -e "process.stdout.write(require('./package.json').name||'app')" 2>/dev/null || basename "$root")"
  dir="packages/$name"
  [ -e "$dir" ] && { err "$dir already exists"; return 1; }
  mkdir -p "$dir/src" "$dir/test"
  cat > "$dir/package.json" <<EOF
{
  "name": "@$scope/$name",
  "version": "0.0.0",
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": { ".": "./src/index.ts" },
  "scripts": { "build": "tsc -p tsconfig.json", "test": "vitest run", "typecheck": "tsc --noEmit" },
  "devDependencies": { "typescript": "^5.7.0", "vitest": "^2.1.0" }
}
EOF
  local ext=""; [ -f tsconfig.base.json ] && ext='"extends": "../../tsconfig.base.json", '
  cat > "$dir/tsconfig.json" <<EOF
{ ${ext}"compilerOptions": { "outDir": "dist", "rootDir": "src", "moduleResolution": "Bundler", "strict": true, "declaration": true, "skipLibCheck": true }, "include": ["src"], "exclude": ["dist", "node_modules", "test"] }
EOF
  printf 'export const hello = (): string => "hello from %s";\n' "$name" > "$dir/src/index.ts"
  cat > "$dir/test/index.test.ts" <<EOF
import { describe, expect, it } from "vitest";
import { hello } from "../src/index.js";
describe("$name", () => { it("works", () => expect(hello()).toContain("$name")); });
EOF
  ok "Created @$scope/$name at $dir — types exported from source (tsc resolves them)."
  info "Consume it: add  \"@$scope/$name\": \"workspace:*\"  to an app's package.json, then pnpm install."
  have pnpm && confirm "Run pnpm install to link it now?" Y && spin "pnpm install" pnpm install || true
}

# generate the autonomous PR loop + roadmap into a project
gen_autoloop() {
  local root="${1:-$PWD}"; cd "$root" || return 1
  mkdir -p scripts
  [ -f ROADMAP.md ] || cat > ROADMAP.md <<'EOF'
# Roadmap — the auto-loop works through this top-to-bottom

## Now (in progress)

## Next (the loop implements the first unchecked item)
- [ ] (add your first feature / improvement here)

## Later / ideas

## Done
EOF
  local _seeded_obj=0; [ -f OBJECTIVES.md ] || _seeded_obj=1
  [ -f OBJECTIVES.md ] || cat > OBJECTIVES.md <<'EOF'
# Objectives — the north star. The loop works top-down toward these: it breaks the current
# objective into ROADMAP.md tasks, implements them, and marks progress HERE. Edit freely.

## How it runs
- The loop implements ROADMAP.md items. When ROADMAP is empty it PLANS the next objective below
  into new ROADMAP tasks and updates the progress/status here.

## 1. Full local testable setup
Goal: a fully working LOCAL stack (self-signed TLS on localhost) where every test runs and
validates real functionality — unit + integration + e2e against the running app.
- status: not-started
- [ ] dev stack up (db + app) over self-signed HTTPS on localhost
- [ ] all unit + integration tests run green locally
- [ ] e2e smoke validates the key user flows against the running app

## 2. Major polishing of each feature
Goal: bring every existing feature to a high, consistent bar — UX, error states, edge cases,
accessibility, performance.
- status: not-started

## 3. Roadmap & expansion planning
Goal: continuously plan new high-value functionality and keep the roadmap full.
- status: ongoing

## 4. Improve existing functionality
Goal: deepen and harden existing features (correctness, tests, robustness) where weakest.
- status: ongoing

## Done
EOF
  # shape-aware: a non-HTTP shape (cli/worker/library) has no web stack to bring up — rewrite the two
  # service-flavored local-stack lines so its north-star isn't chasing a /healthz + running-app e2e it can't serve.
  if [ "${_seeded_obj:-0}" = 1 ]; then case "$(_prof_get shape 2>/dev/null)" in
    ''|api|cli-web) ;;
    *) sed -i -e 's#^- \[ \] dev stack up (db + app) over self-signed HTTPS on localhost#- [ ] builds + runs locally (./ci.sh GREEN)#' \
              -e 's#^- \[ \] e2e smoke validates the key user flows against the running app#- [ ] the primary entrypoint / public API is exercised by an integration test#' OBJECTIVES.md 2>/dev/null || true ;;
  esac; fi
  # Payment reconciliation stub — scaffolded ONLY when a payment provider is already a dependency
  # (idempotent; a clean no-op on a greenfield skeleton). Reconciliation catches silent drift between the
  # provider and the local DB; the loop wires + schedules it (see the appended ROADMAP item).
  if ! ls jobs/reconcile-payments.* >/dev/null 2>&1; then
    _pay_re='stripe|paypal|braintree|square|paddle|lemonsqueez|razorpay'
    _pay_ext=""
    if grep -rIqiE "$_pay_re" package.json 2>/dev/null; then _pay_ext=ts
    elif grep -rIqiE "$_pay_re" requirements.txt pyproject.toml 2>/dev/null; then _pay_ext=py
    elif grep -rIqiE "$_pay_re" go.mod 2>/dev/null; then _pay_ext=go
    fi
    if [ -n "$_pay_ext" ]; then
      mkdir -p jobs
      case "$_pay_ext" in
        ts) cat > jobs/reconcile-payments.ts <<'RPTS'
// Payment reconciliation — scheduled job (idempotent). Pull recent provider objects (charges/
// subscriptions) since the last run, compare against local DB state, and report/alert on mismatches.
// Never auto-mutate money state here. Wire the provider client, the DB queries, and a scheduler (cron).
export type ReconcileReport = { checked: number; mismatches: string[] };

export async function reconcilePayments(sinceIso: string): Promise<ReconcileReport> {
  const mismatches: string[] = [];
  const checked = 0;
  // Fill in: list provider objects created since `sinceIso`, load each local record, compare
  // status/amount/currency, push a description to `mismatches` on drift, then alert. Do not write money.
  void sinceIso;
  return { checked, mismatches };
}
RPTS
        ;;
        py) cat > jobs/reconcile-payments.py <<'RPPY'
"""Payment reconciliation — scheduled job (idempotent).

Pull recent provider objects (charges/subscriptions) since the last run, compare against local DB
state, and report/alert on mismatches. Never auto-mutate money state here. Wire the provider client,
the DB queries, and a scheduler (cron).
"""
from __future__ import annotations


def reconcile_payments(since_iso: str) -> dict:
    """Return {"checked": int, "mismatches": list}. Fill in the provider + DB comparison, then alert."""
    mismatches: list = []
    checked = 0
    _ = since_iso
    return {"checked": checked, "mismatches": mismatches}
RPPY
        ;;
        go) cat > jobs/reconcile-payments.go <<'RPGO'
//go:build ignore

// Command reconcile-payments is a scheduled reconciliation job (idempotent): compare recent provider
// objects to the local DB since sinceRFC3339 and report/alert on mismatches. Never auto-mutate money.
// Wire the provider client + DB comparison + a scheduler, then remove the build:ignore tag above.
package main

func ReconcilePayments(sinceRFC3339 string) (checked int, mismatches []string) {
	return 0, nil
}
RPGO
        ;;
      esac
      if ! grep -qF 'wire + schedule payment reconciliation' ROADMAP.md 2>/dev/null; then
        awk -v ext="$_pay_ext" 'BEGIN{d=0}{print}/^## Next/&&!d{print "- [ ] wire + schedule payment reconciliation (jobs/reconcile-payments." ext " — idempotent; alert on provider/DB drift; never auto-mutate money)"; d=1}END{if(!d)print "- [ ] wire + schedule payment reconciliation (jobs/reconcile-payments." ext ")"}' ROADMAP.md > ROADMAP.md.tmp && mv ROADMAP.md.tmp ROADMAP.md
      fi
      ok "payment provider detected → scaffolded jobs/reconcile-payments.$_pay_ext + ROADMAP item"
    fi
  fi
  # Launch-readiness scaffolds (C6) — idempotent, create-if-absent. The launch_readiness_reviewer agent +
  # './ci.sh --launch' verify these before promotion to the live VPS; a backup isn't done until a restore runs.
  # COMPOSITION-AWARE: only scaffold + task the DB restore-drill when the project HAS a database, and the
  # rollback/SLO/runbook service-ops when it's a deployed service. A no-DB CLI gets neither the artefact nor
  # a task it can't do (mirrors the stack-conditional ci.sh gates + the payment-reconcile scaffold above).
  local _dbp=0 _svcp=0
  { [ -f package.json ] && grep -qiE '"(pg|postgres|prisma|@prisma/client|drizzle-orm|mysql2?|mongoose|mongodb|better-sqlite3|sqlite3|sequelize|typeorm|knex|kysely|pg-promise|@libsql/client|@neondatabase/serverless|@planetscale/database|@vercel/postgres)"' package.json; } && _dbp=1
  { [ -f go.mod ] && grep -qiE 'lib/pq|jackc/pgx|jackc/pgconn|go-sql-driver|mattn/go-sqlite3|modernc\.org/sqlite|glebarez/sqlite|gorm\.io|entgo\.io/ent|uptrace/bun|jmoiron/sqlx|mongo-driver' go.mod; } && _dbp=1
  grep -qiE 'psycopg|sqlalchemy|sqlmodel|asyncpg|pymysql|mysqlclient|mariadb|aiosqlite|pymongo|django|tortoise|peewee|alembic' requirements*.txt pyproject.toml 2>/dev/null && _dbp=1
  { ls prisma/schema.prisma migrations/*.sql db/migrations/*.sql migrations/0*.py */migrations/0*.py alembic/versions/*.py 2>/dev/null | grep -q .; } && _dbp=1
  [ "$(_prof_get deploy_kind 2>/dev/null)" = service ] && _svcp=1
  mkdir -p ops
  [ -f LAUNCH-READINESS.md ] || cat > LAUNCH-READINESS.md <<'LRMD'
# Launch readiness — verified ONCE before promotion to the live VPS (launch_readiness_reviewer gate).
# Legend: [ ] not-started · [~] present-untested · [x] verified. NO-GO until every BLOCK item is [x].

## BLOCK (launch must not proceed until all are [x])
- [ ] Tested restore (if the app has a database) — run ops/restore-drill.sh; ops/restore-drill.result shows rows_verified (non-zero) + RPO/RTO
- [ ] Rollback (if deployed as a service) — ops/rollback.md documents the tested revert for the last deploy
- [ ] Secrets & env separation — prod secrets least-privilege, not in the client bundle, separated from staging
- [ ] Money paths — webhook signature verify + reconciliation job (if the app takes payments)
- [ ] Spend caps — token/iteration caps + a per-user/session budget (if the app calls an LLM)

## WARN (note, don't block)
- [ ] SLO + alerting (ops/slo.md: golden signals, error-rate + burn-rate)
- [ ] Incident runbook (ops/runbook.md: symptoms -> diagnostics -> remediation)
- [ ] Load/capacity test evidence for the expected launch traffic
- [ ] GDPR: retention + a verifiable PII erasure path (not soft-delete only)
- [ ] Health/readiness endpoints wired to the platform
LRMD
  [ "$_dbp" = 1 ] && [ ! -f ops/restore-drill.sh ] && { cat > ops/restore-drill.sh <<'RDSH'
#!/usr/bin/env bash
# Restore drill — a backup is NOT done until a restore has been executed and the data queried (AWS REL09-BP04).
# WIRE ME: restore the LATEST backup into a scratch DB, run a data-presence query, then record the result.
set -uo pipefail
rows_verified=0; rpo="UNKNOWN"; rto="UNKNOWN"; status="UNVERIFIED"
# EDIT: 1) restore latest backup into a throwaway DB  2) query key tables for row counts
#       3) set rows_verified to the real count and rpo/rto to measured figures, then status=verified.
echo "restore-drill: WIRE ME — restore a real backup, query it, set rows_verified/rpo/rto/status" >&2
{ printf 'date=%s\n' "$(date -u +%FT%TZ 2>/dev/null || echo unknown)"; printf 'rows_verified=%s\n' "$rows_verified"; printf 'RPO=%s\n' "$rpo"; printf 'RTO=%s\n' "$rto"; printf 'status=%s\n' "$status"; } > ops/restore-drill.result
echo "wrote ops/restore-drill.result (status=UNVERIFIED until you wire a real restore)"
RDSH
  chmod +x ops/restore-drill.sh; }
  if [ "$_svcp" = 1 ]; then
    [ -f ops/rollback.md ] || printf '# Rollback — the tested revert path for the last deploy\n\n1. Identify the last-good release/sha.\n2. Redeploy the last-good image/binary (or git revert + redeploy).\n3. If a migration ran: apply its reverse (expand-contract makes this safe) — never drop data blind.\n4. Verify /health + a smoke check; confirm the SLO recovered.\n\nRecord the date + result of your last rollback rehearsal here.\n' > ops/rollback.md
    [ -f ops/runbook.md ] || printf '# Incident runbook — symptoms -> diagnostics -> remediation\n\n> Committed in-repo (versioned with the code), not a wiki.\n\n## <symptom, e.g. 5xx spike>\n- Diagnose: <exact commands> (logs, /health, recent deploys)\n- Remediate: <steps>\n- Roll back: see ops/rollback.md\n' > ops/runbook.md
    [ -f ops/slo.md ] || printf '# SLOs + alerting (golden signals)\n\n| Signal | SLO | Alert |\n|---|---|---|\n| Availability | 99.9%% | error-rate > 1%% for 5m; burn-rate fast+slow |\n| Latency | p95 < 300ms, p99 < 1s | p95 breach for 10m |\n| Errors | < 1%% 5xx | as above |\n| Saturation | CPU/mem < 80%% | sustained > 85%% |\n\nWire these to your alerting; EDIT thresholds for this service.\n' > ops/slo.md
  fi
  # Seed ops ROADMAP tasks ONLY when they apply (composition-aware): restore-drill needs a DB; rollback/SLO a service.
  _seed_ri(){ grep -qF "$1" ROADMAP.md 2>/dev/null || { awk -v it="$1" 'BEGIN{d=0}{print}/^## Next/&&!d{print "- [ ] " it; d=1}END{if(!d)print "- [ ] " it}' ROADMAP.md > ROADMAP.md.tmp && mv ROADMAP.md.tmp ROADMAP.md; }; }
  [ "$_dbp" = 1 ]  && _seed_ri "run + verify the restore drill (ops/restore-drill.sh -> non-zero rows_verified) before promotion"
  [ "$_svcp" = 1 ] && _seed_ri "document + rehearse the rollback (ops/rollback.md); wire SLO alerts (ops/slo.md)"
  ok "launch-readiness scaffolds ready: LAUNCH-READINESS.md + ops/{restore-drill.sh,rollback.md,runbook.md,slo.md}"
  # Thin wrapper — the loop logic is PURE ACE (single source: lib/autoloop.sh);
  # only this project's ROADMAP/OBJECTIVES/.opencode/ci.sh are project-specific.
  { echo '#!/usr/bin/env bash'
    echo '# Generated by ACE — thin wrapper; the loop lives in ace/lib/autoloop.sh (single source).'
    printf '_l=%q\n' "$ACE_DIR/lib/autoloop.sh"
    echo '[ -f "$_l" ] || _l="$(dirname "$(readlink -f "$(command -v ace 2>/dev/null)" 2>/dev/null)" 2>/dev/null)/lib/autoloop.sh"'
    echo '[ -f "$_l" ] || { echo "ace loop: autoloop.sh not found — is ace installed?" >&2; exit 1; }'
    echo 'exec bash "$_l" "$@"'
  } > scripts/.auto-loop.sh.tmp
  chmod +x scripts/.auto-loop.sh.tmp
  mv -f scripts/.auto-loop.sh.tmp scripts/auto-loop.sh
  # Seed loop-context caches (read by orchestrator + critics to avoid re-deriving each task) — only if absent.
  mkdir -p .opencode
  [ -f .opencode/lessons.md ] || printf '# Lessons (most useful first) — durable decisions/gotchas the loop learned.\n# One terse line each, deduped. Read before planning; append after each task.\n' > .opencode/lessons.md
  if [ ! -f .opencode/project-facts.md ]; then
    { printf '# Project facts (stable) — so agents do NOT rediscover them every task.\n- Gate: ./ci.sh (fast, pre-commit) and ./ci.sh --container (full VPS-parity, pre-push).\n- The ACE/loop CLI and its config live OUTSIDE this repo and are not editable here — own fixes in-repo.\n- Orchestrator shell is git/gh only; delegate file writes + ./ci.sh to implementer/verifier.\n'
      # GitNexus hosts many repos under one shared local index — agents MUST pass repo:"<this repo>" or calls error
      printf -- '- GitNexus index is SHARED across repos — ALWAYS pass `repo: "%s"` to every gitnexus_* call (omitting it errors "Multiple repositories indexed").\n' "$(basename "$PWD")"
      # dynamic: ground the orchestrator on this host so it never ratholes on package installs
      [ "${ACE_IMMUTABLE:-0}" = 1 ] && printf -- '- HOST IS IMMUTABLE (%s): do NOT install system packages — sudo/dnf/rpm-ostree FAIL here. Required tools must already be on PATH (run `ace install` once, user-local) or be wired into the Containerfile/CI; never retry a system install (that is a rathole).\n' "${ACE_DISTRO_PRETTY:-atomic}"
      printf -- '- (Append stack, key paths, and conventions here as you learn them.)\n'
    } > .opencode/project-facts.md
  fi
  # Self-heal: project-facts.md files seeded before the GitNexus repo-scoping fact existed lack the `repo:` rule.
  # Without it agents omit the param and every gitnexus_* call errors "Multiple repositories indexed", silently
  # degrading to whole-file reads. Append it in place (idempotent) so already-bootstrapped loops get the fix too.
  if [ -f .opencode/project-facts.md ] && ! grep -qF 'gitnexus_* call' .opencode/project-facts.md; then
    printf -- '- GitNexus index is SHARED across repos — ALWAYS pass `repo: "%s"` to every gitnexus_* call (omitting it errors "Multiple repositories indexed").\n' "$(basename "$PWD")" >> .opencode/project-facts.md
  fi
  ok "Autonomous loop ready: scripts/auto-loop.sh + ROADMAP.md + .opencode context caches"
}

# ace autoloop — bootstrap (if needed) + run the autonomous PR loop
# Inception: a BOUNDED, READ-ONLY opencode pass that TRIAGES ACE itself (this bash CLI) from the rathole
# notes the supervisor filed and FILES A GITHUB ISSUE on ACE's repo with the root cause + proposed fix.
# It NEVER edits ACE's code, branches, commits, pushes, or opens a PR — a human changes main's code after
# reading the issue, so the autonomous loop can never write to ACE itself. `timeout` bounds the triage.
ace_self_fix() {
  local f="${1:-${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}}" notes dir slug fp url title body
  local ledger="${ACE_FIXME_LEDGER:-$HOME/.config/ace/ace-fixme-filed.log}"
  notes="$(cat "$f" 2>/dev/null)"; [ -n "$notes" ] || { info "no ACE self-fix notes."; return 0; }
  command -v gh >/dev/null 2>&1 || { warn "gh not found — cannot file an ACE issue; notes kept at $f."; return 1; }
  dir="${ACE_DIR:-$(dirname "$(readlink -f "$(command -v ace 2>/dev/null)" 2>/dev/null)" 2>/dev/null)}"
  [ -d "$dir/.git" ] || { warn "ACE_DIR is not a git repo — cannot file an issue."; return 1; }
  slug="$(cd "$dir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [ -n "$slug" ] || { warn "ACE repo has no GitHub remote — cannot file an issue; notes kept at $f."; return 1; }
  # MECHANICAL DEDUP: fingerprint the rathole MESSAGE only (drop timestamp + repo:branch columns), so the
  # same root cause across branches files ONE issue. Skip if already filed.
  fp="$(printf '%s' "$notes" | cut -f3- | sort -u | sha1sum 2>/dev/null | cut -c1-12)"
  mkdir -p "$(dirname "$ledger")"
  if [ -n "$fp" ] && grep -qxF "$fp" "$ledger" 2>/dev/null; then
    info "ACE self-fix: these rathole notes were already filed (fp=$fp) — archiving, not re-filing."
    mv -f "$f" "${f}.${fp}.done" 2>/dev/null; return 0
  fi
  step "ACE self-fix (inception) — $(wc -l <"$f" 2>/dev/null) note(s) → a GitHub ISSUE on $slug (fp=$fp; you fix the code)"
  # DETERMINISTIC: file the issue from bash (an issue is ALWAYS filed; not left to the model).
  title="[ace-self-fix] rathole: $(printf '%s' "$notes" | head -1 | cut -f3- | cut -c1-72)"
  body="$(printf '## Symptom — rathole notes the loop filed\n\n```\n%s\n```\n\n## Triage (a human fixes ACE; the loop only files this)\n- [ ] Root cause in the driver/judge/config (lib/*.sh / ./ace) — function + file:line\n- [ ] Proposed fix\n- [ ] Risk if unfixed\n\n_fingerprint: %s_\n' "$notes" "$fp")"
  url="$( cd "$dir" || exit 1
    gh label create ace-self-fix -c FBCA04 -d "ACE loop self-diagnosis" >/dev/null 2>&1 || true
    gh issue create --repo "$slug" --title "$title" --label ace-self-fix --body "$body" 2>/dev/null \
      || gh issue create --repo "$slug" --title "$title" --body "$body" 2>/dev/null )"
  [ -n "$url" ] || { warn "ACE self-fix could not file an issue (gh error) — notes kept at $f."; return 1; }
  printf '%s\n' "$fp" >> "$ledger"; mv -f "$f" "${f}.${fp}.done" 2>/dev/null
  ok "ACE self-fix filed $url — review + fix it; notes archived (fp=$fp)."
  # OPTIONAL enrichment: a bounded READ-ONLY opencode pass adds a root-cause comment (never edits code).
  if command -v opencode >/dev/null 2>&1; then
    ( cd "$dir" && mkdir -p .opencode
      timeout "${ACE_SELFFIX_TIMEOUT:-1800}" opencode run --agent orchestrator </dev/null "READ-ONLY triage of ACE itself (bash: ./ace + lib/*.sh; the driver is lib/scaffold.sh). You MUST NOT edit/create/delete any file, branch, commit, push, open a PR, or delegate any code change. Diagnose the ROOT cause of the rathole notes below — navigate via grep/gitnexus/serena and pin the function + file:line — then add ONE comment to the existing issue via: gh issue comment $url --body \"## Root cause (file:line) … ## Proposed fix …\". Do NOTHING else. Notes:
$notes" >.opencode/last-self-fix.log 2>&1 || true ) \
      && info "added a root-cause comment to $url." || true
  fi
}
# Pre-run gate: if past ratholes filed ACE-level notes, ask permission to triage ACE first (your #2 gate).
# Acts on the start-of-run "Self-fix ACE?" setting ($1=1 → run the inception pass). Notes filed by the supervisor.
ace_fixme_gate() {
  local f="${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}"
  [ -s "$f" ] || return 0
  if [ "${1:-0}" = 1 ]; then ace_self_fix "$f"
  else info "ACE self-fix OFF — $(wc -l <"$f" 2>/dev/null) rathole note(s) left queued at $f"; fi
}
# snap_card — default `ace snap` content: banner + a compact, NETWORK-FREE status card.
snap_card() {
  banner
  local eng; eng="$(container_engine 2>/dev/null)"
  step "Status"
  drow info "version" "ace ${ACE_VERSION:-?} · ${ACE_DISTRO_PRETTY:-?}"
  drow "$([ -n "${DEEPSEEK_API_KEY:-}" ] && echo ok || echo warn)" "DeepSeek key" "$([ -n "${DEEPSEEK_API_KEY:-}" ] && echo set || echo unset)"
  drow "$([ -n "$eng" ] && echo ok || echo warn)" "container" "${eng:-none}"
  drow "$(have hermes && echo ok || echo warn)" "hermes" "$(have hermes && echo wired || echo absent) · target=$(hermes_to)"
  if systemctl --user is-active ace-loop.service >/dev/null 2>&1; then drow ok "loop service" "active"; else drow info "loop service" "idle"; fi
  hr
}

# ace_snap [--to TARGET] [--out PNG] [command…] — render the REAL coloured CLI output to a PNG (a
# screenshot of ACE) via freeze (preferred) or ansitoimg, then optionally send it to Signal/etc. as a
# media attachment. Default content = snap_card. Needs a renderer: `ace install` offers freeze+ansitoimg.
ace_snap() {
  local target="${ACE_TO:-}" out="${ACE_OUT:-}" cmd=() had_args=$#
  while [ $# -gt 0 ]; do case "$1" in
    --to)  target="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --)    shift; cmd=("$@"); break ;;
    *)     cmd+=("$1"); shift ;;
  esac; done
  [ "$had_args" -eq 0 ] && [ ${#cmd[@]} -eq 0 ] && [ -n "${ACE_ARG:-}" ] && cmd=("$ACE_ARG" ${ACE_ARG2:+"$ACE_ARG2"})
  [ ${#cmd[@]} -eq 0 ] && cmd=(snapcard)
  out="${out:-$(mktemp -u --suffix=.png "${TMPDIR:-/tmp}/ace-snap-XXXX")}"
  local self; self="$(command -v ace 2>/dev/null || echo "$ACE_DIR/ace")"
  local inner; inner="env ACE_FORCE_COLOR=1 ACE_NO_ANIM=1 $(printf '%q ' "$self" "${cmd[@]}")"
  # render via freeze (native PNG); subshell-isolated so a freeze crash/segfault stays quiet and falls back
  if command -v freeze >/dev/null 2>&1; then
    # via bash -c (with a trailing ':' to defeat bash's exec-optimization) so a freeze crash is reaped
    # by the inner shell and its "Segmentation fault" notice goes to the redirected stderr, not ours
    bash -c 'freeze --execute "$1" --output "$2"; :' _ "$inner" "$out" >/dev/null 2>&1 || true
  fi
  # fall back to ansitoimg (SVG) → rasterize to PNG, whenever freeze produced nothing
  if [ ! -s "$out" ] && command -v ansitoimg >/dev/null 2>&1; then
    local t svg; t="$(mktemp)"; svg="$(mktemp -u).svg"
    ACE_FORCE_COLOR=1 ACE_NO_ANIM=1 "$self" "${cmd[@]}" >"$t" 2>&1
    ansitoimg "$t" "$svg" >/dev/null 2>&1; rm -f "$t"
    if   command -v magick       >/dev/null 2>&1; then magick "$svg" "$out" >/dev/null 2>&1
    elif command -v rsvg-convert >/dev/null 2>&1; then rsvg-convert "$svg" -o "$out" >/dev/null 2>&1
    elif command -v convert      >/dev/null 2>&1; then convert "$svg" "$out" >/dev/null 2>&1
    else cp "$svg" "$out"; warn "no SVG→PNG rasterizer (ImageMagick/librsvg) — sending SVG."; fi
    rm -f "$svg"
  fi
  [ -s "$out" ] || { err "snapshot render failed — install a renderer: 'uv tool install ansitoimg' (+ ImageMagick), or fix freeze."; return 1; }
  if [ -n "$target" ]; then
    command -v hermes >/dev/null 2>&1 || { err "hermes not found — can't send (image saved at $out)."; return 1; }
    if hermes send --to "$target" --subject "ACE" "MEDIA:$out" </dev/null >/dev/null 2>&1; then ok "Snapshot sent to $target  ($out)"
    else err "hermes send failed — image saved at $out (is the gateway running?)"; return 1; fi
  else ok "Snapshot: $out"; fi
}

# ace approve [<token>] yes|no — answer a pending loop approval request (the autonomous loop, run with
# MERGE_APPROVAL=hermes, polls for it). From chat the bot runs this when you reply approve/deny.
#   ace approve <tok> yes · ace approve <tok> no · ace approve yes (newest) · ace approve no (newest)
#
# DENY-BY-DEFAULT. This is the ONLY human gate on an otherwise unattended merge-to-main, and its caller is
# an LLM chat relay (lib/hermes-ace-skill.md rule 8) that hands us whatever the human typed. So the ONLY
# input that releases a merge is an explicit, recognised approval word; every other string — "nope",
# "hold off", "not yet", a paraphrase the relay invented, a truncated word — records a DENY, which the
# loop reads as "leave the PR open and stop". Asymmetry of harm: a wrong DENY costs one chat round-trip,
# a wrong APPROVE merges unreviewed code to main. (Was: `local d=yes` + a lowercase-only deny list, i.e.
# every unrecognised reply — and a missing decision entirely — recorded an APPROVAL.)
ace_approve() {
  local root tok="${1:-}" dec="${2:-}" dir d ltok ldec
  root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; dir="$root/.opencode/approvals"
  # Case-fold BOTH slots up front. The relay passes the human's raw casing ("No", "YES", "Approve"), and
  # the two slots used to be matched against DIFFERENT vocabularies — a word could be accepted as a
  # decision in the token slot and then fall through to the yes-default when it was classified.
  ltok="$(printf '%s' "$tok" | tr 'A-Z' 'a-z')"; ldec="$(printf '%s' "$dec" | tr 'A-Z' 'a-z')"
  # Single-arg form `ace approve yes|no`: the lone argument is the DECISION for the newest pending
  # request, not a token. Same vocabulary as the classifier below, so the two can no longer disagree.
  # Guarded on an EMPTY decision slot: when BOTH args are present arg1 is the token and arg2 is the
  # decision, so a malformed `ace approve yes no` must not let the leading "yes" override the trailing
  # "no" (it falls through instead, finds no request named "yes", and records nothing — fail-closed).
  if [ -z "$ldec" ]; then
    case "$ltok" in
      y|yes|approve|approved|ok|1|✅|n|no|deny|denied|reject|rejected|0|❌) dec="$tok"; ldec="$ltok"; tok="" ;;
    esac
  fi
  # A MISSING decision is not consent. `ace approve <tok>` (and bare `ace approve`) used to record a yes.
  [ -n "$ldec" ] || { err "usage: ace approve [<token>] yes|no  — a decision is REQUIRED (no decision is NOT an approval)."; return 1; }
  ls "$dir"/*.request >/dev/null 2>&1 || { err "no pending approval in $(basename "$root") — nothing to approve."; return 1; }
  [ -n "$tok" ] || { tok="$(ls -t "$dir"/*.request 2>/dev/null | head -1)"; tok="$(basename "${tok%.request}")"; }
  [ -f "$dir/$tok.request" ] || { err "no pending approval '$tok'."; return 1; }
  d=no; case "$ldec" in y|yes|approve|approved|ok|1|✅) d=yes ;; esac
  # Tell the human when we did NOT understand them, so a denied-by-fallback reply isn't silently mistaken
  # for a deliberate deny — they can re-answer with the exact word while the request is still pending.
  case "$ldec" in
    y|yes|approve|approved|ok|1|✅|n|no|deny|denied|reject|rejected|0|❌) ;;
    *) warn "decision '$dec' not recognised — recorded as DENY (fail-closed). Approve with the exact word: yes" ;;
  esac
  printf '%s\n' "$d" > "$dir/$tok.decision"
  ok "recorded decision: $tok → $d  (the loop will pick it up)"
  grep -E '^(kind|summary)=' "$dir/$tok.request" 2>/dev/null | sed 's/^/  /'
}

# ace schedule '<when>' — schedule a recurring autorun for THIS project via Hermes cron (any channel).
#   ace schedule '0 9 * * 1-5'  (weekday 9am)  ·  ace schedule 'every 6h'  ·  ace schedule '30m'
ace_schedule() {
  local when="${1:-}" proj slug to
  command -v hermes >/dev/null 2>&1 || { err "hermes not found — scheduling needs Hermes. (Standalone: use a systemd --user timer / OS cron to run 'ace loop start'.)"; return 1; }
  [ -n "$when" ] || { err "usage: ace schedule '<schedule>'   e.g. '0 9 * * 1-5' · 'every 6h' · '30m'"; return 1; }
  proj="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; slug="$(basename "$proj" | tr -c 'a-zA-Z0-9' '-')"; to="$(hermes_to)"
  if hermes cron create "$when" --name "ace-autorun-$slug" --deliver "$to" --workdir "$proj" \
       "Start the ACE autorun loop for this project: run \`ace loop start\` (it (re)starts the detached service), then run \`ace loop status\` and report a one-line summary." >/dev/null 2>&1; then
    ok "Scheduled autorun for '$slug' ($when → $to). Manage: hermes cron list · hermes cron remove ace-autorun-$slug."
  else err "hermes cron create failed — see 'hermes cron --help' + that the gateway is running."; return 1; fi
}

# ace hermes mcp — register THIS repo's code-graph servers (Serena · GitNexus) with the Hermes agent, so
# chat questions ("what calls X?", "impact of Y?") are GROUNDED — the same servers OpenCode uses. Graceful.
ace_hermes_mcp() {
  command -v hermes >/dev/null 2>&1 || { err "hermes not found — grounding needs Hermes."; return 1; }
  hermes mcp --help >/dev/null 2>&1 || { err "this hermes build has no 'mcp' command — upgrade Hermes."; return 1; }
  local root slug; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; slug="$(basename "$root" | tr -c 'a-zA-Z0-9' '-')"
  # Serena: grounded symbol search / find-usages for THIS repo (absolute --project ⇒ repo-scoped, gateway-cwd-safe).
  if command -v uvx >/dev/null 2>&1; then
    if hermes mcp add "serena-$slug" --command uvx --args --from git+https://github.com/oraios/serena serena start-mcp-server --context ide-assistant --project "$root" >/dev/null 2>&1; then
      ok "registered serena-$slug — the chat agent can now navigate $slug's symbols + usages."
    else warn "hermes mcp add serena failed — add it manually (command from ~/.config/opencode/opencode.json)."; fi
  else warn "uvx missing (run 'ace install') — can't register Serena."; fi
  # GitNexus reads .gitnexus/ from the cwd, which a global server can't scope; ask the agent in-repo (terminal
  # workdir=$root) or rely on Serena above. Register best-effort for when the gateway runs from the repo.
  command -v npx >/dev/null 2>&1 && hermes mcp add "gitnexus-$slug" --command npx --args -y gitnexus@latest mcp >/dev/null 2>&1 \
    && info "registered gitnexus-$slug (best-effort; impact/graph needs the gateway in $root)."
  info "Restart the gateway to load these: hermes gateway (stop + start)."
}

# ace brain — file ACE's cross-project host-lessons + this repo's durable lessons into gbrain (if present),
# so the brain-first chat agent surfaces them across sessions. Optional + graceful; ACE keeps its own lessons.
ace_brain() {
  command -v gbrain >/dev/null 2>&1 || { err "gbrain not found — this bridges ACE lessons into your gbrain knowledge base (optional). ACE keeps its own lessons regardless."; return 1; }
  local os hl n=0 slug
  os="$( . /etc/os-release 2>/dev/null; echo "${ID:-unknown}-${VERSION_ID:-0}" )"
  hl="$HOME/.config/ace/host-lessons/$os.md"
  [ -f "$hl" ] && gbrain put "ace-host-lessons-$os" < "$hl" >/dev/null 2>&1 && { ok "filed host-lessons ($os) → gbrain."; n=$((n+1)); }
  if [ -f .opencode/lessons.md ]; then slug="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"; gbrain put "ace-lessons-$slug" < .opencode/lessons.md >/dev/null 2>&1 && { ok "filed $slug lessons → gbrain."; n=$((n+1)); }; fi
  [ "$n" = 0 ] && info "nothing to file yet (no host-lessons / .opencode/lessons.md)." || info "now searchable in chat via gbrain (brain-first)."
}

# ace hermes webhook — subscribe a Hermes webhook route so GitHub CI/PR events ping chat (dovetails the
# CI-gate work: get notified when Actions finishes instead of watching). Needs the gateway publicly reachable;
# ACE prints the route to add to the repo's GitHub webhooks. Graceful.
ace_hermes_webhook() {
  command -v hermes >/dev/null 2>&1 || { err "hermes not found."; return 1; }
  hermes webhook --help >/dev/null 2>&1 || { err "this hermes build has no 'webhook' command — upgrade Hermes."; return 1; }
  local slug to; slug="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" | tr -c 'a-zA-Z0-9' '-')"; to="$(hermes_to)"
  if hermes webhook subscribe "gh-$slug" --events 'push,pull_request,workflow_run' --deliver "$to" --deliver-only >/dev/null 2>&1; then
    ok "Subscribed route 'gh-$slug' → $to."
    info "Add a GitHub webhook on this repo → your gateway's  /webhooks/gh-$slug  (content-type application/json):"
    info "  GitHub: repo → Settings → Webhooks → Add webhook. Or, with a public gateway URL:"
    info "  gh api repos/<owner>/<repo>/hooks -f config[url]=<GATEWAY_URL>/webhooks/gh-$slug -f config[content_type]=json -f events[]=push -f events[]=pull_request -f events[]=workflow_run"
  else err "hermes webhook subscribe failed — see 'hermes webhook --help' + that the gateway is running."; return 1; fi
}

# Sync the canonical Hermes "ace" skill (lib/hermes-ace-skill.md) into ~/.hermes so the chat conductor
# always tracks the INSTALLED ace. Stamps $ACE_VERSION + today's date into the skill, so it can't drift:
# every install/update/hermes-wire re-syncs it. Idempotent, best-effort, silent when Hermes isn't present.
# Called from guided() (= `ace install`), update(), and ace_hermes().
ensure_hermes_skill() {
  command -v hermes >/dev/null 2>&1 || return 0          # no Hermes on this host → nothing to sync
  local src="$ACE_DIR/lib/hermes-ace-skill.md"
  [ -f "$src" ] || { warn "Hermes skill source missing: $src — skipping."; return 1; }
  local dir="$HOME/.hermes/skills/autonomous-ai-agents/ace" dst today rendered
  dst="$dir/SKILL.md"; today="$(date +%F)"
  if [ "${ACE_DRY_RUN:-0}" = 1 ]; then info "[dry-run] would sync Hermes ace skill → $dst (stamp ace $ACE_VERSION)"; return 0; fi
  mkdir -p "$dir" 2>/dev/null || { warn "can't create $dir — skipping Hermes skill sync."; return 1; }
  rendered="$(sed -e "s/__ACE_VERSION__/$ACE_VERSION/g" -e "s/__SYNC_DATE__/$today/g" "$src")"
  # write the GLOBAL copy — idempotent: skip if it already matches (ignoring only the synced_at date)
  if [ -f "$dst" ] && diff -q <(grep -v '^    synced_at:' "$dst") <(printf '%s\n' "$rendered" | grep -v '^    synced_at:') >/dev/null 2>&1; then
    info "Hermes ace skill already current (ace $ACE_VERSION) — kept."
  else
    [ -f "$dst" ] && cp "$dst" "$dst.acebak.$(date +%s)" 2>/dev/null   # back up a differing/hand-edited copy once
    if printf '%s\n' "$rendered" > "$dst"; then ok "Synced Hermes ace skill → $dst (stamped ace $ACE_VERSION)."
    else warn "failed writing $dst — Hermes ace skill not synced."; return 1; fi
  fi
  # ALSO refresh any Hermes PROFILE that carries its OWN copy of the ace skill — a cloned profile (e.g. a
  # dedicated `ace` profile) has its own skills dir, not the global one, so it would otherwise drift.
  local pskill
  for pskill in "$HOME"/.hermes/profiles/*/skills/autonomous-ai-agents/ace/SKILL.md; do
    [ -f "$pskill" ] || continue
    diff -q <(grep -v '^    synced_at:' "$pskill") <(printf '%s\n' "$rendered" | grep -v '^    synced_at:') >/dev/null 2>&1 && continue
    printf '%s\n' "$rendered" > "$pskill" 2>/dev/null && info "  · also refreshed profile skill: ${pskill#"$HOME"/.hermes/profiles/}"
  done
}

# `ace hermes` — wire loop milestone notifications + command-back to Hermes Agent (-> Telegram/Signal/phone).
ace_hermes() {
  banner; step "Hermes ↔ chat — notifications + command-back (Telegram · Signal · Discord · Slack · …)"
  if ! command -v hermes >/dev/null 2>&1; then
    warn "Hermes is not installed (no 'hermes' on PATH). ACE works fine without it — this just adds chat."
    box "Install Hermes Agent (Nous Research), then re-run 'ace hermes'" \
      "https://hermes-agent.org          one-command install" \
      "hermes gateway setup              wire your channel (Telegram BotFather token+id · Signal number · …)" \
      "hermes gateway start              the bot goes live"
    return 1
  fi
  ok "hermes present: $(hermes --version 2>/dev/null | head -1)"
  info "Target format: telegram · telegram:<chat_id> · signal:+15551234567 · discord:<channel_id> · slack:<channel> · whatsapp:<id> (any channel your gateway has set up)"
  local to _t; ask "Hermes target for ACE loop notifications" "$(config_get HERMES_TO 2>/dev/null || echo telegram)"; to="$ASK_REPLY"
  config_set HERMES_TO "$to"; ok "Saved HERMES_TO=$to"
  # the #1 gotcha: a Telegram supergroup/channel id MUST be the -100… form. A long +digits id (no '-') is
  # almost certainly a supergroup missing its minus — outbound `hermes send` then fails with "chat not found".
  _t="${to#telegram:}"; case "$_t" in
    "$to") : ;;                                                         # not a telegram:<id> target
    [0-9]*) [ "${#_t}" -ge 12 ] && warn "'$_t' looks like a Telegram supergroup id with NO '-' — outbound sends usually need 'telegram:-$_t'. Confirm the exact target: hermes send --list telegram" ;;
  esac
  if confirm "Send a test notification to '$to' now?" Y; then
    if hermes send --to "$to" --subject "ACE" "✅ ACE ↔ Hermes wired — loop milestones will arrive here." </dev/null >/dev/null 2>&1; then
      ok "Test sent — check your ${to%%:*}."
    else err "hermes send failed. Check: the gateway is set up (hermes gateway start) · the target is exact — list the real ones with 'hermes send --list ${to%%:*}' (a Telegram group needs its -100… id, with the minus)."; fi
  fi
  # --- optional: ENABLE COMMAND-BACK (let the chat bot run host commands) — edits ~/.hermes, backed up ---
  local cfg="$HOME/.hermes/config.yaml" envf="$HOME/.hermes/.env"
  if [ -f "$cfg" ] && [ -f "$envf" ]; then
    warn "Command-back gives the chat bot a HOST SHELL — it can run ANY command as you. Lock it to your id."
    if confirm "Enable command-back for '$to' now (adds the terminal toolset + locks the allowlist)?" N; then
      local plat pup myid; plat="${to%%:*}"; pup="$(printf '%s' "$plat" | tr 'a-z' 'A-Z')"
      # the COMMANDING user is who may run commands — NEVER the notification target. A channel/group id is
      # where messages GO, not who may COMMAND, so don't seed the allowlist from it. Default to the existing
      # allowlist (a real prior user id); else the target ONLY if it's a direct user; never a Telegram -100… id.
      myid="$(grep -E "^${pup}_ALLOWED_USERS=" "$envf" 2>/dev/null | cut -d= -f2- | tr ',' ' ' | awk '{print $1}')"
      [ -z "$myid" ] && [ "${to#*:}" != "$to" ] && myid="${to#*:}"
      case "$myid" in -100*) myid="" ;; esac   # a Telegram supergroup/channel id is never a commanding user
      ask "Your $plat PERSONAL user id allowed to command the bot — NOT the group/channel id (Telegram: get it from @userinfobot · Signal: your +E.164 number)" "$myid"; myid="$ASK_REPLY"
      # 1) allowlist in .env (flat KEY=val — safe + idempotent)
      if grep -qE "^${pup}_ALLOWED_USERS=" "$envf"; then sed -i "s|^${pup}_ALLOWED_USERS=.*|${pup}_ALLOWED_USERS=${myid}|" "$envf"
      else printf '%s_ALLOWED_USERS=%s\n' "$pup" "$myid" >> "$envf"; fi
      ok "locked: ${pup}_ALLOWED_USERS=${myid}"
      # 2) terminal toolset under platform_toolsets in config.yaml (backup + idempotent + YAML-validate).
      #    CRUCIAL: command-back only works if the platform's bundle actually lists 'terminal'. A bundle that
      #    exists with only its messaging adapter (e.g. telegram: [hermes-telegram]) does NOT grant a shell —
      #    so verify, add it if missing, and only report ON when it's genuinely there.
      cp "$cfg" "$cfg.bak.$(date +%s)"
      local cb_ok=0 yok
      if awk -v p="$plat" '$0=="  "p":"{f=1;next} f&&/^  [a-zA-Z]/{f=0} f&&$0=="    - terminal"{print;exit}' "$cfg" | grep -q .; then
        cb_ok=1   # the platform bundle already grants the terminal toolset — already wired
      elif awk '/^platform_toolsets:/{f=1;next} f&&/^[^[:space:]]/{f=0} f' "$cfg" | grep -qE "^  ${plat}:"; then
        # bundle EXISTS but has no terminal → insert the command-back toolsets right under the platform line
        awk -v p="$plat" '{print} $0=="  "p":"{print "    - terminal"; print "    - code_execution"; print "    - file"; print "    - web"; print "    - cronjob"}' "$cfg" > "$cfg.tmp"
        yok=1; { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; } && { python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$cfg.tmp" 2>/dev/null || yok=0; }
        if [ "$yok" = 1 ]; then mv "$cfg.tmp" "$cfg"; cb_ok=1; ok "added the terminal toolset to your existing platform_toolsets.${plat}."
        else warn "couldn't add 'terminal' without breaking the YAML — kept your original (backup made); add it by hand under platform_toolsets.${plat}."; rm -f "$cfg.tmp"; fi
      else
        # no bundle for this platform → create it with the command-back toolsets
        awk -v p="$plat" '/^platform_toolsets:/ && !d { print; print "  " p ":"; print "    - terminal"; print "    - code_execution"; print "    - file"; print "    - web"; d=1; next } { print }' "$cfg" > "$cfg.tmp"
        yok=1; { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; } && { python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$cfg.tmp" 2>/dev/null || yok=0; }
        if [ "$yok" = 1 ]; then mv "$cfg.tmp" "$cfg"; cb_ok=1; ok "added platform_toolsets.${plat} = [terminal, code_execution, file, web]."
        else warn "edit would break the YAML — kept your original (backup made); add the toolset manually."; rm -f "$cfg.tmp"; fi
      fi
      command -v hermes >/dev/null 2>&1 && info "apply it: restart the gateway (systemctl --user restart hermes-gateway, or 'hermes gateway' stop+start)."
      if [ "$cb_ok" = 1 ]; then ok "Command-back ON — after the gateway restart, from $plat you can run 'ace loop status' · 'ace logs' · any command (locked to ${myid})."
      else warn "Command-back NOT active — 'terminal' isn't in platform_toolsets.${plat} yet. Add it (see the backup) + restart the gateway, then re-check with: hermes send --list ${plat}."; fi
    fi
  fi
  # --- optional: a periodic status digest via Hermes's own cron (no-agent: delivers the script's stdout) ---
  local dig="$HOME/.hermes/scripts/ace-loop-digest.sh"
  if [ -f "$dig" ] && hermes cron --help >/dev/null 2>&1 && confirm "Register a periodic loop-status digest to '$to' via hermes cron (silent when idle)?" N; then
    local every; ask "How often? (e.g. 30m · every 2h · '0 9 * * *')" "30m"; every="$ASK_REPLY"
    if hermes cron create "$every" --name ace-loop-digest --deliver "$to" --script ace-loop-digest.sh --no-agent >/dev/null 2>&1; then
      ok "Digest scheduled ($every → $to). Manage: hermes cron list · hermes cron pause ace-loop-digest."
    else warn "hermes cron create failed — register manually: hermes cron create '$every' --name ace-loop-digest --deliver $to --script ace-loop-digest.sh --no-agent"; fi
  fi
  box "Watch + control the loop from your phone" \
    "WATCH — answer Y to the Hermes prompt at 'ace autorun' (or set HERMES_NOTIFY=1)." \
    "        Pushed milestones: started · merged · deployed · CI-red · rathole · stopped." \
    "TAIL (live) — from your chat (Telegram/Signal/…) ask the bot (needs the terminal toolset, below):" \
    "        tail -n 40 <project>/.opencode/last-run.log" \
    "COMMAND-BACK — enable Hermes's TERMINAL toolset so the bot can run host commands:" \
    "        hermes chat -t terminal   (or add 'terminal' to toolsets in ~/.hermes/config.yaml)" \
    "        then from chat: 'run ace logs' · 'ace resume' · 'stop the loop'" \
    "SECURITY — the terminal toolset gives the bot a host shell; lock it to YOU (Telegram user id, or Signal SIGNAL_ALLOWED_USERS=<your +E.164>)."
  ensure_hermes_skill   # keep the chat conductor's 'ace' skill in lockstep with this CLI version
  ok "Done. Notifications opt-in per run; the target is saved (HERMES_TO=$to)."
}

# Internal ExecStart target for the systemd user service: a NON-interactive loop run for $1 (or the
# saved LOOP_PROJECT). `ace` self-bootstraps PATH + secrets at startup, so systemd's bare env is fine.
loop_service_run() {
  local proj="${1:-$(config_get LOOP_PROJECT 2>/dev/null)}"
  [ -n "$proj" ] && cd "$proj" 2>/dev/null || { err "loop-service: no project (run 'ace loop start' in your project first)"; exit 1; }
  [ -f scripts/auto-loop.sh ] || gen_autoloop "$proj"
  set -a; [ -f .opencode/loop.env ] && . .opencode/loop.env; set +a
  if command -v systemd-inhibit >/dev/null 2>&1; then
    exec systemd-inhibit --what=idle:sleep:handle-lid-switch --why="ace loop" bash scripts/auto-loop.sh
  else exec bash scripts/auto-loop.sh; fi
}

# Write the ace-loop systemd USER unit for $1=<project> to $2=<unit path>. The OOM/restart guards live HERE
# (not inlined) so every machine gets them the same way — via `ace loop start`, `ace loop restart`, and the
# ensure_loop_unit self-heal on `ace update`. Reads LOOP_MEMORY_LOW from env (default 1G; 0 to omit).
write_loop_unit() {
  local proj="$1" unit="$2" mlow="${LOOP_MEMORY_LOW:-1G}"
  mkdir -p "$(dirname "$unit")"
  { echo "[Unit]"; echo "Description=ACE autorun loop — $proj"; echo "After=network-online.target"
    # Bound a genuinely-broken crash-loop: >6 restarts in 10min ⇒ systemd gives up (check 'ace loop logs').
    echo "StartLimitIntervalSec=600"; echo "StartLimitBurst=6"
    echo "[Service]"; echo "Type=simple"; echo "ExecStart=$(command -v ace) loop-service $proj"
    # Auto-recover from an OOM-kill / crash — the loop comes back and RESUMES (scans for in-flight work; state
    # persists). on-abnormal = restart on a SIGNAL (OOM=SIGKILL, crash=SIGSEGV) or timeout, NOT on any exit code
    # — so the loop's OWN deliberate halts (clean exit 0, or an 'exit 1' like "REFUSING to resume: WIP fails
    # ci.sh") are respected, not flapped. 'ace loop stop' never restarts. OOMPolicy=continue keeps the loop
    # alive if only a child (e.g. vitest) is culled.
    echo "Restart=on-abnormal"; echo "RestartSec=20"; echo "OOMPolicy=continue"
    # OOM-AVOIDANCE: a user process can't get a protective (negative) oom_score_adj without root, but the memory
    # controller is delegated to the user manager, so MemoryLow shields this much of the loop's RAM from reclaim
    # → the kernel prefers other victims (e.g. a game). Tune/disable via LOOP_MEMORY_LOW (2G = more headroom, 0 =
    # omit). Use MemoryMin for a HARD reservation.
    [ -n "$mlow" ] && [ "$mlow" != 0 ] && { echo "MemoryAccounting=yes"; echo "MemoryLow=$mlow"; }
    echo "KillSignal=SIGTERM"; echo "TimeoutStopSec=40"
    echo "[Install]"; echo "WantedBy=default.target"; } > "$unit"
}

# Self-heal an ALREADY-installed ace-loop.service to the current unit (OOM/restart guards) on `ace update`, so
# machines that installed the loop before these guards shipped pick them up without a manual fresh start.
# Regenerates + daemon-reload only; does NOT restart a running loop (takes effect on its next start/restart).
ensure_loop_unit() {
  local unit="$HOME/.config/systemd/user/ace-loop.service" proj
  [ -f "$unit" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  grep -q '^Restart=on-abnormal' "$unit" && grep -q '^MemoryLow=' "$unit" && return 0   # already current
  proj="$(config_get LOOP_PROJECT 2>/dev/null)"
  [ -n "$proj" ] || proj="$(sed -n 's/^ExecStart=.* loop-service //p' "$unit" | head -1)"
  [ -n "$proj" ] || return 0
  LOOP_MEMORY_LOW="${LOOP_MEMORY_LOW:-1G}" write_loop_unit "$proj" "$unit"
  systemctl --user daemon-reload 2>/dev/null || true
  info "refreshed ace-loop.service with OOM/restart guards (effect on next 'ace loop start'/'restart')."
}

# `ace loop {start|stop|restart|status|logs|update}` — drive the loop as a detached systemd USER service
# (survives terminal-close + sleep), so you can steer it from Hermes/Signal. Bare `ace loop` = interactive.
loop_ctl() {
  local action="$1" unit="$HOME/.config/systemd/user/ace-loop.service" proj
  command -v systemctl >/dev/null 2>&1 || { err "systemctl --user is unavailable here — can't run the loop as a service."; return 1; }
  case "$action" in
    start)
      proj="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
      { [ -f "$proj/scripts/auto-loop.sh" ] || [ -e "$proj/ci.sh" ]; } || { err "no loop project here ($proj) — cd to your project (needs ci.sh / scripts/auto-loop.sh)."; return 1; }
      config_set LOOP_PROJECT "$proj"
      if [ ! -f "$proj/.opencode/loop.env" ]; then
        mkdir -p "$proj/.opencode"
        # Capture the LAUNCH-TIME policy from the environment — the detached service inherits NONE of your
        # shell env, so anything not written here (channel, opt-ins, approval mode) silently won't apply.
        { echo "# ace loop run-config (read by the service). Edit, then: ace loop restart"
          echo "AUTOMERGE=${AUTOMERGE:-1}"; echo "LOCAL_CI_FALLBACK=${LOCAL_CI_FALLBACK:-1}"; echo "MAX_FEATURES=${MAX_FEATURES:-0}"
          echo "DEPLOY=${DEPLOY:-0}"; echo "VERIFY=${VERIFY:-0}"
          echo "HERMES_NOTIFY=${HERMES_NOTIFY:-$([ -n "$(config_get HERMES_TO 2>/dev/null)" ] && echo 1 || echo 0)}"
          echo "HERMES_TO=${HERMES_TO:-$(config_get HERMES_TO 2>/dev/null || echo telegram)}"
          echo "HERMES_KANBAN=${HERMES_KANBAN:-0}"; echo "HERMES_SNAP=${HERMES_SNAP:-0}"
          echo "MERGE_APPROVAL=${MERGE_APPROVAL:-}"
          [ -n "${HERMES_SUBJECT:-}" ] && echo "HERMES_SUBJECT=${HERMES_SUBJECT}"
          [ -n "${SELF_IMPROVE:-}" ] && echo "SELF_IMPROVE=${SELF_IMPROVE}"
        } > "$proj/.opencode/loop.env"
        info "wrote run-config (captured launch env) → $proj/.opencode/loop.env (edit to taste)"
      fi
      write_loop_unit "$proj" "$unit"
      systemctl --user daemon-reload 2>/dev/null
      if systemctl --user start ace-loop.service 2>/dev/null; then
        ok "loop started as a user service (ace-loop) → $proj"
        info "watch: 'ace loop logs' · stop: 'ace loop stop' · survives terminal-close + auto-restarts on OOM/crash/error (resumes). Boot-survival: 'loginctl enable-linger'."
      else err "start failed — see 'ace loop logs'."; fi
      ;;
    stop)    systemctl --user stop ace-loop.service 2>/dev/null && ok "loop stopped (SIGTERM → clean shutdown, no orphans)." || warn "loop not running." ;;
    restart)
      proj="$(config_get LOOP_PROJECT 2>/dev/null)"
      [ -n "$proj" ] && { write_loop_unit "$proj" "$unit"; systemctl --user daemon-reload 2>/dev/null; }   # pick up guard/unit changes
      systemctl --user restart ace-loop.service 2>/dev/null && ok "loop restarted (unit refreshed)." || err "restart failed — see 'ace loop logs'." ;;
    status)
      local here running rpid rmode d
      proj="$(config_get LOOP_PROJECT 2>/dev/null)"; here="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
      running=""; rpid=""; rmode=""
      if systemctl --user is-active ace-loop.service >/dev/null 2>&1; then
        running="service (since $(systemctl --user show -p ActiveEnterTimestamp --value ace-loop.service 2>/dev/null))"
      else  # foreground autorun? a live heartbeat (pid alive) in LOOP_PROJECT or the current repo
        for d in "$proj" "$here"; do
          [ -n "$d" ] && [ -f "$d/.opencode/loop-state.env" ] || continue
          rpid="$(grep -E '^pid=' "$d/.opencode/loop-state.env" | cut -d= -f2-)"; rmode="$(grep -E '^mode=' "$d/.opencode/loop-state.env" | cut -d= -f2-)"
          if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; then running="${rmode:-foreground} (pid $rpid)"; proj="$d"; break; fi
        done
      fi
      if [ -n "$running" ]; then ok "loop: RUNNING — $running"; else warn "loop: not running."; fi
      [ -n "$proj" ] && { echo "  project: $proj"; echo "  last output:"; tail -n 6 "$proj/.opencode/last-run.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/    /'; }
      ;;
    logs|tail)
      proj="$(config_get LOOP_PROJECT 2>/dev/null)"
      if [ -n "$proj" ] && [ -f "$proj/.opencode/last-run.log" ]; then tail -n "${ACE_LOG_LINES:-40}" "$proj/.opencode/last-run.log" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
      else journalctl --user -u ace-loop.service -n 40 --no-pager 2>/dev/null || warn "no logs yet."; fi
      ;;
    stats|metrics)
      proj="$(config_get LOOP_PROJECT 2>/dev/null)"; [ -d "$proj/.opencode" ] || proj="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
      local sm="$proj/.opencode/run-summary.txt" cv="$proj/.opencode/metrics.csv"
      if [ -f "$sm" ]; then step "Run post-mortems (newest last) — $sm"; tail -n "${ACE_STATS_LINES:-44}" "$sm"
      else warn "no run-summary yet — it's written when an 'ace autorun' loop ends (or is stopped)."; fi
      [ -f "$cv" ] && info "per-step CSV ($(($(wc -l <"$cv" 2>/dev/null)-1)) rows): $cv — e.g.  column -ts, '$cv' | less -S"
      ;;
    up|update)
      proj="$(config_get LOOP_PROJECT 2>/dev/null)"
      step "Bringing ACE + project up to date"
      ( cd "${ACE_DIR:-$(dirname "$(readlink -f "$(command -v ace 2>/dev/null)" 2>/dev/null)" 2>/dev/null)}" 2>/dev/null && git pull --ff-only 2>&1 | tail -2 ) || true
      # REFUSE on a dirty tree. This used to be `checkout -f main` with everything /dev/null'd: it
      # DISCARDED uncommitted work in the user's project and said nothing. It also used `;` after the
      # cd, so a failed cd still ran `git pull` in the CALLER's repo. Both are now &&-chained, the
      # checkout is a plain (non-forcing) one, and a dirty tree stops the update instead of eating it.
      if [ -n "$proj" ]; then
        if [ -n "$(git -C "$proj" status --porcelain 2>/dev/null)" ]; then
          warn "$proj has uncommitted changes — NOT touching it (this used to 'checkout -f main' and discard them)."
          say  "    Commit or stash there, then re-run: ${C_BOLD}ace loop update${C_RESET}"
        else
          ( cd "$proj" && git checkout main >/dev/null 2>&1 && git pull --ff-only 2>&1 | tail -2 ) \
            || warn "project update skipped — could not switch to main / fast-forward in $proj."
        fi
      fi
      ok "updated. Run 'ace loop restart' to apply (driver/config changes need a fresh loop)."
      ;;
    *) err "usage: ace loop {start|stop|restart|status|logs|stats|update}   (bare 'ace loop' = interactive launcher)"; return 1 ;;
  esac
}

# `ace awake on [<dur>] | off | status` — hold a systemd-inhibit lock so the machine won't idle-sleep
# or suspend on lid-close. Lets you reach it from Hermes/Signal while away (you can't wake a sleeping
# laptop over chat). `on <dur>` (e.g. 4h / 30m) auto-releases; bare `on` holds until `ace awake off`.
awake_ctl() {
  local action="${1:-status}" dur="${ACE_ARG2:-}" unit="$HOME/.config/systemd/user/ace-awake.service"
  { command -v systemctl >/dev/null 2>&1 && command -v systemd-inhibit >/dev/null 2>&1; } || { err "needs systemctl --user + systemd-inhibit (systemd-logind)."; return 1; }
  case "$action" in
    on)
      local sleeparg="${dur:-infinity}"
      mkdir -p "$(dirname "$unit")"
      { echo "[Unit]"; echo "Description=ACE keep-awake — machine stays reachable for remote control (Hermes/Signal)"
        echo "[Service]"; echo "Type=simple"
        echo "ExecStart=$(command -v systemd-inhibit) --what=idle:sleep:handle-lid-switch --who=ace --why=remote-control --mode=block sleep $sleeparg"
        echo "Restart=on-failure"; } > "$unit"
      systemctl --user daemon-reload
      if systemctl --user start ace-awake.service 2>/dev/null; then
        ok "keep-awake ON — won't idle-sleep or suspend on lid-close${dur:+ (auto-off after $dur)}."
        info "off: 'ace awake off' · check: 'ace awake status'. Battery: it stays awake until then."
      else err "failed to start — see 'journalctl --user -u ace-awake'."; fi
      ;;
    off) systemctl --user stop ace-awake.service 2>/dev/null && ok "keep-awake OFF — normal sleep restored." || warn "keep-awake was not on." ;;
    status|"")
      if systemctl --user is-active ace-awake.service >/dev/null 2>&1; then
        ok "keep-awake: ON"
        systemd-inhibit --list 2>/dev/null | grep -iE 'ace|remote-control' | head -1 | sed 's/^/  /'
      else warn "keep-awake: OFF — the machine can sleep (won't be reachable while suspended)."; fi
      ;;
    *) err "usage: ace awake {on [<duration e.g. 4h>] | off | status}"; return 1 ;;
  esac
}
# Sanity-check the delivery policy before a run. Returns non-zero only for a HARD blocker (git=false).
delivery_preflight() {
  local gi mg cc; gi="$(_prof_get git)"; mg="$(_prof_get merge_gate)"; cc="$(_prof_get ci_cd)"
  if [ "$gi" = false ]; then err "profile git=false, but the autorun loop needs git + gh (push/PR/CI). Set git: true ('ace profile')."; return 1; fi
  # The loop is PR-based: it pushes a branch and opens a PR regardless of merge_gate, so it needs a
  # GitHub 'origin'. Catch it HERE (before the loop spends time on tool/consistency setup then dies at
  # its own deep "no 'origin' remote" exit). 'merge_gate: local' only skips WAITING on Actions — it
  # still needs a remote + PR.
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then err "not a git repo here — run 'ace gitflow' or scaffold with git."; return 1; fi
  if ! git remote get-url origin >/dev/null 2>&1; then
    err "no 'origin' remote — the loop must push a branch + open a PR (even merge_gate=local)."
    info "Create one: ${C_BOLD}cd $(pwd) && ace scaffold --publish${C_RESET} earlier, or publish this repo now: ${C_BOLD}gh repo create --private --source=. --remote=origin && git push -u origin HEAD${C_RESET}"
    return 1
  fi
  # A remote-watching gate (remote OR both) needs remote CI to wait on; warn if there's none.
  case "$mg" in remote|both) [ -n "$cc" ] && [ "$cc" != github-actions ] && warn "merge_gate=$mg but ci_cd=$cc — no remote CI to wait on; consider merge_gate: local ('ace profile')." ;; esac
  return 0
}

# Fail fast if the project's stack tools aren't on PATH — otherwise the orchestrator burns a long rathole
# trying to install them (esp. on immutable hosts where it can't). Returns 1 with a clear fix hint.
_loop_tool_preflight() {
  local lang; lang="$(_prof_get language 2>/dev/null)"
  { [ -z "$lang" ] && [ -f go.mod ]; } && lang=go
  local miss=() t
  case "$lang" in
    go) for t in go gopls; do command -v "$t" >/dev/null 2>&1 || miss+=("$t"); done ;;
  esac
  if [ "${#miss[@]}" -gt 0 ]; then
    err "${lang} toolchain not on PATH: ${miss[*]} — the orchestrator can't build/navigate and will rathole."
    info "Install first:  ace install --yes    then verify:  ace status"
    return 1
  fi
  return 0
}

# Print the resolved delivery policy without running (ace autorun --explain).
autorun_explain() {
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" 2>/dev/null || true
  [ -f .opencode/profile.yaml ] || warn "no .opencode/profile.yaml here — loop defaults apply."
  step "Autorun — resolved delivery policy for $(basename "$root") (no run)"
  local mg dk amp cc; mg="${MERGE_GATE:-$(_prof_get merge_gate)}"; mg="${mg:-remote}"; dk="$(_prof_get deploy_kind)"; dk="${dk:-service}"
  cc="$(_prof_get ci_cd)"; case "$mg" in remote|both) [ -n "$cc" ] && [ "$cc" != github-actions ] && mg="local (forced — ci_cd=$cc, no Actions to watch)" ;; esac
  case "$(_prof_get auto_merge)" in true|yes|1) amp=1 ;; *) amp=0 ;; esac
  printf '  shape        : %s\n' "$(_prof_get shape | sed 's/^$/<none>/')"
  printf '  merge_gate   : %s   (env MERGE_GATE overrides)\n' "$mg"
  printf '  auto_merge   : %s   (env AUTOMERGE overrides)\n' "${AUTOMERGE:-$amp}"
  printf '  deploy_kind  : %s\n' "$dk"
  printf '  git / ci_cd  : %s / %s\n' "$(_prof_get git | sed 's/^$/true/')" "$(_prof_get ci_cd | sed 's/^$/?/')"
  printf '  caps         : MAX_FEATURES=%s MAX_FIX=%s MAX_PLANS=%s RESOLVE_CONFLICTS=%s\n' "${MAX_FEATURES:-3}" "${MAX_FIX:-5}" "${MAX_PLANS:-5}" "${RESOLVE_CONFLICTS:-1}"
  hr; delivery_preflight && ok "delivery policy OK." || true
}

autoloop_run() {
  banner; step "Autonomous PR loop (watch CI -> autofix -> next roadmap item)"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" || return 1
  delivery_preflight || return 1   # hard-stop on a contradictory delivery policy (e.g. git=false)
  # Guard: a loop project needs a ./ci.sh gate. Without one (and not already set up), this is almost
  # always the wrong directory (e.g. ACE's own repo) — refuse clearly BEFORE bootstrapping scaffold
  # files into it, instead of later reporting the missing gate as "uncommitted work FAILS ./ci.sh".
  if [ ! -e ci.sh ] && [ ! -f scripts/auto-loop.sh ]; then
    err "No ./ci.sh gate in $root — this doesn't look like a loop project."
    info "cd to your project directory, or set one up first: 'ace scaffold' (new) / 'ace upgrade' (existing)."
    return 1
  fi
  _loop_tool_preflight || return 1   # don't spawn the orchestrator if its stack tools are missing (fail-fast)
  [ -f scripts/auto-loop.sh ] || { info "bootstrapping scripts/auto-loop.sh + ROADMAP.md"; gen_autoloop "$root"; }
  if [ "${REANALYZE:-0}" = 1 ]; then
    box "How it works — REANALYZE (plan-only, no implement)" \
      "snapshot your OPEN features -> re-derive each from scratch: research ->" \
      "re-spec (template + EARS + cited) -> spec-lint gate$([ "${SPEC_DEBATE:-0}" = 1 ] && echo ' + cross-model DEBATE') -> re-slice ->" \
      "STOP. Inspect: ace reanalyze report. Then run a normal loop to build it."
  else
    box "How it works" \
      "watch the PR's CI -> on failure feed the log to opencode -> it fixes + pushes ->" \
      "re-watch -> when ALL checks green + mergeable, squash-merge -> pull main ->" \
      "implement the next ROADMAP item. Caps stop runaway."
  fi
  local sm dp vf lf mf si ig fa hn fxf fixn _yn par
  fxf="${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}"; fixn=0   # guard: '<missing-file' errors even with 2>/dev/null
  [ -f "$fxf" ] && fixn="$(wc -l <"$fxf" 2>/dev/null || echo 0)"
  _yn() { [ "${1:-0}" = 1 ] && echo Y || echo N; }
  if _noninteractive; then
    # headless (ace autorun --yes, or driven from Hermes/Signal): policy from env, NO prompts, auto-start.
    # auto-merge default comes from the PROFILE's auto_merge (env AUTOMERGE still overrides) — don't hardcode
    # 1, or a profile that set auto_merge:false would be silently self-merged in headless runs.
    local _pam; _pam="$(_prof_get auto_merge 2>/dev/null)"; case "$_pam" in true|yes|1) _pam=1 ;; *) _pam=0 ;; esac
    sm="${AUTOMERGE:-$_pam}"; dp="${DEPLOY:-0}"; vf="${VERIFY:-0}"; lf="${LOCAL_CI_FALLBACK:-0}"
    mf="${MAX_FEATURES:-3}"; si="${SELF_IMPROVE:-0}"; ig="${IMPROVE_GOAL:-generate income · solve real user problems · professional, reliable UX}"
    fa="${FIX_ACE:-0}"; hn="${HERMES_NOTIFY:-0}"; par="${SWARM_MAX:-1}"   # SWARM_MAX>1 (env) → parallel swarm, headless
    info "headless: AUTOMERGE=$sm DEPLOY=$dp VERIFY=$vf LOCAL_CI_FALLBACK=$lf MAX_FEATURES=$mf SELF_IMPROVE=$si FIX_ACE=$fa HERMES_NOTIFY=$hn PARALLEL=$par"
  else
    # interactive: prompt, but the env vars become the pre-selected DEFAULTS (so AUTOMERGE=1 pre-picks Y)
    sm=1; confirm "Self-merge PRs once EVERYTHING is green + mergeable (to keep the loop going)?" "$(_yn "${AUTOMERGE:-1}")" && sm=1 || sm=0
    dp=0; vps_configured && confirm "Deploy to the VPS after each merge (loop-driven)?" "$(_yn "${DEPLOY:-0}")" && dp=1
    vf=0; [ "$dp" = 1 ] && confirm "After each deploy, run the verify agent (triage live errors/improvements into ROADMAP)?" "$(_yn "${VERIFY:-1}")" && vf=1
    lf=0; confirm "If GitHub Actions is BLOCKED (billing/infra: a run that fails having executed no jobs), accept a GREEN local ./ci.sh --container as the pass and merge?" "$(_yn "${LOCAL_CI_FALLBACK:-0}")" && lf=1
    ask "Feature cap for this run (0 = unlimited, run until stopped)" "${MAX_FEATURES:-3}"; mf="$ASK_REPLY"
    ask "Parallel flows — SWARM (1 = single loop · 2-5 = parallel workers, path-disjoint + self-merging)" "${SWARM_MAX:-$(config_get SWARM_MAX 2>/dev/null || echo 1)}"; par="$ASK_REPLY"
    si=0; ig="${IMPROVE_GOAL:-}"
    if confirm "When all objectives are done, keep improving the project toward an end goal?" "$(_yn "${SELF_IMPROVE:-0}")"; then
      si=1; ask "Optimize self-improvement toward (the system's end goal)" "${ig:-generate income · solve real user problems · professional, reliable UX}"; ig="$ASK_REPLY"
    fi
    fa="${FIX_ACE:-0}"
    [ "${fixn:-0}" -gt 0 ] && { confirm "Triage ACE first from $fixn rathole note(s) (files a GitHub issue for you to fix — never edits ACE's code)?" "$(_yn "$fa")" && fa=1 || fa=0; }
    hn="${HERMES_NOTIFY:-0}"
    command -v hermes >/dev/null 2>&1 && { confirm "Push milestone notifications to Hermes (→ Signal/Telegram/phone)?" "$(_yn "$hn")" && hn=1 || hn=0; }
    warn "$([ "${par:-1}" -ge 2 ] && echo "PARALLEL=${par} (swarm)" || echo 'single flow')  self-merge=$sm  deploy=$dp  verify=$vf  local-ci-fallback=$lf  hermes=$hn  features=$([ "$mf" = 0 ] && echo '∞' || echo "$mf")  self-improve=$si  fix-ace=$fa  MAX_FIX=${MAX_FIX:-5}. Merges ONLY when every check passes + no conflicts (or local gate vouches on a blocked CI). Ctrl-C stops."
    confirm "Start the loop now?" Y || { info "Not started. Run: FIX_ACE=$fa AUTOMERGE=$sm DEPLOY=$dp VERIFY=$vf LOCAL_CI_FALLBACK=$lf HERMES_NOTIFY=$hn MAX_FEATURES=$mf SELF_IMPROVE=$si IMPROVE_GOAL=$(printf %q "$ig") bash scripts/auto-loop.sh"; return; }
  fi
  par="${par//[!0-9]/}"; [ -z "$par" ] && par=1; [ "$par" -lt 1 ] && par=1; [ "$par" -gt 8 ] && par=8   # cap parallelism at 8
  [ "${REANALYZE:-0}" = 1 ] && { par=1; info "REANALYZE=1 → solo plan-only re-assessment (re-derive breakdown, no implement); inspect: ace reanalyze report"; }   # re-assessment always takes the solo plan-only path
  config_set SWARM_MAX "$par" 2>/dev/null || true   # remember the choice → next run defaults to it
  export AUTOMERGE="$sm" DEPLOY="$dp" VERIFY="$vf" LOCAL_CI_FALLBACK="$lf" HERMES_NOTIFY="$hn" HERMES_TO="${HERMES_TO:-$(config_get HERMES_TO 2>/dev/null || echo telegram)}" HERMES_SUBJECT="${HERMES_SUBJECT:-}" MAX_FEATURES="$mf" SELF_IMPROVE="$si" IMPROVE_GOAL="$ig" FIX_ACE="$fa"
  export MERGE_APPROVAL="${MERGE_APPROVAL:-}" APPROVAL_TIMEOUT="${APPROVAL_TIMEOUT:-3600}"   # MERGE_APPROVAL=hermes ⇒ ask in chat before each merge (ace approve)
  export HERMES_KANBAN="${HERMES_KANBAN:-0}" HERMES_SNAP="${HERMES_SNAP:-0}"   # opt-in chat extras: mirror ROADMAP→kanban · attach a CLI snapshot to notifies (must reach the loop child)
  ace_fixme_gate "$fa"; cd "$root" || return 1   # issue-filing ACE triage now, if the setting is on
  # DEPLOY=1 needs a provisioned VPS. The interactive path already gates dp=1 on vps_configured, but a
  # headless DEPLOY=1 (env / Hermes) doesn't — warn so every post-merge deploy doesn't silently fail.
  if [ "$dp" = 1 ] && [ "$(_prof_get deploy_kind)" = service ] && ! vps_configured; then
    warn "DEPLOY=1 + deploy_kind=service but no VPS is configured — post-merge deploys will fail. Configure + provision first ('ace vps'), or run without DEPLOY=1."
  fi
  # ── PARALLEL (swarm) vs SINGLE flow ─────────────────────────────────────────
  # par>=2 → hand off to the swarm coordinator (path-disjoint parallel workers,
  # each self-merging; watch with `ace swarm dash`). par=1 → the classic single loop.
  if [ "${par:-1}" -ge 2 ]; then
    if [ ! -d .git ] || ! git remote get-url origin >/dev/null 2>&1; then
      warn "swarm needs a GitHub remote (it merges via PRs). Run 'ace publish' first, or use 1 (single loop)."; return 1
    fi
    step "SWARM · $par parallel flows (cap 8) — path-disjoint, self-merging, self-healing"
    # PASS THE USER'S ANSWERS THROUGH. This hardcoded AUTOMERGE=1, so answering "no self-merge" and
    # then choosing 2-5 parallel flows self-merged anyway — the prompt was decorative the moment you
    # picked a swarm. Forward the real answers ($sm self-merge, $mf cap, $dp deploy) + debate toggles.
    # startd's exit status is the ONLY signal that the coordinator actually came up. It used to be
    # discarded, so a coordinator that died on launch still printed "the forge is lit" and auto-attached
    # a dash to nothing — the user watched an empty cockpit believing work was in flight. Fail closed.
    if ! ( cd "$root" && SWARM_LIVE=1 DRY_RUN=0 SWARM_REPO="$root" SWARM_MAX="$par" \
        AUTOMERGE="$sm" MAX_FEATURES="$mf" DEPLOY="$dp" \
        SPEC_DEBATE="${SPEC_DEBATE:-0}" REVIEW_DEBATE="${REVIEW_DEBATE:-0}" \
        HERMES_NOTIFY="$hn" bash "$ACE_DIR/lib/swarm-run.sh" startd ); then
      err "swarm coordinator failed to start — nothing is running."
      say  "    Diagnose: ${C_BOLD}ace swarm status${C_RESET} · ${C_BOLD}ace swarm logs${C_RESET}   (then re-run 'ace autorun')"
      return 1
    fi
    box "the forge is lit — $par workers" \
      "watch    ace swarm dash      (live cockpit: per-worker stage pipeline)" \
      "columns  ace swarm split     (tmux — one pane per worker)" \
      "status   ace swarm status  ·  tail  ace swarm tail" \
      "control  ace swarm pause | resume | drain | kill wN | stop"
    # auto-attach the live cockpit (interactive terminals only). q quits the VIEW; the
    # detached swarm keeps running — re-attach anytime with `ace swarm dash`.
    if [ -t 1 ] && [ -t 0 ] && [ "${ACE_NO_DASH:-0}" != 1 ]; then
      info "opening the dashboard — press q to exit the view (the swarm keeps running in the background)…"
      sleep 2
      ( cd "$root" && SWARM_REPO="$root" bash "$ACE_DIR/lib/swarm-run.sh" dash )
    fi
    return 0
  fi
  # run at reduced CPU/IO priority so the loop never starves your foreground (desktop, a game…);
  # it still uses idle cores. Disable with ACE_NICE=0.
  local nice=""
  if [ "${ACE_NICE:-1}" = 1 ] && command -v nice >/dev/null 2>&1; then nice="nice -n 10"; command -v ionice >/dev/null 2>&1 && nice="$nice ionice -c3"; fi
  if command -v systemd-inhibit >/dev/null 2>&1; then
    info "keeping the system awake for the run (auto-releases when it ends)${nice:+ · low-priority ($nice)}"
    $nice systemd-inhibit --what=idle:sleep:handle-lid-switch --why="ace autorun" --mode=block bash scripts/auto-loop.sh
  else
    $nice bash scripts/auto-loop.sh
  fi
}

# ---------------------------------------------------------------- idempotent file installers
# Each writes only if missing (preserves user customization), reports added/kept.
ensure_graph_refresh() {
  [ -f scripts/graph-refresh.sh ] && { info "kept scripts/graph-refresh.sh"; return; }
  mkdir -p scripts
  cat > scripts/graph-refresh.sh <<'EOF'
#!/usr/bin/env bash
# Refresh the code map (GitNexus graph + Serena symbols) and regenerate docs/architecture.md.
set -uo pipefail
cd "$(dirname "$0")/.."
# In a swarm flow, skip re-analyze: it rewrites tracked snapshot files (docs/architecture.md +
# the GitNexus stat blocks in AGENTS.md/CLAUDE.md) which churn across parallel branches and get
# swept into unrelated PRs. Agents navigate off the run-start index (close enough per item). GRAPH_FORCE=1 overrides.
[ -n "${SWARM_WORKER:-}" ] && [ "${GRAPH_FORCE:-0}" != 1 ] && { echo "[graph] swarm flow — skip re-analyze (avoid tracked-file churn)"; exit 0; }
# Skip the (slow) re-analyze when NOTHING changed since last time — agents call this before AND after
# every subtask, so back-to-back runs with no code change in between are pure waste (a single session
# spent ~21 min here). Signature = HEAD + uncommitted tracked diff + untracked files. GRAPH_FORCE=1 overrides.
sig="$(git rev-parse HEAD 2>/dev/null):$( { git diff HEAD -- . ':(exclude)docs/architecture.md' ':(exclude).gitnexus' 2>/dev/null
        git ls-files --others --exclude-standard -- . ':(exclude)docs/architecture.md' ':(exclude).gitnexus' 2>/dev/null; } | sha1sum 2>/dev/null | cut -c1-16)"
stamp=".gitnexus/.analyze-sig"
if [ "${GRAPH_FORCE:-0}" != 1 ] && [ -f "$stamp" ] && [ -f docs/architecture.md ] && [ "$(cat "$stamp" 2>/dev/null)" = "$sig" ]; then
  echo "[graph] code unchanged since last analyze — skipping (GRAPH_FORCE=1 to force)"; exit 0
fi
# GITNEXUS_PDG=1 → deeper index: build the control-flow/PDG substrate so `impact --mode pdg` gets
# statement-level blast radius (slower; opt-in). Default stays the fast callgraph index.
out="$(CI=1 timeout -k 10 900 npx -y gitnexus@latest analyze ${GITNEXUS_PDG:+--pdg} </dev/null 2>&1)"; printf '%s\n' "$out" | tail -3
printf 'N\nN\nN\n' | CI=1 timeout -k 10 600 uvx --from git+https://github.com/oraios/serena serena project index >/dev/null 2>&1 || true
mkdir -p docs
counts="$(printf '%s\n' "$out" | grep -oE '[0-9,]+ nodes \| [0-9,]+ edges \| [0-9,]+ clusters \| [0-9,]+ flows' | head -1)"
{
  echo "# Architecture map (generated — do not edit by hand)"
  echo
  echo "Regenerate with \`scripts/graph-refresh.sh\` or \`ace graph\`. The live, full map is the GitNexus"
  echo "graph + Serena symbols; this file is a committed snapshot + a CI freshness check."
  echo
  [ -n "$counts" ] && { echo "**Graph:** $counts"; echo; }
  echo "## How to navigate (agents do this first, every task)"
  echo "- SHARED index hosts MANY repos — pass \`repo: \"<this repo's dir name>\"\` on EVERY call (see .opencode/project-facts.md), else it errors."
  echo "- \`query({concept, repo})\` -> flows;  \`context({symbol, repo})\` -> callers/callees/flows"
  echo "- \`impact({target, direction, repo})\` -> all connections of a symbol"
  echo "- Serena \`find_referencing_symbols\` -> every exact usage (live)"
} > docs/architecture.md
mkdir -p .gitnexus 2>/dev/null && printf '%s\n' "$sig" > "$stamp" 2>/dev/null || true   # remember this state so an unchanged re-run is skipped
echo "[graph] code map + docs/architecture.md refreshed"
EOF
  chmod +x scripts/graph-refresh.sh; ok "added scripts/graph-refresh.sh"
}

ensure_atlas_refresh() {
  local ver=3 act=added   # bump `ver` (+ the 'atlas-gen-version:' stamp in the emitted script) when the generator changes, so `ace upgrade` refreshes an outdated copy instead of keeping the buggy one.
  if [ -f scripts/atlas-refresh.sh ]; then
    grep -q "atlas-gen-version: $ver" scripts/atlas-refresh.sh 2>/dev/null && { info "kept scripts/atlas-refresh.sh (v$ver)"; return; }
    act=updated   # present but an older version → rewrite so ace generator fixes propagate
  fi
  mkdir -p scripts
  cat > scripts/atlas-refresh.sh <<'ATLAS_GEN_EOF'
#!/usr/bin/env bash
# atlas-refresh.sh — regenerate the human Architecture Atlas (docs/atlas.md) + the README system-map block.
# Deterministic + REAL: a Node/TS monorepo becomes its actual workspace dependency graph (grouped by layer),
# a layer data-flow, and a module reference table (fan-in/fan-out) — all from package.json, no LLM. Other
# repos fall back to a top-level-dir import graph. NEVER fabricates a diagram. Optional narrative enriches roles.
# Runs on main after merge (autoloop, every MAP_EVERY) and on demand (`ace atlas`). NEVER in swarm workers.
# atlas-gen-version: 3
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0

[ "${ATLAS:-1}" = 0 ] && { echo "[atlas] disabled (ATLAS=0)"; exit 0; }

# Swarm flow: skip — regenerating tracked files churns across parallel worktrees and gets swept into
# unrelated PRs (identical guard to graph-refresh). ATLAS_FORCE=1 overrides.
[ -n "${SWARM_WORKER:-}" ] && [ "${ATLAS_FORCE:-0}" != 1 ] && { echo "[atlas] swarm flow — skip (avoid tracked-file churn)"; exit 0; }

# Skip when nothing changed since last time (excluding the files we generate). ATLAS_FORCE=1 overrides.
sig="$(git rev-parse HEAD 2>/dev/null):$( { \
  git diff HEAD -- . ':(exclude)docs/atlas.md' ':(exclude)README.md' ':(exclude).gitnexus' 2>/dev/null
  git ls-files --others --exclude-standard -- . ':(exclude)docs/atlas.md' ':(exclude)README.md' 2>/dev/null; \
  } | sha1sum 2>/dev/null | cut -c1-16)"
stamp=".opencode/.atlas-sig"
if [ "${ATLAS_FORCE:-0}" != 1 ] && [ -f "$stamp" ] && [ -f docs/atlas.md ] && [ "$(cat "$stamp" 2>/dev/null)" = "$sig" ]; then
  echo "[atlas] unchanged since last run — skipping (ATLAS_FORCE=1 to force)"; exit 0
fi

mkdir -p docs .opencode
HEAD_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
# provenance timestamp = the COMMIT date (strict ISO, from the commit itself, not wall-clock) so regenerating
# at the same SHA is byte-identical — a stale page then reads as visibly stale rather than silently churning.
NOW="$(git show -s --format=%cI HEAD 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
NAME="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"

# ---- 1. REAL architecture from the code (deterministic) ------------------------------------------
_atlas_is_workspace() { [ -f pnpm-workspace.yaml ] || grep -q '"workspaces"' package.json 2>/dev/null; }

# TSV per workspace package: name \t layer(top-dir) \t description \t all-deps. One jq/file (fault-isolated).
_atlas_ws_tsv() {
  local pj name layer
  git ls-files 'package.json' '**/package.json' 2>/dev/null | grep -vE '(^|/)node_modules/' | while IFS= read -r pj; do
    [ -f "$pj" ] || continue
    [ "$pj" = package.json ] && continue   # the monorepo-root manifest is not a module
    name="$(jq -r '.name // empty' "$pj" 2>/dev/null)"; [ -z "$name" ] && continue
    layer="$(printf '%s' "$pj" | awk -F/ '{print (NF>1?$1:"(root)")}')"
    jq -r --arg n "$name" --arg l "$layer" '
      ((.description // "") | gsub("[\t\n\"]";" ") | .[0:70]) as $desc
      | ((.dependencies // {}) + (.devDependencies // {}) | keys | join(",")) as $deps
      | [$n,$l,$desc,$deps] | @tsv' "$pj" 2>/dev/null
  done
}

# awk builds: map (subgraph-per-layer + internal edges) · flow (layer aggregation, data direction) · table.
_atlas_from_tsv() {
  _atlas_ws_tsv | awk -F'\t' -v which="$1" '
    function id(x){ gsub(/^@[^/]+\//,"",x); gsub(/[^A-Za-z0-9]/,"_",x); return x }
    function short(x){ gsub(/^@[^/]+\//,"",x); return x }
    { name[NR]=$1; layer[NR]=$2; desc[NR]=$3; deps[NR]=$4; inset[$1]=1; NL[$1]=$2; n=NR }
    END{
      if (which=="flow"){
        print "flowchart LR"
        for(i=1;i<=n;i++){ m=split(deps[i],dd,","); for(j=1;j<=m;j++) if(dd[j] in inset && dd[j]!=name[i]){
          from=NL[dd[j]]; to=layer[i]; if(from!=to){ e=from SUBSEP to; if(!(e in seen)){ seen[e]=1; ef[++ne]=from; et[ne]=to } } } }
        for(i=1;i<=n;i++){ lid=id(layer[i]); if(!(lid in seenL)){ seenL[lid]=1; printf "  %s([\"%s\"])\n", lid, layer[i] } }
        for(k=1;k<=ne;k++) printf "  %s --> %s\n", id(ef[k]), id(et[k])
      }
      else if (which=="map"){
        print "flowchart LR"
        for(i=1;i<=n;i++){ L=layer[i]; if(!(L in seenL)){ seenL[L]=1; ord[++d]=L } }
        for(k=1;k<=d;k++){ L=ord[k]; printf "  subgraph %s[\"%s\"]\n", id(L), L
          for(i=1;i<=n;i++) if(layer[i]==L) printf "    %s[\"%s\"]\n", id(name[i]), short(name[i])
          print "  end" }
        for(i=1;i<=n;i++){ m=split(deps[i],dd,","); for(j=1;j<=m;j++) if(dd[j] in inset && dd[j]!=name[i])
          printf "  %s --> %s\n", id(name[i]), id(dd[j]) }
      } else {
        for(i=1;i<=n;i++){ m=split(deps[i],dd,","); il=""
          for(j=1;j<=m;j++) if(dd[j] in inset && dd[j]!=name[i]){ il=il (il==""?"":", ") short(dd[j])
            ub[dd[j]]=ub[dd[j]] (ub[dd[j]]==""?"":", ") short(name[i]) }
          intdeps[i]=il }
        print "| Module | Layer | Role | Used by | Depends on |"
        print "|---|---|---|---|---|"
        for(pass=1;pass<=2;pass++) for(i=1;i<=n;i++){ isapp=(layer[i] ~ /app|service/)
          if((pass==1)==isapp){ role=desc[i]; if(role=="") role="—"
            printf "| `%s` | %s | %s | %s | %s |\n", short(name[i]), layer[i], role,
              (ub[name[i]]==""?"—":ub[name[i]]), (intdeps[i]==""?"—":intdeps[i]) } }
      }
    }'
}

# Fallback for non-workspace repos: coarse top-level source-dir import graph (honest, crude).
_atlas_dir_fallback() {
  if [ "$1" = table ]; then printf '| Module | Layer | Role | Used by | Depends on |\n|---|---|---|---|---|\n| _(non-workspace repo — richer module roles need ATLAS_NARRATIVE=1)_ |  |  |  |  |\n'; return; fi
  if [ "$1" = flow ]; then printf 'flowchart LR\n  src(["sources"]) --> %s["%s"]\n' "$(printf '%s' "$NAME"|tr -c '[:alnum:]' '_')" "$NAME"; return; fi
  local dirs; dirs="$(git ls-files 2>/dev/null | grep -E '\.(ts|tsx|js|mjs|py|go|rs|cs|java)$' \
    | grep -E '/' | sed -E 's#/.*##' | sort -u | grep -vE '^(node_modules|dist|build|vendor|test|tests|\.[^/]*)$' | head -12)"
  echo "flowchart LR"
  if [ -z "$dirs" ]; then printf '  root["%s"]\n' "$NAME"; return; fi
  while IFS= read -r x; do [ -n "$x" ] && printf '  %s["%s"]\n' "$(printf '%s' "$x"|tr -c '[:alnum:]' '_')" "$x"; done <<EOD
$dirs
EOD
  while IFS= read -r a; do [ -z "$a" ] && continue; while IFS= read -r b; do { [ -z "$b" ]||[ "$a" = "$b" ]; }&&continue
    git grep -qiE "(import|require|from|use).*\\b$b\\b" -- "$a/" 2>/dev/null && printf '  %s --> %s\n' "$(printf '%s' "$a"|tr -c '[:alnum:]' '_')" "$(printf '%s' "$b"|tr -c '[:alnum:]' '_')"
  done <<EOD
$dirs
EOD
  done <<EOD
$dirs
EOD
}

_ws=0; _atlas_is_workspace && _ws=1
if [ "$_ws" = 1 ]; then SYS_MAP="$(_atlas_from_tsv map)"; DATA_FLOW="$(_atlas_from_tsv flow)"; MODULE_TABLE="$(_atlas_from_tsv table)"
else SYS_MAP="$(_atlas_dir_fallback map)"; DATA_FLOW="$(_atlas_dir_fallback flow)"; MODULE_TABLE="$(_atlas_dir_fallback table)"; fi

# ---- 2. optional grounded narrative (cartographer, DeepSeek) — enriches module ROLES when enabled --
# OFF by default (zero tokens, deterministic). ATLAS_NARRATIVE=1 asks a read-only worker to fill the Role
# column from real code; if it returns a table it replaces the deterministic one, else the structure stands.
if [ "${ATLAS_NARRATIVE:-0}" = 1 ] && command -v opencode >/dev/null 2>&1; then
  NARR="$(CI=1 timeout -k 10 300 opencode run --agent "${ATLAS_AGENT:-cartographer}" </dev/null \
    "For '$NAME', fill the Role column of this module table from REAL code (one grounded phrase each; keep Module/Layer/Used by/Depends on exactly as given; output ONLY the markdown table):
$MODULE_TABLE" </dev/null 2>/dev/null || true)"
  grep -q '| Module ' <<<"$NARR" && MODULE_TABLE="$NARR"
fi

# ---- 3. assemble docs/atlas.md -------------------------------------------------------------------
cat > docs/atlas.md <<EOF
# $NAME — Architecture Atlas

> **Generated — do not edit by hand.** Rebuilt by \`scripts/atlas-refresh.sh\` (\`ace atlas\`), and
> automatically every \`MAP_EVERY\` merged features by the autorun loop.
> Built from commit \`$HEAD_SHA\` at $NOW.
>
> **System map** = the real modules and how they depend on each other · **Data flow** = how data moves
> across layers · **Module map** = every module, what depends on it, and what it depends on.

## System map

\`\`\`mermaid
$SYS_MAP
\`\`\`

## Data flow

\`\`\`mermaid
$DATA_FLOW
\`\`\`

## Module map

$MODULE_TABLE

---

- Mission, values, delivery policy → [ARCHITECTURE.md](../ARCHITECTURE.md)
- Agent-facing code map (GitNexus / Serena) → [docs/architecture.md](architecture.md)
- Regenerate: \`ace atlas\`  ·  disable in a run: \`ATLAS=0\`  ·  cadence: \`MAP_EVERY=N\`  ·  richer roles: \`ATLAS_NARRATIVE=1\`
EOF

# ---- 4. README managed block (create-if-absent, update ONLY between the sentinels) ----------------
_atlas_readme() {
  local start='<!-- ace:atlas:start -->' end='<!-- ace:atlas:end -->' block
  block="$start
## 📐 Architecture Atlas

\`\`\`mermaid
$SYS_MAP
\`\`\`

**Full atlas — data flow + module map → [\`docs/atlas.md\`](docs/atlas.md)**
$end"
  if [ ! -f README.md ]; then
    printf '# %s\n\n%s\n\n_See [ARCHITECTURE.md](ARCHITECTURE.md) for mission & [OBJECTIVES.md](OBJECTIVES.md) for goals._\n' "$NAME" "$block" > README.md
    echo "[atlas] created README.md with atlas block"; return 0
  fi
  if grep -qF "$start" README.md; then
    awk -v s="$start" -v e="$end" -v b="$block" '$0==s{print b; skip=1; next} $0==e{skip=0; next} !skip{print}' README.md > README.md.tmp && mv README.md.tmp README.md
    echo "[atlas] updated README atlas block"
  else
    awk -v b="$block" '!done && /^# /{print; print ""; print b; done=1; next} {print} END{if(!done){print ""; print b}}' README.md > README.md.tmp && mv README.md.tmp README.md
    echo "[atlas] inserted README atlas block"
  fi
}
_atlas_readme

# ---- 5. stamp ------------------------------------------------------------------------------------
printf '%s\n' "$sig" > "$stamp" 2>/dev/null || true
echo "[atlas] docs/atlas.md + README block refreshed (commit $HEAD_SHA)"
ATLAS_GEN_EOF
  chmod +x scripts/atlas-refresh.sh; ok "$act scripts/atlas-refresh.sh (v$ver)"
}

ensure_env_merge() {
  [ -f scripts/env-merge.sh ] && { info "kept scripts/env-merge.sh"; return; }
  mkdir -p scripts
  cat > scripts/env-merge.sh <<'EOF'
#!/usr/bin/env bash
# Add NEW keys from an example env into the live env, preserving existing values.
set -euo pipefail
ex="${1:-.env.example}"; live="${2:-.env}"
[ -f "$ex" ] || { echo "[env-merge] no $ex; skip"; exit 0; }
touch "$live"; added=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  key=${line%%=*}
  case "$key" in *[!A-Za-z0-9_]*|'') continue ;; esac
  if ! grep -qE "^[[:space:]]*${key}=" "$live"; then
    printf '%s\n' "$line" >> "$live"; echo "[env-merge] + $key"; added=$((added+1))
  fi
done < "$ex"
[ "$added" -gt 0 ] && echo "[env-merge] added $added new key(s) to $live (existing values kept)." || echo "[env-merge] $live already current."
EOF
  chmod +x scripts/env-merge.sh; ok "added scripts/env-merge.sh"
}

ensure_tsconfig_base() {
  [ -f tsconfig.base.json ] && { info "kept tsconfig.base.json"; return; }
  cat > tsconfig.base.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "declaration": true,
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "skipLibCheck": true,
    "esModuleInterop": true,
    "forceConsistentCasingInFileNames": true
  }
}
EOF
  ok "added tsconfig.base.json"
}

ensure_eslint() {
  [ -f eslint.config.mjs ] && { info "kept eslint.config.mjs"; return; }
  cat > eslint.config.mjs <<'EOF'
import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["**/dist/**", "**/.next/**", "**/node_modules/**", "brownfield/**", "**/*.config.*"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/ban-ts-comment": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/no-unused-vars": ["error", { "argsIgnorePattern": "^_", "varsIgnorePattern": "^_" }]
    }
  }
);
EOF
  ok "added eslint.config.mjs"
}

upgrade_node_pkg() {
  [ -f package.json ] || return
  have jq || { warn "jq missing — add a 'lint' script + eslint devDeps to package.json manually."; return; }
  local tmp; tmp="$(mktemp)"
  jq '.scripts.lint //= "eslint ."
      | .devDependencies.eslint //= "^9.17.0"
      | .devDependencies["@eslint/js"] //= "^9.17.0"
      | .devDependencies["typescript-eslint"] //= "^8.20.0"' package.json > "$tmp" && mv "$tmp" package.json
  ok "package.json: ensured lint script + eslint devDependencies"
}

# ace upgrade — adopt an existing repo with ACE machinery (additive, non-destructive)

upgrade_repo() {
  banner; step "Upgrade / adopt an existing repo with ACE machinery"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"; cd "$root" || { err "not a git repo"; return 1; }
  info "Repo: $root"
  local node=0; { [ -f package.json ] && [ -f pnpm-workspace.yaml ]; } && node=1
  info "Stack: $([ "$node" = 1 ] && echo 'Node/TS monorepo' || echo 'generic')"
  hr
  ensure_graph_refresh
  ensure_atlas_refresh
  [ -x scripts/atlas-refresh.sh ] && env ATLAS_FORCE=1 bash scripts/atlas-refresh.sh >/dev/null 2>&1 || true   # back-fill: generate docs/atlas.md + the README block now (idempotent; §G.10 phase 6)
  command -v gen_spec_template >/dev/null 2>&1 && gen_spec_template   # Part H/H1: refresh the feature-spec template on upgrade
  ensure_env_merge
  ensure_ace_ignores   # back-fill ignore rules for artifacts added since this repo was adopted
  gen_autoloop "$root"
  # WIRE THE LOCAL CI GATE — the loop relies on it, and adopt used to skip it entirely (gate-less repo).
  # .githooks/ is ACE-owned so we always write it; but we only AUTO-ACTIVATE (core.hooksPath) when the
  # repo has no hooks of its own, so we never silently bypass a user's existing gate.
  gen_hooks
  gen_opencode_local
  local _hp; _hp="$(git config --get core.hooksPath 2>/dev/null || true)"
  # A GATE MUST EXIST BEFORE WE ACTIVATE THE HOOK THAT RUNS IT. .githooks/pre-commit does `./ci.sh ||
  # exit 1`, so pointing core.hooksPath at it in a repo with no ci.sh makes EVERY commit fail with
  # "./ci.sh: No such file or directory" — adoption bricking the repo it was meant to help. We still
  # WRITE .githooks/ (it is ACE-owned and harmless while inactive); we just don't switch it on yet.
  local _hasgate=0; [ -f ci.sh ] && _hasgate=1
  if [ "$_hasgate" = 0 ]; then
    warn "no ci.sh in this repo — wrote .githooks/ but did NOT activate it (an active gate with no ci.sh blocks every commit)."
    say  "    Add a ci.sh gate, then turn it on: ${C_BOLD}git config core.hooksPath .githooks${C_RESET}"
  elif [ -z "$_hp" ] && [ -f .git/hooks/pre-commit ]; then
    warn "you already have .git/hooks/pre-commit — wrote .githooks/ but left yours active. Enable ACE's gate with: git config core.hooksPath .githooks"
  elif [ -z "$_hp" ] || [ "$_hp" = .githooks ]; then
    # `;` here would print "wired" even when the install failed — install_gitflow_hooks now returns 1 on a
    # partial install (it used to always return 0), so the success claim must be gated on it.
    if install_gitflow_hooks "$root"; then ok "local CI gate wired (pre-commit/pre-push ./ci.sh + commit-msg + main-guard)"
    else warn "local CI gate NOT fully wired — commits to main may not be blocked (see the warning above)"; fi
  else
    warn "core.hooksPath='$_hp' (custom) — wrote .githooks/ but left it. Enable ACE's gate with: git config core.hooksPath .githooks"
  fi
  if [ "$node" = 1 ]; then ensure_tsconfig_base; ensure_eslint; upgrade_node_pkg; fi
  hr
  # never clobber user gate/CI — report what to merge by hand
  if [ -f ci.sh ]; then
    grep -q 'pnpm lint' ci.sh 2>/dev/null || warn "ci.sh exists but has no 'pnpm lint' step — add it to enforce the lint gate locally."
    grep -q 'No stubs'  ci.sh 2>/dev/null || warn "ci.sh has no anti-stub gate — consider adding one."
  else warn "no ci.sh here — add a gate (scaffold projects get a tiered one)."; fi
  [ -d .github/workflows ] && info "Existing CI workflow left untouched — add a 'pnpm lint' step + a codemap job if you want them in CI."
  hr
  ok "Upgrade complete (additive). Review 'git status', then commit."
  # count from _agent_counts (architecture.sh → $ACE_AGENTS) — a literal here is how this drifted to "10"
  # while write_opencode_config was already emitting 12 agent blocks.
  warn "Restart opencode so it loads the global $(_agent_counts | cut -d' ' -f2)-agent config + AGENTS.md rules."
  have pnpm && [ "$node" = 1 ] && confirm "Run pnpm install now (for any new eslint deps)?" Y && spin "pnpm install" pnpm install || true
}

# ---------------------------------------------------------------- CI + deploy artifacts
# ---- CI workflow (factored): shared codemap + deploy + release jobs are emitted ONCE; only the
# per-stack build-test + security jobs vary. _ci_build_security_jobs reads the caller's
# $install/$build/$test/$typecheck via bash dynamic scope.
_ci_build_security_jobs() {
  case "$1" in
    go)
      cat <<EOF
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod }
      # Same brownfield exclusion as ./ci.sh — remote CI must agree with the local gate, or a repo that
      # commits imported code passes pre-commit and then fails here on somebody else's legacy package.
      # go list's rc is judged on its own: an empty list must mean "no owned packages", never "go list
      # blew up". Inlining it in the echo discarded the rc and left an empty GOPKGS that only fails the
      # next step by luck (and silently narrows 'go test' to the root package in a repo with a root main).
      - name: Resolve owned packages (excludes brownfield/)
        run: |
          # stdout and stderr MUST stay separate: `go list` writes "go: downloading <mod>" to STDERR while
          # exiting 0 — routine on a cold module cache, i.e. the first CI run of every scaffolded Go repo with
          # a dependency. Folding it in put that text INTO the package list, and the next step ran
          # `go build go: downloading … app` -> malformed import path. Judge rc; keep stderr for the message.
          if ! out=\$(go list ./... 2>/tmp/golist.err); then
            echo "::error::'go list ./...' failed — the module does not resolve; refusing to build/vet/test a tree we cannot enumerate"
            cat /tmp/golist.err; exit 1
          fi
          pkgs=\$(printf '%s\n' "\$out" | grep -v '/brownfield' | tr '\n' ' ')
          echo "GOPKGS=\$pkgs" >> "\$GITHUB_ENV"
          if [ -z "\${pkgs// /}" ]; then echo "no Go packages outside brownfield/ — skipping build/vet/test (same as ./ci.sh)"; echo "GOSKIP=1" >> "\$GITHUB_ENV"; fi
      - if: env.GOSKIP != '1'
        run: go build \$GOPKGS
      - if: env.GOSKIP != '1'
        run: go vet \$GOPKGS
      - if: env.GOSKIP != '1'
        run: go test \$GOPKGS -race -timeout 120s
      - if: env.GOSKIP != '1'
        run: go run honnef.co/go/tools/cmd/staticcheck@latest \$GOPKGS || true
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod }
      - run: go run golang.org/x/vuln/cmd/govulncheck@latest ./...
      - name: Secret scan
        run: |
          if git ls-files | grep -vE '(^|/)\.env\.example\$' | xargs -r grep -nIE '(-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36})'; then echo "::error::secret committed"; exit 1; fi
          echo "no secrets found"
EOF
      ;;
    python)
      cat <<EOF
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.13' }
      - run: $install
      - run: $test
      - run: $typecheck
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: '3.13' }
      - run: pip install pip-audit
      - run: pip-audit -r requirements.txt
      - name: Secret scan
        run: |
          if git ls-files | grep -vE '(^|/)\.env\.example\$' | xargs -r grep -nIE '(-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36})'; then echo "::error::secret committed"; exit 1; fi
          echo "no secrets found"
EOF
      ;;
    *)  # node + config (config sets the run commands to 'echo skip')
      cat <<EOF
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@b906affcce14559ad1aafd4ab0e942779e9f58b1 # v4
      - uses: actions/setup-node@v4
        with: { node-version: 24, cache: pnpm }
      - run: $install
      - run: $build
      - run: $test
      - run: $typecheck
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@b906affcce14559ad1aafd4ab0e942779e9f58b1 # v4
      - uses: actions/setup-node@v4
        with: { node-version: 24, cache: pnpm }
      - run: $install
      - run: pnpm audit --audit-level=high
      - name: Secret scan
        run: |
          if git ls-files | grep -vE '(^|/)\.env\.example\$' | xargs -r grep -nIE '(-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36})'; then echo "::error::secret committed"; exit 1; fi
          echo "no secrets found"
EOF
      ;;
  esac
}
_ci_codemap_job() {
  cat <<'EOF'
  codemap:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 24 }
      - run: bash scripts/graph-refresh.sh || true
      - name: Code map must be current
        run: |
          if ! git diff --quiet -- docs/architecture.md; then
            echo "::error::docs/architecture.md is STALE — run scripts/graph-refresh.sh and commit."
            git --no-pager diff -- docs/architecture.md; exit 1; fi
          echo "code map current"
EOF
}
_ci_deploy_job() {  # $1 = post-deploy health path ('/healthz' for HTTP services; EMPTY = liveness-only); $2 = port (default 3000)
  local hpath="${1-/}" port="${2:-3000}"
  cat <<EOF
  deploy:
    needs: [build-test, security, codemap]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    env: { HOST: "\${{ secrets.VPS_HOST }}" }
    steps:
      - name: Deploy over SSH + verify it came up
        if: env.HOST != ''
        uses: appleboy/ssh-action@0ff4204d59e8e51228ff73bce53f80d53301dee2 # v1
        with:
          host: \${{ secrets.VPS_HOST }}
          username: \${{ secrets.VPS_USER }}
          port: \${{ secrets.VPS_PORT }}
          key: \${{ secrets.VPS_SSH_KEY }}
          script: |
            set -e
            cd ~/apps/$(basename "$PWD")
            GIT_SSH_COMMAND='ssh -i ~/.ssh/ace_deploy' git fetch origin
            git reset --hard origin/main
            ./scripts/deploy.sh
EOF
  if [ -n "$hpath" ]; then
    cat <<EOF
            # post-deploy health check (timeout-bounded). Override with repo Variables VPS_HEALTH_URL / VPS_HEALTH_TIMEOUT.
            url="\${{ vars.VPS_HEALTH_URL || 'http://127.0.0.1:$port$hpath' }}"; to="\${{ vars.VPS_HEALTH_TIMEOUT || '90' }}"; n="$(basename "$PWD")"
            dl=\$(( \$(date +%s) + to )); ok=0
            while [ \$(date +%s) -lt \$dl ]; do
              if [ "\$(podman inspect -f '{{.State.Running}}' "\$n" 2>/dev/null)" = true ] && curl -fsS -o /dev/null --max-time 5 "\$url"; then ok=1; break; fi
              sleep 3
            done
            [ \$ok = 1 ] || { echo "::error::post-deploy health check FAILED — \$n @ \$url"; podman logs --tail 40 "\$n" 2>&1 || true; exit 1; }
            echo "post-deploy health check passed: \$n @ \$url"
EOF
  else
    cat <<EOF
            # liveness-only check (no HTTP endpoint): the container must be Running after deploy.
            n="$(basename "$PWD")"; sleep 5
            [ "\$(podman inspect -f '{{.State.Running}}' "\$n" 2>/dev/null)" = true ] || { echo "::error::\$n is not running after deploy"; podman logs --tail 40 "\$n" 2>&1 || true; exit 1; }
            echo "post-deploy liveness check passed: \$n is running"
EOF
  fi
}
_ci_release_job() {  # Go: on a v* tag, build hardened binaries and publish them to the Release
  cat <<EOF
  release:
    needs: [build-test, security]
    runs-on: ubuntu-latest
    if: startsWith(github.ref, 'refs/tags/v')
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version-file: go.mod }
      - run: go install mvdan.cc/garble@latest
      - name: Build hardened release binaries (profile-driven)
        run: bash scripts/release.sh --host
      - name: Publish binaries to the GitHub Release
        env: { GH_TOKEN: "\${{ github.token }}" }
        run: gh release create "\${{ github.ref_name }}" dist/* --generate-notes || gh release upload "\${{ github.ref_name }}" dist/* --clobber
EOF
}

gen_ci_workflow() {
  local stack="$1" install build test typecheck hpath="/" trigger _shape=api _dk=service _bin=1
  case "$stack" in
    node)   install='pnpm install --frozen-lockfile'; build='pnpm build'; test='pnpm test'; typecheck='pnpm -r --if-present typecheck && pnpm lint' ;;
    # typecheck: -z/-0 throughout (an unquoted $(git ls-files) word-splits spaced paths, and py_compile
    # then reports "[Errno 2] No such file" — the same bug ./ci.sh had). brownfield/ IS tracked, so it
    # must be filtered here too or remote CI disagrees with the local gate about the same commit.
    python) install='pip install -r requirements.txt'; build='echo "(no build)"'; test='python -m pytest -q --ignore=brownfield'; typecheck='git ls-files -z "*.py" | grep -zv "^brownfield/" | xargs -0 -r python -m py_compile' ;;
    go)     _shape="$(_prof_get shape 2>/dev/null)"; _shape="${_shape:-api}"; _dk="$(_go_deploy_kind "$_shape")"
            _go_binary_shape "$_shape" || _bin=0
            [ "$_shape" = api ] && hpath='/healthz' || hpath='' ;;   # only api exposes an HTTP health endpoint
    *)      install='echo skip'; build='echo skip'; test='echo skip'; typecheck='echo skip' ;;
  esac
  # resolve the CI DEPLOY job for non-go stacks (go set _dk from its shape above): honor the profile's
  # deploy_kind + container/stack settings. A config-only, container:false, or deploy=none project must
  # NOT emit a deploy job — it has no service to ship and its running-container health-check would always
  # fail. (This closed the gap where every non-go stack defaulted _dk=service.)
  if [ "$stack" != go ]; then
    _dk="${ACE_DEPLOY:-$(_prof_get deploy_kind 2>/dev/null)}"; _dk="${_dk:-service}"
    case "$stack" in node|python) ;; *) _dk=none ;; esac          # only real runtimes deploy
    [ "${PROFILE_CONTAINER:-true}" = false ] && _dk=none           # no image → no service deploy
    _shape="$(_prof_get shape 2>/dev/null)"; _shape="${_shape:-api}"
    case "$_shape" in worker|library|cli) hpath='' ;; esac          # a non-HTTP shape has no health endpoint to curl (mirrors the go arm) — deploy uses liveness only
  fi
  mkdir -p .github/workflows
  trigger="  push: { branches: [main] }"; { [ "$stack" = go ] && [ "$_bin" = 1 ]; } && trigger="  push: { branches: [main], tags: ['v*'] }"
  {
    cat <<EOF
name: CI
on:
$trigger
  pull_request: { branches: [main] }
concurrency: { group: "ci-\${{ github.ref }}", cancel-in-progress: true }
jobs:
EOF
    _ci_build_security_jobs "$stack"
    _ci_codemap_job
    local _hport=3000; [ "$stack" = python ] && _hport=8000
    [ "$_dk" = service ] && _ci_deploy_job "$hpath" "$_hport"
    { [ "$stack" = go ] && [ "$_bin" = 1 ]; } && _ci_release_job
  } > .github/workflows/ci.yml
  ok "CI workflow written ($stack$([ "$stack" = go ] && printf '/%s' "$_shape"): build-test + security + codemap$([ "$_dk" = service ] && printf ' + deploy')$({ [ "$stack" = go ] && [ "$_bin" = 1 ]; } && printf ' + release'))"
}

gen_deploy_artifacts() {
  local name="$1" stack="${2:-}"
  mkdir -p scripts
  ensure_env_merge   # settings-safe merge: adds NEW keys only, never overwrites live values

  # Block 3 (build + run) differs between stacks ONLY in the header line, the `podman run` arguments and
  # the closing message — the build/replace/rollback machinery around them is identical, so it is written
  # once below instead of in three near-identical copies that drift apart.
  local _gshape _hdr _runargs _upmsg _port=3000
  _gshape="$(_prof_get shape 2>/dev/null)"; _gshape="${_gshape:-api}"
  if [ "$stack" = go ] && [ "$_gshape" = worker ]; then
    _hdr='# 3) build the final (distroless) image and (re)start the worker (no published port)'
    _runargs='--restart=always --env-file .env'
    _upmsg="$name worker running (liveness = container up)"
  elif [ "$stack" = go ]; then
    _hdr='# 3) build the final (distroless) image and (re)start it'
    _runargs='--restart=always --env-file .env -p 3000:3000'
    _upmsg="$name running on :3000 (health: /healthz)"
  else
    [ "$stack" = python ] && _port=8000
    _hdr='# 3) build the runtime (final) image and (re)start the service.
# The start command lives in the `final` stage of the Containerfile (CMD) — set it there for your app.'
    _runargs="--restart=always --env-file .env -p $_port:$_port"
    _upmsg="$name running on :$_port (set the final-stage CMD if it is not up yet)"
  fi

  cat > scripts/deploy.sh <<EOF
#!/usr/bin/env bash
# Deploy on the VPS. SETTINGS ARE NEVER OVERWRITTEN: existing .env values are kept and
# only NEW keys from .env.example are appended; *.example configs are seeded once.
# (The caller fetch+reset's the code first; runtime config must be gitignored — see README.)
# Generated by ACE.
set -euo pipefail
cd "\$(dirname "\$0")/.."

# 1) merge new settings keys without clobbering live values
bash scripts/env-merge.sh .env.example .env

# 2) seed any *.example config that doesn't exist yet (never overwrite an existing one)
for ex in \$(git ls-files '*.example' 2>/dev/null); do
  [ "\$ex" = ".env.example" ] && continue
  target="\${ex%.example}"
  [ -e "\$target" ] || { cp "\$ex" "\$target"; echo "[deploy] seeded \$target from \$ex"; }
done

$_hdr
NAME="$name"
IMAGE="localhost/\$NAME:latest"
PREV="localhost/\$NAME:prev"

# ROLLBACK GUARD. This block used to overwrite :latest and then 'podman rm -f' the live container with
# no trap and no previous image kept — so a failing 'podman run' left the host with NO container AND no
# last-good image to restore, i.e. a hard outage from a routine deploy. Now: keep the current :latest as
# :prev BEFORE the build overwrites it, and if the new container fails to come up, put :prev back.
#
# The rollback target is taken from the image the container is ACTUALLY RUNNING, not from :latest.
# :latest is overwritten by every build, including a failed deploy's — so re-tagging :latest as :prev
# would, on the second consecutive failed deploy, overwrite the last-good :prev with the known-bad image
# and leave nothing to roll back to. The running container is the only image proven to work.
_LIVE_IMG=\$(podman inspect -f '{{if .State.Running}}{{.Image}}{{end}}' "\$NAME" 2>/dev/null || true)
if [ -n "\$_LIVE_IMG" ]; then
  podman tag "\$_LIVE_IMG" "\$PREV"
  echo "[deploy] kept the RUNNING image as \$PREV (rollback target)"
elif podman image exists "\$PREV" 2>/dev/null; then
  echo "[deploy] \$NAME is not running — keeping the existing \$PREV as the rollback target (not overwriting it with an unproven image)"
else
  echo "[deploy] no running container and no \$PREV — first deploy, nothing to roll back to"
fi

# Armed only for the window where the old container is already gone but the new one is not up yet.
# Outside that window a failure leaves the running service untouched, so there is nothing to undo.
_ROLLBACK_ARMED=0
_rollback() {
  [ "\$_ROLLBACK_ARMED" = 1 ] || return 0
  if ! podman image exists "\$PREV" 2>/dev/null; then
    echo "[deploy] DEPLOY FAILED and there is no \$PREV image — \$NAME is DOWN. Inspect: podman logs \$NAME" >&2
    return 0
  fi
  echo "[deploy] DEPLOY FAILED — rolling back to \$PREV …" >&2
  podman rm -f "\$NAME" 2>/dev/null || true
  if podman run -d --name "\$NAME" $_runargs "\$PREV"; then
    echo "[deploy] rolled back: \$NAME is running the previous image (\$PREV)." >&2
  else
    echo "[deploy] ROLLBACK ALSO FAILED — \$NAME is DOWN. Inspect: podman logs \$NAME" >&2
  fi
}
trap _rollback EXIT

echo "[deploy] building \$IMAGE (final image) …"
podman build --target final -t "\$IMAGE" -f Containerfile .
podman rm -f "\$NAME" 2>/dev/null || true
_ROLLBACK_ARMED=1
podman run -d --name "\$NAME" $_runargs "\$IMAGE"
_ROLLBACK_ARMED=0; trap - EXIT
echo "[deploy] $_upmsg"
EOF
  chmod +x scripts/deploy.sh
  # rootless systemd (Quadlet) example for auto-start on the VPS
  cat > scripts/$name.container.example <<EOF
# Copy to ~/.config/containers/systemd/$name.container on the VPS, then:
#   systemctl --user daemon-reload && systemctl --user enable --now $name.service
[Unit]
Description=$name
After=network-online.target
Wants=network-online.target
[Container]
Image=localhost/$name:latest
ContainerName=$name
PublishPort=127.0.0.1:3000:3000
[Service]
Restart=always
[Install]
WantedBy=default.target
EOF
  ok "Deploy artifacts: scripts/deploy.sh + scripts/env-merge.sh + scripts/$name.container.example"
}

# Is this repo ready for the autorun loop? (git repo + an 'origin' remote + main pushed)
_publish_status() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { warn "not a git repo — run 'ace publish' (or 'ace gitflow')."; return 1; }
  if ! git remote get-url origin >/dev/null 2>&1; then warn "no 'origin' remote yet — the loop can't push/PR. Run: ${C_BOLD}ace publish${C_RESET}"; return 1; fi
  local slug ahead; slug="$(repo_slug 2>/dev/null)"
  git fetch origin -q 2>/dev/null || true
  ahead="$(git rev-list --count @{u}..HEAD 2>/dev/null || echo '?')"
  if [ "${ahead:-0}" = 0 ] 2>/dev/null; then ok "loop-ready: origin=${slug:-$(git remote get-url origin)} · branch=$(git branch --show-current 2>/dev/null) · pushed. Run: ${C_BOLD}ace autorun${C_RESET}"
  else warn "origin set but $ahead local commit(s) unpushed — run: ${C_BOLD}ace publish${C_RESET} (or git push)"; return 1; fi
}

# Create + push the GitHub repo for this project — idempotent and re-runnable. Handles the common
# "the repo of this name already exists (I forgot to delete the old one)" case: warns and lets you
# REUSE it, RENAME, or abort; and if 'origin' is already set it just (re-)pushes. So a failed first
# attempt can simply be re-run (`ace publish`).
publish_repo() {
  local name="${1:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
  have gh || { err "gh not installed — run 'ace git' first."; return 1; }
  gh auth status >/dev/null 2>&1 || { warn "Not logged in — running gh auth login."; gh auth login || return 1; }
  gh auth setup-git >/dev/null 2>&1 || true
  # ensure a git repo + at least one commit on main (idempotent — safe to re-run)
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { run git init -q; ok "git init"; }
  git branch -M main 2>/dev/null || true
  if [ -z "$(git rev-parse --verify -q HEAD 2>/dev/null)" ] || [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A
    [ -x scripts/atlas-refresh.sh ] && env ATLAS_FORCE=1 bash scripts/atlas-refresh.sh >/dev/null 2>&1 && git add -A || true   # section G: ship docs/atlas.md + the README system-map in the scaffold commit (files are tracked now → real skeleton)
    git -c core.hooksPath=/dev/null commit -q -m "chore: scaffold $name via ACE" 2>/dev/null || true
  fi

  # RE-PUSH path: origin already wired (a prior attempt set it, or the repo was published before).
  if git remote get-url origin >/dev/null 2>&1; then
    info "origin already set ($(git remote get-url origin)) — (re-)pushing…"
    git push -u origin HEAD 2>&1 | tail -2 || { err "push failed — see above (auth? branch protection? diverged?)."; return 1; }
    gh_protect_main; _publish_status; return 0
  fi

  local owner; owner="$(gh api user -q .login 2>/dev/null)"
  [ -n "$owner" ] || { err "couldn't resolve your GitHub login — check 'gh auth status'."; return 1; }

  # COLLISION: a repo of this name already exists on GitHub and we have no local origin.
  while gh repo view "$owner/$name" >/dev/null 2>&1; do
    warn "GitHub repo ${C_BOLD}$owner/$name${C_RESET} ALREADY EXISTS (and this clone has no 'origin')."
    if _noninteractive; then
      err "refusing to auto-reuse or overwrite a pre-existing repo headlessly. Delete/rename it on GitHub, or run 'ace publish' interactively to choose."; return 1
    fi
    choose use "How do you want to resolve it?" \
      "use::add it as 'origin' and push into THIS existing repo (it's mine / intended)" \
      "rename::publish under a different name instead" \
      "abort::stop — I'll delete or rename it on GitHub myself"
    case "$CHOOSE_REPLY" in
      use)    git remote add origin "$(gh repo view "$owner/$name" --json sshUrl -q .sshUrl 2>/dev/null || echo "git@github.com:$owner/$name.git")"
              info "pushing into existing $owner/$name…"
              git push -u origin HEAD 2>&1 | tail -2 || { err "push into existing repo failed — see above."; return 1; }
              gh_protect_main; _publish_status; return 0 ;;
      rename) ask "New repo name" "${name}-2"; name="$(printf '%s' "$ASK_REPLY" | tr ' ' '-' | tr -cd '[:alnum:]._-')"
              [ -n "$name" ] || { err "empty name — aborting."; return 1; }; continue ;;
      *)      info "aborted — no repo created or pushed. Re-run 'ace publish' to try again."; return 1 ;;
    esac
  done

  # name is free → create + set remote + push in one shot
  info "Creating private repo $owner/$name…"
  gh repo create "$owner/$name" --private --source=. --remote=origin --push 2>&1 | tail -2 \
    || { err "repo create/push failed — see above. If the name is taken, re-run 'ace publish' and pick rename."; return 1; }
  ok "created + pushed $owner/$name."
  gh_protect_main; _publish_status
}

# After a standalone `ace profile`, nudge toward loop-readiness: if git is on but the repo isn't
# published/pushed, offer to publish so the autorun loop can actually run.
_profile_postcheck() {
  [ "$(_prof_get git)" = false ] && return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  _publish_status && return 0   # already git+origin+pushed → loop-ready, nothing to do
  _optin ACE_PUBLISH "Publish / push this repo to GitHub now so the loop is ready?" Y && publish_repo
}

# ---------------------------------------------------------------- brownfield import
import_brownfield() {
  local proj="${1:-$PWD}" first=1 imported=0
  cd "$proj" || return 1
  while :; do
    if [ "$first" = 1 ]; then
      confirm "Import existing code/data into ./brownfield/ (map it with GitNexus/Serena)?" N || break
    else
      confirm "Import another path?" N || break
    fi
    first=0
    ask_path "Path to existing code/data (Tab to complete)"; local src="$ASK_REPLY"
    [ -n "$src" ] && [ -e "$src" ] || { warn "not found: $src"; continue; }
    local base sug; base="$(basename "$src")"; sug="$(printf '%s' "$base" | tr ' ' '-' | tr -cd '[:alnum:]._-')"
    ask "Folder under brownfield/" "${sug:-import}"; local dst="brownfield/$ASK_REPLY"
    menu "Import mode" \
      "Copy into repo (versioned)::recommended — committed + mapped" \
      "Symlink (reference only)::maps in place, not committed"
    run mkdir -p brownfield
    if [ "$MENU_CHOICE" = 1 ]; then
      spin "Copying $src → $dst" cp -a "$src" "$dst" || { err "copy failed"; continue; }
      if find "$dst" -maxdepth 5 -name .git -type d 2>/dev/null | grep -q .; then
        warn "imported tree contains a nested .git (would become an embedded repo)."
        confirm "Flatten it (remove nested .git so files track normally)?" Y \
          && find "$dst" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null && ok "flattened nested git"
      fi
      ok "copied → $dst"
    else
      run ln -s "$(realpath "$src")" "$dst" && ok "symlinked → $dst (not tracked by git)"
    fi
    imported=1
  done
  [ "$imported" = 1 ] || return 0
  gen_brownfield_readme "$proj"
  append_brownfield_ignores "$proj"
  ok "Brownfield imported — excluded from the gate, mapped on next index."
}

gen_brownfield_readme() {
  [ -f "$1/brownfield/README.md" ] && return
  [ "$ACE_DRY_RUN" = 1 ] && return
  cat > "$1/brownfield/README.md" <<'EOF'
# brownfield — existing code & data (reference)

Imported systems live here. They are **mapped by GitNexus + Serena** (so the agents can read and
understand them) but are **excluded from the build/test gate**. Port pieces into the active project
(apps/packages/services or src/) with tests, then delete the brownfield copy once verified green.
EOF
}

append_brownfield_ignores() {
  local gi="$1/.gitignore"
  [ "$ACE_DRY_RUN" = 1 ] && return
  grep -q 'brownfield artifacts' "$gi" 2>/dev/null && return
  cat >> "$gi" <<'EOF'

# brownfield artifacts (build outputs of imported code)
brownfield/**/node_modules/
brownfield/**/bin/
brownfield/**/obj/
brownfield/**/__pycache__/
brownfield/**/.venv/
brownfield/**/dist/
brownfield/**/*.dll
brownfield/**/*.exe
EOF
}

# standalone: add brownfield to an existing project, then re-map
import_existing() {
  banner; step "Import & map existing code"
  local root; root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
  info "Project: $root"
  import_brownfield "$root"
  confirm "Re-map now with GitNexus + Serena?" Y && { cd "$root" && index_project; }
}

# ---------------------------------------------------------------- emitted-gate behavioural selftest
# tests/snapshot-generators.sh is a CHANGE DETECTOR: it locks in what the generators EMIT, and it would
# have accepted the `go list` fail-open (rc discarded, empty list read as "no packages", CI GREEN on a
# module that does not parse) exactly as happily as it accepts the fix. This asserts the emitted Go gate
# BEHAVES: a `go list` FAILURE is RED, and only a genuine rc=0 empty list is a skip.
# Hermetic — `go`/`gofmt` are stubbed on PATH, so no Go toolchain is needed to run it:
#   bash lib/scaffold.sh gates-selftest
scaffold_gates_selftest() {
  local work bin app out rc n_fail=0
  work="$(mktemp -d)" || return 1
  bin="$work/bin"; app="$work/app"; mkdir -p "$bin" "$app/cmd/app" || return 1

  # Stub toolchain. STUB_GOLIST picks which of the three states `go list ./...` is in.
  cat > "$bin/go" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  case "${STUB_GOLIST:-ok}" in
    ok)    printf '%s\n' app/cmd/app app/brownfield/legacy; exit 0 ;;
    empty) exit 0 ;;                                                   # rc=0, nothing owned
    fail)  echo "go: errors parsing go.mod: go.mod:5: syntax error" >&2; exit 1 ;;
  esac
fi
exit 0
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/gofmt"
  chmod +x "$bin/go" "$bin/gofmt"

  ( cd "$app" && gen_go app >/dev/null 2>&1 ) || { echo "gates-selftest: gen_go failed"; rm -rf "$work"; return 1; }
  [ -f "$app/ci.sh" ] || { echo "gates-selftest: no ci.sh emitted"; rm -rf "$work"; return 1; }

  _gs_case() { # <STUB_GOLIST> <label> ; sets $out/$rc
    out="$(cd "$app" && PATH="$bin:$PATH" STUB_GOLIST="$1" bash ci.sh 2>&1)"; rc=$?
  }
  _gs_want() { case "$out" in *"$1"*) return 0 ;; *) echo "  MISSING expected text: $1"; return 1 ;; esac; }
  _gs_deny() { case "$out" in *"$1"*) echo "  UNEXPECTED text present: $1"; return 1 ;; *) return 0 ;; esac; }

  # 1) go list FAILS -> must be RED, and must NOT be mistaken for "no packages".
  _gs_case fail
  { _gs_want "'go list ./...' failed" \
    && _gs_deny "skipping build/vet/test" \
    && _gs_want "CI RED" \
    && [ "$rc" != 0 ]; } \
    && echo "ok   go list failure -> CI RED" \
    || { echo "FAIL go list failure must be RED (rc=$rc) — this is the fail-open the gate exists to kill"; n_fail=$((n_fail+1)); }

  # 2) go list SUCCEEDS but owns nothing -> a legitimate skip, and NOT reported as a go-list failure.
  _gs_case empty
  { _gs_want "skipping build/vet/test" && _gs_deny "'go list ./...' failed"; } \
    && echo "ok   empty package list -> skip" \
    || { echo "FAIL rc=0 empty list should skip build/vet/test cleanly"; n_fail=$((n_fail+1)); }

  # 3) packages resolve -> the build/vet/test arm actually runs (neither skip nor failure text).
  _gs_case ok
  { _gs_deny "skipping build/vet/test" && _gs_deny "'go list ./...' failed"; } \
    && echo "ok   packages resolve -> build/vet/test runs" \
    || { echo "FAIL resolved packages must reach build/vet/test"; n_fail=$((n_fail+1)); }

  unset -f _gs_case _gs_want _gs_deny
  rm -rf "$work"
  [ "$n_fail" = 0 ] && { echo "gates-selftest: PASS"; return 0; }
  echo "gates-selftest: $n_fail FAILED"; return 1
}

# Direct invocation only (sourcing this file must stay side-effect free): bash lib/scaffold.sh gates-selftest
if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = gates-selftest ]; then
  _sc_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  . "$_sc_lib/ui.sh" 2>/dev/null || true; . "$_sc_lib/core.sh" 2>/dev/null || true
  export ACE_DIR="${ACE_DIR:-$(dirname "$_sc_lib")}" ACE_DRY_RUN=0
  scaffold_gates_selftest
fi
