#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# swarm-policy.sh — declarative conflict policy for the swarm.
#
# Some files are PREDICTABLY contended: every feature touches them (version,
# changelog, a lockfile, a command registry). Letting workers fight over these and
# then asking the conflict_resolver to sort out the mess is backwards — the outcome
# is *knowable up front*, so decide it up front. This turns three previously ad-hoc
# mechanisms (SWARM_META_FREE, the .gitattributes union driver, the graph refresh)
# into ONE declarative table, keyed by strategy:
#
#   union            append-only (changelog/lessons/notes) → git merge=union keeps both sides
#   struct:json|toml|yaml   structured manifest → 3-way DATA merge (disjoint dep-adds merge clean;
#                    real clashes escalate to the resolver). See merge-structured.sh.
#   regenerate:<cmd> derived file (lockfile, generated) → coordinator RE-RUNS <cmd> post-merge
#   assign           monotonic/authoritative (version) → SINGLE writer; workers never touch it
#                    (ACE cuts version as a release tag — `ace release --tag`). No per-item edit.
#   allocate         sequential id (migration number) → coordinator hands out the next value
#                    (see docs/deferred-decisions.md — not auto-applied yet)
#   ignore           never leased, never merged (regenerated wholesale by tooling)
#
# EVERY strategy implies the file is LEASE-FREE (no worker gets exclusive ownership),
# so items never falsely contend on it. Defaults are auto-detected per project by what
# files exist (so it's universal, no config needed); a project can override/extend via
# .opencode/conflict-policy  (lines: "<glob><whitespace><strategy>"; # comments ok).
# ---------------------------------------------------------------------------
_POLICY_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"

# built-in, language-agnostic defaults — emitted only for files that actually exist,
# so the effective policy is minimal and correct for THIS repo.
swarm_policy_defaults() {
  local repo="${1:-$PWD}" f
  # --- derived: lockfiles → regenerate (the command is auto-selected by which lock is present) ---
  [ -f "$repo/package-lock.json" ] && echo "package-lock.json	regenerate:npm install --package-lock-only --ignore-scripts"
  [ -f "$repo/pnpm-lock.yaml" ]    && echo "pnpm-lock.yaml	regenerate:pnpm install --lockfile-only"
  [ -f "$repo/yarn.lock" ]         && echo "yarn.lock	regenerate:yarn install --mode=update-lockfile"
  { [ -f "$repo/go.sum" ] || [ -f "$repo/go.mod" ]; } && echo "go.sum	regenerate:go mod tidy"
  [ -f "$repo/Cargo.lock" ]        && echo "Cargo.lock	regenerate:cargo generate-lockfile"
  [ -f "$repo/poetry.lock" ]       && echo "poetry.lock	regenerate:poetry lock --no-update"
  [ -f "$repo/Gemfile.lock" ]      && echo "Gemfile.lock	regenerate:bundle lock"
  [ -f "$repo/composer.lock" ]     && echo "composer.lock	regenerate:composer update --lock"
  # --- structured manifests → 3-way DATA merge (universal; keeps disjoint additions) ---
  [ -f "$repo/package.json" ]      && echo "package.json	struct:json"
  [ -f "$repo/composer.json" ]     && echo "composer.json	struct:json"
  [ -f "$repo/tsconfig.json" ]     && echo "tsconfig.json	struct:json"
  [ -f "$repo/Cargo.toml" ]        && echo "Cargo.toml	struct:toml"
  [ -f "$repo/pyproject.toml" ]    && echo "pyproject.toml	struct:toml"
  # --- authoritative: version carriers → assign (single writer; workers never edit) ---
  for f in VERSION version.txt; do [ -f "$repo/$f" ] && echo "$f	assign"; done
  # --- append-only: changelogs / release notes / lessons → union ---
  for f in CHANGELOG.md HISTORY.md NEWS.md RELEASES.md; do [ -f "$repo/$f" ] && echo "$f	union"; done
  echo ".opencode/lessons.md	union"
  echo ".opencode/memory/changelog.md	union"
  echo ".opencode/STANDARDS.md	union"   # many items touch it (standards_keeper) — union > lock-contention
  # --- generated: never leased, tooling regenerates ---
  [ -d "$repo/.gitnexus" ] && echo ".gitnexus/**	ignore"
}

# normalize "glob <ws> strategy..." → "glob<TAB>strategy" (strategy may contain spaces)
_policy_norm(){ awk '{ g=$1; $1=""; sub(/^[ \t]+/,""); if (g!="" && $0!="") printf "%s\t%s\n", g, $0 }'; }

# effective policy = defaults, with .opencode/conflict-policy overriding by glob (last wins)
swarm_policy_table() {
  local repo="${1:-$PWD}"
  { swarm_policy_defaults "$repo" | _policy_norm
    [ -f "$repo/.opencode/conflict-policy" ] && grep -vE '^[[:space:]]*(#|$)' "$repo/.opencode/conflict-policy" | _policy_norm
  } | awk -F'\t' '{ g[$1]=$2 } END{ for (k in g) printf "%s\t%s\n", k, g[k] }' | sort
}

# the set of globs that must NOT be leased to a worker (every strategy implies this).
swarm_policy_leasefree() {
  swarm_policy_table "${1:-$PWD}" | awk -F'\t' '{print $1}' | tr '\n' ' '
}

# apply the policy to a repo: register merge drivers + write .gitattributes. Idempotent.
swarm_policy_apply() {
  local repo="${1:-}"; [ -n "$repo" ] || repo="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local ga="$repo/.gitattributes"; touch "$ga"
  # union driver (append-only) — keep both sides; never lose an entry.
  git -C "$repo" config merge.union.name "line-union" 2>/dev/null || true
  git -C "$repo" config merge.union.driver 'git merge-file --union -L %O -L %A -L %B %A %O %B >/dev/null 2>&1 || cat %A %B > %A; true' 2>/dev/null || true
  # structured DATA drivers — disjoint additions merge clean, real clashes escalate.
  local drv; drv="bash '$_POLICY_HERE/merge-structured.sh'"
  git -C "$repo" config merge.structjson.name "3-way JSON merge" 2>/dev/null || true
  git -C "$repo" config merge.structjson.driver "$drv json %O %A %B" 2>/dev/null || true
  git -C "$repo" config merge.structtoml.name "3-way TOML merge" 2>/dev/null || true
  git -C "$repo" config merge.structtoml.driver "$drv toml %O %A %B" 2>/dev/null || true
  git -C "$repo" config merge.structyaml.name "3-way YAML merge" 2>/dev/null || true
  git -C "$repo" config merge.structyaml.driver "$drv yaml %O %A %B" 2>/dev/null || true
  local glob strat attr
  while IFS=$'\t' read -r glob strat; do
    case "$strat" in
      union)       attr="merge=union" ;;
      struct:json) attr="merge=structjson" ;;
      struct:toml) attr="merge=structtoml" ;;
      struct:yaml) attr="merge=structyaml" ;;
      *)           attr="" ;;   # regenerate/assign/allocate/ignore: no per-file merge driver
    esac
    [ -n "$attr" ] && ! grep -qF "$glob $attr" "$ga" 2>/dev/null && echo "$glob $attr" >> "$ga"
  done < <(swarm_policy_table "$repo")
  echo "conflict-policy: $(swarm_policy_table "$repo" | wc -l | tr -d ' ') rules (union/struct on .gitattributes; regenerate/assign post-merge; all lease-free)"
}

# the manifest(s) whose change should trigger regenerating a given lockfile.
_policy_manifest_for(){
  case "$1" in
    go.sum)            echo "go.mod" ;;
    package-lock.json|pnpm-lock.yaml|yarn.lock) echo "package.json" ;;
    Cargo.lock)        echo "Cargo.toml" ;;
    poetry.lock)       echo "pyproject.toml" ;;
    Gemfile.lock)      echo "Gemfile" ;;
    composer.lock)     echo "composer.json" ;;
    *)                 echo "" ;;
  esac
}

# POST-MERGE (coordinator, serialized under the merge lock, on the merged branch tip):
# re-run each regenerate:<cmd> whose lockfile OR governing manifest changed in this merge,
# and commit+push the normalized result. Keeps derived files coherent without text-merging them.
swarm_policy_regenerate() {
  local repo="${1:-$PWD}" branch="${2:-main}" glob strat cmd manifest changed did=0
  changed="$(git -C "$repo" diff --name-only HEAD~1 HEAD 2>/dev/null)" || return 0
  [ -n "$changed" ] || return 0
  while IFS=$'\t' read -r glob strat; do
    case "$strat" in regenerate:*) cmd="${strat#regenerate:}" ;; *) continue ;; esac
    manifest="$(_policy_manifest_for "$glob")"
    # run only if the derived file or its manifest actually moved (avoids needless installs)
    if ! printf '%s\n' "$changed" | grep -qxF "$glob" \
       && { [ -z "$manifest" ] || ! printf '%s\n' "$changed" | grep -qxF "$manifest"; }; then
      continue
    fi
    ( cd "$repo" && eval "$cmd" ) >/dev/null 2>&1 || true
    if ! git -C "$repo" diff --quiet 2>/dev/null; then
      git -C "$repo" commit -q -am "chore(swarm): regenerate ${glob} after merge" 2>/dev/null && did=1
    fi
  done < <(swarm_policy_table "$repo")
  [ "$did" = 1 ] && git -C "$repo" push -q origin "$branch" 2>/dev/null || true
  return 0
}

# selftest — exercise the structured merge (disjoint add merges; real clash escalates).
swarm_policy_selftest() {
  local t rc=0; t="$(mktemp -d)"; local ms="$_POLICY_HERE/merge-structured.sh"
  printf '{"deps":{"a":"1"}}\n' > "$t/O"
  printf '{"deps":{"a":"1","b":"2"}}\n' > "$t/A"     # ours adds b
  printf '{"deps":{"a":"1","c":"3"}}\n' > "$t/B"     # theirs adds c
  if bash "$ms" json "$t/O" "$t/A" "$t/B" && jq -e '.deps.b=="2" and .deps.c=="3"' "$t/A" >/dev/null; then
    echo "[policy] disjoint-add merge: PASS ✓"
  else echo "[policy] disjoint-add merge: FAIL ✗"; rc=1; fi
  printf '{"v":"1"}\n' > "$t/O"; printf '{"v":"2"}\n' > "$t/A"; printf '{"v":"3"}\n' > "$t/B"
  if bash "$ms" json "$t/O" "$t/A" "$t/B"; then echo "[policy] true-clash escalation: FAIL ✗ (should conflict)"; rc=1
  else echo "[policy] true-clash escalation: PASS ✓ (left as conflict)"; fi
  rm -rf "$t"; return $rc
}
