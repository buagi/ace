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
.serena/cache/
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
# SAFETY: only ever untracks paths under .opencode/ that are ALSO ignored — it will
# never touch a file the user force-added, and never touches .opencode/specs/ (tracked by design).
ace_repo_hygiene() {
  _con_in_repo || return 0
  ensure_ace_ignores >/dev/null 2>&1 || true
  local f n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in .opencode/*) ;; *) continue ;; esac   # .opencode ONLY — .serena/memories/** is user content, not a transient
    git check-ignore -q --no-index -- "$f" 2>/dev/null || continue   # --no-index: a TRACKED path is never "ignored" without it
    git rm --cached --quiet -- "$f" 2>/dev/null && n=$((n+1))
  done < <(git ls-files -- .opencode 2>/dev/null)
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

# _con_opencode_dbs — the EXACT set of opencode sqlite stores that `ace consistency fix` will size-cap.
# ONE enumerator, shared by the read-only CHECK and the destructive FIX. They used to each keep their own
# list: the check looked at the default store only, while the fix ALSO deleted every per-worker swarm db
# under ~/.config/ace/swarm/ — so `ace consistency` previewed one file and `ace consistency fix` deleted N.
# A user approved a deletion they were never shown. Add a new store HERE, once, or the preview goes stale
# again. Emits absolute paths, one per line; callers do their own -f test (an absent store is a no-op for
# both sides). Nothing is filtered by size here — that is the caller's job, using _con_db_mb below.
_con_opencode_dbs(){
  local d
  printf '%s\n' "$HOME/.local/share/opencode/opencode.db"
  # per-worker swarm stores are REUSED (appended to) across runs, so they grow unboundedly
  for d in "$HOME"/.config/ace/swarm/*/*.opencode.db; do [ -f "$d" ] && printf '%s\n' "$d"; done
  return 0
}
# _con_db_mb — size of one db in MB, by the SAME measurement the fix uses to decide. Shared for the same
# reason as the enumerator: if the preview measured differently from the fix, it could show "142MB, safe"
# for a file the fix then deletes. An unreadable db reports 0, which means the check calls it safe AND the
# fix leaves it alone — the two stay in agreement, and the failure direction is "never delete", not
# "delete unannounced". A store we cannot size is never destroyed on the strength of a guess.
_con_db_mb(){ local m; m="$(du -sm "$1" 2>/dev/null | cut -f1)"; printf '%s' "${m:-0}"; }

# con_check_opencode — READ-ONLY PREVIEW of a destructive operation. Its contract is not "is the default db
# big" but "name every file `fix` would delete", because that report is the only thing the user sees before
# approving. It therefore walks _con_opencode_dbs (all of them) and reproduces the fix's own guards.
con_check_opencode(){
  local db mb n=0 over=0 tot=0 over_list=""
  while IFS= read -r db; do
    [ -n "$db" ] && [ -f "$db" ] || continue
    n=$((n+1)); mb="$(_con_db_mb "$db")"; tot=$((tot+mb))
    [ "$mb" -ge "$ACE_OPENCODE_DB_MAX_MB" ] || continue
    over=$((over+1)); over_list="${over_list}
             · ${db} (${mb}MB, plus its -wal/-shm)"
  done < <(_con_opencode_dbs)
  [ "$n" -gt 0 ] || { ok "opencode   no session db present (recreated fresh on next run)"; return 0; }
  if [ "$over" -gt 0 ]; then
    # Mirror _con_reset_db_if_big's fail-closed live-process guard, or the preview promises a deletion that
    # `fix` will decline to perform — an inaccurate preview in the harmless direction is still inaccurate.
    if pgrep -x opencode >/dev/null 2>&1; then
      warn "opencode   ${over}/${n} session db(s) ≥ ${ACE_OPENCODE_DB_MAX_MB}MB, but opencode is RUNNING — 'fix' will SKIP them (fail-closed):${over_list}"
    else
      warn "opencode   ${over}/${n} session db(s) ≥ ${ACE_OPENCODE_DB_MAX_MB}MB — 'fix' WILL DELETE (history is disposable):${over_list}"
    fi
    return 1
  fi
  ok "opencode   ${n} session db(s), ${tot}MB total (all < ${ACE_OPENCODE_DB_MAX_MB}MB)"; return 0
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
  local mb; mb="$(_con_db_mb "$db")"          # SAME measurement con_check_opencode previewed with
  [ "$mb" -ge "$ACE_OPENCODE_DB_MAX_MB" ] || return 0
  if pgrep -x opencode >/dev/null 2>&1; then
    warn "opencode: $(basename "$db") ${mb}MB over threshold but opencode is running — skipping reset (fail-closed)"; return 0; fi
  rm -f "$db" "$db-wal" "$db-shm" && ok "opencode: $(basename "$db") was ${mb}MB ≥ ${ACE_OPENCODE_DB_MAX_MB}MB — reset (history is disposable; recreates fresh)"
}
# E4: each swarm worker keeps its OWN opencode.db under ~/.config/ace/swarm/<proj>/, REUSED (appended to)
# across runs → it grows unboundedly and was never capped (only the default store was). The set of stores
# lives in _con_opencode_dbs so that con_check_opencode previews EXACTLY this loop — see the note there.
_con_fix_opencode(){
  local d
  # `continue` rather than `[ -n "$d" ] && …`, so a blank line cannot make the loop — and therefore this
  # function — return a misleading non-zero rc that has nothing to do with any reset having failed.
  while IFS= read -r d; do [ -n "$d" ] || continue; _con_reset_db_if_big "$d"; done < <(_con_opencode_dbs)
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

# ---------------------------------------------------------------------------------------------------
# firecrawl_url / firecrawl_probe — the ONE endpoint resolution + ONE reachability probe (D2).
#
# THE DEFECT THIS REPLACES: firecrawl_ensure resolved `${FIRECRAWL_API_URL:-http://127.0.0.1:$port}`
# while `_fc_up` in lib/install.sh (behind `ace firecrawl status`) hardcoded `http://127.0.0.1:$port`
# and IGNORED FIRECRAWL_API_URL entirely. With a self-hosted crawler on any non-default endpoint the two
# DISAGREED: ensure enabled the MCP saying "UP", status said "DOWN" — and ensure's own degraded-path
# message points the user at `ace firecrawl status`, the one command guaranteed to contradict it.
#
# Endpoint resolution matches firecrawl_mode (lib/core.sh): it goes through firecrawl_secret, so a URL
# saved in secrets.env by `ace firecrawl up` is honoured in a headless run that never sourced ~/.bashrc,
# and empty-but-set / whitespace-only is treated as UNSET (same rule that keeps a cloud key from being
# shadowed). Falling back to the loopback default only when nothing is configured.
firecrawl_url() {
  local u
  if declare -F firecrawl_secret >/dev/null 2>&1; then
    u="$(firecrawl_secret FIRECRAWL_API_URL)"
  else
    u="$(printf '%s' "${FIRECRAWL_API_URL:-}" | tr -d '[:space:]')"   # core.sh absent: same strip rule
  fi
  [ -n "$u" ] || u="http://127.0.0.1:${FIRECRAWL_PORT:-3002}"
  printf '%s' "${u%/}"
}
# firecrawl_probe [url] [timeout] — reachable? Defaults to the resolved endpoint above; callers pass an
# explicit url ONLY when they mean a different question (install.sh's `up` waits on the container it just
# started, which is a local-port question, not a "which backend will ACE use" question).
firecrawl_probe() {
  local u="${1:-}"
  [ -n "$u" ] || u="$(firecrawl_url)"
  curl -fsS -m "${2:-2}" "${u%/}/" >/dev/null 2>&1
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

# ---------------------------------------------------------------------------------------------------
# firecrawl_ensure — bring the LOCAL research crawler up at run start, and make the MCP actually usable.
#
# WHY THIS EXISTS: the enable/disable decision was frozen at `ace opencode` time. write_opencode_config
# probes 127.0.0.1:3002 and writes `mcp.firecrawl.enabled=false` when nothing answers -- correct in itself
# (a dead MCP server makes opencode fail to start it on EVERY launch), but the flag then never changed
# again. So `ace firecrawl up` AFTER `ace opencode` left the container running and the MCP still disabled,
# and a run silently fell back to single-URL webfetch. Observed live: a full re-analysis pass produced 16
# citations, every one an in-repo file reference, and ZERO web research -- while nothing said so.
#
# Two halves, and BOTH are required:
#   1. start the container if it is down (FIRECRAWL_AUTO=1, the default -- set 0 to opt out)
#   2. flip mcp.firecrawl.enabled in the LIVE config to match reality, BEFORE opencode launches
#
# FAIL-OPEN BY DESIGN, LOUDLY (C1/C3): no compose dir, no container engine, or a crawler that will not
# answer must DEGRADE research to webfetch, never block the run. But it must SAY which one you got --
# the silent fallback is the whole defect being fixed here.
firecrawl_ensure() {
  local port url cfg n started=0 was_enabled
  port="${FIRECRAWL_PORT:-3002}"
  url="$(firecrawl_url)"                       # D2: the SAME resolution `ace firecrawl status` uses
  cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json"
  _fce_up() { firecrawl_probe; }               # D2: the SAME probe `ace firecrawl status` uses

  # No config = nothing to flip; opencode is not wired here at all.
  [ -f "$cfg" ] || return 0
  command -v jq >/dev/null 2>&1 || { say "research: cannot check the Firecrawl MCP (jq missing) — leaving the config untouched."; return 0; }
  # NOT `.mcp.firecrawl.enabled // "absent"` -- jq's // treats FALSE as empty exactly like null, so a config
  # with enabled:false (the precise case this function exists to repair) read back as "absent" and the whole
  # feature returned early doing nothing. Descend on has() and stringify. Same absent-vs-false trap that bit
  # lib/merge-structured.sh; caught here only because the selftest asserted the enabled:false path.
  was_enabled="$(jq -r 'if (.mcp|type)=="object" and (.mcp|has("firecrawl")) and (.mcp.firecrawl|type)=="object" and (.mcp.firecrawl|has("enabled")) then (.mcp.firecrawl.enabled|tostring) else "absent" end' "$cfg" 2>/dev/null)"
  [ "$was_enabled" = absent ] && return 0        # this install does not carry the firecrawl MCP at all

  # MODE FIRST (firecrawl_mode, lib/core.sh). Without this, a CLOUD user got the self-hosted path: a probe
  # of a loopback port nothing listens on, then a pointless attempt to start a container, then a WRONG
  # "research falls back to webfetch" line while the cloud key was working perfectly.
  local _mode; _mode="$(firecrawl_mode 2>/dev/null || echo none)"
  if [ "$_mode" = cloud ]; then
    if [ "$was_enabled" = true ]; then
      say "research: Firecrawl CLOUD (Fire-engine: anti-bot + IP rotation) — MCP already enabled."
    else
      _fce_set true "$cfg" \
        && say "research: Firecrawl CLOUD (Fire-engine: anti-bot + IP rotation) — MCP ENABLED for this run." \
        || say "research: Firecrawl CLOUD key present but the MCP could not be enabled (config write failed) — falling back to webfetch."
    fi
    return 0
  fi
  if [ "$_mode" = none ]; then
    _fce_set false "$cfg"
    say "research: NO Firecrawl backend (no FIRECRAWL_API_KEY, no self-hosted URL) — webfetch only: single URL, no JS render, no search. Set a key with 'ace keys'."
    return 0
  fi

  # LOCAL from here down. When BOTH a cloud key and a self-hosted URL are set the URL wins (that is what
  # firecrawl-mcp itself does) — SAY it, or a paid cloud key is silently bypassed by a stale URL and the
  # run looks identical to a cloud run that simply degraded. core.sh's firecrawl_mode header promises the
  # callers narrate this case; this is the caller that has to keep the promise.
  if declare -F firecrawl_secret >/dev/null 2>&1 && [ -n "$(firecrawl_secret FIRECRAWL_API_KEY)" ]; then
    say "research: Firecrawl LOCAL (self-hosted $url) — BOTH a CLOUD key and a self-hosted URL are set; the URL WINS (firecrawl-mcp's own rule) and the cloud key is NOT used. Unset FIRECRAWL_API_URL to use the cloud."
  fi

  if ! _fce_up; then
    if [ "${FIRECRAWL_AUTO:-1}" != 1 ]; then
      say "research: Firecrawl DOWN and FIRECRAWL_AUTO=0 — research falls back to webfetch (single URL, no search+scrape)."
      _fce_set false "$cfg"; return 0
    fi
    local dir; dir="${FIRECRAWL_DIR:-$HOME/firecrawl}"
    if ! { [ -f "$dir/docker-compose.yaml" ] || [ -f "$dir/docker-compose.yml" ]; }; then
      say "research: no Firecrawl compose in $dir — research falls back to webfetch. ('ace firecrawl up' after self-hosting it.)"
      _fce_set false "$cfg"; return 0
    fi
    if ! { command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; }; then
      say "research: no podman/docker — research falls back to webfetch."
      _fce_set false "$cfg"; return 0
    fi
    say "research: Firecrawl is down — starting it (loopback-only, no cloud key). This takes ~10-30s…"
    # `set --` before sourcing: install.sh is a lib, but a command substitution/function scope inherits the
    # caller's positional parameters, and a lib that grows a `case "${1:-}"` dispatcher would then execute
    # an arbitrary arm. Cheap insurance against a real trap (A13).
    ( set --; . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" >/dev/null 2>&1; firecrawl_cmd up ) >/dev/null 2>&1 || true
    for n in $(seq 1 20); do _fce_up && { started=1; break; }; sleep 1.5; done
    if [ "$started" != 1 ]; then
      say "research: Firecrawl did NOT come up within 30s — research falls back to webfetch (run is NOT blocked). Check: ace firecrawl status"
      _fce_set false "$cfg"; return 0
    fi
  fi

  # Reachable. Make the live config agree — this is the half that was missing.
  if [ "$was_enabled" = true ]; then
    say "research: Firecrawl LOCAL (self-hosted) UP ($url) — MCP already enabled."
  else
    _fce_set true "$cfg" \
      && say "research: Firecrawl LOCAL (self-hosted) UP ($url) — MCP ENABLED for this run (was disabled; no 'ace opencode' needed)." \
      || say "research: Firecrawl LOCAL (self-hosted) UP but the MCP could not be enabled (config write failed) — falling back to webfetch."
  fi
  return 0
}

# _fce_set <true|false> <cfg> — flip mcp.firecrawl.enabled, atomically. Never leaves a truncated config:
# a half-written opencode.json breaks every agent, which is far worse than the wrong research backend.
# The atomicity + metadata preservation live in _ace_json_edit (below), shared with lib/install.sh.
_fce_set() {
  local want="$1" cfg="$2" cur
  cur="$(jq -r 'if (.mcp|type)=="object" and (.mcp|has("firecrawl")) and (.mcp.firecrawl|type)=="object" and (.mcp.firecrawl|has("enabled")) then (.mcp.firecrawl.enabled|tostring) else "absent" end' "$cfg" 2>/dev/null)"
  [ "$cur" = "$want" ] && return 0
  _ace_json_edit "$cfg" '.mcp.firecrawl.enabled=$v' --argjson v "$want"
}

# _ace_clone_meta <src> <dst> — give <dst> the mode + ownership of <src>, so replacing <src> with <dst>
# does not silently re-permission the user's file.
_ace_clone_meta() {
  local m
  chmod --reference="$1" "$2" 2>/dev/null || {
    m="$(stat -c %a "$1" 2>/dev/null)"
    [ -n "$m" ] && chmod "$m" "$2" 2>/dev/null
  } || true
  chown --reference="$1" "$2" 2>/dev/null || true
  return 0
}

# _ace_json_edit <file> <jq-filter> [jq-args…] — apply a jq filter to a JSON file IN PLACE, atomically,
# without changing its mode or owner. The ONE writer for every generated-config flip (opencode.json).
#
# WHY THE TEMP FILE MUST BE A SIBLING (D1): a bare `mktemp` lands in $TMPDIR, which is routinely a
# DIFFERENT filesystem (tmpfs) from ~/.config. `mv` across filesystems is not rename(2) — it is
# copy-then-unlink, so a crash or ENOSPC mid-copy leaves exactly the truncated opencode.json the old
# comment here promised could not happen. A sibling temp makes `mv` a real rename: the target is either
# the whole old file or the whole new one, never a prefix of either.
#
# WHY THE MODE IS CLONED (D1): `mktemp` creates 0600 by design, and `mv` carries that mode onto the
# destination — so every flip silently tightened a 0644 opencode.json to 0600. Measured, not theorised.
# Same pattern as lib/core.sh's `mktemp "$ACE_LESSONS_SHARED.XXXXXX"`.
#
# Fails CLOSED: on any error the ORIGINAL file is left byte-identical and the temp is removed.
_ace_json_edit() {
  local f="$1" filter="$2"; shift 2
  local tmp
  [ -f "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$f.XXXXXX")" || return 1     # SIBLING of the target — see above
  _ace_clone_meta "$f" "$tmp"
  jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  jq -e . "$tmp" >/dev/null 2>&1             || { rm -f "$tmp"; return 1; }   # never install unparseable JSON
  mv -f "$tmp" "$f" 2>/dev/null              || { rm -f "$tmp"; return 1; }
}
