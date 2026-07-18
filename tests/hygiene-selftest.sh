#!/usr/bin/env bash
# hygiene-selftest.sh — ace_repo_hygiene must (a) back-fill missing ACE ignore rules, (b) untrack ACE transients
# a previous run swept into git, (c) NEVER untrack .opencode/specs/ (worktrees read specs from git), (d) leave a
# CLEAN tree, (e) be idempotent. Guards the exact failure seen live: a resume-commit swallowing .opencode/cache/
# plus a 151-spec .opencode/reanalyze/ baseline. Hermetic: temp repo, no network.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ok=1; bad(){ echo "[hygiene] $*"; ok=0; }
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
( cd "$d" && git init -q && git checkout -qb feat/x && git config user.email t@t && git config user.name t
  printf '.env\n.opencode/cache/versions.json\n' > .gitignore            # stale rules: pre-date cache/ + reanalyze/
  mkdir -p .opencode/specs .opencode/cache .opencode/reanalyze/before/specs
  echo spec > .opencode/specs/real.md
  echo transcript > .opencode/cache/spec-debate-x.md
  echo baseline > .opencode/reanalyze/before/specs/old.md
  git add -A && git commit -qm "artifacts wrongly swept in" >/dev/null
  . "$ROOT/lib/core.sh" 2>/dev/null; . "$ROOT/lib/ui.sh" 2>/dev/null; . "$ROOT/lib/consistency.sh"
  ace_repo_hygiene >/dev/null 2>&1
  [ "$(git ls-files | grep -cE '\.opencode/(cache|reanalyze)/')" = 0 ] || bad "transients still tracked"
  [ "$(git ls-files | grep -c '\.opencode/specs/')" = 1 ]              || bad ".opencode/specs/ must stay tracked"
  [ -f .opencode/cache/spec-debate-x.md ]                              || bad "untrack must keep files on disk"
  grep -qx '.opencode/reanalyze/' .gitignore                           || bad "reanalyze rule not back-filled"
  [ -z "$(git status --porcelain)" ]                                   || bad "hygiene left a dirty tree"
  before="$(git log --oneline | wc -l)"
  ace_repo_hygiene >/dev/null 2>&1
  [ "$(git log --oneline | wc -l)" = "$before" ]                       || bad "not idempotent (committed twice)"
  [ "$ok" = 1 ] && echo "[hygiene] PASS ✓" || { echo "[hygiene] FAIL ✗"; exit 1; }
) || exit 1
