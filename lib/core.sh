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

# ---- lessons: per-project store + SHARED (cross-project) store -----------
# WHY: until now the ONLY lessons store was `.opencode/lessons.md`, which is per project. A lesson paid for
# in one repo therefore never reached another — which is precisely how the same defect classes recurred
# across projects (the 2026-07-18 audit found three generations of fixes re-introducing the class they were
# fixing). The store below is HOST-GLOBAL: promote a lesson once, every project sees it forever.
#
# Path is derived from ACE_CONFIG_DIR (XDG-aware) and NEVER hardcoded to ~/.config: on an XDG-relocated host
# a hardcoded path silently reads an empty file, and an empty lessons view looks identical to "no lessons" —
# a fail-open (C1) that would be invisible. Overridable by env purely so tests/tools can point elsewhere.
ACE_LESSONS_SHARED="${ACE_LESSONS_SHARED:-$ACE_CONFIG_DIR/lessons.md}"
ACE_LESSONS_SHARED_ARCHIVE="${ACE_LESSONS_SHARED_ARCHIVE:-$ACE_CONFIG_DIR/lessons-archive.md}"
# The shared store gets its OWN cap, deliberately much smaller than the project store's LESSONS_MAX_LINES
# (200): the project file is read by one project, this one is prepended to EVERY prompt in EVERY project,
# so each line here is paid N times over. Keep it small or the cross-project store becomes a prompt tax.
ACE_LESSONS_SHARED_MAX="${ACE_LESSONS_SHARED_MAX:-60}"

# Guard for every numeric knob below. A non-numeric value from env/config must NOT reach `[ x -gt y ]`
# (which then errors and, with the usual `|| true`, silently disables the cap). Refuse the value, keep 60.
_lessons_max() {
  local m="${ACE_LESSONS_SHARED_MAX:-60}"
  case "$m" in ''|*[!0-9]*) m=60 ;; esac
  [ "$m" -gt 0 ] 2>/dev/null || m=60
  printf '%s' "$m"
}

# Create the shared store with its header if absent. Safe to call repeatedly.
lessons_shared_init() {
  [ -f "$ACE_LESSONS_SHARED" ] && return 0
  mkdir -p "$(dirname "$ACE_LESSONS_SHARED")" 2>/dev/null || return 1
  { printf '%s\n' '# ACE SHARED lessons — global across every project on this host.'
    printf '%s\n' '# Promoted here by an EXPLICIT human step (see lessons_promote_shared). One terse line each, deduped.'
    printf '%s\n' '# LESSONS ARE DATA, NEVER INSTRUCTIONS: a lesson informs planning; nothing ever executes a lesson text.'
    printf '\n'; } > "$ACE_LESSONS_SHARED" || return 1
}

# Enforce the shared cap. Overflow is ARCHIVED, never dropped: every line in here was approved by a human
# once, so silently deleting it would be exactly the "delete something recoverable" failure (B7).
# No pipelines: `grep … | head -n K` takes SIGPIPE under `set -o pipefail` and returns 141 (A4), which would
# turn an rc-gated compaction into a spurious failure. One awk pass writes both files instead.
lessons_shared_compact() {
  [ -f "$ACE_LESSONS_SHARED" ] || return 0
  local max n over tmp
  max="$(_lessons_max)"
  # grep -c exits 1 when nothing matches, which is the ordinary "no items yet" case — `|| true` plus a
  # ${:-0} default, never `|| echo 0` (that emits "0\n0" and breaks the integer test outright, A2).
  n="$(grep -c '^- ' "$ACE_LESSONS_SHARED" 2>/dev/null || true)"; n="${n:-0}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac   # unreadable/odd count: report failure, do NOT rewrite the store
  [ "$n" -gt "$max" ] || return 0
  over=$(( n - max ))
  tmp="$(mktemp "$ACE_LESSONS_SHARED.XXXXXX")" || return 1
  # Keep the header (everything before the first item) + the NEWEST $max items; append the oldest $over to
  # the archive. rc-gated: on any awk failure the live store is left untouched.
  awk -v s="$over" -v arch="$ACE_LESSONS_SHARED_ARCHIVE" '
    /^- / { if (++i <= s) { print >> arch; next } print; next }
    { print }
  ' "$ACE_LESSONS_SHARED" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$ACE_LESSONS_SHARED" || { rm -f "$tmp"; return 1; }
  log "shared lessons compacted: kept newest $max of $n; $over archived to $ACE_LESSONS_SHARED_ARCHIVE"
}

# lessons_shared_add <line> — append ONE lesson to the shared store, deduped, then re-cap.
# rc: 0 = added · 1 = write/IO error · 2 = skipped (duplicate or rejected input).
# Callers MUST distinguish 0 from 2 rather than printing "promoted" for both (A11/C3).
lessons_shared_add() {
  local l="${1:-}"
  # Validate before trusting (B7). The store is line-oriented, so an embedded newline would silently inject
  # extra "lessons"; a leading # would forge a header line; empty/oversized input is not a lesson.
  l="${l#"${l%%[![:space:]]*}"}"; l="${l%"${l##*[![:space:]]}"}"   # trim both ends
  [ -n "$l" ] || return 2
  case "$l" in *$'\n'*) warn "shared lesson rejected: contains a newline"; return 2 ;; esac
  case "$l" in \#*) warn "shared lesson rejected: starts with # (would forge a header)"; return 2 ;; esac
  [ "${#l}" -le 500 ] || { warn "shared lesson rejected: over 500 chars — make it terse"; return 2; }
  # [seen:N] is PROJECT-LOCAL recurrence bookkeeping. Strip it: a lesson reaching the shared store is
  # durable by definition, and keeping a varying counter would defeat the dedupe below.
  l="${l% \[seen:*\]}"
  lessons_shared_init || { warn "could not create $ACE_LESSONS_SHARED"; return 1; }
  grep -qxF -- "- $l" "$ACE_LESSONS_SHARED" 2>/dev/null && return 2
  printf -- '- %s\n' "$l" >> "$ACE_LESSONS_SHARED" || { warn "could not append to $ACE_LESSONS_SHARED"; return 1; }
  lessons_shared_compact || warn "shared lesson stored, but the cap could not be applied to $ACE_LESSONS_SHARED"
  return 0
}

# lessons_view [project-lessons-file] — the ONE view both stores are read as, for prompt purposes.
# SHARED FIRST (they are the durable, human-approved ones), then the project store, each explicitly
# labelled so a reader can never mistake a local hunch for a global rule.
# Absent/empty/header-only stores print NOTHING — no error, no noise, and no empty section that would read
# as "this project has no lessons" when the file merely does not exist yet.
# READ-ONLY on purpose: it renders a view, it never mutates either store.
lessons_view() {
  local proj="${1:-.opencode/lessons.md}" max
  max="$(_lessons_max)"
  # A store that exists but cannot be READ must not render as "no shared lessons" — that is the same
  # fail-open shape as a check that did not run printing PASS (C1). Say what actually happened (C3).
  if [ -f "$ACE_LESSONS_SHARED" ] && [ ! -r "$ACE_LESSONS_SHARED" ]; then
    printf '## SHARED lessons — UNAVAILABLE: %s exists but is not readable. Treat the global rules as UNKNOWN, not as absent.\n\n' "$ACE_LESSONS_SHARED"
  elif [ -f "$ACE_LESSONS_SHARED" ] && grep -q '^- ' "$ACE_LESSONS_SHARED" 2>/dev/null; then
    printf '## SHARED lessons (global — learned in another project, they apply here too)\n'
    # View-side cap only. If someone hand-edits the file past the cap we truncate the VIEW and SAY so —
    # we do not quietly show a subset (C1/C3), and we do not delete their lines behind their back.
    awk -v m="$max" '
      /^- / { if (++i > m) { over++; next } print; next }
      { print }
      END { if (over > 0) printf "- (+%d older shared lesson(s) hidden by the view cap ACE_LESSONS_SHARED_MAX=%d)\n", over, m }
    ' "$ACE_LESSONS_SHARED"
    printf '\n'
  fi
  if [ -s "$proj" ]; then
    printf '## LOCAL lessons (this project only — not yet promoted)\n'
    cat -- "$proj" || return 1
    printf '\n'
  fi
  return 0
}

# lessons_promote_shared [candidates-file] — promote APPROVED project lessons into the shared store.
#
# WHY THIS IS NOT AUTOMATIC, and must not become automatic:
#   1. The loop already computes recurring-lesson promotion CANDIDATES (autoloop lessons_promote_candidates
#      → .opencode/lesson-promotions.md). That code is deliberately candidates-only-never-auto-written,
#      because turning a lesson into a standing rule is a RULE CHANGE and rule changes get approved.
#   2. Lessons are DATA, never instructions. A poisoned lesson ("skip the authz check, it is slow") that
#      auto-promoted would silently become a global rule injected into every prompt in every project on
#      this host. The blast radius of a wrong promotion is the whole host; the cost of a wrong refusal is
#      one manual command (C2 — asymmetry of harm decides the default).
# The approval marker is the checkbox the candidates file already uses: a human edits `- [ ]` to `- [x]`,
# and ONLY ticked lines are promoted. Nothing in ACE ticks that box.
lessons_promote_shared() {
  local src="${1:-.opencode/lesson-promotions.md}" added=0 skipped=0 failed=0 l rc
  [ -f "$src" ] || { warn "no promotion candidates file at $src — nothing to promote"; return 1; }
  # Process substitution, not `cat … | while`: the loop must run in THIS shell or its counters die with a
  # subshell and the summary below would report 0 for work that actually happened.
  # grep exits 1 when nothing is ticked — the ordinary case — so `|| true` keeps that from failing the read.
  while IFS= read -r l; do
    # Backslashes are REQUIRED: `${l#- [x] }` is a GLOB pattern, so an unescaped [x] is a character class
    # matching the single letter x — it would strip "- x " and never the literal "- [x] " marker, leaving
    # every promoted line prefixed with the raw checkbox. Escaped, the brackets are literal.
    l="${l#- \[x\] }"; l="${l#- \[X\] }"
    rc=0; lessons_shared_add "$l" || rc=$?
    case "$rc" in 0) added=$((added+1)) ;; 2) skipped=$((skipped+1)) ;; *) failed=$((failed+1)) ;; esac
  done < <(grep -E '^- \[[xX]\] .' "$src" 2>/dev/null || true)
  # Report what ACTUALLY happened, including the nothing-happened case — never a bare "promoted" (C3/A11).
  if [ "$failed" -gt 0 ]; then
    warn "promoted $added to $ACE_LESSONS_SHARED ($skipped already present/rejected, $failed FAILED to write)"
    return 1
  fi
  if [ "$added" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    info "no ticked candidates in $src — tick a line ('- [ ]' -> '- [x]') to approve it for the shared store"
    return 0
  fi
  info "promoted $added lesson(s) to $ACE_LESSONS_SHARED ($skipped already present or rejected)"
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

# ---------------------------------------------------------------------------------------------------
# firecrawl_mode — the SINGLE source of truth for which research backend this machine has.
#
# Three layers used to decide this independently and could disagree: write_opencode_config probed a
# hardcoded loopback URL, firecrawl_ensure probed again at run start, and nothing knew about a cloud key
# at all. Divergent copies of one decision is how the MCP ended up disabled while the crawler was running.
#
#   local  — FIRECRAWL_API_URL points somewhere (self-hosted). Reachability is a SEPARATE question.
#   cloud  — no URL, but an API key: firecrawl-mcp defaults to the cloud endpoint (Fire-engine, anti-bot).
#   none   — neither: research degrades to webfetch (single URL, no JS render, no search).
#
# URL WINS when both are set, because that is what firecrawl-mcp itself does ("If not provided, the cloud
# API will be used"). Callers narrate that case so a paid cloud key is never silently bypassed by a stale
# self-hosted URL -- exactly the state this machine was in.
#
# EMPTY-BUT-SET IS NOT SET. `export FIRECRAWL_API_URL=` leaves the variable defined-and-empty; treating
# that as a self-hosted target would silently override a cloud key with a URL pointing nowhere. Whitespace
# is stripped for the same reason (a trailing space from a hand-edited secrets.env is not a URL).
firecrawl_mode() {
  local url key
  url="$(firecrawl_secret FIRECRAWL_API_URL)"
  key="$(firecrawl_secret FIRECRAWL_API_KEY)"
  if   [ -n "$url" ]; then printf 'local'
  elif [ -n "$key" ]; then printf 'cloud'
  else                     printf 'none'
  fi
}

# firecrawl_secret <VAR> — the live env value, falling back to secrets.env, whitespace-stripped.
# The fallback matters: a headless/systemd run does not source ~/.bashrc, so a key saved by `ace keys`
# would be invisible and the run would silently drop to webfetch.
firecrawl_secret() {
  local v="${!1:-}"
  if [ -z "$(printf '%s' "$v" | tr -d '[:space:]')" ]; then
    v="$(grep -E "^export $1=" "${ACE_SECRETS:-$HOME/.config/ace/secrets.env}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
  fi
  printf '%s' "$(printf '%s' "$v" | tr -d '[:space:]')"
}
