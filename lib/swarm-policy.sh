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
  # B3: structural (AST) pre-merge driver in FRONT of the LLM conflict_resolver. git's line merge invents
  # FALSE conflicts when two workers edit DIFFERENT functions in the SAME file (the dominant parallel-agent
  # conflict mode); Mergiraf resolves those deterministically so the resolver only handles genuine SEMANTIC
  # overlap. It is an ASSIST, never an auto-lander — the hardened merge gate (ci.sh --container + verifier
  # PASS) still decides what lands. FEATURE-GATED + FAIL-OPEN: the driver is registered and `* merge=mergiraf`
  # is written ONLY when the `mergiraf` binary is on PATH. When it is ABSENT we touch NOTHING here, so git's
  # plain 3-way merge escalates to the conflict_resolver EXACTLY as before — a missing tool never breaks the
  # merge flow (mirrors the shellcheck-absent pattern in A1/B1).
  if command -v mergiraf >/dev/null 2>&1; then
    git -C "$repo" config merge.mergiraf.name "mergiraf structural merge" 2>/dev/null || true
    git -C "$repo" config merge.mergiraf.driver 'mergiraf merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L' 2>/dev/null || true
    # `* merge=mergiraf` is the FRONT-LINE default. It must sit ABOVE the specific struct/union/ours rules
    # appended below so that .gitattributes' last-match-wins lets THOSE win for the manifests ACE merges with
    # its own data-aware drivers (package.json→structjson, lockfiles→ours, changelogs→union). Mergiraf itself
    # falls back to git's line merge for file types it can't parse, so a catch-all `*` is safe. Idempotent:
    # written once, kept at the top on every re-apply.
    if ! grep -qxF '* merge=mergiraf' "$ga" 2>/dev/null; then
      { printf '* merge=mergiraf\n'; cat "$ga"; } > "$ga.tmp" 2>/dev/null && mv "$ga.tmp" "$ga"
    fi
  fi
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
  # "ours" driver (S4/P8): lockfiles + other derived files are conflict HUBS — every worker's
  # dep-add rewrites them, and Git's line-merge serializes all parallel work onto them. Take ONE
  # side at merge time (keep ours) so the merge never blocks, then let swarm_policy_regenerate
  # re-derive it deterministically from the merged manifest post-merge. Never hand-merge a lockfile.
  git -C "$repo" config merge.ours.name "keep ours (regenerate post-merge)" 2>/dev/null || true
  git -C "$repo" config merge.ours.driver true 2>/dev/null || true
  local glob strat attr
  while IFS=$'\t' read -r glob strat; do
    case "$strat" in
      union)        attr="merge=union" ;;
      struct:json)  attr="merge=structjson" ;;
      struct:toml)  attr="merge=structtoml" ;;
      struct:yaml)  attr="merge=structyaml" ;;
      regenerate:*) attr="merge=ours" ;;   # lockfiles/derived: keep ours at merge, regenerate after (never text-conflict)
      *)            attr="" ;;   # assign/allocate/ignore: no per-file merge driver
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

# ONE-FILE-PER-WORKER shared state (S6): append logs (lessons) are conflict hotspots — every worker
# writing the SAME .opencode/lessons.md guarantees merge collisions on the very file meant to reduce
# rework. Instead each flow appends ONLY to its own .opencode/lessons/<branch>.md shard (no two flows
# share one, so shards NEVER conflict), and this reduce folds the shards into the canonical
# .opencode/lessons.md — the file the planner + critics read. Pure working-tree op (the caller decides
# whether to commit); idempotent (a line already in the canonical file is never re-added).
swarm_aggregate_lessons() {
  local repo="${1:-$PWD}" dir canon shard line hdr
  dir="$repo/.opencode/lessons"; canon="$repo/.opencode/lessons.md"
  [ -d "$dir" ] || return 0
  hdr='# Lessons (most useful first) — durable decisions/gotchas the loop learned.'
  [ -f "$canon" ] || { printf '%s\n# One terse line each, deduped. Read before planning; append after each task.\n' "$hdr" > "$canon"; }
  for shard in "$dir"/*.md; do
    [ -e "$shard" ] || continue                      # nullglob-safe: no shards → nothing to fold
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      case "$line" in \#*) continue ;; esac          # skip shard header/comment lines
      grep -qxF -- "$line" "$canon" 2>/dev/null || printf '%s\n' "$line" >> "$canon"
    done < "$shard"
  done
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
  rm -rf "$t"
  swarm_mergiraf_selftest || rc=1
  return $rc
}

# B3 selftest — the Mergiraf structural-merge FRONT-END wiring. Proves:
#  (a) ABSENT → FAIL-OPEN: with no `mergiraf` on PATH, swarm_policy_apply registers NO driver and writes NO
#      `* merge=mergiraf`, so git's plain 3-way merge escalates to conflict_resolver exactly as before. This
#      is THE critical proof, since real mergiraf isn't installed on this host.
#  (b) PRESENT (stubbed): the driver is registered, `* merge=mergiraf` FRONTS the specific data-merge rules
#      (so package.json→structjson etc. still win via last-match), and a real git merge INVOKES the driver —
#      resolving a FALSE (disjoint-function) conflict cleanly while leaving a GENUINE clash as markers to
#      escalate. The stub stands in for the AST merger; it proves the front-end runs BEFORE the LLM fallback.
swarm_mergiraf_selftest() {
  local rc=0 t stub
  t="$(mktemp -d)"; stub="$t/bin"; mkdir -p "$stub"
  # stub `mergiraf`: record each invocation, then mimic mergiraf's contract — cleanly 3-way-merge what it
  # can (exit 0), leave a genuine clash as conflict markers (exit 1) so git escalates to conflict_resolver.
  cat > "$stub/mergiraf" <<'STUB'
#!/usr/bin/env bash
[ -n "${MERGIRAF_STUB_SENTINEL:-}" ] && printf '%s\n' "$*" >> "$MERGIRAF_STUB_SENTINEL"
# driver args are: merge --git %O %A %B -s %S -x %X -y %Y -p %P -l %L  → O=$3 A=$4(ours+output) B=$5.
# git merge-file takes <current/ours> <base> <other/theirs> and writes the result into the first arg (=%A).
git merge-file "$4" "$3" "$5" >/dev/null 2>&1 && exit 0 || exit 1
STUB
  chmod +x "$stub/mergiraf"

  # ---- (a) ABSENT → fail-open -------------------------------------------------------------------------
  ( set +e
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    if command -v mergiraf >/dev/null 2>&1; then echo "SKIP(real-mergiraf-present)"; exit 0; fi
    mkdir -p "$t/absent" && cd "$t/absent" || exit 1
    git init -q . && git symbolic-ref HEAD refs/heads/main 2>/dev/null
    git config user.email a@b.c; git config user.name t
    printf '{"deps":{"a":"1"}}\n' > package.json
    swarm_policy_apply "$PWD" >/dev/null 2>&1
    grep -q 'merge=mergiraf' .gitattributes 2>/dev/null && { echo "FAIL(wrote mergiraf line)"; exit 1; }
    git config --get merge.mergiraf.driver >/dev/null 2>&1 && { echo "FAIL(registered driver)"; exit 1; }
    grep -q 'package.json merge=structjson' .gitattributes || { echo "FAIL(struct rule missing)"; exit 1; }
    exit 0
  ) >/dev/null 2>&1 && echo "[mergiraf] absent → fail-open (no driver / no '* merge=mergiraf'; struct rules intact): PASS ✓" \
     || { echo "[mergiraf] absent → fail-open: FAIL ✗"; rc=1; }

  # ---- (b) PRESENT (stub) → registered, fronting, invoked-first -------------------------------------
  ( set +e
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export PATH="$stub:$PATH"
    command -v mergiraf >/dev/null 2>&1 || { echo "FAIL(stub not on PATH)"; exit 1; }
    mkdir -p "$t/present" && cd "$t/present" || exit 1
    git init -q . && git symbolic-ref HEAD refs/heads/main 2>/dev/null
    git config user.email a@b.c; git config user.name t
    printf 'func a() {\n  return 1\n}\n\nfunc b() {\n  return 2\n}\n' > foo.go
    printf '{"deps":{"x":"1"}}\n' > package.json
    printf 'x = 1\n' > clash.txt
    git add -A && git commit -q -m base
    swarm_policy_apply "$PWD" >/dev/null 2>&1
    git add .gitattributes && git commit -q -m attrs
    # wiring: driver registered + `* merge=mergiraf` present and ABOVE package.json's structjson rule
    grep -qxF '* merge=mergiraf' .gitattributes || { echo "FAIL(no catch-all line)"; exit 1; }
    git config --get merge.mergiraf.driver | grep -q 'mergiraf merge --git' || { echo "FAIL(driver not registered)"; exit 1; }
    aln="$(grep -n '^\* merge=mergiraf$' .gitattributes | head -1 | cut -d: -f1)"
    pln="$(grep -n 'package.json merge=structjson' .gitattributes | head -1 | cut -d: -f1)"
    { [ -n "$aln" ] && [ -n "$pln" ] && [ "$aln" -lt "$pln" ]; } || { echo "FAIL(precedence a=$aln p=$pln)"; exit 1; }
    # branches: theirs edits the 2nd function; main edits the 1st (disjoint) + diverges clash.txt
    git checkout -q -b theirs
    printf 'func a() {\n  return 1\n}\n\nfunc b() {\n  return 20\n}\n' > foo.go
    git commit -q -am theirs
    git checkout -q main
    printf 'func a() {\n  return 10\n}\n\nfunc b() {\n  return 2\n}\n' > foo.go
    printf 'x = 2\n' > clash.txt
    git commit -q -am ours
    ours_sha="$(git rev-parse HEAD)"
    git checkout -q -b theirs2 theirs
    printf 'x = 3\n' > clash.txt
    git commit -q -am theirs-clash
    git checkout -q main
    # false conflict (disjoint functions) → driver resolves CLEAN, both intents kept, no markers
    export MERGIRAF_STUB_SENTINEL="$t/sentinel1"; : > "$MERGIRAF_STUB_SENTINEL"
    git merge --no-edit -q theirs >/dev/null 2>&1
    [ -s "$t/sentinel1" ] || { echo "FAIL(false: driver not invoked)"; exit 1; }
    grep -q '^<<<<<<<' foo.go && { echo "FAIL(false: unexpected markers)"; exit 1; }
    { grep -q 'return 10' foo.go && grep -q 'return 20' foo.go; } || { echo "FAIL(false: lost an edit)"; exit 1; }
    git reset -q --hard "$ours_sha"
    # genuine clash → driver leaves MARKERS so it escalates to conflict_resolver
    export MERGIRAF_STUB_SENTINEL="$t/sentinel2"; : > "$MERGIRAF_STUB_SENTINEL"
    git merge --no-edit -q theirs2 >/dev/null 2>&1
    [ -s "$t/sentinel2" ] || { echo "FAIL(clash: driver not invoked)"; exit 1; }
    grep -q '^<<<<<<<' clash.txt || { echo "FAIL(clash: not escalated as markers)"; exit 1; }
    git merge --abort 2>/dev/null
    exit 0
  ) >/dev/null 2>&1 && echo "[mergiraf] present(stub) → driver registered + fronts struct rules; false conflict resolved CLEAN (both intents), genuine clash escalated: PASS ✓" \
     || { echo "[mergiraf] present(stub): FAIL ✗"; rc=1; }

  rm -rf "$t"; return $rc
}
