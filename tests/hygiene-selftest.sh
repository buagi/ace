#!/usr/bin/env bash
# hygiene-selftest.sh — ace_repo_hygiene must (a) back-fill missing ACE ignore rules, (b) untrack ACE transients
# a previous run swept into git, (c) NEVER untrack .opencode/specs/ (worktrees read specs from git), (d) leave a
# CLEAN tree, (e) be idempotent. Guards the exact failure seen live: a resume-commit swallowing .opencode/cache/
# plus a 151-spec .opencode/reanalyze/ baseline. Hermetic: temp repo, no network.
#
# PARAMETERISED OVER GIT STATE. The untrack half of ace_repo_hygiene runs unconditionally, but the COMMIT half
# is gated by four guards (consistency.sh:88-90) that exist because committing in the wrong state is
# destructive in a way the loop cannot undo: a commit on main bypasses review entirely, and a commit while
# MERGE_HEAD / rebase-merge is live either finalises somebody elses half-finished merge or derails the rebase.
# For a long time this file only ever exercised feat/x, so every one of those four guards was unverified —
# delete any of them and the suite still went green. Each state below now asserts the guard HOLDS, by the only
# observable that matters: the commit count must not move.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0

# _fixture <dir> — a repo on feat/x whose HEAD commit wrongly TRACKS ACE transients (the live failure), plus
# real user content that must survive, plus a conflict.txt used to drive the merge/rebase states.
_fixture() {
  local r="$1"; mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" checkout -qb feat/x
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  git -C "$r" config commit.gpgsign false      # never touch the developers signing setup
  printf '.env\n.opencode/cache/versions.json\n' > "$r/.gitignore"   # stale rules: pre-date cache/ + reanalyze/
  mkdir -p "$r/.opencode/specs" "$r/.opencode/cache" "$r/.opencode/reanalyze/before/specs"
  echo spec       > "$r/.opencode/specs/real.md"
  echo transcript > "$r/.opencode/cache/spec-debate-x.md"
  echo baseline   > "$r/.opencode/reanalyze/before/specs/old.md"
  mkdir -p "$r/.serena/memories/specs"                               # user CONTENT, deliberately tracked
  echo handover > "$r/.serena/memories/handover.md"
  echo phase1   > "$r/.serena/memories/specs/phase-1.md"
  echo base     > "$r/conflict.txt"
  git -C "$r" add -A && git -C "$r" commit -qm "artifacts wrongly swept in" >/dev/null
}

# _state <dir> <state> — put the fixture repo into the git state under test. Echoes nothing; rc 1 if the
# state could not be established (never silently degrade to "feat/x" — that would test nothing and pass).
#
# SANDBOX RULE: resolve the git dir ABSOLUTELY and refuse to proceed unless it lives inside $r. `git rev-parse
# --git-path` returns a path relative to the CURRENT directory, not to -C, so an earlier version of this file
# did `mkdir -p "$(git -C "$r" rev-parse --git-path rebase-merge)"` and created .git/rebase-merge in whatever
# repo the test was launched from — convincing that real repo it was mid-rebase. A test that fabricates git
# states must never be able to address a repo it did not create.
_state() {
  local r="$1" s="$2" gd
  gd="$(git -C "$r" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  case "$gd" in "$r"/*) ;; *) echo "[hygiene] REFUSING: git dir '$gd' is outside the sandbox '$r'" >&2; return 1 ;; esac
  case "$s" in
    feat) : ;;                                            # ordinary feature branch: the one state ever tested before
    main) git -C "$r" branch -qm feat/x main ;;           # protected branch — the loop must never commit here
    detached) git -C "$r" checkout -q --detach ;;         # rev-parse --abbrev-ref reports "HEAD"
    merge)
      # a REAL mid-merge: --no-commit --no-ff leaves MERGE_HEAD set on a still-named branch, which is what
      # isolates the MERGE_HEAD guard from the branch-name guard above it.
      git -C "$r" branch -q other
      git -C "$r" checkout -q other && echo other > "$r/conflict.txt" \
        && git -C "$r" commit -qam other >/dev/null
      git -C "$r" checkout -q feat/x
      git -C "$r" merge --no-commit --no-ff other >/dev/null 2>&1
      [ -f "$gd/MERGE_HEAD" ] || return 1
      ;;
    rebase)
      # a REAL conflicted rebase. NOTE: git detaches HEAD for the duration, so consistency.sh:88 (the "HEAD"
      # arm) fires BEFORE the rebase-merge test at :89 — this state proves the end-to-end contract (no commit
      # mid-rebase) but cannot on its own prove :89 is load-bearing. The rebase-dir state below does that.
      git -C "$r" branch -q other
      git -C "$r" checkout -q other && echo other > "$r/conflict.txt" \
        && git -C "$r" commit -qam other >/dev/null
      git -C "$r" checkout -q feat/x && echo feat > "$r/conflict.txt" \
        && git -C "$r" commit -qam feat >/dev/null
      git -C "$r" rebase other >/dev/null 2>&1
      [ -d "$gd/rebase-merge" ] || return 1
      ;;
    rebase-dir)
      # synthetic, and deliberately so: a rebase-merge dir on a NAMED branch is the only way to reach line 89
      # with line 88 not already returning. Delete that line and this is the state that goes red.
      mkdir -p "$gd/rebase-merge" || return 1
      ;;
    *) return 1 ;;
  esac
  return 0
}

# _check <state> <may-commit:yes|no> — run ace_repo_hygiene once in that state and assert the contract.
_check() {
  local st="$1" may="$2" d
  d="$(mktemp -d)" || { echo "[hygiene/$st] mktemp failed"; return 1; }
  (
    set -uo pipefail
    ok=1; bad(){ echo "[hygiene/$st] $*"; ok=0; }
    _fixture "$d" || { bad "fixture setup failed"; exit 1; }
    _state "$d" "$st" || { bad "could not establish git state '$st' — NOT falling back to a state that would pass vacuously"; exit 1; }
    cd "$d" || { bad "cd failed"; exit 1; }
    . "$ROOT/lib/core.sh" 2>/dev/null; . "$ROOT/lib/ui.sh" 2>/dev/null; . "$ROOT/lib/consistency.sh"

    local before after
    before="$(git log --oneline | wc -l)"
    ace_repo_hygiene >/dev/null 2>&1
    after="$(git log --oneline | wc -l)"

    # --- state-independent: the untrack half always runs, and never destroys anything ---
    [ "$(git ls-files | grep -cE '\.opencode/(cache|reanalyze)/')" = 0 ] || bad "transients still tracked"
    [ "$(git ls-files | grep -c '\.opencode/specs/')" = 1 ]              || bad ".opencode/specs/ must stay tracked"
    [ -f .opencode/cache/spec-debate-x.md ]                              || bad "untrack must keep files on disk"
    [ -f .opencode/reanalyze/before/specs/old.md ]                       || bad "untrack must keep the reanalyze baseline on disk"
    grep -qx '.opencode/reanalyze/' .gitignore                           || bad "reanalyze rule not back-filled"
    [ "$(git ls-files | grep -c '^\.serena/memories/')" = 2 ]            || bad ".serena/memories/** must stay tracked (user content, not a transient)"
    grep -qx '.serena/' .gitignore                                       && bad "canonical list must NOT blanket-ignore .serena/ (only .serena/cache/)"

    # --- the guards: did it commit, and was it allowed to? ---
    if [ "$may" = yes ]; then
      [ "$after" -gt "$before" ] || bad "expected hygiene to commit the untrack on an ordinary branch, but the commit count did not move"
      [ -z "$(git status --porcelain)" ] || bad "hygiene left a dirty tree"
      # idempotent: a second pass must be a no-op
      before="$after"; ace_repo_hygiene >/dev/null 2>&1
      [ "$(git log --oneline | wc -l)" = "$before" ] || bad "not idempotent (committed twice)"
    else
      [ "$after" = "$before" ] || bad "GUARD BREACHED — hygiene committed in state '$st' ($before → $after commits)"
    fi
    [ "$ok" = 1 ]
  )
  local rc=$?
  rm -rf "$d"
  return "$rc"
}

for spec in feat:yes main:no detached:no merge:no rebase:no rebase-dir:no; do
  _check "${spec%%:*}" "${spec##*:}" || fails=$((fails+1))
done

# ---- con_check_opencode is a PREVIEW of a destructive fix: it must name every db `fix` would delete -------
# _con_fix_opencode size-caps the default store AND every per-worker swarm store, but the check only ever
# looked at the default one — so `ace consistency` showed one file and `ace consistency fix` deleted several.
# Hermetic: a fake HOME with two oversized dbs, threshold lowered to 1MB, and the report is read-only.
(
  set -uo pipefail
  ok=1; bad(){ echo "[hygiene/preview] $*"; ok=0; }
  h="$(mktemp -d)" || exit 1
  trap 'rm -rf "$h"' EXIT
  mkdir -p "$h/.local/share/opencode" "$h/.config/ace/swarm/projA"
  dd if=/dev/zero of="$h/.local/share/opencode/opencode.db"     bs=1M count=3 status=none 2>/dev/null
  dd if=/dev/zero of="$h/.config/ace/swarm/projA/w1.opencode.db" bs=1M count=3 status=none 2>/dev/null
  # verify BOTH fixtures landed — a silently-empty dd would size to 0MB, drop under the threshold, and make
  # the "2/2 over threshold" assertion below fail for a reason that has nothing to do with the code under test
  for _db in "$h/.local/share/opencode/opencode.db" "$h/.config/ace/swarm/projA/w1.opencode.db"; do
    [ -s "$_db" ] || { bad "could not build the oversized-db fixture: $_db"; exit 1; }
  done
  # core.sh installs its OWN `trap cleanup EXIT` at source time, which silently REPLACES the `rm -rf "$h"`
  # trap set above — so this fixture (a multi-MB fake HOME) leaked one temp dir per run. Re-install ours
  # after sourcing, chaining core's cleanup so we do not disable that either.
  . "$ROOT/lib/core.sh" 2>/dev/null; . "$ROOT/lib/ui.sh" 2>/dev/null; . "$ROOT/lib/consistency.sh"
  trap 'cleanup 2>/dev/null || true; rm -rf "$h"' EXIT
  out="$(HOME="$h" ACE_OPENCODE_DB_MAX_MB=1 con_check_opencode 2>&1)"; rc=$?
  [ "$rc" = 1 ] || bad "over-threshold dbs must report drift (rc 1), got rc=$rc"
  printf '%s' "$out" | grep -q 'w1.opencode.db' \
    || { bad "PREVIEW INCOMPLETE — the per-worker swarm db that 'fix' deletes was not named in the report"; printf '%s\n' "$out"; }
  printf '%s' "$out" | grep -q 'opencode/opencode.db' || bad "default db missing from the report"
  printf '%s' "$out" | grep -qE '2/2' || { bad "report should count BOTH dbs as over-threshold"; printf '%s\n' "$out"; }
  # read-only: previewing must not delete what it is previewing
  [ -f "$h/.config/ace/swarm/projA/w1.opencode.db" ] || bad "con_check_opencode DELETED a db — the check must be read-only"
  [ -f "$h/.local/share/opencode/opencode.db" ]      || bad "con_check_opencode deleted the default db — the check must be read-only"
  # under threshold → clean, and still enumerating both
  out2="$(HOME="$h" ACE_OPENCODE_DB_MAX_MB=99999 con_check_opencode 2>&1)"; rc2=$?
  [ "$rc2" = 0 ] || bad "under-threshold dbs must report no drift, got rc=$rc2"
  printf '%s' "$out2" | grep -q '2 session db' || { bad "clean report should still count both stores"; printf '%s\n' "$out2"; }
  [ "$ok" = 1 ]
) || fails=$((fails+1))

[ "$fails" = 0 ] && echo "[hygiene] PASS ✓" || { echo "[hygiene] FAIL ✗ ($fails case(s))"; exit 1; }
