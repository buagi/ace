#!/usr/bin/env bash
# gitflow.sh — enforce a clean git-flow: main as integration, feature branches,
# conventional commits, no direct commits to main, PR template. Idempotent.

git_flow_apply() {
  local dir="${1:-$PWD}"
  cd "$dir" || { err "not a directory: $dir"; return 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { run git init -q; ok "git init"; }

  step "Git-flow compliance"
  # default branch name → main, everywhere
  run git config --global init.defaultBranch main
  run git config push.autoSetupRemote true
  run git config pull.rebase true

  # rename current branch to main if it's master / not main and history is fresh
  local cur; cur="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo '')"
  if [ "$cur" = "master" ]; then
    run git branch -M main; ok "renamed master → main"
  elif [ -z "$cur" ]; then
    info "no commits yet; first commit will be on main"
    run git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  else
    ok "current branch: $cur"
  fi

  install_gitflow_hooks "$dir"

  mkdir -p .github
  if [ ! -f .github/PULL_REQUEST_TEMPLATE.md ] && [ "$ACE_DRY_RUN" != 1 ]; then
    cat > .github/PULL_REQUEST_TEMPLATE.md <<'EOF'
## What & why

## Checklist
- [ ] `./ci.sh` green locally (fast gate)
- [ ] `./ci.sh --container` green (VPS parity) / CI green
- [ ] Conventional commit title: `type(scope): summary`
- [ ] No secrets committed; new env vars added to `.env.example`
EOF
    ok "added .github/PULL_REQUEST_TEMPLATE.md"
  fi
  ok "Git-flow: main integration branch, feature branches, conventional commits, PR-only merges."
  if have gh && git remote get-url origin >/dev/null 2>&1; then
    confirm "Try to enable branch protection on main (GitHub)?" Y && gh_protect_main
  fi
}

# Best-effort server-side protection. Free private repos can't (needs Pro) — we fall
# back with a clear message rather than failing.
gh_protect_main() {
  need gh
  local slug; slug="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  [ -z "$slug" ] && { warn "no GitHub origin — skipping protection"; return 0; }
  # Only require a status CHECK when a CI actually produces one. With ci_cd:none / a local gate there is NO
  # check, so 'required_status_checks' would block EVERY merge forever (the check never reports). Detect from
  # the project profile + the presence of a workflow; otherwise protect main WITHOUT a required check.
  local cicd checks_rule="" checkmsg=""
  cicd="$(sed -n 's/^[[:space:]]*ci_cd:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
  if [ "$cicd" = github-actions ] || ls .github/workflows/*.yml >/dev/null 2>&1; then
    checks_rule=',
    { "type":"required_status_checks", "parameters":{ "strict_required_status_checks_policy":true, "required_status_checks":[ { "context":"build-test" } ] } }'
    checkmsg=" + 'build-test' must pass"
  fi
  step "Branch protection on main ($slug)${checkmsg:+ (CI-gated)}${checkmsg:- (local gate — no required CI check)}"
  if [ "$ACE_DRY_RUN" = 1 ]; then info "[dry-run] would create a ruleset: PR required${checkmsg}"; return 0; fi
  local tmp out rc; tmp="$(mktmp)/ruleset.json"
  cat > "$tmp" <<JSON
{ "name":"ace: protect main", "target":"branch", "enforcement":"active",
  "conditions":{ "ref_name":{ "include":["refs/heads/main"], "exclude":[] } },
  "rules":[
    { "type":"deletion" },
    { "type":"non_fast_forward" },
    { "type":"pull_request", "parameters":{ "required_approving_review_count":0, "dismiss_stale_reviews_on_push":false, "require_code_owner_review":false, "require_last_push_approval":false, "required_review_thread_resolution":false } }${checks_rule}
  ] }
JSON
  out="$(gh api -X POST "repos/$slug/rulesets" --input "$tmp" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "Ruleset active: PR required${checkmsg} to merge to main."
  elif printf '%s' "$out" | grep -qiE 'already exists|name.*exists'; then
    ok "main is already protected (ruleset exists)."
  elif printf '%s' "$out" | grep -qiE 'Pro|upgrade|payment|403'; then
    warn "GitHub blocked it: rulesets/branch-protection need GitHub Pro on PRIVATE repos."
    say  "  ${C_GREY}Options: upgrade to Pro · make the repo public · rely on local hooks (main-guard).${C_RESET}"
  else
    warn "Could not set protection:"; say "  ${C_GREY}$out${C_RESET}"
  fi
}

# Hooks that complement the project's ci gate (pre-commit/pre-push already run ci.sh):
#  - commit-msg : enforce Conventional Commits
#  - main-guard : block direct commits to main (prepended into pre-commit if present)
install_gitflow_hooks() {
  local dir="$1" hd
  hd="$(cd "$dir" && git rev-parse --git-path hooks 2>/dev/null)"
  [ -d .githooks ] && hd=".githooks"   # prefer repo-tracked hooks if present
  [ "$ACE_DRY_RUN" = 1 ] && { info "[dry-run] would install commit-msg + main-guard hooks in $hd"; return; }
  mkdir -p "$hd"

  cat > "$hd/commit-msg" <<'EOF'
#!/usr/bin/env bash
# Enforce Conventional Commits: type(scope)!: subject
msg="$(head -1 "$1")"
re='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9._-]+\))?!?: .{1,}'
[[ "$msg" =~ $re ]] && exit 0
# allow merge/revert/release commits
[[ "$msg" =~ ^(Merge|Revert|Release) ]] && exit 0
echo "✗ commit message must be Conventional: type(scope): summary" >&2
echo "  e.g. feat(auth): add google login   |   fix(ci): pin pnpm" >&2
exit 1
EOF
  chmod +x "$hd/commit-msg"

  # main-guard: refuse direct commits on main (use a feature branch + PR)
  if [ -f "$hd/pre-commit" ] && ! grep -q 'ace:main-guard' "$hd/pre-commit"; then
    local tmp; tmp="$(mktemp)"
    {
      head -1 "$hd/pre-commit"
      cat <<'EOF'
# ace:main-guard — never commit straight to the integration branch
b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ "$b" = "main" ]; then
  echo "✗ direct commits to main are blocked. Work on feat/<slug> and open a PR." >&2
  echo "  git switch -c feat/<slug>" >&2
  exit 1
fi
EOF
      tail -n +2 "$hd/pre-commit"
    } > "$tmp" && mv "$tmp" "$hd/pre-commit" && chmod +x "$hd/pre-commit"
  fi
  run git config core.hooksPath "$hd"
  ok "hooks: commit-msg (conventional) + main-guard installed"
}
