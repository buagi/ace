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

# --- drift guard: the canonical reader sed must appear exactly 3x, across its real homes:
#   _prof_get + the release.sh `prof` emitter (both in lib/scaffold.sh) and prof_get (lib/autoloop.sh,
#   embedded into the generated scripts/auto-loop.sh). Generated files can't source a shared function, so
#   the parsing logic is one canonical sed kept identical and enforced here. ---
n="$(grep -hcF 's/^[^:]*:[[:space:]]*\"([^\"]*)\"' "$ROOT/lib/scaffold.sh" "$ROOT/lib/autoloop.sh" | awk '{s+=$1} END{print s+0}')"
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

# --- drift guard #2: orch_model() is implemented TWICE, and cannot be de-duplicated ---------------
# lib/core.sh:150 and lib/autoloop.sh both resolve the EFFECTIVE overseer model. autoloop.sh cannot source
# core.sh (core.sh installs `trap cleanup EXIT`, which would bind autoloop's own cleanup — kill the process
# subtree, exit 130 — to every normal end-of-run), so the copies are pinned here instead: extract autoloop's
# copy, point BOTH resolvers at the same config file, and require identical output on every branch. Silent
# drift means the loop runs one model while the banner/status/settings report another.
echo "orch_model drift (lib/core.sh vs lib/autoloop.sh):"
OMF="$WORK/orch_model.autoloop.sh"
awk '/^orch_model\(\)\{/,/^\}/' "$ROOT/lib/autoloop.sh" > "$OMF"
if [ ! -s "$OMF" ]; then echo "  ✗ could not extract orch_model() from lib/autoloop.sh (renamed or reformatted?)"; fail=1; fi
XDGD="$WORK/xdg"; mkdir -p "$XDGD/ace"
om_chk(){ # <config-body>  — both resolvers must agree; core.sh is the reference
  printf '%s\n' "$1" > "$XDGD/ace/config"
  local a b
  # autoloop's copy reads $ACE_CFG; core.sh's reads $ACE_CONFIG, derived from XDG_CONFIG_HOME at source time.
  a="$(XDG_CONFIG_HOME="$XDGD" ACE_CFG="$XDGD/ace/config" bash -c '. "$1"; orch_model' _ "$OMF" 2>/dev/null)"
  b="$(XDG_CONFIG_HOME="$XDGD" bash -c '. "$1"; orch_model' _ "$ROOT/lib/core.sh" 2>/dev/null)"
  if [ -n "$b" ] && [ "$a" = "$b" ]; then echo "  ✓ [${1:-<empty config>}] -> $a"
  else echo "  ✗ DRIFT for [${1:-<empty config>}]: autoloop.sh -> '$a' · core.sh -> '$b'"; fail=1; fi
}
om_chk ""                                     # no keys at all -> the documented default overseer
om_chk "ORCH_PROVIDER=opus"
om_chk "ORCH_PROVIDER=sonnet"
om_chk "ORCH_PROVIDER=gpt"
om_chk "ORCH_PROVIDER=deepseek"
om_chk "ORCH_PROVIDER=nonsense"               # unknown alias -> same fallback on both sides
om_chk "MODEL_orchestrator=anthropic/claude-opus-4-8"
om_chk "$(printf 'ORCH_PROVIDER=deepseek\nMODEL_orchestrator=openai/gpt-5')"   # explicit override must win
# XDG-relocated config must be FOUND, not silently missed (autoloop.sh used to hardcode ~/.config/ace/config,
# so with XDG_CONFIG_HOME set it read nothing and reported the Opus fallback as the configured overseer).
printf 'ORCH_PROVIDER=deepseek\n' > "$XDGD/ace/config"
# (sourcing lib/autoloop.sh outright would RUN the loop, so re-use the extracted copy and reproduce the
#  file's own ACE_CFG default line here — the grep assertion below keeps the two in step.)
x="$(XDG_CONFIG_HOME="$XDGD" HOME="$WORK/nonexistent-home" bash -c '
  ACE_CFG="${ACE_CFG:-${XDG_CONFIG_HOME:-$HOME/.config}/ace/config}"; . "$1"; orch_model' _ "$OMF" 2>/dev/null)"
if [ "$x" = "deepseek/deepseek-v4-pro" ]; then echo "  ✓ XDG_CONFIG_HOME honoured (config found, no silent Opus fallback)"
else echo "  ✗ XDG_CONFIG_HOME ignored: got '$x' want 'deepseek/deepseek-v4-pro'"; fail=1; fi
if grep -qF 'ACE_CFG="${ACE_CFG:-${XDG_CONFIG_HOME:-$HOME/.config}/ace/config}"' "$ROOT/lib/autoloop.sh"; then
  echo "  ✓ lib/autoloop.sh ACE_CFG default is XDG-aware"
else echo "  ✗ lib/autoloop.sh ACE_CFG default is not XDG-aware (must match core.sh:4 ACE_CONFIG_DIR)"; fail=1; fi

[ "$fail" = 0 ] && { echo "✓ profile reader OK"; exit 0; } || { echo "✗ profile reader FAILED"; exit 1; }
