#!/usr/bin/env bash
# cli-dispatch-selftest.sh — per-PR static+behavioural gate for ./ace's ARG PARSER and its help/dispatch
# agreement. Free, offline, zero tokens.
#
# WHY THIS EXISTS (the bug it locks down):
#   ./ace's parser used to end in `-*) ;;` — a silent swallow of every unknown flag. One missing dash on
#   `ace autorun --explain` therefore did not print the read-only delivery policy; it fell through to the
#   default arm and started a REAL autonomous build loop that commits, pushes and merges. The same swallow
#   ate the documented sub-command modifiers (`--capture`, `--stub`, `--diagnose`, `--emit-tsv`,
#   `--propose-prompt`), so `ace debate score --capture` silently scored STALE snapshots and still printed
#   a GO verdict. Both halves must hold together, which is why they are asserted in one file.
#
# HOW IT TESTS THE REAL THING WITHOUT RUNNING IT:
#   We cannot execute `ace autorun -explain` to prove it now refuses — if the guard ever regressed, the test
#   itself would launch a live build loop. So we AWK the parser block straight out of ./ace (same technique
#   prompt-contracts.sh uses on install.sh's heredoc) and run THAT in isolation, with the dispatch `case`
#   left behind. It is the shipped code, byte for byte, with nothing destructive attached to it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
fail=0
bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }
# die() is for STRUCTURAL failures, and it must ABORT rather than set a flag. Two of the blocks we cut out of
# ./ace are EXECUTED; if an anchor has drifted, continuing would run whatever fell out of awk. `bad` here was
# a real hazard: a surviving opening anchor with a lost closing anchor dumped the entire remainder of ./ace
# — dispatch table included — into a file this test then ran three times.
die(){ printf 'FAIL: %s\ncli-dispatch: FAIL — aborting (refusing to execute an unverified slice of ./ace)\n' "$*"; exit 1; }
[ -f ace ] || { echo "cli-dispatch: ./ace not found"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- extract <start-re> <end-re> <hard-stop-re> <outfile> ------------------------------------------------
# Copies one block out of ./ace, with two independent bounds so a drifted anchor can never yield an
# open-ended slice:
#   1. HARD STOP — a structural line that cannot legally occur inside the block. Checked BEFORE printing, so
#      a lost closing anchor truncates at a known landmark instead of running to EOF.
#   2. TERMINATOR CHECK — the block must actually END on <end-re>. Truncation at the hard stop, or a run to
#      EOF, fails this and aborts. This is what makes executing the result safe.
# Anchors are ERE strings passed via -v, so they use [)] rather than \) — a backslash would be eaten by awk's
# escape processing before the regex ever sees it.
extract(){
  # awk's own rc is judged before anything else: a bad regex or unreadable input must abort here, not be
  # inferred from the shape of a half-written file.
  awk -v s="$1" -v e="$2" -v h="$3" '$0~s{f=1} f&&$0~h{exit} f{print} f&&$0~e{exit}' ace > "$4" ||
    die "awk failed while extracting /$1/ from ./ace"
  [ -s "$4" ] || die "extraction of /$1/ from ./ace produced nothing — opening anchor drifted"
  tail -n1 "$4" | grep -qE "$2" ||
    die "extraction of /$1/ did not end on its closing anchor /$2/ (last line: '$(tail -n1 "$4")') — anchors drifted"
}

# --- extract the parser: from the dispatch banner down to the `done` that closes the while-loop ----------
# The block carries cmd="", _ace_arg_push() and the whole flag `case`. The hard stop is `case "${cmd:-menu}"`
# at column 0 — the dispatch table itself — so no command can ever be dispatched from here.
extract '^# -+ dispatch$' '^done$' '^case "' "$WORK/parse.body"
grep -q '_ace_arg_push' "$WORK/parse.body" || die "parser block extracted but contains no _ace_arg_push — ./ace changed shape"
{ echo 'set -uo pipefail'
  echo 'usage(){ :; }'                                  # stub: we assert on the error line, not the help text
  echo 'err(){ printf "err: %s\n" "$*" >&2; }'
  echo 'ACE_VERSION=selftest'
  cat "$WORK/parse.body"
  echo 'printf "%s|%s|%s|%s\n" "${cmd:-}" "${ACE_ARG:-}" "${ACE_ARG2:-}" "${ACE_ARG3:-}"'
} > "$WORK/parse.sh"

# parse <args…> → "cmd|ARG|ARG2|ARG3"; exit status is the parser's own
parse(){ bash "$WORK/parse.sh" "$@" 2>"$WORK/err"; }

# --- 1. documented sub-command modifiers survive into argv ----------------------------------------------
# Each of these is a real documented invocation whose flag must reach the tests/*.sh harness that parses it.
for t in \
  "debate score --capture|debate|score|--capture|" \
  "debate score --emit-tsv|debate|score|--emit-tsv|" \
  "debate autotune DEBATE_MAX=3 --stub|debate|autotune|DEBATE_MAX=3|--stub" \
  "debate autotune --propose-prompt|debate|autotune|--propose-prompt|" \
  "debate --diagnose|debate|--diagnose||" ; do
  args="${t%%|*}"; want="${t#*|}"
  # shellcheck disable=SC2086  # word-splitting is the point: $args is a fixed literal argv, not user input
  got="$(parse $args)"
  [ "$got" = "$want" ] || bad "ace $args parsed as '$got', expected '$want' (modifier flag was dropped or misrouted)"
done

# --- 2. a flag never becomes the command ----------------------------------------------------------------
# _ace_arg_push must skip the `cmd` slot: if a modifier landed there, a typo would surface as
# "unknown command" and, worse, a real command could be shadowed.
got="$(parse --capture)"
[ "${got%%|*}" = "" ] || bad "a modifier flag was allowed to become the command ('$got')"

# --- 3. THE SAFETY ASSERTION: an unknown flag is fatal, during parsing --------------------------------
# This is the one that stops `ace autorun -explain` from starting a live build loop. It must exit non-zero
# BEFORE the dispatch case is reached — which is exactly what running the parser in isolation proves.
parse autorun -explain >/dev/null; rc=$?
[ "$rc" = 1 ] || bad "unknown flag '-explain' did not exit 1 (got $rc) — 'ace autorun -explain' would fall through to a LIVE build loop"
grep -qi 'unknown flag' "$WORK/err" || bad "unknown flag produced no 'unknown flag' diagnostic on stderr"
parse -zzz >/dev/null; rc=$?
[ "$rc" = 1 ] || bad "bare unknown flag '-zzz' did not exit 1 (got $rc)"
# …while every flag ace documents in its own usage() must still parse. Guards against an over-broad reject.
for f in --dry-run --yes --confirm --watch --index --publish --explain --check --force --demo --json --host; do
  parse $f >/dev/null 2>&1 || bad "documented flag $f is now rejected by the unknown-flag arm"
done

# --- 4. `ace swarm` help and dispatch agree (both directions) -------------------------------------------
# The usage() line and the typo-path fallback previously each omitted subcommands the other had, and both
# omitted some the dispatch table implements. Derive the truth from the dispatch arms and compare.
# `tail -n +2` drops the `  swarm)` header line itself: harvesting it too would put the literal token `swarm`
# in $impl, and both help strings contain the word "swarm" — a trivially-true assertion masking a real gap.
# The closing anchor matches `esac ;;` at ANY indentation (it was pinned to exactly 21 spaces, so a re-indent
# sent awk to EOF and dragged in the arms of every later command); extract's terminator check enforces it.
extract '^  swarm[)]' '^ +esac ;;$' '^esac$' "$WORK/swarm.body"
impl="$(tail -n +2 "$WORK/swarm.body" | grep -oE '^ *[a-z|-]+\)' | tr -d ' )' | tr '|' '\n' | grep -vE '^\*$|^$' | sort -u)"
[ -n "$impl" ] || die "swarm block extracted but yielded no dispatch arms — ./ace changed shape"
# A NON-EMPTY harvest is not proof of a COMPLETE one. The closing anchor matches `esac ;;` at any depth, so a
# nested case inside the swarm arm truncates the block early — and the terminator check cannot notice, because
# the truncated slice legitimately ends on that anchor. Measured on a scratch copy: injecting one nested
# `esac ;;` cut the harvest from 20 subcommands to 7 and the suite still printed PASS. ace already uses that
# nesting in sibling arms (:377, :390, :408), so this is a live shape, not a hypothetical. Cross-check the
# count against the arms the dispatch actually declares, so a silent truncation FAILS instead of shrinking.
_declared="$(awk '/^  swarm[)]/{f=1;next} f&&/^  [a-z][a-z|-]*[)]/{exit} f' ace | grep -cE '^ *[a-z|-]+\)')"
[ "$(printf '%s\n' "$impl" | grep -c .)" -ge "$(( _declared > 3 ? _declared - 3 : 1 ))" ] \
  || die "swarm harvest looks TRUNCATED: got $(printf '%s\n' "$impl" | grep -c .) subcommand(s) but the dispatch declares ~$_declared arms — a nested 'esac ;;' likely cut the block short"
help_top="$(grep -m1 '^  ace swarm ' ace)"
help_fb="$(grep -m1 'usage: ace swarm {' ace)"
for sub in $impl; do
  case "$help_top" in *"$sub"*) ;; *) bad "swarm subcommand '$sub' is dispatched but missing from usage() (ace:'  ace swarm …')" ;; esac
  case "$help_fb"  in *"$sub"*) ;; *) bad "swarm subcommand '$sub' is dispatched but missing from the 'usage: ace swarm {…}' fallback" ;; esac
done

# --- 5. usage() lists every top-level command a user is told to run --------------------------------------
for c in debate scorecard swarm autorun reanalyze quality stats; do
  grep -qE "^  ace $c" ace || bad "'ace $c' is dispatched but absent from usage()"
done

# --- 6. the debate toggles are actually wired: config → env, env wins ------------------------------------
# Settings → Cross-model debate writes SPEC_DEBATE/REVIEW_DEBATE with config_set, but every consumer
# (autoloop.sh, swarm-run.sh) reads the ENVIRONMENT with a default of 0. Without the export block in ./ace
# the menu shows ON while every run skips the debate — a decorative safety toggle.
extract 'ACE_DEBATE_ENV anchor' '^export _ACE_DEBATE_FROM_ENV$' '^# -+ dispatch$' "$WORK/dbg.body"
# Anchor on a token that exists ONLY in the extracted block (the footer above mentions SPEC_DEBATE too).
grep -q '_ACE_DEBATE_FROM_ENV=' "$WORK/dbg.body" || die "debate config→env block extracted but contains no assignment — ./ace changed shape"
{ echo 'set -uo pipefail'
  echo 'config_get(){ eval "printf %s \"\${FAKECFG_$1:-}\""; }'   # stand-in store, keyed by FAKECFG_<KEY>
  cat "$WORK/dbg.body"
  echo 'printf "%s|%s|%s\n" "${SPEC_DEBATE:-unset}" "${REVIEW_DEBATE:-unset}" "${_ACE_DEBATE_FROM_ENV# }"'
} > "$WORK/dbg.sh"

got="$(FAKECFG_SPEC_DEBATE=1 FAKECFG_REVIEW_DEBATE=1 bash "$WORK/dbg.sh")"
[ "$got" = "1|1|" ] || bad "config SPEC_DEBATE/REVIEW_DEBATE=1 did not reach the environment (got '$got') — the Settings toggle stays decorative"
got="$(bash "$WORK/dbg.sh")"
[ "$got" = "unset|unset|" ] || bad "empty config exported something (got '$got') — must fall through to the consumer's own default of 0"
# env beats config, and is reported as an override so the menu can say so
got="$(FAKECFG_SPEC_DEBATE=1 SPEC_DEBATE=0 bash "$WORK/dbg.sh")"
[ "$got" = "0|unset|SPEC_DEBATE" ] || bad "env SPEC_DEBATE=0 did not beat config SPEC_DEBATE=1 (got '$got') — precedence must be env > config > default"

if [ "$fail" = 0 ]; then
  echo "cli-dispatch: PASS — unknown flags fatal, modifier flags routed, swarm help ↔ dispatch agree, debate toggles wired (env > config > default)"
  exit 0
fi
echo "cli-dispatch: FAIL — see above"
exit 1
