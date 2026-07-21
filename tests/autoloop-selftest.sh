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


# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "spec-lint net gate:"
# SPEC_LINT_NET shipped assigned NOWHERE — not in ace, any lib, CI, settings or docs — so the SRC_LIVE
# check and the provenance writer had never executed once, while a test asserted the literal string
# appears in lib/swarm.sh (it matched the COMMENT). Assert the ASSIGNMENT, in code, not a mention.
_al_code(){ sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -vE '^[[:space:]]*$'; }
grep -qE '(^|[[:space:]])SPEC_LINT_NET=' <<<"$(_al_code "$AL")" \
  && ok "autoloop ASSIGNS SPEC_LINT_NET (the source-verification gate can actually run)" \
  || no "autoloop never assigns SPEC_LINT_NET — SRC_LIVE + provenance can never execute"
grep -qE 'export[[:space:]]+SPEC_LINT_NET' <<<"$(_al_code "$AL")" \
  && ok "SPEC_LINT_NET is exported (swarm.sh runs as a child process and must inherit it)" \
  || no "SPEC_LINT_NET assigned but not exported — the child spec-lint would not see it"
grep -q 'SPEC_LINT_NET' lib/menu.sh \
  && ok "SPEC_LINT_NET is settable from 'ace settings'" \
  || no "SPEC_LINT_NET is not in ace settings — an undiscoverable knob is an unused knob"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "run display:"
# The plan-only path called agent_state ONCE and emitted no stage markers, so `ace loop dash` showed the
# orchestrator lit and nothing changing for 3.5 hours, and say() coloured only the timestamp prefix — every
# line of a long run arrived identical and white. Phases give the run a visible spine.
grep -qE '^phase\(\) \{' "$AL" \
  && ok "phase() exists (a run has a visible spine, not one undifferentiated colour)" \
  || no "no phase() — the plan-only run has no stage markers at all"
_ph_count="$(grep -cE '(^|[[:space:]])phase [0-9]+ 5 ' <<<"$(sed -E 's/(^|[[:space:]])#.*$//' "$AL")")"
[ "${_ph_count:-0}" -eq 5 ] \
  && ok "all 5 plan-only phases are wired ($_ph_count call sites)" \
  || no "expected 5 phase call sites in the plan-only path, found ${_ph_count:-0} — a skipped number reads as a lost stage"
# 3 and 4 must fire even on the clean/disabled paths, or the spine develops holes exactly when a run is
# uneventful — which is when a silent screen is most alarming.
grep -qE '^\s+phase 3 5 ' <<<"$(sed -E 's/(^|[[:space:]])#.*$//' "$AL")" \
  && ok "phase 3 is emitted before the gap branch (fires whether or not there are gaps)" \
  || no "phase 3 is inside a conditional — a clean spec set would skip the number"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "debate telemetry:"
# The debate loop was the single biggest wall-clock consumer of a real run (50%) and emitted NO metric
# row, so run-summary and scorecard under-reported by 2x. Assert each debate call site is TIMED.
_al_code(){ sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -vE '^[[:space:]]*$'; }
grep -qE 'phase_metric debate ' <<<"$(_al_code "$AL")" \
  && ok "spec-debate call site emits a phase_metric row (its wall-clock is attributable)" \
  || no "the debate loop emits no phase_metric — half a run's wall-clock lands in no metric row"
# both the spec AND review debate sites must be timed, or one path stays invisible
_dbg="$(grep -cE 'phase_metric debate ' <<<"$(_al_code "$AL")")"
[ "${_dbg:-0}" -ge 2 ] \
  && ok "both spec-debate and review-debate are timed ($_dbg call sites)" \
  || no "only ${_dbg:-0} debate call site(s) timed — the other debate path is unattributed"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "exit-0-errored classifier:"
_e0f="$(mktemp)"
# The #14551 "exit 0 but errored" check grep'd the log tail for `\bfatal\b|^Error:|traceback` and fired on
# CONTENT the step legitimately produced — a test named "NON-FATAL: ...", a handled research miss
# ("Error: Tool 'firecrawl_search' execution failed"). Advisory (classify is `|| true`), so it never halted a
# run, but it wrote a false crash label into failmode telemetry that then failed the acceptance harness.
# autoloop.sh can't be sourced (it runs the loop), so EXTRACT the function and exercise both directions.
awk '/^_exit0_errored\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$AL" > "$_e0f"
[ -s "$_e0f" ] || no "_exit0_errored not found in autoloop.sh"
_e0chk(){ bash -c ". '$_e0f'; _exit0_errored '$1'" >/dev/null 2>&1 && echo ERRORED || echo clean; }
_e0d="$(mktemp -d)"
printf 'stderr | settings-route.test.ts > NON-FATAL: admin PUT ignores unknown keys\nci.sh GREEN\n' > "$_e0d/fp1"
printf "Error: Tool 'firecrawl_search' execution failed: Invalid URL\nPR opened.\n"                 > "$_e0d/fp2"
printf 'Error: StatusCode: non 2xx status code (404 GET https://stooq.com/)\nspec written.\n'       > "$_e0d/fp3"
printf '  ✓ throws Error on bad config\nAll tests pass.\n'                                          > "$_e0d/fp4"
printf 'node uncaughtException\n  at Object\n'                                                       > "$_e0d/c1"
printf 'FATAL ERROR: Reached heap limit - JavaScript heap out of memory\n'                           > "$_e0d/c2"
printf 'panic: runtime error: invalid memory address\n'                                              > "$_e0d/c3"
_fpbad=0; for f in fp1 fp2 fp3 fp4; do [ "$(_e0chk "$_e0d/$f")" = clean ] || _fpbad=$((_fpbad+1)); done
_crok=0;  for f in c1 c2 c3;   do [ "$(_e0chk "$_e0d/$f")" = ERRORED ] && _crok=$((_crok+1)); done
rm -rf "$_e0d" "$_e0f"
[ "$_fpbad" -eq 0 ] && ok "exit-0-errored does NOT fire on test output / handled tool errors (4/4 clean)" \
                    || no "exit-0-errored false-positives on $_fpbad/4 benign logs (NON-FATAL test names, research misses)"
[ "$_crok" -eq 3 ] && ok "exit-0-errored STILL catches real runtime crashes (uncaughtException / OOM / panic)" \
                   || no "exit-0-errored missed $((3-_crok))/3 genuine crashes — the tightening went too far"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "reanalyze per-feature iteration:"
_alc(){ sed -E 's/(^|[[:space:]])#.*$//' "$AL" | grep -vE '^[[:space:]]*$'; }
# STRUCTURE — the re-derive must LOOP over features, not be one giant drive. Each piece is revert-provable.
grep -qE 'for _slug in \$_feats' <<<"$(_alc)" \
  && ok "re-derive iterates per feature (for _slug in \$_feats …), not one drive over all items" \
  || no "re-derive is not a per-feature loop — a single drive can't reliably cover a large backlog"
grep -qE 'phase_metric reanalyze-feature' <<<"$(_alc)" \
  && ok "each feature is TIMED (phase_metric reanalyze-feature) — coverage + cost are attributable" \
  || no "per-feature re-derive emits no metric — a batch that stalls would be invisible"
grep -qE 'REANALYZE_MAX_FEATURES' <<<"$(_alc)" \
  && ok "REANALYZE_MAX_FEATURES batches a huge backlog across runs" \
  || no "no REANALYZE_MAX_FEATURES — a 90-item backlog can't be split across quota windows"
grep -q 'DEEP RESEARCH' <<<"$(_alc)" \
  && ok "per-feature drive mandates DEEP research (breadth + depth), not a SHORT bounded pass" \
  || no "the re-derive prompt lost its deep-research mandate — research stays shallow"
grep -q 'THIS FEATURE ONLY' <<<"$(_alc)" \
  && ok "each drive is SCOPED to one feature (THIS FEATURE ONLY) — no cross-feature bleed" \
  || no "the per-feature drive is not scoped to a single feature"
grep -qE '_ffail=\$\(\(_ffail\+1\)\)' <<<"$(_alc)" \
  && ok "a feature that errors is counted and the loop CONTINUES (failure-tolerant)" \
  || no "one failed feature aborts the whole re-derivation — not robust"

# LOGIC — enumeration against a fixture: distinct slugs, DONE excluded, unspecced catch-all, batching.
_rd="$(mktemp -d)"
cat > "$_rd/ROADMAP.md" <<'RM'
- [ ] [value] **A** — Spec: .opencode/specs/alpha.md AC: AC-1 Files: a.ts
- [ ] [value] **B** — Spec: .opencode/specs/alpha.md AC: AC-2 Files: b.ts
- [ ] [value] **C** — Spec: .opencode/specs/beta.md AC: AC-1 Files: c.ts
- [ ] [infra] **D no spec** — Files: d.ts
- [x] [value] **done** — Spec: .opencode/specs/gamma.md
RM
_feats="$(grep -E '^[[:space:]]*- \[ \] ' "$_rd/ROADMAP.md" | grep -oE 'Spec:[[:space:]]*[^ )]+\.md' | sed -E 's#.*/##; s/\.md$//' | sort -u)"
_ot="$(grep -cE '^[[:space:]]*- \[ \] ' "$_rd/ROADMAP.md")"
_os="$(grep -E '^[[:space:]]*- \[ \] ' "$_rd/ROADMAP.md" | grep -cE 'Spec:[[:space:]]*[^ )]+\.md')"
_un=0; [ "$_ot" -gt "$_os" ] && _un=1
_nslug="$(printf '%s\n' "$_feats" | grep -c .)"
[ "$_nslug" = 2 ] && ok "enumeration: 2 distinct feature slugs (alpha, beta) — duplicate items collapse" || no "enumeration wrong: $_nslug distinct slugs, want 2"
[ "$_un" = 1 ] && ok "enumeration: the un-spec'd item (D) is caught for a catch-all pass" || no "enumeration missed the un-spec'd open item"
printf '%s\n' "$_feats" | grep -q gamma && no "a DONE item's spec (gamma) leaked into the worklist" || ok "DONE items are excluded from re-derivation"
rm -rf "$_rd"


# ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "interactive settings reach the swarm:"
# `ace loop` PROMPTS for self-merge / feature cap / deploy / parallel flows — then the swarm handoff
# hardcoded AUTOMERGE=1 (scaffold.sh) and every worker hardcoded AUTOMERGE=1 MAX_FEATURES=1 ... DEPLOY=0
# (swarm-run.sh). So the moment you chose 2-5 parallel flows, answering "no self-merge" self-merged anyway
# and the prompt was decorative. The answers must survive BOTH hops.
_sc(){ sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -vE '^[[:space:]]*$'; }
grep -qE 'AUTOMERGE="\$sm"[^|]*swarm-run\.sh|AUTOMERGE="\$sm" MAX_FEATURES' <<<"$(_sc lib/scaffold.sh)" \
  && ok "the swarm handoff forwards the user's self-merge answer (not hardcoded AUTOMERGE=1)" \
  || no "the autorun->swarm handoff still hardcodes AUTOMERGE — 'no self-merge' is ignored once you pick parallel workers"
grep -qE 'AUTOMERGE="\$\{AUTOMERGE:-1\}"' <<<"$(_sc lib/swarm-run.sh)" \
  && ok "workers INHERIT AUTOMERGE from the coordinator (user choice reaches the worker)" \
  || no "workers still hardcode AUTOMERGE=1 — the coordinator's/user's choice never reaches them"
grep -qE 'DEPLOY="\$\{DEPLOY:-0\}"' <<<"$(_sc lib/swarm-run.sh)" \
  && ok "workers inherit DEPLOY (still defaulting OFF)" \
  || no "workers hardcode DEPLOY=0 — a deliberate deploy choice cannot reach them"
# MAX_FEATURES=1 / MERGE_GATE=local per worker are STRUCTURAL and must stay pinned.
grep -qE 'MAX_FEATURES=1 MERGE_GATE=local' <<<"$(_sc lib/swarm-run.sh)" \
  && ok "per-worker MAX_FEATURES=1 + MERGE_GATE=local remain structural (one item per worker; queue merges)" \
  || no "the structural per-worker pins changed — a worker must own exactly ONE item and merge via the queue"

[ "$fail" = 0 ] && { echo "✓ autoloop selftest OK"; exit 0; } || { echo "✗ autoloop selftest FAILED"; exit 1; }
