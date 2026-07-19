#!/usr/bin/env bash
# vps.sh — configure a VPS, detect its OS, install the runtime, wire CI deploy
# secrets, provision a git-based deploy (deploy key + clone), and trigger deploys.

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
vssh() { ssh "${SSH_OPTS[@]}" -i "$VPS_KEY" -p "${VPS_PORT:-22}" "$VPS_USER@$VPS_HOST" "$@"; }
repo_slug() { gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null; }

# ---------------------------------------------------------------- configure
vps_configure() {
  step "VPS connection"
  vps_load
  ask "VPS host (IP or domain)" "${VPS_HOST:-}"; VPS_HOST="$ASK_REPLY"
  [ -z "$VPS_HOST" ] && { warn "no host — aborting"; return 1; }
  ask "VPS user" "${VPS_USER:-root}"; VPS_USER="$ASK_REPLY"
  ask "SSH port" "${VPS_PORT:-22}"; VPS_PORT="$ASK_REPLY"
  ask "SSH private key path" "${VPS_KEY:-$HOME/.ssh/id_ed25519}"; VPS_KEY="$ASK_REPLY"
  [ -f "$VPS_KEY" ] || warn "key not found at $VPS_KEY (you can fix it later)"
  ask "Remote deploy dir" "${VPS_DEPLOY_DIR:-\$HOME/apps}"; VPS_DEPLOY_DIR="$ASK_REPLY"
  ask "Post-deploy health URL (probed ON the VPS)" "${VPS_HEALTH_URL:-http://127.0.0.1:3000/}"; VPS_HEALTH_URL="$ASK_REPLY"
  ask "Health-check timeout (seconds to become healthy)" "${VPS_HEALTH_TIMEOUT:-90}"; VPS_HEALTH_TIMEOUT="$ASK_REPLY"
  ask "systemd unit (blank = a podman container named after the repo — ACE's default deploy)" "${VPS_SERVICE_UNIT:-}"; VPS_SERVICE_UNIT="$ASK_REPLY"
  ask "Public domain (optional — enables DNS + TLS-SAN checks in 'ace vps check')" "${VPS_DOMAIN:-}"; VPS_DOMAIN="$ASK_REPLY"
  export VPS_HOST VPS_USER VPS_PORT VPS_KEY VPS_DEPLOY_DIR VPS_HEALTH_URL VPS_HEALTH_TIMEOUT VPS_SERVICE_UNIT VPS_DOMAIN

  if [ "$ACE_DRY_RUN" != 1 ]; then
    if spin "Testing SSH to $VPS_USER@$VPS_HOST:$VPS_PORT" vssh true; then
      VPS_OS="$(vssh '. /etc/os-release 2>/dev/null && echo "$ID"' 2>/dev/null | tr -d '\r')"
      export VPS_OS
      ok "Connected. Remote OS: ${VPS_OS:-unknown}"
    else
      warn "Could not connect (check host/user/key/port, and that your pubkey is in the VPS authorized_keys)."
      confirm "Save config anyway?" Y || return 1
    fi
  fi
  vps_save
  ok "VPS config saved to $ACE_VPS"
}

vps_require() { vps_load; [ -n "${VPS_HOST:-}" ] && [ -n "${VPS_USER:-}" ] || die "VPS not configured — run: ace vps → configure"; }

vps_detect_os() {
  vps_require
  VPS_OS="$(vssh '. /etc/os-release 2>/dev/null && echo "$ID"' 2>/dev/null | tr -d '\r')"
  export VPS_OS; vps_save
  ok "Remote OS: ${VPS_OS:-unknown}"
}

# ---------------------------------------------------------------- bootstrap
vps_bootstrap() {
  vps_require
  [ -n "${VPS_OS:-}" ] || vps_detect_os
  step "Bootstrap VPS runtime (podman + git) on ${VPS_OS:-unknown}"
  local pkgcmd
  case "$VPS_OS" in
    ubuntu|debian)        pkgcmd='$S apt-get update -y && $S DEBIAN_FRONTEND=noninteractive apt-get install -y podman git curl' ;;
    arch|cachyos|manjaro) pkgcmd='$S pacman -Sy --noconfirm --needed podman git curl' ;;
    fedora|rhel|centos|rocky|almalinux) pkgcmd='$S dnf install -y podman git curl' ;;
    *) warn "unknown remote OS '${VPS_OS:-}'. Supported: ubuntu/debian, arch, fedora."; confirm "Try the fedora/dnf path?" N && pkgcmd='$S dnf install -y podman git curl' || return 1 ;;
  esac
  local remote
  remote=$(cat <<EOF
set -e
if [ "\$(id -u)" = 0 ]; then S=; else S=sudo; fi
$pkgcmd
loginctl enable-linger "\$(whoami)" 2>/dev/null || true
systemctl --user enable --now podman.socket 2>/dev/null || true
echo "OK: \$(podman --version 2>/dev/null), \$(git --version 2>/dev/null)"
EOF
)
  if [ "$ACE_DRY_RUN" = 1 ]; then info "[dry-run] would ssh + run:"; say "$remote"; return 0; fi
  spin "Installing runtime on $VPS_HOST" bash -c "echo '$remote' | ssh ${SSH_OPTS[*]} -i '$VPS_KEY' -p '${VPS_PORT:-22}' '$VPS_USER@$VPS_HOST' bash -s" \
    && ok "Runtime installed (podman + git)." || { err "Bootstrap failed — see: ace logs"; return 1; }
  confirm "Harden the host now (fail2ban · auto-updates · ufw · key-only SSH)?" Y && vps_harden || info "skipped hardening (run 'ace vps harden' any time)."
}

# ---------------------------------------------------------------- hardening (opt-in, lockout-safe)
# Idempotent server hardening: fail2ban (sshd jail), unattended security upgrades, a ufw baseline
# (SSH port + 80/443, deny the rest), and key-only SSH. Lock-out guards: allows the SSH port BEFORE
# enabling ufw; keeps key-based root (prohibit-password, not 'no'); validates sshd config and
# RELOADS (never restarts/drops the session); skips the SSH password-disable if no authorized_keys
# exist. Ubuntu/Debian (apt). Re-running is a no-op.
vps_harden() {
  vps_require
  local sp="${VPS_PORT:-22}" out ch
  step "Harden $VPS_USER@$VPS_HOST"
  box "Idempotent + lockout-safe. This will:" \
    "• install + enable fail2ban (sshd jail)" \
    "• enable unattended-upgrades (auto security patches)" \
    "• ufw: allow ${sp}/80/443, default-deny incoming (SSH allowed BEFORE enabling)" \
    "• SSH: disable password auth, keep key-based root (config validated + reloaded, not restarted)"
  confirm "Apply to $VPS_HOST?" Y || { info "skipped."; return 0; }
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would ssh + apply the hardening above"; return 0; }
  local remote
  remote=$(cat <<EOF
set -u
if [ "\$(id -u)" = 0 ]; then S=; else S=sudo; fi
export DEBIAN_FRONTEND=noninteractive
ch=""
have(){ command -v "\$1" >/dev/null 2>&1; }
have apt-get || echo "NOTE: non-apt OS — apt steps skipped; doing ufw/ssh where available"

# 1) fail2ban (sshd jail)
if ! systemctl is-active --quiet fail2ban 2>/dev/null && have apt-get; then
  \$S apt-get update -qq && \$S apt-get install -y fail2ban >/dev/null 2>&1 && \$S systemctl enable --now fail2ban >/dev/null 2>&1 && ch="\$ch fail2ban"
fi
# 2) unattended-upgrades
if ! systemctl is-enabled --quiet unattended-upgrades 2>/dev/null && have apt-get; then
  \$S apt-get install -y unattended-upgrades >/dev/null 2>&1 \
    && printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' | \$S tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null \
    && \$S systemctl enable --now unattended-upgrades >/dev/null 2>&1 && ch="\$ch auto-updates"
fi
# 3) ufw — allow SSH FIRST, then 80/443, then enable (never lock out)
have ufw || { have apt-get && \$S apt-get install -y ufw >/dev/null 2>&1; }
if have ufw; then
  \$S ufw allow ${sp}/tcp >/dev/null 2>&1; \$S ufw allow 80/tcp >/dev/null 2>&1; \$S ufw allow 443/tcp >/dev/null 2>&1
  \$S ufw default deny incoming >/dev/null 2>&1; \$S ufw default allow outgoing >/dev/null 2>&1
  \$S ufw status 2>/dev/null | grep -qi '^Status: active' || { \$S ufw --force enable >/dev/null 2>&1 && ch="\$ch ufw"; }
fi
# 4) key-only SSH — ONLY if a key is installed (else skip to avoid lockout)
if [ -s "\$HOME/.ssh/authorized_keys" ]; then
  d=/etc/ssh/sshd_config.d/99-ace-hardening.conf
  want=\$(printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\nPubkeyAuthentication yes')
  if [ "\$(\$S cat "\$d" 2>/dev/null)" != "\$want" ]; then
    printf '%s\n' "\$want" | \$S tee "\$d" >/dev/null
    if \$S sshd -t 2>/dev/null; then \$S systemctl reload ssh 2>/dev/null || \$S systemctl reload sshd 2>/dev/null; ch="\$ch ssh-keyonly"
    else \$S rm -f "\$d"; echo "WARN: sshd config would be invalid — reverted the SSH step"; fi
  fi
else
  echo "NOTE: no authorized_keys for \$(whoami) — skipped the SSH password-disable (would risk lockout)"
fi
echo "CHANGED:\$ch"
echo "STATE fail2ban=\$(systemctl is-active fail2ban 2>/dev/null) auto-updates=\$(systemctl is-enabled unattended-upgrades 2>/dev/null) ufw=\$(\$S ufw status 2>/dev/null | head -1 | awk '{print \$2}')"
EOF
)
  out="$(timeout 200 ssh "${SSH_OPTS[@]}" -i "$VPS_KEY" -p "$sp" "$VPS_USER@$VPS_HOST" bash -s <<<"$remote" 2>&1)"
  if ! printf '%s' "$out" | grep -q 'CHANGED:'; then
    err "Hardening didn't complete cleanly (SSH failed?) — output:"; printf '%s\n' "$out" | sed 's/^/  /'; return 1
  fi
  printf '%s\n' "$out" | grep -vE '^(CHANGED|STATE):' | sed 's/^/  /'
  ch="$(printf '%s' "$out" | sed -n 's/^CHANGED://p')"
  printf '%s\n' "$out" | sed -n 's/^STATE /  /p'
  [ -n "${ch// }" ] && ok "Hardened:${ch}" || ok "Already hardened — nothing to change."
  info "Confirm with 'ace vps check'."
}

# ---------------------------------------------------------------- CI deploy secrets
vps_wire_ci() {
  vps_require; need gh
  local slug; slug="$(repo_slug)"
  [ -z "$slug" ] && die "run this inside a repo with a GitHub 'origin' (use Scaffold/Git-flow first)."
  step "Wire GitHub Actions deploy secrets → $slug"
  # vps-3/UI-004: every `gh secret set` here is rc-gated and the summary line is only reached when
  # ALL of them landed. Previously a failed VPS_SSH_KEY upload (no admin scope / repo not found /
  # unreadable key) still printed "Deploy secrets set", so the deploy job silently failed to
  # authenticate later and the failure was misattributed to the VPS.
  run gh secret set VPS_HOST --body "$VPS_HOST" || { err "could not set VPS_HOST"; return 1; }
  run gh secret set VPS_USER --body "$VPS_USER" || { err "could not set VPS_USER"; return 1; }
  run gh secret set VPS_PORT --body "${VPS_PORT:-22}" || { err "could not set VPS_PORT"; return 1; }
  if [ "$ACE_DRY_RUN" = 1 ]; then info "[dry-run] gh secret set VPS_SSH_KEY < $VPS_KEY"
  else
    [ -r "$VPS_KEY" ] || { err "SSH key not readable: $VPS_KEY — deploy secrets NOT set."; return 1; }
    gh secret set VPS_SSH_KEY < "$VPS_KEY" && ok "VPS_SSH_KEY set" \
      || { err "could not set VPS_SSH_KEY (gh auth / repo admin rights?) — deploy secrets NOT set."; return 1; }
  fi
  ok "Deploy secrets set. The deploy job (on push to main) can now reach the VPS."
}

# ---------------------------------------------------------------- provision (git deploy)
vps_provision() {
  vps_require; need gh
  local slug name; slug="$(repo_slug)"
  [ -z "$slug" ] && die "no GitHub origin here — scaffold/publish the repo first."
  name="${slug##*/}"
  local ddir="${VPS_DEPLOY_DIR:-\$HOME/apps}/$name"
  step "Provision git deploy for $slug → $VPS_HOST:$ddir"

  spin "Checking VPS connectivity" vssh true || die "cannot reach VPS"
  if ! vssh 'command -v podman >/dev/null'; then
    confirm "podman missing on VPS — bootstrap runtime now?" Y && vps_bootstrap || warn "continuing without runtime"
  fi

  # read-only deploy key on the VPS, registered with the repo
  if [ "$ACE_DRY_RUN" = 1 ]; then
    info "[dry-run] generate VPS deploy key, register via gh, clone $slug into $ddir, run scripts/deploy.sh"; return 0
  fi
  info "Creating a read-only deploy key on the VPS…"
  vssh 'test -f ~/.ssh/ace_deploy || ssh-keygen -t ed25519 -N "" -f ~/.ssh/ace_deploy -C ace-deploy >/dev/null'
  local pub tmp; pub="$(vssh 'cat ~/.ssh/ace_deploy.pub')"; tmp="$(mktmp)/key.pub"; printf '%s\n' "$pub" > "$tmp"
  if gh repo deploy-key list 2>/dev/null | grep -q ace-deploy; then ok "deploy key already registered"
  else gh repo deploy-key add "$tmp" -t ace-deploy >/dev/null 2>&1 && ok "deploy key registered (read-only)" || warn "could not add deploy key (check gh perms)"; fi

  info "Cloning / updating repo on the VPS…"
  local gitssh="GIT_SSH_COMMAND='ssh -i ~/.ssh/ace_deploy -o StrictHostKeyChecking=accept-new'"
  # $ddir is DOUBLE-quoted on the remote side, not printf %q'd like sibling vps_check does: ddir
  # deliberately carries a LITERAL \$HOME (the default is "\$HOME/apps/<name>") that must expand on
  # the VPS, and %q would escape that $ into a literal path component. Double quotes keep the
  # expansion while stopping word-splitting/globbing on a VPS_DEPLOY_DIR containing spaces. $slug is
  # a pure value with nothing to expand, so it gets the stronger %q treatment.
  local qslug; qslug="$(printf %q "$slug")"
  vssh "mkdir -p \"\$(dirname \"$ddir\")\"; if [ -d \"$ddir/.git\" ]; then cd \"$ddir\" && $gitssh git fetch origin && git reset --hard origin/main; else $gitssh git clone git@github.com:$qslug \"$ddir\"; fi" \
    && ok "Repo on VPS at $ddir" || { err "clone/pull failed"; return 1; }

  if vssh "test -x \"$ddir/scripts/deploy.sh\""; then
    confirm "Run first deploy now (scripts/deploy.sh on VPS)?" Y && vps_run_deploy_script "$ddir"
  else
    warn "No scripts/deploy.sh in repo yet — generate one with 'ace scaffold' (it adds CI + deploy.sh)."
  fi
}

vps_run_deploy_script() {
  local ddir="$1"
  spin "Deploying on $VPS_HOST" vssh "cd \"$ddir\" && ./scripts/deploy.sh" \
    && ok "Deployed." || { err "deploy.sh failed — see: ace logs"; return 1; }
  vps_healthcheck
}

# ---------------------------------------------------------------- post-deploy health check
# Verifies the app actually came up after a deploy: polls (with timeouts) for the HTTP health
# URL to answer, ON the VPS. Process model is auto-detected — VPS_SERVICE_UNIT (systemd) takes
# precedence, else a podman container named after the repo. On failure dumps the RIGHT logs
# (journalctl for systemd, podman logs for a container). Returns non-zero so 'ace deploy' / the
# autorun loop treat a sick deploy as a failure.
vps_healthcheck() {
  vps_require
  local name url timeout interval unit
  name="${1:-$(repo_slug)}"; name="${name##*/}"
  url="${VPS_HEALTH_URL:-http://127.0.0.1:3000/}"
  timeout="${VPS_HEALTH_TIMEOUT:-90}"
  interval="${VPS_HEALTH_INTERVAL:-3}"
  unit="${VPS_SERVICE_UNIT:-}"                  # set => systemd service; empty => podman container
  # One precomputed label. `${unit:+A}${unit:-B}` printed BOTH when unit was set (the :- fallback
  # expands to $unit itself), so the line read "service 'app', app".
  local svc; if [ -n "$unit" ]; then svc="service '$unit'"; else svc="container '$name'"; fi
  step "Health check → $url ($svc; up to ${timeout}s)"
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would poll $url for ≤${timeout}s on the VPS"; return 0; }

  # one SSH session runs the whole poll loop remotely. HTTP answering is the authoritative signal.
  local remote
  remote=$(cat <<EOF
set -u
name=$(printf %q "$name"); url=$(printf %q "$url"); unit=$(printf %q "$unit")
# Try the OTHER scheme too: prod often serves http on the app port (TLS terminated by nginx on 443),
# while the local dev stack serves self-signed https there. A healthy app on either scheme passes.
case "\$url" in
  https://*) alt="http://\${url#https://}" ;;
  http://*)  alt="https://\${url#http://}" ;;
  *)         alt="\$url" ;;
esac
deadline=\$(( \$(date +%s) + $timeout ))
http=0; code=000; goodurl=""
while [ \$(date +%s) -lt \$deadline ]; do
  for u in "\$url" "\$alt"; do
    if code=\$(curl -fsSk -o /dev/null -w '%{http_code}' --max-time 5 "\$u" 2>/dev/null); then http=1; goodurl="\$u"; break; fi
  done
  [ \$http -eq 1 ] && break
  sleep $interval
done
echo "HTTP=\$http CODE=\$code URL=\$goodurl"
if [ \$http -ne 1 ]; then
  # classify the failure so the caller can tell a CONFIG/probe issue from a real code crash
  # Liveness must be derived from the ACTUAL process model. ACE's DEFAULT deploy is a podman
  # container (no systemd unit), and the old code left active="n/a" in that case, so the CONFIG and
  # RUNTIME branches below were UNREACHABLE and every podman failure was classified CODE — telling
  # the loop "the app crashed, redevelop it" when the real fault was a wrong health URL or a
  # non-binding port. podman inspect gives the same up/down signal systemctl gives for a unit.
  if [ -n "\$unit" ]; then
    active=\$(systemctl is-active "\$unit" 2>/dev/null || echo unknown)
  else
    case "\$(podman inspect -f '{{.State.Running}}' "\$name" 2>/dev/null)" in
      true)  active=active ;;
      false) active=inactive ;;
      *)     active=unknown ;;   # no such container (never started / wrong name) — treated as CODE below
    esac
  fi
  port=\$(printf '%s' "\$url" | sed -E 's#.*://[^/:]+:([0-9]+).*#\1#'); case "\$port" in ''|*[!0-9]*) port=3000 ;; esac
  listen=\$( { ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null; } | grep -c ":\$port " )
  if [ "\$active" = active ] && [ "\$listen" -gt 0 ]; then echo "CLASS=CONFIG"
  elif [ "\$active" = active ]; then echo "CLASS=RUNTIME"
  else echo "CLASS=CODE"; fi
  echo "ACTIVE=\$active LISTEN=\$listen PORT=\$port"
  if [ -n "\$unit" ]; then
    echo "--- systemctl status \$unit ---"; systemctl --no-pager status "\$unit" 2>&1 | head -15
    echo "--- journalctl -u \$unit (last 40) ---"; journalctl -u "\$unit" -n 40 --no-pager 2>&1 | tail -40
  else
    echo "--- podman ps -a ---"; podman ps -a 2>&1 | head
    echo "--- podman logs --tail 40 \$name ---"; podman logs --tail 40 "\$name" 2>&1 || echo "(no container '\$name')"
  fi
  exit 1
fi
EOF
)
  local out rc class
  # outer guard so a hung SSH session can't outlive the budget
  out="$(timeout "$((timeout + 30))" ssh "${SSH_OPTS[@]}" -i "$VPS_KEY" -p "${VPS_PORT:-22}" "$VPS_USER@$VPS_HOST" 'bash -s' <<<"$remote" 2>&1)"; rc=$?
  if printf '%s\n' "$out" | grep -q 'HTTP=1'; then
    ok "Healthy — $(printf '%s' "$out" | grep -oE 'URL=[^ ]+' | head -1 | cut -d= -f2) answered ($(printf '%s' "$out" | grep -oE 'CODE=[0-9]+' | head -1 | cut -d= -f2))."
    return 0
  fi
  class="$(printf '%s' "$out" | grep -oE 'CLASS=[A-Z]+' | head -1 | cut -d= -f2)"
  case "$class" in
    CONFIG)  err "App is UP and listening, but $url didn't return 2xx — this is a CONFIG/probe issue (wrong URL / http-vs-https / path), NOT a code crash. Fix VPS_HEALTH_URL; do NOT redevelop the app." ;;
    RUNTIME) err "Service is active but nothing is serving the port — the app isn't binding (runtime/config: start command, port, env). Check the unit, not the code first." ;;
    CODE)    err "Service is NOT running — the app crashed (code/runtime error). This needs a FIX/redevelop — see the logs below." ;;
    *)       [ "$rc" = 124 ] && err "Health check TIMED OUT (ssh budget ${timeout}s+30) — $VPS_HOST unreachable or app never came up." \
                             || err "Health check FAILED after ${timeout}s — nothing serving $url ($svc)." ;;
  esac
  printf '%s\n' "$out" | sed 's/^/  /'
  return 1
}

# ---------------------------------------------------------------- redeploy
vps_deploy() {
  # honor deploy_kind — a VPS deploy only makes sense for a 'service' project. artifact/none projects
  # have no scripts/deploy.sh, so fail with a clear message instead of a confusing "Deploy failed".
  # deploy_kind is a PROJECT-profile field (.opencode/profile.yaml), same store autoloop + scaffold read —
  # NOT the global ace config (which never carries it, so the guard used to be dead).
  local _dk; _dk="$(_prof_get deploy_kind 2>/dev/null)"; [ -n "$_dk" ] && [ "$_dk" != service ] && {
    warn "deploy_kind=$_dk — this project has no VPS service to deploy.$([ "$_dk" = artifact ] && echo " Binaries ship on a v* tag: 'ace release --tag vX.Y.Z'.")"; return 0; }
  vps_require
  local slug name ddir latest="" gate force last=""; slug="$(repo_slug)"; name="${slug##*/}"
  ddir="${VPS_DEPLOY_DIR:-\$HOME/apps}/$name"
  # ---- milestone gate -----------------------------------------------------------------
  # DEPLOY_GATE=release: ship ONLY when origin/main carries a v* tag we haven't deployed yet, so
  # the loop can call `ace deploy` every merge yet only deploy at a milestone you mark (`ace release
  # --tag vX.Y.Z`, or any `git tag v*` pushed at a complete feature / section / major version).
  # Bypass for an on-demand deploy: `ace deploy --force` or DEPLOY_FORCE=1.
  gate="${DEPLOY_GATE:-$(config_get DEPLOY_GATE)}"; gate="${gate:-always}"
  force="${DEPLOY_FORCE:-0}"; [ "${ACE_ARG:-}" = force ] && force=1
  if [ "$gate" = release ] && [ "$force" != 1 ]; then
    git fetch --tags --quiet origin 2>/dev/null || true
    latest="$(git tag --merged origin/main --sort=-v:refname 2>/dev/null | grep -E '^v[0-9]' | head -1)"
    last="$(config_get DEPLOY_LAST_TAG)"
    if [ -z "$latest" ]; then
      info "deploy gated (DEPLOY_GATE=release): no v* tag on origin/main yet — mark a milestone with 'ace release --tag vX.Y.Z' (or 'ace deploy --force' to ship now). Skipping."; return 0
    elif [ "$latest" = "$last" ]; then
      info "deploy gated (DEPLOY_GATE=release): $last already deployed, no newer tag. Skipping."; return 0
    fi
    step "Milestone $latest (last deployed: ${last:-none}) — deploying."
  fi
  # ---- launch-readiness gate (C6) -------------------------------------------------------
  # Before promoting to the live VPS, run the project's mechanical pre-promotion subset
  # (ci.sh --launch): tested-restore evidence, rollback runbook, SLO/runbook presence.
  # FAIL-CLOSED — a NO-GO BLOCKS the promote (never ship unverified). The launch_readiness_reviewer
  # agent does the judgment; this is the mechanical floor the deploy flow enforces. LAUNCH_GATE=0 overrides.
  if [ "${LAUNCH_GATE:-1}" = 1 ] && [ -f ci.sh ] && grep -q -- '--launch' ci.sh 2>/dev/null; then
    step "Launch-readiness gate (ci.sh --launch)"
    bash ci.sh --launch || { err "launch-readiness NO-GO — promote BLOCKED. Fix the [blocker] ops/ evidence (restore-drill.result, rollback.md) or set LAUNCH_GATE=0 to override. See: LAUNCH-READINESS.md"; return 1; }
    ok "Launch-readiness GO."
  elif [ "${LAUNCH_GATE:-1}" = 1 ]; then
    warn "launch-readiness gate SKIPPED — no ci.sh --launch tier here (re-scaffold to add ops/ readiness checks, or set LAUNCH_GATE=0 to silence)."
  fi
  step "Deploy (pull + rebuild + restart) → $VPS_HOST:$ddir"
  # Use the ace deploy key for git ONLY if it was provisioned; otherwise fall back to the repo's
  # existing git auth on the VPS (e.g. a CI-provisioned deploy key / stored credential / agent).
  local rcmd
  rcmd="cd \"$ddir\" || { echo '[deploy] missing $ddir — run: ace vps -> Provision'; exit 1; }; "
  rcmd+='if [ -f "$HOME/.ssh/ace_deploy" ]; then export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/ace_deploy -o StrictHostKeyChecking=accept-new"; fi; '
  rcmd+='git fetch origin && git reset --hard origin/main && ./scripts/deploy.sh'
  spin "Syncing code + running deploy.sh" vssh "$rcmd" \
    || { err "Deploy failed — see: ace logs (git auth on the VPS? run: ace vps -> Provision, or check the repo's remote/creds on the server)"; return 1; }
  ok "Deployed latest."
  # B4: the health check IS the release gate — record DEPLOY_LAST_TAG only AFTER it passes.
  # Recording first marked a FAILED release as shipped, so every retry short-circuited at the
  # "$last already deployed" branch above with exit 0 and the fix NEVER reached the VPS (a broken
  # tag stayed live until someone manually forced a deploy). Matches docs/deploy.md:27.
  vps_healthcheck "$slug" || return 1
  if [ "$gate" = release ] && [ -n "$latest" ]; then
    config_set DEPLOY_LAST_TAG "$latest" \
      || warn "could not record DEPLOY_LAST_TAG=$latest — the next 'ace deploy' will simply ship this tag again."
  fi
  return 0
}

# ---------------------------------------------------------------- post-deploy verification agent
# Deeper than the health check: COLLECT live facts from the VPS read-only (reachability, TLS,
# service state, recent errors, integration/connection status), then TRIAGE — an agent reads the
# report + repo and appends real errors + high-value improvements to ROADMAP.md, so the autonomous
# loop fixes them on the next pass. The agent only *curates the backlog*; it changes nothing live.
#   ACE_VERIFY_TRIAGE=auto|ask|off   VPS_SERVICE_UNIT=<systemd unit>   VPS_HEALTH_URL / VERIFY_ENDPOINTS
vps_verify() {
  vps_require
  local name unit health endpoints report
  name="$(repo_slug)"; name="${name##*/}"
  unit="${VPS_SERVICE_UNIT:-}"                  # set => systemd service; empty => podman container named $name (matches vps_healthcheck)
  # Same default as vps_healthcheck / vps_check / vps_configure. It used to default to
  # /api/system/status, an endpoint most projects do not have, so an unconfigured VPS_HEALTH_URL made
  # verify report a healthy app as "unreachable" — and the triage agent filed that phantom outage
  # into ROADMAP.md, sending the loop off to fix a service that was never down.
  health="${VPS_HEALTH_URL:-http://127.0.0.1:3000/}"
  endpoints="${VERIFY_ENDPOINTS:-$health}"   # space-separated list of URLs to probe ON the VPS
  report=".opencode/vps-verify-report.md"
  mkdir -p .opencode
  # same single-expansion label as vps_healthcheck (the :+/:- pair both fired when unit was set)
  local svc; if [ -n "$unit" ]; then svc="systemd service '$unit'"; else svc="container '$name'"; fi
  step "Verify deployment → $VPS_HOST ($svc)"
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would collect VPS facts → $report, then triage into ROADMAP.md"; return 0; }

  # ---- phase 1: collect (one read-only SSH session) ----
  local remote
  remote=$(cat <<EOF
set +e
echo "## Post-deploy verification — \$(hostname) — \$(date -u +%FT%TZ)"
unit=$(printf %q "$unit"); name=$(printf %q "$name")
if [ -n "\$unit" ]; then
  echo; echo "### Service (systemd: \$unit)"
  systemctl is-active "\$unit" 2>/dev/null || echo "is-active: unknown"
  systemctl --no-pager show "\$unit" -p ActiveState,SubState,NRestarts,ExecMainStartTimestamp 2>/dev/null
  echo; echo "### Recent errors (journalctl -p err, last 40)"
  journalctl -u "\$unit" -p err -n 40 --no-pager 2>/dev/null | tail -40 || echo "(no journal access)"
else
  echo; echo "### Service (podman container: \$name)"
  podman inspect -f 'Running={{.State.Running}} Restarts={{.RestartCount}} Started={{.State.StartedAt}} Status={{.State.Status}}' "\$name" 2>/dev/null || echo "container not found: \$name"
  echo; echo "### Recent errors (podman logs, last 40)"
  podman logs --tail 40 "\$name" 2>&1 | tail -40 || echo "(no container logs)"
fi
echo; echo "### TLS cert (:443)"
echo | openssl s_client -connect localhost:443 -servername localhost 2>/dev/null | openssl x509 -noout -issuer -subject -enddate 2>/dev/null || echo "no TLS on :443"
echo; echo "### Reachability"
for u in $endpoints; do
  code=\$(curl -fsS -o /dev/null -w '%{http_code} %{time_total}s' --max-time 8 "\$u" 2>/dev/null) && echo "OK   \$u -> \$code" || echo "FAIL \$u -> unreachable"
done
echo; echo "### Connection / integration status (\$(echo "$health"))"
curl -fsS --max-time 8 "$health" 2>/dev/null || echo "health endpoint not responding"
echo; echo "### Host"
echo "node \$(node -v 2>/dev/null)  pnpm \$(pnpm -v 2>/dev/null)"
echo "disk \$(df -h / 2>/dev/null | awk 'NR==2{print \$5\" used\"}')  mem \$(free -h 2>/dev/null | awk '/Mem:/{print \$3\"/\"\$2}')"
EOF
)
  { echo "<!-- generated by: ace vps verify -->"
    timeout 75 ssh "${SSH_OPTS[@]}" -i "$VPS_KEY" -p "${VPS_PORT:-22}" "$VPS_USER@$VPS_HOST" 'bash -s' <<<"$remote" 2>&1
  } > "$report"
  ok "Collected → $report"; sed 's/^/  /' "$report" | head -45

  # ---- phase 2: triage findings into the backlog (agent CURATES, script writes) ----
  local mode="${ACE_VERIFY_TRIAGE:-ask}"
  if [ "$mode" = ask ]; then { [ -t 0 ] && confirm "Triage findings into ROADMAP.md (the loop fixes them next)?" Y && mode=auto || mode=off; }; fi
  [ "$mode" = auto ] || { info "Triage skipped. Report at $report."; return 0; }
  have opencode || { warn "opencode not found — can't triage. Report at $report."; return 0; }

  step "Triage — agent curates errors + improvements into ROADMAP.md"
  # vps-5/UI-005: capture the agent rc AND its stderr. The old call discarded both (2>/dev/null) and
  # then grepped an EMPTY string, so an auth failure / bad model id / rate limit produced zero
  # findings and ACE printed "Verification clean — no new backlog items". A triage that never ran is
  # NOT a clean bill of health: warn, show the tail, and return non-zero so callers can react.
  local findings raw trc
  raw="$(opencode run --agent "${AGENT:-orchestrator}" </dev/null "Read the post-deploy verification report at $report and cross-check the codebase. Identify ONLY real, verifiable problems (unreachable/erroring endpoints, broken or unconnected integrations, service restarts/crashes, TLS expiring soon, missing wiring) AND concrete high-value improvements toward a professional, money-making portal. SYMPTOM CLOSURE: first read .opencode/memory/changelog.md (recent ships); if a problem in the report is the SAME symptom a recently-shipped item claimed to fix, the fix did NOT take effect live — prefix that item with 'RE-OPENED: fix did not take effect live — ' instead of filing a fresh duplicate. Skip anything already listed (unchecked) in ROADMAP.md. Output ONLY a GitHub-Markdown checklist — one '- [ ] <specific, actionable item> (evidence: <short cite from report>)' per finding, nothing else. If everything is healthy, output nothing." 2>&1)"; trc=$?
  if [ "$trc" -ne 0 ]; then
    warn "Triage agent FAILED (rc=$trc) — findings were NOT collected. This is NOT 'verification clean'; check opencode auth/model/rate limits, then re-run: ace vps verify"
    printf '%s\n' "$raw" | tail -5 | sed 's/^/  /'
    info "Raw report is still at $report."
    return 1
  fi
  findings="$(printf '%s\n' "$raw" | grep -E '^- \[ \] ')"
  if [ -n "$findings" ]; then
    [ -f ROADMAP.md ] || printf '# Roadmap\n\n## Next\n' > ROADMAP.md
    printf '\n### From post-deploy verify (%s)\n%s\n' "$(date -u +%F)" "$findings" >> ROADMAP.md
    ok "Appended $(printf '%s\n' "$findings" | grep -c '^- \[ \] ') item(s) to ROADMAP.md — the loop will pick them up."
  else
    ok "Verification clean — no new backlog items."
  fi
}

# ---------------------------------------------------------------- menu
# ---------------------------------------------------------------- readiness / hardening doctor
# Read-only assessment of how ready the VPS is to deploy on / initialize / harden. Probes
# reachability, system resources, container engine, reverse proxy + TLS cert (expiry/SAN), DNS
# (domain -> this host), the app service + its env, the database, firewall/SSH hardening, and
# deploy readiness (dir, git auth, env file). Prints ✓/⚠/✗ per check + a verdict. Changes NOTHING.
# Optional: set VPS_DOMAIN in vps.env to enable the DNS + cert-SAN match.
vps_check() {
  vps_require
  local name ddir rcmd out fails warns
  name="$(repo_slug)"; name="${name##*/}"
  ddir=""; [ -n "$name" ] && ddir="${VPS_DEPLOY_DIR:-\$HOME/apps}/$name"   # match configure/provision/deploy default ($HOME/apps), not /root/apps
  step "VPS readiness check → $VPS_USER@$VPS_HOST (read-only; nothing is changed)"
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would SSH and assess system/TLS/DNS/app/DB/hardening/deploy"; return 0; }
  rcmd="UNIT=$(printf %q "${VPS_SERVICE_UNIT:-}") HEALTH=$(printf %q "${VPS_HEALTH_URL:-http://127.0.0.1:3000/}") DOMAIN=$(printf %q "${VPS_DOMAIN:-}") EXPECT_IP=$(printf %q "$VPS_HOST") DDIR=$(printf %q "$ddir") bash -s"
  out="$(timeout 75 ssh "${SSH_OPTS[@]}" -i "$VPS_KEY" -p "${VPS_PORT:-22}" "$VPS_USER@$VPS_HOST" "$rcmd" <<'REMOTE' 2>&1
set -u
P(){ printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
W(){ printf '  \033[1;33m⚠\033[0m %s\n' "$*"; }
F(){ printf '  \033[1;31m✗\033[0m %s\n' "$*"; }
H(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
ports(){ ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null; }

H "SYSTEM"
. /etc/os-release 2>/dev/null && P "OS ${PRETTY_NAME:-?} · $(uname -m) · kernel $(uname -r)" || W "OS unknown"
use=$(df / 2>/dev/null | awk 'NR==2{print $5+0}'); free=$(df -h / 2>/dev/null | awk 'NR==2{print $4" free / "$2}')
[ "${use:-100}" -lt 85 ] && P "disk /: $free (${use}% used)" || W "disk /: $free (${use}% used) — low"
P "memory: $(free -m 2>/dev/null | awk '/Mem:/{print $7"MB avail / "$2"MB"}')   load:$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"

H "RUNTIME"
if have podman; then P "podman $(podman --version 2>/dev/null|awk '{print $3}') (rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null||echo ?))"
elif have docker; then P "docker $(docker --version 2>/dev/null|awk '{print $3}')"
else F "no container engine (podman/docker) — DB + --container gate can't run"; fi

H "WEB / PROXY / TLS"
proxy=""; for s in nginx caddy; do systemctl is-active "$s" >/dev/null 2>&1 && proxy="$s"; done
[ -n "$proxy" ] && P "reverse proxy: $proxy active" || W "no nginx/caddy active — public TLS likely not terminated"
ports | grep -q ':443 ' && P "listening on :443" || W "nothing on :443 — no public TLS endpoint"
ports | grep -q ':80 '  && P "listening on :80"  || W "nothing on :80"
cert=$(grep -rhoE 'ssl_certificate[[:space:]]+[^;]+' /etc/nginx 2>/dev/null | awk '{print $2}' | head -1)
[ -z "$cert" ] && for c in /etc/letsencrypt/live/*/fullchain.pem /etc/ssl/*/fullchain.pem; do [ -f "$c" ] && cert="$c" && break; done
if [ -n "${cert:-}" ] && have openssl && [ -f "$cert" ]; then
  end=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
  days=$(( ( $(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  san=$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null | grep -oE 'DNS:[^,]+' | sed 's/DNS://' | paste -sd, -)
  if [ "${days:-0}" -gt 21 ]; then P "TLS cert OK — ${days}d left (until $end) [${san:-?}]"
  elif [ "${days:-0}" -gt 0 ]; then W "TLS cert expires in ${days}d ($end) — renew soon [${san:-?}]"
  else F "TLS cert EXPIRED/invalid ($end)"; fi
else W "no TLS cert found to inspect (checked nginx config + /etc/letsencrypt)"; fi

H "DNS"
if [ -z "$DOMAIN" ]; then DOMAIN=$(grep -rhoE 'server_name[[:space:]]+[^;]+' /etc/nginx 2>/dev/null | awk '{print $2}' | grep -vE '_|localhost' | head -1); fi
if [ -n "$DOMAIN" ]; then
  rip=$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1; exit}'); [ -z "$rip" ] && have dig && rip=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
  if [ -z "$rip" ]; then F "$DOMAIN has no A record (does not resolve)"
  elif [ "$rip" = "$EXPECT_IP" ]; then P "$DOMAIN → $rip (matches this VPS)"
  else W "$DOMAIN → $rip, but this VPS is $EXPECT_IP (mismatch, or fronted by a proxy/CDN)"; fi
else W "no domain known (set VPS_DOMAIN) — skipped DNS/A-record check"; fi

H "APP SERVICE"
if [ -n "$UNIT" ]; then
  act=$(systemctl is-active "$UNIT" 2>/dev/null)
  [ "$act" = active ] && P "service $UNIT: active (enabled=$(systemctl is-enabled "$UNIT" 2>/dev/null||echo ?))" || F "service $UNIT: ${act:-missing}"
  ef=$(systemctl show "$UNIT" -p EnvironmentFiles --value 2>/dev/null)
  [ -n "$ef" ] && P "env file wired: $ef" || W "service has NO EnvironmentFile — runtime DATABASE_URL/secrets may be unset"
else
  n=$(basename "${DDIR:-}" 2>/dev/null)
  if [ -n "$n" ] && command -v podman >/dev/null 2>&1; then
    run=$(podman inspect -f '{{.State.Running}}' "$n" 2>/dev/null)
    [ "$run" = true ] && P "container $n: running" || F "container $n: not running (or not found) — set VPS_SERVICE_UNIT if you deploy via systemd"
  else W "no VPS_SERVICE_UNIT and no container name known — skipped app-service check"; fi
fi
code=$(curl -fsSk -o /dev/null -w '%{http_code}' --max-time 5 "$HEALTH" 2>/dev/null || echo 000)
case "$code" in 2*) P "health $HEALTH → $code";; *) W "health $HEALTH → $code (down, or wrong URL/protocol)";; esac

H "DATABASE"
if have pg_isready && pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null; then P "postgres 127.0.0.1:5432 ready"
elif (echo >/dev/tcp/127.0.0.1/5432) 2>/dev/null; then P "postgres port 5432 open"
else W "postgres 127.0.0.1:5432 not reachable (DB container/quadlet down?)"; fi

H "SECURITY / HARDENING"
if have ufw && ufw status 2>/dev/null | grep -qi active; then P "firewall: ufw active"
elif systemctl is-active firewalld >/dev/null 2>&1; then P "firewall: firewalld active"
else W "no host firewall (ufw/firewalld) active"; fi
sc=/etc/ssh/sshd_config
pr=$(grep -iE '^[[:space:]]*PermitRootLogin' $sc 2>/dev/null | tail -1 | awk '{print $2}')
pa=$(grep -iE '^[[:space:]]*PasswordAuthentication' $sc 2>/dev/null | tail -1 | awk '{print $2}')
case "${pr:-yes}" in no|prohibit-password) P "ssh: root login restricted (${pr})";; *) W "ssh: PermitRootLogin=${pr:-default(yes)} — consider 'no'";; esac
[ "${pa:-yes}" = no ] && P "ssh: password auth disabled (keys only)" || W "ssh: PasswordAuthentication=${pa:-default(yes)} — consider 'no'"
systemctl is-active fail2ban >/dev/null 2>&1 && P "fail2ban active" || W "fail2ban not active — no brute-force protection"
( systemctl is-enabled unattended-upgrades >/dev/null 2>&1 || systemctl is-active dnf-automatic.timer >/dev/null 2>&1 ) && P "auto security updates: on" || W "auto security updates: off"

H "DEPLOY READINESS"
if [ -z "$DDIR" ]; then W "run 'ace vps check' from your project dir to assess deploy readiness (no git repo in the current dir)"
elif [ -d "$DDIR" ]; then P "deploy dir $DDIR present"
  if [ -d "$DDIR/.git" ]; then
    if [ -f "$HOME/.ssh/ace_deploy" ]; then export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/ace_deploy -o StrictHostKeyChecking=accept-new"; fi
    ( cd "$DDIR" && git ls-remote origin -h >/dev/null 2>&1 ) && P "git remote reachable + authenticated" || F "git auth/remote FAILS — fix the deploy key/creds on the VPS"
    envf=""; for e in "$DDIR/.env" "$DDIR/.env.local" "$DDIR/.env.production"; do [ -f "$e" ] && envf="$e" && break; done
    [ -n "$envf" ] && P "env file present ($envf — $(grep -cE '^[A-Z][A-Z0-9_]*=' "$envf" 2>/dev/null) vars set)" || W "no .env/.env.local in $DDIR — secrets unset"
  else F "$DDIR is not a git repo — not provisioned (run: ace vps -> Provision)"; fi
else F "deploy dir $DDIR missing — run: ace vps -> Provision"; fi
REMOTE
)"
  if ! printf '%s' "$out" | grep -q '== SYSTEM =='; then
    err "Couldn't assess the VPS (SSH failed / host unreachable). Raw:"; printf '%s\n' "$out" | sed 's/^/  /'; return 1
  fi
  printf '%s\n' "$out"
  fails=$(printf '%s' "$out" | grep -c '✗'); warns=$(printf '%s' "$out" | grep -c '⚠')
  echo
  if [ "${fails:-0}" -gt 0 ]; then err "VERDICT: NOT deploy-ready — ${fails} blocker(s), ${warns} warning(s). Clear the ✗ first."
  elif [ "${warns:-0}" -gt 0 ]; then warn "VERDICT: deployable, with ${warns} hardening/config item(s) worth fixing."
  else ok "VERDICT: ready + hardened. ✓"; fi
}

vps_menu() {
  while true; do
    vps_load
    local statusline="not configured"
    vps_configured && statusline="${VPS_USER}@${VPS_HOST}:${VPS_PORT:-22}  os=${VPS_OS:-?}"
    banner
    menu "VPS  (${statusline})" \
      "Configure connection::host / user / ssh key / deploy dir (tests + detects OS)" \
      "Detect OS::re-probe /etc/os-release over SSH" \
      "Bootstrap runtime::install podman + git (ubuntu/arch/fedora)" \
      "Wire CI deploy secrets::gh secret set VPS_HOST/USER/PORT/SSH_KEY" \
      "Provision git deploy::deploy key + clone repo on VPS + first deploy" \
      "Deploy now::pull + rebuild + restart on VPS (+ health check)" \
      "Health check::verify the live deployment is up (container + HTTP, with timeout)" \
      "Verify (agent)::deep post-deploy checks -> triage errors/improvements into ROADMAP" \
      "Readiness check::read-only doctor: system / TLS-cert / DNS / app / DB / firewall / SSH / deploy-readiness" \
      "Harden host::fail2ban + auto-updates + ufw + key-only SSH (opt-in, lockout-safe, idempotent)" \
      "← back::"
    case "$MENU_CHOICE" in
      1) vps_configure; pause ;; 2) vps_detect_os; pause ;; 3) vps_bootstrap; pause ;;
      4) vps_wire_ci; pause ;; 5) vps_provision; pause ;; 6) vps_deploy; pause ;;
      7) vps_healthcheck; pause ;; 8) vps_verify; pause ;; 9) vps_check; pause ;; 10) vps_harden; pause ;; 11) return ;;
    esac
  done
}
