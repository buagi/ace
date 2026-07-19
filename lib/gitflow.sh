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
  # 'build-test' check, so 'required_status_checks' would block EVERY merge forever (the check never reports).
  # The PROFILE is authoritative here — do NOT re-derive "there is CI" from the mere presence of a workflow file:
  # a brownfield repo (or a user-added CodeQL/Dependabot/release yml) has workflows that never emit 'build-test',
  # which would silently re-impose an unsatisfiable check on a ci_cd:none project. Gate purely on ci_cd.
  local cicd checks_rule="" checkmsg=""
  cicd="$(sed -n 's/^[[:space:]]*ci_cd:[[:space:]]*\([^ #]*\).*/\1/p' .opencode/profile.yaml 2>/dev/null | head -1)"
  # No profile (brownfield, pre-scaffold) + a real ACE ci.yml present → treat as github-actions so the check is kept.
  [ -z "$cicd" ] && [ -f .github/workflows/ci.yml ] && grep -q 'build-test' .github/workflows/ci.yml 2>/dev/null && cicd=github-actions
  if [ "$cicd" = github-actions ]; then
    checks_rule=',
    { "type":"required_status_checks", "parameters":{ "strict_required_status_checks_policy":true, "required_status_checks":[ { "context":"build-test" } ] } }'
    checkmsg=" + 'build-test' must pass"
  fi
  step "Branch protection on main ($slug)${checkmsg:+ (CI-gated)}${checkmsg:- (local gate — no required CI check)}"
  if [ "$ACE_DRY_RUN" = 1 ]; then info "[dry-run] would create a ruleset: PR required${checkmsg}"; return 0; fi
  # bypass_actors: a RULESET (unlike classic branch protection) is NOT bypassed by `gh pr merge --admin` alone —
  # the merging actor must be listed here or the merge is BLOCKED even for an admin. Add THIS gh identity (the
  # account the loop merges as) so the automation can land PRs the ruleset would otherwise block (e.g. a required
  # check still pending under merge_gate=local, or the coordinator's chore/plan PR). Without this, merges wedge
  # forever — the exact failure #41's `--admin` did NOT fix. (bypass_mode:always; tighten to "pull_request" only —
  # PR-merges but not direct pushes — if you never need the loop to force-sync main.)
  local uid bypass=""
  uid="$(gh api user -q .id 2>/dev/null)"
  if [ -n "$uid" ] && printf '%s' "$uid" | grep -qE '^[0-9]+$'; then
    bypass="\"bypass_actors\":[ { \"actor_id\":$uid, \"actor_type\":\"User\", \"bypass_mode\":\"always\" } ],"
  elif [ -n "$checkmsg" ]; then
    warn "could not resolve gh user id — ruleset will have NO bypass; a required check may block --admin merges."
  fi
  local tmp out rc; tmp="$(mktmp)/ruleset.json"
  cat > "$tmp" <<JSON
{ "name":"ace: protect main", "target":"branch", "enforcement":"active",
  ${bypass}
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
    # RECONCILE: a ruleset from an older ACE may LACK bypass_actors (→ --admin can't merge) or carry a now-wrong
    # required check. PUT our current definition over it so an upgraded repo SELF-HEALS instead of staying wedged.
    local rid perr; rid="$(gh api "repos/$slug/rulesets" -q '.[] | select(.name=="ace: protect main") | .id' 2>/dev/null | head -1)"
    # UI-012/PW-7: `${checkmsg:- …}` ALREADY expands to $checkmsg when it is set — the extra ${checkmsg}
    # printed the CI clause twice. Same paired idiom as the step line above, single expansion.
    if [ -z "$rid" ]; then
      warn "A ruleset named 'ace: protect main' exists but its id could not be read — its bypass_actors cannot be verified, so an --admin merge may be BLOCKED."
      say  "  ${C_GREY}$out${C_RESET}"
    elif perr="$(gh api -X PUT "repos/$slug/rulesets/$rid" --input "$tmp" 2>&1)"; then
      ok "main protection reconciled (ruleset #$rid: bypass${checkmsg:- + no required check})."
    else
      # UI-006: a FAILED reconcile used to report `ok "main is already protected"`. That hides the exact
      # wedge this reconcile exists to clear — a legacy ruleset WITHOUT bypass_actors blocks even
      # `gh pr merge --admin`, so the loop stalls forever on a green PR while ACE claims success.
      warn "main IS protected (ruleset #$rid) but could NOT be reconciled — if it predates bypass_actors, '--admin' merges will wedge."
      say  "  ${C_GREY}$perr${C_RESET}"
      say  "  ${C_GREY}Fix: GitHub → Settings → Rules → 'ace: protect main' → add yourself to bypass list, or delete the ruleset and re-run.${C_RESET}"
    fi
  # PW-6: anchor the plan-limit test. The old unanchored 'Pro|upgrade|payment|403' matched the words
  # "protection"/"protected"/"Improve" in ANY generic API error, so permission/validation failures were
  # reported as "you need GitHub Pro" and the real $out was thrown away.
  elif printf '%s' "$out" | grep -qiE 'upgrade to github|github pro|payment required|plan.*not.*support|HTTP 403'; then
    warn "GitHub blocked it: rulesets/branch-protection need GitHub Pro on PRIVATE repos (or the token lacks admin scope)."
    say  "  ${C_GREY}$out${C_RESET}"
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
  dir="$(cd "$dir" 2>/dev/null && pwd)" || { err "not a directory: $1"; return 1; }
  # Resolve the hooks dir ABSOLUTELY. `git rev-parse --git-path hooks` prints a path relative to the
  # repo it runs in, but the `cd` happens inside a command-substitution SUBSHELL — so the caller then
  # wrote ".git/hooks" relative to ITS OWN cwd and installed the hooks (and core.hooksPath) into
  # whatever repo the operator was standing in, never into $dir. Same for the bare `[ -d .githooks ]`.
  hd="$(cd "$dir" && git rev-parse --git-path hooks 2>/dev/null)"
  hd="${hd:-.git/hooks}"   # keep RELATIVE: git resolves core.hooksPath against the worktree top, so
                           # ".git/hooks" survives a `mv` of the project dir while an absolute path
                           # silently stops matching and disables the main-guard entirely.
  [ -d "$dir/.githooks" ] && hd="$dir/.githooks"   # prefer repo-tracked hooks if present
  local _gf_msg=0 _gf_guard=0
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
  chmod +x "$hd/commit-msg" && _gf_msg=1 || warn "could not install $hd/commit-msg"


  # main-guard: refuse direct commits on main (use a feature branch + PR)
  local guard
  guard=$(cat <<'EOF'
# ace:main-guard — never commit straight to the integration branch
b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ "$b" = "main" ]; then
  echo "✗ direct commits to main are blocked. Work on feat/<slug> and open a PR." >&2
  echo "  git switch -c feat/<slug>" >&2
  exit 1
fi
EOF
)
  if [ ! -f "$hd/pre-commit" ]; then
    # PW-5/SC-02: the guard used to be PREPENDED only when a pre-commit already existed, yet the
    # "main-guard installed" line below printed unconditionally — on any repo without a pre-commit
    # (every brownfield / non-ACE repo reached via `ace gitflow` or the menu) ACE claimed a guard it
    # had never written, and direct commits to main sailed through. Write a standalone hook instead.
    { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$guard"; } > "$hd/pre-commit" \
      && chmod +x "$hd/pre-commit" && _gf_guard=1 || warn "could not write $hd/pre-commit — main-guard NOT installed"
  elif ! grep -q 'ace:main-guard' "$hd/pre-commit"; then
    local tmp; tmp="$(mktemp)"
    # keep the existing hook's shebang first, then the guard, then the rest of the original hook
    { head -1 "$hd/pre-commit"; printf '%s\n' "$guard"; tail -n +2 "$hd/pre-commit"; } > "$tmp" \
      && mv "$tmp" "$hd/pre-commit" && chmod +x "$hd/pre-commit" \
      && _gf_guard=1 || { rm -f "$tmp"; warn "could not update $hd/pre-commit — main-guard NOT installed"; }
  fi
  # -C "$dir" for the same reason: without it the hooksPath was written to the CALLER's repo config.
  run git -C "$dir" config core.hooksPath "$hd"
  # Only claim what actually landed. Printing "installed" unconditionally is the same fail-open this
  # function was fixed for: a read-only hooks dir left NO pre-commit while still reporting success.
  if [ "${_gf_msg:-0}" = 1 ] && [ "${_gf_guard:-0}" = 1 ]; then
    ok "hooks: commit-msg (conventional) + main-guard installed in $hd"
  else
    warn "hooks PARTIALLY installed in $hd (commit-msg=${_gf_msg:-0} main-guard=${_gf_guard:-0}) — commits to main are NOT blocked"
    return 1
  fi
}
