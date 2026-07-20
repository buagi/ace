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
