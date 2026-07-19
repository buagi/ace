#!/usr/bin/env bash
# autoloop-selftest.sh — offline regression guards for lib/autoloop.sh lifecycle behaviour.
#
# Everything here is hermetic: no gh, no opencode, no network, no model. The loop body itself cannot be
# sourced (sourcing lib/autoloop.sh RUNS the loop), so each check either extracts the unit under test with
# awk and executes it in isolation, or asserts a structural invariant that cannot be expressed any other way.
# Every check below FAILS on the pre-fix code — see the comment on each.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AL="${AUTOLOOP_SH:-$ROOT/lib/autoloop.sh}"   # override to run these guards against a scratch/pre-fix copy
fail=0
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ok(){ echo "  ✓ $1"; }
no(){ echo "  ✗ $1"; fail=1; }

# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "claude_limit_hit — tail-scoped + provider-shaped:"
# Extract the knob, the regex and the predicate. A provider cap mis-detection is expensive in BOTH
# directions: a false positive parks the run for CLAUDE_RESET_WAIT (6h) and then stops WITHOUT ever
# surfacing the real error; a false negative burns the step budget against a wall.
CLH="$WORK/claude_limit_hit.sh"
{ grep -E '^CAP_TAIL_LINES=' "$AL"; grep -E '^_CAP_RE(_CS)?=' "$AL"; grep -E '^claude_limit_hit\(\)' "$AL"; } > "$CLH"
if [ "$(grep -c . "$CLH")" != 4 ]; then
  no "could not extract CAP_TAIL_LINES/_CAP_RE/_CAP_RE_CS/claude_limit_hit from lib/autoloop.sh"
else
  # shellcheck disable=SC1090
  . "$CLH"
  hit(){ # <label> <expect: yes|no> <log-body>
    printf '%s\n' "$3" > "$WORK/log"
    if claude_limit_hit "$WORK/log"; then r=yes; else r=no; fi
    [ "$r" = "$2" ] && ok "$1" || no "$1 (expected $2, got $r)"
  }
  # --- POSITIVE: real provider cap messages must still be caught (no under-detection) ---
  hit "claude subscription cap"      yes "Claude usage limit reached. Your limit will reset at 3pm."
  hit "HTTP 429 with status shape"   yes "api error: status 429 too many requests"
  hit "anthropic overloaded"         yes '{"type":"overloaded_error","message":"Overloaded"}'
  hit "low credit balance"           yes "Your credit balance is too low to access the Anthropic API."
  hit "insufficient quota"           yes "openai: insufficient quota for this request"
  hit "bad key"                      yes "authentication_error: invalid x-api-key"
  hit "402 with code shape"          yes "request failed with code 402 payment required"
  # UNDER-DETECTION guards. `overloaded_error` alone missed these: the bare capitalised message string is
  # what AI-SDK/opencode print when the `type` field is stripped, and it IS a real 529.
  hit "bare Overloaded (529 body)"   yes "Overloaded"
  hit "Overloaded + retry advice"    yes "API Error: Overloaded. Please try again later."
  # Google/OpenAI RESOURCE_EXHAUSTED phrasing — `quota (exceeded|…)` has the words the other way round.
  hit "exceeded your current quota"  yes "You have exceeded your current quota, please check your plan"
  hit "RESOURCE_EXHAUSTED phrasing"  yes "RESOURCE_EXHAUSTED: You exceeded your current quota"
  # --- NEGATIVE: the regression this file exists for ---
  # A step that merely DISCUSSES caps. Pre-fix this matched (bare billing|quota|expired|429|402|529,
  # grepped over the WHOLE file) and a genuine failure became a 6-hour wait then a silent stop.
  hit "prose mentioning cap words"   no  "I will add handling for billing errors, quota limits and expired
tokens, plus retry on 429/402/529 responses."
  hit "source code with the codes"   no  "  if (res.status === 429 || res.status === 402) return retry(res)"
  hit "test names"                   no  "  ok 14 - returns 529 when the upstream is overloaded"
  # TAIL-SCOPING: cap words far above the tail must not decide the verdict — the provider reports a cap at
  # the END of a run. Pre-fix this matched (whole-file grep); post-fix the tail holds the REAL error.
  { printf 'reviewing the billing module: quota, 429, 402, 529, expired credentials\n'
    for i in $(seq 1 120); do printf 'build step %s ok\n' "$i"; done
    printf 'FATAL: cannot open ./src/main.go: no such file or directory\n'; } > "$WORK/log"
  if claude_limit_hit "$WORK/log"; then no "cap words above the tail window still decide the verdict"
  else ok "tail-scoped (early cap words ignored; the real tail error surfaces)"; fi
  # ...and a cap that IS in the tail is still caught after a long clean run.
  { for i in $(seq 1 200); do printf 'build step %s ok\n' "$i"; done
    printf 'Claude usage limit reached\n'; } > "$WORK/log"
  claude_limit_hit "$WORK/log" && ok "a cap in the tail is still caught after a long run" \
                               || no "a real cap in the tail was MISSED"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo ".step-budget — trailing newline (active_s/build_s telemetry):"
# `read -r a b < file` returns 1 when the final line has no terminator, so an unterminated .step-budget
# made drive()'s fallback fire on EVERY step: active_s=0/build_s=0 in metrics.csv and a run summary that
# always printed "~0m active-think · ~0m builds". Demonstrate the shell semantics, then assert the writers.
printf '5 7' > "$WORK/nb"; if read -r _a _b < "$WORK/nb"; then _rc=0; else _rc=1; fi
[ "$_rc" = 1 ] && ok "read returns 1 on an unterminated line (why the newline is load-bearing)" \
               || no "read unexpectedly returned 0 on an unterminated line"
printf '5 7\n' > "$WORK/wb"; if read -r _a _b < "$WORK/wb" && [ "$_a" = 5 ] && [ "$_b" = 7 ]; then
  ok "read returns 0 and both fields on a terminated line"; else no "terminated read failed"; fi
# Both writers of .step-budget must terminate the line. Pre-fix BOTH lacked the \n.
_w="$(grep -c "step-budget" "$AL")"
_wn="$(grep -E "printf '[^']*\\\\n' *(\"?\\\$charged\"? \"?\\\$credited\"?)? *> \.opencode/\.step-budget|printf '0 0\\\\n' > \.opencode/\.step-budget" "$AL" | grep -c .)"
[ "$_wn" -ge 2 ] && ok "both .step-budget writers emit a trailing newline ($_wn found)" \
                 || no "a .step-budget writer is missing its trailing newline ($_wn of 2 terminated)"
# And the reader must default BEFORE reading, so a missing/torn file cannot leak stale or junk values.
grep -q 'mc=0; mb=0; read -r mc mb 2>/dev/null < \.opencode/\.step-budget' "$AL" \
  && ok "reader presets 0 before read (torn/absent file degrades to 0, not junk)" \
  || no "reader still relies on read's exit status for its fallback"

# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "resume-rescue — never commits to main:"
# THE SAFETY FIX. A prior run dying dirty on main used to be committed AND PUSHED straight to main,
# bypassing the PR + gate path entirely. Every sibling WIP site in the file gates on `!= main`; this one
# did not. Run the real extracted block in a throwaway repo, on main, with a dirty tree.
RB="$WORK/rescue.sh"
# Anchored on the ci.sh-green condition and the closing say — BOTH of which predate the fix — so this
# extracts (and therefore actually EXECUTES) the buggy body too, instead of silently degrading to a
# "could not extract" skip. Wrapped in a function because the body declares locals.
{ echo 'rescue_block(){'
  awk '/elif \.\/ci\.sh >\/dev\/null 2>&1; then/,/say "rescued \+ pushed/' "$AL" | tail -n +2
  echo '}'; } > "$RB"
if ! grep -q 'git commit -m "chore(resume)' "$RB"; then
  no "could not extract the resume-rescue block from lib/autoloop.sh"
else
  R="$WORK/repo"; BARE="$WORK/origin.git"
  git init -q --bare "$BARE"
  git init -q -b main "$R"
  ( cd "$R"
    git config user.email t@t; git config user.name t
    echo base > file.txt; git add -A; git -c commit.gpgsign=false commit -qm base
    git remote add origin "$BARE"; git push -q -u origin main 2>/dev/null
    echo dirty >> file.txt                     # the uncommitted work a killed run left behind
    mkdir -p "$WORK/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/gh"; chmod +x "$WORK/bin/gh"
    export PATH="$WORK/bin:$PATH"
    branch(){ git branch --show-current; }
    say(){ printf '    | %s\n' "$*"; }
    b="$(branch)"
    # shellcheck disable=SC1090
    . "$RB"; rescue_block
  ) > "$WORK/rescue.out" 2>&1
  _now="$(cd "$R" && git branch --show-current)"
  _mainc="$(cd "$R" && git rev-list --count main)"
  case "$_now" in chore/resume-*) ok "moved the rescue off main onto '$_now'" ;;
    *) no "rescue left HEAD on '$_now' (expected chore/resume-*)" ;; esac
  [ "$_mainc" = 1 ] && ok "main has no rescue commit (still $_mainc commit)" \
                    || no "MAIN WAS COMMITTED TO: $_mainc commits (expected 1)"
  ( cd "$R" && git status --porcelain | grep -q . ) && no "rescue left the tree dirty" \
                                                   || ok "the rescued work is committed on the branch"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "merge gate — a MISSING ./ci.sh is not a code RED:"
# merge_gate=local|both ran `./ci.sh --container` with no existence check, so an absent gate failed with
# "No such file or directory" — which the loop read as RED and fed to the fixer as a build failure, on
# every lap. The tentative-merge gate has had the guard all along. Structural: these three call sites live
# inside the main `while` body and cannot be extracted or executed in isolation.
_g="$(grep -c '\[ ! -e \./ci\.sh \]' "$AL")"
[ "$_g" -ge 3 ] && ok "all three container-gate call sites guard on ./ci.sh existence ($_g guards)" \
                || no "only $_g of 3 container-gate call sites guard on ./ci.sh existence"
grep -q 'merge_gate=local makes ./ci.sh the merge authority' "$AL" \
  && ok "merge_gate=local fails CLOSED on a missing gate (never vouches unverified)" \
  || no "merge_gate=local does not fail closed on a missing gate"

# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "merge_if_ready — 'no PR' is distinguished from 'could not ask':"
# A gh transport failure used to read as "no PR" -> rc 2 -> the caller does `git checkout -f main`,
# ABANDONING an unmerged feature branch on a transient blip. gh pr list is the discriminator: rc 0 with an
# empty array means genuinely no PR; non-zero means the question was not answered.
grep -q 'gh pr list --head "\$(branch)" --state open -L1 --json number' "$AL" \
  && ok "PR presence probed with gh pr list (rc-distinguishable)" \
  || no "PR presence still probed with bare gh pr view (empty output == error)"
grep -q 'treating as UNKNOWN, NOT as .no PR' "$AL" \
  && ok "an unanswerable gh call returns the not-mergeable path, not the abandon path" \
  || no "an unanswerable gh call is not handled distinctly"
# BEHAVIOURAL: gh exits 0 while writing to stderr (GH_DEBUG=api, "!"/Warning lines). If stderr is folded
# into the captured value, $pr becomes a log blob -> `gh pr view` fails -> the not-OPEN arm returns 2 ->
# the caller runs `git checkout -f main` and abandons unmerged work. Same defect, new door. Run the real
# probe head against a fake gh instead of trusting a grep.
MIR="$WORK/merge_if_ready_head.sh"
awk '/^merge_if_ready\(\)\{/{f=1} f{print} f&&/^  esac$/{print "  echo \"$pr\"; return 0"; print "}"; exit}' "$AL" > "$MIR"
mkdir -p "$WORK/bin"
{ echo '#!/usr/bin/env bash'
  echo 'echo "* Request to https://api.github.com/graphql" >&2'
  echo 'printf "%s\n" "${FAKE_GH_OUT-}"'
  echo 'exit "${FAKE_GH_RC:-0}"'; } > "$WORK/bin/gh"
chmod +x "$WORK/bin/gh"
if ! grep -q '^}' "$MIR"; then
  no "could not extract the merge_if_ready PR-probe head from lib/autoloop.sh"
else
  mir(){ # <FAKE_GH_OUT> <FAKE_GH_RC> -> prints "<rc>|<pr>"
    ( PATH="$WORK/bin:$PATH"; export FAKE_GH_OUT="$1" FAKE_GH_RC="$2"
      say(){ :; }; branch(){ echo feat/x; }; sleep(){ :; }
      # shellcheck disable=SC1090
      . "$MIR"; _out="$(merge_if_ready)"; printf '%s|%s\n' "$?" "$_out" )
  }
  r="$(mir 4242 0)"
  [ "$r" = "0|4242" ] && ok "gh stderr noise does not contaminate the PR number (got 4242, rc 0)" \
                      || no "stderr folded into the PR number (expected 0|4242, got $r)"
  r="$(mir '' 0)"
  [ "${r%%|*}" = 2 ] && ok "rc 0 + empty stdout is still a positively-confirmed 'no PR' (rc 2)" \
                     || no "an empty PR list no longer returns rc 2 (got $r)"
  r="$(mir '' 1)"
  [ "${r%%|*}" = 1 ] && ok "gh failure is UNKNOWN (rc 1), not the abandon path" \
                     || no "a failing gh does not return rc 1 (got $r)"
  r="$(mir 'Warning: something happened' 0)"
  [ "${r%%|*}" = 1 ] && ok "a non-numeric PR id is UNKNOWN (rc 1), not 'no PR'" \
                     || no "a non-numeric PR id is not treated as UNKNOWN (got $r)"
fi

# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "misc:"
# token_report aggregate cache-read% must use the SAME denominator capture_usage documents (input+cache_read).
grep -q 'den=IN\[a\]+CR\[a\]; pct=(den>0?int(CR\[a\]\*100/den):0)' "$AL" \
  && ok "token_report cache-read% divides by input+cache_read (no >100% over-reporting)" \
  || no "token_report cache-read% still divides by input alone"
# debate narration (stderr) must reach the loop log — the call sites promise "per-turn progress follows".
grep -qE 'bash "\$_dsh" spec "\$sp" 2>/dev/null' "$AL" \
  && no "spec-debate call site still discards debate.sh narration + fail-open reasons" \
  || ok "spec-debate narration reaches the loop log"

[ "$fail" = 0 ] && { echo "✓ autoloop selftest OK"; exit 0; } || { echo "✗ autoloop selftest FAILED"; exit 1; }
