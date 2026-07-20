#!/usr/bin/env bash
# ace — interactive menu system. Thematic top-level + submenus, and a comprehensive Settings surface
# (every screen is a thin wrapper over config_get/config_set + the provider/auth helpers, so a UI can
# plug straight in). Sourced last, so it can call functions defined across the other modules + ./ace.

# ---------------------------------------------------------------- provider / key setters (reusable)
set_deepseek_key() {
  ask_secret "DeepSeek API key (sk-…, Enter to keep current)"; local k="$ASK_REPLY"
  [ -n "$k" ] || { info "kept current DeepSeek key."; return; }
  info "Validating against api.deepseek.com…"
  if validate_deepseek_key "$k"; then secret_set DEEPSEEK_API_KEY "$k"; export DEEPSEEK_API_KEY="$k"; ok "DeepSeek key saved + valid."
  else err "Key rejected by DeepSeek — not saved."; fi
}
set_openrouter_key() {
  ask_secret "OpenRouter API key (sk-or-…, Enter to keep current)"; local k="$ASK_REPLY"
  [ -n "$k" ] || { info "kept current OpenRouter key."; return; }
  secret_set OPENROUTER_API_KEY "$k"; export OPENROUTER_API_KEY="$k"
  ok "OpenRouter key saved. Use it per agent via 'openrouter/<model>' (Models → per-agent), or for the cross-model debate (DEBATE_MODEL_B)."
}
set_context7_key() {
  ask_secret "Context7 API key (optional; Enter to KEEP the current one)"
  if [ -n "$ASK_REPLY" ]; then
    secret_set CONTEXT7_API_KEY "$ASK_REPLY"; export CONTEXT7_API_KEY="$ASK_REPLY"   # export so the status chip/doctor reflect it this session
    ok "Context7 key updated."
  else info "Kept existing Context7 key (nothing entered)."   # Enter must NOT wipe it; to clear, edit ~/.config/ace/secrets.env
  fi
}
set_anthropic_sub() {
  box "Claude Pro/Max subscription" \
    "ACE installs the anthropic-auth plugin and runs the OAuth login you already use." \
    "Pick the SUBSCRIPTION option at the prompt so agents bill your plan, not an API key."
  ensure_opencode_plugins
  ensure_provider_auth anthropic
}
set_openai() {
  menu "OpenAI auth" \
    "ChatGPT subscription (default)::opencode auth login -p openai — bills your ChatGPT plan" \
    "API key::pay-per-token via OPENAI_API_KEY" \
    "← back::"
  case "$MENU_CHOICE" in
    1) config_set AUTH_openai subscription; ensure_provider_auth openai ;;
    2) config_set AUTH_openai api; ask_secret "OpenAI API key (sk-…, Enter to keep)"; [ -n "$ASK_REPLY" ] && { secret_set OPENAI_API_KEY "$ASK_REPLY"; export OPENAI_API_KEY="$ASK_REPLY"; }; ok "OpenAI → API-key mode." ;;
    3) : ;;
  esac
}
providers_menu() {
  while true; do
    local astat ostat
    astat="$(opencode auth list 2>/dev/null | grep -qi anthropic && echo 'authed' || echo 'not authed')"
    ostat="$(opencode auth list 2>/dev/null | grep -qi openai && echo 'authed' || echo 'not authed')"
    banner   # screen clears the previous (no scroll-back clutter)
    menu "Settings · Providers & keys" \
      "DeepSeek API key::$([ -n "${DEEPSEEK_API_KEY:-}" ] && echo set || echo unset)" \
      "Anthropic — Claude Pro/Max subscription::$astat (login + plugin)" \
      "OpenAI::mode=$(o=$(config_get AUTH_openai); echo "${o:-subscription}") · $ostat" \
      "OpenRouter API key::$([ -n "${OPENROUTER_API_KEY:-}" ] && echo set || echo unset) · per-agent 'openrouter/<model>' + debate challenger" \
      "Context7 key::$([ -n "${CONTEXT7_API_KEY:-}" ] && echo set || echo unset)" \
      "← back::"
    case "$MENU_CHOICE" in 1) set_deepseek_key ;; 2) set_anthropic_sub ;; 3) set_openai ;; 4) set_openrouter_key ;; 5) set_context7_key ;; 6) return ;; esac
  done
}

# ---------------------------------------------------------------- models & agents
# Resolve the model-env (EFF_*/VERIFIER_MODEL/ORCH_MODEL) so default models display correctly.
_menu_model_env() {
  read -r EFF_MAIN EFF_VERIFY VERIFIER_MODEL <<<"$(profile_values)"
  ORCH_MODEL="$(orch_model)"   # single resolver (MODEL_orchestrator override wins, else ORCH_PROVIDER alias, else deepseek)
}
set_agent_model() {  # <agent>
  local a="$1" prov def m
  menu "Model provider for: $a" \
    "DeepSeek::deepseek-v4-pro / -flash" \
    "Anthropic (Claude subscription)::claude-opus-4-8 / sonnet-4-6" \
    "OpenAI::gpt-… (subscription or API)" \
    "OpenRouter::openrouter/<vendor/model> (API key)" \
    "Reset to default::clears the per-agent override" \
    "← back::"
  case "$MENU_CHOICE" in
    1) prov=deepseek; def="deepseek/deepseek-v4-pro" ;;
    2) prov=anthropic; def="anthropic/claude-opus-4-8" ;;
    3) prov=openai; def="openai/gpt-5" ;;
    4) prov=openrouter; def="openrouter/anthropic/claude-opus-4.1"
       [ -n "${OPENROUTER_API_KEY:-}" ] || warn "No OPENROUTER_API_KEY set — Settings → Providers & keys → OpenRouter first." ;;
    5) config_set "MODEL_$a" ""; ok "$a → default"; return ;;
    6) return ;;
  esac
  ask "Model id for $a ($prov/…)" "$def"; m="$ASK_REPLY"
  [ -n "$m" ] && { config_set "MODEL_$a" "$m"; ok "$a → $m"; }
}
model_presets_menu() {
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Models · presets" \
    "All DeepSeek::reset every agent (incl. overseer) to DeepSeek — no subscription" \
    "Overseer on Claude::orchestrator → claude-opus-4-8, rest DeepSeek" \
    "Overseer on OpenAI::orchestrator → gpt-5, rest DeepSeek" \
    "Mixed (Claude plan + DeepSeek)::orchestrator → claude-sonnet-4-6; light checks (verifier/standards/alignment) → flash; deep critics stay pro" \
    "Cross-review (critics ≠ implementer)::implementer/test → DeepSeek; the review panel → OpenRouter, so review isn't same-model self-agreement (needs OPENROUTER_API_KEY)" \
    "← back::"
  local a
  case "$MENU_CHOICE" in
    1) for a in $ACE_AGENTS; do config_set "MODEL_$a" ""; done; config_set ORCH_PROVIDER deepseek; ok "preset: all DeepSeek." ;;
    2) for a in $ACE_AGENTS; do config_set "MODEL_$a" ""; done; config_set MODEL_orchestrator "anthropic/claude-opus-4-8"; config_set ORCH_PROVIDER opus; ok "preset: overseer on Claude." ;;
    3) for a in $ACE_AGENTS; do config_set "MODEL_$a" ""; done; config_set MODEL_orchestrator "openai/gpt-5"; config_set ORCH_PROVIDER gpt; ok "preset: overseer on OpenAI." ;;
    4) for a in $ACE_AGENTS; do config_set "MODEL_$a" ""; done
       config_set MODEL_orchestrator "anthropic/claude-sonnet-4-6"; config_set ORCH_PROVIDER sonnet
       config_set MODEL_verifier "deepseek/deepseek-v4-flash"; config_set MODEL_standards_keeper "deepseek/deepseek-v4-flash"; config_set MODEL_alignment_reviewer "deepseek/deepseek-v4-flash"
       ok "preset: mixed." ;;
    5) [ -n "${OPENROUTER_API_KEY:-}" ] || warn "No OPENROUTER_API_KEY — set it first (Settings → Providers & keys → OpenRouter); the preset is applied regardless."
       local _orm; ask "OpenRouter model for the review panel" "openrouter/anthropic/claude-opus-4.1"; _orm="$ASK_REPLY"
       for a in $ACE_AGENTS; do config_set "MODEL_$a" ""; done
       # implementer + test_engineer stay DeepSeek (default); the review panel moves to a DIFFERENT provider so
       # critics don't share the implementer's blind spots. Overseer unchanged.
       for a in reviewer ux_reviewer standards_keeper alignment_reviewer; do config_set "MODEL_$a" "$_orm"; done
       ok "preset: cross-review — review panel → $_orm (implementer/test stay DeepSeek). Run 'ace opencode' to apply." ;;
    6) : ;;
  esac
}
agent_models_menu() {
  local EFF_MAIN EFF_VERIFY VERIFIER_MODEL ORCH_MODEL
  while true; do
    _menu_model_env
    local opts=() a n total
    for a in $ACE_AGENTS; do opts+=("$a → $(_agent_model "$a")::$([ -n "$(config_get "MODEL_$a")" ] && echo custom || echo default)"); done
    total="$(printf '%s\n' $ACE_AGENTS | wc -l)"
    opts+=("Presets (overseer-Claude · overseer-OpenAI · all-DeepSeek · mixed)::quick set")
    opts+=("Apply → rewrite OpenCode config::write + install plugins + login")
    opts+=("← back::")
    banner   # screen clears the previous (no scroll-back clutter)
    # Title states BOTH numbers: this list renders only the configurable agents, so a bare "12 agents"
    # here would contradict the 11 rows below it (the drift the settings screen used to ship).
    menu "Settings · Models & agents ($total of $((total + 1)) — debater is model-pinned)" "${opts[@]}"
    n="$MENU_CHOICE"
    if [ "$n" -le "$total" ]; then set_agent_model "$(printf '%s\n' $ACE_AGENTS | sed -n "${n}p")"
    elif [ "$n" = "$((total+1))" ]; then model_presets_menu
    elif [ "$n" = "$((total+2))" ]; then write_opencode_config; warn "Restart opencode so it loads the new models."; pause
    else return; fi
  done
}
# ---------------------------------------------------------------- cross-model debate
# Every debate knob is a thin config_get/config_set wrapper (same as the other Settings screens). The model
# fields show a GREYED format template per provider so the routing prefix is never guessed:
#   OpenRouter → openrouter/vendor/model   ·   OpenAI → openai/model   ·   Anthropic → anthropic/model
_DEBATE_MODEL_HINT="openrouter/vendor/model · openai/model · anthropic/model"
_debate_toggle() { local k="$1"; [ "$(config_get "$k")" = 1 ] && config_set "$k" 0 || config_set "$k" 1; }
_debate_onoff()  { [ "$(config_get "$1")" = 1 ] && echo ON || echo off; }
# after setting a challenger/defender model, remind the user which provider credential it needs
_debate_key_hint() {
  case "$1" in
    openrouter/*) [ -n "${OPENROUTER_API_KEY:-}" ] || warn "needs OPENROUTER_API_KEY — Settings → Providers & keys → OpenRouter." ;;
    openai/*)     opencode auth list 2>/dev/null | grep -qi openai || [ -n "${OPENAI_API_KEY:-}" ] || warn "needs OpenAI auth — Settings → Providers & keys → OpenAI." ;;
    anthropic/*)  opencode auth list 2>/dev/null | grep -qi anthropic || warn "needs the Anthropic (Claude) subscription login — Settings → Providers & keys → Anthropic." ;;
    "") : ;;
    */*) : ;;
    *) warn "‘$1’ has no provider prefix — use $_DEBATE_MODEL_HINT." ;;
  esac
}
debate_rounds_menu() {
  banner
  local mn mx hm to wl
  mn="$(config_get DEBATE_MIN)"; mx="$(config_get DEBATE_MAX)"; hm="$(config_get DEBATE_HARD_MAX)"
  to="$(config_get DEBATE_TIMEOUT)"; wl="$(config_get DEBATE_WALL_MAX)"
  menu "Settings · Debate — rounds & limits" \
    "Min rounds::${mn:-2} (default) — floor before it may converge" \
    "Max rounds::${mx:-4} (default) — the normal ceiling" \
    "Hard-max rounds::${hm:-10} (default) — absolute cap for complex specs" \
    "Per-turn timeout (s)::${to:-600} (default)" \
    "Wall backstop (s)::${wl:-1800} (default) — total-debate kill" \
    "← back::"
  case "$MENU_CHOICE" in
    1) ask "Min rounds" "${mn:-2}" "integer ≥1"; config_set DEBATE_MIN "$ASK_REPLY" ;;
    2) ask "Max rounds" "${mx:-4}" "integer ≥ min"; config_set DEBATE_MAX "$ASK_REPLY" ;;
    3) ask "Hard-max rounds" "${hm:-10}" "integer ≥ max"; config_set DEBATE_HARD_MAX "$ASK_REPLY" ;;
    4) ask "Per-turn timeout (seconds)" "${to:-600}"; config_set DEBATE_TIMEOUT "$ASK_REPLY" ;;
    5) ask "Wall backstop (seconds)" "${wl:-1800}"; config_set DEBATE_WALL_MAX "$ASK_REPLY" ;;
    6) return ;;
  esac
}
# Does an env var currently OVERRIDE the stored toggle? ./ace records that at startup (before it exports
# the config value), because after the export we can no longer tell env-set from config-set apart. Shown
# per row so the screen never claims a setting is in force when this session's env says otherwise.
_debate_envnote() { case " ${_ACE_DEBATE_FROM_ENV:-} " in *" $1 "*) printf ' [env %s=%s overrides this session]' "$1" "${!1:-}" ;; esac; }
debate_settings_menu() {
  while true; do
    banner   # screen clears the previous (no scroll-back clutter)
    # ${x:-default} is the ONLY working idiom here: config_get always exits 0 (core.sh), so the
    # `config_get X || echo N` form this screen used to use could never fire and rendered blanks.
    local a b mn mx hm
    a="$(config_get DEBATE_MODEL_A)"; b="$(config_get DEBATE_MODEL_B)"
    mn="$(config_get DEBATE_MIN)"; mx="$(config_get DEBATE_MAX)"; hm="$(config_get DEBATE_HARD_MAX)"
    menu "Settings · Cross-model debate" \
      "Spec debate (planning)::$(_debate_onoff SPEC_DEBATE) — two models pressure-test each spec before build$(_debate_envnote SPEC_DEBATE)" \
      "Review debate (pre-merge)::$(_debate_onoff REVIEW_DEBATE) — debate the branch diff before merging$(_debate_envnote REVIEW_DEBATE)" \
      "Defender model (A)::${a:-overseer default ($(orch_model 2>/dev/null))} · your side" \
      "Challenger model (B)::${b:-unset — debate is a no-op until set} · the OTHER model" \
      "Rounds & limits::min ${mn:-2} · max ${mx:-4} · hard ${hm:-10}" \
      "Verify cited sources::$(_debate_onoff SPEC_LINT_NET) — fetch each cited URL during the spec gate; catches invented citations, blocked and auth-walled sources (default: on when a research backend exists)" \
      "← back::"
    case "$MENU_CHOICE" in
      # These two are LIVE: ./ace exports the stored value into the environment every run, so flipping one
      # on here really does spend credits (and, for REVIEW_DEBATE, sends the branch diff to the challenger's
      # provider) on the next run. Say so — the toggle used to be inert, and a user who set it long ago may
      # not expect it to start firing. An env var set for a given run still wins over this value.
      1) _debate_toggle SPEC_DEBATE
         ok "Spec debate → $(_debate_onoff SPEC_DEBATE) — applies to the next run (env SPEC_DEBATE=… still overrides)." ;;
      2) _debate_toggle REVIEW_DEBATE
         ok "Review debate → $(_debate_onoff REVIEW_DEBATE) — applies to the next run; it sends the branch DIFF to the challenger's provider." ;;
      3) ask "Defender model (A) — Enter to use the overseer" "$a" "$_DEBATE_MODEL_HINT"; config_set DEBATE_MODEL_A "$ASK_REPLY"; _debate_key_hint "$ASK_REPLY" ;;
      4) ask "Challenger model (B)" "$b" "$_DEBATE_MODEL_HINT"; config_set DEBATE_MODEL_B "$ASK_REPLY"; _debate_key_hint "$ASK_REPLY" ;;
      5) debate_rounds_menu ;;
      6) _debate_toggle SPEC_LINT_NET
         ok "Verify cited sources → $(_debate_onoff SPEC_LINT_NET) — applies to the next run (env SPEC_LINT_NET=… still overrides)." ;;
      7) return ;;
    esac
  done
}
model_profile_menu() {
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Settings · Model profile (DeepSeek effort)" \
    "Max (recommended)::all workers think 'max'" \
    "High::lighter/faster" \
    "Balanced::flash verifier (cheapest checks)" \
    "← back::"
  case "$MENU_CHOICE" in 1) config_set MODEL_PROFILE max ;; 2) config_set MODEL_PROFILE high ;; 3) config_set MODEL_PROFILE balanced ;; 4) return ;; esac
  ok "Model profile: $(config_get MODEL_PROFILE) — Apply in 'Models & agents' to rewrite the config."
}

settings_menu() {
  # counts come from _agent_counts (architecture.sh → $ACE_AGENTS) so this label can never drift from the
  # roster the picker actually renders. The screen used to promise "12 agents" and then list 11, because
  # `debater` ships but is NOT model-configurable (it always runs with an explicit --model override).
  local n_cfg n_all; read -r n_cfg n_all <<<"$(_agent_counts)"
  while true; do
    banner   # screen clears the previous (no scroll-back clutter)
    menu "ACE — Settings" \
      "Providers & keys::DeepSeek · Anthropic · OpenAI · OpenRouter · Context7" \
      "Models & agents::$n_all agents ($n_cfg configurable — debater is model-pinned)" \
      "Model profile::DeepSeek effort (max/high/balanced)" \
      "Cross-model debate::spec/review toggles · defender/challenger models · rounds" \
      "Appearance::theme · animation · pixel art" \
      "(Re)write OpenCode config::apply current settings now" \
      "Toolchain update::opencode · bun · node · uv · go" \
      "← back::"
    case "$MENU_CHOICE" in
      1) providers_menu ;; 2) agent_models_menu ;; 3) model_profile_menu ;; 4) debate_settings_menu ;; 5) appearance_menu ;; 6) write_opencode_config; pause ;; 7) update; pause ;; 8) return ;;
    esac
  done
}

# Appearance — purely visual prefs (stored in ~/.config/ace/config; env vars override per-run).
appearance_menu() {
  local cap; while true; do
    if [ "$ACE_TC" = 1 ]; then cap="truecolor"; elif [ "$ACE_COLOR" = 1 ]; then cap="256-color"; else cap="no-color"; fi
    banner
    menu "Appearance  ($cap · theme=${_ACE_THEME:-warp} · anim=$([ "${ACE_NO_ANIM:-}" = 1 ] && echo off || echo on))" \
      "Theme: warp::violet (default)" \
      "Theme: blood::crimson / red" \
      "Theme: void::indigo-cyan (dark sci-fi)" \
      "Animation: $([ "${ACE_NO_ANIM:-}" = 1 ] && echo 'off → turn on' || echo 'on → turn off')::one-time intro reveal" \
      "← back::"
    case "$MENU_CHOICE" in
      1) config_set THEME warp;  apply_theme warp ;;
      2) config_set THEME blood; apply_theme blood ;;
      3) config_set THEME void;  apply_theme void ;;
      4) if [ "${ACE_NO_ANIM:-}" = 1 ]; then ACE_NO_ANIM=0; config_set NO_ANIM ""; else ACE_NO_ANIM=1; config_set NO_ANIM 1; fi; _ACE_BANNER_DONE=0 ;;
      5) return ;;
    esac
  done
}

# ---------------------------------------------------------------- thematic top-level submenus
setup_menu() {
  local n_all; n_all="$(_agent_counts | cut -d' ' -f2)"
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Setup / install" \
    "Full guided setup::host tools · keys · $n_all-agent config · git" \
    "Host tools only::fnm/node · uv · bun · jq · opencode · Go" \
    "Connect Git + GitHub::identity · gh login · credentials" \
    "(Re)write OpenCode config::agents + models + MCP" \
    "← back::"
  case "$MENU_CHOICE" in 1) guided; pause ;; 2) install_host_tools; pause ;; 3) setup_git_github; pause ;; 4) write_opencode_config; pause ;; 5) : ;; esac
}
build_menu() {
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Project / build" \
    "Scaffold a new project::Node · Python · Go · config-only" \
    "Edit project profile::architecture / delivery (ace profile)" \
    "Stacks::list / add a scaffoldable stack" \
    "Add a workspace package::wired TS package" \
    "Import existing code::map into brownfield/" \
    "Refresh code map::GitNexus + Serena" \
    "← back::"
  case "$MENU_CHOICE" in
    1) scaffold_project; pause ;;
    2) ( cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true; profile_wizard ); pause ;;
    3) stack_list; pause ;;
    4) ask "Package name" "core"; add_workspace_package "$ASK_REPLY"; pause ;;
    5) import_existing; pause ;;
    6) graph_refresh; pause ;;
    7) : ;;
  esac
}
# Keep-awake submenu. The main list entry used to call `awake_ctl status` unconditionally, so the only
# on/off control reachable from bare `ace` could report the state but never change it.
# NB: awake_ctl takes its optional duration from $ACE_ARG2 (the CLI's positional slot), NOT from $2 — so
# the timed variant sets that variable rather than passing an argument. `local` keeps it out of the
# exported environment the rest of the session sees.
awake_menu() {
  banner   # screen clears the previous (every other submenu does this; without it this list drew under "Run the loop")
  local ACE_ARG2="" st
  systemctl --user is-active ace-awake.service >/dev/null 2>&1 && st=ON || st=OFF
  menu "Keep machine awake  (currently: $st)" \
    "Turn ON::no idle-sleep / lid-suspend — stays reachable from Hermes/Signal until you turn it off" \
    "Turn ON for a duration::auto-releases afterwards (e.g. 4h) — kinder to a battery" \
    "Turn OFF::restore normal sleep/suspend" \
    "Status::show the active inhibitor" \
    "← back::"
  case "$MENU_CHOICE" in
    1) awake_ctl on ;;
    2) ask "Duration (systemd sleep syntax, e.g. 4h · 90m)" "4h"; ACE_ARG2="$ASK_REPLY"; awake_ctl on ;;
    3) awake_ctl off ;;
    4) awake_ctl status ;;
    5) : ;;
  esac
}
run_menu() {
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Run the loop" \
    "Autorun (the autonomous loop)::build → CI → merge → next" \
    "Resume after a stop::rescue gate-green work + continue" \
    "Explain delivery policy::resolved merge_gate/auto_merge/deploy_kind (no run)" \
    "Loop as a service::systemd user service — start/stop/restart/status/logs" \
    "Keep machine awake::on / on for a duration / off / status — reachable while away" \
    "← back::"
  case "$MENU_CHOICE" in
    1) autoloop_run; pause ;;
    2) autoloop_run; pause ;;
    3) ( cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null || true; autorun_explain ); pause ;;
    4) menu "Loop service (systemd --user)" \
         "Start::run the loop detached (survives terminal close + sleep)" \
         "Stop::" "Restart::" "Status::" "Logs (tail)::" "← back::"
       case "$MENU_CHOICE" in 1) loop_ctl start ;; 2) loop_ctl stop ;; 3) loop_ctl restart ;; 4) loop_ctl status ;; 5) loop_ctl logs ;; 6) : ;; esac
       pause ;;
    5) awake_menu; pause ;;   # entry 5 = "Keep machine awake" — keep this arm number aligned with the list above
    6) : ;;
  esac
}
gitq_menu() {
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Git & quality" \
    "Apply git-flow::main + conventional commits + guards" \
    "Protect main::GitHub ruleset (PR + CI required)" \
    "Audit deps & secrets::vuln audit + outdated + secret scan" \
    "Consistency / drift check::git ↔ origin · code-map · podman" \
    "← back::"
  case "$MENU_CHOICE" in 1) git_flow_apply "$PWD"; pause ;; 2) gh_protect_main; pause ;; 3) ace_audit; pause ;; 4) consistency_cmd; pause ;; 5) : ;; esac
}
deploy_menu() {
  local vh=""; vps_configured || vh="  (configure VPS first — option 1)"
  banner   # screen clears the previous (no scroll-back clutter)
  menu "Deploy & release" \
    "VPS menu::configure · bootstrap · provision · deploy" \
    "Deploy::pull + rebuild + restart + health-check$vh" \
    "Healthcheck::probe the live deploy$vh" \
    "Verify live deploy::agent triages findings → ROADMAP$vh" \
    "Release binaries (Go)::hardened cross-compile · ship with ace release --tag vX.Y.Z" \
    "← back::"
  # Guard the VPS-requiring entries: a not-yet-configured host gets a friendly hint, not a hard `die`.
  case "$MENU_CHOICE" in
    1) vps_menu; pause ;;
    2) if vps_configured; then vps_deploy; else warn "No VPS configured — use 'VPS menu' (option 1) to configure + provision first."; fi; pause ;;
    3) if vps_configured; then vps_healthcheck; else warn "No VPS configured — nothing to health-check yet."; fi; pause ;;
    4) if vps_configured; then vps_verify; else warn "No VPS configured — deploy to a VPS first."; fi; pause ;;
    5) release_run; pause ;;
    6) : ;;
  esac
}

main_menu() {
  while true; do
    banner
    menu "ACE — main menu" \
      "Status & health::tools · keys · providers · VPS · Go" \
      "Setup / install::guided · host tools · git+GitHub · OpenCode config" \
      "Project / build::scaffold · profile · stacks · package · code-map" \
      "Run the loop::autorun · resume · explain · service · awake" \
      "Git & quality::gitflow · protect · audit · consistency" \
      "Deploy & release::VPS · deploy · healthcheck · verify · release" \
      "Settings::providers/keys · models & agents · profile · toolchain" \
      "Architecture & help::how it works + what-lives-where" \
      "Logs::tail the latest run" \
      "Quit::"
    case "$MENU_CHOICE" in
      1) doctor; pause ;;
      2) setup_menu ;;
      3) build_menu ;;
      4) run_menu ;;
      5) gitq_menu ;;
      6) deploy_menu ;;
      7) settings_menu ;;
      8) show_architecture ;;
      9) logs; pause ;;
      10) return ;;
    esac
  done
}
