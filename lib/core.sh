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
# 2>/dev/null comes FIRST on purpose: redirections are applied left-to-right, so if the >> open fails
# (log dir missing / read-only / bad ACE_LOG_FILE) the shell's own error message must already have a
# sink, otherwise it leaks onto the terminal and corrupts command substitutions that capture stderr.
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" 2>/dev/null >> "$ACE_LOG_FILE" || true; }

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
# Temp-dir registry (CA-06). mktmp is ALWAYS called as `$(mktmp)` — i.e. inside a command-substitution
# SUBSHELL — so appending to a shell array here died with that subshell and the EXIT trap below had
# nothing to remove: every run leaked its /tmp dirs. Record the dirs in a FILE instead, because a
# subshell write IS visible to the parent. This keeps `$(mktmp)` as the calling convention, so no call
# site changes ($$ stays the top-level shell PID even inside a subshell, so the path is stable).
# Registry lives under the 0700 per-user config dir, NOT world-writable /tmp: the path is derived from $$
# and therefore PREDICTABLE, so on a shared host (VPS, CI runner) another user could pre-create it and have
# cleanup() rm -rf every line it contains as the ACE user. $$ is still the top-level PID inside a subshell,
# so the path stays stable and $(mktmp) keeps its calling convention.
mkdir -p "$ACE_CONFIG_DIR" 2>/dev/null || true; chmod 700 "$ACE_CONFIG_DIR" 2>/dev/null || true
ACE_TMP_REG="$ACE_CONFIG_DIR/.tmpdirs.$$"
cleanup() {
  local d
  if [ -f "$ACE_TMP_REG" ]; then
    while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null || true; done < "$ACE_TMP_REG"
    rm -f "$ACE_TMP_REG" 2>/dev/null || true
  fi
}
trap cleanup EXIT
mktmp() {
  local d; d="$(mktemp -d)" || return 1
  printf '%s\n' "$d" >> "$ACE_TMP_REG" 2>/dev/null || true   # best-effort: a lost registry line only leaks, never breaks the caller
  printf '%s\n' "$d"
}

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
# Atomic, lock-guarded rewrite of ONE key in a line-oriented store (CFG-1/2/3).
# The old config_set/secret_set did a read-modify-write through a FIXED "$file.tmp": two ACE processes
# (the autoloop and the menu, or two swarm workers) raced on the SAME temp path, and BOTH the grep and
# the mv were unchecked (`|| true`), so a half-written temp could be renamed over the live store while
# the function still returned 0 — a silently truncated config/secrets file. Now: one lock per store,
# a UNIQUE mktemp in the same directory (so the mv stays an atomic same-filesystem rename), and every
# step rc-gated — on ANY failure we bail out non-zero leaving the live file untouched.
# _store_put <file> <drop-regex> <new-line|empty-to-delete>
_store_put() {
  local file="$1" re="$2" line="$3"
  mkdir -p "$(dirname "$file")" || return 1
  [ -e "$file" ] || { : > "$file" || return 1; }
  (
    # flock serializes concurrent writers. It is best-effort: where util-linux is absent we still get
    # the atomic mktemp+rename (no torn file), just without mutual exclusion — strictly better than before.
    if have flock; then flock 9 || exit 1; fi
    local tmp rc
    tmp="$(mktemp "$file.XXXXXX")" || exit 1
    # grep exits 1 when NOTHING matches, which is the normal "store has no other keys" case; only an
    # rc>1 is a real read error. Refusing to rename a short read is the whole point of this gate.
    grep -v -E "$re" "$file" > "$tmp" 2>/dev/null; rc=$?
    [ "$rc" -le 1 ] || { rm -f "$tmp"; exit 1; }
    if [ -n "$line" ]; then printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; exit 1; }; fi
    # mktemp is 0600; both stores live in a 0700 dir and one holds API keys, so keep it that way.
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file" || { rm -f "$tmp"; exit 1; }
  ) 9>"$file.lock"
}
config_set()  {
  config_init
  [ "$ACE_DRY_RUN" = 1 ] && { printf '%s set %s=%s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$1" "$2"; return; }
  _store_put "$ACE_CONFIG" "^$1=" "$(printf '%s=%s' "$1" "$2")" \
    || { warn "could not write $1 to $ACE_CONFIG (left unchanged)"; return 1; }
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
  local line=""
  # %q, NOT bare interpolation (CA-02/SEC-003). secrets.env is SOURCED by every login shell via the
  # managed bashrc block, so an unquoted value containing whitespace/;/$(…) truncated the assignment
  # and EXECUTED the remainder at every shell start — a paste of a key with a stray space was enough.
  # vps_save below already does this. install.sh's reader (grep '^export CONTEXT7_API_KEY=.') still
  # matches a %q-quoted value, so no reader needs to change.
  [ -n "${2:-}" ] && line="$(printf 'export %s=%q' "$1" "$2")"
  _store_put "$ACE_SECRETS" "^export $1=" "$line" \
    || { warn "could not write secret $1 to $ACE_SECRETS (left unchanged)"; return 1; }
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
  # CA-09: back up the PRISTINE bashrc ONCE. Copying on every run meant run #2 overwrote the pre-ACE
  # backup with an already-ACE-managed one, so the user's original bashrc became unrecoverable.
  if [ ! -e "$BASHRC.ace.bak" ]; then
    cp "$BASHRC" "$BASHRC.ace.bak" 2>/dev/null && log "backed up pristine $BASHRC -> $BASHRC.ace.bak"
  fi
  # strip any existing block — rc-gated so a failed awk/append never gets renamed over the live bashrc
  local tmp; tmp="$(mktemp "$BASHRC.ace.XXXXXX")" || { warn "could not create a temp file next to $BASHRC"; return 1; }
  awk -v b="$ACE_MARK_BEGIN" -v e="$ACE_MARK_END" '
    $0==b{skip=1} !skip{print} $0==e{skip=0}' "$BASHRC" > "$tmp" \
    || { rm -f "$tmp"; warn "could not rewrite $BASHRC — left unchanged"; return 1; }
  printf '%s\n%s\n%s\n' "$ACE_MARK_BEGIN" "$body" "$ACE_MARK_END" >> "$tmp" \
    || { rm -f "$tmp"; warn "could not rewrite $BASHRC — left unchanged"; return 1; }
  # mktemp is 0600; keep the bashrc's own mode so a rewrite never silently tightens/loosens it
  chmod --reference="$BASHRC" "$tmp" 2>/dev/null || chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$BASHRC" || { rm -f "$tmp"; warn "could not replace $BASHRC — left unchanged"; return 1; }
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
