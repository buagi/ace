#!/usr/bin/env bash
# Tests the profile.yaml reader (quote-aware; must not truncate a '#' inside a quoted value) and
# guards that the THREE copies of it stay identical: _prof_get in lib/scaffold.sh, and the generated
# prof_get (auto-loop.sh) + prof (release.sh). Generated files can't source a shared function, so the
# parsing logic is one canonical sed kept identical and enforced here.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ACE_DIR="$ROOT" ACE_DRY_RUN=0
# shellcheck disable=SC1091
source "$ROOT/lib/ui.sh"; source "$ROOT/lib/core.sh" 2>/dev/null || true; source "$ROOT/lib/scaffold.sh"
fail=0

# --- drift guard: the canonical reader sed must appear exactly 3x (lib + 2 generated readers) ---
n="$(grep -cF 's/^[^:]*:[[:space:]]*\"([^\"]*)\"' "$ROOT/lib/scaffold.sh")"
if [ "$n" = 3 ]; then echo "✓ reader sed is identical across all 3 copies"
else echo "✗ reader sed appears $n times (want 3) — the readers drifted; keep them identical"; fail=1; fi

# --- behavior: tricky values ---
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; mkdir -p "$WORK/.opencode"
cat > "$WORK/.opencode/profile.yaml" <<'EOF'
name: my-app
domain: "C# to Go rewrite # not a comment"
merge_gate: local    # remote | local
auto_merge: true     # auto-accept
targets: [linux/amd64, linux/arm64]   # build targets
philosophy: 'fail-closed # always'
empty_field:
EOF
cd "$WORK"
chk(){ if [ "$(_prof_get "$1")" = "$2" ]; then echo "  ✓ $1"; else echo "  ✗ $1 -> got '$(_prof_get "$1")' want '$2'"; fail=1; fi; }
chk name "my-app"
chk domain "C# to Go rewrite # not a comment"
chk merge_gate "local"
chk auto_merge "true"
chk targets "[linux/amd64, linux/arm64]"
chk philosophy "fail-closed # always"
chk empty_field ""
chk missing_key ""

[ "$fail" = 0 ] && { echo "✓ profile reader OK"; exit 0; } || { echo "✗ profile reader FAILED"; exit 1; }
