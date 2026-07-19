#!/usr/bin/env bash
# reanalyze-selftest.sh — fabricate a repo, snapshot a baseline, simulate the planner's re-derivation (new +
# changed specs, re-sliced ROADMAP), and assert ace_reanalyze_report renders the before/after deltas + --json.
# No network, no opencode, deterministic. The snapshot + report are the testable surface (the drive() re-spec
# itself needs a live model, out of scope here).
#
# THE SPEC-LINT GAP DELTA IS THE POINT. Every other row here is a file/line COUNT — if it is wrong you can see
# it. The gap delta is the only COMPUTED, fail-open, "—"-capable value in the module: it shells out to
# swarm.sh, divides by a spec count that the re-derivation deliberately changes, and has three distinct
# reasons to be unmeasured. Both shipped reanalyze bugs lived in exactly that value, and both shipped because
# this file asserted every metric except it. So it is now asserted three ways: MEASURED (real numbers, delta
# consistent with the operands), UNMEASURED-because-no-specs, and UNMEASURED-because-the-lint-did-not-run —
# the last two must render "—"/null and must never be reported as 0 or turned into a regression verdict.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ok=1; bad(){ echo "[reanalyze] $*"; ok=0; }

# pull a scalar out of one of these flat JSON objects (no jq dependency; values are bare numbers or null)
_jget(){ printf '%s' "$2" | sed -n 's/.*"'"$1"'":\([^,}]*\).*/\1/p'; }

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
# The gap assertions below are only meaningful if these are the REAL lint fixtures. The old `cp … || printf
# stub` fallback meant a renamed fixture silently swapped in a two-line stub and the suite still went green.
for _f in strong-authz:authz vague-acs:vague; do
  _src="$ROOT/tests/debate-sandbox/specs/${_f%%:*}.md"; _dst="$d/.opencode/specs/${_f##*:}.md"
  [ -f "$_src" ] || { echo "[reanalyze] FIXTURE MISSING: $_src — refusing to substitute a stub"; exit 1; }
  cp "$_src" "$_dst" || { echo "[reanalyze] could not copy fixture $_src"; exit 1; }
done

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

# 3a) THE GAP DELTA, MEASURED. Both sides have real specs and swarm.sh is next to reanalyze.sh, so both sides
# MUST be numbers — a "—" here means the lint silently failed to run and the module fell open.
js="$(RA_REPO="$d" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; ace_reanalyze_report --json' 2>&1)"
gb="$(_jget gaps_before "$js")"; ga="$(_jget gaps_after "$js")"
rb="$(_jget gaps_per_spec_before "$js")"; ra="$(_jget gaps_per_spec_after "$js")"
case "$gb" in ''|null|*—*) bad "gaps_before must be a measured number with real specs + swarm.sh present, got: '$gb'" ;; esac
case "$ga" in ''|null|*—*) bad "gaps_after must be a measured number, got: '$ga'" ;; esac
case "$rb" in ''|null|*—*) bad "gaps_per_spec_before must be a bare decimal, got: '$rb'" ;; esac
case "$ra" in ''|null|*—*) bad "gaps_per_spec_after must be a bare decimal, got: '$ra'" ;; esac
# the fixtures are gappy on both sides; 0 would mean the lint produced nothing and got counted as clean
[ "${gb:-0}" -gt 0 ] 2>/dev/null || bad "baseline gaps counted 0 — a lint that produced nothing must render — , not a clean bill of health"
[ "${ga:-0}" -gt 0 ] 2>/dev/null || bad "after gaps counted 0 — same fail-open shape"
# the RENDERED delta must agree with its own operands (this is the arithmetic the reader trusts).
# The rows are column-padded, so squeeze runs of spaces and compare as FIXED strings — the delta is literally
# "+17", and a "+" is a quantifier in ERE, which silently made an earlier regex form of this check unreliable.
exp="$(( ga - gb ))"; [ "$exp" -gt 0 ] && exp="+$exp"
outsq="$(printf '%s\n' "$out" | tr -s ' ')"
printf '%s' "$outsq" | grep -qF "spec-lint GAPS $gb → $ga ($exp)" \
  || { bad "GAPS row/delta does not match its operands (expected '$gb → $ga ($exp)')"; printf '%s\n' "$out" | grep -i 'GAPS'; }
# the per-spec rate is what the verdict judges; the stub spec is far gappier, so this run IS a regression
printf '%s' "$outsq" | grep -qF "spec-lint GAPS/spec $rb → $ra" \
  || { bad "GAPS/spec row does not match the JSON rates ($rb → $ra)"; printf '%s\n' "$out" | grep -i 'GAPS/spec'; }
printf '%s' "$out" | grep -q 'MORE spec gaps per spec' \
  || { bad "a measured rate increase ($rb → $ra) must produce the regression verdict"; printf '%s\n' "$out" | grep -i verdict; }

# 4) --json parses + carries the structural deltas
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$js" | jq -e '.captured==true and .specs_new==1 and .specs_changed==1 and .open_before==2 and .open_after==3
                             and (.gaps_before|type=="number") and (.gaps_after|type=="number")
                             and (.gaps_per_spec_before|type=="number") and (.gaps_per_spec_after|type=="number")' >/dev/null 2>&1 \
    || { bad "--json wrong/invalid (gaps_* must be bare NUMBERS, never null or a quoted — )"; printf '%s\n' "$js"; }
else
  printf '%s' "$js" | grep -q '"specs_new":1' || bad "--json specs_new missing (no jq)"
fi

# 5) UNMEASURED — a spec-LESS baseline. This is the COMMON shape for the headline use of reanalyze (re-assess
# a project that had no specs yet), and it is the bug that shipped: 0 specs was counted as "0 gaps", so the
# after side — real specs, real gaps — was reported as a REGRESSION for the one case where specs were just
# created. The baseline must render the "—" sentinel, serialise as null, and produce NO regression verdict.
e="$(mktemp -d)"; trap 'rm -rf "$d" "$e"' EXIT
mkdir -p "$e/.opencode/specs"
printf '# ROADMAP\n## Next\n- [ ] build the thing  Files: src/a.ts\n' > "$e/ROADMAP.md"
RA_REPO="$e" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; reanalyze_snapshot "'"$e"'"' >/dev/null 2>&1
[ -f "$e/.opencode/reanalyze/before/.captured" ] || bad "spec-less baseline should still snapshot"
cp "$ROOT/tests/debate-sandbox/specs/vague-acs.md" "$e/.opencode/specs/vague.md" || bad "fixture copy failed (spec-less case)"

oute="$(RA_REPO="$e" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; ace_reanalyze_report' 2>&1)"
jse="$(RA_REPO="$e" bash -c 'source "'"$ROOT"'/lib/reanalyze.sh"; ace_reanalyze_report --json' 2>&1)"
outesq="$(printf '%s\n' "$oute" | tr -s ' ')"
printf '%s' "$outesq" | grep -qF 'spec-lint GAPS — →' \
  || { bad "spec-LESS baseline must render — for gaps, never 0"; printf '%s\n' "$oute" | grep -i 'GAPS'; }
printf '%s' "$outesq" | grep -qF 'spec-lint GAPS 0 →' \
  && bad "REGRESSION: spec-less baseline reported as 0 gaps — a dir that was never linted is not clean"
[ "$(_jget gaps_before "$jse")" = null ] || bad "gaps_before must serialise as null when unmeasured, got: '$(_jget gaps_before "$jse")'"
[ "$(_jget gaps_per_spec_before "$jse")" = null ] || bad "gaps_per_spec_before must be null when unmeasured"
printf '%s' "$oute" | grep -q 'MORE spec gaps' \
  && { bad "REGRESSION: unmeasured baseline must NOT produce a MORE-spec-gaps verdict"; printf '%s\n' "$oute" | grep -i verdict; }
printf '%s' "$oute" | grep -q 'baseline had no specs to lint' \
  || { bad "spec-less baseline should say so explicitly, not blame the tool"; printf '%s\n' "$oute" | grep -i verdict; }

# 6) UNMEASURED — the lint could not RUN (swarm.sh absent beside reanalyze.sh). Same "—", but a DIFFERENT
# claim: "—" has three causes and reporting a broken tool as "the baseline had no specs" invents a fact about
# the baseline out of a missing binary. Both sides here have real specs, so only the tool is missing.
iso="$(mktemp -d)"; trap 'rm -rf "$d" "$e" "$iso"' EXIT
cp "$ROOT/lib/reanalyze.sh" "$iso/reanalyze.sh" \
  || { echo "[reanalyze] could not stage the isolated copy"; exit 1; }   # no swarm.sh beside it → cannot lint
outi="$(RA_REPO="$d" bash -c 'source "'"$iso"'/reanalyze.sh"; ace_reanalyze_report' 2>&1)"
jsi="$(RA_REPO="$d" bash -c 'source "'"$iso"'/reanalyze.sh"; ace_reanalyze_report --json' 2>&1)"
printf '%s\n' "$outi" | tr -s ' ' | grep -qF 'spec-lint GAPS — → —' \
  || { bad "with no swarm.sh both gap sides must be — (a lint that cannot run is not 0 gaps)"; printf '%s\n' "$outi" | grep -i 'GAPS'; }
[ "$(_jget gaps_after "$jsi")" = null ] || bad "gaps_after must be null when the lint cannot run, got: '$(_jget gaps_after "$jsi")'"
printf '%s' "$outi" | grep -q 'spec-lint UNAVAILABLE' \
  || { bad "a missing lint must be reported as UNAVAILABLE, not as a fact about the baseline contents"; printf '%s\n' "$outi" | grep -i verdict; }
printf '%s' "$outi" | grep -qE 'MORE spec gaps|cleaner breakdown|same gaps/spec' \
  && { bad "REGRESSION: a comparison was invented from an unmeasured lint"; printf '%s\n' "$outi" | grep -i verdict; }

[ "$ok" = 1 ] && echo "[reanalyze] PASS ✓" || { echo "[reanalyze] FAIL ✗"; exit 1; }
