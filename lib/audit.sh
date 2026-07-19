#!/usr/bin/env bash
# audit.sh — dependency + security checks for the project in $PWD.

# ── Secret pattern: SINGLE SOURCE OF TRUTH ──────────────────────────────────
# Every secret scanner in ACE must reuse this constant. Historically the local
# `ace audit` scan and the scanner generated into a project's ci.sh
# (lib/scaffold.sh) carried two hand-maintained copies that silently diverged:
# the audit copy used a `sk-[a-zA-Z0-9]{20,}` class that excludes `-` and `_`,
# so it could not match `sk-ant-…` or `sk-or-…` — the exact keys ACE itself
# provisions for agents. It also had no `github_pat_` (fine-grained PAT) or
# `ASIA` (STS temporary credential) alternative. Anything that needs this regex
# must reference $ACE_SECRET_RE rather than paste a literal; the generated CI
# scanner is scheduled to be fed from here too.
# Notes on the alternatives:
#   gh[pousr]_       — classic GitHub tokens (pat/oauth/user/server/refresh)
#   github_pat_      — fine-grained PAT: <11 char prefix>_<59 char body>
#   (AKIA|ASIA)      — AWS long-lived AND STS temporary access-key ids
#   sk-[A-Za-z0-9_-] — OpenAI/Anthropic/OpenRouter style; `-`/`_` are REQUIRED
#                      in the class or every provider-prefixed key slips past
ACE_SECRET_RE='-----BEGIN [A-Z ]*PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|(AKIA|ASIA)[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|AIza[0-9A-Za-z_-]{35}|sk_live_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9_-]{20,}'

secret_scan() {
  step "Secret scan (tracked files)"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { warn "not a git repo — skipping secret scan"; return 0; }

  # NUL transport end to end. The old version piped newline-separated `git
  # ls-files` into bare `xargs`, which parses quotes: ONE tracked filename
  # containing an apostrophe made xargs abort with "unmatched single quote"
  # BEFORE grep ever ran. With stderr thrown away by 2>/dev/null the result was
  # an empty $hits, which the code read as "clean" — a committed token sat right
  # there and the scan reported no obvious secrets. -z/-0 removes all quoting
  # and whitespace interpretation, so filenames are opaque bytes.
  local tmp err_log list rc
  tmp="$(mktemp)"; err_log="$(mktemp)"; list="$(mktemp)"

  # Build the NUL-separated file list as its OWN step. `ace` runs under
  # `set -o pipefail`, and the exclusion grep exits 1 when it filters everything
  # out (a repo tracking only .env.example, or no files at all) — folding that
  # into the scan pipeline made a legitimately empty list look like a scan
  # failure. Judge git's rc, and only git's, via PIPESTATUS here.
  local -a ps
  git ls-files -z 2>>"$err_log" | grep -zvE '(^|/)\.env\.example$' >"$list" 2>>"$err_log"
  ps=("${PIPESTATUS[@]}")
  # git must succeed. grep rc 1 is LEGITIMATE here (it filtered every path out: a repo tracking only
  # .env.example, or none at all) but rc>=2 is a REAL grep error (non-GNU grep with no -z, full disk,
  # OOM) that truncates $list — and an empty list makes xargs -r skip, which would print "clean" over a
  # committed token. Judging git alone left exactly the fail-open this whole function exists to kill.
  if [ "${ps[0]}" -ne 0 ] || [ "${ps[1]}" -ge 2 ]; then
    err "secret scan FAILED to list tracked files (git exit ${ps[0]}, filter exit ${ps[1]}) — treating as unsafe, not clean:"
    head -20 "$err_log" >&2; rm -f "$tmp" "$err_log" "$list"; return 1
  fi

  # xargs returns 123 if ANY child exits 1..125, and grep exits 1 for "no match"
  # — so xargs alone cannot tell clean from broken. The sh wrapper absorbs
  # grep rc 1 (clean) and lets rc 2 (real error: unreadable file, bad regex)
  # propagate, making 123 mean *error* and 0 mean *ran successfully*.
  # `-e` is mandatory: the pattern starts with `-----BEGIN`, which grep would
  # otherwise parse as a bundle of short options. `--` ends option parsing so a
  # filename starting with `-` is treated as a file, not a flag. The wrapper
  # shifts the pattern off before "$@" so it is not also scanned as a filename.
  xargs -0 -r sh -c 'p=$1; shift; grep -nIE -e "$p" -- "$@" || [ $? = 1 ]' _ "$ACE_SECRET_RE" \
    <"$list" >"$tmp" 2>>"$err_log"
  rc=$?

  if [ "$rc" -ne 0 ]; then
    # Never fall through to the clean path on an error: an unreadable scan is
    # an UNKNOWN result, and unknown must fail closed.
    err "secret scan FAILED to run (exit $rc) — treating as unsafe, not clean:"
    head -20 "$err_log" >&2
    rm -f "$tmp" "$err_log" "$list"; return 1
  fi

  if [ -s "$tmp" ]; then
    err "potential secret(s) committed:"; head -20 "$tmp"
    rm -f "$tmp" "$err_log" "$list"; return 1
  fi

  rm -f "$tmp" "$err_log" "$list"
  ok "no obvious secrets in tracked files"; return 0
}

ace_audit() {
  banner; step "Dependency & security audit ($PWD)"
  # found  — a check ran and reported a problem
  # ran    — names of checks that ACTUALLY executed; the summary may only claim
  #          "clean" for these. Previously the summary said "no high vulns" even
  #          when pnpm/uvx were missing and no manifest existed, i.e. when zero
  #          audits had run — a fail-open gate that reads as a pass.
  local found=0 detected=0
  local ran=()

  if [ -f package.json ]; then
    detected=1; info "Node project"
    if have pnpm; then
      spin "pnpm audit (high+)" pnpm audit --audit-level=high || { warn "vulnerabilities at high+ severity"; found=1; }
      ran+=("pnpm audit")
      spin_sh "outdated deps (info)" 'pnpm -r outdated || true'
      info "lockfile integrity is enforced by the gate (pnpm install --frozen-lockfile)."
    else warn "pnpm not on PATH — open a new shell or run 'ace install'."; fi
  fi

  if [ -f requirements.txt ] || [ -f pyproject.toml ]; then
    detected=1; info "Python project"
    local args=(); [ -f requirements.txt ] && args=(-r requirements.txt)
    if have uvx; then
      spin "pip-audit" uvx pip-audit "${args[@]}" || { warn "Python vulnerabilities found"; found=1; }
      ran+=("pip-audit")
    elif have python3; then
      spin_sh "pip-audit" "python3 -m pip install --quiet --user pip-audit >/dev/null 2>&1; python3 -m pip_audit ${args[*]}" || { warn "pip-audit issues"; found=1; }
      ran+=("pip-audit")
    else warn "no uvx/python3 to run pip-audit."; fi
  fi

  # Go was missing entirely even though the CI we generate runs govulncheck, so
  # a Go project audited locally as "clean" without a single check executing.
  if [ -f go.mod ]; then
    detected=1; info "Go project"
    if have govulncheck; then
      spin "govulncheck" govulncheck ./... || { warn "Go vulnerabilities found"; found=1; }
      ran+=("govulncheck")
    elif have go; then
      # Same tool the generated gate uses; `go run` pins nothing on purpose so
      # the vuln DB client stays current (it fetches the DB at run time anyway).
      spin_sh "govulncheck (go run)" 'go run golang.org/x/vuln/cmd/govulncheck@latest ./...' || { warn "Go vulnerabilities found"; found=1; }
      ran+=("govulncheck")
    else warn "no govulncheck/go on PATH — cannot audit Go modules."; fi
  fi

  [ "$detected" = 0 ] && warn "No package.json / requirements.txt / go.mod here — run inside a project."
  secret_scan || found=1
  # Only credit the secret scan as "run" when there was a git repo to scan —
  # outside one it self-skips and must not prop up the summary.
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 && ran+=("secret scan")

  echo
  # Distinguish "checked and clean" from "nothing was checked". The latter is an
  # indeterminate result and returns 2 so a caller/CI cannot mistake it for a pass.
  if [ "${#ran[@]}" -eq 0 ]; then
    err "Audit INCONCLUSIVE — no checks could run (no supported manifest, or the audit tools are missing)."
    err "Install pnpm / uvx / govulncheck, or run inside a project. This is NOT a clean result."
    return 2
  fi

  local ran_list; ran_list="$(printf '%s, ' "${ran[@]}")"; ran_list="${ran_list%, }"
  if [ "$found" = 0 ]; then ok "Audit clean — checks run: ${ran_list}."
  else err "Audit found issues (see above / 'ace logs') — checks run: ${ran_list}. Fix before shipping."; fi
  return "$found"
}
