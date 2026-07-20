#!/usr/bin/env bash
# debate-eligibility-selftest — pins WHICH specs get debated. This gate spends real money per spec, so both
# directions matter: a spec that should be debated and is not is a missed defect; a spec that should not be
# and is costs a paid cross-model dialogue on every run.
#
# HISTORY: the gate was `risk: HIGH` alone. Measured on a real project that selected 2 of 9 roadmap-linked
# specs. Both were security specs and the debate found blocker-severity bugs in both -- the targeting was
# good, the reach was not: 8 of those 9 described a real user-facing surface, and UX/design defects are
# precisely the kind a single model talks itself into. The gate now also fires on the spec template's OWN
# marker for a user-facing surface (a populated "C3. UX flow"), rather than a second, competing definition.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

fail=0
bad(){ echo "FAIL: $*"; fail=1; }

D="$(mktemp -d)" || exit 1
trap 'rm -rf "$D"' EXIT

# mkspec <name> <risk> <c3-body>
mkspec(){
  printf '<!-- ace-spec-template v1 -->\n# Spec: %s   (slug: %s · risk: %s · tier: FULL)\n\n## 3. Scope\nIn: x\n\n## C3. UX flow            <!-- trigger: user-facing surface -->\n%s\n\n## C6. Risk\nn/a\n' \
    "$1" "$1" "$2" "$3" > "$D/$1.md"
  printf '%s' "$D/$1.md"
}

# eligible? -> prints "YES <reason>" / "NO <reason>"; reason comes from the narration on stderr (C1).
elig(){
  local sp="$1"; shift
  local extra="$*"          # captured BEFORE `set --`, which clears $@ -- see below
  ( [ -n "$extra" ] && eval "$extra"      # apply the knob first; it must survive into the sourced lib
    set --                                # A13: a sourced lib must never see our positional params.
                                          # This clears $@, so the knobs are applied ABOVE, not via "$@" --
                                          # doing it after silently dropped them and made both knob
                                          # assertions fail against code that was actually correct.
    . lib/debate.sh >/dev/null 2>&1
    if out="$(_debate_spec_eligible "$sp" 2>&1)"; then printf 'YES %s' "$out"; else printf 'NO %s' "$out"; fi )
}

# --- SHOULD be debated ----------------------------------------------------------------------------------
s="$(mkspec high-api HIGH 'API-only. No user surface.')"
case "$(elig "$s")" in YES*) ;; *) bad "risk: HIGH spec was NOT eligible — the original signal regressed";; esac

s="$(mkspec low-ux LOW 'Settings page: owner sees the form; non-owner sees a static notice. Loading + empty states.')"
r="$(elig "$s")"
case "$r" in YES*) ;; *) bad "a LOW-risk spec with a real user-facing C3 was NOT eligible — this is the whole point of the change"$'\n'"  $r";; esac
grep -qi 'user-facing' <<<"$r" || bad "eligibility reason did not name the user-facing trigger: $r"

# --- should NOT be debated (each exclusion pinned separately) --------------------------------------------
s="$(mkspec low-na LOW 'N/A — backend only, no user-visible change.')"
case "$(elig "$s")" in NO*) ;; *) bad "an explicit 'N/A' C3 was treated as user-facing — every backend spec would now be debated";; esac

s="$(mkspec low-placeholder LOW '<Key flow(s) · loading/empty/error states · accessibility note.>')"
case "$(elig "$s")" in NO*) ;; *) bad "the UNEDITED template placeholder counted as user-facing — a spec nobody filled in would be debated";; esac

s="$(mkspec low-apionly LOW 'API-only. Callers handle the status codes.')"
case "$(elig "$s")" in NO*) ;; *) bad "a spec that says API-only was treated as user-facing";; esac

s="$(mkspec low-empty LOW '')"
case "$(elig "$s")" in NO*) ;; *) bad "an EMPTY C3 counted as user-facing";; esac

# a spec with no C3 section at all
printf '# Spec: nosection   (slug: nosection · risk: LOW)\n\n## 3. Scope\nIn: x\n' > "$D/nosection.md"
case "$(elig "$D/nosection.md")" in NO*) ;; *) bad "a spec with NO C3 section counted as user-facing";; esac

# --- the widening knobs -----------------------------------------------------------------------------------
s="$(mkspec low-na2 LOW 'N/A — backend only.')"
case "$(elig "$s" export DEBATE_MIN_RISK=LOW)" in YES*) ;; *) bad "DEBATE_MIN_RISK=LOW did not widen to every spec";; esac
case "$(elig "$s" export DEBATE_ALL=1)"        in YES*) ;; *) bad "DEBATE_ALL=1 did not widen to every spec";; esac

# --- the skip must be NARRATED (C1: the silent return 0 is how the old filter hid its own narrowness) -----
r="$(elig "$(mkspec low-na3 LOW 'N/A — backend.')")"
grep -qi 'SKIPPED' <<<"$r" || bad "a skipped spec produced no narration — a run would look fully debated: $r"
grep -qi 'DEBATE_MIN_RISK' <<<"$r" || bad "the skip message does not tell the user how to widen it: $r"

if [ "$fail" = 0 ]; then
  echo "debate-eligibility-selftest: PASS — HIGH-risk + user-facing debated; N/A, placeholder, API-only, empty and absent C3 excluded; knobs widen; skips narrated"
else
  echo "debate-eligibility-selftest: FAIL"
fi
exit "$fail"
