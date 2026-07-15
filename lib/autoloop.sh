#!/usr/bin/env bash
# autoloop.sh — the ACE autonomous loop (SINGLE SOURCE). Run in a project cwd:
#   bash "$ACE_DIR/lib/autoloop.sh"   (projects exec this via a thin scripts/auto-loop.sh)
# Reads only cwd-relative project files: ROADMAP.md, OBJECTIVES.md, .opencode/*, ci.sh.
# Autonomous PR loop. Watch CI; on failure feed the failed-job log to opencode to fix the
# ROOT CAUSE; repeat until green; then implement the next ROADMAP item. Capped, no auto-merge.
#   MAX_FIX=5 MAX_FEATURES=3 AUTOMERGE=0 GENERATE_IDEAS=0 bash scripts/auto-loop.sh
set -uo pipefail
# shared-state coordination helpers (swarm_aggregate_lessons — S6 per-worker lessons reduce). Pure
# function defs, safe to source; guarded so a missing module never breaks the single-flow loop.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm-policy.sh" 2>/dev/null || true
# item 3: RED-main circuit breaker — driven via the swarm.sh CLI (autoloop does NOT source swarm.sh; this keeps
# them decoupled). No-op outside a swarm (SWARM_WORKER unset) or if swarm.sh is absent. SWARM_DIR flows in via env.
_SWARM_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/swarm.sh"
_swarm(){ [ -n "${SWARM_WORKER:-}" ] && [ -f "$_SWARM_SH" ] && bash "$_SWARM_SH" "$@" 2>/dev/null; }
# per-subagent token/cost telemetry from opencode's session DB (subagent_report / ace stats). Fail-soft.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/telemetry.sh" 2>/dev/null || true
cd "$(git rev-parse --show-toplevel)" || exit 1
# delivery policy: defaults come from .opencode/profile.yaml; env still overrides per run.
prof_get(){ grep -E "^[[:space:]]*$1:[[:space:]]*" .opencode/profile.yaml 2>/dev/null | head -1 | sed -E "s/^[^:]*:[[:space:]]*\"([^\"]*)\".*$/\1/; t; s/^[^:]*:[[:space:]]*'([^']*)'.*$/\1/; t; s/^[^:]*:[[:space:]]*//; s/^#.*$//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//"; }
case "$(prof_get auto_merge)" in true|yes|1) _pam=1 ;; *) _pam=0 ;; esac
_pmg="$(prof_get merge_gate)"; case "$_pmg" in local|remote|both) : ;; *) _pmg=remote ;; esac
_pcc="$(prof_get ci_cd)"   # ci_cd: github-actions | none — only watch Actions when the project actually uses it
AGENT="${AGENT:-orchestrator}"
ACE_TELEMETRY="${ACE_TELEMETRY:-1}"; export ACE_TELEMETRY   # 1 = full per-subagent × worker × run token/cost logging (default) · 0 = OFF (max throughput, nothing logged)
MAX_FIX="${MAX_FIX:-5}"; MAX_FEATURES="${MAX_FEATURES:-3}"; MAX_PLANS="${MAX_PLANS:-5}"   # caps: CI-fix attempts/red · features/run (0=∞) · re-plan attempts before "stuck"
AUTOMERGE="${AUTOMERGE:-$_pam}"; PLAN="${PLAN:-1}"; DEPLOY="${DEPLOY:-0}"
MERGE_GATE="${MERGE_GATE:-$_pmg}"   # remote = wait for Actions green · local = merge on ./ci.sh --container green · both = require local AND remote green
# Don't watch GitHub Actions unless the project actually USES it: ci_cd != github-actions ⇒ local gate is the authority.
# 'both' also degrades to 'local' when there's no remote CI to wait on (there's no remote half to require).
{ [ "$MERGE_GATE" = remote ] || [ "$MERGE_GATE" = both ]; } && [ -n "$_pcc" ] && [ "$_pcc" != github-actions ] && { printf '[auto-loop] ci_cd=%s (no GitHub Actions) -> merge_gate=local (was %s); not watching Actions.\n' "$_pcc" "$MERGE_GATE"; MERGE_GATE=local; }
DEPLOY_KIND="${DEPLOY_KIND:-$(prof_get deploy_kind)}"; DEPLOY_KIND="${DEPLOY_KIND:-service}"   # service|artifact|none — what to do after a merge
# Overseer-on-Claude (subscription) limit policy: wait | cancel | deepseek
ON_CLAUDE_LIMIT="${ON_CLAUDE_LIMIT:-wait}"        # on a Claude/OpenAI cap: WAIT for reset on your model (default) — never auto-downgrade. wait|cancel|deepseek (deepseek is opt-in)
CLAUDE_RESET_WAIT="${CLAUDE_RESET_WAIT:-21600}"  # keep polling this long (6h — rides through a sub's reset window) then STOP for review; NEVER auto-downgrades the model
CLAUDE_POLL="${CLAUDE_POLL:-120}"                # poll interval while waiting — resumes within ~this long of a reset
OPENCODE_TIMEOUT="${OPENCODE_TIMEOUT:-2700}"     # base per-run budget (s, +50%); on overrun it's a BIG TASK -> retried with a larger budget (not failed)
OPENCODE_TIMEOUT_MAX="${OPENCODE_TIMEOUT_MAX:-8100}"  # ceiling (s, +50%) the escalating big-task budget grows to
export OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS="${OPENCODE_EXPERIMENTAL_BASH_DEFAULT_TIMEOUT_MS:-300000}"  # E4: raise the inner bash cap to 5m for legit-long commands (opencode env, verified present on 1.17.x). The 120s streamText step ceiling (#25509) may STILL fire — so keep the FULL/--container build OUT of the inner agent loop (FAST ci.sh inner; FULL at the merge gate).
OPENCODE_RETRIES="${OPENCODE_RETRIES:-2}"        # extra big-task attempts (each with a larger budget) before stopping for review
HEARTBEAT="${HEARTBEAT:-60}"                     # seconds between live "still running" elapsed/remaining ticks
WATCH_POLL="${WATCH_POLL:-10}"                    # seconds between activity samples (budget-accounting granularity)
OPENCODE_WALL_MAX="${OPENCODE_WALL_MAX:-10800}"  # HARD wall-clock ceiling (s) per attempt — bounds a stuck step even while slow steps pause the budget clock
STALL_AFTER="${STALL_AFTER:-900}"                # s of ZERO new output (and no build running) before the rathole supervisor judges the step
HANG_AFTER="${HANG_AFTER:-900}"                  # s of ZERO opencode log growth (stdout AND internal) → deterministic hang-kill (deadlocked step / stalled parallel subagents). Lowered from 1500: a real fan-out deadlock is silent within minutes.
RATHOLE_JUDGE="${RATHOLE_JUDGE:-deepseek-v4-flash}"  # cheap model the driver curls (hard-timed + fail-open) for a stuck-vs-progress verdict
RATHOLE_RETRIES="${RATHOLE_RETRIES:-2}"          # max autonomous fix-and-retry attempts on a CONFIRMED rathole, then hard-stop (no infinite fixing)
RATHOLE_MAXCHECKS="${RATHOLE_MAXCHECKS:-6}"      # circuit-breaker: max supervisor checks per step before it stops re-checking (wall cap takes over)
ACE_FIXME="${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}"  # queue: persistent ratholes get filed here for the issue-filing inception meta-loop
SLOW_STEPS="${SLOW_STEPS:-podman buildah docker pnpm npm yarn pip pip3 poetry uv cargo rustc go gradle mvn make cmake ninja tsc turbo nx webpack vite rollup esbuild jest vitest pytest playwright cypress}"  # subprocess names whose run time is NOT charged to the task budget
SERVER_PROCS="${SERVER_PROCS:-mcp|langserver|language-server|serena}"  # persistent MCP/LSP helpers launch under uv/npm (which ARE slow-steps) but run the WHOLE session — exclude them, else the budget clock freezes and both the BIG-TASK timeout and the rathole supervisor are defeated
DEEPSEEK_OVERSEER="${DEEPSEEK_OVERSEER:-deepseek/deepseek-v4-pro}"  # model used when the overseer is delegated to DeepSeek
ORCH_MODEL_OVERRIDE="${ORCH_MODEL_OVERRIDE:-}"   # set to delegate the overseer (auto-set on a Claude limit)
CI_STATE="${CI_STATE:-idle}"                     # live gate state for the dash chip: idle|running|green|red (set at the gate choke points)
WAITED=0                                          # cumulative seconds spent waiting on the current limit
ACE_CFG="${ACE_CFG:-$HOME/.config/ace/config}"
EXPECT_REPO="${EXPECT_REPO:-}"                    # optional owner/name guard for the loop
VERIFY="${VERIFY:-0}"                            # 1 => after each deploy, run 'ace verify' (triage findings -> ROADMAP)
HARVEST="${HARVEST:-1}"                          # 1 => after each GREEN merge, curate build WARNINGS the gate let through into ROADMAP
HARVEST_MAX="${HARVEST_MAX:-15}"                 # cap candidate warning lines fed to the curator (noise/cost guard)
LOCAL_CI_FALLBACK="${LOCAL_CI_FALLBACK:-0}"      # 1 => when Actions is BLOCKED (billing/infra: run failed but ran 0 jobs), accept a GREEN local ./ci.sh --container as the pass and merge
JANITOR_EVERY="${JANITOR_EVERY:-3}"              # run the per-lap consistency/disk janitor every Nth lap (1 = every lap); housekeeping, not correctness
HERMES_NOTIFY="${HERMES_NOTIFY:-0}"              # 1 => push milestone events to Hermes (-> Telegram/phone) via `hermes send`; opt-in, fail-soft
HERMES_TO="${HERMES_TO:-telegram}"               # hermes target: telegram | telegram:<chat_id> | discord | slack | ...
HERMES_SUBJECT="${HERMES_SUBJECT:-}"             # optional notification prefix (defaults to repo:branch)
RESOLVE_CONFLICTS="${RESOLVE_CONFLICTS:-1}"      # 1 => auto-resolve a conflicting PR (preserve both intents) vs stop
MAX_CONFLICT="${MAX_CONFLICT:-2}"               # max conflict-resolution attempts per branch before stopping
STOP_ON_DEPLOY_FAIL="${STOP_ON_DEPLOY_FAIL:-1}"  # 1 => a failed VPS deploy/health-check HALTS the loop (don't ship more onto a broken live deploy); 0 => log + keep going
RESOLVE_INSTR="The PR for the current branch CONFLICTS with main. Resolve it per your CONFLICT RESOLUTION protocol: merge origin/main into this branch, delegate to the conflict_resolver subagent (preserve BOTH intents; NO reverts to old; escalate UNRESOLVABLE), then have the reviewer confirm NO intended change was lost or reverted (APPROVE required). Ensure ./ci.sh GREEN, commit the merge, and push. If UNRESOLVABLE or any intended change would be lost, abort the merge and report — do NOT force it. NEVER merge the PR."
MAINFIX_INSTR="The main branch is RED ON ITS OWN — its latest container build (./ci.sh --container) FAILS independent of your branch (another flow's merge broke it). You are the designated FIXER. Read .opencode/ci-failure.log, find the ROOT cause, and fix it MINIMALLY on this branch — do NOT revert unrelated work, do NOT implement new features, touch only what the failing build needs to go GREEN. Ensure ./ci.sh is GREEN, commit, and push so this branch lands the repair onto main. If the failure is infra / not code-fixable (billing/network/host), report and stop — do NOT force a merge."
SELF_IMPROVE="${SELF_IMPROVE:-0}"                # 1 => when all objectives done, keep improving
IMPROVE_GOAL="${IMPROVE_GOAL:-generate income · solve real user problems · professional, reliable UX}"  # the end goal self-improvement optimizes toward
# ── structured, traceable telemetry (feeds `ace swarm dash` now + the web UI later) ──
# CURRENT_PHASE is the coarse stage the loop is in (set by drive()); SWARM_WORKER /
# SWARM_FEATURE / SWARM_HASH / SWARM_RUNID come from the coordinator's env.
CURRENT_PHASE="${CURRENT_PHASE:-boot}"
_ev(){ # level msg  → one tagged JSON event line onto the shared bus
  [ -n "${SWARM_DIR:-}" ] || return 0; command -v jq >/dev/null 2>&1 || return 0
  printf '{"ts":%s,"run":"%s","worker":"%s","feat":%s,"hash":"%s","phase":"%s","agent":"%s","level":"%s","msg":%s}\n' \
    "$(date +%s)" "${SWARM_RUNID:-}" "${SWARM_WORKER:-solo}" \
    "$(printf '%s' "${SWARM_FEATURE:-}" | jq -Rsc .)" "${SWARM_HASH:-}" "$CURRENT_PHASE" "${AGENT:-}" "$1" \
    "$(printf '%s' "$2" | jq -Rsc .)" >> "$SWARM_DIR/events.jsonl" 2>/dev/null || true
}
_stat(){ # phase wall budget act  → per-worker snapshot the dash reads for the pipeline box
  [ -n "${SWARM_DIR:-}" ] || return 0
  mkdir -p "$SWARM_DIR/status" 2>/dev/null
  printf 'worker=%s\nfeat=%s\nhash=%s\nphase=%s\nagent=%s\nwall=%s\nbudget=%s\nact=%s\nts=%s\n' \
    "${SWARM_WORKER:-solo}" "${SWARM_FEATURE:-}" "${SWARM_HASH:-}" "$1" "${AGENT:-}" "$2" "$3" "$4" "$(date +%s)" \
    > "$SWARM_DIR/status/${SWARM_WORKER:-solo}.stat" 2>/dev/null || true
}
_wtag(){ # stable per-worker colour (any N) so workers are eye-trackable in tail/split
  local wc; case "${SWARM_WORKER#w}" in 1) wc='38;2;176;114;230';; 2) wc='38;2;212;160;74';; 3) wc='38;2;63;185;106';;
    4) wc='38;2;208;80;70';; 5) wc='38;2;90;190;210';; 6) wc='38;2;110;150;230';;
    *) wc="$(awk -v n="${SWARM_WORKER#w}" 'BEGIN{ h=n*137.508; h=h-int(h/360)*360; s=0.55; v=0.92; c=v*s; hp=h/60;
         hh=hp-int(hp/2)*2; if(hh<0)hh+=2; x=c*(1-(hh>1?hh-1:1-hh)); m=v-c;
         if(hp<1){r=c;g=x;b=0}else if(hp<2){r=x;g=c;b=0}else if(hp<3){r=0;g=c;b=x}
         else if(hp<4){r=0;g=x;b=c}else if(hp<5){r=x;g=0;b=c}else{r=c;g=0;b=x}
         printf "38;2;%d;%d;%d",(r+m)*255,(g+m)*255,(b+m)*255 }')" ;;
  esac
  printf '\033[%sm[worker %s · %s]\033[0m ' "$wc" "${SWARM_WORKER#w}" "${SWARM_FEATURE:-?}"; }
say(){ local tag=""; [ -n "${SWARM_WORKER:-}" ] && tag="$(_wtag)"
  printf '\n\033[1;35m[auto-loop %s]\033[0m %b%s\n' "$(date +%H:%M:%S)" "$tag" "$*"; _ev "${_LVL:-info}" "$*"; }
# dashboard signal: which agent the bash loop is currently driving (best-effort — the 4 critics run INSIDE
# opencode and are invisible to this loop, so only orchestrator/implementer/verifier/conflict light up).
# `ace loop dash` reads .opencode/.agents to colour the grid. Fail-soft; never affects the loop.
agent_state(){ local x s=""; for x in orchestrator implementer test_engineer verifier reviewer ux_reviewer standards alignment conflict; do [ "$x" = "$1" ] && s="$s $x:${2:-active}" || s="$s $x:idle"; done; printf '%s\n' "${s# }" > .opencode/.agents 2>/dev/null || true; }
# telemetry: one CSV row per completed step -> .opencode/metrics.csv. You can't tune what you can't
# see; this makes where-the-time-goes (active thinking vs slow builds, per agent) visible after a run.
metric(){ [ "${ACE_TELEMETRY:-1}" = 1 ] || return 0; local f=.opencode/metrics.csv; mkdir -p .opencode 2>/dev/null
  [ -f "$f" ] || printf 'run_id,ts,branch,event,agent,label,wall_s,active_s,build_s,rc\n' > "$f" 2>/dev/null
  printf '%s,%s,%s,%s\n' "${RUN_ID:-0}" "$(date +%FT%T)" "$(branch 2>/dev/null)" "$*" >> "$f" 2>/dev/null || true; }
# Time a NON-agent phase -> one CSV row.  $1=event $2=label(commas stripped) $3=wall_s $4=rc.  (agent blank; active/build 0.)
phase_metric(){ metric "$1,,$(printf '%s' "${2:-}" | tr ',\n' '; '),$3,0,0,${4:-0}"; }
# D1: capture token / prefix-cache usage from the LAST opencode run into metrics.csv (feeds D3 observability
# and PROVES the caching win). The prefix-cache MECHANISM is guaranteed by the S5/D1 invariant at drive();
# this only makes the HIT RATIO visible. Best-effort + FAIL-SOFT: opencode's default output may not surface
# per-call cache tokens (the JSON event stream / provider usage does), so an absent field records nothing —
# NEVER a crash and never a blocked step. Verified numbers require a live/credit run (see TESTS-TODO D1).
capture_usage(){
  [ "${ACE_TELEMETRY:-1}" = 1 ] || return 0
  local log=.opencode/last-run.log inp out chr chw ratio=""
  [ -f "$log" ] || return 0
  # `input_tokens` is a substring of `cache_read_input_tokens` — require input/prompt NOT preceded by a
  # letter/underscore so the total isn't confused with the cache fields (proven: scratchpad/d1-usage-test.sh).
  inp=$(grep -oiE '(^|[^_a-z])(input|prompt)[ _-]?tokens?["=: ]+[0-9,]+' "$log" 2>/dev/null | grep -oE '[0-9,]+' | tail -1 | tr -d ,)
  out=$(grep -oiE '(^|[^_a-z])(output|completion)[ _-]?tokens?["=: ]+[0-9,]+' "$log" 2>/dev/null | grep -oE '[0-9,]+' | tail -1 | tr -d ,)
  chr=$(grep -oiE '(cache[ _-]?read|prompt.?cache.?hit)[a-z_ -]*["=: ]+[0-9,]+' "$log" 2>/dev/null | grep -oE '[0-9,]+' | tail -1 | tr -d ,)
  chw=$(grep -oiE '(cache[ _-]?(write|creation)|prompt.?cache.?miss)[a-z_ -]*["=: ]+[0-9,]+' "$log" 2>/dev/null | grep -oE '[0-9,]+' | tail -1 | tr -d ,)
  [ -n "$inp$out$chr$chw" ] || return 0   # format didn't expose usage → record nothing
  # cache-hit% = cache_read / (FRESH input + cache_read); opencode's `input` is the UNCACHED portion only,
  # so dividing by input alone over-reports (>100%). Guard the denominator.
  { [ -n "${chr:-}" ] && [ "$(( ${inp:-0} + ${chr:-0} ))" -gt 0 ] 2>/dev/null; } && ratio=$(( ${chr:-0} * 100 / ( ${inp:-0} + ${chr:-0} ) ))
  metric "usage,${AGENT:-?},cache_read=${chr:-0}/cache_write=${chw:-0}/in=${inp:-0}${ratio:+(${ratio}%)}_out=${out:-0},0,0,0,0"
  [ -n "$ratio" ] && say "prefix cache-read: ${ratio}% of input (in=${inp:-?} cache_read=${chr:-0} out=${out:-0}) — target ≥60% Opus / ≥70% DeepSeek"
  return 0
}
# D2: reduce a raw CI / gh-run log to its ERROR SIGNATURE before it's fed back to the fixer — the model needs
# the FAILURE, not the build noise. Keeps failing-test / error / assertion / panic / stack-frame (file:line)
# lines, drops passing tests + build/setup noise + timestamps + ANSI + spinners, dedups, and HARD-CAPS the
# payload (CI_SIG_LINES, default 120) so a pathological log can't blow the context. FAIL-SOFT: if nothing
# matches, keeps a tail of the raw log rather than emptying the feedback. Proven: scratchpad/d2-cisig-test.sh.
ci_signature(){
  local raw="$1" out="${2:-$1}" cap="${CI_SIG_LINES:-120}" sig
  [ -f "$raw" ] || return 0
  sig=$(sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$raw" 2>/dev/null \
    | grep -iE '\b(fail|failed|error|assert|assertion|expected|panic|exception|traceback|denied|undefined|referenceerror|typeerror|syntaxerror)\b|--- FAIL|✗|✘|✕|✖|×|not ok|exit (code |status )?[1-9]|::error|\[blocker\]|\[major\]|[A-Za-z0-9_./-]+\.(go|ts|tsx|js|jsx|mjs|cjs|py|rb|rs|java|php|c|cpp|h):[0-9]+|File "[^"]*", line [0-9]+|\bat .+:[0-9]+' 2>/dev/null \
    | grep -viE '\b(0 (failed|errors?)|no (errors?|failures?)|passed|passing|✓|✔|success|all good)\b' 2>/dev/null \
    | awk '!seen[$0]++' | head -"$cap")
  if [ -n "$sig" ]; then
    { printf '# CI failure signature (reduced from the raw log — the failure, not the build noise):\n'; printf '%s\n' "$sig"; } > "$out.d2sig" && mv -f "$out.d2sig" "$out"
  else
    { printf '# CI log tail (no error signature matched — last lines of the raw log):\n'; tail -40 "$raw"; } > "$out.d2sig" && mv -f "$out.d2sig" "$out"
  fi
}
# D3: per-agent token/cost report at end-of-run — aggregates the D1 `usage` rows in metrics.csv per agent,
# names the cost HOG (usually the 4-critic panel at max effort), and appends `opencode stats` if available.
# ONE file per run; in a swarm each worker writes its OWN .opencode/token-report.md (B1 one-file-per-worker,
# no shared-file clash). Empty offline (needs D1's live usage rows); the aggregation is proven in
# scratchpad/d3-tokenreport-test.sh. Fail-soft — never breaks the run report.
token_report(){
  [ "${ACE_TELEMETRY:-1}" = 1 ] || return 0
  local f=.opencode/metrics.csv out=.opencode/token-report.md
  [ -f "$f" ] || return 0
  { printf '# Token report — run %s (%s)\n\n' "${RUN_ID:-?}" "$(date +%FT%T 2>/dev/null || echo '?')"
    printf '| agent | calls | input | cache_read | output | cache-read%% |\n|---|--:|--:|--:|--:|--:|\n'
    awk -F, -v r="${RUN_ID:-0}" 'NR>1 && $1==r && $4=="usage" {
        a=$5; n[a]++; chr=inp=out=0;
        if (match($6,/cache_read=[0-9]+/)) chr=substr($6,RSTART+11,RLENGTH-11);
        if (match($6,/in=[0-9]+/))        inp=substr($6,RSTART+3,RLENGTH-3);
        if (match($6,/out=[0-9]+/))       out=substr($6,RSTART+4,RLENGTH-4);
        CR[a]+=chr; IN[a]+=inp; OUT[a]+=out; TOT[a]+=inp+out
      } END {
        hog=""; hv=0;
        for (a in n){ pct=(IN[a]>0?int(CR[a]*100/IN[a]):0); printf "| %s | %d | %d | %d | %d | %d%% |\n",a,n[a],IN[a],CR[a],OUT[a],pct; if(TOT[a]>hv){hv=TOT[a];hog=a} }
        if (hog!="") printf "\n**Cost hog:** %s (~%d input+output tokens this run). If one agent dominates it is usually the HIGH-risk 4-critic panel at max effort — risk-tier the panel or shorten its prompt.\n",hog,hv
      }' "$f"
    printf '\n## opencode stats (per-session token/cost, if available)\n\n```\n'
    opencode stats 2>/dev/null | head -40 || true
    printf '```\n'
  } > "$out" 2>/dev/null || true
  grep -qE '^\| [A-Za-z_]+ \| [0-9]' "$out" 2>/dev/null && say "token report → .opencode/token-report.md (per-agent input/cache/output + cost hog)" || true
}
# E3: classify WHY a step stopped from its log + exit code so recovery is correct (never trust exit 0 —
# opencode run can exit 0 on error, #14551). Mechanical (log signatures + rc); the rathole supervisor covers
# the SILENT-progress judgment, this covers the STOP cause. Returns 0 + logs the mode when a failure signature
# is found (incl. exit-0-errored), 1 on a clean success. Proven: scratchpad/e3-failmode-test.sh.
classify_failure_mode(){
  [ "${ACE_TELEMETRY:-1}" = 1 ] || return 1
  local rc="${1:-0}" log=.opencode/last-run.log ilog="$HOME/.local/share/opencode/log/opencode.log" mode action blob
  # P1-4: on a CLEAN success (rc 0) do NOT scan the noisy inner debug log — on GOOD runs it routinely
  # carries keep-alive / ERROR-level lines / 3-digit numbers the broad regexes misread (advisory-only, but
  # it made nearly every clean step print a bogus FAILURE-MODE + write a junk row). Only when rc != 0 do we
  # scan both logs for the MODE; at rc 0 we run ONE narrow exit-0 check on the run log with a STRONG signal.
  if [ "$rc" != 0 ]; then
    blob="$( { tail -c 20000 "$log" 2>/dev/null; tail -c 20000 "$ilog" 2>/dev/null; } )"
    if printf '%s' "$blob" | grep -qiE 'timed out after 120000 ?ms|streamtext.*timeout|tool call timed out'; then mode="tool/bash-timeout (120s AI-SDK step ceiling)"; action="OVERSIZED inner step -> split (E1) / move the build out of the inner loop"
    elif printf '%s' "$blob" | grep -qiE 'contextoverflow|context (window )?(exceeded|overflow)|compaction failed'; then mode="context-overflow / compaction"; action="OVERSIZED -> split (E1); check D2 compaction / limit.input"
    elif printf '%s' "$blob" | grep -qiE 'steps? (cap|limit|budget) (hit|reached|exceeded)|max.?steps (cap|limit|hit|reached|exceeded)|force.?summariz'; then mode="steps-cap hit"; action="OVERSIZED -> split (E1) or raise the steps cap (E4)"
    elif printf '%s' "$blob" | grep -qiE 'connection (closed|reset)|econnreset|provider .*(timeout|error)|deepseek .*(closed|timeout)|(status|code|http)[^0-9]{0,8}(429|50[234]|529)\b|too many requests|overloaded'; then mode="provider timeout/limit"; action="backoff + retry (fresh run, lossless via E2)"
    elif [ "$rc" = 124 ] || [ "$rc" = 130 ]; then mode="outer wrapper timeout (kill)"; action="raise the wall budget or split (E1); checkpoint+resume (E2)"
    else return 1; fi
  elif printf '%s' "$(tail -c 20000 "$log" 2>/dev/null)" | grep -qiE '\b(fatal|panic|unhandled (exception|rejection)|segmentation fault)\b|traceback \(most recent call|^Error:|uncaughtexception'; then
    mode="EXIT 0 BUT ERRORED (#14551) — not a real success"; action="treat as FAILURE; re-run (lossless via E2), do NOT mark done"
  else return 1; fi
  metric "failmode,${AGENT:-?},$(printf '%s' "$mode -> $action" | tr ',' ';'),0,0,0,$rc"
  say "FAILURE-MODE CLASSIFICATION: ${mode} → ${action}"
  return 0
}
# Post-mortem: append THIS run's time breakdown (by phase + slowest steps) to .opencode/run-summary.txt
# (rolling history, newest at bottom) and a closing `run` row to the CSV. Reads only this run's rows (run_id).
write_run_summary(){
  [ "${ACE_TELEMETRY:-1}" = 1 ] || return 0
  [ -n "${_SUMMARY_DONE:-}" ] && return 0; _SUMMARY_DONE=1
  local f=.opencode/metrics.csv out=.opencode/run-summary.txt now dur; now=$(date +%s); dur=$(( now - ${RUN_T0:-now} ))
  { printf '═══ run %s · %s · ended %s ═══\n' "${RUN_ID:-?}" "$(branch 2>/dev/null)" "$(date +%FT%T)"
    printf 'wall %dm%02ds · laps=%s features=%s ci_fixes=%s plans=%s conflicts=%s\n' "$((dur/60))" "$((dur%60))" "${lap:-0}" "${features:-0}" "${fixes:-0}" "${plans:-0}" "${conflicts:-0}"
    printf 'policy merge_gate=%s auto_merge=%s deploy=%s max_features=%s overseer=%s\n' "${MERGE_GATE:-remote}" "${AUTOMERGE:-0}" "${DEPLOY:-0}" "${MAX_FEATURES:-0}" "$(orch_model 2>/dev/null)"
    if [ -f "$f" ]; then
      printf 'time by phase:\n'
      awk -F, -v r="${RUN_ID:-0}" 'NR>1 && $1==r {w[$4]+=$7; n[$4]++} END{for(e in w) printf "%d %s %d\n", w[e], e, n[e]}' "$f" \
        | sort -rn | while read -r s e c; do printf '  %-9s %3dm%02ds  (%d×)\n' "$e" "$((s/60))" "$((s%60))" "$c"; done
      printf 'slowest steps:\n'
      awk -F, -v r="${RUN_ID:-0}" 'NR>1 && $1==r {printf "%d\t%s\t%s\n",$7,$4,$6}' "$f" | sort -rn | head -5 \
        | while IFS="$(printf '\t')" read -r s e l; do printf '  %4ds  %-7s %s\n' "$s" "$e" "$l"; done
    fi
    printf '\n'
  } >> "$out" 2>/dev/null || true
  metric "run,,${features:-0}feat_${fixes:-0}fix_${lap:-0}lap,$dur,0,0,0"
}
# Push a milestone line to Hermes (-> Telegram/phone) with `hermes send`. Opt-in (HERMES_NOTIFY=1) and
# FAIL-SOFT: notify off, no `hermes` on PATH, or a send error all degrade to a silent no-op — it can never
# break or block the loop. Curated milestones only (merge/deploy/CI-red/rathole/block/stop); for LIVE output
# ask the bot (terminal toolset) to tail .opencode/last-run.log. stdin from /dev/null so it can't TTY-hang.
hermes_notify(){
  [ "${HERMES_NOTIFY:-0}" = 1 ] || return 0
  command -v hermes >/dev/null 2>&1 || return 0
  hermes send --to "${HERMES_TO:-telegram}" --subject "${HERMES_SUBJECT:-$(repo_slug 2>/dev/null):$(branch 2>/dev/null)}" "$1" </dev/null >/dev/null 2>&1 || true
  # optional: attach a visual status snapshot to the milestone (HERMES_SNAP=1)
  [ "${HERMES_SNAP:-0}" = 1 ] && ace snap --to "${HERMES_TO:-telegram}" >/dev/null 2>&1 || true
}

# request_approval <kind> <summary> -> 0 approved · 1 denied/timeout · 2 no chat channel (caller decides).
# Notifies chat + polls .opencode/approvals/<token>.decision, which `ace approve` writes when you reply.
request_approval(){
  command -v hermes >/dev/null 2>&1 || return 2
  mkdir -p .opencode/approvals 2>/dev/null
  local tok; tok="$(date +%s)$$"; tok="a${tok: -8}"
  printf 'kind=%s\nsummary=%s\nbranch=%s\nrequested=%s\n' "$1" "$2" "$(branch 2>/dev/null)" "$(date -Is)" > ".opencode/approvals/$tok.request" 2>/dev/null
  hermes send --to "${HERMES_TO:-telegram}" --subject "ACE approval" "🔔 Approve: $1
$2
Reply:  ace approve $tok yes   |   ace approve $tok no   (or just: approve / deny)" </dev/null >/dev/null 2>&1 || true
  say "⏳ awaiting chat approval ($tok): $1"
  local waited=0 to="${APPROVAL_TIMEOUT:-3600}" iv="${APPROVAL_POLL:-15}" d
  while [ "$waited" -lt "$to" ]; do
    if [ -f ".opencode/approvals/$tok.decision" ]; then
      d="$(cat ".opencode/approvals/$tok.decision" 2>/dev/null)"; rm -f ".opencode/approvals/$tok.request" ".opencode/approvals/$tok.decision"
      case "$d" in yes) say "✅ approved ($tok)."; return 0 ;; *) say "❌ denied ($tok)."; return 1 ;; esac
    fi
    sleep "$iv"; waited=$((waited+iv))
  done
  say "⌛ approval timed out after ${to}s ($tok) — treating as DENIED."; rm -f ".opencode/approvals/$tok.request"; return 1
}

# kanban_sync — mirror ROADMAP.md -> Hermes kanban for a chat-visible board (ONE-WAY; ACE stays the
# executor, no swarm). Opt-in HERMES_KANBAN=1. Best-effort + fail-soft; idempotent by content hash.
kanban_sync(){
  [ "${HERMES_KANBAN:-0}" = 1 ] || return 0
  command -v hermes >/dev/null 2>&1 && hermes kanban --help >/dev/null 2>&1 || return 0
  [ -f ROADMAP.md ] || return 0
  mkdir -p .opencode; local map=.opencode/.kanban-map proj; proj="$(repo_slug 2>/dev/null || basename "$(pwd)")"; touch "$map" 2>/dev/null || return 0
  local line item h cid
  grep -nE '^[[:space:]]*- \[ \] ' ROADMAP.md 2>/dev/null | grep -v 'add your first' | while IFS= read -r line; do
    item="$(printf '%s' "$line" | sed -E 's/^[0-9]+:[[:space:]]*- \[ \] //')"; h="$(printf '%s' "$item" | sha1sum | cut -c1-12)"
    grep -q "^$h " "$map" 2>/dev/null && continue
    cid="$(hermes kanban create --project "$proj" --idempotency-key "$proj-$h" --body "$item" "$item" 2>/dev/null | grep -oiE '[a-f0-9][a-f0-9-]{6,}' | head -1)"
    printf '%s %s\n' "$h" "${cid:-pending}" >> "$map"
  done
  grep -nE '^[[:space:]]*- \[[xX]\] ' ROADMAP.md 2>/dev/null | while IFS= read -r line; do
    item="$(printf '%s' "$line" | sed -E 's/^[0-9]+:[[:space:]]*- \[[xX]\] //')"; h="$(printf '%s' "$item" | sha1sum | cut -c1-12)"
    cid="$(grep "^$h " "$map" 2>/dev/null | awk '{print $2}')"
    { [ -n "$cid" ] && [ "$cid" != pending ]; } && { hermes kanban complete "$cid" >/dev/null 2>&1; sed -i "/^$h /d" "$map" 2>/dev/null; }
  done
  return 0
}
command -v gh >/dev/null || { echo "need gh"; exit 1; }
command -v opencode >/dev/null || { echo "need opencode"; exit 1; }
branch(){ git branch --show-current; }
repo_slug(){ gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null; }
# effective overseer model id: per-agent MODEL_orchestrator override › ORCH_PROVIDER alias › Claude Opus (default).
orch_model(){
  local m=""; [ -f "$ACE_CFG" ] && m="$(grep -E '^MODEL_orchestrator=' "$ACE_CFG" | tail -1 | cut -d= -f2-)"
  if [ -z "$m" ]; then case "$([ -f "$ACE_CFG" ] && grep -E '^ORCH_PROVIDER=' "$ACE_CFG" | tail -1 | cut -d= -f2-)" in
    opus) m=anthropic/claude-opus-4-8 ;; sonnet) m=anthropic/claude-sonnet-4-6 ;; gpt) m=openai/gpt-5 ;; deepseek) m=deepseek/deepseek-v4-pro ;; *) m=anthropic/claude-opus-4-8 ;;
  esac; fi
  printf '%s' "$m"
}
# provider family for the Claude-limit guard — must reflect the EFFECTIVE model, not just ORCH_PROVIDER,
# or a Claude overseer set via MODEL_orchestrator is treated as deepseek and its usage-cap is never handled.
orch_provider(){ case "$(orch_model)" in anthropic/*) echo claude ;; openai/*) echo openai ;; *) echo deepseek ;; esac; }
latest_run(){ gh run list --branch "$(branch)" -L1 --json databaseId -q '.[0].databaseId' 2>/dev/null; }
# In a swarm flow, the coordinator hands us the exact claimed item via SWARM_ITEM
# (so N flows take DIFFERENT items without filtering ROADMAP — each ticks its own
# line, which merges cleanly). Otherwise pick the first open ROADMAP item.
next_item(){
  [ -n "${SWARM_ITEM:-}" ] && { printf '%s\n' "$SWARM_ITEM"; return; }
  grep -nE '^[[:space:]]*- \[ \] ' ROADMAP.md 2>/dev/null | grep -v 'add your first' | head -1 | sed -E 's/^[0-9]+:[[:space:]]*- \[ \] //'; }

# Keep the ROADMAP fed from OBJECTIVES — the loop draws from BOTH. Before working the
# queue, the orchestrator decomposes any objective NOT already covered by ROADMAP items
# into concrete tasks and appends them. So a goal ADDED to OBJECTIVES.md is broken down +
# queued automatically (no hand-editing ROADMAP). Runs ONCE per single-flow run; the swarm
# coordinator invokes it via LOOP_SYNC_ONLY=1 before spawning workers. Gated: PLAN on, NOT a
# per-item swarm worker, and only when OBJECTIVES actually has open goals (else zero cost).
sync_objectives(){
  [ "${PLAN:-1}" = 1 ] || return 0
  [ -n "${SWARM_WORKER:-}" ] && return 0
  [ -f OBJECTIVES.md ] || return 0
  grep -qE '^[[:space:]]*- \[ \] ' OBJECTIVES.md 2>/dev/null || return 0
  # only when OBJECTIVES changed since the last sync (adding a goal bumps its mtime) → no
  # per-run planning cost when nothing new was added.
  local mark=.opencode/.objectives-synced
  [ -f "$mark" ] && [ "$mark" -nt OBJECTIVES.md ] && return 0
  say "syncing OBJECTIVES.md → ROADMAP.md (decomposing any uncovered goal into tasks)…"
  drive "sync OBJECTIVES → ROADMAP" "Read OBJECTIVES.md AND ROADMAP.md. For EACH objective or sub-goal that is NOT done AND NOT already covered by an existing ROADMAP item (open OR done — match by INTENT, not exact wording), break it into 2-6 concrete, independently-shippable tasks and append them under '## Next' in ROADMAP.md. Make the tasks PATH-DISJOINT so the parallel swarm never collides: no two OPEN tasks may edit the same file — ESPECIALLY not the same test file; if a shared file is unavoidable, give ONE task that file and add 'deps: <that task's title/keyword>' to the others so they run only after it merges. EVERY task MUST carry a 'Files:' hint listing the exact files it will touch — the source files AND their test files — so the swarm leases the true scope up front instead of colliding mid-flight. CONFLICT-AWARE BATCHING: a task's true FOOTPRINT is its edit set PLUS the upstream/downstream callers a signature change ripples onto — make the 'Files:' hint cover that blast radius, not just the obvious file, so two OPEN tasks never share a file. Prefer VERTICAL slices (one feature end-to-end in its own files) over HORIZONTAL layers (all models, then all controllers), which share files and force serialization. If several tasks must touch a HUB file (a shared registry, barrel, schema, DI container, or migration sequence many features import), give that hub to ONE task and add 'deps: <that task>' to the rest so only it edits the hub — never leave two OPEN tasks both touching it. Emit the tasks as a disjoint BATCH: enough independent items to feed 2-3 parallel workers now, deferring the rest behind deps, so each planning pass hands the swarm a ready-to-run path-disjoint set. TASK-SIZE: each ROADMAP task MUST be sized to complete in a SINGLE run — ≤~3 files, ≤~150-200 changed lines, within the steps budget, no unbounded build in the inner loop. If an objective is larger, decompose it into ORDERED increments (scaffold → stub → fill → wire), each independently committable and independently verifiable by ci.sh; record the increment order + dependencies in the ROADMAP so a resumed run knows what is already done. CRITICAL: SKIP any objective already covered by the ROADMAP — do NOT duplicate existing items. Prefer North-Star value (user-facing/revenue/decision-quality) over infra; tag each task [value] or [infra]; never queue >2 infra in a row. Update OBJECTIVES.md statuses (mark in-progress; tick met sub-goals). If EVERY objective is already covered by the ROADMAP, output nothing and make NO commit. Otherwise branch chore/plan, commit ROADMAP.md + OBJECTIVES.md, and open a PR into main. Do NOT implement features — planning only." \
    || say "objectives sync skipped (planner error) — continuing with the existing ROADMAP."
  mkdir -p .opencode 2>/dev/null; touch .opencode/.objectives-synced 2>/dev/null || true
}

# Cache current runtime LTS/EOL facts so the standards_keeper reads a local file instead of webfetch-ing
# endoflife.date on EVERY review. Detects the stack cheaply, fetches the matching products, TTL-guarded.
refresh_version_cache(){
  local cache=.opencode/cache/versions.json ttl="${VERSION_CACHE_TTL:-604800}"   # 7 days
  { command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; } || return 0
  [ -f "$cache" ] && [ "$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) ))" -lt "$ttl" ] && return 0
  local prods=""
  [ -f package.json ] && prods="$prods nodejs"
  { [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; } && prods="$prods python"
  [ -f go.mod ] && prods="$prods go"
  [ -f Cargo.toml ] && prods="$prods rust"
  grep -rqiE 'postgres' .env.example Containerfile docker-compose* 2>/dev/null && prods="$prods postgresql"
  [ -n "$prods" ] || return 0
  mkdir -p .opencode/cache
  local out p b; out="$(jq -nc '{_fetched:(now|todate)}')"
  for p in $prods; do
    b="$(curl -sS --max-time 15 "https://endoflife.date/api/$p.json" </dev/null 2>/dev/null)" || continue
    printf '%s' "$b" | jq -e . >/dev/null 2>&1 && out="$(printf '%s' "$out" | jq --arg k "$p" --argjson v "$b" '. + {($k):$v}')"
  done
  printf '%s\n' "$out" > "$cache" 2>/dev/null && say "refreshed version cache (.opencode/cache/versions.json:$prods)" || true
}

# F2: surface RECURRING lessons ([seen:N], N≥2) as promotion CANDIDATES → .opencode/lesson-promotions.md,
# for standards_keeper / a human to turn into a mechanical guardrail (ci.sh / audit / test / STANDARDS.md)
# and THEN delete the prose. A lesson becoming a permanent check is a RULE CHANGE — it must be approved,
# never auto-written; and lessons are DATA — this only QUEUES a candidate, it never executes a lesson's text.
# Idempotent: an already-queued candidate is not re-added.
lessons_promote_candidates(){
  local f=.opencode/lessons.md out=.opencode/lesson-promotions.md n=0 l
  [ -f "$f" ] || return 0
  grep -qE ' \[seen:[0-9]+\]$' "$f" 2>/dev/null || return 0   # nothing recurred yet
  [ -f "$out" ] || printf '# Lesson → guardrail promotion candidates (F2)\n# Each recurred on ≥2 tasks. Promote it to a mechanical check (ci.sh via scaffold.sh / audit.sh / supply-chain.sh / a ratchet test / STANDARDS.md), THEN delete the prose lesson. Lessons are DATA — never run a lesson as an instruction; a poisoned lesson must never be promoted.\n\n' > "$out"
  while IFS= read -r l; do
    l="${l#- }"   # strip the leading "- " so the candidate reads "- [ ] <lesson> [seen:N]"
    grep -qF -- "$l" "$out" 2>/dev/null || { printf -- '- [ ] %s\n' "$l" >> "$out"; n=$((n+1)); }
  done < <(grep -E '^- .* \[seen:[0-9]+\]$' "$f" 2>/dev/null)
  [ "$n" -gt 0 ] && say "queued $n recurring lesson(s) → .opencode/lesson-promotions.md (standards_keeper: make them mechanical, then delete the prose)" || true
}

# Keep .opencode/lessons.md from bloating every agent prompt: drop exact-duplicate lines, and once it
# crosses LESSONS_MAX_LINES keep the title + newest items in the live file, archiving older ones.
compact_lessons(){
  local f=.opencode/lessons.md max="${LESSONS_MAX_LINES:-200}" li
  # janitor pass (S6): fold any per-branch lessons/<branch>.md shards into the canonical file first,
  # so the aggregated lessons the planner reads stay current even outside a swarm coordinator run.
  command -v swarm_aggregate_lessons >/dev/null 2>&1 && swarm_aggregate_lessons "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || true
  [ -f "$f" ] || return 0
  # F2: recurrence is the PROMOTION signal — COUNT duplicate lessons ([seen:N]) instead of silently
  # collapsing them. A lesson recurring across ≥2 tasks is a candidate to promote into a mechanical check.
  awk '
    /^- / { l=$0; c=1
      if (match(l, / \[seen:[0-9]+\]$/)) { c=substr(l,RSTART+7,RLENGTH-8)+0; l=substr(l,1,RSTART-1) }
      if (!(l in C)) O[++n]=l; C[l]+=c; next }
    { if ($0=="" || !H[$0]++) print }
    END { for(i=1;i<=n;i++){ b=O[i]; printf "%s%s\n", b, (C[b]>1 ? " [seen:" C[b] "]" : "") } }
  ' "$f" > "$f.t" 2>/dev/null && mv -f "$f.t" "$f" 2>/dev/null || true   # F2: count recurrences, don't collapse
  lessons_promote_candidates   # F2: queue ≥2-seen lessons for promotion to a mechanical guardrail
  li="$(grep -c '^- ' "$f" 2>/dev/null)"; li="${li:-0}"; [ "$li" -gt "$max" ] 2>/dev/null || return 0
  { awk '/^- /{exit} {print}' "$f"; grep '^- ' "$f" | tail -n "$max"; } > "$f.t" 2>/dev/null         # header + newest $max items
  grep '^- ' "$f" | head -n "$(( li - max ))" >> .opencode/lessons-archive.md 2>/dev/null || true     # archive the rest (no overlap)
  mv -f "$f.t" "$f" 2>/dev/null && say "compacted lessons.md (kept newest $max of $li; older archived)" || true
}

# --- preflight: confirm we're acting on the RIGHT repo + branch + PR before doing anything ---
preflight(){
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { say "not inside a git repo — stopping."; exit 1; }
  git remote get-url origin >/dev/null 2>&1 || { say "no 'origin' remote — stopping."; exit 1; }
  local slug b; slug="$(repo_slug)"; b="$(branch)"
  [ -n "$slug" ] || { say "gh can't resolve this repo (gh auth / origin?) — stopping."; exit 1; }
  [ -n "$b" ]    || { say "detached HEAD — checkout a branch first. Stopping."; exit 1; }
  if [ -n "$EXPECT_REPO" ] && [ "$EXPECT_REPO" != "$slug" ]; then
    say "REFUSING: repo is $slug but EXPECT_REPO=$EXPECT_REPO — wrong repo. Stopping."; exit 1; fi
  say "preflight — repo: $slug   branch: $b   overseer: $(orch_model)${ORCH_MODEL_OVERRIDE:+ (override $ORCH_MODEL_OVERRIDE)}"
  # CONSISTENCY: reconcile drift before starting (git main↔origin, gitnexus, opencode, podman) so the
  # guards below act on synced state and the loop starts in-scope. Never destroys unpushed work.
  # PREFLIGHT DEDUPE: the consistency reconcile + version-cache warm are PROJECT-GLOBAL + relatively expensive
  # (git/gh fetch, gitnexus, webfetch). In a swarm every worker re-runs preflight PER ITEM — so gate them
  # behind a short per-project TTL stamp instead of reconciling on every lap (set PREFLIGHT_TTL=0 to force).
  local _pfs="$HOME/.config/ace/preflight/$(printf '%s' "$slug" | tr '/ ' '__').stamp" _pfttl="${PREFLIGHT_TTL:-600}"
  mkdir -p "$(dirname "$_pfs")" 2>/dev/null
  if [ "$_pfttl" -gt 0 ] 2>/dev/null && [ -f "$_pfs" ] && [ "$(( $(date +%s) - $(stat -c %Y "$_pfs" 2>/dev/null || echo 0) ))" -lt "$_pfttl" ]; then
    say "preflight — reconcile skipped (done <${_pfttl}s ago; PREFLIGHT_TTL=0 forces)"
  else
    command -v ace >/dev/null 2>&1 && { ace consistency fix </dev/null >/dev/null 2>&1 || true; say "preflight — consistency reconciled (git/gitnexus/opencode/podman)"; }
    touch "$_pfs" 2>/dev/null || true
  fi
  # version-cache warm is WORKTREE-LOCAL, NOT project-global: versions.json is gitignored, so each swarm worktree
  # needs its own copy. It must run per-worktree — NOT behind the shared stamp above (which the coordinator/first
  # worker warms, starving every other worker → standards_keeper webfetches endoflife.date each review). It carries
  # its own 7-day mtime TTL (refresh_version_cache), so this is a cheap no-op once a worktree's cache is warm.
  refresh_version_cache
  # STALE-BRANCH GUARD: if this branch's work is already shipped (a MERGED PR for its head), don't
  # reprocess it — return to main, delete the stale branch (local + remote), and continue from there.
  if [ "$b" != main ] && [ "$b" != master ]; then
    local mpr; mpr="$(gh pr list --head "$b" --state merged -L1 --json number -q '.[0].number' 2>/dev/null)"
    if [ -n "$mpr" ]; then
      say "branch '$b' was already merged (PR #$mpr) — switching to main + removing the stale branch."
      git checkout -f main >/dev/null 2>&1 && git pull --ff-only >/dev/null 2>&1 || true
      git branch -D "$b" >/dev/null 2>&1 || true
      git push origin --delete "$b" >/dev/null 2>&1 || true
      b="$(branch)"
    fi
  fi
  # RESUME: a prior run may have died mid-commit (overseer ran out of credits/limit, crash) leaving
  # finished, gate-passing work uncommitted. Rescue it before doing anything else so nothing is lost.
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    say "uncommitted changes from a prior run — verifying ./ci.sh before resuming…"
    for f in .opencode/last-run.log .opencode/ci-failure.log .opencode/vps-verify-report.md .opencode/loop-state.env .opencode/metrics.csv .opencode/run-summary.txt .opencode/token-report.md .opencode/.session-id .opencode/.kanban-map .opencode/approvals/ .opencode/.step-budget .opencode/.container-green .opencode/ci-build.log .opencode/.harvested-warnings .opencode/cache/versions.json; do
      grep -qxF "$f" .gitignore 2>/dev/null || echo "$f" >> .gitignore; done
    if [ ! -e ./ci.sh ]; then
      say "STOPPING: no ./ci.sh gate in $(pwd) — can't verify the uncommitted work. Is this your project directory (not e.g. ACE's own repo)?"; exit 1
    elif ./ci.sh >/dev/null 2>&1; then
      git add -A && git commit -m "chore(resume): commit gate-green work from an interrupted run" >/dev/null 2>&1 || true
      git push -u origin HEAD >/dev/null 2>&1 || true
      gh pr create --base main --fill >/dev/null 2>&1 || true
      say "rescued + pushed the interrupted work (./ci.sh GREEN)."
    else
      say "REFUSING to resume: uncommitted work FAILS ./ci.sh — fix or stash it, then re-run. Stopping."; exit 1
    fi
  fi
  # if gh associates an open PR with this branch, make sure it's really THIS repo+branch
  local prnum; prnum="$(gh pr view --json number -q .number 2>/dev/null)"
  if [ -n "$prnum" ]; then
    local st hd base
    st="$(gh pr view --json state -q .state 2>/dev/null)"
    hd="$(gh pr view --json headRefName -q .headRefName 2>/dev/null)"
    base="$(gh pr view --json baseRepository -q '.baseRepository.owner.login + "/" + .baseRepository.name' 2>/dev/null)"
    if [ "$st" != OPEN ]; then
      say "the PR gh maps to '$b' is #$prnum ($st) — not open, treating as no pending PR."
    elif [ "$hd" != "$b" ] || { [ -n "$base" ] && [ "$base" != "$slug" ]; }; then
      say "REFUSING: pending PR #$prnum is for ${base:-?}:$hd, not $slug:$b — wrong repo/branch. Stopping."; exit 1
    else
      say "pending PR #$prnum confirmed for $slug:$b."
    fi
  fi
}

# --- opencode runner with Claude (subscription) session-limit handling ---
claude_limit_hit(){ grep -qiE 'usage limit|rate.?limit|quota|too many requests|429|limit reached|resets? (at|in)|session limit|credit balance|insufficient (credit|quota|funds|balance)|out of (credit|usage|tokens)|billing|payment required|402|overloaded|529|authentication_error|invalid x-api-key|expired' "$1" 2>/dev/null; }
handle_claude_limit(){
  [ "$(orch_provider)" = deepseek ] && return 1   # not on Claude -> not a subscription cap, let it surface
  [ -n "$ORCH_MODEL_OVERRIDE" ]     && return 1   # already delegated to DeepSeek -> a real failure
  local action="$ON_CLAUDE_LIMIT"
  if [ -z "$action" ]; then
    if [ -t 0 ]; then
      printf '\n[auto-loop] Claude limit hit. [w]ait for reset / [c]ancel & save / [d]elegate to DeepSeek? '
      local a; read -r a </dev/tty || a=w
      case "$a" in c*) action=cancel;; d*) action=deepseek;; *) action=wait;; esac
    else action=wait; fi   # unattended default: ride it out
  fi
  case "$action" in
    cancel)   say "saving (all work is committed per-PR) + stopping. Resume later: ace resume."; exit 0 ;;
    deepseek) ORCH_MODEL_OVERRIDE="$DEEPSEEK_OVERSEER"; WAITED=0; say "delegating overseer -> DeepSeek ($ORCH_MODEL_OVERRIDE) for the rest of this run."; return 0 ;;
    wait|*)
      # DO NOT auto-downgrade the overseer — a weaker model gives worse plans/reviews. Wait for the
      # provider limit to RESET on the model you chose. Only stop (never silently swap models) if it
      # somehow hasn't reset within the (long) budget. Opt in to a fallback with ON_CLAUDE_LIMIT=deepseek.
      if [ "$WAITED" -ge "$CLAUDE_RESET_WAIT" ]; then
        say "⛔ $(orch_provider) limit hasn't reset in ~$((CLAUDE_RESET_WAIT/3600))h — stopping for review (all work is committed per-PR; resume: ace resume). To auto-fall-back instead, re-run with ON_CLAUDE_LIMIT=deepseek."
        hermes_notify "⛔ $(orch_provider) limit — loop stopped (no reset in ~$((CLAUDE_RESET_WAIT/3600))h); NOT downgraded"; exit 0; fi
      say "⏳ $(orch_provider) usage limit — WAITING for reset on your model (no downgrade). Re-checking in ${CLAUDE_POLL}s · waited ${WAITED}/${CLAUDE_RESET_WAIT}s · ON_CLAUDE_LIMIT=deepseek|cancel to change · Ctrl-C to stop."
      write_state "waiting: $(orch_provider) limit reset"; sleep "$CLAUDE_POLL"; WAITED=$((WAITED+CLAUDE_POLL)); return 0 ;;
  esac
}
# best-effort overseer context-fill readout (opencode hard-compacts/hands over at ~80% of the 1M window)
report_context(){ local u; u="$(grep -oiE '[0-9][0-9,]+ *tokens' .opencode/last-run.log 2>/dev/null | tail -1 | grep -oE '[0-9,]+' | tr -d ,)"; [ -n "$u" ] && say "overseer context: ~$((u*100/1048576))% of 1M (auto-handover at ~80%)" || true; }
# machine-readable resume state, refreshed each step (read by 'ace resume')
write_state(){ printf 'updated=%s\npid=%s\nmode=%s\nbranch=%s\noverseer=%s\nstep=%s\nci=%s\nfeatures=%s\nfixes=%s\nplans=%s\n' "$(date -Is)" "$$" "${ACE_LOOP_MODE:-foreground}" "$(branch)" "${ORCH_MODEL_OVERRIDE:-$(orch_model)}" "${1:-}" "${CI_STATE:-idle}" "${features:-0}" "${fixes:-0}" "${plans:-0}" > .opencode/loop-state.env 2>/dev/null || true; }
# best-effort: the heaviest live subprocess under the loop (what's eating wall-time right now),
# or "⋯ thinking" when only the agent is running (waiting on the model). One ps snapshot; no output captured.
current_activity(){
  ps -eo pid=,ppid=,cputime=,args= 2>/dev/null | awk -v r="${1:-$$}" -v srv="${SERVER_PROCS}" '
    function secs(t,  n,a){ n=split(t,a,":"); return (n==3)?a[1]*3600+a[2]*60+a[3]:(n==2)?a[1]*60+a[2]:a[1] }
    function base(s,  b){ b=s; sub(/.*\//,"",b); return b }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      pid=$1; ppid=$2; ct[pid]=secs($3); $1=$2=$3=""; sub(/^ +/,""); ar[pid]=$0
      kids[ppid]=kids[ppid] " " pid
    }
    END{
      qn=1; Q[1]=r; vis[r]=1
      for(i=1;i<=qn;i++){ n=split(kids[Q[i]],c," "); for(j=1;j<=n;j++){ ch=c[j]; if(ch!="" && !vis[ch]){ vis[ch]=1; qn++; Q[qn]=ch } } }
      lbl=""; bt=-1
      for(i=2;i<=qn;i++){ p=Q[i]
        if(ar[p] ~ srv) continue                                    # skip idle MCP/LSP helper servers
        m=split(ar[p],t," "); name=base(t[1])
        if(name==""||name=="opencode"||name=="timeout"||name=="tee"||name=="sleep"||name=="ps"||name=="awk") continue
        lab=name
        if(name ~ /^(node|python[0-9.]*|uv|uvx|npm|npx|bun|deno|sh|bash)$/){           # a launcher: name the SCRIPT it runs
          for(k=2;k<=m;k++){ if(t[k] ~ /^-/) continue; lab=name" "base(t[k]); break } }
        else if(m>=2 && t[2]~/^[a-zA-Z]/ && t[2]!~/[\/.]/) lab=name" "t[2]
        if(ct[p]>bt){ bt=ct[p]; lbl=lab }
      }
      printf "%s", (lbl==""||bt<1) ? "⋯ thinking" : (lbl" ("bt"s)")
    }'
}
# exits 0 if any descendant of $1 is a known-slow build/install/compile/test step — its time is credited,
# not charged. EXCLUDES the persistent MCP/LSP servers (Serena under uv/uvx, gitnexus/context7 under
# npm/npx): they share slow-step launcher names but run the whole session, so counting them would freeze
# the budget clock forever (defeating the BIG-TASK timeout AND the rathole supervisor — see SERVER_PROCS).
slow_active(){
  ps -eo pid=,ppid=,args= 2>/dev/null | awk -v r="${1:-$$}" -v slow=" ${SLOW_STEPS} " -v srv="${SERVER_PROCS}" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { pid=$1; ppid=$2; n=$3; sub(/.*\//,"",n); $1=$2=""; sub(/^ +/,""); kids[ppid]=kids[ppid]" "pid; nm[pid]=n; ar[pid]=$0 }
    END{
      qn=1; Q[1]=r; vis[r]=1; found=0
      for(i=1;i<=qn;i++){ m=split(kids[Q[i]],c," "); for(j=1;j<=m;j++){ ch=c[j]; if(ch!="" && !vis[ch]){ vis[ch]=1; qn++; Q[qn]=ch; if(index(slow," "nm[ch]" ")>0 && ar[ch] !~ srv) found=1 } } }
      exit (found?0:1)
    }'
}
# _credited_phase — review/reconcile/merge are OVERHEAD phases (like builds); they shouldn't burn the
# item's ACTIVE budget. Returns 0 when the MOST-RECENT opencode activity is a critic/reconcile/merge
# step (not the implementer/test_engineer, which is real building work → charged). This only relaxes
# the escalating big-task budget — the silence (HANG_AFTER), rathole (STALL_AFTER) and hard wall
# (OPENCODE_WALL_MAX) backstops still kill a genuinely stuck review. CREDIT_REVIEW=0 to charge it.
_credited_phase(){
  [ "${CREDIT_REVIEW:-1}" = 1 ] || return 1
  tail -n 40 .opencode/last-run.log 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tac 2>/dev/null | awk '
    BEGIN { r=1 }   # default: charge (exit 1). END always runs after a main-block exit, so decide via r.
    { l=tolower($0)
      if (l ~ /implementer|implement:|test_engineer|writing |editing |apply patch|str_replace|create file/) { r=1; exit }
      if (l ~ /reviewer|ux.?review|standards.?keep|alignment.?review|approve|changes_requested|conflict|reconcil|gh pr merge|pr merge|merging/) { r=0; exit }
    }
    END { exit r }'
}
# kill a process AND all its descendants, so a timed-out step never orphans a build holding the output pipe open.
kill_tree(){ local p="$1" sig="${2:-TERM}" k; for k in $(pgrep -P "$p" 2>/dev/null); do kill_tree "$k" "$sig"; done; kill -"$sig" "$p" 2>/dev/null; }
# Clean shutdown: on Ctrl-C / TERM, terminate the WHOLE subtree (the in-flight opencode + its MCP
# servers, any podman build, the watchdog subshell) so nothing is left orphaned — without this, ^C
# kills only this driver and its children keep running (Serena/gitnexus MCP, a build, opencode).
cleanup(){ trap - INT TERM; say "stopping — terminating child processes (opencode · MCP servers · builds)…"
  write_run_summary 2>/dev/null || true   # post-mortem even on a chat/Ctrl-C stop, not just a clean end
  local c op b; op="$(cat .opencode/.oppid 2>/dev/null)"
  [ -n "$op" ] && kill_tree "$op" TERM                                   # STOP opencode first (before it reparents) so it isn't mid-write while we snapshot
  for c in $(pgrep -P $$ 2>/dev/null); do kill_tree "$c" TERM; done      # watchdog subshell, tee, any build
  sleep 1
  # PRESERVE WIP: commit any in-flight work on the FEATURE branch (never main) so a later
  # 'reset --hard origin/main' can't wipe it — "kill everything, but don't lose stuff".
  b="$(branch 2>/dev/null)"
  if [ "$b" != main ] && [ "$b" != master ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git add -A 2>/dev/null && git commit --no-verify -q -m "WIP: preserved on stop (Ctrl-C/kill) — incomplete, do not merge" >/dev/null 2>&1 \
      && say "preserved in-flight work as a WIP commit on $b before stopping."
  fi
  sleep 1
  [ -n "$op" ] && kill_tree "$op" KILL
  for c in $(pgrep -P $$ 2>/dev/null); do kill_tree "$c" KILL; done
  exit 130; }
trap cleanup INT TERM
# Bounded, FAIL-OPEN rathole judge: asks a cheap model whether a SILENT step is progressing or stuck.
# It can NEVER hang the loop — curl is hard-timed and any failure/garble returns "unknown" (caller falls
# back to the wall cap). Echoes one of: progress | stuck|<reason>|<fix> | unknown.
rathole_verdict(){
  { [ -n "${DEEPSEEK_API_KEY:-}" ] && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; } || { echo unknown; return; }
  local oclog ctx body resp content v r f
  oclog="$HOME/.local/share/opencode/log/opencode.log"
  ctx="$( { echo '### last visible output (tail):'; tail -n 20 .opencode/last-run.log 2>/dev/null
            echo; echo '### recent internal tool activity (tail):'
            tail -n 200 "$oclog" 2>/dev/null | grep -oiE 'evaluated permission=bash pattern="[^"]{0,80}"|agent=[a-z_]+|message=[a-z ]+|error|denied' | sort | uniq -c | sort -rn | head -n 25
            echo; echo "### busiest process now: $(current_activity "${1:-$$}")"; } 2>/dev/null )"
  body="$(jq -nc --arg m "${RATHOLE_JUDGE:-deepseek-v4-flash}" --arg c "An autonomous coding agent step has produced NO new visible output for a while. Decide: is it making genuine progress, or stuck in a loop (ratholed)? A classic rathole is retrying an impossible action — e.g. installing a tool on an immutable/atomic host via sudo/dnf/rpm-ostree, or repeating a denied command. Reply with ONE LINE of strict JSON and nothing else: {\"verdict\":\"progress\"|\"stuck\",\"reason\":\"<=12 words\",\"fix\":\"<one corrective instruction, or empty>\"}

CONTEXT:
$ctx" '{model:$m,stream:false,temperature:0,max_tokens:200,messages:[{role:"user",content:$c}]}' 2>/dev/null)" || { echo unknown; return; }
  resp="$(curl -sS --max-time 60 https://api.deepseek.com/chat/completions \
            -H "Authorization: Bearer $DEEPSEEK_API_KEY" -H 'Content-Type: application/json' -d "$body" 2>/dev/null)" || { echo unknown; return; }
  content="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
  content="$(printf '%s' "$content" | grep -oE '\{.*\}' | head -1)"   # tolerate code-fences / stray prose
  [ -n "$content" ] || { echo unknown; return; }
  v="$(printf '%s' "$content" | jq -r '.verdict // empty' 2>/dev/null)"
  r="$(printf '%s' "$content" | jq -r '.reason  // empty' 2>/dev/null | tr '|\n' '  ')"
  f="$(printf '%s' "$content" | jq -r '.fix     // empty' 2>/dev/null | tr '|\n' '  ')"
  case "$v" in progress) echo progress ;; stuck) echo "stuck|${r}|${f}" ;; *) echo unknown ;; esac
}
# Discriminate a REAL denied-command loop from healthy-but-quiet internal tool
# work: a genuine loop is DOMINATED by one repeated actionable line in opencode's
# own log; healthy deep work is varied. Returns 0 (looping) only when a single
# pattern is ≥70% of ≥10 recent actionable lines. Fixes ACE issue #102: the
# stall watchdog only saw stdout (last-run.log), so tool-heavy steps read as
# silent and the un-deduped judge rationalised a false "repetitive calls" rathole.
_internal_looping(){
  local oclog counts top total
  oclog="$HOME/.local/share/opencode/log/opencode.log"
  # ONE canonical key per actionable line (the attempted command, or ERR) so a
  # denied line isn't double-counted (which would dilute the dominance ratio).
  counts="$(tail -n 80 "$oclog" 2>/dev/null | awk '
    match($0, /pattern="[^"]{0,80}"/) { print substr($0, RSTART, RLENGTH); next }
    /error|denied/                    { print "ERR"; next }' | sort | uniq -c | sort -rn)"
  [ -n "$counts" ] || return 1
  top="$(printf '%s\n' "$counts" | head -1 | awk '{print $1}')"
  total="$(printf '%s\n' "$counts" | awk '{s+=$1} END{print s+0}')"
  [ "${total:-0}" -ge 10 ] && [ "$(( ${top:-0} * 100 / total ))" -ge 70 ]
}
drive(){
  CURRENT_PHASE="$(printf '%s' "$1" | awk '{print $1}' | tr -d ':' | tr 'A-Z' 'a-z')"; export CURRENT_PHASE
  _ev accent "→ $1"
  say "→ opencode ($AGENT): $1"; mkdir -p .opencode; write_state "$1"
  local base="${OPENCODE_TIMEOUT:-1800}" budget="${OPENCODE_TIMEOUT:-1800}" tries=0 rtries=0 rc kp rdiag task="$2"
  local dstart lbl mc mb; dstart=$(date +%s); lbl="$(printf '%s' "$1" | tr ',\n' '; ' | cut -c1-60)"; printf '0 0' > .opencode/.step-budget
  while :; do
    # ACTIVE-WORK budget: run opencode in the background and PAUSE the budget clock while a known-slow
    # deterministic step (container build, dependency install, compile, test run) is in its subtree — those
    # shouldn't burn the task budget or trip a false BIG-TASK timeout. OPENCODE_WALL_MAX still bounds a stuck step.
    rm -f .opencode/.timedout .opencode/.oppid
    ( charged=0; credited=0; sincep=0; miss=0; lastsz=0; lastisz=0; stall=0; checks=0; hsz=0; hisz=0; ihang=0; start=$(date +%s); last=$start; lasthead="$(git rev-parse HEAD 2>/dev/null||echo none)"; op=""
      while :; do
        sleep "${WATCH_POLL:-10}"
        [ -n "$op" ] || op=$(cat .opencode/.oppid 2>/dev/null)
        if [ -z "$op" ] || ! kill -0 "$op" 2>/dev/null; then miss=$((miss+1)); [ "$miss" -ge 3 ] && break || continue; fi
        miss=0; now=$(date +%s); d=$(( now - last )); last=$now
        if slow_active "$op" || _credited_phase; then credited=$(( credited + d )); else charged=$(( charged + d )); fi
        # E3: a NEW commit = real progress (E2's per-increment checkpoints) → reset the active-work budget so a
        # steadily-committing worker is never killed for "no progress"; the hard OPENCODE_WALL_MAX still caps.
        nh="$(git rev-parse HEAD 2>/dev/null||echo none)"; [ "$nh" != "$lasthead" ] && { lasthead="$nh"; charged=0; }
        printf '%s %s' "$charged" "$credited" > .opencode/.step-budget 2>/dev/null   # surfaced to the per-step metric
        sincep=$(( sincep + d ))
        if [ "$sincep" -ge "${HEARTBEAT:-60}" ]; then sincep=0; e=$(( now - start )); act=$(current_activity "$op"); \
          printf '\033[0;36m[auto-loop %s]   … %dm%02ds wall (active %dm/%dm · +%dm build/review · ~%dm left) · now: %s\033[0m\n' \
            "$(date +%H:%M:%S)" $((e/60)) $((e%60)) $((charged/60)) $((budget/60)) $((credited/60)) $(((budget-charged)/60)) "$act"
          _stat "${CURRENT_PHASE:-work}" "$((charged/60))" "$((budget/60))" "$act"; fi
        # --- rathole supervisor: a SILENT step (no new output for STALL_AFTER, and no build running) gets judged ---
        sz=$(stat -c%s .opencode/last-run.log 2>/dev/null || echo 0)
        isz=$(stat -c%s "$HOME/.local/share/opencode/log/opencode.log" 2>/dev/null || echo 0)
        # --- HARD hang guard (deterministic, judge-INDEPENDENT): opencode's own log — stdout AND internal
        # tool log — has produced ZERO bytes for HANG_AFTER while nothing slow is building. That is a real
        # deadlock (e.g. hung parallel subagents — the 79-min stall the DeepSeek judge kept ruling
        # 'inconclusive', which then burned the full escalating wall cap). Preserve WIP so the retry RESUMES
        # instead of redoing from scratch, then kill → BIG-TASK retry (capped by OPENCODE_RETRIES).
        if [ "$sz" != "$hsz" ] || [ "$isz" != "$hisz" ]; then hsz=$sz; hisz=$isz; ihang=0
        elif ! slow_active "$op"; then ihang=$(( ihang + d )); fi
        if [ "$ihang" -ge "${HANG_AFTER:-1500}" ]; then
          printf '\033[0;31m[auto-loop %s]   ⛔ HANG — no opencode output for ~%dm (deadlocked step / stalled subagents). Preserving WIP + restarting the step.\033[0m\n' "$(date +%H:%M:%S)" $(( ${HANG_AFTER:-1500} / 60 ))
          _ev warn "⛔ HANG ~$(( ${HANG_AFTER:-1500}/60 ))m silent — WIP saved, restarting step"
          b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; { [ "$b" != main ] && [ "$b" != master ] && [ -n "$(git status --porcelain 2>/dev/null)" ] && git add -A 2>/dev/null && git commit --no-verify -q -m "WIP: auto-saved before hang-restart (resumes next attempt)" >/dev/null 2>&1; } || true
          : > .opencode/.timedout; kill_tree "$op" TERM; sleep 3; kill_tree "$op" KILL; break
        fi
        if [ "$sz" != "$lastsz" ]; then lastsz=$sz; lastisz=$isz; stall=0            # visible output → progressing
        elif [ "$isz" != "$lastisz" ]; then lastisz=$isz                             # internal tool work grew, no stdout:
          if _internal_looping; then stall=$(( stall + d )); else stall=0; fi        #   heal false-silence unless it's a real repeat-loop
        elif ! slow_active "$op"; then stall=$(( stall + d )); fi                     # truly silent → accrue toward a judge check
        if [ "$stall" -ge "${STALL_AFTER:-900}" ] && [ "$checks" -lt "${RATHOLE_MAXCHECKS:-6}" ]; then
          checks=$(( checks + 1 )); stall=0
          printf '\033[0;33m[auto-loop %s]   ⚠ no new output ~%dm — supervisor checking for a rathole…\033[0m\n' "$(date +%H:%M:%S)" $(( ${STALL_AFTER:-900} / 60 ))
          v=$(rathole_verdict "$op")
          if [ "${v%%|*}" = stuck ]; then
            rest=${v#stuck|}; reason=${rest%%|*}; fix=${rest#*|}
            printf '\033[0;31m[auto-loop %s]   ⛔ RATHOLE confirmed: %s\033[0m\n' "$(date +%H:%M:%S)" "$reason"
            { echo "reason: $reason"; echo "fix: $fix"; } > .opencode/.rathole
            kill_tree "$op" TERM; sleep 3; kill_tree "$op" KILL; break
          elif [ "$v" = progress ]; then
            printf '\033[0;36m[auto-loop %s]   ✓ supervisor: still progressing — continuing.\033[0m\n' "$(date +%H:%M:%S)"
          else
            printf '\033[0;36m[auto-loop %s]   · supervisor inconclusive — wall cap stays in charge.\033[0m\n' "$(date +%H:%M:%S)"
          fi
        fi
        if [ "$charged" -ge "$budget" ] || [ "$(( now - start ))" -ge "${OPENCODE_WALL_MAX:-10800}" ]; then \
          : > .opencode/.timedout; kill_tree "$op" TERM; sleep 3; kill_tree "$op" KILL; break; fi
      done ) & kp=$!
    # S5 shared prefix cache (swarm): the crew SYSTEM prompt + tool schemas come from the shared, STATIC
    # ~/.config/opencode/opencode.json, so the request PREFIX is byte-identical across all N workers and
    # DeepSeek's disk prefix cache bills the shared chunk at hit price. Keep every per-worker/per-run salt
    # (worker id, timestamp, branch/slug, the claimed item) in the VARIABLE TAIL — the "$task" user message
    # here — and NEVER prepend it to the system prompt or a shared context block, or the cache forks → misses.
    # D1 (across-TURNS + overseer): this SAME invocation runs every turn of a single autoloop with only
    # "$task" varying, so the prefix is byte-identical turn 1..N too. DeepSeek's disk prefix cache (hits bill
    # ~2%/8% of miss on Flash/Pro) AND Anthropic prompt caching for the Opus OVERSEER (cache-read ~10% of base
    # input, break-even ~2 hits) both apply AUTOMATICALLY: opencode 1.17.x / the AI SDK add cache_control to
    # the stable system+tools prefix for Claude — there is NO opencode.json knob to set. The ONLY requirement
    # is prefix stability (guaranteed above); never set/inject per-turn state BEFORE "$task". Live cache-read
    # ratio is captured by capture_usage() below (proven only on a real credit run — see TESTS-TODO / LEDGER D1).
    { opencode run --agent "$AGENT" ${ORCH_MODEL_OVERRIDE:+--model "$ORCH_MODEL_OVERRIDE"} "$task" & echo $! > .opencode/.oppid; wait $!; } 2>&1 | tee .opencode/last-run.log
    rc=${PIPESTATUS[0]}; kill "$kp" 2>/dev/null
    [ -f .opencode/.timedout ] && rc=124
    capture_usage 2>/dev/null || true   # D1: log token/prefix-cache usage (fail-soft) — feeds D3 + proves the cache win
    # E2 (same-session resume — a BONUS; the RELIABLE checkpoint/resume is git + the progress ledger, via the
    # orchestrator's commit-per-increment + RESUME DISCIPLINE). opencode 1.17.x HAS `opencode run -s <id>` /
    # `--continue` + `session list`, but headless REPLAY reliability is unverified (#11680/#3434) and the
    # `session list` columns need a live check — so keep it OFF by default (OPENCODE_SESSION_RESUME). On a
    # recoverable kill the loop re-runs the task FRESH; RESUME DISCIPLINE + per-increment commits make that
    # LOSSLESS from git. Opt-in only captures the id for a manual/verified `opencode run -s "$(cat
    # .opencode/.session-id)"` — do NOT auto-rely on it until a live run confirms replay (see TESTS-TODO E2).
    [ "${OPENCODE_SESSION_RESUME:-0}" = 1 ] && { opencode session list 2>/dev/null | grep -oiE 'ses[_-][a-z0-9]{6,}|[0-9a-f-]{20,}' | head -1 > .opencode/.session-id 2>/dev/null; } || true
    classify_failure_mode "$rc" 2>/dev/null || true   # E3: name the stop cause (incl. exit-0-errored #14551) → recovery guidance + metrics
    [ -f .opencode/.rathole ] && rc=124
    if [ "$rc" = 0 ]; then WAITED=0; report_context
      read -r mc mb 2>/dev/null < .opencode/.step-budget || { mc=0; mb=0; }
      metric "step,$AGENT,$lbl,$(( $(date +%s) - dstart )),${mc:-0},${mb:-0},0"
      return 0; fi
    if [ "$rc" = 124 ]; then
      if [ -f .opencode/.rathole ]; then
        # ---- CONFIRMED RATHOLE (not a big task): fix-and-retry, capped, then hard-stop + file an ACE item ----
        rdiag="$(cat .opencode/.rathole 2>/dev/null)"; rm -f .opencode/.rathole
        rtries=$((rtries+1))
        if [ "$rtries" -gt "${RATHOLE_RETRIES:-2}" ]; then
          mkdir -p "$(dirname "${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}")" 2>/dev/null
          printf '%s\t%s\t%s\n' "$(date -Is)" "$(repo_slug 2>/dev/null):$(branch 2>/dev/null)" "$(printf '%s' "$rdiag" | tr '\n' ' ')" >> "${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}" 2>/dev/null || true
          say "⛔ rathole persisted after ${RATHOLE_RETRIES:-2} fix-retries — stopping for review (filed an ACE-fixme note for the inception loop)."; hermes_notify "⛔ RATHOLE — loop stopped for review (ACE-fixme filed)"; return 1
        fi
        budget="$base"
        task="⚠ The previous attempt RATHOLED — it made NO progress and the supervisor stopped it:
$rdiag

Do NOT repeat the stuck action. Find the ROOT cause and take a DIFFERENT approach. If a tool was missing, this host is ATOMIC (Silverblue): never sudo/dnf/rpm-ostree install — use a toolbox or wire it into the Containerfile / --container gate.

--- original task ---
$2"
        say "🩺 supervisor fix-and-retry ($rtries/${RATHOLE_RETRIES:-2}) — ${rdiag//$'\n'/ }"
        continue
      fi
      tries=$((tries+1))
      if [ "$tries" -gt "${OPENCODE_RETRIES:-2}" ]; then
        # PRESERVE PROGRESS: never leave in-flight work uncommitted on a timeout-stop — a later
        # preflight 'git reset --hard origin/main' would wipe it. Auto-save a WIP commit on the
        # feature branch (never main/master), skipping the gate since the work is incomplete.
        if [ "$(branch)" != main ] && [ "$(branch)" != master ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
          git add -A 2>/dev/null && git commit --no-verify -m "WIP: auto-saved on timeout-stop ($1) — incomplete, do not merge" >/dev/null 2>&1 \
            && say "preserved in-flight work as a WIP commit on $(branch) before stopping."
        fi
        say "⏳ step still unfinished after ${OPENCODE_RETRIES:-2} extra attempt(s) at up to ${budget}s — stopping for review (raise OPENCODE_TIMEOUT/_MAX/_RETRIES, or split the task)."; return 1; fi
      budget=$(( base * (tries + 1) )); [ "$budget" -gt "${OPENCODE_TIMEOUT_MAX:-5400}" ] && budget="${OPENCODE_TIMEOUT_MAX:-5400}"
      # checkpoint in-flight work so the retry RESUMES from committed state instead of redoing from scratch.
      { b="$(branch)"; [ "$b" != main ] && [ "$b" != master ] && [ -n "$(git status --porcelain 2>/dev/null)" ] \
        && git add -A 2>/dev/null && git commit --no-verify -q -m "WIP: slice checkpoint before BIG-TASK retry" >/dev/null 2>&1 \
        && say "checkpointed in-flight work before retry (resumes from it)."; } || true
      task="⚠ BIG TASK / time budget exceeded — this step is too large for one pass. FIRST check git for already-committed WIP from a prior attempt and BUILD ON IT (do not restart). Then do ONLY the FIRST independently-shippable slice: implement it to the Definition of Done, commit, push, open its PR. Append the REMAINING slices to ROADMAP.md as separate items for later passes. Do NOT attempt the whole thing again.

--- original task ---
$2"
      say "⏳ BIG TASK — step ran past ${base}s (attempt $tries/${OPENCODE_RETRIES:-2}). Retrying with a SPLIT directive (ship one slice + queue the rest) and a larger ${budget}s budget."
      continue
    fi
    if claude_limit_hit .opencode/last-run.log && handle_claude_limit; then
      say "retrying the step after limit handling…"; continue
    fi
    return 1
  done
}
# A run can be conclusion=failure yet have executed ZERO jobs — GitHub Actions BLOCKED by a billing/
# spend cap or an infra outage marks the jobs failed without ever running them (no logs). That is NOT
# a code RED: no source change can turn it green. Signal = total executed (non-skipped) steps == 0.
# Fail-closed: any API error -> "not blocked" so we never auto-merge on uncertainty.
ci_blocked(){
  local id="$1" ran
  ran="$(gh run view "$id" --json jobs -q '[.jobs[].steps[]? | select(.conclusion!=null and .conclusion!="skipped")] | length' 2>/dev/null)"
  [ -n "$ran" ] && [ "$ran" -eq 0 ] 2>/dev/null
}
# B3 merge-gate hardening: a PR is verified against the base it BRANCHED FROM, not the CURRENT main — so
# two PRs that each pass alone can break together ("green-alone, broken-together"). After the merge queue
# merges the freshest origin/main into the branch (below), the branch holds a TENTATIVE MERGE commit that
# neither the dev-time FAST gate nor the pre-rebase FULL gate ever saw. Re-run the FULL container CI tier
# (the same VPS-parity gate merge_gate=local/both already trusts) on THAT tree and land ONLY on green — a
# semantic integration break surfaces HERE, at the gate, never on main (the GitHub-merge-queue discipline).
# Cache-aware (reuses the .container-green stamp; skips the rebuild when this exact merged tree already
# passed). Fails CLOSED on a RED (blocks the land). Fails OPEN only when the gate MECHANISM is unavailable
# (no ./ci.sh) — a missing gate must not wedge the merge queue, but a real RED always must.
_tentative_merge_ci_ok(){
  [ -e ./ci.sh ] || { say "tentative-merge gate: no ./ci.sh here — skipping the re-check (nothing to gate)."; return 0; }
  local cstate; cstate="$(git rev-parse HEAD 2>/dev/null):$(git status --porcelain 2>/dev/null | sha1sum | cut -c1-12)"
  if [ "$(cat .opencode/.container-green 2>/dev/null)" = "$cstate" ]; then
    say "tentative-merge gate: FULL ./ci.sh --container already GREEN for this merged tree (cached)."; return 0
  fi
  say "tentative-merge gate: running FULL ./ci.sh --container on the tentative merge with current origin/main…"
  if timeout "${LOCAL_CI_TIMEOUT:-1800}" ./ci.sh --container > .opencode/ci-failure.log 2>&1; then
    mkdir -p .opencode; printf '%s\n' "$cstate" > .opencode/.container-green 2>/dev/null || true
    say "tentative-merge gate: FULL ci GREEN on the merged tree — safe to land."; return 0
  fi
  say "tentative-merge gate: FULL ci RED on the merge with current origin/main — a green-alone/broke-together break. NOT landing (.opencode/ci-failure.log)."
  return 1
}
# item 3: is origin/main RED on its OWN — independent of THIS branch? Distinguishes a real RED main (a bad
# commit already landed; every worker's tentative merge is doomed) from a green-alone/broke-together break
# THIS branch caused. Verifies main's tip ALONE in a throwaway detached worktree; result cached per-sha in
# SWARM_DIR and serialized by a DEDICATED lock (fd 8, NOT the merge queue) so — even if two workers probe at
# once — the expensive build runs ONCE per bad sha. Fail-open (return 1 = "not proven RED"): no ./ci.sh, no
# worktree, or any error → we never INVENT a RED main (worst case = the old conflict path, no regression).
_main_head_red(){
  [ -n "${SWARM_WORKER:-}" ] || return 1
  [ -e ./ci.sh ] || return 1
  local msha; msha="$(git rev-parse origin/main 2>/dev/null)"; [ -n "$msha" ] || return 1
  local dir="${SWARM_DIR:-.opencode}"; local cache="$dir/main-ci.$msha"
  [ -f "$cache" ] && { [ "$(cat "$cache" 2>/dev/null)" = red ]; return; }
  exec 8>"$dir/main-check.lock" 2>/dev/null && flock -w "${LOCAL_CI_TIMEOUT:-1800}" 8 2>/dev/null
  [ -f "$cache" ] && { flock -u 8 2>/dev/null; [ "$(cat "$cache" 2>/dev/null)" = red ]; return; }   # built while we waited
  local base wt rc=0; base="$(mktemp -d)"; wt="$base/main-check"
  if git worktree add -q --detach "$wt" "$msha" 2>/dev/null; then
    say "RED-main probe: building origin/main ($( printf '%.12s' "$msha" )) ALONE to see if the break is ours or main's…"
    ( cd "$wt" && timeout "${LOCAL_CI_TIMEOUT:-1800}" ./ci.sh --container >/dev/null 2>&1 ) || rc=1
    git worktree remove --force "$wt" 2>/dev/null
  else rc=2; fi   # couldn't isolate main → fail-open
  rm -rf "$base"; flock -u 8 2>/dev/null
  case "$rc" in
    0) echo green > "$cache" 2>/dev/null; say "RED-main probe: main is GREEN on its own — the break is THIS branch's (conflict/fix path)."; return 1 ;;
    1) echo red   > "$cache" 2>/dev/null; say "RED-main probe: main is RED on its own — a bad commit landed. Triggering the RED-main breaker."; return 0 ;;
    *) return 1 ;;
  esac
}

# returns: 0 merged now · 2 nothing to merge (already merged / no PR / on main) · 1 PR present but not mergeable -> caller should stop
# When LOCAL_VOUCHED=1 (remote CI blocked but the local VPS-parity gate is GREEN) it skips the
# failed-check guard and merges with --admin (in case a required check is later configured).
merge_if_ready(){
  local pr; pr="$(gh pr view --json number -q .number 2>/dev/null)"
  [ -z "$pr" ] && { say "no PR for $(branch) — nothing to merge"; return 2; }
  local st hd; st="$(gh pr view --json state -q .state 2>/dev/null)"; hd="$(gh pr view --json headRefName -q .headRefName 2>/dev/null)"
  [ "$st" = OPEN ] || { say "PR #$pr is $st (not open) — nothing to merge"; return 2; }
  [ "$hd" = "$(branch)" ] || { say "PR #$pr head ($hd) != current branch ($(branch)) — refusing to merge the wrong PR"; return 1; }
  # ALL checks must be passing — no failures, none still pending. (Skipped when a local VPS-parity
  # gate has vouched for a PR whose ONLY problem is a BLOCKED remote CI — billing/infra.)
  if [ "${LOCAL_VOUCHED:-0}" != 1 ]; then
    local _chk; _chk="$(gh pr checks "$pr" 2>/dev/null)"
    if printf '%s' "$_chk" | grep -qiE '\b(fail|pending|cancelled|action_required)\b'; then
      say "PR #$pr: not every check is green yet — not merging"; return 1; fi
    # ZERO checks configured: an empty `gh pr checks` matches nothing above, which would let a remote/both
    # gate merge with NO CI having run. Don't treat "no checks" as "all green" — require ≥1 check.
    if [ -z "$(printf '%s' "$_chk" | tr -d '[:space:]')" ] && { [ "${MERGE_GATE:-remote}" = remote ] || [ "${MERGE_GATE:-remote}" = both ]; }; then
      say "PR #$pr: merge_gate=${MERGE_GATE:-remote} but the PR has NO CI checks — not merging (add a CI workflow, or use merge_gate=local)."; return 1; fi
  fi
  local m=""; for _ in 1 2 3 4 5; do m="$(gh pr view "$pr" --json mergeable -q .mergeable 2>/dev/null)"; [ "$m" = "UNKNOWN" ] || break; sleep 3; done
  if [ "$m" != MERGEABLE ]; then
    [ "$m" = CONFLICTING ] && { say "PR #$pr CONFLICTS with main"; return 3; }
    say "PR #$pr not mergeable ($m: required reviews / unknown) — not merging"; return 1
  fi
  # ── SWARM merge queue: serialize the merge + rebase onto the FRESHEST main first ────────────────────
  # Concurrent flows self-merge feat/<slug> PRs against a MOVING main with no rebase, so siblings touching
  # shared lines collide at merge (the genuine merge-conflict source). Hold a shared lock across the whole
  # rebase→merge and bring the branch up to the latest main first. Fail-safe: a rebase that itself conflicts
  # returns 3 (the caller's conflict path); any lock/fetch error falls through to a normal merge. Default on
  # in a swarm (SWARM_WORKER set); disable with SWARM_MERGE_QUEUE=0.
  local _mlk=""
  if [ "${SWARM_MERGE_QUEUE:-${SWARM_WORKER:+1}}" = 1 ] && [ -n "${SWARM_DIR:-}" ] && exec 9>"$SWARM_DIR/.merge.lock" 2>/dev/null && flock -w 900 9 2>/dev/null; then
    _mlk=1
    git fetch -q origin main 2>/dev/null || true
    if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
      say "swarm merge-queue: $(branch) is behind main — rebasing onto freshest origin/main before merge"
      if git merge --no-edit -q origin/main 2>/dev/null && git push -q origin "HEAD:$(branch)" 2>/dev/null; then
        for _ in 1 2 3; do m="$(gh pr view "$pr" --json mergeable -q .mergeable 2>/dev/null)"; [ "$m" = UNKNOWN ] || break; sleep 3; done
        [ "$m" = CONFLICTING ] && { flock -u 9 2>/dev/null; say "PR #$pr CONFLICTS after rebase"; return 3; }
        # B3: the branch now MERGES current origin/main — a tree the isolation gate never saw. Re-verify
        # THAT tentative merge with the FULL container gate before landing; a semantic break is caught here,
        # not on main. RED → defer to the conflict/fix path (bounded by MAX_CONFLICT), NOT a blind land.
        if ! _tentative_merge_ci_ok; then
          flock -u 9 2>/dev/null   # release the merge queue BEFORE the (slow) main-alone probe — don't stall siblings
          # item 3: is main RED on its OWN (not this branch's fault)? Then skip the conflict path — raise the
          # RED-main breaker (distinct return 4) so ONE worker fixes main and the rest stand down.
          if _main_head_red; then _swarm main-red set "$(git rev-parse origin/main 2>/dev/null)"; return 4; fi
          return 3
        fi
      else
        git merge --abort 2>/dev/null; flock -u 9 2>/dev/null
        say "PR #$pr: rebase onto main conflicts → deferring to the conflict path"; return 3
      fi
    fi
  fi
  if [ "${LOCAL_VOUCHED:-0}" = 1 ]; then say "PR #$pr: merging on the local ./ci.sh --container gate's authority ($([ "${MERGE_GATE:-remote}" = local ] && echo 'merge_gate=local' || echo 'remote CI blocked'))"
  else say "PR #$pr: ALL green + mergeable -> squash-merging and continuing on main"; fi
  local feat merged=0 mergeerr="" mflags="--squash --delete-branch"; feat="$(branch)"
  # local gate = the merge authority → bypass a GitHub ruleset an autonomous bot can't satisfy (a required
  # status check that never runs under ci_cd:none, or a required approval — the crew reviews internally).
  { [ "${LOCAL_VOUCHED:-0}" = 1 ] || [ "${MERGE_GATE:-remote}" = local ]; } && mflags="$mflags --admin"
  # retry: right after a fresh push GitHub may still be recomputing mergeability and reject the first call.
  # a PR merged out-of-band (e.g. you merged it in the UI during a limit pause) is SUCCESS, not failure.
  for _ in 1 2 3; do
    mergeerr="$(gh pr merge "$pr" $mflags 2>&1)" && { merged=1; break; }
    printf '%s' "$mergeerr" | grep -qi 'already merged' && { merged=1; say "PR #$pr was already merged out-of-band — treating as done."; break; }
    sleep 4
  done
  [ "$merged" = 1 ] || { [ "$_mlk" = 1 ] && flock -u 9 2>/dev/null; say "merge of PR #$pr failed after retries — gh said: ${mergeerr:-<no output>}"; return 1; }
  git checkout -f main >/dev/null 2>&1 && git pull --ff-only >/dev/null 2>&1 || true
  # delete the merged feature branch when safe: squash-merged via PR, now on main, clean tree
  if [ -n "$feat" ] && [ "$feat" != main ] && [ "$feat" != master ] && [ -z "$(git status --porcelain)" ]; then
    git branch -D "$feat" >/dev/null 2>&1 && say "deleted merged branch '$feat' (local; remote removed by --delete-branch)."
  fi
  # item 3: this land passed the tentative gate → the NEW main tip is GREEN. Record it as last-green and clear
  # any RED-main flag — if we were the fixer, main is healthy again and the standby workers may resume.
  local _newmain; _newmain="$(git fetch -q origin main 2>/dev/null; git rev-parse origin/main 2>/dev/null)"
  _swarm green-set "$_newmain"; _swarm main-red clear
  # item 8: broadcast "main advanced → <sha>" on the bus — the one safe pub/sub use. A DETERMINISTIC notice
  # (not agents reasoning over the bus) that other flows are now behind main. Consumption is deliberately left
  # to the merge queue's rebase-and-re-gate at land time: rebasing a worktree earlier, before its own gate,
  # would run the gate on a main-merged tree and so BYPASS the RED-main breaker (item 3), which must see the
  # break at the tentative gate. So this stays a signal (observability + a hook) — correctness is the queue's.
  _swarm post "${SWARM_WORKER:-w?}" main-adv "main advanced → ${_newmain:0:12}" ""
  [ "$_mlk" = 1 ] && flock -u 9 2>/dev/null   # release the swarm merge queue
  return 0
}

# Scan the just-merged GREEN build's CI log for the warnings/deprecations the gate let through
# (SecretsUsedInArgOrEnv, deprecated APIs, peer-dep/engine mismatches, lint noise) and curate the
# NEW ones into ROADMAP.md so the loop drives the build to WARNING-FREE. Cheap + bounded + fail-open:
# a mechanical grep gates the model (a clean OR unchanged build spends nothing), one capped agent
# pass curates + dedups, raw lines are remembered so the same warning is never re-queued, and every
# step degrades to a no-op on error — it can neither block nor rathole the loop.
harvest_warnings(){
  local id="$1" log=".opencode/ci-build.log" seen=".opencode/.harvested-warnings"
  command -v gh >/dev/null 2>&1 || return 0
  mkdir -p .opencode; : >"$log"
  timeout "${HARVEST_FETCH_TIMEOUT:-90}" gh run view "$id" --log >"$log" 2>/dev/null \
    || gh run view "$id" --log-failed >"$log" 2>/dev/null || true
  [ -s "$log" ] || { say "harvest: no build log for run $id — skipping."; return 0; }
  local cand
  cand="$(sed -E 's/\x1b\[[0-9;]*m//g; s/\t/ /g; s/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //g' "$log" \
    | grep -iE 'warn(ing)?|deprecat|SecretsUsedInArgOrEnv|EBADENGINE|peer dep' \
    | grep -ivE '0 warnings| 0 warning|no warnings|--no-warnings|npm warn cleanup' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | sort -u | head -n "${HARVEST_MAX:-15}")"
  [ -n "$cand" ] || { say "build clean — no warnings to harvest."; return 0; }
  touch "$seen"
  local fresh   # drop warnings already harvested; grep -v exits 1 when ALL are filtered, so guard on seen size
  if [ -s "$seen" ]; then fresh="$(printf '%s\n' "$cand" | grep -vxFf "$seen" 2>/dev/null)"; else fresh="$cand"; fi
  [ -n "$fresh" ] || { say "harvest: build warnings unchanged since last build — already queued."; return 0; }
  if ! command -v opencode >/dev/null 2>&1; then
    say "opencode absent — can't curate warnings."; printf '%s\n' "$cand" >>"$seen"; return 0; fi
  say "harvesting $(printf '%s\n' "$fresh" | grep -c .) new build warning(s) -> ROADMAP"
  local items
  items="$(timeout "${HARVEST_TIMEOUT:-180}" opencode run --agent "${AGENT:-orchestrator}" "These warning/deprecation lines are from the LATEST GREEN container build of THIS repo — they did NOT fail the gate, but a professional build must be WARNING-FREE. Read ROADMAP.md first and SKIP anything already listed unchecked. Cross-check the repo, collapse duplicates/transients/non-actionable noise, and for each REAL, fixable warning emit ONE GitHub-Markdown task line and NOTHING else: '- [ ] fix(build): <specific action that removes the warning> (warn: <short cite>)'. If none are real and actionable, output nothing.

$fresh" 2>/dev/null)"
  items="$(printf '%s\n' "$items" | grep -E '^- \[ \] ')"
  if [ -n "$items" ]; then
    [ -f ROADMAP.md ] || printf '# Roadmap\n\n## Next\n' > ROADMAP.md
    printf '\n### From build-warning harvest (%s)\n%s\n' "$(date -u +%F)" "$items" >> ROADMAP.md
    say "queued $(printf '%s\n' "$items" | grep -c '^- \[ \] ') build-warning fix(es) to ROADMAP — the loop will clear them."
  else
    say "harvest: no actionable warnings after curation."
  fi
  printf '%s\n' "$cand" >>"$seen"; sort -u "$seen" -o "$seen"   # never re-curate the same raw warning
}

preflight
hermes_notify "▶ autorun started on $(branch) (self-merge=$AUTOMERGE deploy=$DEPLOY features=$([ "$MAX_FEATURES" = 0 ] && echo ∞ || echo "$MAX_FEATURES"))"
features=0; fixes=0; plans=0; conflicts=0; lap=0; atlas_since=0
RUN_ID="$(date +%Y%m%d-%H%M%S)"; RUN_T0=$(date +%s); export RUN_ID   # tags every metrics row so stats are filterable PER RUN
mkdir -p .opencode 2>/dev/null; write_state startup   # heartbeat (pid) so a FOREGROUND autorun is visible to `ace loop status` + the digest, not just the systemd service
metric "run_start,,$(orch_provider 2>/dev/null) gate=${MERGE_GATE:-remote},0,0,0,0"
kanban_sync || true   # opt-in (HERMES_KANBAN=1): mirror the initial ROADMAP to a chat-visible kanban board
agent_state orchestrator   # dashboard: start with the planner lit (ace loop dash)
sync_objectives            # decompose any newly-added OBJECTIVES goal into ROADMAP tasks BEFORE working the queue
[ "${LOOP_SYNC_ONLY:-0}" = 1 ] && { say "plan-only sync done — exiting."; write_run_summary 2>/dev/null || true; exit 0; }
while :; do
  # janitor: reconcile drift + reclaim disk — git main↔origin sync, gitnexus stale branch-graph prune
  # + re-analyze, opencode DB bound, podman dangling prune, lessons.md compaction. Throttled to every
  # JANITOR_EVERY laps (housekeeping, not correctness — every single lap is pure overhead).
  # Falls back to a bare podman prune if the ace CLI isn't on PATH.
  lap=$((lap+1))
  if [ $(( (lap-1) % ${JANITOR_EVERY:-3} )) -eq 0 ]; then
    _jt=$(date +%s)
    if command -v ace >/dev/null 2>&1; then ace consistency fix </dev/null >/dev/null 2>&1 || true
    elif command -v podman >/dev/null 2>&1; then podman image prune -f >/dev/null 2>&1 || true; fi
    # local↔remote branch sync: drop stale tracking refs + delete LOCAL branches already merged
    # into origin/<default> (their remote was --delete-branch'd on merge) so `git branch` stays clean.
    { _def="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's,^origin/,,')"; _def="${_def:-main}"
      git fetch -q --prune origin 2>/dev/null; _cur="$(branch 2>/dev/null)"
      for _b in $(git branch --merged "origin/$_def" 2>/dev/null | tr -d ' *' | grep -vE "^(main|master|${_cur})$"); do
        git branch -D "$_b" >/dev/null 2>&1 || true; done; } || true
    compact_lessons   # keep .opencode/lessons.md from bloating every agent prompt
    phase_metric janitor "lap$lap" $(( $(date +%s) - _jt )) 0
  fi
  # --- mergeability gate: per MERGE_GATE, the authority is remote (GitHub Actions) or local (./ci.sh --container) ---
  id=""; run_ok=1; LOCAL_VOUCHED=0; _both_local_red=0; _gt=$(date +%s); agent_state verifier
  CI_STATE=running; write_state gate   # dash chip: gate is now running
  # merge_gate=both: the LOCAL ./ci.sh --container gate is a PREREQUISITE that must be GREEN before we even
  # check the remote half. We deliberately do NOT set LOCAL_VOUCHED here — the remote GitHub Actions checks
  # still gate the merge (merge_if_ready enforces them). If the local half is RED, skip the remote watch and
  # go straight to the fix path. Fail-closed: a green here is necessary but NOT sufficient to merge.
  if [ "${MERGE_GATE:-remote}" = both ]; then
    if { [ "$(branch)" = main ] || [ "$(branch)" = master ]; } && [ -z "$(gh pr view --json number -q .number 2>/dev/null)" ]; then
      : # on main with no open PR — nothing to gate; the remote branch below no-ops too
    elif [ "$(gh pr view --json mergeable -q .mergeable 2>/dev/null)" = CONFLICTING ]; then
      : # conflicting PR — let the remote branch's conflict handler resolve it first
    else
      cstate="$(git rev-parse HEAD 2>/dev/null):$(git status --porcelain 2>/dev/null | sha1sum | cut -c1-12)"
      if [ "$(cat .opencode/.container-green 2>/dev/null)" = "$cstate" ]; then
        say "merge_gate=both: local ./ci.sh --container already GREEN for this tree (cached); remote Actions must also pass."
      elif say "merge_gate=both: running ./ci.sh --container (local half of the gate)…" && timeout "${LOCAL_CI_TIMEOUT:-1800}" ./ci.sh --container > .opencode/ci-failure.log 2>&1; then
        mkdir -p .opencode; printf '%s\n' "$cstate" > .opencode/.container-green 2>/dev/null || true
        say "merge_gate=both: local container gate GREEN; now requiring remote GitHub Actions green too."
      else
        say "merge_gate=both: local container gate RED — fixing locally before the remote half (.opencode/ci-failure.log)."
        run_ok=1; _both_local_red=1
      fi
    fi
  fi
  if [ "$_both_local_red" = 1 ]; then
    : # merge_gate=both, local half RED: run_ok=1 drives the fix path; don't watch remote Actions this lap
  elif [ "${MERGE_GATE:-remote}" = local ]; then
    # POLICY merge_gate=local: the local VPS-parity gate is the merge authority — don't wait on / gate by
    # remote Actions (reuses the LOCAL_VOUCHED admin-merge path). A conflicting PR still can't merge — resolve first.
    if [ "$(gh pr view --json mergeable -q .mergeable 2>/dev/null)" = CONFLICTING ]; then
      conflicts=$((conflicts+1))
      if [ "$RESOLVE_CONFLICTS" = 1 ] && [ "$conflicts" -le "$MAX_CONFLICT" ]; then
        say "PR for $(branch) CONFLICTS — resolving (attempt #$conflicts/$MAX_CONFLICT)…"
        agent_state conflict; drive "resolve conflicts (#$conflicts)" "$RESOLVE_INSTR" || { say "conflict resolution errored — stopping for review."; break; }
        continue
      fi
      say "PR for $(branch) CONFLICTS and auto-resolve is off/exhausted — resolve manually or re-plan. Stopping."; break
    fi
    if { [ "$(branch)" = main ] || [ "$(branch)" = master ]; } && [ -z "$(gh pr view --json number -q .number 2>/dev/null)" ]; then
      say "on main with no open PR — nothing to gate."; run_ok=0
    else
      cstate="$(git rev-parse HEAD 2>/dev/null):$(git status --porcelain 2>/dev/null | sha1sum | cut -c1-12)"
      if [ "$(cat .opencode/.container-green 2>/dev/null)" = "$cstate" ]; then
        say "merge_gate=local: container gate already GREEN for this tree (cached)."; run_ok=0; LOCAL_VOUCHED=1
      else
        say "merge_gate=local: running ./ci.sh --container as the merge authority…"
        if timeout "${LOCAL_CI_TIMEOUT:-1800}" ./ci.sh --container > .opencode/ci-failure.log 2>&1; then
          mkdir -p .opencode; printf '%s\n' "$cstate" > .opencode/.container-green 2>/dev/null || true
          say "local container gate GREEN — merging on its authority."; run_ok=0; LOCAL_VOUCHED=1
        else say "local container gate RED — entering the fix path (.opencode/ci-failure.log)."; run_ok=1; fi
      fi
    fi
  else
  say "waiting for a CI run on $(branch) …"
  id=""; for _ in $(seq 1 60); do id="$(latest_run)"; [ -n "$id" ] && break; sleep 5; done
  if [ -z "$id" ]; then
    if [ "$(gh pr view --json mergeable -q .mergeable 2>/dev/null)" = CONFLICTING ]; then
      conflicts=$((conflicts+1))
      if [ "$RESOLVE_CONFLICTS" = 1 ] && [ "$conflicts" -le "$MAX_CONFLICT" ]; then
        say "PR for $(branch) CONFLICTS (GitHub runs no CI on a conflicting PR) — resolving (attempt #$conflicts/$MAX_CONFLICT)…"
        agent_state conflict; drive "resolve conflicts (#$conflicts)" "$RESOLVE_INSTR" || { say "conflict resolution errored — stopping for review."; break; }
        continue
      fi
      say "PR for $(branch) CONFLICTS with main and auto-resolve is off/exhausted — resolve manually or re-plan. Stopping."
    else say "no CI run found — push the branch / open a PR first. Stopping."; fi
    break
  fi
  # On main with no open PR, nothing here can merge/deploy — don't burn minutes (and Actions quota)
  # watching a redundant post-merge run; treat as passed and go straight to the next item.
  if { [ "$(branch)" = main ] || [ "$(branch)" = master ]; } && [ -z "$(gh pr view --json number -q .number 2>/dev/null)" ]; then
    say "on main with no open PR — skipping redundant CI watch."; run_ok=0
  else
    say "watching run $id …"
    if gh run watch "$id" --exit-status >/dev/null 2>&1; then run_ok=0; else run_ok=1; fi
  fi
  # Actions BLOCKED (billing/spend cap or infra outage): the run is "failure" but executed NO jobs, so
  # no code fix applies. If enabled, let a GREEN local VPS-parity gate (./ci.sh --container — the SAME
  # Containerfile CI runs) stand in for the blocked remote check; the green path then merges via
  # LOCAL_VOUCHED. Fail-closed: only triggers on a real block + a real local green.
  if [ "$run_ok" -ne 0 ] && [ "$LOCAL_CI_FALLBACK" = 1 ] && [ "${MERGE_GATE:-remote}" != both ] && ci_blocked "$id"; then
    # NOTE: merge_gate=both is excluded here on purpose — 'both' REQUIRES a real remote-Actions pass, so a
    # blocked Actions run must never be vouched-through on the local gate alone (that would defeat 'both').
    say "run $id is conclusion=failure but executed 0 jobs — Actions is BLOCKED (billing/spend cap or infra), not a code RED."
    # Skip the (slow) container rebuild if this EXACT tree (HEAD + working-tree state) already passed it
    # — e.g. the pre-push hook or a prior fallback lap just built the same SHA. Stamped on every GREEN.
    cstate="$(git rev-parse HEAD 2>/dev/null):$(git status --porcelain 2>/dev/null | sha1sum | cut -c1-12)"
    if [ -n "${cstate%%:*}" ] && [ "$(cat .opencode/.container-green 2>/dev/null)" = "$cstate" ]; then
      say "container gate already GREEN for this exact tree (cached) — skipping the rebuild."; run_ok=0; LOCAL_VOUCHED=1
    else
      say "running the local VPS-parity gate (./ci.sh --container) as the authority…"
      if timeout "${LOCAL_CI_TIMEOUT:-1800}" ./ci.sh --container; then
        mkdir -p .opencode; printf '%s\n' "$cstate" > .opencode/.container-green 2>/dev/null || true
        say "local container gate GREEN — accepting it as the pass while remote CI is blocked."; run_ok=0; LOCAL_VOUCHED=1
      else say "local container gate RED too — this is a REAL failure; entering the fix path."; fi
    fi
  fi
  fi
  phase_metric gate "${MERGE_GATE:-remote}$([ "$LOCAL_VOUCHED" = 1 ] && printf ':vouched')${id:+ run$id}" $(( $(date +%s) - _gt )) "$run_ok"
  [ "$run_ok" = 0 ] && CI_STATE=green || CI_STATE=red; write_state gate   # dash chip: authoritative gate verdict for this lap
  # Actions BLOCKED (run failed having executed 0 jobs) but no local fallback enabled → it's not a code RED,
  # so DON'T enter the fix loop and re-check it every lap. Stop once with the fix options.
  if [ -n "$id" ] && [ "$run_ok" -ne 0 ] && { [ "${LOCAL_CI_FALLBACK:-0}" != 1 ] || [ "${MERGE_GATE:-remote}" = both ]; } && ci_blocked "$id"; then
    say "run $id: conclusion=failure but executed 0 jobs — Actions is BLOCKED (billing/spend cap), not a code RED. Not re-checking."
    if [ "${MERGE_GATE:-remote}" = both ]; then say "  merge_gate=both requires a real Actions pass — not vouching locally. Fix the Actions block (raise the spending limit), or switch to merge_gate=local. Stopping."
    else say "  fix one of: raise the Actions spending limit · set LOCAL_CI_FALLBACK=1 (vouch via local ./ci.sh --container) · set merge_gate=local. Stopping."; fi
    break
  fi
  if [ "$run_ok" -eq 0 ]; then
    if [ "$LOCAL_VOUCHED" = 1 ]; then say "local container gate GREEN${id:+ (run $id)} — proceeding ($([ "${MERGE_GATE:-remote}" = local ] && echo 'merge_gate=local' || echo 'remote CI blocked'))"; else say "CI GREEN (run $id)"; fi; fixes=0
    if [ "$AUTOMERGE" = 1 ] || [ "${MERGE_APPROVAL:-}" = hermes ]; then
      # MERGE_APPROVAL=hermes: ask in chat before each merge (human-in-the-loop; no blind auto-merge).
      if [ "${MERGE_APPROVAL:-}" = hermes ]; then
        request_approval "merge PR on $(branch)" "$(gh pr view --json title,url -q '.title + " — " + .url' 2>/dev/null || branch)"; _ra=$?
        if [ "$_ra" = 2 ]; then say "MERGE_APPROVAL=hermes but no chat channel — leaving the PR open for manual review. Stopping."; break
        elif [ "$_ra" != 0 ]; then say "merge not approved in chat — leaving the PR open. Stopping."; break; fi
      fi
      _mt=$(date +%s); merge_if_ready; mrc=$?; phase_metric merge "$(branch)" $(( $(date +%s) - _mt )) "$mrc"
      if [ "$mrc" = 0 ]; then
        conflicts=0
        hermes_notify "✅ merged to main$([ "${LOCAL_VOUCHED:-0}" = 1 ] && printf ' — local gate (Actions blocked)')"
        [ -x scripts/graph-refresh.sh ] && bash scripts/graph-refresh.sh </dev/null >/dev/null 2>&1 || true   # keep main's map fresh
        atlas_since=$((atlas_since+1))   # section G: refresh the human Architecture Atlas every MAP_EVERY merges (never per-commit; the generator's own SWARM_WORKER guard keeps worker worktrees a no-op)
        if [ -x scripts/atlas-refresh.sh ] && [ "$atlas_since" -ge "${MAP_EVERY:-3}" ]; then
          _at=$(date +%s); bash scripts/atlas-refresh.sh </dev/null >/dev/null 2>&1; _arc=$?
          phase_metric atlas "" $(( $(date +%s) - _at )) "$_arc"; atlas_since=0   # docs/atlas.md + README block ship with this merge
        fi
        [ "$HARVEST" = 1 ] && { harvest_warnings "$id" || true; }   # build warnings the gate let through -> ROADMAP
          kanban_sync || true   # reflect the merge on the chat-visible board (opt-in HERMES_KANBAN=1)
        if [ "$DEPLOY_KIND" != service ]; then
          say "deploy_kind=$DEPLOY_KIND — no per-merge VPS deploy ($([ "$DEPLOY_KIND" = artifact ] && echo 'binaries ship on a v* tag via the release job' || echo 'nothing deployable'))."
          [ "$DEPLOY" = 1 ] && say "⚠ DEPLOY=1 was requested but deploy_kind=$DEPLOY_KIND has no VPS service — DEPLOY is a no-op here (set deploy_kind=service for VPS deploys$([ "$DEPLOY_KIND" = artifact ] && echo "; artifacts ship via 'ace release --tag'"))."
        elif [ "$DEPLOY" = 1 ] && command -v ace >/dev/null 2>&1; then
          say "deploying merged main to the VPS"; hermes_notify "🚀 deploying merged main → VPS"
          # ACE_CONFIRM=1: the loop IS the authorized autonomous driver — clear the headless destructive-op
          # gate (ace:_gate_destructive), else a systemd/--yes run self-blocks the deploy and HALTS the loop.
          _dt=$(date +%s); ACE_CONFIRM=1 ace deploy; _drc=$?; phase_metric deploy "" $(( $(date +%s) - _dt )) "$_drc"
          if [ "$_drc" != 0 ]; then
            if [ "$STOP_ON_DEPLOY_FAIL" = 1 ]; then
              say "deploy/health-check FAILED — HALTING the loop so we don't build onto a broken live deploy (set STOP_ON_DEPLOY_FAIL=0 to keep going). See: ace logs"
              hermes_notify "⛔ deploy/health-check FAILED — loop HALTED (live deploy is broken; fix + \`ace resume\`)"
              break
            fi
            say "deploy/health-check failed — see: ace logs (STOP_ON_DEPLOY_FAIL=0 → continuing)"; hermes_notify "⚠ deploy/health-check FAILED — see: ace logs"
          fi
          if [ "$VERIFY" = 1 ]; then say "verifying live deployment (findings -> ROADMAP)"; _vt=$(date +%s); ACE_VERIFY_TRIAGE=auto ace verify; _vrc=$?; phase_metric verify "" $(( $(date +%s) - _vt )) "$_vrc"; [ "$_vrc" = 0 ] || say "verify step failed — see: ace logs"; fi
        else say "deploy: handled by CI's deploy job on push to main (it deploys AND health-checks; or set DEPLOY=1 + ace on PATH for loop-driven deploy)"; fi
      elif [ "$mrc" = 2 ]; then
        say "nothing to merge on this branch (already merged, or on main) — moving on to the next item."
        git checkout -f main >/dev/null 2>&1 && git pull --ff-only >/dev/null 2>&1 || true
      elif [ "$mrc" = 3 ]; then
        conflicts=$((conflicts+1))
        if [ "$RESOLVE_CONFLICTS" != 1 ] || [ "$conflicts" -gt "$MAX_CONFLICT" ]; then
          say "PR for $(branch) CONFLICTS and auto-resolve is off/exhausted ($((conflicts-1)) tries) — stopping for human review."; break; fi
        say "PR CONFLICTS with main — resolving while preserving both intents (attempt #$conflicts/$MAX_CONFLICT)…"
        agent_state conflict; drive "resolve conflicts (#$conflicts)" "$RESOLVE_INSTR" || { say "conflict resolution errored — stopping for review."; break; }
        say "resolution attempt #$conflicts done — re-checking CI + mergeability."; continue
      elif [ "$mrc" = 4 ]; then
        # item 3: main is RED on its OWN — NOT this branch's fault. Elect ONE fixer to repair main; everyone
        # else stands down until main is GREEN again (then rebases onto it via the merge queue). Prevents N
        # workers dogpiling a phantom "conflict" and colliding on the same repair.
        _rmrole="$(_swarm main-red elect "${SWARM_WORKER:-}")"
        if [ "$_rmrole" = fixer ]; then
          _swarm post "${SWARM_WORKER:-w?}" fixer "elected FIXER — repairing RED main" "$(branch)"
          conflicts=$((conflicts+1))
          if [ "$conflicts" -gt "$MAX_CONFLICT" ]; then say "main-repair attempts exhausted ($((conflicts-1))) — stopping for human review."; break; fi
          say "main is RED on its own — elected FIXER. Repairing from the failing build log (attempt #$conflicts/$MAX_CONFLICT)…"
          agent_state implementer; drive "repair RED main (#$conflicts)" "$MAINFIX_INSTR" || { say "main-repair errored — stopping for review."; break; }
          say "main-repair attempt #$conflicts done — re-checking."; continue
        else
          _swarm post "${SWARM_WORKER:-w?}" standby "standby — another worker is fixing RED main; holding $(branch)" "$(branch)"
          say "main is RED on its own and another worker is the FIXER — standing down; the swarm will rebase this branch onto main once it's GREEN."
          break
        fi
      else
        say "green run, but the PR isn't fully ready to merge (checks pending/failed) — stopping for your review."; break
      fi
    else
      # auto_merge OFF (profile auto_merge:false / AUTOMERGE=0): the documented contract is "opens a PR and
      # STOPS". Do NOT fall through to build the next feature on top of the un-merged branch — stop so the
      # human can review/merge the open PR. (Continuing would stack features on an unmerged branch.)
      say "gate GREEN + PR open on $(branch) — auto-merge is OFF, so stopping for your review (merge the PR, or re-run with AUTOMERGE=1 to self-merge)."
      hermes_notify "✅ PR ready for review on $(branch) — auto-merge off; loop stopping"
      break
    fi
    { [ "$MAX_FEATURES" != 0 ] && [ "$features" -ge "$MAX_FEATURES" ]; } && { say "feature cap ($MAX_FEATURES) reached — stopping."; break; }
    item="$(next_item)"
    if [ -z "$item" ]; then
      [ "$PLAN" = 1 ] || { say "ROADMAP empty and PLAN=0 — stopping."; break; }
      plans=$((plans+1))
      if [ "$plans" -gt "${MAX_PLANS:-5}" ]; then
        say "planned ${plans}x but ROADMAP still has no implementable item — stuck; stopping."
        [ "${AUTOMERGE:-0}" = 1 ] || say "  likely cause: auto-merge is OFF, so the chore/plan PR's tasks never land on this branch. Merge that PR, or re-run with AUTOMERGE=1."
        break
      fi
      [ "$plans" -gt 1 ] && say "ROADMAP still empty after planning (attempt $plans/${MAX_PLANS:-5})$([ "${AUTOMERGE:-0}" = 1 ] && echo '' || echo ' — is the chore/plan PR merged? auto-merge is off')."
      if [ "$SELF_IMPROVE" = 1 ]; then
        drive "plan / self-improve" "Read OBJECTIVES.md. If ANY objective is not done, pick the highest-priority one (or the next slice of the in-progress one) and break it into 3-7 concrete, independently-shippable tasks under '## Next' in ROADMAP.md, updating that objective's status. Prefer North-Star value (user-facing / revenue / decision-quality) over infra/meta; tag each task [value] or [infra]; never queue more than 2 infra tasks in a row. If EVERY objective is already done, instead propose ONE high-leverage self-improvement that best advances the system's end goal: \"$IMPROVE_GOAL\" — either deepen an existing portal section or build a new feature, whichever moves that goal most; justify the choice in one line, append 3-7 concrete tasks to ROADMAP.md, and log the initiative under a '## Self-improvement (loop)' heading in OBJECTIVES.md. Either way: branch chore/plan, commit ROADMAP.md + OBJECTIVES.md, open a PR into main. Do NOT implement features yet." || { say "plan step failed (opencode error / model not found?) — stopping for review."; break; }
      else
        drive "plan from OBJECTIVES.md" "Read OBJECTIVES.md. Pick the highest-priority objective that is NOT done (or the next slice of the in-progress one). Break it into 3-7 concrete, independently-shippable tasks and append them under '## Next' in ROADMAP.md. Prefer North-Star value (user-facing / revenue / decision-quality) over infra/meta; tag each task [value] or [infra]; never queue more than 2 infra tasks in a row. Update OBJECTIVES.md: set that objective's status to in-progress, check off any sub-goals already met, and note the slice being tackled. If ALL objectives are already done, do NOT invent work — leave a note and stop. Branch chore/plan, commit ROADMAP.md + OBJECTIVES.md, open a PR into main. Do NOT implement features yet." || { say "plan step failed (opencode error / model not found?) — stopping for review."; break; }
      fi
      continue
    fi
    agent_state implementer
    drive "implement: $item" "Implement the next roadmap item: \"$item\". Plan -> branch feat/<slug> -> implement to the Definition of Done with tests -> open a PR into main. In the SAME PR: check the item off in ROADMAP.md AND update its parent objective's progress in OBJECTIVES.md (tick sub-goals; bump status; mark the objective done when fully complete). NEVER merge your own PR." || { say "implement step failed (opencode error / model not found?) — stopping for review."; break; }
    plans=0; features=$((features+1)); continue
  else
    fixes=$((fixes+1))
    [ "$fixes" -gt "$MAX_FIX" ] && { say "MAX_FIX=$MAX_FIX reached without green — a human is needed. Stopping."; break; }
    say "CI RED${id:+ (run $id)} — fix attempt $fixes/$MAX_FIX"; hermes_notify "🔴 CI red on $(branch) — auto-fixing ($fixes/$MAX_FIX)"
    mkdir -p .opencode
    # remote gate: pull the failed-job log. local gate (MERGE_GATE=local, $id empty): ci-failure.log already holds ./ci.sh --container output.
    [ -n "$id" ] && { gh run view "$id" --log-failed > .opencode/ci-failure.log 2>&1 || gh run view "$id" --log > .opencode/ci-failure.log 2>&1; }
    # D2: reduce the raw log to its error signature before the fixer reads it, + dedupe across attempts so a
    # repeated failure nudges a DIFFERENT approach instead of silently re-pasting the same noise.
    ci_signature .opencode/ci-failure.log
    _sig_now=$(cksum < .opencode/ci-failure.log 2>/dev/null | awk '{print $1}')
    if [ -n "${_sig_prev:-}" ] && [ "${_sig_now:-x}" = "$_sig_prev" ]; then
      _dedupe="NOTE: this is the SAME failure signature as your previous attempt — that fix did NOT address the ROOT CAUSE. Do something DIFFERENT (deeper diagnosis, not a repeat or a band-aid). "
    else _dedupe=""; fi
    _sig_prev="$_sig_now"
    agent_state implementer
    drive "fix CI from logs" "${_dedupe}CI failed on branch $(branch). Read .opencode/ci-failure.log (already reduced to the failure signature), find the ROOT CAUSE (not a band-aid, not 'as any', not a skipped test), fix it properly via the full loop (impact -> implement -> verify -> both reviewers), and push. Do NOT merge." || { say "fix step failed (opencode error / model not found?) — stopping for review."; break; }
  fi
done
write_run_summary   # post-mortem → .opencode/run-summary.txt (this run's time-by-phase + slowest steps)
subagent_report     # per-subagent × worker tokens/cost from the opencode session DB → .opencode/token-report.md (falls back to token_report if the DB is unavailable)
command -v quality_record >/dev/null 2>&1 && quality_record retry "$RUN_ID" "$fixes"   # F4: this run's real CI-fix retry count (the "false economy" indicator) — the one quality signal the bash loop owns
command -v quality_report >/dev/null 2>&1 && quality_report   # F4: per-critic FP + retry + escaped-bug → .opencode/quality-report.md (leading quality indicators)
say "──────── run report ────────"
say "laps=$lap · features=$features · CI-fixes=$fixes · plans=$plans · conflicts=$conflicts · branch=$(branch)"
say "policy: merge_gate=${MERGE_GATE:-remote} · auto_merge=$AUTOMERGE · deploy_kind=${DEPLOY_KIND:-service}"
[ -f .opencode/metrics.csv ] && awk -F, -v r="$RUN_ID" 'NR>1 && $1==r && $4=="step"{a+=$8;b+=$9;n++} END{if(n)printf "metrics: %d agent-steps · ~%dm active-think · ~%dm builds  (full breakdown: .opencode/run-summary.txt · CSV: .opencode/metrics.csv)\n",n,a/60,b/60}' .opencode/metrics.csv | while read -r _l; do say "$_l"; done
say "────────────────────────────"
say "loop ended."; hermes_notify "🛑 autorun loop ended — features=$features fixes=$fixes laps=$lap"
