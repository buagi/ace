#!/usr/bin/env bash
# audit.sh — dependency + security checks for the project in $PWD.

secret_scan() {
  step "Secret scan (tracked files)"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { warn "not a git repo — skipping secret scan"; return 0; }
  local hits
  hits="$(git ls-files 2>/dev/null | grep -vE '(^|/)\.env\.example$' \
        | xargs -r grep -nIE '(-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|sk-[a-zA-Z0-9]{20,})' 2>/dev/null | head -20)"
  [ -z "$hits" ] && { ok "no obvious secrets in tracked files"; return 0; }
  err "potential secret(s) committed:"; printf '%s\n' "$hits"; return 1
}

ace_audit() {
  banner; step "Dependency & security audit ($PWD)"
  local found=0 detected=0

  if [ -f package.json ]; then
    detected=1; info "Node project"
    if have pnpm; then
      spin "pnpm audit (high+)" pnpm audit --audit-level=high || { warn "vulnerabilities at high+ severity"; found=1; }
      spin_sh "outdated deps (info)" 'pnpm -r outdated || true'
      info "lockfile integrity is enforced by the gate (pnpm install --frozen-lockfile)."
    else warn "pnpm not on PATH — open a new shell or run 'ace install'."; fi
  fi

  if [ -f requirements.txt ] || [ -f pyproject.toml ]; then
    detected=1; info "Python project"
    local args=(); [ -f requirements.txt ] && args=(-r requirements.txt)
    if have uvx; then
      spin "pip-audit" uvx pip-audit "${args[@]}" || { warn "Python vulnerabilities found"; found=1; }
    elif have python3; then
      spin_sh "pip-audit" "python3 -m pip install --quiet --user pip-audit >/dev/null 2>&1; python3 -m pip_audit ${args[*]}" || { warn "pip-audit issues"; found=1; }
    else warn "no uvx/python3 to run pip-audit."; fi
  fi

  [ "$detected" = 0 ] && warn "No package.json / requirements.txt here — run inside a project."
  secret_scan || found=1

  echo
  if [ "$found" = 0 ]; then ok "Audit clean — no high vulns or secrets found."
  else err "Audit found issues (see above / 'ace logs'). Fix before shipping."; fi
  return "$found"
}
