#!/usr/bin/env bash
# core.sh — distro/tool detection, config, dry-run, managed bashrc block.

ACE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ace"
ACE_SECRETS="$ACE_CONFIG_DIR/secrets.env"
ACE_CONFIG="$ACE_CONFIG_DIR/config"
ACE_VPS="$ACE_CONFIG_DIR/vps.env"
ACE_LOG_DIR="$ACE_CONFIG_DIR/logs"
ACE_LOG_FILE="${ACE_LOG_FILE:-$ACE_LOG_DIR/ace.log}"
ACE_DRY_RUN="${ACE_DRY_RUN:-0}"

have() { command -v "$1" >/dev/null 2>&1; }

# ---- logging -------------------------------------------------------------
log_init() {
  mkdir -p "$ACE_LOG_DIR" 2>/dev/null || true
  ACE_LOG_FILE="$ACE_LOG_DIR/ace-$(date +%Y%m%d).log"
  log "──── session start (v${ACE_VERSION:-?}, distro=${ACE_DISTRO:-?}, dry=${ACE_DRY_RUN}) ────"
}
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$ACE_LOG_FILE" 2>/dev/null || true; }

# ---- failsafes -----------------------------------------------------------
die() { err "$*"; log "FATAL: $*"; exit 1; }
need() { have "$1" || die "required command not found: $1"; }
# retry N cmd…
retry() {
  local n="$1"; shift; local i=1
  until "$@"; do
    [ "$i" -ge "$n" ] && { log "retry exhausted ($n): $*"; return 1; }
    warn "attempt $i/$n failed; retrying…"; sleep 2; i=$((i+1))
  done
}
ACE_TMP=()
cleanup() { local d; for d in "${ACE_TMP[@]:-}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true; done; }
trap cleanup EXIT
mktmp() { local d; d="$(mktemp -d)"; ACE_TMP+=("$d"); echo "$d"; }

# run CMD... — executes (logged), or prints in dry-run mode
run() {
  log "CMD: $*"
  if [ "$ACE_DRY_RUN" = "1" ]; then
    printf '%s %s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$*"; return 0
  fi
  "$@"; local rc=$?; log "EXIT $rc: $*"; return $rc
}

# run a shell snippet (for pipes/redirs) with dry-run awareness
run_sh() {
  log "SH: $1"
  if [ "$ACE_DRY_RUN" = "1" ]; then
    printf '%s %s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$1"; return 0
  fi
  bash -c "$1"; local rc=$?; log "EXIT $rc: $1"; return $rc
}

detect_distro() {
  ACE_DISTRO="unknown"; ACE_PKG=""; ACE_IMMUTABLE=0
  ACE_DISTRO_PRETTY="$(uname -srm)"
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    ACE_DISTRO_PRETTY="${PRETTY_NAME:-$NAME}"
    local id="${ID:-} ${ID_LIKE:-} ${VARIANT_ID:-}"
    case "$id" in
      *silverblue*|*kinoite*|*sericea*|*onyx*) ACE_DISTRO="fedora-atomic"; ACE_PKG="rpm-ostree"; ACE_IMMUTABLE=1 ;;
      *arch*|*endeavour*|*manjaro*|*cachyos*)  ACE_DISTRO="arch";          ACE_PKG="pacman" ;;
      *fedora*)                                 ACE_DISTRO="fedora";        ACE_PKG="dnf" ;;
      *debian*|*ubuntu*)                        ACE_DISTRO="debian";        ACE_PKG="apt" ;;
    esac
    # rpm-ostree presence ⇒ treat as immutable even if VARIANT unknown
    have rpm-ostree && { ACE_IMMUTABLE=1; [ -z "$ACE_PKG" ] && ACE_PKG="rpm-ostree"; }
  fi
  export ACE_DISTRO ACE_PKG ACE_IMMUTABLE ACE_DISTRO_PRETTY
}

container_engine() {
  if have podman; then echo podman
  elif have docker; then echo docker
  else echo ""; fi
}

ver() { "$1" --version 2>/dev/null | head -1 | tr -d '\n' || true; }

# Hermes collaboration (all OPTIONAL — ACE works standalone; these only activate when `hermes` is present).
# Delivery target, channel-agnostic + Telegram-first: $HERMES_TO env › stored config › telegram.
# Any channel works: telegram · telegram:<chat_id> · signal:+1555… · discord:<id> · slack:#chan · whatsapp:<id> · matrix:…
hermes_to() { local t="${HERMES_TO:-$(config_get HERMES_TO 2>/dev/null || true)}"; printf '%s' "${t:-telegram}"; }

config_init() { run mkdir -p "$ACE_CONFIG_DIR"; [ "$ACE_DRY_RUN" = 1 ] || chmod 700 "$ACE_CONFIG_DIR" 2>/dev/null || true; }
config_get()  { [ -f "$ACE_CONFIG" ] && grep -E "^$1=" "$ACE_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
config_set()  {
  config_init
  [ "$ACE_DRY_RUN" = 1 ] && { printf '%s set %s=%s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$1" "$2"; return; }
  touch "$ACE_CONFIG"; grep -v -E "^$1=" "$ACE_CONFIG" > "$ACE_CONFIG.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$ACE_CONFIG.tmp"; mv "$ACE_CONFIG.tmp" "$ACE_CONFIG"
}
# Single source of truth for the EFFECTIVE overseer (orchestrator) model id: an explicit per-agent
# MODEL_orchestrator override wins; else the ORCH_PROVIDER brain alias (opus|sonnet|gpt|deepseek); else the
# default overseer = Claude Opus. Used by the banner/status (here) AND the loop (identical resolver from $ACE_CFG).
orch_model() {
  local m; m="$(config_get MODEL_orchestrator)"
  [ -n "$m" ] && { printf '%s' "$m"; return; }
  case "$(config_get ORCH_PROVIDER)" in
    opus)     printf 'anthropic/claude-opus-4-8' ;;
    sonnet)   printf 'anthropic/claude-sonnet-4-6' ;;
    gpt)      printf 'openai/gpt-5' ;;
    deepseek) printf 'deepseek/deepseek-v4-pro' ;;
    *)        printf 'anthropic/claude-opus-4-8' ;;   # default overseer = Claude Opus (needs a Claude subscription)
  esac
}
orch_model_short() { local m; m="$(orch_model)"; printf '%s' "${m##*/}"; }   # e.g. claude-opus-4-8 · deepseek-v4-pro
# Add/update ONE export in secrets.env without clobbering the others (chmod 600). Empty value removes it.
secret_set() {  # <NAME> <VALUE>
  config_init
  [ "$ACE_DRY_RUN" = 1 ] && { printf '%s set secret %s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$1"; return; }
  mkdir -p "$(dirname "$ACE_SECRETS")"; touch "$ACE_SECRETS"
  grep -v -E "^export $1=" "$ACE_SECRETS" > "$ACE_SECRETS.tmp" 2>/dev/null || true
  [ -n "${2:-}" ] && printf 'export %s=%s\n' "$1" "$2" >> "$ACE_SECRETS.tmp"
  mv "$ACE_SECRETS.tmp" "$ACE_SECRETS"; chmod 600 "$ACE_SECRETS"
}

# Write a managed, idempotent block into ~/.bashrc (works on Arch + Silverblue;
# does not rely on ~/.bashrc.d which Arch's default bashrc doesn't source).
BASHRC="$HOME/.bashrc"
ACE_MARK_BEGIN="# >>> ace (agentic coding env) >>>"
ACE_MARK_END="# <<< ace <<<"

write_bashrc_block() {
  local body="$1"
  if [ "$ACE_DRY_RUN" = 1 ]; then
    printf '%s update managed block in %s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$BASHRC"; return
  fi
  touch "$BASHRC"
  cp "$BASHRC" "$BASHRC.ace.bak" 2>/dev/null && log "backed up $BASHRC -> $BASHRC.ace.bak"
  # strip any existing block
  awk -v b="$ACE_MARK_BEGIN" -v e="$ACE_MARK_END" '
    $0==b{skip=1} !skip{print} $0==e{skip=0}' "$BASHRC" > "$BASHRC.ace.tmp"
  { printf '%s\n%s\n%s\n' "$ACE_MARK_BEGIN" "$body" "$ACE_MARK_END"; } >> "$BASHRC.ace.tmp"
  mv "$BASHRC.ace.tmp" "$BASHRC"
}

# Detect whether the current shell will see a freshly-installed tool.
note_new_shell() { warn "Open a new terminal (or: source ~/.bashrc) so PATH/keys take effect."; }

# ---- VPS config (host/user/ssh key) --------------------------------------
vps_load() { [ -f "$ACE_VPS" ] && { set -a; . "$ACE_VPS"; set +a; }; }
vps_configured() { vps_load; [ -n "${VPS_HOST:-}" ] && [ -n "${VPS_USER:-}" ] && [ -n "${VPS_KEY:-}" ]; }
vps_save() {
  config_init
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would write $ACE_VPS"; return; }
  { printf 'export VPS_HOST=%q\n' "$VPS_HOST"
    printf 'export VPS_USER=%q\n' "$VPS_USER"
    printf 'export VPS_KEY=%q\n'  "$VPS_KEY"
    printf 'export VPS_PORT=%q\n' "${VPS_PORT:-22}"
    printf 'export VPS_DEPLOY_DIR=%q\n' "${VPS_DEPLOY_DIR:-}"
    printf 'export VPS_OS=%q\n' "${VPS_OS:-}"
    printf 'export VPS_HEALTH_URL=%q\n' "${VPS_HEALTH_URL:-}"
    printf 'export VPS_HEALTH_TIMEOUT=%q\n' "${VPS_HEALTH_TIMEOUT:-}"
    printf 'export VPS_HEALTH_INTERVAL=%q\n' "${VPS_HEALTH_INTERVAL:-}"
    printf 'export VPS_SERVICE_UNIT=%q\n' "${VPS_SERVICE_UNIT:-}"
    printf 'export VPS_DOMAIN=%q\n' "${VPS_DOMAIN:-}"; } > "$ACE_VPS"
  chmod 600 "$ACE_VPS"; log "saved VPS config to $ACE_VPS"
}
