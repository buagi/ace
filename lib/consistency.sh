#!/usr/bin/env bash
# consistency.sh — drift & scope guardrails.
#
# Keeps four things consistent + bounded, on demand (`ace consistency [fix]`) and from the loop
# (preflight assertion + per-iteration janitor):
#   1. git        — local `main` ↔ `origin/main` (no silent drift; loop never commits to main)
#   2. gitnexus   — graph fresh vs code; per-branch graphs pruned for deleted branches (no bloat)
#   3. opencode   — session DB bounded (resets above a size threshold; history is disposable)
#   4. podman     — dangling images + build-scratch containers reclaimed
# (architecture.md freshness is already enforced by ci.sh + the per-task graph-refresh, so it is
#  reported informationally here, not mutated — avoids uncommitted churn.)
#
# Each check is read-only and fail-soft; `fix` is idempotent and fails CLOSED on anything risky
# (never destroys unpushed local commits; never prunes opencode/podman while they're in use).

# ---- thresholds (override via env / ace config) ----
ACE_OPENCODE_DB_MAX_MB="${ACE_OPENCODE_DB_MAX_MB:-750}"   # reset opencode.db at/above this size
ACE_GITNEXUS_WARN_MB="${ACE_GITNEXUS_WARN_MB:-1500}"      # informational warning above this

# ---- ACE-owned transient artifacts (single source of truth) --------------------------------------------
# A project adopted BEFORE a given feature landed never gets that feature's ignore line — nothing refreshed
# .gitignore on upgrade — so a new artifact dir (e.g. .opencode/reanalyze/) gets swept into the loop's
# rescue-commit. These two functions are the fix: one canonical list, and an idempotent back-fill run by
# `ace upgrade`. Add new ACE-written transients HERE and every adopted repo picks them up on next upgrade.
_ace_ignore_lines() {
  cat <<'IGN'
.serena/
.opencode/.agents
.opencode/.oppid
.opencode/.step-budget
.opencode/.timedout
.opencode/.rathole
.opencode/.container-green
.opencode/.harvested-warnings
.opencode/.objectives-synced
.opencode/last-run.log
.opencode/ci-failure.log
.opencode/ci-build.log
.opencode/loop-state.env
.opencode/metrics.csv
.opencode/run-summary.txt
.opencode/token-report.md
.opencode/quality-report.md
.opencode/.session-id
.opencode/.kanban-map
.opencode/.atlas-sig
.opencode/approvals/
.opencode/HANDOVER.md
.opencode/vps-verify-report.md
.opencode/cache/
.opencode/reanalyze/
IGN
}
# ensure_ace_ignores — append ONLY the missing rules; never rewrites or reorders the user's .gitignore.
# NOTE: .opencode/specs/ is deliberately NOT ignored — swarm worktrees read specs from git.
ensure_ace_ignores() {
  local gi=.gitignore added=0 line
  [ -f "$gi" ] || : > "$gi"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$gi" 2>/dev/null || { [ "$added" = 0 ] && printf '\n# ---- ACE loop transients (added by ace upgrade) ----\n' >> "$gi"; printf '%s\n' "$line" >> "$gi"; added=$((added+1)); }
  done < <(_ace_ignore_lines)
  if [ "$added" -gt 0 ]; then ok "gitignore: back-filled $added missing ACE transient rule(s)"; else ok "gitignore: all ACE transient rules present"; fi
}

# ace_repo_hygiene — keep the project's git state clean so a STOP/KILL never leaves ACE artifacts TRACKED.
# Runs at PREFLIGHT, deliberately BEFORE the resume-rescue `git add -A`: that rescue commits whatever is
# uncommitted, so the ignore rules must be right FIRST or a newly-added artifact dir is swept into git
# (observed live: a resume commit swallowed .opencode/cache/ AND a 151-spec .opencode/reanalyze/ baseline).
# Idempotent + fail-soft, and NOT behind the reconcile TTL — it is a couple of greps.
# SAFETY: only ever untracks paths ACE itself writes (.opencode/, .serena/) that are ALSO ignored — it will
# never touch a file the user force-added, and never touches .opencode/specs/ (tracked by design).
ace_repo_hygiene() {
  _con_in_repo || return 0
  ensure_ace_ignores >/dev/null 2>&1 || true
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in .opencode/*|.serena/*) ;; *) continue ;; esac
    git check-ignore -q --no-index -- "$f" 2>/dev/null || continue   # --no-index: a TRACKED path is never "ignored" without it
    git rm --cached --quiet -- "$f" 2>/dev/null && n=$((n+1))
  done < <(git ls-files -- .opencode .serena 2>/dev/null)
  [ "$n" -gt 0 ] || return 0
  say "hygiene — untracked $n ACE transient file(s) that a previous run swept into git (now ignored)" 2>/dev/null \
    || echo "hygiene — untracked $n ACE transient file(s) (now ignored)"
  # commit the removal ourselves when it is safe: never on main, never mid-merge/rebase
  local br; br="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$br" in main|master|HEAD) return 0 ;; esac
  [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] && return 0
  [ -f "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] && return 0
  git add -- .gitignore 2>/dev/null || true   # the back-filled rules belong in the SAME commit, else hygiene leaves its own dirt
  git commit --no-verify -q -m "chore(git): untrack $n ACE transient file(s) (now covered by .gitignore)" >/dev/null 2>&1 || true
}

_con_in_repo(){ git rev-parse --git-dir >/dev/null 2>&1; }
_con_root(){ git rev-parse --show-toplevel 2>/dev/null; }
# branch dirs are named "<branch with / -> _>-<hash>"; echo the keep-prefixes for live branches
_con_keep_prefixes(){ git -C "${1:-.}" branch --format='%(refname:short)' 2>/dev/null | sed 's#/#_#g'; }
_con_is_stale_branchdir(){ # $1=dirname $2=keep-prefixes ; return 0 if stale (no live branch)
  local n="$1" b; while IFS= read -r b; do [ -n "$b" ] && case "$n" in "$b"-*) return 1;; esac; done <<<"$2"; return 0; }

# ============================ CHECKS (read-only; drow via ok/warn/err; return 1 on drift) ============================

con_check_git(){
  _con_in_repo || { info "git        not a git repo — skipped"; return 0; }
  timeout -k 5 30 git fetch origin -q </dev/null 2>/dev/null || true
  local br dirty; br="$(git symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
  dirty="$(git status --porcelain 2>/dev/null | grep -c . || true)"
  if ! git rev-parse origin/main >/dev/null 2>&1 || ! git rev-parse main >/dev/null 2>&1; then
    warn "git        no local+origin main to compare (branch=$br, $dirty dirty)"; return 0; fi
  local lm om ahead behind
  lm="$(git rev-parse main)"; om="$(git rev-parse origin/main)"
  ahead="$(git rev-list --count origin/main..main 2>/dev/null || echo 0)"
  behind="$(git rev-list --count main..origin/main 2>/dev/null || echo 0)"
  if [ "$lm" = "$om" ]; then
    ok "git        main in sync @ $(git rev-parse --short main)  (on $br, $dirty dirty)"; return 0
  fi
  if [ "$ahead" != 0 ]; then err "git        main AHEAD of origin by $ahead (unpushed!) + behind $behind — needs review"
  else warn "git        main behind origin by $behind — will fast-forward"; fi
  return 1
}

con_check_gitnexus(){
  local root; root="$(_con_root)"
  [ -n "$root" ] && [ -d "$root/.gitnexus" ] || { info "gitnexus   no graph index — skipped"; return 0; }
  local keep stale=0 d n; keep="$(_con_keep_prefixes "$root")"
  for d in "$root"/.gitnexus/branches/*/; do [ -d "$d" ] || continue
    n="$(basename "$d")"; _con_is_stale_branchdir "$n" "$keep" && stale=$((stale+1)); done
  local st sz; st="$(CI=1 timeout -k 5 30 node "$root/.gitnexus/run.cjs" status </dev/null 2>/dev/null | grep -oiE 'up-to-date|stale' | head -1)"
  sz="$(du -sm "$root/.gitnexus" 2>/dev/null | cut -f1)"
  if [ "$st" = stale ] || [ "${stale:-0}" -gt 0 ]; then
    warn "gitnexus   ${st:-?}; ${stale} stale branch-graph(s); ${sz:-?}MB"; return 1; fi
  [ "${sz:-0}" -gt "$ACE_GITNEXUS_WARN_MB" ] && { warn "gitnexus   up-to-date but large (${sz}MB ≥ ${ACE_GITNEXUS_WARN_MB}MB)"; return 1; }
  ok "gitnexus   up-to-date, lean (${sz:-?}MB, $(ls "$root"/.gitnexus/branches 2>/dev/null | grep -c . || true) branch-graphs)"; return 0
}

con_check_arch(){ # informational only — freshness is gated by ci.sh + per-task graph-refresh
  local root; root="$(_con_root)"
  [ -n "$root" ] && [ -f "$root/docs/architecture.md" ] || return 0
  info "arch       snapshot present (freshness gated by ci.sh + per-task graph-refresh)"; return 0
}

con_check_opencode(){
  local db="$HOME/.local/share/opencode/opencode.db"
  [ -f "$db" ] || { ok "opencode   db absent (recreated fresh on next run)"; return 0; }
  local mb; mb="$(du -sm "$db" 2>/dev/null | cut -f1)"
  if [ "${mb:-0}" -ge "$ACE_OPENCODE_DB_MAX_MB" ]; then
    warn "opencode   db ${mb}MB ≥ ${ACE_OPENCODE_DB_MAX_MB}MB threshold — will reset"; return 1; fi
  ok "opencode   db ${mb:-0}MB (< ${ACE_OPENCODE_DB_MAX_MB}MB)"; return 0
}

con_check_podman(){
  command -v podman >/dev/null 2>&1 || { info "podman     not installed — skipped"; return 0; }
  local n; n="$(podman images -f dangling=true -q 2>/dev/null | grep -c . || true)"
  if [ "${n:-0}" -gt 0 ]; then warn "podman     ${n} dangling image(s) to reclaim"; return 1; fi
  ok "podman     no dangling images"; return 0
}

# ============================ REPORT ============================

consistency_report(){
  step "Consistency / drift check${1:+ — $1}"
  local drift=0
  con_check_git      || drift=$((drift+1))
  con_check_gitnexus || drift=$((drift+1))
  con_check_arch     || true
  con_check_opencode || drift=$((drift+1))
  con_check_podman   || drift=$((drift+1))
  hr
  if [ "$drift" -eq 0 ]; then ok "in scope — no drift across git / gitnexus / opencode / podman"
  else warn "$drift area(s) drifting — run 'ace consistency fix' to reconcile"; fi
  return "$drift"
}

# ============================ FIXES (idempotent; fail-closed on risk) ============================

_con_fix_git(){
  _con_in_repo || return 0
  timeout -k 5 30 git fetch --prune origin -q </dev/null 2>/dev/null || true
  # Prune local branches whose upstream was deleted on merge — squash-merge leaves them dangling locally,
  # and the GitHub web UI deletes only the REMOTE, so they pile up (esp. in repos with no loop running,
  # like ace itself). `--prune` above marks them `[gone]`; we delete those. NEVER the current branch,
  # main/master, or any never-pushed branch (those have no upstream, so they're never `[gone]`).
  local cur b gone n=0; cur="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo HEAD)"
  gone="$(git for-each-ref --format '%(refname:short) %(upstream:track)' refs/heads 2>/dev/null | awk '$2=="[gone]"{print $1}')"
  for b in $gone; do case "$b" in main|master|"$cur") : ;; *) git branch -D "$b" >/dev/null 2>&1 && n=$((n+1)) ;; esac; done
  [ "$n" -gt 0 ] && ok "git: pruned $n merged local branch(es) whose upstream was deleted"
  git rev-parse origin/main >/dev/null 2>&1 && git rev-parse main >/dev/null 2>&1 || return 0
  local lm om ahead; lm="$(git rev-parse main)"; om="$(git rev-parse origin/main)"
  [ "$lm" = "$om" ] && return 0
  ahead="$(git rev-list --count origin/main..main 2>/dev/null || echo 0)"
  if [ "$ahead" != 0 ]; then
    warn "git: local main is AHEAD of origin by $ahead (unpushed) — NOT auto-resetting; review/push manually."
    return 0
  fi
  # pure-behind → safe fast-forward of local main to origin (handles on-main and off-main)
  if [ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ]; then
    git merge --ff-only origin/main >/dev/null 2>&1 && ok "git: fast-forwarded main → origin ($(git rev-parse --short main))"
  else
    git branch -f main origin/main >/dev/null 2>&1 && ok "git: synced local main → origin ($(git rev-parse --short origin/main))"
  fi
}

_con_fix_gitnexus(){
  local root; root="$(_con_root)"; [ -n "$root" ] && [ -d "$root/.gitnexus" ] || return 0
  local keep d n pruned=0; keep="$(_con_keep_prefixes "$root")"
  for d in "$root"/.gitnexus/branches/*/; do [ -d "$d" ] || continue
    n="$(basename "$d")"; _con_is_stale_branchdir "$n" "$keep" && { rm -rf "$d"; pruned=$((pruned+1)); }; done
  [ "$pruned" -gt 0 ] && ok "gitnexus: pruned $pruned stale branch-graph(s) for deleted branches"
  if CI=1 timeout -k 5 30 node "$root/.gitnexus/run.cjs" status </dev/null 2>/dev/null | grep -qi stale; then
    ( cd "$root" && CI=1 timeout -k 10 300 node .gitnexus/run.cjs analyze </dev/null >/dev/null 2>&1 ) && ok "gitnexus: re-analyzed → fresh"
  fi
}

_con_reset_db_if_big(){   # size-cap ONE opencode sqlite db; skip while opencode is live (fail-closed)
  local db="$1"; [ -f "$db" ] || return 0
  local mb; mb="$(du -sm "$db" 2>/dev/null | cut -f1)"
  [ "${mb:-0}" -ge "$ACE_OPENCODE_DB_MAX_MB" ] || return 0
  if pgrep -x opencode >/dev/null 2>&1; then
    warn "opencode: $(basename "$db") ${mb}MB over threshold but opencode is running — skipping reset (fail-closed)"; return 0; fi
  rm -f "$db" "$db-wal" "$db-shm" && ok "opencode: $(basename "$db") was ${mb}MB ≥ ${ACE_OPENCODE_DB_MAX_MB}MB — reset (history is disposable; recreates fresh)"
}
_con_fix_opencode(){
  _con_reset_db_if_big "$HOME/.local/share/opencode/opencode.db"
  # E4: each swarm worker keeps its OWN opencode.db under ~/.config/ace/swarm/<proj>/, REUSED (appended to)
  # across runs → it grows unboundedly and was never capped (only the default store was). Cap those too.
  local d
  for d in "$HOME"/.config/ace/swarm/*/*.opencode.db; do [ -f "$d" ] && _con_reset_db_if_big "$d"; done
}

_con_fix_podman(){
  command -v podman >/dev/null 2>&1 || return 0
  # clear build-scratch (buildah) containers FIRST — only when no build is active (else it breaks the
  # build) — THEN prune, so images freed by clearing the containers are reclaimed in the same pass.
  if ! pgrep -x buildah >/dev/null 2>&1 && ! pgrep -f 'podman build' >/dev/null 2>&1; then
    buildah rm --all >/dev/null 2>&1 || true
  fi
  podman image prune -f >/dev/null 2>&1 || true          # dangling-only: safe even mid-build (in-use layers kept)
}

consistency_fix(){
  local quiet="${1:-}"
  [ "$quiet" = quiet ] || step "Consistency / janitor — reconciling"
  _con_fix_git
  _con_fix_gitnexus
  _con_fix_opencode
  _con_fix_podman
  [ "$quiet" = quiet ] || ok "reconciled."
}

# ============================ DISPATCH ============================

consistency_cmd(){
  case "${ACE_ARG:-}" in
    fix|--fix|reconcile) consistency_fix ;;
    *)                   consistency_report ;;
  esac
}
