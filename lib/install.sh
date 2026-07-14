#!/usr/bin/env bash
# install.sh — host tools, API keys, OpenCode config, gh/git wiring.

# ---------------------------------------------------------------- supply chain
# fetch_verified <url> <sha256> <outfile> — download a release artifact and verify its sha256
# BEFORE anything uses it. This is the ONE choke point every pinned binary install goes through
# (jq, gh, UPX, Go); the mergiraf block predates it and inlines the same fail-closed check.
# It FAILS CLOSED: a hash mismatch removes the artifact and refuses to install an unverified binary.
# The return code lets each caller keep its own optional/required semantics AND tells a transient
# NETWORK problem apart from a supply-chain INTEGRITY failure:
#   0  downloaded and sha256 VERIFIED (safe to install)
#   1  DOWNLOAD/NETWORK failure — nothing written (caller may treat as non-fatal / retry next run)
#   2  SHA256 MISMATCH — FAIL CLOSED; artifact deleted; never install it (a real supply-chain event)
# In dry-run it prints intent and returns 0 without touching the network.
fetch_verified() {
  local url="$1" want="$2" out="$3"
  if [ "$ACE_DRY_RUN" = 1 ]; then
    printf '%s %s\n' "${C_YELLOW}[dry-run]${C_RESET}" "would fetch+verify $url (sha256 ${want:0:12}…)"
    return 0
  fi
  log "FETCH: $url"
  if ! curl -fsSL "$url" -o "$out" 2>/dev/null; then
    log "FETCH network-fail: $url"; rm -f "$out" 2>/dev/null || true; return 1
  fi
  if ! printf '%s  %s\n' "$want" "$out" | sha256sum -c - >/dev/null 2>&1; then
    err "supply-chain: SHA256 MISMATCH for $url — refusing to install (expected $want, got $(sha256sum "$out" 2>/dev/null | awk '{print $1}'))"
    log "FETCH sha256-mismatch: $url"; rm -f "$out" 2>/dev/null || true; return 2
  fi
  log "FETCH verified: $url"; return 0
}

# Make freshly-installed user-local tools visible to the rest of this run.
activate_paths() {
  export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.bun/bin:$HOME/.opencode/bin:$HOME/.local/go/bin:$HOME/go/bin:$PATH"
  export FNM_LOGLEVEL=quiet
  have fnm && eval "$(fnm env --use-on-cd --log-level quiet --shell bash 2>/dev/null)" 2>/dev/null || true
  [ -f "$ACE_SECRETS" ] && { set -a; . "$ACE_SECRETS"; set +a; }
}

# ---------------------------------------------------------------- pinned tool installs
# Each tool below is PINNED to a specific version and its release artifact is sha256-verified via
# fetch_verified BEFORE install — never `releases/latest`, never `go.dev/VERSION` (floating). Per-arch
# hashes were computed from the real upstream artifacts with `sha256sum`. To move a pin deliberately,
# set <TOOL>_VERSION together with a matching <TOOL>_SHA256 (same escape hatch as MERGIRAF_*). A hash
# mismatch FAILS CLOSED (refuses to install); a download failure stays non-fatal where it already was.

# jq — user-local static binary. Optional-ish: a download failure is non-fatal (retried next run).
install_jq_verified() {
  local ver="${JQ_VERSION:-1.8.2}" arch sha rc tmp
  case "$(uname -m)" in
    x86_64)        arch=amd64; sha=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f ;;
    aarch64|arm64) arch=arm64; sha=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 ;;
    *) warn "jq: unsupported arch $(uname -m) — skipping (optional)."; return 0 ;;
  esac
  [ "$ver" = 1.8.2 ] || sha="${JQ_SHA256:-}"
  [ -n "$sha" ] || { warn "jq: no pinned sha256 for $ver — set JQ_SHA256 to install it (skipping)."; return 0; }
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would install jq $ver ($arch), sha256-verified."; return 0; }
  mkdir -p "$HOME/.local/bin"; tmp="$HOME/.local/bin/.jq.$$"
  fetch_verified "https://github.com/jqlang/jq/releases/download/jq-${ver}/jq-linux-${arch}" "$sha" "$tmp"; rc=$?
  case $rc in
    0) chmod +x "$tmp" && mv -f "$tmp" "$HOME/.local/bin/jq" ;;
    1) warn "jq: download failed — skipping (optional; retried next run)." ;;
    *) err "jq: refused to install (sha256 mismatch) — leaving jq absent." ;;
  esac
  rm -f "$tmp" 2>/dev/null || true; return 0
}

# UPX — OPTIONAL release packer (tar.xz). All failures are non-fatal; a mismatch fails closed.
install_upx_verified() {
  local ver="${UPX_VERSION:-5.2.0}" arch sha rc d f
  case "$(uname -m)" in
    x86_64)        arch=amd64; sha=3db5d3294707439db97866feab8d75d800f028f48481a40547411824da4288a1 ;;
    aarch64|arm64) arch=arm64; sha=55d48a61e8ffd17152db871c855376cba7f08e830b37799d0947a16dff8ec36c ;;
    *) warn "upx: unsupported arch $(uname -m) — skipping (optional)."; return 0 ;;
  esac
  [ "$ver" = 5.2.0 ] || sha="${UPX_SHA256:-}"
  [ -n "$sha" ] || { warn "upx: no pinned sha256 for $ver — set UPX_SHA256 to install it (skipping)."; return 0; }
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would install UPX $ver ($arch), sha256-verified."; return 0; }
  d="$(mktemp -d)"; f="$d/upx.tar.xz"
  fetch_verified "https://github.com/upx/upx/releases/download/v${ver}/upx-${ver}-${arch}_linux.tar.xz" "$sha" "$f"; rc=$?
  case $rc in
    0) mkdir -p "$HOME/.local/bin"; tar -C "$d" -xf "$f" && install -m755 "$d/upx-${ver}-${arch}_linux/upx" "$HOME/.local/bin/upx" || warn "upx: extract/install failed (optional)." ;;
    1) warn "upx: download failed — skipping (optional)." ;;
    *) : ;;  # mismatch already reported by fetch_verified (fail closed)
  esac
  rm -rf "$d" 2>/dev/null || true; return 0
}

# Go toolchain — user-local tarball into ~/.local/go (no root). Non-fatal on failure (the Go stack's
# gate needs it, but `ace install` proceeds). Only wipes an existing ~/.local/go AFTER a verified DL.
install_go_verified() {
  local ver="${GO_VERSION:-go1.26.5}" arch sha rc d f
  case "$(uname -m)" in
    x86_64)        arch=amd64; sha=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053 ;;
    aarch64|arm64) arch=arm64; sha=fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49 ;;
    *) warn "go: unsupported arch $(uname -m) — skipping."; return 0 ;;
  esac
  [ "$ver" = go1.26.5 ] || sha="${GO_SHA256:-}"
  [ -n "$sha" ] || { warn "go: no pinned sha256 for $ver — set GO_SHA256 to install it (skipping)."; return 0; }
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would install Go $ver ($arch), sha256-verified."; return 0; }
  d="$(mktemp -d)"; f="$d/go.tar.gz"
  fetch_verified "https://go.dev/dl/${ver}.linux-${arch}.tar.gz" "$sha" "$f"; rc=$?
  case $rc in
    0) mkdir -p "$HOME/.local" && rm -rf "$HOME/.local/go" && tar -C "$HOME/.local" -xzf "$f" || warn "go: extract failed." ;;
    1) warn "go: download failed — skipping (Go stack gate unavailable until next run)." ;;
    *) : ;;  # mismatch already reported by fetch_verified (fail closed)
  esac
  rm -rf "$d" 2>/dev/null || true; return 0
}

# gh (GitHub CLI) — user-local tarball. Returns 0 on success, 1 on any failure (caller decides).
install_gh_verified() {
  local ver="${GH_VERSION:-2.96.0}" arch sha rc d f
  case "$(uname -m)" in
    x86_64)        arch=amd64; sha=83d5c2ccad5498f58bf6368acb1ab32588cf43ab3a4b1c301bf36328b1c8bd60 ;;
    aarch64|arm64) arch=arm64; sha=06f86ec7103d41993b76cd78072f43595c34aaa56506d971d9860e67140bf909 ;;
    *) err "gh: unsupported arch $(uname -m)."; return 1 ;;
  esac
  [ "$ver" = 2.96.0 ] || sha="${GH_SHA256:-}"
  [ -n "$sha" ] || { err "gh: no pinned sha256 for $ver — set GH_SHA256 to install it."; return 1; }
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would install gh $ver ($arch), sha256-verified."; return 0; }
  d="$(mktemp -d)"; f="$d/gh.tar.gz"
  info "Downloading gh ${ver} (user-local, ${arch}; sha256-verified)…"
  fetch_verified "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_${arch}.tar.gz" "$sha" "$f"; rc=$?
  if [ "$rc" -eq 0 ]; then
    mkdir -p "$HOME/.local/bin"
    tar -xzf "$f" -C "$d" && install -m755 "$d/gh_${ver}_linux_${arch}/bin/gh" "$HOME/.local/bin/gh" || rc=1
  fi
  rm -rf "$d" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------- host tools
install_host_tools() {
  step "Host tooling (all user-local, no root)"
  info "Distro: ${ACE_DISTRO_PRETTY} (${ACE_DISTRO}, pkg=${ACE_PKG:-n/a})"

  # VENDOR INSTALL SCRIPTS (fnm · uv · bun · opencode) — these four deliberately run upstream's
  # `curl … | bash` installer. Their CONTENTS (and therefore their hash) rotate on every upstream
  # release, so pinning the SCRIPT's sha256 would brick `ace install` whenever upstream re-cuts it;
  # converting them to pinned release BINARIES (like jq/gh/upx/go below) is a separate, larger change.
  # They are ALLOWLISTED (with a per-entry reason + follow-up) in tests/supply-chain-allowlist.txt and
  # enforced by tests/supply-chain.sh — adding a NEW `curl | bash` fails CI until it is pinned or listed.
  # FOLLOW-UP (#supply-chain): replace each with fetch_verified over a pinned release binary.
  if have fnm; then ok "fnm present ($(ver fnm))"
  else
    info "Installing fnm (Node manager)…"
    run_sh 'curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$HOME/.local/share/fnm" --skip-shell'
  fi
  export PATH="$HOME/.local/share/fnm:$PATH"
  if have fnm; then
    eval "$(fnm env --log-level quiet --shell bash 2>/dev/null)" 2>/dev/null || true
    have node || { info "Installing Node LTS…"; run fnm install --lts && run fnm default lts-latest; }
    eval "$(fnm env --log-level quiet --shell bash 2>/dev/null)" 2>/dev/null || true
    have node && ok "Node $(node -v 2>/dev/null)"
    have corepack && run_sh 'corepack enable >/dev/null 2>&1 || true'
  fi

  if have uv; then ok "uv present ($(ver uv))"
  else info "Installing uv (provides uvx for Serena)…"; run_sh 'curl -LsSf https://astral.sh/uv/install.sh | sh'; fi

  if have bun; then ok "bun present ($(ver bun))"
  else info "Installing bun (OpenCode plugin deps)…"; run_sh 'curl -fsSL https://bun.sh/install | bash'; fi

  if have jq; then ok "jq present ($(ver jq))"
  else
    info "Installing jq v${JQ_VERSION:-1.8.2} (pinned; sha256-verified; user-local static binary)…"
    install_jq_verified
    have jq && ok "jq $(ver jq) (sha256-verified)"
  fi

  if have opencode; then ok "opencode present ($(ver opencode))"
  else info "Installing OpenCode…"; run_sh 'XDG_BIN_DIR="$HOME/.local/bin" curl -fsSL https://opencode.ai/install | bash'; fi

  # GitNexus (code-intelligence MCP) — install GLOBALLY, not via npx@latest. npx re-resolves @latest on
  # every spawn (slow + npm-11-flaky, #1939), which races opencode's first tool call → "MCP server not
  # connected". A global binary starts deterministically; the MCP command falls back to npx if it's absent.
  if have gitnexus; then ok "gitnexus present ($(ver gitnexus 2>/dev/null))"
  elif have npm; then info "Installing gitnexus (code-intelligence MCP)…"; run_sh 'npm i -g gitnexus >/dev/null 2>&1 || true'; fi

  # Go toolchain (user-local tarball into ~/.local/go, no root) + go-installed linters — for the Go stack's gate.
  if have go; then ok "Go present ($(go version 2>/dev/null | awk '{print $3}'))"
  else
    info "Installing Go ${GO_VERSION:-go1.26.5} (pinned; sha256-verified; user-local tarball into ~/.local/go)…"
    install_go_verified
  fi
  export PATH="$HOME/.local/go/bin:$HOME/go/bin:$PATH"
  if have go; then
    ok "Go $(go version 2>/dev/null | awk '{print $3}')"
    have staticcheck || { info "Installing staticcheck (Go linter)…"; run_sh 'go install honnef.co/go/tools/cmd/staticcheck@latest >/dev/null 2>&1 || true'; }
    have govulncheck || { info "Installing govulncheck (Go vuln scanner)…"; run_sh 'go install golang.org/x/vuln/cmd/govulncheck@latest >/dev/null 2>&1 || true'; }
    have gopls || { info "Installing gopls (official Go MCP server + LSP)…"; run_sh 'go install golang.org/x/tools/gopls@latest >/dev/null 2>&1 || true'; }
    have garble || { info "Installing garble (Go obfuscator for 'strong' hardened release builds)…"; run_sh 'go install mvdan.cc/garble@latest >/dev/null 2>&1 || true'; }
    have upx || { info "Installing UPX v${UPX_VERSION:-5.2.0} (pinned; sha256-verified; optional release packer; user-local)…"; install_upx_verified; }
  fi

  # Mergiraf (structural/AST 3-way merge) — deterministic FRONT-END to the LLM conflict_resolver.
  # User-local prebuilt STATIC (musl) binary → ~/.local/bin (never rpm-ostree; matches jq/upx). OPTIONAL:
  # every merge path feature-detects `mergiraf` and falls back to git + conflict_resolver when absent.
  # SUPPLY CHAIN: the release is PINNED and its tarball is sha256-verified before install. A mismatch
  # FAILS CLOSED (refuses to install) rather than executing an unverified binary; a download failure is
  # non-fatal (the driver already falls open). Never resolves "latest" — that is an unpinned download.
  # To move the pin deliberately, set MERGIRAF_VERSION together with a matching MERGIRAF_SHA256.
  if have mergiraf; then ok "mergiraf present ($(ver mergiraf 2>/dev/null))"
  else
    info "Installing Mergiraf v0.17.0 (pinned; sha256-verified; user-local static binary)…"
    run_sh 'mv="${MERGIRAF_VERSION:-v0.17.0}"; case "$(uname -m)" in x86_64) ma=x86_64; msum=e52f375111dba2030686e910a69536390b8f8071313ccbd39d6cc63fbf23e764 ;; aarch64|arm64) ma=aarch64; msum=ff60601cc5a7e987573685413230ced2d83b8e9f171658347de428c7edaf963b ;; *) ma="" ;; esac; [ -n "$ma" ] || { echo "mergiraf: unsupported arch $(uname -m) - skipping (optional)"; exit 0; }; [ "$mv" = v0.17.0 ] || msum="${MERGIRAF_SHA256:-}"; [ -n "$msum" ] || { echo "mergiraf: no pinned sha256 for $mv - set MERGIRAF_SHA256 to install it (skipping)"; exit 0; }; f=/tmp/ace-mergiraf.tgz; d=/tmp/ace-mergiraf.d; mkdir -p "$HOME/.local/bin" "$d"; curl -fsSL "https://codeberg.org/mergiraf/mergiraf/releases/download/${mv}/mergiraf_${ma}-unknown-linux-musl.tar.gz" -o "$f" || { echo "mergiraf: download failed - skipping (optional)"; rm -rf "$f" "$d"; exit 0; }; printf "%s  %s\n" "$msum" "$f" | sha256sum -c - >/dev/null 2>&1 || { echo "mergiraf: SHA256 MISMATCH for $mv ($ma) - refusing to install"; rm -rf "$f" "$d"; exit 0; }; tar -C "$d" -xzf "$f" && mbin="$(find "$d" -type f -name mergiraf | head -1)" && [ -n "$mbin" ] && install -m755 "$mbin" "$HOME/.local/bin/mergiraf"; rm -rf "$f" "$d" 2>/dev/null || true'
    have mergiraf && ok "Mergiraf $(ver mergiraf 2>/dev/null) (sha256-verified)" || info "Mergiraf not installed (optional) — swarm merges fall back to git + conflict_resolver."
  fi

  ensure_serena_quiet
  ensure_container_engine
  ensure_visual_extras
  ensure_render_tools
  write_host_bashrc_block
  activate_paths
  ok "Host tooling done."
  note_new_shell
}

# Serena opens its web dashboard in a browser tab on EVERY MCP launch by default; since each
# opencode run starts Serena fresh, an overnight autorun spawns dozens of tabs. Disable the
# auto-open (the dashboard stays reachable at http://localhost:24282). Idempotent; works whether
# or not Serena has created its config yet.
ensure_serena_quiet() {
  local cfg="$HOME/.serena/serena_config.yml"
  mkdir -p "$HOME/.serena"
  if [ -f "$cfg" ]; then
    if grep -q '^web_dashboard_open_on_launch:' "$cfg"; then
      sed -i 's/^web_dashboard_open_on_launch:.*/web_dashboard_open_on_launch: false/' "$cfg"
    else
      printf '\nweb_dashboard_open_on_launch: false\n' >> "$cfg"
    fi
  else
    printf '# created by ace — keep Serena from opening a browser tab on every MCP launch\nweb_dashboard_open_on_launch: false\n' > "$cfg"
  fi
  ok "Serena: dashboard won't auto-open a browser (web_dashboard_open_on_launch: false)."
}

ensure_container_engine() {
  local eng; eng="$(container_engine)"
  if [ -n "$eng" ]; then ok "Container engine: $eng ($($eng --version 2>/dev/null | head -1))"; return; fi
  warn "No container engine (podman/docker) found — ci.sh's parity build needs one."
  case "$ACE_DISTRO" in
    arch)
      if confirm "Install podman now via 'sudo pacman -S --needed podman'?" Y; then
        run sudo pacman -S --needed podman
      else warn "Skipped. Install podman later for the container gate."; fi ;;
    fedora-atomic)
      warn "Fedora Atomic ships podman by default; it appears missing. Try a reboot, or:"
      say  "    rpm-ostree install podman   ${C_GREY}(layers + needs reboot — last resort)${C_RESET}" ;;
    *)
      say "Install podman or docker with your package manager, then re-run doctor." ;;
  esac
}

# ensure_visual_extras — OPTIONAL terminal eye-candy, never required: chafa (renders the lib/art sprite
# via kitty/sixel/half-blocks) + figlet/toilet (gothic ACE wordmark). ACE auto-detects and uses them only
# when present; the banner degrades to a truecolor half-block emblem + block wordmark otherwise. Offer is
# confirm-gated (default no) and a no-op on immutable hosts (layering needs a reboot). ACE_VISUAL_EXTRAS=0 skips.
ensure_visual_extras() {
  [ "${ACE_VISUAL_EXTRAS:-1}" = 0 ] && return 0
  local missing=() t; for t in chafa figlet toilet; do have "$t" || missing+=("$t"); done
  if [ ${#missing[@]} -eq 0 ]; then ok "Visual extras: chafa + figlet + toilet present."; return 0; fi
  info "Optional visual extras missing: ${missing[*]} — ACE works without them (half-block emblem + block wordmark)."
  case "$ACE_DISTRO" in
    arch)   confirm "Install ${missing[*]} via 'sudo pacman -S --needed ${missing[*]}'?" N \
              && run sudo pacman -S --needed "${missing[@]}" || say "    ${C_GREY}later: sudo pacman -S --needed ${missing[*]}${C_RESET}" ;;
    fedora) confirm "Install ${missing[*]} via 'sudo dnf install ${missing[*]}'?" N \
              && run sudo dnf install -y "${missing[@]}" || say "    ${C_GREY}later: sudo dnf install ${missing[*]}${C_RESET}" ;;
    debian) confirm "Install ${missing[*]} via 'sudo apt-get install ${missing[*]}'?" N \
              && run sudo apt-get install -y "${missing[@]}" || say "    ${C_GREY}later: sudo apt-get install ${missing[*]}${C_RESET}" ;;
    fedora-atomic) say "    ${C_GREY}immutable host — layer when convenient: rpm-ostree install ${missing[*]} (needs reboot), or use a toolbox.${C_RESET}" ;;
    *)      say "    ${C_GREY}install with your package manager: ${missing[*]}${C_RESET}" ;;
  esac
}

# ensure_render_tools — terminal→image renderers for `ace snap` (the Signal screenshot feature):
# freeze (Go binary) + ansitoimg (uv tool). Both, user-local. Optional — `ace snap` errors clearly if
# neither is present. ACE_RENDER_TOOLS=0 skips.
ensure_render_tools() {
  [ "${ACE_RENDER_TOOLS:-1}" = 0 ] && return 0
  if have freeze; then ok "Snapshot renderer: freeze present."
  elif have go; then info "Installing freeze (terminal→image for Signal snapshots)…"
    run_sh 'go install github.com/charmbracelet/freeze@latest >/dev/null 2>&1 || true'
    have freeze && ok "freeze installed." || warn "freeze install failed (go install) — ansitoimg used if present."
  else warn "freeze needs Go (missing) — skipping; ansitoimg used if present."; fi
  if have ansitoimg; then ok "Snapshot renderer: ansitoimg present."
  elif have uv; then info "Installing ansitoimg (uv tool)…"
    run_sh 'uv tool install ansitoimg >/dev/null 2>&1 || true'
    have ansitoimg && ok "ansitoimg installed." || warn "ansitoimg install failed (uv tool install)."
  else warn "ansitoimg needs uv (missing) — skipping."; fi
}

write_host_bashrc_block() {
  info "Writing managed block to ~/.bashrc (PATH, fnm, bun, opencode, keys)…"
  write_bashrc_block "$(cat <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
# Node via fnm
export FNM_LOGLEVEL=quiet
export PATH="$HOME/.local/share/fnm:$PATH"
command -v fnm >/dev/null 2>&1 && eval "$(fnm env --use-on-cd --log-level quiet --shell bash)"
# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
# opencode
export PATH="$HOME/.opencode/bin:$PATH"
# .NET (if installed)
[ -d "$HOME/.dotnet" ] && { export DOTNET_ROOT="$HOME/.dotnet"; export PATH="$HOME/.dotnet:$PATH"; }
# ACE secrets (DeepSeek / Context7)
[ -f "$HOME/.config/ace/secrets.env" ] && { set -a; . "$HOME/.config/ace/secrets.env"; set +a; }
EOF
)"
}

# ---------------------------------------------------------------- API keys
validate_deepseek_key() {
  local key="$1"
  have curl || { warn "curl missing — skipping key validation."; return 0; }
  [ "$ACE_DRY_RUN" = 1 ] && return 0
  local out; out="$(curl -s --max-time 20 https://api.deepseek.com/models -H "Authorization: Bearer $key" 2>/dev/null)"
  printf '%s' "$out" | grep -q 'deepseek'
}

configure_keys() {
  step "API keys (DeepSeek + Context7)"
  config_init
  local ds ctx
  if _noninteractive; then
    # headless: keys come from env (DEEPSEEK_API_KEY / CONTEXT7_API_KEY), profile/brain from ACE_PROFILE / ACE_BRAIN
    ds="${DEEPSEEK_API_KEY:-}"; ctx="${CONTEXT7_API_KEY:-}"
    if [ -n "$ds" ]; then
      if validate_deepseek_key "$ds"; then ok "DeepSeek key valid (v4 models reachable)."; else err "DeepSeek key REJECTED by api.deepseek.com."; fi
    else warn "DEEPSEEK_API_KEY not provided — leaving any existing key untouched."; fi
  else
    while true; do
      ask_secret "DeepSeek API key (sk-…)"; ds="$ASK_REPLY"
      [ -z "$ds" ] && { warn "DeepSeek key is required for the agents."; confirm "Skip for now?" N && { ds=""; break; }; continue; }
      info "Validating against api.deepseek.com…"
      if validate_deepseek_key "$ds"; then ok "DeepSeek key valid (v4 models reachable)."; break
      else err "Key rejected by DeepSeek. Re-enter."; fi
    done
    ask_secret "Context7 API key (optional, Enter to skip)"; ctx="$ASK_REPLY"
  fi

  if [ "$ACE_DRY_RUN" = 1 ]; then info "[dry-run] would update $ACE_SECRETS (chmod 600)"
  elif [ -n "$ds" ] || [ -n "$ctx" ]; then
    # MERGE per key (secret_set), never truncate the whole file — re-running `ace keys` and leaving
    # Context7 blank must NOT wipe a previously-saved CONTEXT7_API_KEY (and vice-versa).
    [ -n "$ds" ]  && secret_set DEEPSEEK_API_KEY "$ds"
    [ -n "$ctx" ] && secret_set CONTEXT7_API_KEY "$ctx"
    ok "Saved keys to $ACE_SECRETS (chmod 600, sourced from ~/.bashrc)."
  else info "No new key provided — kept existing $ACE_SECRETS."
  fi
  activate_paths

  if _noninteractive; then
    [ -n "${ACE_PROFILE:-}" ] && config_set MODEL_PROFILE "$ACE_PROFILE"
  else
    menu "Model profile (DeepSeek)" \
      "Max (recommended)::all workers think 'max' incl. the 4 critics — most thorough, deepest" \
      "High::all agents 'high' reasoning (faster, lighter)" \
      "Balanced::pro for build, flash verifier (cheapest checks)"
    case "$MENU_CHOICE" in
      1) config_set MODEL_PROFILE max ;;
      2) config_set MODEL_PROFILE high ;;
      3) config_set MODEL_PROFILE balanced ;;
    esac
  fi
  ok "Profile: $(config_get MODEL_PROFILE)"

  if _noninteractive; then
    [ -n "${ACE_BRAIN:-}" ] && config_set ORCH_PROVIDER "$ACE_BRAIN"
  else
    menu "Orchestrator / planner brain" \
      "Claude Opus (default · subscription)::deepest planning — ACE's default overseer; needs a Claude Pro/Max plan" \
      "Claude Sonnet (subscription)::strong planning, lighter on Claude quota — best for long autoruns" \
      "OpenAI GPT-5 (subscription or API)::strong planning on OpenAI — ChatGPT login or OPENAI_API_KEY" \
      "DeepSeek (no subscription)::everything on DeepSeek — works without any Claude/OpenAI plan"
    case "$MENU_CHOICE" in
      1) config_set ORCH_PROVIDER opus ;;
      2) config_set ORCH_PROVIDER sonnet ;;
      3) config_set ORCH_PROVIDER gpt ;;
      4) config_set ORCH_PROVIDER deepseek ;;
    esac
  fi
  case "$(config_get ORCH_PROVIDER)" in
    opus|sonnet|"")   # "" = unset → the default overseer (Claude Opus), which still needs Anthropic auth
      local _b; _b="$(config_get ORCH_PROVIDER)"; _b="${_b:-opus (default)}"
      if opencode auth list 2>/dev/null | grep -qi anthropic; then
        ok "Orchestrator → Claude ($_b); Anthropic is authed."
      else
        warn "Orchestrator → Claude ($_b): run 'opencode auth login' (Anthropic → Claude Pro/Max), then 'ace opencode'. Prefer no subscription? Pick DeepSeek in 'ace keys'."
      fi ;;
    gpt)
      if opencode auth list 2>/dev/null | grep -qi openai; then
        ok "Orchestrator → OpenAI (gpt-5); OpenAI is authed."
      else
        warn "Orchestrator → OpenAI (gpt-5): run 'opencode auth login' (OpenAI — ChatGPT subscription or API key), then 'ace opencode'."
      fi ;;
  esac
}

profile_values() {  # echoes "EFF_MAIN EFF_VERIFIER VERIFIER_MODEL"  (default = max)
  case "$(config_get MODEL_PROFILE)" in
    high)     echo "high high deepseek-v4-pro" ;;
    balanced) echo "high high deepseek-v4-flash" ;;
    max|*)    echo "max max deepseek-v4-pro" ;;
  esac
}

# ---------------------------------------------------------------- per-agent models + provider auth
ACE_AGENTS="orchestrator implementer test_engineer verifier reviewer ux_reviewer standards_keeper alignment_reviewer conflict_resolver"

# effort tier per agent (checkers use the verifier tier)
_agent_eff() { case "$1" in verifier|standards_keeper|alignment_reviewer) printf '%s' "${EFF_VERIFY:-max}" ;; *) printf '%s' "${EFF_MAIN:-max}" ;; esac; }
# today's default model per agent — orchestrator from ORCH_MODEL; checkers = verifier model; rest = pro
_agent_default_model() {
  case "$1" in
    orchestrator) printf '%s' "$(orch_model)" ;;   # MODEL_orchestrator override › ORCH_PROVIDER alias › deepseek (don't depend on a caller-set ORCH_MODEL local — _used_providers calls this outside write_opencode_config)
    verifier|standards_keeper|alignment_reviewer) printf 'deepseek/%s' "${VERIFIER_MODEL:-deepseek-v4-pro}" ;;
    *) printf 'deepseek/deepseek-v4-pro' ;;
  esac
}
# resolved model — an explicit MODEL_<agent> config overrides the default
_agent_model() { local m; m="$(config_get "MODEL_$1" 2>/dev/null)"; [ -n "$m" ] && printf '%s' "$m" || _agent_default_model "$1"; }
# provider-appropriate options JSON for a model + effort tier
_model_opts() {  # <provider/model> <eff>
  case "$1" in
    deepseek/*)  printf '{ "reasoningEffort": "%s", "thinking": { "type": "enabled" } }' "$2" ;;
    anthropic/*) printf '{ "thinking": { "type": "enabled" } }' ;;
    openai/*)    printf '{ "reasoningEffort": "%s" }' "$2" ;;
    *)           printf '{ }' ;;
  esac
}
# distinct providers across all agents' resolved models
_used_providers() { local a; for a in $ACE_AGENTS; do _agent_model "$a"; echo; done | sed 's#/.*##' | sort -u; }

# Install the opencode plugins the current config needs (yaml-hooks always; anthropic-auth if any
# Claude model). This is the install half ACE used to only WARN about.
ensure_opencode_plugins() {
  local cfgdir="$HOME/.config/opencode" deps='"opencode-yaml-hooks": "latest"'
  _used_providers | grep -qx anthropic && deps="$deps, \"@ex-machina/opencode-anthropic-auth\": \"latest\""
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would write $cfgdir/package.json + bun install ($deps)"; return 0; }
  mkdir -p "$cfgdir"
  printf '{ "name": "ace-opencode", "private": true, "dependencies": { %s } }\n' "$deps" > "$cfgdir/package.json"
  if have bun; then spin "opencode plugins (bun install)" bash -c "cd '$cfgdir' && bun install" || warn "bun install failed — run: cd $cfgdir && bun install"
  elif have npm; then spin "opencode plugins (npm install)" bash -c "cd '$cfgdir' && npm install" || warn "npm install failed — run: cd $cfgdir && npm install"
  else warn "no bun/npm on PATH — install plugins manually: cd $cfgdir && bun install"; fi
}

# Drive the SAME login flow that already works on this account: opencode auth login -p <provider>,
# guiding the token paste. Subscription is the default; ACE never stores the token (opencode owns it).
ensure_provider_auth() {  # <provider>  e.g. anthropic | openai
  local p="$1"
  command -v opencode >/dev/null 2>&1 || { warn "opencode not installed — can't log in to $p (run: ace install)."; return 1; }
  if opencode auth list 2>/dev/null | grep -qi "$p"; then ok "$p: already authenticated."; return 0; fi
  info "$p not authenticated — running your usual flow: 'opencode auth login -p $p'."
  info "  → it prints a URL · authorize in the browser · copy the token · paste it back at the prompt."
  info "  (subscription/OAuth = bills your plan, not an API key; $p discourages third-party clients — wiring as you asked.)"
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would run: opencode auth login -p $p"; return 0; }
  confirm "Run 'opencode auth login -p $p' now (pick the subscription/OAuth option)?" Y || { warn "skipped — later: opencode auth login -p $p"; return 1; }
  opencode auth login -p "$p" || warn "login didn't complete — re-run: opencode auth login -p $p"
  opencode auth list 2>/dev/null | grep -qi "$p" && ok "$p authenticated." || warn "$p still not authed — re-run the login."
}

# ---------------------------------------------------------------- opencode config
write_opencode_config() {
  step "OpenCode config (9 agents: orchestrator/implementer/test_engineer/verifier/reviewer/ux_reviewer/standards_keeper/alignment_reviewer/conflict_resolver + MCP)"
  local cfgdir="$HOME/.config/opencode"
  run mkdir -p "$cfgdir"
  read -r EFF_MAIN EFF_VERIFY VERIFIER_MODEL <<<"$(profile_values)"
  # orchestrator/planner model — Claude Opus by default (your Claude sub); or Sonnet/GPT-5/DeepSeek
  local ORCH_MODEL ORCH_OPTS MAXCTX
  # compaction threshold ≈ overseer's context window − its max output − margin, so a long run
  # auto-compacts before the model's REAL ceiling. All current overseers are 1M-context (verified:
  # Opus 4.8 / Sonnet 4.6 = 1,000,000 in; DeepSeek V4 = 1,048,576). Smaller-window models would set a lower cap.
  # Resolve the EFFECTIVE model (MODEL_orchestrator override › ORCH_PROVIDER alias › deepseek), then derive
  # opts + compaction cap FROM THAT MODEL — so a Claude overseer set via the per-agent MODEL_orchestrator
  # (presets) gets the right window, not DeepSeek's. (The per-agent jq override below stamps the same model.)
  ORCH_MODEL="$(orch_model)"
  case "$ORCH_MODEL" in
    anthropic/claude-opus-*)   ORCH_OPTS='"thinking": { "type": "enabled" }'; MAXCTX=820000 ;;   # 1M ctx − 128K out
    anthropic/claude-sonnet-*) ORCH_OPTS='"thinking": { "type": "enabled" }'; MAXCTX=900000 ;;   # 1M ctx − 64K out
    anthropic/*)               ORCH_OPTS='"thinking": { "type": "enabled" }'; MAXCTX=820000 ;;   # other Claude: safe 1M − margin
    openai/*)                  ORCH_OPTS="\"reasoningEffort\": \"$EFF_MAIN\""; MAXCTX=360000 ;;   # gpt-5 ~400K ctx − margin
    deepseek/*)                ORCH_OPTS="\"reasoningEffort\": \"$EFF_MAIN\", \"thinking\": { \"type\": \"enabled\" }"; MAXCTX=840000 ;;  # 1.048M ctx − 196K out
    *)                         ORCH_OPTS="\"reasoningEffort\": \"$EFF_MAIN\", \"thinking\": { \"type\": \"enabled\" }"; MAXCTX=820000 ;;  # unknown: conservative
  esac
  # Plugins from the union of providers ANY agent uses: yaml-hooks always; anthropic-auth registers the
  # Pro/Max OAuth subscription provider (without it anthropic/* are NotFound). openai is native to opencode.
  local PLUGINS='"opencode-yaml-hooks"' _provs; _provs="$(_used_providers)"
  printf '%s' "$_provs" | grep -qx anthropic && PLUGINS='"opencode-yaml-hooks", "@ex-machina/opencode-anthropic-auth"'
  # OpenAI provider block — only in explicit API-key mode (subscription uses opencode's native openai + login).
  local OPENAI_PROVIDER=''
  if printf '%s' "$_provs" | grep -qx openai && [ "$(config_get AUTH_openai)" = api ]; then
    OPENAI_PROVIDER=', "openai": { "npm": "@ai-sdk/openai", "name": "OpenAI", "options": { "apiKey": "{env:OPENAI_API_KEY}" } }'
  fi

  if [ "$ACE_DRY_RUN" = 1 ]; then
    info "[dry-run] would write $cfgdir/opencode.json (eff=$EFF_MAIN, verifier=$VERIFIER_MODEL) + AGENTS.md"; return
  fi

  cat > "$cfgdir/opencode.json" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": [__PLUGINS__],
  "provider": {
    "deepseek": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "DeepSeek",
      "options": { "baseURL": "https://api.deepseek.com", "apiKey": "{env:DEEPSEEK_API_KEY}" },
      "models": {
        "deepseek-v4-pro":   { "name": "DeepSeek V4 Pro",   "limit": { "context": 1048576, "output": 196608 }, "options": { "reasoningEffort": "max", "thinking": { "type": "enabled" } } },
        "deepseek-v4-flash": { "name": "DeepSeek V4 Flash", "limit": { "context": 1048576, "output": 196608 }, "options": { "reasoningEffort": "high", "thinking": { "type": "enabled" } } }
      }
    }__OPENAI_PROVIDER__
  },
  "model": "deepseek/deepseek-v4-pro",
  "small_model": "deepseek/deepseek-v4-flash",
  "default_agent": "orchestrator",
  "compaction": { "auto": true, "maxContext": __MAXCTX__ },
  "agent": {
    "orchestrator": {
      "description": "Plans into small tasks and drives implement->verify->review(4 critics)->fix->commit->PR. Writes no code.",
      "mode": "primary",
      "model": "__ORCH_MODEL__",
      "permission": { "edit": "deny", "write": "deny", "doom_loop": "allow", "bash": { "*": "deny", "git": "allow", "git *": "allow", "gh": "allow", "gh *": "allow", "echo": "allow", "echo *": "allow", "cat*": "allow", "ls": "allow", "ls *": "allow", "sed*": "allow", "awk*": "allow", "find*": "allow", "test*": "allow", "[ *": "allow", "true": "allow", "sleep *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow", "grep*": "allow", "sort*": "allow" } },
      "options": { __ORCH_OPTS__ },
      "prompt": "You are the orchestrator. You NEVER write code — you plan, delegate, and drive the loop to a HIGH-QUALITY, COMPLETE result. Assume the end user is a highly advanced professional: hold every step to staff/principal-engineer standard. 'It works' and 'good enough' are failures.\n\nTOOLS — you can run git, gh, read-only inspection (cat · ls · sed · awk · find) and output filters (echo · head · tail · wc · grep · sort), INCLUDING heredocs like \"$(cat <<EOF … EOF)\" for gh/git PR + commit bodies. DENIED (don't try — each wastes a turn): direct file WRITES, mkdir, and './ci.sh'. Delegate ALL file writes (specs included) and ./ci.sh runs to the implementer/verifier. Navigate code via GitNexus (gitnexus_query/gitnexus_context/gitnexus_impact) + Serena — do NOT re-read whole files or shell out to find things. The GitNexus index hosts MULTIPLE repos, so pass `repo: \"<this repo's name>\"` on EVERY gitnexus_* call (it's in .opencode/project-facts.md) or it errors `Multiple repositories indexed`. The ACE/loop CLI and its config live OUTSIDE this repo and can't be edited here — own any needed fix in-repo. Read .opencode/lessons.md and .opencode/project-facts.md (if present) before planning, so you don't re-derive what's already known. ALSO read .opencode/profile.yaml + ARCHITECTURE.md (if present) — the project's MISSION, values, audience, throughput target, philosophy, and delivery policy — and ROUTE every task to SERVE that mission and audience; flag and de-prioritize off-mission work.\n\nFOR EACH REQUEST:\n0. ALREADY DONE? Before planning, check whether the item is already implemented (GitNexus/grep for the artifact/symbol; does its acceptance already hold?). If yes, VERIFY-ONLY and mark it done in ROADMAP/OBJECTIVES — do NOT re-implement. Also check for EXISTING in-flight work before building from scratch: a prior interrupted session may have left it on a local branch (scan `git branch -a` + `git log --all --oneline` grepping the slug/keywords) or in an open PR (`gh pr list --search`) — if found and it covers the acceptance, the remaining work is usually just rebase/push/PR, NOT a fresh re-implementation; finish THAT instead of duplicating it.\n1. PLAN. Decompose into SMALL independently-testable tasks (smaller than feels necessary). For each, write a spec to .opencode/specs/<slug>.md: apply the 3 WHYS (AGENTS.md) to reach the ROOT need, then capture goal (root need), exact SCOPE (in/out), acceptance criteria derived from the root need — INCLUDING the Production & security bar criteria that apply to this surface (authz default-deny, input validation, idempotency + audit for money/auth/order paths, no destructive DB ops, no leaked internals) — edge cases (incl. abuse/security cases), integration points, and (if user-facing) UX/states. Run GitNexus impact first. CONFLICT-AWARE BATCHING: before parallelizing, compute each candidate task's FOOTPRINT = its predicted edit set ∪ its gitnexus_impact upstream+downstream closure (repo-scoped). Two tasks may run in parallel worktrees ONLY if their footprints are DISJOINT. Tasks whose footprints intersect MUST be serialized into the same worktree's queue. Any task that touches a HUB file (high in/out-degree in GitNexus — barrels, registries, DI containers, migration sequences, shared schema) is assigned to a SINGLE integration worker and never parallelized with another hub-touching task. Prefer VERTICAL slices (one feature end-to-end, its own files) over HORIZONTAL layers (all-controllers vs all-models), because vertical slices minimise cross-worker file sharing. State the batch plan (which tasks run parallel, which serialize, and why) in ROADMAP.md before dispatch. VALUE ROUTING: prefer work that advances the North Star (user-facing / revenue / decision-quality); do NOT chain more than 2 consecutive infra/meta/self-tooling tasks — after two, pick a user-facing objective next.\n2. BRANCH: git checkout -b feat/<slug>\n3. PER TASK: (a) IMPLEMENT — delegate to implementer with the spec, impacted callers, DoD reminder. PARALLELIZE CAREFULLY (fan-out deadlocks are the #1 cause of a hung step): fan out AT MOST 2 parallel implementer subagents, and ONLY when they touch DISJOINT packages/directories — two subagents editing the SAME package (a shared compile unit / same language-server workspace) reliably deadlock and stall the whole step. For a review-FIX round (applying critic findings) use a SINGLE implementer with the consolidated findings — do NOT fan out fixes across one package. When an implementer runs long, that means DECOMPOSE the ROADMAP item (ship the first slice, append the rest as new items) — never respond by adding more parallel subagents. For HIGH-RISK or logic-dense tasks (the same gate that triggers the full critic panel — money/auth/orders/migrations, parsers/serializers, state machines, algorithms), after the implementer returns ALSO delegate to test_engineer to author INDEPENDENT adversarial tests (the right test TYPE per .opencode/STANDARDS.md, reusing the shared testutil/factories/fixtures/golden helpers); if it reports a production bug, send that back to the implementer to fix before proceeding. LOW-RISK tasks rely on the implementer's own tests (no test_engineer). (b) VERIFY — verifier runs ./ci.sh; on FAIL send exact output, re-verify, max 3 then STOP. (c) REVIEW — on PASS, first GATE BY RISK to scale ceremony to the change: LOW-RISK (docs/comments/config/copy, a test-only change, or a single non-security package with no auth / money / data-migration / secret surface) needs only the engineering reviewer's APPROVE — UNLESS the AUTO-ACCEPT SAFETY RAIL applies: if .opencode/profile.yaml has auto_merge: true (the loop self-merges with NO human gate) AND audience is oss-public/end-customer/enterprise, there is NO low-risk fast lane — treat EVERY change as HIGH-RISK (full panel + security hard gate). HIGH-RISK (auth/authz, money/orders/payments/webhooks, DB migrations or destructive ops, secrets, public APIs, or multi-package changes — when unsure, treat as HIGH) gets the full panel. Delegate IN PARALLEL to reviewer (engineering) and — for HIGH-RISK only — ALSO ux_reviewer (product/UX/scope) AND standards_keeper (stack best-practices vs .opencode/STANDARDS.md) AND alignment_reviewer (mission/values/audience/philosophy vs .opencode/profile.yaml + ARCHITECTURE.md), passing the spec. If standards_keeper reports STANDARDS.md missing/stale, have the implementer create/update .opencode/STANDARDS.md in THIS PR. If ANY critic returns CHANGES_REQUESTED, send the combined prioritized findings to the implementer — splitting INDEPENDENT findings across PARALLEL implementer subagents — then re-verify AND re-review. DIMINISHING-RETURNS CAP: after round 2, only [blocker]/[major] findings trigger another round — queue any remaining [minor] findings to ROADMAP.md and proceed (don't loop on minors). Up to 4 rounds. (d) COMMIT — only when verifier PASS and the required reviewer(s) APPROVE per the risk gate (all FOUR critics for HIGH-RISK; the engineering reviewer for LOW-RISK) — or the only remaining findings are [minor] and queued: git add -A && git commit -m 'type(area): summary'. (HIGH-RISK requires all four critics — reviewer + ux_reviewer + standards_keeper + alignment_reviewer — to APPROVE.)\n4. AFTER ALL TASKS: re-verify + re-review the whole branch; push (git push -u origin HEAD) and open a PR into main (gh pr create --base main --fill). NEVER merge your own PR. Update .opencode/memory/changelog.md; SCRIBE — append any durable lesson/decision/gotcha from this task to .opencode/lessons/<branch-slug>.md — your OWN per-branch shard, NEVER the shared .opencode/lessons.md (aggregated from lessons/*.md on main; see AGENTS.md Memory) — (one terse line each, deduped against what's there) so the loop never re-derives it; and if a critic gated this change (CHANGES_REQUESTED in any round), add one line naming the critic (reviewer/ux_reviewer/standards_keeper/alignment_reviewer) + the gist, so review-gating patterns stay visible; report tasks, branch, PR URL.\n\nCONFLICT RESOLUTION (when asked to resolve a PR that conflicts with main): merge origin/main into the branch and delegate the conflict resolution to the conflict_resolver subagent (it preserves BOTH sides' intent, never reverts to old, and escalates UNRESOLVABLE). Then REQUIRE the reviewer to confirm NO intended change was lost or reverted (APPROVE mandatory). If the reviewer flags any lost/reverted change, send it back to conflict_resolver. If conflict_resolver returns UNRESOLVABLE or the loss can't be fixed, run 'git merge --abort' and report UNRESOLVABLE — never force or fake it. Only when verifier PASS + reviewer APPROVE: commit the merge and push. Never merge the PR.\n\nRULES: keep messages short; never mark done without verifier PASS AND the risk-gated critics' APPROVE (HIGH-risk = all four critics: reviewer + ux_reviewer + standards_keeper + alignment_reviewer; LOW-risk = engineering reviewer; minor-only findings may be queued to ROADMAP); keep a change and the tests + any STANDARDS.md update that validate it in ONE PR — never open a test-only or standards-only PR split from the code it covers (that strands main self-contradictory / stale-RED); never accept shallow/partial work; never invent paths/symbols/APIs."
    },
    "implementer": {
      "description": "Senior implementation specialist. Executes ONE scoped task to production quality; self-reviews before returning.",
      "mode": "subagent",
      "model": "deepseek/deepseek-v4-pro",
      "options": { "reasoningEffort": "__EFF_MAIN__", "thinking": { "type": "enabled" } },
      "permission": { "edit": "allow", "write": "allow", "external_directory": "allow", "bash": { "*": "allow", "sudo": "deny", "sudo *": "deny", "rpm-ostree": "deny", "rpm-ostree *": "deny", "dnf install*": "deny", "dnf -y install*": "deny", "apt*": "deny", "apt-get*": "deny" } },
      "prompt": "You are a senior implementation specialist. ONE scoped task with a spec.\n\nSCOPE: Do exactly what the spec asks — no more. Do not improve, refactor, comment, or reformat unrelated code. Return edits as targeted changes to the specific lines/functions in scope; do not rewrite or re-emit whole files that only partially changed.\n\nCONTEXT PASS first (don't code blind): FIRST run ./scripts/graph-refresh.sh so the code map (GitNexus graph + docs/architecture.md) reflects the latest state from prior subtasks; read the spec + AGENTS.md; use gitnexus_impact (upstream+downstream) and context on the symbols you'll touch; read the actual callers/consumers and a neighboring module with Serena to match patterns and wire integration correctly; use Context7 for any third-party API.\n\nDEFINITION OF DONE (all required — partial work is failure):\n- COMPLETE: every acceptance criterion; NO stubs/TODO/FIXME/placeholders/'not implemented'/empty handlers/mocked core logic. If you can't finish, say so.\n- ROBUST: validate inputs; handle errors and the spec's edge cases; fail loudly.\n- INTEGRATED: update every caller/consumer the change affects; keep contracts and types coherent.\n- IN SCOPE: do exactly the spec — no scope creep, no unrelated edits, nothing in-scope omitted.\n- TESTED: happy + error + edge paths with tests that exercise the logic.\n- SECURE & PRODUCTION-READY (Production & security bar, AGENTS.md): authz default-deny + an authz-DENY test; validate inputs and parameterize queries; encode output; no secrets in code/logs/bundle; no destructive DB ops; money/order/auth paths are idempotent (replay test) and write an audit record; user-facing errors leak no internals. If a precondition can't be met, FAIL CLOSED.\n- CLEAN: follow conventions; correct placement (right layer/module); no dead code; document non-obvious public APIs.\n\nBEFORE RETURNING, run a PRE-MORTEM (AGENTS.md): name the 3 most-likely production failures of this change — include at least one SECURITY/abuse failure (authz bypass, injection, secret leak, non-idempotent retry, destructive migration, leaked internals) — and ensure each is handled and covered by a test. Then self-review your own diff against this list and fix gaps, and run ./scripts/graph-refresh.sh again so docs/architecture.md reflects your change (committed with your work). Return a concise summary: changes (files/symbols), how each criterion is met, integration touched, edge cases, tests added."
    },
    "test_engineer": {
      "description": "Adversarial test author. Invoked AFTER the implementer on HIGH-RISK / logic-dense tasks to design the test strategy and write INDEPENDENT tests that try to BREAK the code. Writes test files + shared helpers only — never production code.",
      "mode": "subagent",
      "model": "deepseek/deepseek-v4-pro",
      "options": { "reasoningEffort": "__EFF_MAIN__", "thinking": { "type": "enabled" } },
      "permission": { "edit": "allow", "write": "allow", "bash": { "*": "deny", "./ci.sh": "allow", "./ci.sh *": "allow", "go test*": "allow", "go tool cover*": "allow", "pnpm test*": "allow", "pnpm exec vitest*": "allow", "npm test*": "allow", "pytest*": "allow", "python -m pytest*": "allow", "git diff*": "allow", "git log*": "allow", "git show*": "allow", "git status*": "allow", "git branch*": "allow", "git rev-parse*": "allow", "echo": "allow", "echo *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow", "grep*": "allow" } },
      "prompt": "You are an adversarial test engineer. You are invoked AFTER the implementer, on a HIGH-RISK or logic-dense task, to author tests INDEPENDENTLY of the implementer's mental model — your job is to BREAK the code, not confirm it. You write ONLY test files + shared test helpers/fixtures/factories/golden data; you NEVER change production code. If a test reveals a bug, REPORT it for the implementer to fix — never paper over it by weakening the test or editing the code.\n\nCONTEXT PASS: read the spec (.opencode/specs/<slug>.md) + AGENTS.md + .opencode/STANDARDS.md (the TEST-TYPE-PER-SCENARIO table + the reuse conventions); read the FULL diff (git diff main...HEAD) and the changed files; use gitnexus_impact + Serena to see how the code is reached and what it integrates with; read the existing tests AND the shared test helpers (testutil / factories / fixtures / golden) so you REUSE them instead of re-rolling setup.\n\nDESIGN THE STRATEGY (don't just add a few asserts). For each changed unit pick the RIGHT test TYPE per the STANDARDS.md decision table: table-driven for branchy logic; property + fuzz for parsers/serializers/encoders/math (roundtrip + invariants); golden/snapshot for generated output; httptest + a contract check for handlers; integration against an ephemeral dependency for DB/wiring; replay/idempotency for money/order/webhook paths; an authz-DENY matrix (role x resource) for access control; race/contention for concurrency. For any endpoint that reads/writes a user-owned or tenant-scoped object, author a CROSS-USER test: user A creates a resource, user B (valid session, different account) attempts read/update/delete and MUST be denied; AND an UNAUTHENTICATED request MUST be denied. A route without both tests is not done. HERMETIC (mandatory): every test must be DETERMINISTIC and independent of wall-clock/timezone/order/network — NEVER bake a clock value into a golden or an assertion (no Date.now(), no bare new Date(), no absolute future dates as expiries/anchors); inject a FIXED clock/seed and freeze time. A time-drifting golden turns main RED for the WHOLE swarm on the next calendar day. Then WRITE them — reusing the shared helpers and EXTENDING them (a missing factory/fixture/fake-clock is yours to add, so the next task reuses it).\n\nATTACK: target boundaries (0 / 1 / empty / nil / max / overflow / unicode / duplicate / out-of-order), error and partial-failure paths, concurrency interleavings, and the abuse cases (injection, authz bypass, non-idempotent retry, resource exhaustion, leaked internals). Prefer a test that would FAIL on a plausible WRONG implementation over one that merely passes on this one — no trivial/tautological asserts, no asserting the code's current output without judging if it's CORRECT.\n\nMUTATION CHECK (required): after writing tests, introduce ONE plausible bug into the code under test — flip a boundary, negate a condition, or drop a guard — run the tests, and confirm at least one of your new tests FAILS on it; then revert the bug. In your report, name the specific wrong implementation each key test catches. If a test would still pass on an obviously broken version, rewrite it. RUN ./ci.sh and read the coverage summary; your added tests must be GREEN and should close the obvious coverage gaps on the CHANGED code (don't chase a blanket %). Tests ship in the SAME PR as the code — never a test-only PR/branch.\n\nRETURN: the test type you chose per unit + why; the files/helpers you added or reused; the boundary/abuse cases now covered; any coverage gap you closed; and — IMPORTANT — any production BUG or weakness your tests exposed that the implementer MUST fix, each with a concrete failing-case description. Never edit production code."
    },
    "verifier": {
      "description": "Read-only verifier. Runs ./ci.sh, re-reads the diff, confirms cited symbols exist, reports PASS/FAIL.",
      "mode": "subagent",
      "model": "deepseek/__VERIFIER_MODEL__",
      "options": { "reasoningEffort": "__EFF_VERIFY__", "thinking": { "type": "enabled" } },
      "permission": { "edit": "deny", "write": "deny", "task": "deny", "bash": { "*": "deny", "./ci.sh": "allow", "./ci.sh *": "allow", "git diff*": "allow", "git status*": "allow", "git log*": "allow", "git show*": "allow", "git branch": "allow", "git branch *": "allow", "git status": "allow", "git status *": "allow", "git rev-parse*": "allow", "git remote": "allow", "git remote *": "allow", "echo": "allow", "echo *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow" } },
      "prompt": "You are a verification agent. Verify, never change.\n1. Run ./ci.sh; capture exact command, output, exit code.\n2. Re-read the diff and changed files.\n3. For every symbol/path/API the implementer claims to have touched, look it up (Serena/GitNexus) and QUOTE the file:line where it is defined. If you cannot quote it, mark it UNVERIFIED — never assume it exists.\n4. PRODUCTION & SECURITY SCAN of the diff (FAIL with file:line on any hit): a secret/credential/token committed; a destructive DB op in a prod path (--accept-data-loss / db push / unguarded drop/truncate); a new or changed endpoint/mutation with no authz check; external input used unvalidated or concatenated into a query/command; a money/order/webhook path lacking an idempotency guard or audit write; a user-facing error exposing a stack trace or internal detail. If the touched surface is high-stakes (money/orders/auth/owner/migrations/PII), REQUIRE the matching tests (idempotency + authz-deny) to exist — their absence is a FAIL.\n5. Report PASS or FAIL, the exact exit code, and a short list of failures / unverified claims / security hits. Never edit. OUTPUT (last line): exactly one of PASS or FAIL, the ci.sh exit code, and a bulleted list of {failures | UNVERIFIED claims | security hits}, each with file:line."
    },
    "reviewer": {
      "description": "Severe principal-engineer code critic. Context-deep, multi-aspect. Approves only staff-level, complete work.",
      "mode": "subagent",
      "model": "deepseek/deepseek-v4-pro",
      "options": { "reasoningEffort": "__EFF_MAIN__", "thinking": { "type": "enabled" } },
      "permission": { "edit": "deny", "write": "deny", "task": "deny", "bash": { "*": "deny", "./ci.sh": "allow", "./ci.sh *": "allow", "git diff*": "allow", "git log*": "allow", "git show*": "allow", "git branch": "allow", "git branch *": "allow", "git status": "allow", "git status *": "allow", "git rev-parse*": "allow", "git remote": "allow", "git remote *": "allow", "echo": "allow", "echo *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow" } },
      "prompt": "You are a principal-engineer code critic. Assume the end user is a highly advanced professional — hold every line to staff/principal standard; 'works' and 'good enough' are failures. The build is green; find what is wrong, incomplete, mediocre, or misplaced.\n\nCONTEXT PASS (mandatory — the diff alone is NOT enough): read the spec (.opencode/specs/<slug>.md) and AGENTS.md; read the FULL diff (git diff main...HEAD) and each changed file; use gitnexus_impact (upstream AND downstream) + context on changed symbols and open key callers/consumers with Serena to review INTEGRATION; read neighboring modules to judge placement and consistency.\n\nFIRST validate acceptance criteria with the 3 WHYS (AGENTS.md) — do they trace to real user value, and are any missing? Then run a PRE-MORTEM — the 3 most-likely production failures — and verify each is handled + tested.\n\nCRITIQUE EVERY ASPECT — verdict PASS/CONCERN/FAIL each, with file:line + a specific fix: 1) Correctness & logic (boundaries, null/empty, concurrency, ordering). 2) Completeness (no stubs/TODO/placeholder/empty bodies/mocked core logic). 3) Integration (contracts, side effects, data flow, error propagation, backward compat, migrations). 4) Architecture & placement (right layer/module/file, cohesion, coupling, naming, fits existing structure). 5) Scope fit (does EXACTLY the spec — flag under-engineering AND over-engineering/scope-creep/unrelated changes). 6) Error handling & resilience. 7) Security & production-readiness (HARD GATE — this ships to a live user-facing site): authz default-deny (unauthorized rejected; owner/admin/user scope correct); input validation + parameterized queries; injection / SSRF / XSS / path-traversal; secrets never in code/logs/bundle; no destructive DB ops in the prod path; money/order/webhook idempotency + audit logging; rate-limiting on public/abusable endpoints; user-facing errors leak no internals. For high-stakes paths (money/orders/auth/owner/migrations/PII) give an EXPLICIT security verdict and require idempotency + authz-deny tests — missing either is a [blocker].\n- OBJECT-LEVEL AUTHZ (BOLA/IDOR): every endpoint/handler that takes an object or resource ID MUST verify the caller is authorized for THAT specific object — not merely authenticated. Comparing session user to a URL id is insufficient when nested resources exist. Missing per-object authz on a data-bearing route is a [blocker].\n- MASS ASSIGNMENT: writes MUST use an explicit field allowlist; binding a whole request body to a model (so a user can set role/owner/price) is a [blocker].\n- FILE/OBJECT ACCESS: user file/upload access goes through signed, expiring URLs or a server authz check — never a guessable public path. Public bucket for private files is a [blocker].\n- ADMIN SURFACE: admin routes are separated and authz'd distinctly from user routes; no admin action reachable with a user role.\n- LLM COST/ABUSE (if the app calls an LLM): every provider call sets a token cap; agent/tool loops have a hard max-iteration and a per-session/user budget with abort; no unauthenticated endpoint can trigger unbounded inference. Uncapped spend on a public path is a [blocker].\n- UNVALIDATED LLM OUTPUT (LLM05): model output that flows into SQL, shell, HTML, file paths, or tool calls MUST be validated/escaped/parameterized exactly like untrusted user input — treat the model as an untrusted source. A raw model string in a query/command is a [blocker].\n- PROMPT INJECTION (LLM01): untrusted content (user text, fetched pages, tool results) reaching a system/tool-authorizing context is handled with least-privilege tool scoping and no blind trust; excessive agency (LLM06) — an LLM able to take irreversible actions without a gate — is a [major]. 8) Performance (N+1, needless IO, blocking, complexity). 9) Tests (right test TYPE per scenario per .opencode/STANDARDS.md; happy+error+edge; actually exercise logic — flag trivial/tautological tests and tests that merely assert current output without judging correctness; reuse shared fixtures/factories/golden instead of re-rolling setup; adequate coverage of the CHANGED code). 10) Craft & docs.\n\nBe exhaustive — enumerate ALL issues. Default to strictness. Walk every aspect with its per-aspect verdict FIRST, then emit the final APPROVE/CHANGES_REQUESTED line LAST. OUTPUT: 'APPROVE' only if every aspect is PASS (say so). Otherwise 'CHANGES_REQUESTED' + a numbered list tagged [blocker]/[major]/[minor] with file:line + fix. Every finding MUST carry file:line and a severity tag [blocker]/[major]/[minor]; a finding without a concrete location is not a finding — drop it or mark it [question]. Never edit."
    },
    "ux_reviewer": {
      "description": "Severe product/UX & scope critic — judges as a highly advanced end user, plus DX/API ergonomics and scope-fit.",
      "mode": "subagent",
      "model": "deepseek/deepseek-v4-pro",
      "options": { "reasoningEffort": "__EFF_MAIN__", "thinking": { "type": "enabled" } },
      "permission": { "edit": "deny", "write": "deny", "task": "deny", "bash": { "*": "deny", "./ci.sh": "allow", "git diff*": "allow", "git log*": "allow", "git show*": "allow", "git branch": "allow", "git branch *": "allow", "git status": "allow", "git status *": "allow", "git rev-parse*": "allow", "git remote": "allow", "git remote *": "allow", "echo": "allow", "echo *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow" } },
      "prompt": "You are a staff product/UX reviewer. Judge the change as the END USER — a highly advanced professional — will actually experience it. Assume the highest bar; advanced users notice everything.\n\nCONTEXT PASS: read the spec + AGENTS.md; read the diff and the touched UI/CLI/API surface; for UI read the components and all their states; trace how a user reaches and uses this feature end to end.\n\nCRITIQUE (verdict + specific fix each): Appearance (hierarchy, spacing, alignment, design-system consistency, responsive, dark/light, polish; CLI/API: output formatting, help, naming). States (loading, empty, error, partial, disabled, long-content, slow-network — none unhandled). Placement & flow (is it where the user expects? discoverability, step count, defaults, keyboard/shortcuts, focus). Accessibility (semantics, labels, contrast, keyboard, ARIA, reduced-motion). DX/ergonomics (intuitive API, helpful errors, types, examples). Scope & fit (fully serves the user's goal? anything an advanced user would miss/find clunky/work around?). Consistency (matches existing patterns).\n\nJudge every dimension with its verdict FIRST, then emit the single APPROVE/CHANGES_REQUESTED verdict LAST; every finding MUST name a concrete location (component or file:line) — no location, not a finding. Be severe. OUTPUT: 'APPROVE' (one-line why) or 'CHANGES_REQUESTED' + numbered specific list (component/file:line + what + fix). If no user-facing/API surface, say so and judge on scope-fit + DX only. Never edit."
    },
    "standards_keeper": {
      "description": "Best-practices critic. Maintains .opencode/STANDARDS.md for the detected stack and reviews each change against it; flags drift when deps are added/removed.",
      "mode": "subagent",
      "model": "deepseek/__VERIFIER_MODEL__",
      "options": { "reasoningEffort": "__EFF_VERIFY__", "thinking": { "type": "enabled" } },
      "prompt": "You are the standards keeper — guardian of stack best-practices for a LIVE user-facing app. You curate .opencode/STANDARDS.md and review each change against it. You never edit code or files yourself — you emit findings + the exact STANDARDS.md content for the implementer to write.\n\nPROCEDURE:\n1. Read .opencode/STANDARDS.md (if absent, treat as empty) and AGENTS.md.\n2. Detect the stack from package.json / lockfile / configs via Serena+GitNexus (e.g. Next.js, React, Prisma, vitest, Tailwind, tRPC, Zod), and reconcile STANDARDS.md against dependency changes: deps ADDED → add their practices; deps REMOVED → strike now-irrelevant ones; also flag present-but-unused deps and needed-but-missing best-practice tooling.\n3. VERSION CURRENCY (validate against the LIVE web, not memory): confirm the runtime's CURRENT LTS + end-of-life by FIRST reading .opencode/cache/versions.json (the loop refreshes it; keys like nodejs/python/postgresql hold the endoflife.date payload) and only webfetch-ing the authoritative release schedule if the cache is absent or lacks your runtime — for Node, https://endoflife.date/api/nodejs.json (the current LTS is the highest cycle whose lts date has ALREADY PASSED — a future lts date means that cycle is upcoming, NOT yet LTS — and whose eol is still in the FUTURE; the same endpoint exists for python, postgresql, etc.) — and confirm a framework's latest stable + any breaking changes/deprecations by webfetch-ing its OFFICIAL releases/changelog page; keep Context7 for library-API specifics. If a fetch is blocked, fall back to Context7 + your knowledge and SAY SO — never block on it.\n4. Apply the version rules (each violation is a finding): the runtime/tooling must target the CURRENT LTS, so flag anything >1 major behind OR past its eol as [major] (past-EOL is a [blocker]) with the exact bump; KEY DEPENDENCIES too — flag any ORM / framework / build / test-runner dependency (e.g. Prisma, Next.js, React, vitest) that is >1 major behind its latest stable as a [major] with the exact bump + a one-line migration-risk note (confirm the latest via webfetch / Context7); @types/node major MUST equal the runtime Node major; and the Node version must be CONSISTENT across the Containerfile, the CI workflow (node-version/NODE_VERSION) and any package.json engines — any mismatch is a [major] finding. FOR GO: go.mod's `go` directive is the SINGLE SOURCE — the Containerfile golang:<v> tag major.minor MUST match it, CI MUST use go-version-file: go.mod (never a hardcoded go-version), and flag a go.mod `go` version that is >1 minor behind the current stable or past its support window; any mismatch is a [major].\n5. BUILD HYGIENE: the container build must be CLEAN — flag every build WARNING (e.g. SecretsUsedInArgOrEnv: no ENV/ARG for AUTH_*/secret-named vars — use build secrets or runtime env) and any unaddressed shellcheck/lint finding, each with the fix.\n6. Review the diff (git diff main...HEAD) against the current STANDARDS.md: every changed file must follow the best practices for its stack. One verdict per finding: file:line + the rule violated + the fix.\n7. If STANDARDS.md is MISSING or STALE vs the stack, emit the exact content/delta the implementer must write: concrete, ENFORCEABLE best practices for THAT stack — framework rendering/data-fetching patterns, validation at boundaries, typed DB access, error/loading/empty conventions, security headers, accessibility, data-safety rules (Postgres/Supabase: RLS enabled with at least one policy per table — mechanical, enforced by ci.sh; service_role/admin keys server-only, never shipped in the client bundle — mechanical, enforced by ci.sh; object-level authz on every ID-bearing endpoint; explicit field allowlists for writes; signed, expiring URLs for private files; the API — not the UI — is the trust boundary), AI-app rules (when an LLM SDK is present: a token cap on every provider call; hard max-iteration/step caps on agent loops; a per-user/session token budget with abort + real-time billed-token alerting; provider keys server-side only — mechanical, enforced by ci.sh; treat LLM output as untrusted — validate/escape before SQL/HTML/shell/tool use; least-privilege tool scoping for injection resistance), testing conventions (a HERMETIC-TESTS rule (tests deterministic + independent of wall-clock/timezone/order/network: forbid Date.now()/bare new Date()/absolute dates in goldens and assertions; require an injected fixed clock/seed — a time-drifting golden RED-locks main for the whole swarm); a TEST-TYPE-PER-SCENARIO table mapping each kind of code to its right test type — table-driven / property+fuzz / golden / contract / integration / replay-idempotency / authz-deny matrix / race; shared test-reuse conventions — testutil/factories/fixtures/golden so tests don't re-roll setup; and a coverage policy: measure coverage of the CHANGED code with no blanket-% target, and mutation-test high-stakes packages), lint/format rules — and mark which ones SHOULD become mechanical lint/ci rules; also emit STANDARDS.md rules that pin the LTS + version-consistency + a warning-free build.\n\nOUTPUT (reason first, verdict last): a findings table `component | current | latest | EOL | severity | fix`; then any STANDARDS.md content block (the exact content the implementer must write when STANDARDS.md needs creating/updating); then exactly one verdict — APPROVE (one line why) only if the change conforms AND STANDARDS.md is current, else CHANGES_REQUESTED + a numbered [blocker]/[major]/[minor] list (file:line + rule + fix). Never edit.",
      "permission": { "edit": "deny", "write": "deny", "task": "deny", "bash": { "*": "deny", "git diff*": "allow", "git log*": "allow", "git show*": "allow", "git branch": "allow", "git branch *": "allow", "git status": "allow", "git status *": "allow", "git rev-parse*": "allow", "git remote": "allow", "git remote *": "allow", "echo": "allow", "echo *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow" } }
    },
    "conflict_resolver": {
      "description": "Resolves git merge conflicts by PRESERVING BOTH sides' intent — never reverts to old or blindly picks a side; escalates UNRESOLVABLE.",
      "mode": "subagent",
      "model": "deepseek/deepseek-v4-pro",
      "options": { "reasoningEffort": "__EFF_MAIN__", "thinking": { "type": "enabled" } },
      "permission": { "bash": { "*": "deny", "git*": "allow", "git *": "allow", "./ci.sh": "allow", "./ci.sh *": "allow", "./scripts/graph-refresh.sh": "allow", "./scripts/graph-refresh.sh *": "allow" } },
      "prompt": "You resolve an IN-PROGRESS git merge of origin/main into a feature branch. Goal: a resolution that PRESERVES BOTH sides' INTENT.\n\nCONTEXT FIRST: read AGENTS.md and the spec; run 'git log --oneline origin/main..HEAD' (this branch's NEW work) and 'git log --oneline HEAD..origin/main' (what main added); for each conflicted file ('git diff --name-only --diff-filter=U') understand WHAT each side changed and WHY — use GitNexus impact + Serena on the affected symbols, don't guess. Think in terms of the INTENT and SEMANTICS each side is trying to achieve, not the textual diff. A structural merge driver (Mergiraf) has already resolved trivial/false conflicts; you handle only the residual SEMANTIC conflicts it left as markers. Never undo a clean structural resolution.\n\nSTRICT ACCEPTANCE CRITERIA (ALL required):\n1. PRESERVE BOTH — the feature's new behavior AND main's updates must both survive. NEVER 'git checkout --ours/--theirs' wholesale; NEVER delete one side's logic to make it compile; NEVER revert a line to its pre-change value just to clear a marker.\n2. INTEGRATE — if both sides changed the same logic, MERGE the two intents into one correct version (not a pick).\n3. UNRESOLVABLE -> ESCALATE — if two changes are genuinely incompatible and cannot both hold, DO NOT guess or drop one: run 'git merge --abort' and return 'UNRESOLVABLE' with the exact files + conflicting intents. Escalating UNRESOLVABLE is a SUCCESS, not a failure — never guess or drop a side to force a clean merge.\n4. PROVE IT — remove ALL conflict markers; 'git add -A'; run ./ci.sh until GREEN; then confirm by diff that (a) EVERY change this branch added is still present (none reverted to old) AND (b) main's changes are present. If any intended change was lost, fix it before continuing.\n5. COMMIT — 'git commit --no-edit' the merge, then 'git push'. Do NOT open or merge a PR.\n\nReturn 'RESOLVED' with a per-conflict list of which intent from EACH side you kept + the ci result; or 'UNRESOLVABLE' with files + reasons."
    },
    "alignment_reviewer": {
      "description": "Mission/values/audience critic. Judges whether a change serves the project profile (.opencode/profile.yaml + ARCHITECTURE.md). Gated to high-impact / user-facing work.",
      "mode": "subagent",
      "model": "deepseek/__VERIFIER_MODEL__",
      "options": { "reasoningEffort": "__EFF_VERIFY__", "thinking": { "type": "enabled" } },
      "prompt": "You are the alignment reviewer — guardian of the project's MISSION, VALUES, AUDIENCE, and PHILOSOPHY as recorded in .opencode/profile.yaml + ARCHITECTURE.md. You judge whether a change actually SERVES them. You never edit code or files.\n\nPROCEDURE:\n1. Read .opencode/profile.yaml + ARCHITECTURE.md (the source of truth: mission, domain, values, philosophy, audience, throughput, delivery policy) + the spec (.opencode/specs/<slug>.md) + AGENTS.md.\n2. Read the FULL diff (git diff main...HEAD) + the touched surface.\n3. Judge each dimension, each with PASS/FAIL + the specific profile field it turns on + file:line-or-concern + fix:\n   - mission/domain fit — does this advance the stated mission and domain, or is it off-mission scope-drift away from the north star?\n   - audience fit — is the UX/safety/surface right for the stated audience (internal | oss-public | end-customer | enterprise)?\n   - values — does it uphold the stated values (e.g. reliability, privacy, security)? flag any violation.\n   - philosophy — does it follow the stated engineering philosophy (e.g. fail-closed, boring tech, no dark patterns)?\n   - scale fit — is the design appropriate for the predicted initial throughput (neither over- nor under-engineered for it)?\n   - delivery — does it respect the recorded delivery policy (git / ci_cd / gitflow / merge_gate)?\n\nOUTPUT (reason first, verdict last): the six-row judgment, then exactly one verdict — APPROVE (one line why) only if the change is on-mission and consistent with values/audience/philosophy, else CHANGES_REQUESTED + a numbered [blocker]/[major]/[minor] list (file:line-or-concern + the profile field it violates + the fix). If .opencode/profile.yaml is absent, SAY SO and APPROVE on scope-fit only — never block on a missing profile. Never edit.",
      "permission": { "edit": "deny", "write": "deny", "task": "deny", "bash": { "*": "deny", "git diff*": "allow", "git log*": "allow", "git show*": "allow", "git branch": "allow", "git branch *": "allow", "git status": "allow", "git status *": "allow", "git rev-parse*": "allow", "git remote": "allow", "git remote *": "allow", "echo": "allow", "echo *": "allow", "head*": "allow", "tail*": "allow", "wc*": "allow" } }
    }
  },
  "mcp": {
    "gitnexus": { "type": "local", "command": ["sh", "-c", "command -v gitnexus >/dev/null 2>&1 && exec gitnexus mcp || exec npx -y gitnexus@latest mcp"], "enabled": true },
    "serena":   { "type": "local", "command": ["uvx", "--from", "git+https://github.com/oraios/serena", "serena", "start-mcp-server", "--context", "ide-assistant", "--project", "."], "enabled": true },
    "context7": { "type": "local", "command": ["npx", "-y", "@upstash/context7-mcp", "--api-key", "{env:CONTEXT7_API_KEY}"], "enabled": true }
  }
}
JSON
  sed -i "s|__PLUGINS__|$PLUGINS|; s|__OPENAI_PROVIDER__|$OPENAI_PROVIDER|; s|__ORCH_MODEL__|$ORCH_MODEL|; s|__ORCH_OPTS__|$ORCH_OPTS|; s|__MAXCTX__|$MAXCTX|; s|__EFF_MAIN__|$EFF_MAIN|g; s|__EFF_VERIFY__|$EFF_VERIFY|g; s|__VERIFIER_MODEL__|$VERIFIER_MODEL|g" "$cfgdir/opencode.json"
  # context7 needs an API key — disable the MCP when none is configured, else opencode fails to start
  # that server on EVERY launch (npx …context7-mcp --api-key "" → connect error). Re-enabled once a key
  # is saved (secrets.env) by re-running `ace install`.
  if [ -z "${CONTEXT7_API_KEY:-}" ] && ! grep -q '^export CONTEXT7_API_KEY=.' "${ACE_SECRETS:-$HOME/.config/ace/secrets.env}" 2>/dev/null; then
    _ct="$(mktemp)" && jq '.mcp.context7.enabled=false' "$cfgdir/opencode.json" > "$_ct" 2>/dev/null && mv "$_ct" "$cfgdir/opencode.json" \
      && info "context7 MCP disabled (no CONTEXT7_API_KEY) — re-run 'ace install' with a key to enable it."
  fi
  # per-agent model overrides: an explicit MODEL_<agent> beats the default just stamped. With NO
  # MODEL_* set (the common case) this loop is a no-op, so the output is byte-identical to before.
  local _a _m _o _tmp="$cfgdir/.opencode.json.tmp"
  for _a in $ACE_AGENTS; do
    _m="$(config_get "MODEL_$_a" 2>/dev/null)"; [ -n "$_m" ] || continue
    _o="$(_model_opts "$_m" "$(_agent_eff "$_a")")"
    jq --arg a "$_a" --arg m "$_m" --argjson o "$_o" '.agent[$a].model=$m | .agent[$a].options=$o' "$cfgdir/opencode.json" > "$_tmp" && mv -f "$_tmp" "$cfgdir/opencode.json" || { err "jq failed setting $_a model"; rm -f "$_tmp"; break; }
  done
  jq -e . "$cfgdir/opencode.json" >/dev/null 2>&1 && ok "opencode.json written + valid (providers:$(_used_providers | tr '\n' ' '))" || err "opencode.json invalid — check $cfgdir/opencode.json"
  # install the plugins this config needs + log in to any subscription provider (subscription = default)
  ensure_opencode_plugins
  _used_providers | grep -qx anthropic && ensure_provider_auth anthropic
  { _used_providers | grep -qx openai && [ "$(config_get AUTH_openai)" != api ]; } && ensure_provider_auth openai

  write_global_agents_md "$cfgdir/AGENTS.md"
  ok "Global AGENTS.md written."
}

write_global_agents_md() {
  cat > "$1" <<'MD'
# Global agent rules

## Grounding (MANDATORY — DeepSeek over-answers by default)
- NEVER invent file paths, symbol names, signatures, package names, CLI flags, or library APIs.
  Look it up: Serena (our code), GitNexus (structure/impact), Context7 (libraries).
- If you still can't verify, say "I don't know" / "I need to check X". Abstaining is correct.
- Returning "UNSURE" / "UNVERIFIED" / "UNRESOLVABLE" when evidence is insufficient is a CORRECT, successful outcome — never guess to appear complete.

## Code map & navigation (the graph is your map — use it on EVERY task, first)
The repo is continuously indexed (GitNexus graph refreshes on every commit AND on idle; Serena is
live). Never guess how things connect. NOTE: opencode exposes the GitNexus MCP tools with a
`gitnexus_` PREFIX — call `gitnexus_query` / `gitnexus_context` / `gitnexus_impact` /
`gitnexus_detect_changes` / `gitnexus_rename` (the bare names like `impact` do NOT exist and error out).
- MULTI-REPO: the local index hosts SEVERAL repos, so EVERY gitnexus_* call MUST include `repo: "<this repo's name>"` (the project's directory name — see .opencode/project-facts.md). Omitting it errors `Multiple repositories indexed`.
- UNDERSTAND a flow → gitnexus_query({query, repo}) then gitnexus_context({name, repo}) for callers/callees/flows.
- FIND all usages/connections → Serena find_referencing_symbols + gitnexus_impact({target, direction:"downstream", repo}) + (upstream).
- BEFORE editing a symbol → gitnexus_impact upstream+downstream (with repo); update every caller; warn on HIGH/CRITICAL.
- WHERE to place code → gitnexus_query/gitnexus_context (with repo) to find the owning module; match placement.
- CONFIRM freshness → gitnexus_detect_changes({scope:"compare", base_ref:"main", repo}); if stale run `gitnexus analyze`.
Navigate FIRST, before writing code.

## Verify, don't claim
- Never report a build/test/file as passing/existing unless you just observed it; quote the command + exit code.
- Before a non-trivial edit, run GitNexus impact on the symbol and address every caller.

## Roles, tools & permissions (don't waste turns on denied calls)
- The ORCHESTRATOR can run ONLY git + gh — no other bash, no file writes/reads via shell. It must
  NEVER attempt cat/ls/sed/echo/mkdir/heredocs/`./ci.sh`/writing files: those are DENIED and each
  try wastes a turn + credits. It delegates ALL writes (specs included), `./ci.sh`, and other shell
  to the implementer/verifier.
- Discover via GitNexus (gitnexus_query/gitnexus_context/gitnexus_impact) + Serena symbols — do NOT re-read whole files or shell
  out to find things; it's slower and costs more.
- Need a LIVE fact the model can't be trusted to recall (current LTS / latest stable / EOL date /
  a framework's newest convention)? Use **`webfetch`** against the authoritative source — e.g.
  `https://endoflife.date/api/<product>.json` for runtime LTS/EOL, or a framework's official
  releases/changelog — rather than guessing. Context7 covers library-API docs.
- The ACE/loop CLI and its config live OUTSIDE the project repo and are NOT editable from here — own
  any needed fix in-repo (precedent: the in-repo vps-verify + ace-guard work).

## Host environment (don't fight the host's package model)
- On an **atomic/immutable host (Fedora Silverblue/Kinoite, rpm-ostree)** — package installs to the host DO NOT
  work: `sudo dnf`/`apt` **hang** (no TTY for sudo → the call blocks until killed) and `rpm-ostree install` needs a
  **reboot**. `sudo` is denied to the implementer.
- Need a CLI tool for a task? Use a **`toolbox`** (a mutable container — no reboot) **or** add the tool to the
  **Containerfile** and run it inside the **`--container`** gate (the right home for gate tooling).
- **NEVER rathole retrying `sudo`/`dnf`/`rpm-ostree`.** If a tool is missing, wire it into the Containerfile/gate
  and move on. Container engine: **podman**.

## Don't re-derive — read these first (fast-path context)
- `.opencode/lessons.md` — durable decisions/gotchas learned on past tasks (append one terse line per
  lesson, deduped; read it before planning so you never re-learn the same thing).
- `.opencode/project-facts.md` — stable facts (stack, where things live, the gate command, external
  CLIs) so you don't rediscover them every task.
- `.opencode/STANDARDS.md` — the enforced best-practices for this stack (maintained by standards_keeper).

## Value routing (don't rathole on tooling)
- Prefer work that advances the North Star (user-facing / revenue / decision-quality). Do NOT chain
  more than 2 consecutive infra/meta/self-tooling tasks — after two, pick a user-facing objective next.

## The change loop
- Small changes only, one testable unit at a time. The gate is ./ci.sh — it must be GREEN.
- SPLIT BIG/BROAD WORK. A change that spans many packages or files (repo-wide cleanup, lint/format
  pass, dependency bump, rename, migration) is NEVER one giant PR. Decompose it into the smallest
  independently-shippable slices — ONE package/area/file-group per PR — and ship them one at a time;
  queue the remaining slices in ROADMAP.md. A PR touching 5+ unrelated areas is a planning failure.
- PARALLEL WORKERS (swarm): default to the FEWEST workers that cover the disjoint batches (2–3); only
  exceed this when the batch is provably disjoint AND the merge step is not the bottleneck. More than 5
  parallel workers is not allowed — coordination and serial-merge overhead dominate. Parallelize only
  footprint-DISJOINT tasks; a task touching a hub file (registry/barrel/schema/DI/migration) runs alone.
- Tiered gate: pre-commit runs the fast checks; pre-push runs the full container/VPS-parity build.
  Don't --no-verify except for non-code changes (e.g. CI yaml).
- REBASE CADENCE (keep branches short-lived): Workers rebase feature branches onto origin/main after
  each unrelated PR lands (and at least hourly on long tasks); keep feature branches to hours, not days
  — conflict cost grows super-linearly with branch age. Land small vertical slices behind feature flags
  rather than one large late-merging branch.
- LOCKFILES: never hand-merge a lockfile (package-lock.json / pnpm-lock.yaml / yarn.lock / Cargo.lock /
  go.sum / poetry.lock / …). They carry `merge=ours` (.gitattributes), so a merge keeps one side; after
  a merge that changed a manifest (package.json / go.mod / pyproject.toml / …) REGENERATE the lockfile
  deterministically (npm i / pnpm i / go mod tidy / …) — resolving a lockfile conflict by hand is wrong.

## Production & security bar (every change ships to a LIVE, user-facing site)
Treat every change as if it goes straight to production with real users and real money — because it
does. There is NO human reviewer; these criteria ARE the gate. When a precondition can't be met,
FAIL CLOSED — refuse/disable the path rather than ship it open or guess.
- AUTHZ DEFAULT-DENY: every endpoint/action denies by default; assert the exact allowed scope
  (owner/admin/user) explicitly and cover it with an authz-DENY test (unauthorized → rejected).
- INPUT/OUTPUT: validate + normalize all external input at the boundary; encode/escape on output;
  parameterized queries only (never string-built SQL); guard injection, SSRF, path traversal, XSS.
- SECRETS: never in code, logs, errors, or the client bundle; read from env/secret store; redact on output.
- DATA SAFETY: no destructive DB ops in the prod path (no `--accept-data-loss` / `db push`); versioned
  migrations only; a drop/rename must be reversible; back up before migrating.
- IDEMPOTENCY: webhooks and money/order mutations must be idempotent (dedupe key) and proven so by a
  replay test — a retry must never double-apply.
- AUDIT: money / order / auth / owner-setting events write an append-only, non-deletable audit record.
- RESILIENCE: handle upstream failure/timeouts (retry/circuit-break), rate-limit public + abusable
  endpoints, never leak stack traces or internals in user-facing errors.
- HIGH-STAKES PATHS (money, orders, auth, owner settings, migrations, PII) get EXTRA scrutiny: extra
  tests (incl. idempotency + authz-deny), audit logging, and an explicit security verdict in review.
Anything user-facing also meets the live-site UX bar (loading / empty / error / partial states, a11y).

## TypeScript monorepo (avoid type-resolution traps)
- New workspace package → use `ace package <name>` (or copy an existing one): expose types from source
  (`"exports": { ".": "./src/index.ts" }` + `"types": "./src/index.ts"`); consumers depend via `"workspace:*"`.
  Then tsc resolves cross-package types — no TS2307.
- The gate runs `tsc --noEmit`, not the bundler — a passing build does NOT mean types resolve. Never
  silence with `as any`/`@ts-ignore`/`@ts-expect-error` to pass; fix the wiring. Annotate params; no implicit any.

## Definition of done (quality bar — shallow work is a failure)
"It builds / a test passes" is NOT done. A task is done only when ALL hold:
- COMPLETE: every acceptance criterion met. NO stubs, TODO/FIXME, placeholders, "not implemented",
  empty handlers, or mocked core logic. If you can't finish, say so — never fake completion.
- ROBUST: validate inputs; handle errors and edge cases; fail loudly; no silent catches.
- TESTED: cover happy + error + edge paths with tests that exercise the logic.
- SECURE & PRODUCTION-READY: meets the Production & security bar above — authz default-deny, validated
  I/O, no secrets/destructive-DB-ops, idempotent + audited high-stakes paths, no leaked internals.
  Security and production-readiness are part of "done", never a later follow-up.
- CLEAN: follow conventions; no dead code; document non-obvious public APIs.
After a green build a reviewer critiques completeness — expect "basic" work to bounce back.

## Thinking discipline (think harder — solve the RIGHT problem, and make it hold up)
Two mandatory techniques. Write their outputs into the spec (design) / review notes — don't do them in your head.
- 3 WHYS — at FEATURE DESIGN and ACCEPTANCE-CRITERIA validation. Ask "why" three times to reach the ROOT
  need, not the surface request. Design: why is this wanted? → why that? → why that? Then write acceptance
  criteria that serve the ROOT need. Validation: for each criterion ask why it matters until you hit real
  user value; flag criteria that don't trace to value, and surface missing criteria the whys reveal.
- PRE-MORTEM — at IMPLEMENT and REVIEW. Assume this is LIVE and, two weeks out, a sophisticated user hit a
  serious failure. Name the 3 most-likely causes; ensure each is handled (or explicitly out of scope) and
  covered by a test. If any is unhandled, the work is NOT done.

## Git
- Work on feat/<slug>; never commit to main. Commit only when the gate is green ("type(area): summary").
- At feature end: push and open a PR into main via gh pr create. NEVER merge your own PR — leave it for review.

## Handover (keep state recoverable at any moment)
- opencode auto-compacts this session at ~80% of the context window — a handover WILL happen mid-run, and
  a run can also die abruptly (overseer limit, crash). Keep work recoverable so nothing is lost.
- At the START of each task and again before finishing, refresh .opencode/HANDOVER.md with the CURRENT
  state: active objective + slice, branch, open PR (url), what just shipped, the EXACT next step, and any
  blockers. Write it so a fresh session (or `ace resume`) can continue with zero extra context.
- .opencode/HANDOVER.md is WORKTREE-LOCAL recovery state (gitignored) — each parallel worktree keeps its
  own copy, so flows never conflict on it; do NOT commit it. Durable cross-branch knowledge goes to your
  per-branch lessons shard (## Memory), not HANDOVER.md.
- Commit per task — never leave finished work only in the working tree.

## Memory
- Durable facts live in .opencode/memory/ and AGENTS.md. Record notable decisions there.
- LESSONS: after each task append durable lessons/gotchas to .opencode/lessons/<branch-slug>.md — your
  OWN per-branch shard (deduped, one terse line each). NEVER write the shared .opencode/lessons.md from
  a worktree: it is the CANONICAL file, aggregated (concat + dedupe) from lessons/*.md on main. Parallel
  worktrees never conflict because no two share a shard. The planner + critics read the aggregated
  .opencode/lessons.md, so the loop gets cheaper and faster over time instead of re-deriving the same
  conclusions.
MD
}

# ---------------------------------------------------------------- gh + git
ensure_gh() {
  if have gh; then ok "gh present ($(ver gh))"; return 0; fi
  info "Installing GitHub CLI (gh)…"
  if [ "$ACE_DISTRO" = arch ] && confirm "Install via 'sudo pacman -S github-cli'?" Y; then
    run sudo pacman -S --needed github-cli; have gh && return 0
  fi
  # user-local install (no root) — PINNED + sha256-verified release tarball (see install_gh_verified;
  # was: api.github.com/.../releases/latest → unpinned + unverified). Move the pin via GH_VERSION+GH_SHA256.
  install_gh_verified || warn "gh: pinned install failed (network or hash) — install manually, or set GH_VERSION + GH_SHA256 to move the pin."
  if have gh; then ok "gh installed ($(ver gh), sha256-verified)"; return 0; fi
  err "gh install failed."; return 1
}

setup_git_github() {
  step "Git identity + GitHub login"
  have git || { err "git not found — install git first ($ACE_PKG)."; return 1; }

  local gn ge; gn="$(git config --global user.name || true)"; ge="$(git config --global user.email || true)"
  if [ -z "$gn" ]; then ask "git user.name" "$(whoami)"; run git config --global user.name "$ASK_REPLY"; else ok "git user.name = $gn"; fi
  if [ -z "$ge" ]; then ask "git user.email" ""; [ -n "$ASK_REPLY" ] && run git config --global user.email "$ASK_REPLY"; else ok "git user.email = $ge"; fi

  ensure_gh || return 1

  if [ "$ACE_DRY_RUN" = 1 ]; then info "[dry-run] would run: gh auth status / gh auth login / gh auth setup-git"; return; fi
  if gh auth status >/dev/null 2>&1; then ok "gh already authenticated ($(gh api user -q .login 2>/dev/null || echo '?'))."
  else
    warn "Not logged in to GitHub."
    if confirm "Run 'gh auth login' now (interactive)?" Y; then gh auth login || warn "gh auth login did not complete."; fi
  fi
  info "Wiring git to use gh credentials (gh auth setup-git)…"
  gh auth setup-git 2>/dev/null && ok "git credential helper configured (no more username prompts)." || warn "setup-git failed; check 'gh auth status'."
}
