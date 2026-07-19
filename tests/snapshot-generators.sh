#!/usr/bin/env bash
# Snapshot test for ACE's code generators.
#
# Generates each stack's artifacts (CI workflow, deploy script, Go skeleton, profile) into a temp dir
# and diffs them against tests/snapshots/. This locks in the generated output so a refactor (e.g.
# adding a stack, or touching gen_ci_workflow) can't silently change what existing stacks emit.
#
#   tests/snapshot-generators.sh            # check against snapshots (exit 1 on any diff)
#   tests/snapshot-generators.sh --update   # (re)write the snapshots after an intentional change
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAP="$ROOT/tests/snapshots"
UPDATE=0; [ "${1:-}" = --update ] && UPDATE=1

export ACE_DIR="$ROOT" ACE_DRY_RUN=0
# shellcheck disable=SC1091
source "$ROOT/lib/ui.sh"; source "$ROOT/lib/core.sh" 2>/dev/null || true; source "$ROOT/lib/scaffold.sh"
detect_distro >/dev/null 2>&1 || true
# Determinism: plain image tags (no registry digest), fixed profile timestamps.
pin_image() { printf '%s' "$1"; }
# Hermetic: gen_node ends with `confirm "Run 'pnpm install' now"` (scaffold.sh:614) and confirm()
# auto-answers the coded default Y when non-interactive — so snapshotting node used to perform a REAL
# ~130MB network install on every run. Stub the BINARY rather than confirm(): the generator still takes
# the identical branch (so the captured output is unchanged), it just no-ops instead of hitting the network.
SNAPBIN="$(mktemp -d)"; printf '#!/bin/sh\nexit 0\n' > "$SNAPBIN/pnpm"; chmod +x "$SNAPBIN/pnpm"
PATH="$SNAPBIN:$PATH"; export PATH

WORK="$(mktemp -d)"; OUT="$(mktemp -d)"; trap 'rm -rf "$WORK" "$OUT" "$SNAPBIN"' EXIT
norm() { sed -E 's/^(created|updated): .*/\1: <ts>/'; }   # strip non-deterministic timestamps

capture() { # <label> <relpath-in-project>  -> $OUT/<label>
  local label="$1" rel="$2"
  [ -f "$rel" ] || { echo "MISSING generated file: $rel"; return 1; }
  norm < "$rel" > "$OUT/$label"
}

# --- CI workflows for every stack (the factored generator — the regression-prone surface) ---
for s in node python config go; do
  d="$WORK/ci-$s/app"; mkdir -p "$d"
  ( cd "$d" && gen_ci_workflow "$s" >/dev/null 2>&1 && cp .github/workflows/ci.yml "$OUT/ci-$s.yml" )
done
# --- Go CI per shape (deploy/release gating): api=deploy+release · cli=release · worker=deploy(liveness)+release · library=neither ---
for sh in api cli worker library; do
  d="$WORK/cish-$sh/app"; mkdir -p "$d/.opencode"
  printf 'name: app\nshape: %s\n' "$sh" > "$d/.opencode/profile.yaml"
  ( cd "$d" && gen_ci_workflow go >/dev/null 2>&1 && cp .github/workflows/ci.yml "$OUT/ci-go-$sh.yml" )
done
# --- deploy scripts (service default vs Go final-image branch) ---
for s in node go; do
  d="$WORK/dep-$s/app"; mkdir -p "$d"
  ( cd "$d" && gen_deploy_artifacts app "$s" >/dev/null 2>&1 && cp scripts/deploy.sh "$OUT/deploy-$s.sh" )
done
# --- Go skeleton + profile (deterministic given args) ---
d="$WORK/go/app"; mkdir -p "$d"
( cd "$d"
  PROFILE_SHAPE=api; PROFILE_LANG=go   # real `ace scaffold --stack go` sets PROFILE_LANG; match it (this dir is empty)
  write_profile app api "demo" internal low "mission" "reliability" "fail-closed" true github-actions true remote false standard "linux/amd64, linux/arm64" >/dev/null 2>&1
  gen_go app >/dev/null 2>&1
  for rel in go.mod Containerfile ci.sh opencode.json scripts/release.sh "cmd/app/main.go" .opencode/profile.yaml .opencode/STANDARDS.md; do
    capture "go-$(printf '%s' "$rel" | tr '/' '_')" "$rel"
  done
)

# --- node + python skeletons ---
# These were unsnapshotted for a long time, which is exactly how the generator bugs in the python ci.sh
# (byte-compiling .venv, unquoted word-splitting) and the missing brownfield exclusions survived unnoticed:
# only the Go arm above was ever diffed. ci.sh is the highest-churn/highest-risk emission of the three, so
# it is captured alongside the Containerfile (base image + build steps) and .gitignore (loop transients).
for s in node python; do
  d="$WORK/skel-$s/app"; mkdir -p "$d"
  ( cd "$d"
    PROFILE_SHAPE=api; PROFILE_LANG="$s"   # real `ace scaffold --stack <s>` sets these; match it (this dir is empty)
    write_profile app api "demo" internal low "mission" "reliability" "fail-closed" true github-actions true remote false standard "linux/amd64, linux/arm64" >/dev/null 2>&1
    "gen_$s" app >/dev/null 2>&1
    for rel in ci.sh Containerfile .gitignore; do
      capture "$s-$(printf '%s' "$rel" | tr '/' '_')" "$rel"
    done
  )
done

# --- compare or update ---
if [ "$UPDATE" = 1 ]; then
  mkdir -p "$SNAP"; find "$SNAP" -maxdepth 1 -type f -delete 2>/dev/null   # replace generator snapshots (top-level files) but PRESERVE subdirs (e.g. agents/ — F3 goldens)
  cp "$OUT"/* "$SNAP"/
  echo "snapshots updated ($(ls "$SNAP" | wc -l) files) -> tests/snapshots/"
  exit 0
fi

[ -d "$SNAP" ] || { echo "no snapshots yet — run: tests/snapshot-generators.sh --update"; exit 1; }
fail=0
for f in "$OUT"/*; do
  name="$(basename "$f")"
  if [ ! -f "$SNAP/$name" ]; then echo "NEW (unsnapshotted): $name"; fail=1
  elif ! diff -q "$SNAP/$name" "$f" >/dev/null 2>&1; then
    echo "CHANGED: $name"; diff "$SNAP/$name" "$f" | head -30; fail=1
  fi
done
for f in "$SNAP"/*; do
  [ -d "$f" ] && continue   # subdirs (e.g. agents/ — F3 behavioural goldens) aren't generator snapshots
  name="$(basename "$f")"; [ -f "$OUT/$name" ] || { echo "REMOVED (snapshot has no match): $name"; fail=1; }
done
# YAML-validity gate: a text diff can't catch invalid YAML (e.g. ${{ }} inside a flow mapping parse-breaks).
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  for f in "$OUT"/ci-*.yml; do
    [ -f "$f" ] || continue
    python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$f" 2>/dev/null || { echo "INVALID YAML: $(basename "$f")"; fail=1; }
  done
else echo "(python3+yaml absent — skipped the YAML-validity gate)"; fi
[ "$fail" = 0 ] && { echo "✓ generators match snapshots ($(ls "$OUT" | wc -l) files)"; exit 0; } \
                 || { echo "✗ generator output drifted — review, then: tests/snapshot-generators.sh --update"; exit 1; }
