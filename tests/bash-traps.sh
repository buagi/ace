#!/usr/bin/env bash
# bash-traps.sh — STATIC gate over ACE's own shell for the mechanically-findable bash traps from the
# 2026-07-18 audit (lessons A1-A11). Converts "remember this" into "cannot recur".
#
# WHY A STATIC GATE AND NOT A CHECKLIST: every one of these traps was found by REPRODUCTION, never by
# reading — three generations of fixes each re-introduced the class they were fixing (lesson B8). A human
# reviewer demonstrably cannot hold A1-A11 in working memory across a 152-defect audit. A grep can.
#
# DESIGN RULE — PRECISION OVER RECALL. This runs at ERROR level in CI, so one false positive blocks every
# PR, and a gate that blocks every PR gets disabled, and a disabled gate protects nothing. Every pattern
# here is measured against the real tree before shipping. Where the honest broad rule was unusably noisy
# (see A4 below) the rule is NARROWED and the narrowing is documented, rather than shipped noisy or
# silently dropped.
#
# THREE ESCAPE HATCHES, in descending order of preference:
#   1. Fix the code.
#   2. Per-line allowlist: append `# bash-traps: allow <ID> — <reason>` to the offending line. The reason
#      is MANDATORY and asserted non-empty — an exception without a stated reason is just a suppression.
#   3. BASELINE (below): pre-existing sites that predate this gate. Fail-closed for anything NEW, loud
#      about what already exists, and it can only ever SHRINK — a stale entry is a hard failure, so the
#      baseline cannot quietly become a permanent parking lot.
#
# SELF-TEST (lesson B1 applied to the gate itself): a pattern that silently stops matching is worse than
# no pattern, because it reports "clean" (lesson C1 — fail-open reporting is the dominant defect class).
# `--selftest` runs EVERY check against a known-bad fixture and asserts it FIRES, and against a known-good
# fixture and asserts it does NOT. The default mode runs the scan AND the self-test, so CI always gets both.
#
# APOSTROPHE NOTE (lesson A6, which this file implements): every regex needing a literal apostrophe builds
# it from $SQ below instead of embedding it. Writing the A6 detector with a raw apostrophe inside a
# single-quoted pattern would have been the trap detecting itself, one edit too late.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1

SQ=$(printf '\047')          # a literal apostrophe, never typed inline — see APOSTROPHE NOTE above
fail=0
FILES=()

bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }

# ---------------------------------------------------------------------------------------------------
# BASELINE — pre-existing sites, verified by hand on 2026-07-19 against the tree this gate landed on.
# Format: <ID>|<file>|<fixed substring that must still appear on the offending line>|<why it is still here>
#
# These are REAL findings, not false positives. They are baselined (not suppressed, not silently narrowed
# away) because this gate landed as its own change and fixing nine call sites across four files in the same
# change would have made the gate itself unreviewable. Each is reported loudly on every run.
#
# A baseline entry that no longer matches anything is a HARD FAILURE. That is deliberate: it forces the
# entry to be deleted when the code is fixed, so the list is a shrinking debt register rather than a
# growing amnesty.
# ---------------------------------------------------------------------------------------------------
# Fields are TAB-separated, deliberately: a shell fragment legitimately contains `|` (a pipeline is exactly
# what several of these checks look for), so a `|` delimiter truncated the stored fragment mid-way. The
# staleness check then matched a shorter, far less specific string — and could tell a developer who had
# CORRECTLY fixed the code that the detector had regressed. A tab cannot occur inside these one-line fragments.
BASELINE=(
  "A1	lib/scaffold.sh	local os=\"\$1\" arch=\"\$2\" out=	out= interpolates \${os}/\${arch} declared on the SAME local, so both expand from the OUTER scope — split into two local statements"
  "A4	tests/autoloop-selftest.sh	git status --porcelain | grep -q .	porcelain output is unbounded on a dirty tree; rewrite as grep -q . <<<\"\$(git status --porcelain)\""   # bash-traps: allow A4 — baseline register entry, not an invocation
  "A4	lib/scaffold.sh	-name .git -type d 2>/dev/null | grep -q .	find output is unbounded on a deep tree; same here-string rewrite applies"
  "A8	tests/agent-goldens.sh	opencode run --agent \"\$c\"	nightly capture mode, never runs in CI; still hangs if a human runs it detached"   # bash-traps: allow A8 — baseline register entry, not an invocation
  "A8	tests/agent-goldens.sh	opencode run --agent researcher	same nightly capture path"   # bash-traps: allow A8 — baseline register entry, not an invocation
  "A11	lib/gitflow.sh	run git init -q; ok \"git init\"	run() propagates rc but the ; discards it, so ok fires on a failed init"
  "A11	lib/gitflow.sh	run git branch -M main; ok	same shape on the master->main rename"
  "A11	ace	run rm -rf \"\$ACE_CONFIG_DIR\"; ok	claims 'ACE config removed' whether or not the rm succeeded (lesson C3)"
  "A11	ace	run rm -rf \"\$HOME/.config/opencode\"; ok	same shape on the opencode config removal"
  "A11	lib/scaffold.sh	run git init -q; ok \"git init\"	same shape as gitflow.sh:8"
)

# ---------------------------------------------------------------------------------------------------
# CHECKS. Each _chk_<ID> takes a file list and prints one `file:line:source` record per hit, nothing else.
# Filtering (allowlist, baseline) is the driver's job, so a check stays a pure pattern.
#
# COMMENT HANDLING: the ENTIRE match must fall before the first `#` on the line — note that every pattern
# uses `[^#]*` for its interior gaps, never `.*`. A first draft used `.*` in the middle and let matches
# span straight over a trailing comment, which produced four false positives on lines whose comment merely
# QUOTED the anti-pattern it was warning about. Constraining only the prefix is not enough.
# Known limitation: a `#` inside an earlier string literal masks the rest of the line. That direction is
# deliberate — it costs false NEGATIVES, and for a gate that blocks merges a miss is recoverable while a
# false block is not (lesson C2, asymmetry of harm, applied to the gate's own failure mode).
#
# COMMAND POSITION: patterns anchor with `^([^#]*[;&|(])?[[:space:]]*`, i.e. the construct must begin a
# command — start of line, or just after `;`, `&&`, `||`, `|`, `(`, `$(`. This is what separates a real
# invocation from PROSE ABOUT one. This tree documents its own traps heavily: agent prompts in
# lib/install.sh quote `grep -c PAT f || echo 0` verbatim, and tests/prompt-contracts.sh contains
# `grep -q 'opencode run --agent debater'`. Without the command-position anchor the gate flags the
# documentation of a bug as the bug — which is precisely the noise that gets a gate switched off.
# ---------------------------------------------------------------------------------------------------
# The optional keyword group is load-bearing: `if git diff … | grep -q` is command position too, and a
# first draft that omitted it silently dropped a real finding in lib/scaffold.sh. The self-test caught
# that, which is the whole argument for having one.
# `{` is in the set because `cond && { cmd; ok "..."; }` is command position too — omitting it hid two live
# A11 sites in `ace`, and the baseline masked the loss because the entries still matched TEXT. That is why
# the baseline is now verified by HIT, not by grep (see scan()).
CMDPOS='^([^#]*[;&|{(])?[[:space:]]*((if|elif|while|until|!)[[:space:]]+)?'

# A1 — `local a=X b=$a`. The $a in the SECOND assignment expands from the OUTER scope: bash binds the
# locals left to right but does not make an earlier one visible to a later one on the same statement, so
# under `set -u` this is an unbound-variable death and without it a silent empty string. Killed the
# cross-model debate on entry, behind a fail-open. Needs a real parser, not a regex: we walk the tokens of
# each local/declare/typeset statement and flag any RHS referencing a name declared earlier in the SAME
# statement. Stops scanning at the first token that is neither a bare name nor name=value (e.g. `-a`, `&&`)
# so exotic declare forms are skipped rather than guessed at.
_chk_A1(){
  awk '
    { line=$0; sub(/#.*/,"",line) }
    line ~ /(^|[;&|{(])[[:space:]]*(local|declare|typeset)[[:space:]]/ {
      n=split(line,tok," "); ndecl=0; started=0
      for(i=1;i<=n;i++){
        # a NEW local/declare statement resets scope: `local a=1; local b=$a` is CORRECT, because the
        # first statement has already completed by the time the second is evaluated.
        if(tok[i]=="local"||tok[i]=="declare"||tok[i]=="typeset"){started=1;ndecl=0;continue}
        if(!started) continue
        if(tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/){
          eq=index(tok[i],"="); nm=substr(tok[i],1,eq-1); rhs=substr(tok[i],eq+1)
          for(j=1;j<=ndecl;j++){
            p=decl[j]
            if(rhs ~ ("[$]" p "([^A-Za-z0-9_]|$)") || rhs ~ ("[$][{]" p "[}:]")) {
              print FILENAME":"FNR":"$0; next
            }
          }
          decl[++ndecl]=nm
        } else if(tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { decl[++ndecl]=tok[i] }
        else { started=0 }
      }
    }' "$@" 2>/dev/null
}

# A2 — `grep -c PAT f || echo 0`. grep -c PRINTS "0" and ALSO exits 1 on no match, so the || fires on top
# of the already-emitted 0 and the caller reads "0\n0" — which then fails every integer comparison it is
# fed to. Correct shape: `v=$(grep -c ... || true); v=${v:-0}`.
# The trailing `[[:space:]]*([);]|$)` requires the `echo 0` to actually END a shell construct. Prose that
# quotes the anti-pattern closes with a quote or a backtick instead, and is correctly ignored.
_chk_A2(){ grep -nE "${CMDPOS}grep +-[a-zA-Z]*c[a-zA-Z]*[^#]*\|\| *echo +\"?0\"?[[:space:]]*([);]|$)" "$@" 2>/dev/null; }

# A4 — a pipeline into `grep -q` under `set -o pipefail`. grep -q exits at the FIRST match, the writer on
# the left takes SIGPIPE, and the pipeline returns 141 even though the match succeeded. This flipped a
# DATA-LOSS guard to fail-open past the 64KB pipe buffer (measured live at 215KB).
#
# NARROWED, DELIBERATELY. The literal rule from the lesson — flag `printf|echo` of a variable piped to
# `grep -q` — matches 98 sites in this tree, effectively all of them safe: a small printf finishes writing
# before grep can exit, so the SIGPIPE window never opens. Shipping that rule at ERROR level would have
# blocked every PR on day one and been switched off by day two. So we flag only UNBOUNDED producers, where
# exceeding the pipe buffer is a property of the input rather than of the source line: cat, git
# diff/log/show/status, find, curl, wget. That is where the real defect lived. The fix is the same in every
# case: `grep -q PAT <<<"$v"` — a here-string has no second process to kill.
_chk_A4(){ grep -nE "${CMDPOS}(cat |git +(diff|log|show|status)|find |curl |wget )[^|#]*\| *grep +-[a-zA-Z]*q" "$@" 2>/dev/null; }

# A5 — `git check-ignore` returns 1 for a TRACKED path regardless of the ignore rules, so an untrack sweep
# built on it silently matches nothing and reports a clean sweep (lesson C1). `--no-index` asks the
# question actually intended: "do the ignore rules cover this path", independent of the index.
_chk_A5(){ grep -nE "${CMDPOS}git +check-ignore" "$@" 2>/dev/null | grep -v -- "--no-index"; }

# A6 — an apostrophe inside a single-quoted jq/awk program TERMINATES the bash string. `jq '... don't ...'`
# closes at `don`, and what follows is reparsed as shell.
#
# RELIABLE FORM ONLY. A general "unbalanced apostrophe" counter is not viable here: legitimate multi-line
# single-quoted programs are everywhere in this tree, and bash -n (already a CI gate) catches the truly
# unterminated case at EOF anyway. What it does NOT catch is the case that stays syntactically valid, so we
# detect the unambiguous signature of that: a jq/awk program whose closing apostrophe is immediately
# followed by an alphanumeric. A real closing quote is followed by whitespace, ), |, ;, " or end of line —
# never by a letter. `'"'"'t ...' after `don` is exactly that, and English contractions in comments (which
# are common and harmless) are excluded by the ^[^#]* prefix.
_chk_A6(){ grep -nE "${CMDPOS}(jq|awk|gawk)([[:space:]]+-[^[:space:]]+)*[[:space:]]+${SQ}[^${SQ}#]*${SQ}[A-Za-z0-9_]" "$@" 2>/dev/null; }

# A8 — `opencode run` (any REPL-ish tool) blocks forever on non-TTY stdin waiting for an EOF that never
# arrives, then dies at its internal timeout while the caller's fail-open reports "nothing found".
#
# NOT DUPLICATED — EXTENDED. tests/prompt-contracts.sh already owns this check and it stays there, because
# it belongs next to that file's other opencode-transport assertions. Its scope is lib/*.sh only. This
# check covers the REST of the tree (ace, tests/*.sh, scripts/*.sh), which was never covered — and found
# two real sites on its first run. The meta-check further down asserts prompt-contracts.sh still carries
# its half, so deleting it turns THIS gate red rather than silently halving the coverage.
#
# Looks ahead 3 lines because an opencode invocation with a multi-line prompt can carry its redirect on a
# continuation line; without the lookahead every such call would be a false positive.
_chk_A8(){
  local f n src
  for f in "$@"; do
    case "$f" in lib/*.sh) continue ;; esac   # prompt-contracts.sh owns lib/ — do not double-report
    while IFS=: read -r n src; do
      [ -n "${n:-}" ] || continue
      sed -n "${n},$((n+3))p" "$f" 2>/dev/null | grep -qF "</dev/null" && continue
      printf '%s:%s:%s\n' "$f" "$n" "$src"
    done < <(grep -nE "${CMDPOS}opencode run " "$f" 2>/dev/null | grep -v pkill)
  done
}

# A11 — `cmd; ok "success"`. The `;` discards the rc, so the success message is printed the moment cmd can
# fail. Note that wrapping in run() does NOT help: run() faithfully returns the rc, and the `;` throws it
# away just the same. Gate on rc instead: `cmd && ok "..." || die "..."`.
#
# CONSERVATIVE BY CONSTRUCTION. Restricted to an explicit list of commands known to fail in normal
# operation, and to `ok` followed by a message (which excludes `ok=0`, the assignment used pervasively by
# the in-file selftests and the single largest false-positive source when this was first drafted).
_chk_A11(){ grep -nE "${CMDPOS}(run +)?(git|gh|curl|wget|jq|opencode|npm|node|python3?|ssh|scp|tar|mv|cp|rm|mkdir)\b[^;#]*; *ok +[\"${SQ}\$]" "$@" 2>/dev/null; }

CHECKS=(A1 A2 A4 A5 A6 A8 A11)
_desc(){ case "$1" in
  A1)  echo "same-line 'local a=X b=\$a' — \$a comes from the OUTER scope" ;;
  A2)  echo "'grep -c ... || echo 0' — grep -c prints 0 AND exits 1, emitting '0\\n0'" ;;
  A4)  echo "unbounded producer piped to 'grep -q' — SIGPIPE returns 141 under pipefail" ;;
  A5)  echo "'git check-ignore' without --no-index — returns 1 for any TRACKED path" ;;
  A6)  echo "apostrophe inside a single-quoted jq/awk program — terminates the bash string" ;;
  A8)  echo "'opencode run' without '</dev/null' — blocks forever on non-TTY stdin" ;;
  A11) echo "'<failable cmd>; ok \"...\"' — the ';' claims success unconditionally" ;;
esac; }

# _allowed <ID> <source-line> — an allowlist comment counts ONLY if it names this ID and carries a
# non-empty reason. Returns 2 for "claimed but reasonless", which the driver treats as a hard failure:
# an exception nobody had to justify is indistinguishable from a suppression.
_allowed(){
  local id="$1" src="$2" tail
  case "$src" in *"# bash-traps: allow $id"*) ;; *) return 1 ;; esac
  tail="${src##*# bash-traps: allow $id}"
  tail="${tail#"${tail%%[![:space:]]*}"}"           # strip leading whitespace
  tail="${tail#—}"; tail="${tail#-}"                # strip the em-dash or hyphen separator
  tail="${tail#"${tail%%[![:space:]]*}"}"
  [ -n "$tail" ] || return 2
  return 0
}

# _baselined <ID> <file> <source-line> — true if this exact known site is on the debt register.
# Sets BASELINE_MATCHED to the index of the entry that matched, so scan() can prove every entry was used.
BASELINE_MATCHED=""; BASELINE_HIT=""
_baselined(){
  local id="$1" f="$2" src="$3" e bid bfile bfrag i=0
  for e in "${BASELINE[@]}"; do
    i=$((i+1))
    bid="${e%%	*}"; e="${e#*	}"; bfile="${e%%	*}"; e="${e#*	}"; bfrag="${e%%	*}"
    [ "$bid" = "$id" ] && [ "$bfile" = "$f" ] || continue
    case "$src" in *"$bfrag"*) BASELINE_MATCHED="$i"; return 0 ;; esac
  done
  return 1
}

# ---------------------------------------------------------------------------------------------------
# SCAN
# ---------------------------------------------------------------------------------------------------
scan(){
  local id hits f n src rc baseline_hits=0
  for id in "${CHECKS[@]}"; do
    hits="$("_chk_$id" "${FILES[@]}")"
    [ -n "$hits" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      f="${line%%:*}"; line="${line#*:}"; n="${line%%:*}"; src="${line#*:}"
      _allowed "$id" "$src"; rc=$?
      if [ "$rc" = 0 ]; then continue
      elif [ "$rc" = 2 ]; then
        bad "$f:$n: '# bash-traps: allow $id' with NO REASON — state why, or fix the line"
        continue
      fi
      if _baselined "$id" "$f" "$src"; then
        baseline_hits=$((baseline_hits+1))
        BASELINE_HIT="$BASELINE_HIT|$BASELINE_MATCHED"     # record WHICH entry matched, for the audit below
        printf 'KNOWN [%s] %s:%s (baselined — real defect, tracked)\n' "$id" "$f" "$n"
        continue
      fi
      bad "[$id] $f:$n — $(_desc "$id")"
      printf '        %s\n' "$src"
    done <<<"$hits"
  done

  # EVERY baseline entry must have been HIT by its check on this run. Verified by hit, not by grepping the
  # file for the fragment — because the fragment can still be present while the CHECK has quietly stopped
  # matching it, which is exactly what happened when `{` was missing from CMDPOS: two live A11 sites in
  # `ace` went undetected and the text-based staleness check saw nothing wrong. A baseline that can hide a
  # broken detector is worse than no baseline (lesson C1). An unhit entry now means one of two things and
  # both must be loud: the code was fixed (prune the entry), or the check regressed (fix the check).
  local e bid bfile bfrag i=0
  for e in "${BASELINE[@]}"; do
    i=$((i+1))
    bid="${e%%	*}"; e="${e#*	}"; bfile="${e%%	*}"; e="${e#*	}"; bfrag="${e%%	*}"
    case "$BASELINE_HIT" in
      *"|$i|"*|*"|$i") continue ;;
    esac
    if [ ! -f "$bfile" ]; then
      bad "baseline entry #$i ($bid $bfile) — file is gone; DELETE this entry"
    elif grep -qF -- "$bfrag" "$bfile" 2>/dev/null; then
      bad "baseline entry #$i ($bid $bfile) still matches the source text but check $bid did NOT flag it — the DETECTOR has regressed and is now reporting clean. Fix _chk_$bid; do not delete this entry."
    else
      bad "baseline entry #$i ($bid $bfile) no longer matches (\"$bfrag\") — the code was fixed; DELETE this entry so the register keeps shrinking"
    fi
  done
  [ "$baseline_hits" = 0 ] || printf '\n%s known baselined site(s) above are REAL defects awaiting a fix, not exemptions.\n' "$baseline_hits"

  # A8 meta-check: this file deliberately does not cover lib/*.sh because prompt-contracts.sh does. If that
  # assertion is ever deleted, lib/ silently loses its stdin gate and both files report clean (lesson C1).
  # Assert the other half still exists, so coverage cannot be halved without turning something red.
  if [ -f tests/prompt-contracts.sh ]; then
    grep -qF "</dev/null" tests/prompt-contracts.sh \
      && grep -qE "opencode run" tests/prompt-contracts.sh \
      || bad "tests/prompt-contracts.sh lost its A8 stdin check — it owns lib/*.sh coverage, which bash-traps.sh deliberately skips. Restore it there, or move the check here and widen _chk_A8's scope."
  else
    bad "tests/prompt-contracts.sh is missing — A8 coverage for lib/*.sh is GONE (bash-traps.sh skips lib/ by design)"
  fi
}

# ---------------------------------------------------------------------------------------------------
# SELF-TEST — lesson B1 turned on the gate itself. Every check must FIRE on a known-bad fixture and stay
# SILENT on a known-good one. Without this, a pattern that stops matching (a refactor, a grep version, a
# stray escape) degrades to a check that always says "clean" — the exact fail-open shape that produced 34
# of the audit's 152 findings.
#
# The good fixtures are not merely "the bad one removed": each is the CORRECT form of the same code, so a
# pattern that has degenerated into matching everything fails too.
# ---------------------------------------------------------------------------------------------------
selftest(){
  local tmp id badf goodf out sfail=0
  tmp="$(mktemp -d)" || { bad "selftest: mktemp failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # BAD fixtures — each must trip its check.
  printf 'f(){\n  local a=X b=$a\n}\n'                                              > "$tmp/A1.bad"
  printf 'n=$(grep -c PAT file || echo 0)\n'                                        > "$tmp/A2.bad"   # bash-traps: allow A2 — this IS the known-bad fixture the A2 self-test needs
  printf 'if git diff HEAD | grep -q PAT; then :; fi\n'                             > "$tmp/A4.bad"
  printf 'git check-ignore -q -- "$f" || continue\n'                                > "$tmp/A5.bad"
  printf 'jq -r %sthe caller%ss name%s <<<"$j"\n' "$SQ" "$SQ" "$SQ"                 > "$tmp/A6.bad"
  printf 'opencode run --agent x "$p" >out\n'                                       > "$tmp/A8.bad"
  printf '  run git branch -M main; ok "renamed"\n'                                 > "$tmp/A11.bad"

  # GOOD fixtures — the correct form of the same code; none may trip.
  printf 'f(){\n  local a=X\n  local b=$a\n}\n'                                     > "$tmp/A1.good"
  printf 'n=$(grep -c PAT file || true); n=${n:-0}\n'                               > "$tmp/A2.good"
  printf 'if grep -q PAT <<<"$(git diff HEAD)"; then :; fi\n'                       > "$tmp/A4.good"
  printf 'git check-ignore -q --no-index -- "$f" || continue\n'                     > "$tmp/A5.good"
  printf 'jq -r %s.caller.name%s <<<"$j"\n' "$SQ" "$SQ"                             > "$tmp/A6.good"
  printf 'opencode run --agent x "$p" </dev/null >out\n'                            > "$tmp/A8.good"
  printf '  run git branch -M main && ok "renamed" || die "rename failed"\n'        > "$tmp/A11.good"

  for id in "${CHECKS[@]}"; do
    badf="$tmp/$id.bad"; goodf="$tmp/$id.good"
    [ -f "$badf" ] && [ -f "$goodf" ] || { bad "selftest: missing fixture for $id"; sfail=1; continue; }

    out="$("_chk_$id" "$badf")"
    if [ -z "$out" ]; then
      bad "selftest: check $id did NOT fire on its known-bad fixture — the pattern has stopped matching and is now reporting clean"
      sfail=1
    fi

    out="$("_chk_$id" "$goodf")"
    if [ -n "$out" ]; then
      bad "selftest: check $id fired on its known-GOOD fixture — it would block correct code:"
      printf '        %s\n' "$out"
      sfail=1
    fi
  done

  # The allowlist is a bypass, so it gets the same treatment: it must work, and it must REFUSE a bypass
  # with no stated reason. An allowlist that silently accepts a bare `# bash-traps: allow A2` would let any
  # defect through with three words and no justification.
  # The offending code is built ONCE into $code and the three allow-comment variants are appended, so this
  # file carries exactly one copy of each anti-pattern instead of three the scanner has to be told about.
  local code rc
  code='n=$(grep -c PAT f || echo 0)'   # bash-traps: allow A2 — allowlist fixture; not executed

  _allowed A2 "$code   # bash-traps: allow A2 — a stated reason"; rc=$?
  [ "$rc" = 0 ] || { bad "selftest: allowlist did not honour a well-formed allow comment (rc=$rc)"; sfail=1; }

  _allowed A2 "$code   # bash-traps: allow A2"; rc=$?
  [ "$rc" = 2 ] || { bad "selftest: a reasonless allow comment must return 2 (got rc=$rc) — an unjustified bypass would pass silently"; sfail=1; }

  _allowed A2 "$code   # bash-traps: allow A9 — different id"; rc=$?
  [ "$rc" = 1 ] || { bad "selftest: an allow for A9 must not suppress an A2 finding (got rc=$rc)"; sfail=1; }

  [ "$sfail" = 0 ] && printf 'selftest: all %s checks fire on bad input and stay silent on good input; allowlist enforces a reason.\n' "${#CHECKS[@]}"
  return 0
}

# ---------------------------------------------------------------------------------------------------
# DRIVER
# ---------------------------------------------------------------------------------------------------
# Build the file list explicitly and REFUSE to run on an empty one. A scan of zero files passes trivially
# and prints nothing — indistinguishable from a clean tree (lesson C1: a check that did not run must never
# report clean).
while IFS= read -r f; do FILES+=("$f"); done < <(
  { [ -f ace ] && echo ace; ls -1 lib/*.sh tests/*.sh scripts/*.sh 2>/dev/null; } | sort -u
)
if [ "${#FILES[@]}" -lt 5 ]; then
  echo "bash-traps: only ${#FILES[@]} file(s) in scope — refusing to report a clean scan from the wrong directory." >&2
  exit 1
fi

MODE="${1:-all}"
case "$MODE" in
  --selftest) selftest ;;
  --scan)     scan ;;
  all)        selftest; echo; scan ;;
  *) echo "usage: bash-traps.sh [--scan|--selftest]" >&2; exit 2 ;;
esac

if [ "$fail" = 0 ]; then
  printf '\nbash-traps: PASS — %s checks over %s files.\n' "${#CHECKS[@]}" "${#FILES[@]}"
else
  printf '\nbash-traps: FAIL — see above. Fix the code, or add `# bash-traps: allow <ID> — <reason>` to the line.\n'
fi
exit "$fail"
