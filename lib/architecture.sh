#!/usr/bin/env bash
# architecture.sh — the "first screen": architecture diagram + on-demand explainers.

# ---------------------------------------------------------------- agent count (ONE source of truth)
# Every screen that quotes "the N-agent crew" derives N from here instead of hardcoding it. Hardcoding is
# exactly how this drifted: the same rig was advertised as 9, 10, 11 AND 12 agents across five files.
# $ACE_AGENTS (install.sh) lists every CONFIGURABLE agent; `debater` is deliberately absent from it because
# it always runs with an explicit --model override (DEBATE_MODEL_A/B), so a MODEL_debater knob would be a
# no-op. It still SHIPS and still counts on screen — hence total = configurable + 1.
_agent_counts() {  # echoes "<configurable> <total>"
  local n; n="$(printf '%s\n' ${ACE_AGENTS:-} | grep -c .)"
  # install.sh not sourced (e.g. a test sourcing a single lib) — fall back to today's shipped roster
  # rather than rendering "0 agents". Keep this literal in step with ACE_AGENTS if the roster changes.
  [ "${n:-0}" -gt 0 ] 2>/dev/null || n=11
  printf '%s %s' "$n" "$((n + 1))"
}

show_architecture() {
  local n_all; n_all="$(_agent_counts | cut -d' ' -f2)"
  banner
  cat <<ART
${C_BOLD}The loop you're installing${C_RESET}    ${C_GREY}(two nested loops)${C_RESET}

  ${C_DIM}OUTER — the autorun (ace autorun): ship objectives unattended${C_RESET}
  ┌─────────────────────────────────────────────────────────────────┐
  │ ${C_BOLD}OBJECTIVES.md${C_RESET}  (you set the north star)                         │
  │      │ planner decomposes the top objective when the board empties │
  │      ▼                                                             │
  │ ${C_BOLD}ROADMAP.md${C_RESET}  task queue ──▶ next item ──▶ INNER loop builds it   │
  │      ▲                                         │                   │
  │      │                                         ▼                   │
  │      │   push PR ▸ watch CI ── 🔴 ─▶ feed log to opencode ─▶ fix ─▶┘│
  │      │                       └─ 🟢 ─▶ merge-if-green ▸ pull main    │
  │      └── progress ◀── refresh code-map ▸ deploy ▸ next ────────────┘│
  └─────────────────────────────────────────────────────────────────┘
        │ each ROADMAP item = one fresh session
        ▼
  ${C_DIM}INNER — the ${n_all}-agent build (one feature)${C_RESET}
  ┌───────────────────────────────────────────────────────────────────┐
  │ ${C_BOLD}orchestrator${C_RESET}  (Claude Opus ${C_GREY}· Sonnet/GPT/DS${C_RESET}; plans, never edits)    │
  │   1. PLAN     break into small testable tasks (GitNexus impact)    │
  │       └─ ${C_CYAN}researcher${C_RESET}     drafts the spec (high-risk only)           │
  │   2. BRANCH   git checkout -b feat/<slug>                          │
  │   3. PER TASK                                                      │
  │       ├─ ${C_CYAN}implementer${C_RESET}    context-pass, then builds to Done          │
  │       ├─ ${C_CYAN}test_engineer${C_RESET}  adversarial tests (high-risk tasks)        │
  │       ├─ ${C_CYAN}verifier${C_RESET}       runs ./ci.sh (fast gate)                   │
  │       ├─ 4 critics  ${C_CYAN}reviewer${C_RESET}·${C_CYAN}ux${C_RESET}·${C_CYAN}standards${C_RESET}·${C_CYAN}alignment${C_RESET}                │
  │       ├─ fix loop    on red/changes, retry then stop               │
  │       └─ commit      on PASS + all 4 critics APPROVE ──▶ re-index  │
  │   4. PUBLISH  push branch · open PR · ${C_CYAN}conflict_resolver${C_RESET} on conflict │
  │   5. PROMOTE  ${C_CYAN}launch_readiness_reviewer${C_RESET} GO/NO-GO before the VPS    │
  │   ${C_GREY}opt-in${C_RESET}      ${C_CYAN}debater${C_RESET} ×2 — cross-model spec/diff debate            │
  └───────────────────────────────────────────────────────────────────┘

  ${C_GREY}context stays lean: each subagent runs in its own session; only short${C_RESET}
  ${C_GREY}summaries return + the loop auto-compacts at ~80% of the 1M window.${C_RESET}
  ${C_GREY}the agent never self-merges; the autorun SCRIPT merges only when safe.${C_RESET}
ART
  explain_menu
}

explain_menu() {
  local n_all; n_all="$(_agent_counts | cut -d' ' -f2)"
  while true; do
    menu "Learn more (on demand)" \
      "The $n_all agents::orchestrator / researcher / implementer / test_engineer / verifier / 4 critics / conflict_resolver / launch_readiness / debater" \
      "The autorun loop::objectives -> roadmap -> CI self-heal -> merge -> deploy" \
      "The tiered gate::fast pre-commit vs container pre-push/CI" \
      "Code intelligence::GitNexus · Serena · Context7 — who updates when" \
      "Git & GitHub flow::branches, hooks, PRs, credentials" \
      "VPS & deploy::ssh, runtime bootstrap, git deploy, CI secrets" \
      "Silverblue vs Arch::how install differs per distro" \
      "← back::"
    case "$MENU_CHOICE" in
      1) explain_agents ;; 2) explain_autoloop ;; 3) explain_gate ;; 4) explain_codeintel ;;
      5) explain_git ;; 6) explain_vps ;; 7) explain_distro ;; 8) return ;;
    esac
    pause
  done
}

explain_agents() {
  local n_cfg n_all; read -r n_cfg n_all <<<"$(_agent_counts)"
  box "The $n_all agents — $n_cfg configurable (DeepSeek reasoningEffort=max by default)" \
    "${C_BOLD}orchestrator${C_RESET} (primary) — plans, writes per-task specs, drives the loop." \
    "  Write-denied: never edits; only runs git/gh. Runs on Claude Opus by default (your Claude" \
    "  plan), or Sonnet / OpenAI GPT-5 / DeepSeek (no sub) via 'ace keys' → orchestrator brain." \
    "${C_BOLD}researcher${C_RESET} (subagent) — read-only; invoked ONCE per HIGH-RISK/[value] feature" \
    "  BEFORE implementation to draft the spec body in a FRESH context (keeps the expensive" \
    "  orchestrator context clean). Never writes — the implementer lands the spec it returns." \
    "${C_BOLD}implementer${C_RESET} (subagent) — the only agent that edits. Does a CONTEXT PASS first" \
    "  (GitNexus impact up/down + Serena callers + neighbors), then builds to the" \
    "  Definition of Done, then self-reviews its own diff before returning." \
    "${C_BOLD}test_engineer${C_RESET} (subagent) — on high-risk/logic-dense tasks, authors tests" \
    "  INDEPENDENTLY of the implementer to BREAK the code; reports bugs, never papers over." \
    "${C_BOLD}verifier${C_RESET} (subagent) — read-only; runs ./ci.sh, confirms symbols, PASS/FAIL." \
    "${C_DIM}The four critics (a HIGH-RISK change needs all four to APPROVE):${C_RESET}" \
    "${C_BOLD}reviewer${C_RESET} (subagent) — severe principal-engineer critic. Reads the spec, full" \
    "  diff, impact graph + callers; grades 10 aspects (logic, integration, placement," \
    "  scope-fit, security, perf, tests…). Strict by default." \
    "${C_BOLD}ux_reviewer${C_RESET} (subagent) — judges it as a highly advanced END USER:" \
    "  appearance, states, placement/flow, a11y, DX, scope-fit." \
    "${C_BOLD}standards_keeper${C_RESET} (subagent) — curates .opencode/STANDARDS.md for the stack and" \
    "  reviews the diff against it; flags version/EOL + build-hygiene drift." \
    "${C_BOLD}alignment_reviewer${C_RESET} (subagent) — judges the change against .opencode/profile.yaml" \
    "  + ARCHITECTURE.md: mission, audience, values, philosophy, scale, delivery." \
    "${C_BOLD}conflict_resolver${C_RESET} (subagent) — on a conflicting PR, merges main in and reconciles" \
    "  BOTH sides' intent (no --ours/--theirs, no reverts to old); escalates UNRESOLVABLE." \
    "${C_BOLD}launch_readiness_reviewer${C_RESET} (subagent) — runs ONCE before promoting to the live VPS," \
    "  not per-diff. Checks the OPERATIONAL things a diff review can't see: a TESTED restore," \
    "  a documented rollback, prod/staging separation, money reconciliation, LLM spend caps." \
    "  NO-GO blocks the promotion; './ci.sh --launch' runs the mechanical subset." \
    "${C_BOLD}debater${C_RESET} (×2, opt-in) — the ${n_all}th agent, and the one you CANNOT pick a model for:" \
    "  it is always launched with an explicit per-side --model override (DEBATE_MODEL_A/B), so" \
    "  it is absent from the per-agent picker by design. Two DIFFERENT models argue a spec or a" \
    "  diff (defender vs challenger, both read-only) and report only what BOTH sides accept." \
    "  Off by default — turn it on in Settings → Cross-model debate." \
    "" \
    "A commit needs verifier PASS AND the risk-gated critics' APPROVE (LOW-risk = the" \
    "engineering reviewer; HIGH-risk = all four critics). Each agent runs in its OWN" \
    "context window — only a short summary returns, so the main context never jams." \
    "" \
    "${C_BOLD}Thinking discipline${C_RESET} (all agents, via AGENTS.md): 3 WHYS at design + acceptance-" \
    "criteria (reach the root need) · PRE-MORTEM at implement + review (assume it broke in prod — why?)."
}
explain_autoloop() {
  local n_all; n_all="$(_agent_counts | cut -d' ' -f2)"
  box "The autorun loop (ace autorun / autoloop)" \
    "Chains the whole pipeline and runs unattended until the feature cap:" \
    "  ${C_BOLD}0. preflight${C_RESET} confirm the right repo+branch and that any pending PR belongs to" \
    "             THIS repo:branch (refuses a stale/wrong PR). EXPECT_REPO=owner/name guards it." \
    "  ${C_BOLD}1. plan${C_RESET}     roadmap empty? the planner decomposes the top OBJECTIVE into" \
    "             ROADMAP tasks (two-tier brain: OBJECTIVES.md = north star, you edit;" \
    "             ROADMAP.md = task queue, the loop fills + ticks)." \
    "  ${C_BOLD}2. build${C_RESET}    a FRESH opencode session builds the next roadmap item ($n_all-agent" \
    "             inner loop) — context never piles up across features." \
    "  ${C_BOLD}3. self-heal${C_RESET} push PR ▸ watch CI; on red it pulls 'gh run --log-failed'," \
    "             feeds it to opencode, fixes the ROOT cause (no band-aids), re-watches." \
    "             Caps at MAX_FIX attempts per red before stopping for you." \
    "  ${C_BOLD}4. merge${C_RESET}    when EVERY check is green AND the PR is mergeable, the SCRIPT" \
    "             squash-merges, deletes the branch, pulls main. The agent never self-merges." \
    "  ${C_BOLD}5. finish${C_RESET}   refresh code-map ▸ deploy (CI job, or DEPLOY=1) ▸ mark progress" \
    "             ▸ next item, until MAX_FEATURES (0 = unlimited, until you stop it)." \
    "  ${C_BOLD}∞. self-improve${C_RESET} (optional, set at launch) once every objective is done, keep" \
    "             shipping one high-leverage improvement at a time toward the end goal you" \
    "             set (IMPROVE_GOAL) — deepen a section or build a new feature." \
    "" \
    "Knobs (prompted, or set raw): AUTOMERGE · DEPLOY · PLAN · MAX_FIX · MAX_FEATURES." \
    "The run holds the system awake (systemd-inhibit) and releases when it ends." \
    "" \
    "${C_BOLD}Overseer on Claude?${C_RESET} If the orchestrator runs on a Claude subscription and hits" \
    "its session/usage cap, the loop doesn't die — it WAITS for reset, CANCELs & saves," \
    "or DELEGATEs to DeepSeek as overseer (ON_CLAUDE_LIMIT=wait|cancel|deepseek)."
}
explain_gate() {
  box "The tiered gate (./ci.sh)" \
    "${C_BOLD}fast${C_RESET}  (./ci.sh)            typecheck + affected tests + static checks (~seconds)" \
    "                          ▶ runs in pre-commit and in the verifier each task" \
    "${C_BOLD}full${C_RESET}  (./ci.sh --container) build+test in a pinned container (VPS parity)" \
    "                          ▶ runs in pre-push and in GitHub Actions on the PR" \
    "" \
    "Why: a full container build per commit is minutes on a real monorepo. Tiering" \
    "keeps commits cheap while still enforcing parity at the push/merge boundary."
}
explain_codeintel() {
  box "Code intelligence — who updates when" \
    "${C_BOLD}Serena${C_RESET}     live LSP over your files — reflects uncommitted edits in real time." \
    "${C_BOLD}GitNexus${C_RESET}   batch graph — refreshes only when 'analyze' runs (post-commit hook)," \
    "           i.e. ~per committed task. impact()/detect_changes() are fresh as of" \
    "           the last commit, not your last keystroke." \
    "${C_BOLD}Context7${C_RESET}   external library docs, fetched live per query — no repo state." \
    "" \
    "Gotcha: post-commit analyze is wrapped in '|| true' (never blocks a commit), so" \
    "if it errors the graph silently goes stale — re-run 'npx gitnexus analyze' now and then."
}
explain_git() {
  box "Git & GitHub flow" \
    "• Work on feat/<slug>; never commit to main." \
    "• pre-commit runs the fast gate; pre-push runs the container gate; post-commit" \
    "  refreshes the GitNexus graph + changelog." \
    "• At feature end the orchestrator pushes and opens a PR (gh) — it never self-merges." \
    "• gh CLI is installed + 'gh auth login' if you're not signed in; 'gh auth setup-git'" \
    "  wires git to use the gh token (no username/password prompts)." \
    "• Branch protection needs GitHub Pro on PRIVATE repos — local hooks are the gate" \
    "  meanwhile, with CI status visible on every PR."
}
explain_vps() {
  box "VPS & deploy (git-based)" \
    "1. ${C_BOLD}configure${C_RESET}  host · user · ssh key · port — ACE tests the connection and reads" \
    "   the remote /etc/os-release to detect ubuntu / arch / fedora." \
    "2. ${C_BOLD}bootstrap${C_RESET}  installs podman + git on the VPS with the right package manager" \
    "   (apt / pacman / dnf), sudo only if not root." \
    "3. ${C_BOLD}wire CI${C_RESET}    gh secret set VPS_HOST/USER/PORT/SSH_KEY — the generated deploy" \
    "   job (push to main) then ssh-deploys automatically." \
    "4. ${C_BOLD}provision${C_RESET}  creates a read-only deploy key on the VPS, registers it with the" \
    "   repo, and clones it to ~/apps/<name> — deploys are 'git pull && deploy.sh'." \
    "5. ${C_BOLD}deploy${C_RESET}     pull + rebuild + restart, locally (ace deploy) or via CI on merge." \
    "6. ${C_BOLD}health${C_RESET}     after every deploy — local 'ace deploy' AND the CI deploy job on" \
    "   push to main — ACE polls the VPS for container Running AND the health URL" \
    "   answering, within VPS_HEALTH_TIMEOUT (default 90s, ~3s interval). A sick deploy" \
    "   fails 'ace deploy' / the CI job (and the autorun loop) and dumps recent logs." \
    "7. ${C_BOLD}verify${C_RESET} (agent, 'ace verify' / loop VERIFY=1) deeper than health: probes" \
    "   reachability, TLS, service state, recent errors + integration status, then an" \
    "   agent triages real errors + improvements into ROADMAP.md — the loop fixes them" \
    "   next pass (deploy -> verify -> discover -> enqueue -> fix)." \
    "" \
    "Everything is logged; run any of it with --dry-run to preview first."
}
explain_distro() {
  box "Silverblue vs Arch" \
    "Everything installs ${C_BOLD}user-local in \$HOME${C_RESET} (fnm, uv, bun, opencode, gh) — no root," \
    "identical on both distros. The only difference is the container engine:" \
    "  ${C_BOLD}Fedora Atomic${C_RESET} (Silverblue/Kinoite): podman is preinstalled. ✓" \
    "  ${C_BOLD}Arch${C_RESET}: if podman/docker is missing, ACE offers 'sudo pacman -S podman'." \
    "ACE never layers packages with rpm-ostree (which needs a reboot) — host tools stay" \
    "in \$HOME so the immutable base is untouched."
}
