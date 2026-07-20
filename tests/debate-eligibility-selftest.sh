#!/usr/bin/env bash
# debate-eligibility-selftest — pins WHICH specs get debated.
#
# POLICY UNDER TEST (inverted 2026-07-20): debate everything EXCEPT the provably trivial.
#     trivial == risk: LOW  AND  tier: FAST  AND  every C1-C6 trigger section dead
#
# Both directions are load-bearing and both are asserted. A spec wrongly excluded ships its defect; a spec
# wrongly included bills a paid cross-model dialogue on every run. The exclusion set is deliberately tiny,
# so most of this file is about the ways a spec must NOT be mistaken for trivial.
#
# The history is why the tests below look paranoid. The gate began as `risk: HIGH` alone -- on a real
# project that was 2 specs of 9, missing every architectural and UX spec. Widening it then introduced the
# opposite bug: 147 pre-template specs carrying no `tier:`/`risk:` markers at all were read as DECLARED
# trivial, because absence of a marker was treated as a declaration. Unknown must resolve toward debating.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

fail=0
bad(){ echo "FAIL: $*"; fail=1; }
D="$(mktemp -d)" || exit 1
trap 'rm -rf "$D"' EXIT

# spec <name> <header-attrs> <C-section-id> <C-body>  — writes a spec, prints its path.
# header-attrs is the literal "risk: X · tier: Y" text, or "" for a pre-template spec with no markers.
spec(){
  local n="$1" attrs="$2" cid="${3:-C3}" body="${4:-N/A — nothing user-facing.}"
  { if [ -n "$attrs" ]; then printf '# Spec: %s   (slug: %s · %s)\n' "$n" "$n" "$attrs"
    else printf '# Spec: %s (ROADMAP L1)\n\n## Root need (3-WHYs)\nWhy: legacy pre-template spec.\n' "$n"; fi
    printf '\n## 3. Scope\nIn: x\n\n## %s. Section\n%s\n\n## 9. Tail\nend\n' "$cid" "$body"
  } > "$D/$n.md"
  printf '%s' "$D/$n.md"
}

elig(){
  local sp="$1"; shift
  local extra="$*"                     # captured BEFORE `set --`, which clears $@
  ( [ -n "$extra" ] && eval "$extra"
    set --                             # A13: a sourced lib must never inherit our positional params
    . lib/debate.sh >/dev/null 2>&1
    if out="$(_debate_spec_eligible "$sp" 2>&1)"; then printf 'YES %s' "$out"; else printf 'NO %s' "$out"; fi )
}
yes_(){ case "$(elig "$1" "${@:3}")" in YES*) ;; *) bad "$2";; esac; }
no_(){  case "$(elig "$1" "${@:3}")" in NO*)  ;; *) bad "$2";; esac; }

# --- the ONLY thing that may be skipped: declared-trivial ------------------------------------------------
t="$(spec triv 'risk: LOW · tier: FAST' C3 'N/A — nothing user-facing.')"
no_ "$t" "a DECLARED-trivial spec (risk LOW + tier FAST + dead C3) was debated — the exclusion does not work at all"

# --- every axis that must force a debate -----------------------------------------------------------------
yes_ "$(spec hi   'risk: HIGH · tier: FAST' C3 'N/A — none.')"                          "risk: HIGH was not debated — the original signal regressed"
yes_ "$(spec full 'risk: LOW · tier: FULL'  C3 'N/A — none.')"                          "tier: FULL was not debated"

# ARCHITECTURE — the axis this change was requested for. Each C-section, independently.
for c in C1:contract C2:data-model C4:NFRs; do
  id="${c%%:*}"
  yes_ "$(spec "arch-$id" 'risk: LOW · tier: FAST' "$id" 'POST /api/x returns {id}. Consumed by the worker.')" \
       "ARCHITECTURE spec with a populated $id was NOT debated — this is the whole point of the change"
done
yes_ "$(spec sec 'risk: LOW · tier: FAST' C5 'Owner-only; authz check before body parse.')" "a populated C5 (security) was not debated"
yes_ "$(spec ux  'risk: LOW · tier: FAST' C3 'Settings page: owner sees the form; non-owner a notice.')" "a populated C3 (user-facing) was not debated"
yes_ "$(spec live 'risk: LOW · tier: FAST' C6 'Touches the live deploy path; rollback = revert the flag.')" "a populated C6 (live path) was not debated"

# --- UNKNOWN must resolve toward debating (the 147-spec bug) ---------------------------------------------
r="$(elig "$(spec legacy '')")"
case "$r" in YES*) ;; *) bad "a PRE-TEMPLATE spec with no tier:/risk: marker was skipped as trivial — absence of a declaration is not a declaration of triviality; this silently exempted 147 of 156 real specs"$'\n'"  $r";; esac
grep -qi 'undeclared' <<<"$r" || bad "the undeclared case was not named as such in the reason: $r"

# --- a dead section must not be mistaken for a live one --------------------------------------------------
no_ "$(spec ph  'risk: LOW · tier: FAST' C1 '<Endpoint · request/response shape · errors.>')" \
    "the UNEDITED template placeholder counted as a live section — every untouched spec would be debated"
no_ "$(spec emp 'risk: LOW · tier: FAST' C1 '')"          "an EMPTY section counted as live"
no_ "$(spec api 'risk: LOW · tier: FAST' C3 'API-only. Callers handle status codes.')" \
    "'API-only' in C3 counted as a user-facing surface"
# ...but API-only says nothing about CONTRACTS: the same text under C1 is a live architectural section.
yes_ "$(spec api1 'risk: LOW · tier: FAST' C1 'API-only. POST /api/x, 401 on unauth.')" \
     "'API-only' suppressed a populated C1 — that exemption is specific to the UX section"

# --- scope knobs -----------------------------------------------------------------------------------------
t="$(spec triv2 'risk: LOW · tier: FAST' C3 'N/A — none.')"
yes_ "$t" "DEBATE_SCOPE=all did not widen to a trivial spec"        export DEBATE_SCOPE=all
yes_ "$t" "DEBATE_ALL=1 did not widen to a trivial spec"            export DEBATE_ALL=1
yes_ "$t" "DEBATE_MIN_RISK=LOW did not widen to a trivial spec"     export DEBATE_MIN_RISK=LOW
no_  "$(spec ux2 'risk: LOW · tier: FAST' C3 'Settings page with owner/non-owner states.')" \
     "DEBATE_SCOPE=high still debated a non-HIGH spec — the cost-constrained escape hatch is broken" export DEBATE_SCOPE=high

# --- D6: THE RISK SEVERITY TABLE -------------------------------------------------------------------------
# The gate tested only `risk: HIGH` and let every other value fall through to the trivial path, INVERTING
# severity: `risk: critical` was classified trivial and never debated while `risk: HIGH` was debated.
# `risk: medium` is not hypothetical — compliance-legal-pages.md in the live trading-portal repo carries it,
# written by ACE's own re-spec. Only an explicit LOW-end value may count as low; everything else, including
# values nobody anticipated, must resolve toward debating. Each row is an otherwise-TRIVIAL spec (tier: FAST,
# all C1-C6 dead) so the risk marker is the ONLY thing that can decide it.
while read -r rv exp note; do
  [ -n "${rv:-}" ] || continue
  sp="$(spec "risk-$exp-$(printf '%s' "$rv" | tr -cd 'A-Za-z0-9')" "risk: $rv · tier: FAST" C3 'N/A — none.')"
  r="$(elig "$sp")"
  case "$exp:$r" in
    yes:YES*|no:NO*) ;;
    *) bad "risk: $rv — expected $exp, got '${r%% *}' ($note)"$'\n'"  $r" ;;
  esac
done <<'TABLE'
HIGH       yes  the-original-signal-must-not-regress
high       yes  the-marker-is-case-insensitive
critical   yes  MORE-severe-than-high-must-never-be-classified-trivial
medium     yes  live-repo-value-unknown-must-resolve-toward-debating
severe     yes  a-severity-word-nobody-added-to-the-list
P0-blocker yes  an-invented-vocabulary-must-not-silently-exempt
LOW        no   the-only-value-that-may-count-as-low
low        no   lowercase-low-is-still-low
TABLE

# ABSENT must stay its OWN class, never folded into `low`. With NEITHER marker the spec is `undeclared` and
# debated (asserted above); with `tier: FAST` present and all C-sections dead it stays trivial, because FAST is
# itself a positive declaration. Pinned here so a future "simplification" cannot collapse absent into low —
# which would make every unmarked legacy spec look trivially skippable again.
# OPEN QUESTION (deliberately NOT changed here, out of D6's scope — D6 is about risk VALUES): the module's
# stated rule is `trivial == risk: LOW AND tier: FAST AND dead sections`, and this arm skips on a FAST tier
# with no risk marker at all. Exactly 1 spec tree-wide on trading-portal is in that shape and it is not
# ROADMAP-linked, so nothing a run touches is affected today. Flagged for the owner rather than widened.
r="$(elig "$(spec risk-absent-fast 'tier: FAST' C3 'N/A — none.')")"
case "$r" in NO*) ;; *) bad "tier: FAST + dead sections + no risk marker changed classification — if this was intentional, update the OPEN QUESTION note above: $r";; esac
grep -qi 'no risk marker' <<<"$r" || bad "that skip must still report the absent marker honestly: $r"

# --- D6: the skip reason must quote the spec, never contradict it ----------------------------------------
# The message was a hardcoded "risk: LOW, tier: FAST" printed regardless of the file, so a reader asking why a
# critical spec was skipped was told the spec said LOW. A wrong reason ends an investigation; a bare skip only
# delays one. Only genuinely-trivial specs reach this message, so drive it through DEBATE_SCOPE=high (which
# skips everything not high-or-above) to get a NON-low spec onto the skip path.
r="$(elig "$(spec quote-med 'risk: medium · tier: FAST' C3 'N/A — none.')" export DEBATE_SCOPE=high)"
case "$r" in NO*) ;; *) bad "DEBATE_SCOPE=high must skip a medium-risk spec: $r";; esac
grep -qi 'risk: medium' <<<"$r" || bad "the skip reason must quote the risk value the spec ACTUALLY declares (medium): $r"
grep -qi 'risk: LOW'    <<<"$r" && bad "the skip reason claimed 'risk: LOW' for a spec that declares medium — it states a fact the artifact contradicts: $r"
# a spec with NO markers at all must say so, rather than inventing values for both fields
r="$(elig "$(spec quote-none '' C3 'N/A — none.')" export DEBATE_SCOPE=high)"
grep -qi 'no risk marker' <<<"$r" || bad "a spec with no risk marker must say 'no risk marker', not quote a value it lacks: $r"
grep -qi 'no tier marker' <<<"$r" || bad "a spec with no tier marker must say so: $r"

# --- F9: a knob that restricts spend must never fail OPEN, or fail SILENTLY -------------------------------
# `DEBATE_SCOPE=hgih` fell through to `nontrivial` — WIDER than the `high` intended — and `DEBATE_MIN_RISK=MEDIUM`
# was a no-op. Both left the operator believing cost was capped when it was not.
r="$(elig "$(spec knob-typo 'risk: LOW · tier: FULL' C3 'N/A — none.')" export DEBATE_SCOPE=hgih)"
grep -qi 'hgih' <<<"$r"        || bad "an unrecognised DEBATE_SCOPE must NAME the bad value: $r"
grep -qi 'nontrivial' <<<"$r"  || bad "an unrecognised DEBATE_SCOPE must state which default is in use: $r"
grep -qi 'valid' <<<"$r"       || bad "an unrecognised DEBATE_SCOPE must list the valid values: $r"
r="$(elig "$(spec knob-mr 'risk: LOW · tier: FULL' C3 'N/A — none.')" export DEBATE_MIN_RISK=MEDIUM)"
grep -qi 'DEBATE_MIN_RISK' <<<"$r" || bad "an unrecognised DEBATE_MIN_RISK must be reported, not silently ignored: $r"
grep -qi 'MEDIUM' <<<"$r"          || bad "an unrecognised DEBATE_MIN_RISK must name the bad value: $r"
# ...and the RECOGNISED values must still work (a validator that rejects everything is not a fix)
no_ "$(spec knob-ok 'risk: LOW · tier: FAST' C3 'Settings page: owner sees the form.')" \
    "DEBATE_MIN_RISK=high must still narrow to high-or-above" export DEBATE_MIN_RISK=high
yes_ "$(spec knob-ok2 'risk: critical · tier: FAST' C3 'N/A — none.')" \
     "DEBATE_MIN_RISK=high must still admit a critical spec" export DEBATE_MIN_RISK=high

# --- the skip must be NARRATED (C1) ----------------------------------------------------------------------
r="$(elig "$(spec triv3 'risk: LOW · tier: FAST' C3 'N/A — none.')")"
grep -qi 'SKIPPED' <<<"$r"      || bad "a skipped spec produced no narration — the run would look fully debated: $r"
grep -qi 'DEBATE_SCOPE' <<<"$r" || bad "the skip message does not say how to widen it: $r"

if [ "$fail" = 0 ]; then
  echo "debate-eligibility-selftest: PASS — only declared-trivial skipped; architecture/UX/security/live-path all debated; undeclared resolves to debate; dead sections excluded; knobs work; skips narrated"
else
  echo "debate-eligibility-selftest: FAIL"
fi
exit "$fail"
