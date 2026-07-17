#!/usr/bin/env bash
# reanalyze-selftest.sh — fabricate a repo, snapshot a baseline, simulate the planner's re-derivation (new +
# changed specs, re-sliced ROADMAP), and assert ace_reanalyze_report renders the before/after deltas + --json.
# No network, no opencode, deterministic. The snapshot + report are the testable surface (the drive() re-spec
# itself needs a live model, out of scope here).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok=1; bad(){ echo "[reanalyze] $*"; ok=0; }

d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
mkdir -p "$d/.opencode/specs"

# a baseline: 2 open items (one carrying a Spec:) + 1 done, and 2 specs
cat > "$d/ROADMAP.md" <<'EOF'
# ROADMAP
## Next
- [ ] add password reset  Spec: .opencode/specs/authz.md  AC: AC-1  Files: src/auth.ts
- [ ] add rate limiting  Files: src/rl.ts
- [x] scaffold app  Files: src/app.ts
EOF
cp "$ROOT/tests/debate-sandbox/specs/strong-authz.md" "$d/.opencode/specs/authz.md" 2>/dev/null || \
  printf '<!-- ace-spec-template v1 -->\n# Spec (slug: authz)\n' > "$d/.opencode/specs/authz.md"
cp "$ROOT/tests/debate-sandbox/specs/vague-acs.md" "$d/.opencode/specs/vague.md" 2>/dev/null || \
  printf '# Spec (slug: vague)\n' > "$d/.opencode/specs/vague.md"

export C_BOLD='' C_RESET='' C_YELLOW='' C_GREY=''

# 1) BEFORE any snapshot → report says "no baseline"
out0="$(RA_REPO="$d" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; ace_reanalyze_report' 2>&1)" || bad "report crashed pre-snapshot"
printf '%s' "$out0" | grep -q 'no baseline' || bad "pre-snapshot should report no baseline, got: $out0"

# 2) snapshot the baseline
RA_REPO="$d" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; reanalyze_snapshot "'"$d"'"' >/dev/null 2>&1 || bad "snapshot failed"
[ -f "$d/.opencode/reanalyze/before/.captured" ] || bad "baseline marker not written"
[ -f "$d/.opencode/reanalyze/before/specs/authz.md" ] || bad "baseline did not copy specs"
# idempotent: a second snapshot must NOT clobber (mutate baseline then re-snapshot → unchanged)
echo "MUTATED" >> "$d/.opencode/specs/authz.md"; before_hash="$(cat "$d/.opencode/reanalyze/before/specs/authz.md")"
RA_REPO="$d" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; reanalyze_snapshot "'"$d"'"' >/dev/null 2>&1
[ "$(cat "$d/.opencode/reanalyze/before/specs/authz.md")" = "$before_hash" ] || bad "second snapshot clobbered the pristine baseline"

# 3) simulate the re-derivation: authz.md already CHANGED above; add a NEW spec + a new open ROADMAP item w/ Spec:
printf '<!-- ace-spec-template v1 -->\n# Spec (slug: reset)\n' > "$d/.opencode/specs/reset.md"
cat >> "$d/ROADMAP.md" <<'EOF'
- [ ] reset flow step 1  Spec: .opencode/specs/reset.md  AC: AC-1  Files: src/reset.ts
EOF

out="$(RA_REPO="$d" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; ace_reanalyze_report' 2>&1)" || bad "report crashed post-change"
printf '%s' "$out" | grep -q 'REANALYZE — before → after' || bad "missing section header"
printf '%s' "$out" | grep -q 'open ROADMAP items'          || bad "missing open-items row"
printf '%s' "$out" | grep -q '1 new · 1 changed'           || { bad "specs new/changed wrong"; printf '%s\n' "$out" | grep -i spec; }
printf '%s' "$out" | grep -qi 'verdict:'                   || bad "missing verdict line"

# 4) --json parses + carries the structural deltas
js="$(RA_REPO="$d" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; ace_reanalyze_report --json' 2>&1)"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$js" | jq -e '.captured==true and .specs_new==1 and .specs_changed==1 and .open_before==2 and .open_after==3' >/dev/null 2>&1 \
    || { bad "--json wrong/invalid"; printf '%s\n' "$js"; }
else
  printf '%s' "$js" | grep -q '"specs_new":1' || bad "--json specs_new missing (no jq)"
fi

[ "$ok" = 1 ] && echo "[reanalyze] PASS ✓" || { echo "[reanalyze] FAIL ✗"; exit 1; }
