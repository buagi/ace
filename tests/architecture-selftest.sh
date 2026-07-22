#!/usr/bin/env bash
# architecture-selftest.sh — pins `ace arch`: the panels stay aligned, and the menu stays wired to its arms.
#
# TWO FAILURE MODES, both silent:
#   1. ASCII PANELS WITH ANSI COLOUR IN THEM. Escape sequences have zero visible width but count towards
#      ${#str}, so a hand-aligned panel drifts the moment anyone edits a line. The rows are drawn through
#      _arch_row/_arch_top, which measure VISIBLE width — and the first version of _arch_top measured the RAW
#      title, escapes included, so every box lid came out 2 columns short of its own body. Asserted in BOTH
#      colour modes, because a bug that only appears with colour on is a bug nobody sees in CI.
#   2. MENU/ARM RENUMBERING. explain_menu lists entries and then dispatches on $MENU_CHOICE by NUMBER. An
#      inserted entry that does not get a matching arm runs the WRONG explainer for every option below it,
#      and nothing errors.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
fail=0
bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }

# --- 1. every panel row is the same width, with colour ON and OFF -----------------------------------------
render() { # <1=colour>
  bash -c '
    if [ "${1:-0}" = 1 ]; then C_BOLD=$(printf "\033[1m"); C_RESET=$(printf "\033[0m")
      C_GREY=$(printf "\033[90m"); C_DIM=$(printf "\033[2m"); C_CYAN=$(printf "\033[36m")
    else C_BOLD=; C_RESET=; C_GREY=; C_DIM=; C_CYAN=; fi
    banner(){ :; }; explain_menu(){ :; }; _agent_counts(){ printf "11 12"; }
    eval "$(sed -n "/^# ----* box drawing/,/^explain_menu() {/p" lib/architecture.sh | sed "/^explain_menu() {/d")"
    show_architecture' _ "$1" 2>&1
}
# Width is measured in DISPLAY COLUMNS, not characters — that distinction IS the bug class. An emoji is one
# character and two columns, so a character-count check calls a row correct while the terminal renders it
# overhanging its own box; an ANSI escape is several characters and zero columns, which is the opposite error.
# One column-accurate measurement covers both. (The previous version of this file tried to catch the emoji
# half with `LC_ALL=C grep -q $'\xf0\x9f'`, which never matched anything — a guard that cannot fire.)
_widths() { # <colour 0|1> -> the distinct display widths of the panel rows, one per line
  render "$1" | python3 -c '
import sys, re, unicodedata
strip = re.compile(r"\x1b\[[0-9;]*m")
def cols(t):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in t)
ws = {cols(strip.sub("", l.rstrip("\n"))) for l in sys.stdin if l.startswith(("  ┌", "  │", "  └"))}
print("\n".join(str(w) for w in sorted(ws)))'
}
for c in 0 1; do
  widths="$(_widths "$c")"
  n="$(printf '%s\n' "$widths" | grep -c .)"
  [ "$n" = 1 ] || bad "ace arch panels are RAGGED in DISPLAY COLUMNS with colour=$c — widths seen: $(printf '%s' "$widths" | tr '\n' ' ') (a double-width glyph, or an escape measured as visible)"
done
rows="$(render 0 | awk '/^  [┌│└]/' | grep -c .)"
[ "${rows:-0}" -ge 40 ] || bad "ace arch rendered only $rows panel rows — the workflow panels did not render"

# --- 3. all four workflows are actually presented ---------------------------------------------------------
out="$(render 0)"
# Anchor on each panel's OWN header, not on a word that also appears in the menu panel: asserting "SWARM"
# passed happily with the entire coordinator box deleted, because the menu row "▶ SWARM" still matched.
for w in 'PICK A WORKFLOW' 'OUTER' 'COORDINATOR' 'one feature = one fresh session'; do
  grep -qF -- "$w" <<<"$out" || bad "ace arch lost the panel headed '$w'"
done
for w in 'SOLO' 'SWARM' 'PLAN-ONLY' 'SERVICE' 'INNER'; do
  grep -qF -- "$w" <<<"$out" || bad "ace arch no longer names the '$w' workflow"
done
# each of the four workflow panels must have real content, not just a lid
for hdr in 'COORDINATOR' 'OUTER'; do
  # ANCHOR ON THE BORDERS (^  ┌ / ^  └), not on any ┌/└ anywhere in the line: the panel ART ITSELF contains
  # └ and ┐ characters (the loop-back arrows), so an unanchored terminator ended the count mid-panel and
  # reported a healthy box as gutted.
  body="$(awk -v h="$hdr" 'index($0,h)&&/^  ┌/{f=1;next} /^  └/{f=0} f' <<<"$out" | grep -c .)"
  [ "${body:-0}" -ge 5 ] || bad "the '$hdr' panel rendered only ${body:-0} rows — it was gutted"
done
for v in 'ace start' 'ace start solo' 'ace stop' 'ace dash' 'ace stats' 'ace reanalyze' 'ace loop start'; do
  grep -qF -- "$v" <<<"$out" || bad "ace arch never names '$v' — the map must show how each workflow is started/stopped"
done
# it must NOT point at 'ace report' for reading a run (that files a GitHub issue)
grep -qF 'ace report' <<<"$out" && bad "ace arch points at 'ace report' — that files a GitHub issue; the report surface is 'ace stats'"

# --- 4. menu entries and dispatch arms stay in step -------------------------------------------------------
# Count the menu entries (title::blurb pairs) and the numbered case arms; they must match exactly.
entries="$(sed -n '/menu "Learn more (on demand)"/,/^    case /p' lib/architecture.sh | grep -c '::')"
arms="$(sed -n '/case "\$MENU_CHOICE" in/,/esac/p' lib/architecture.sh | grep -oE '[0-9]+\)' | sort -u | grep -c .)"
[ "$entries" = "$arms" ] || bad "ace arch menu has $entries entries but $arms dispatch arms — an unmatched entry runs the WRONG explainer for every option below it"
# and every explainer the case names must exist as a function
while IFS= read -r fn; do
  grep -qE "^${fn}\(\)" lib/architecture.sh || bad "menu dispatches to ${fn}(), which is not defined"
done < <(sed -n '/case "\$MENU_CHOICE" in/,/esac/p' lib/architecture.sh | grep -oE 'explain_[a-z_]+' | sort -u)

[ "$fail" = 0 ] && echo "architecture-selftest: PASS — panels aligned (colour on+off), no double-width glyphs, 4 workflows + their verbs present, menu entries match dispatch arms"
[ "$fail" = 0 ] || echo "architecture-selftest: FAIL — see above"
exit "$fail"
