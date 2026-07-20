#!/usr/bin/env bash
# reanalyze.sh — the REANALYZE=1 re-assessment mode: snapshot the current OPEN (uncompleted) ROADMAP
# items + their specs BEFORE the planner re-derives them, then a read-only before/after compare so you can
# see whether re-running the full research→spec→slice pipeline actually produced a BETTER breakdown.
#
# Two entry points:
#   reanalyze_snapshot [repo]      — capture the pristine baseline ONCE (idempotent; the planner's REANALYZE
#                                    branch in autoloop.sh calls this before it mutates anything).
#   ace_reanalyze_report [--json]  — diff before/ vs the current tree: open-item count, specs new/changed,
#                                    and the deterministic spec-lint GAP delta (did the breakdown get cleaner?).
#
# Pure read-only + fail-soft: a missing artifact renders "—", never an error. No hot-loop instrumentation, so a
# run behaves identically whether or not you later report it. Mirrors scorecard.sh's use of the ACE-install
# swarm.sh for the lint (swarm.sh lives HERE, not in the scored project). See docs/trial-runs.md.
set -uo pipefail

_RA_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_ra_c(){ local n; n="$(grep -cE "$@" 2>/dev/null)" || true; printf '%s' "${n:-0}"; }   # grep -c without the "0\n0" double-print pitfall

# where the baseline lives, relative to the repo root
_ra_dir(){ printf '%s' "${REANALYZE_DIR:-.opencode/reanalyze}"; }

# reanalyze_snapshot [repo] — copy the OPEN ROADMAP items + all specs into before/ exactly once. Guarded by a
# .captured marker so re-invocation across planning passes never clobbers the pristine baseline.
reanalyze_snapshot(){
  local repo="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  [ -f "$repo/ROADMAP.md" ] || return 0
  local bdir="$repo/$(_ra_dir)/before"
  [ -f "$bdir/.captured" ] && return 0
  mkdir -p "$bdir" 2>/dev/null || return 0
  # RETRY HYGIENE: we only get here with the marker OFF, so anything already in specs/ is a HALF copy from a
  # failed earlier attempt — and the sources have moved on since (a spec deleted, or the planner already
  # re-derived the tree). Copying on top would leave those stale files in place, and the `ncp == nsrc`
  # completeness test below — which only sees the CURRENT sources — would then stamp that MIXED tree
  # "PRISTINE and COMPLETE". Nothing recoverable is lost: every file is re-copied from source right below,
  # and an unmarked before/ is by contract not a baseline at all (the report says "no baseline" for it).
  rm -rf "$bdir/specs" 2>/dev/null || true
  mkdir -p "$bdir/specs" 2>/dev/null || return 0
  # the uncompleted items are the thing being re-derived — save them + the whole ROADMAP + every spec.
  # Every copy is checked: `.captured` is the marker that says "this baseline is PRISTINE and COMPLETE", and
  # it is what makes the snapshot idempotent forever after. Writing it over a HALF copy (an unreadable spec, a
  # full disk, a racing planner) permanently locks in a baseline that is missing files — and the report then
  # measures the re-derivation against a partial before/, silently attributing the missing specs to the
  # planner. So: mark ONLY on a complete copy, otherwise leave the marker off so the NEXT call retries.
  local ok=1
  grep -nE '^[[:space:]]*- \[ \] ' "$repo/ROADMAP.md" 2>/dev/null | grep -v 'add your first' > "$bdir/open-items.txt" 2>/dev/null
  [ -f "$bdir/open-items.txt" ] || ok=0          # grep rc is 1 on "no open items" — that is a legit EMPTY file, not a failure
  cp "$repo/ROADMAP.md" "$bdir/ROADMAP.md" 2>/dev/null || ok=0
  local nsrc=0 ncp=0 f
  if [ -d "$repo/.opencode/specs" ] && ls "$repo/.opencode/specs/"*.md >/dev/null 2>&1; then
    # copy one at a time: a single `cp a b c dir/` reports one rc for the batch, so a partial copy looks clean
    for f in "$repo/.opencode/specs/"*.md; do
      [ -e "$f" ] || continue; nsrc=$((nsrc+1)); cp "$f" "$bdir/specs/" 2>/dev/null && ncp=$((ncp+1))
    done
    [ "$ncp" = "$nsrc" ] || ok=0
  fi
  if [ "$ok" != 1 ]; then
    # fail-soft for the CALLER (the planner must still run) but never claim a baseline we do not have.
    printf 'reanalyze: baseline snapshot INCOMPLETE (%s/%s spec(s) copied) — NOT marking it captured; `ace reanalyze report` will say "no baseline" until a clean snapshot succeeds.\n' "$ncp" "$nsrc" >&2
    return 0
  fi
  : > "$bdir/.captured"
  local ni ns; ni="$(_ra_c . <"$bdir/open-items.txt")"; ns="$(ls "$bdir/specs/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  printf 'reanalyze: baseline snapshotted — %s open ROADMAP item(s) + %s spec(s) → %s\n' "$ni" "$ns" "$(_ra_dir)/before/" >&2
  return 0
}

# count SPECGAP lines from the deterministic lint over a specs dir (via the ACE-install swarm.sh); "—" if unavailable.
# NOTE the zero-specs arm: it returns the "—" (unmeasured) sentinel, NOT 0. A dir with no specs was never linted,
# so "0 gaps" is vacuous — and it is the COMMON baseline for the headline use of this mode (re-assess a project
# that had no specs yet). Reporting it as 0 made the after-side (real specs, real gaps) look like a REGRESSION:
# "MORE spec gaps than before — inspect before running the loop" for the one case where specs were just created.
# The `case *—*` guards in _delta and the verdict already suppress a comparison against an unmeasured side.
# ── GATE SCOPE (D1) ────────────────────────────────────────────────────────────────────────────────────────
# What this report measures MUST be what the run's spec gate measures, and the gate's population is the specs
# REFERENCED from ROADMAP.md (autoloop.sh `_solo_specs`, lifted into swarm.sh as `swarm_roadmap_specs` so both
# sides share ONE definition) — NOT `.opencode/specs/*.md`. Those are wildly different sets: measured on
# trading-portal, 10 files carrying 1 gap versus 157 files carrying 2638. This report used the tree, so it
# printed "2637 → 2640 gaps" and derived a VERDICT from it, for a gate that had ONE gap. ~147 of those files
# are legacy specs that predate the template and that no run will ever touch, so nearly every gap being
# reported was not merely stale — it was unreachable.
#
# The full-tree number is still worth SEEING (it is a real backlog), so it is still computed and printed, but
# labelled as legacy and deliberately kept OUT of the verdict. A number that steers a decision and a number
# that is only context must not look alike.
#
# _ra_active <roadmap> <specdir> — the gate's population, resolved inside specdir (the baseline is a FLAT copy,
# so references are matched by basename there). Empty when swarm.sh is unavailable OR the roadmap links none;
# the caller separates those two by testing for swarm.sh itself.
_ra_active(){
  local roadmap="$1" dir="$2"
  [ -f "$_RA_LIB/swarm.sh" ] || return 0
  [ -f "$roadmap" ] || return 0
  bash "$_RA_LIB/swarm.sh" roadmap-specs "$roadmap" "$dir" 2>/dev/null
}

# _ra_gaps <specdir> <repo> <roadmap> — gaps over the GATE SCOPE only.
# Returns the "—" (unmeasured) sentinel, NEVER 0, when the lint could not run or the ROADMAP links no specs.
# Those are distinct states and the verdict names each one; what they share is that neither is a clean bill of
# health, and 0 reads as exactly that. This is the same trap the zero-specs arm was already written for: a set
# that was never linted is not a clean set. The `case *—*` guards in _delta and the verdict suppress any
# comparison against an unmeasured side.
_ra_gaps(){
  local dir="$1" repo="$2" roadmap="$3" _lint _specs
  [ -d "$dir" ] || { printf '—'; return; }
  [ -f "$_RA_LIB/swarm.sh" ] || { printf '—'; return; }
  _specs="$(_ra_active "$roadmap" "$dir")"
  [ -n "$_specs" ] || { printf '—'; return; }        # no ACTIVE specs — the verdict has a dedicated arm
  # capture, then require OUTPUT before counting. Piping the lint straight into the counter turned a lint that
  # FAILED (non-zero rc, nothing on stdout) into "0 gaps" — a clean bill of health from a check that never
  # ran, which then reads as "same gaps/spec" in the verdict. A successful lint always prints its
  # "spec-lint: N spec(s) · M gap(s)" summary, so empty output means it did not run.
  # shellcheck disable=SC2086 — one path per line from swarm_roadmap_specs; word-splitting is intended
  _lint="$(REPO="$repo" bash "$_RA_LIB/swarm.sh" spec-lint $_specs 2>/dev/null)"
  [ -n "$_lint" ] || { printf '—'; return; }
  printf '%s\n' "$_lint" | _ra_c '^SPECGAP'
}

# _ra_legacy_gaps <specdir> <repo> — the WHOLE-TREE count. CONTEXT ONLY: printed, labelled, and never an input
# to the verdict or to the gaps/spec rate. Same "—" contract as above.
_ra_legacy_gaps(){
  local dir="$1" repo="$2" _lint
  [ -d "$dir" ] || { printf '—'; return; }
  ls "$dir"/*.md >/dev/null 2>&1 || { printf '—'; return; }
  [ -f "$_RA_LIB/swarm.sh" ] || { printf '—'; return; }
  _lint="$(REPO="$repo" bash "$_RA_LIB/swarm.sh" spec-lint "$dir"/*.md 2>/dev/null)"
  [ -n "$_lint" ] || { printf '—'; return; }
  printf '%s\n' "$_lint" | _ra_c '^SPECGAP'
}

# gaps PER SPEC ×100 (integer maths — no bc dependency). The raw gap TOTAL is not comparable across a
# re-derivation that changes the spec COUNT: 12 gaps over 8 specs is a cleaner breakdown than 6 over 2, yet the
# raw total calls it twice as bad. "—" whenever either input is unmeasured or there are no specs to divide by.
_ra_rate100(){
  local g="$1" s="$2"
  case "$g" in ''|*—*) printf '—'; return ;; esac
  [ "${s:-0}" -gt 0 ] 2>/dev/null || { printf '—'; return; }
  printf '%s' "$(( g * 100 / s ))"
}
# render a ×100 rate as a plain decimal (also a valid JSON number); passes the "—" sentinel through untouched
_ra_rate_fmt(){ case "${1:-}" in ''|*—*) printf '—' ;; *) printf '%d.%02d' "$(( $1 / 100 ))" "$(( $1 % 100 ))" ;; esac; }
# JSON scalar: a measured count stays a BARE number like every other field; an unmeasured one is `null`, not
# the "—" glyph in a string (which forced every consumer to string-compare one field and int-compare the rest).
_ra_jnum(){ case "${1:-}" in ''|*—*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
# same, for a ×100 rate: `null` or a bare decimal (never the "—" glyph, never a quoted string)
_ra_jrate(){ case "${1:-}" in ''|*—*) printf 'null' ;; *) _ra_rate_fmt "$1" ;; esac; }

# count ROADMAP items that carry a 'Spec:' field — a proxy for how finely features are broken into increments
_ra_specced_items(){ grep -nE '^[[:space:]]*- \[ \] ' "$1" 2>/dev/null | _ra_c -iE 'Spec:[[:space:]]*\.opencode/specs/'; }

ace_reanalyze_report(){
  local json=0; { [ "${1:-}" = "--json" ] || [ "${ACE_JSON:-0}" = 1 ]; } && json=1
  local repo="${RA_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  local bdir="$repo/$(_ra_dir)/before"
  local C_B="${C_BOLD:-}" C_R="${C_RESET:-}" C_Y="${C_YELLOW:-}" C_G="${C_GREY:-}"
  if [ ! -f "$bdir/.captured" ]; then
    if [ "$json" = 1 ]; then printf '{"captured":false}\n'; else
      printf '%sreanalyze:%s no baseline snapshot found. Run a plan-only re-assessment first:\n   REANALYZE=1 ace autorun --yes   (or:  ace reanalyze)\n' "$C_Y" "$C_R"; fi
    return 0
  fi
  # is the lint available at all? "no active specs" and "cannot lint" are different claims and the verdict
  # must not merge them — testing swarm.sh once, here, is what keeps them apart below.
  local lint_ok=1; [ -f "$_RA_LIB/swarm.sh" ] || lint_ok=0
  # BEFORE — b_spec is the whole tree (context); b_act is the GATE SCOPE, which is what the rate/verdict use.
  local b_open b_spec b_act b_gaps b_legacy b_items
  b_open="$(_ra_c . <"$bdir/open-items.txt" 2>/dev/null)"
  b_spec="$(ls "$bdir/specs/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  b_act="$(_ra_active "$bdir/ROADMAP.md" "$bdir/specs" | _ra_c .)"
  b_gaps="$(_ra_gaps "$bdir/specs" "$repo" "$bdir/ROADMAP.md")"
  b_legacy="$(_ra_legacy_gaps "$bdir/specs" "$repo")"
  b_items="$(_ra_specced_items "$bdir/ROADMAP.md")"
  # AFTER (current tree)
  local a_open a_spec a_act a_gaps a_legacy a_items
  a_open="$(grep -nE '^[[:space:]]*- \[ \] ' "$repo/ROADMAP.md" 2>/dev/null | grep -v 'add your first' | _ra_c .)"
  a_spec="$(ls "$repo/.opencode/specs/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  a_act="$(_ra_active "$repo/ROADMAP.md" "$repo/.opencode/specs" | _ra_c .)"
  a_gaps="$(_ra_gaps "$repo/.opencode/specs" "$repo" "$repo/ROADMAP.md")"
  a_legacy="$(_ra_legacy_gaps "$repo/.opencode/specs" "$repo")"
  a_items="$(_ra_specced_items "$repo/ROADMAP.md")"
  # specs new / changed
  local new=0 changed=0 f base
  if [ -d "$repo/.opencode/specs" ]; then
    for f in "$repo/.opencode/specs/"*.md; do
      [ -e "$f" ] || continue; base="$(basename "$f")"
      if [ ! -f "$bdir/specs/$base" ]; then new=$((new+1))
      elif ! cmp -s "$f" "$bdir/specs/$base"; then changed=$((changed+1)); fi
    done
  fi

  # gaps-per-spec — what the verdict actually compares (see _ra_rate100). Divided by the ACTIVE spec count,
  # not the tree: both operands must come from the same population or the rate is not a rate at all.
  local b_rate a_rate; b_rate="$(_ra_rate100 "$b_gaps" "$b_act")"; a_rate="$(_ra_rate100 "$a_gaps" "$a_act")"

  if [ "$json" = 1 ]; then
    # gaps_* and gaps_per_spec_* are BARE numbers (or null when unmeasured) — matching every other field here.
    # `gaps_*` is the GATE SCOPE (what a run will act on); `legacy_gaps_*` is the whole-tree backlog. Consumers
    # that were reading gaps_* were reading the tree before this change — the field name kept its meaning of
    # "the number that matters", which is now the true one.
    printf '{"captured":true,"open_before":%s,"open_after":%s,"specs_before":%s,"specs_after":%s,"active_specs_before":%s,"active_specs_after":%s,"specs_new":%s,"specs_changed":%s,"gaps_before":%s,"gaps_after":%s,"legacy_gaps_before":%s,"legacy_gaps_after":%s,"gaps_per_spec_before":%s,"gaps_per_spec_after":%s,"specced_items_before":%s,"specced_items_after":%s}\n' \
      "${b_open:-0}" "${a_open:-0}" "${b_spec:-0}" "${a_spec:-0}" "${b_act:-0}" "${a_act:-0}" "$new" "$changed" \
      "$(_ra_jnum "$b_gaps")" "$(_ra_jnum "$a_gaps")" \
      "$(_ra_jnum "$b_legacy")" "$(_ra_jnum "$a_legacy")" \
      "$(_ra_jrate "$b_rate")" "$(_ra_jrate "$a_rate")" \
      "${b_items:-0}" "${a_items:-0}"
    return 0
  fi

  _delta(){ local x="$1" y="$2"; case "$x$y" in *—*) printf '—' ;; *) local d=$((y-x)); [ "$d" -gt 0 ] && printf '+%s' "$d" || printf '%s' "$d" ;; esac; }
  printf '\n%s══ REANALYZE — before → after ══%s   %s(baseline: %s/before/)%s\n' "$C_B" "$C_R" "$C_G" "$(_ra_dir)" "$C_R"
  printf '  open ROADMAP items      %4s → %-4s  (%s)\n' "${b_open:-—}" "${a_open:-—}" "$(_delta "${b_open:-0}" "${a_open:-0}")"
  printf '  specs (whole tree)      %4s → %-4s  (%s new · %s changed)\n' "${b_spec:-—}" "${a_spec:-—}" "$new" "$changed"
  printf '  ACTIVE specs            %4s → %-4s  (%s)  %s← ROADMAP-linked — the gate'"'"'s scope%s\n' "${b_act:-—}" "${a_act:-—}" "$(_delta "${b_act:-0}" "${a_act:-0}")" "$C_G" "$C_R"
  printf '  spec-lint GAPS          %4s → %-4s  (%s)  %s← ACTIVE specs only%s\n' "${b_gaps:-—}" "${a_gaps:-—}" "$(_delta "${b_gaps:-—}" "${a_gaps:-—}")" "$C_G" "$C_R"
  printf '  spec-lint GAPS/spec     %4s → %-4s         %s← lower is better · what the verdict judges%s\n' "$(_ra_rate_fmt "$b_rate")" "$(_ra_rate_fmt "$a_rate")" "$C_G" "$C_R"
  # The legacy row is deliberately last, deliberately grey, and deliberately says it is not judged. It used to
  # BE the headline (and the verdict's input) — on trading-portal that meant a 2638 next to a real gate figure
  # of 1. Keep it visible (the backlog is real) but never let it be mistaken for the run's scope again.
  printf '  legacy backlog gaps     %4s → %-4s  (%s)  %s← ALL %s spec(s) incl. pre-template files no run touches · NOT judged%s\n' \
    "${b_legacy:-—}" "${a_legacy:-—}" "$(_delta "${b_legacy:-—}" "${a_legacy:-—}")" "$C_G" "${a_spec:-?}" "$C_R"
  printf '  items carrying a Spec:  %4s → %-4s  (%s)  %s← finer breakdown%s\n' "${b_items:-—}" "${a_items:-—}" "$(_delta "${b_items:-0}" "${a_items:-0}")" "$C_G" "$C_R"
  printf '\n  Read the actual re-derivation:\n'
  printf '    git diff --stat -- ROADMAP.md .opencode/specs/          %s# what the re-assessment rewrote%s\n' "$C_G" "$C_R"
  printf '    diff -ru %s/before/specs .opencode/specs                %s# spec-by-spec%s\n' "$(_ra_dir)" "$C_G" "$C_R"
  printf '    ace scorecard                                            %s# deep quality read of the NEW breakdown%s\n' "$C_G" "$C_R"
  # a one-line verdict
  # Judge on gaps PER SPEC, not the raw total: the re-derivation is expected to change the spec count, and the
  # raw total punishes it for producing MORE (finer) specs. Either side unmeasured ("—", e.g. a spec-less
  # baseline or no lint available) ⇒ stay silent and tell the reader to look, never invent a regression.
  local verdict="inspect the diff"
  case "$b_rate$a_rate" in
    # "—" has THREE causes (no specs · no swarm.sh · lint produced nothing) and they are not the same claim.
    # Attributing all of them to "baseline had no specs" invents a fact about the baseline's CONTENTS out of a
    # missing/broken tool. Test the spec COUNT for that arm; anything else is an unavailable measurement.
    # Order matters. "cannot lint" is checked FIRST: with swarm.sh missing, the ACTIVE count is 0 for the same
    # reason the gaps are "—", and reading that 0 as "the ROADMAP links no specs" would invent a fact about the
    # ROADMAP's CONTENTS out of a missing tool — the exact error this arm was written to stop.
    *—*) if [ "$lint_ok" != 1 ]; then
           verdict="spec-lint UNAVAILABLE (swarm.sh missing, or the lint produced no output) — gaps were NOT measured, so no comparison is possible; read the diff"
         elif [ "$b_gaps" = '—' ] && [ "${b_act:-0}" = 0 ]; then
           # D1(d): an empty gate scope must SAY it is empty. It is not 0 gaps and it is not all-clear — it is
           # a ROADMAP that points at no spec, so the gate would lint nothing at all on the next run.
           verdict="baseline had no specs to lint — NO ACTIVE SPECS in the baseline (its ROADMAP.md linked none via 'Spec:'), so there was no gate scope to measure; nothing to compare against — read the diff (this is the expected shape for a first re-assessment)"
         elif [ "$a_gaps" = '—' ] && [ "${a_act:-0}" = 0 ]; then
           verdict="NO ACTIVE SPECS in the current tree — ROADMAP.md links none via 'Spec:'${a_spec:+ (the tree holds $a_spec spec file(s), but the gate would lint NONE of them)}. This is NOT a clean bill of health: nothing was measured. Wire the specs into ROADMAP items, then re-report"
         else
           verdict="spec-lint UNAVAILABLE (swarm.sh missing, or the lint produced no output) — gaps were NOT measured, so no comparison is possible; read the diff"
         fi ;;
    *) if [ "$a_rate" -lt "$b_rate" ] 2>/dev/null; then verdict="cleaner breakdown ($(_ra_rate_fmt "$a_rate") vs $(_ra_rate_fmt "$b_rate") gaps/spec) — good candidate to run the loop on"
       elif [ "$a_rate" -gt "$b_rate" ] 2>/dev/null; then verdict="MORE spec gaps per spec ($(_ra_rate_fmt "$a_rate") vs $(_ra_rate_fmt "$b_rate")) — inspect before running the loop"
       else verdict="same gaps/spec — read the diff to judge the qualitative change"; fi ;;
  esac
  printf '\n  %sverdict:%s %s\n\n' "$C_B" "$C_R" "$verdict"
}

# CLI: reanalyze.sh report [--json] | snapshot [repo]  — only when EXECUTED, never when sourced for its functions
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    report)   shift; ace_reanalyze_report "${1:-}" ;;
    snapshot) shift; reanalyze_snapshot "${1:-}" ;;
    *) echo "usage: reanalyze.sh report [--json] | snapshot [repo]" >&2 ;;
  esac
fi
