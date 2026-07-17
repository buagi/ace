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
  mkdir -p "$bdir/specs" 2>/dev/null || return 0
  # the uncompleted items are the thing being re-derived — save them + the whole ROADMAP + every spec
  grep -nE '^[[:space:]]*- \[ \] ' "$repo/ROADMAP.md" 2>/dev/null | grep -v 'add your first' > "$bdir/open-items.txt" 2>/dev/null || true
  cp "$repo/ROADMAP.md" "$bdir/ROADMAP.md" 2>/dev/null || true
  if [ -d "$repo/.opencode/specs" ]; then cp "$repo/.opencode/specs/"*.md "$bdir/specs/" 2>/dev/null || true; fi
  : > "$bdir/.captured"
  local ni ns; ni="$(_ra_c . <"$bdir/open-items.txt")"; ns="$(ls "$bdir/specs/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  printf 'reanalyze: baseline snapshotted — %s open ROADMAP item(s) + %s spec(s) → %s\n' "$ni" "$ns" "$(_ra_dir)/before/" >&2
  return 0
}

# count SPECGAP lines from the deterministic lint over a specs dir (via the ACE-install swarm.sh); "—" if unavailable
_ra_gaps(){
  local dir="$1" repo="$2"
  [ -d "$dir" ] || { printf '—'; return; }
  ls "$dir"/*.md >/dev/null 2>&1 || { printf '0'; return; }
  [ -f "$_RA_LIB/swarm.sh" ] || { printf '—'; return; }
  REPO="$repo" bash "$_RA_LIB/swarm.sh" spec-lint "$dir"/*.md 2>/dev/null | _ra_c '^SPECGAP'
}

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
  # BEFORE
  local b_open b_spec b_gaps b_items
  b_open="$(_ra_c . <"$bdir/open-items.txt" 2>/dev/null)"
  b_spec="$(ls "$bdir/specs/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  b_gaps="$(_ra_gaps "$bdir/specs" "$repo")"
  b_items="$(_ra_specced_items "$bdir/ROADMAP.md")"
  # AFTER (current tree)
  local a_open a_spec a_gaps a_items
  a_open="$(grep -nE '^[[:space:]]*- \[ \] ' "$repo/ROADMAP.md" 2>/dev/null | grep -v 'add your first' | _ra_c .)"
  a_spec="$(ls "$repo/.opencode/specs/"*.md 2>/dev/null | wc -l | tr -d ' ')"
  a_gaps="$(_ra_gaps "$repo/.opencode/specs" "$repo")"
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

  if [ "$json" = 1 ]; then
    printf '{"captured":true,"open_before":%s,"open_after":%s,"specs_before":%s,"specs_after":%s,"specs_new":%s,"specs_changed":%s,"gaps_before":"%s","gaps_after":"%s","specced_items_before":%s,"specced_items_after":%s}\n' \
      "${b_open:-0}" "${a_open:-0}" "${b_spec:-0}" "${a_spec:-0}" "$new" "$changed" "$b_gaps" "$a_gaps" "${b_items:-0}" "${a_items:-0}"
    return 0
  fi

  _delta(){ local x="$1" y="$2"; case "$x$y" in *—*) printf '—' ;; *) local d=$((y-x)); [ "$d" -gt 0 ] && printf '+%s' "$d" || printf '%s' "$d" ;; esac; }
  printf '\n%s══ REANALYZE — before → after ══%s   %s(baseline: %s/before/)%s\n' "$C_B" "$C_R" "$C_G" "$(_ra_dir)" "$C_R"
  printf '  open ROADMAP items      %4s → %-4s  (%s)\n' "${b_open:-—}" "${a_open:-—}" "$(_delta "${b_open:-0}" "${a_open:-0}")"
  printf '  specs                   %4s → %-4s  (%s new · %s changed)\n' "${b_spec:-—}" "${a_spec:-—}" "$new" "$changed"
  printf '  spec-lint GAPS          %4s → %-4s  (%s)  %s← lower is better%s\n' "${b_gaps:-—}" "${a_gaps:-—}" "$(_delta "${b_gaps:-—}" "${a_gaps:-—}")" "$C_G" "$C_R"
  printf '  items carrying a Spec:  %4s → %-4s  (%s)  %s← finer breakdown%s\n' "${b_items:-—}" "${a_items:-—}" "$(_delta "${b_items:-0}" "${a_items:-0}")" "$C_G" "$C_R"
  printf '\n  Read the actual re-derivation:\n'
  printf '    git diff --stat -- ROADMAP.md .opencode/specs/          %s# what the re-assessment rewrote%s\n' "$C_G" "$C_R"
  printf '    diff -ru %s/before/specs .opencode/specs                %s# spec-by-spec%s\n' "$(_ra_dir)" "$C_G" "$C_R"
  printf '    ace scorecard                                            %s# deep quality read of the NEW breakdown%s\n' "$C_G" "$C_R"
  # a one-line verdict
  local verdict="inspect the diff"
  case "$b_gaps$a_gaps" in
    *—*) : ;;
    *) if [ "${a_gaps:-0}" -lt "${b_gaps:-0}" ] 2>/dev/null; then verdict="cleaner breakdown (fewer spec gaps) — good candidate to run the loop on"
       elif [ "${a_gaps:-0}" -gt "${b_gaps:-0}" ] 2>/dev/null; then verdict="MORE spec gaps than before — inspect before running the loop"
       else verdict="same gap count — read the diff to judge the qualitative change"; fi ;;
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
