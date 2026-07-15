#!/usr/bin/env bash
# dash.sh — `ace loop dash`: a live full-screen TUI over the files the loop already writes
# (.opencode/loop-state.env · last-run.log · .opencode/.agents · metrics.csv). Truecolor when available,
# theme C_* otherwise. `--demo` plays a scripted cycle so you can see it without a live loop; the agent
# grid in a REAL run lights only what the bash loop can observe (orchestrator/implementer/verifier/conflict —
# the 4 critics run inside opencode). Watch a running loop in a second terminal/pane.

_dvis(){ local s; s="$(printf '%s' "$1" | sed $'s/\033\\[[0-9;:]*m//g')"; printf %s "${#s}"; }   # ANSI-stripped width
_drep(){ local i s=''; for ((i=0;i<${2:-0};i++)); do s+="$1"; done; printf %s "$s"; }
_dpad(){ local w="$1" s="$2" v; v="$(_dvis "$s")"; [ "$v" -ge "$w" ] && { printf '%s' "$s"; return; }; printf '%s%*s' "$s" "$((w-v))" ''; }
_dcen(){ local w="$1" s="$2" v l; v="$(_dvis "$s")"; [ "$v" -ge "$w" ] && { printf '%s' "$s"; return; }; l=$(((w-v)/2)); printf '%*s%s%*s' "$l" '' "$s" "$((w-v-l))" ''; }
# recursive process-tree kill. The loop's opencode is a grandchild via the `opencode … | tee` pipeline, and a
# bare SIGTERM to the loop is DEFERRED while it's blocked in that pipeline — so a signal to the loop pid alone
# won't stop opencode. Kill the whole TREE (opencode first) to actually take it down.
_dash_killtree(){ local p="$1" s="${2:-TERM}" k; [ -n "$p" ] || return 0; for k in $(pgrep -P "$p" 2>/dev/null); do _dash_killtree "$k" "$s"; done; kill -"$s" "$p" 2>/dev/null; }

loop_dash() {
  local demo=0 test=0
  { [ "${1:-}" = "--demo" ] || [ "${ACE_DEMO:-0}" = 1 ]; } && demo=1
  [ "${ACE_DASH_TEST:-0}" = 1 ] && test=1
  [ "$test" = 1 ] || [ -t 1 ] || { err "ace loop dash needs an interactive terminal (or ACE_DASH_TEST=1 for a one-frame render)."; return 1; }
  local proj; proj="$(config_get LOOP_PROJECT 2>/dev/null || true)"; [ -d "$proj/.opencode" ] 2>/dev/null || proj="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

  # ── palette: the mockup colors in truecolor, else the active theme's C_* ──
  local AC CR GO GN RD FGc MU DM RS
  if [ "${ACE_TC:-0}" = 1 ]; then
    AC="$(_fg 166 87 237)"; CR="$(_fg 204 39 46)"; GO="$(_fg 205 156 31)"; GN="$(_fg 57 158 67)"
    RD="$(_fg 194 23 37)"; FGc="$(_fg 215 213 231)"; MU="$(_fg 110 108 130)"; DM="$(_fg 64 62 84)"
  else
    AC="${C_VIOLET:-}"; CR="${C_RED:-}"; GO="${C_YELLOW:-}"; GN="${C_GREEN:-}"; RD="${C_RED:-}"; FGc=""; MU="${C_GREY:-}"; DM="${C_GREY:-}"
  fi
  RS="${C_RESET:-$'\033[0m'}"; local BD="${C_BOLD:-}"

  # ── agents (id|name|role|icon) + their live state ──
  local -a AGN=(
    "orchestrator|orchestrator|plans · delegates|✦" "implementer|implementer|builds to spec|▸"
    "test_engineer|test engineer|adversarial tests|▽" "verifier|verifier|ci.sh gate|▸"
    "reviewer|reviewer|logic & scope|▸"       "ux_reviewer|ux reviewer|looks & flow|▸"
    "standards|standards|best practices|▸"    "alignment|alignment|mission audit|▸"
    "conflict|conflict|merge reconciler|⚔" )
  declare -A AST; local a
  for a in orchestrator implementer test_engineer verifier reviewer ux_reviewer standards alignment conflict; do AST[$a]=idle; done
  AST[orchestrator]=active

  local ROWS COLS
  _dsz(){ ROWS=$(tput lines 2>/dev/null || echo 40); COLS=$(tput cols 2>/dev/null || echo 110)
          [ "$COLS" -lt 64 ] && COLS=64; [ "$ROWS" -lt 20 ] && ROWS=20; }
  _dsz
  local -a LOG=()
  local cyc=0 feat=0 fixes=0 plans=0 branch="—" ci="idle" ovr="deepseek" paused=0 logoff=0

  # ── colorize a raw log line by ACE marker ──
  _dcol(){ local t="$1" c="$FGc"
    case "$t" in
      *GREEN*|*PASS*|*" ✓"*|*merged*|*approved*|*"CI GREEN"*) c="$GN" ;;
      *RED*|*FAIL*|*" ✗"*|*failed*|*UNRESOLVABLE*) c="$RD" ;;
      *BLOCKED*|*blocked*|*WARN*|*warn*|*rathole*|*Stopping*) c="$GO" ;;
      *ORCHESTRATOR*|*"✦"*|*"⛧"*|*merge*|*deploy*|*autorun*) c="$AC" ;;
      *USER:*|*"⌨"*) c="$GO" ;;
    esac
    printf '%s%s%s' "$c" "$t" "$RS"; }
  _push(){ LOG+=("$(_dcol "$1")"); while [ "${#LOG[@]}" -gt 400 ]; do LOG=("${LOG[@]:1}"); done; }

  # ── pull live state from the loop's files (real mode) ──
  local _logsz=0
  _refresh(){
    local f="$proj/.opencode/loop-state.env" v
    if [ -f "$f" ]; then
      v="$(grep -E '^branch=' "$f" 2>/dev/null | cut -d= -f2-)"; branch="${v:-$branch}"
      v="$(grep -E '^features=' "$f" 2>/dev/null | cut -d= -f2-)"; feat="${v:-0}"
      v="$(grep -E '^fixes=' "$f" 2>/dev/null | cut -d= -f2-)"; fixes="${v:-0}"
      v="$(grep -E '^plans=' "$f" 2>/dev/null | cut -d= -f2-)"; plans="${v:-0}"
      v="$(grep -E '^overseer=' "$f" 2>/dev/null | cut -d= -f2-)"; ovr="${v:-$ovr}"
      v="$(grep -E '^ci=' "$f" 2>/dev/null | cut -d= -f2-)"; ci="${v:-$ci}"
    fi
    local af="$proj/.opencode/.agents" kv
    [ -f "$af" ] && for kv in $(tail -1 "$af" 2>/dev/null); do [ -n "${AST[${kv%%:*}]+x}" ] && AST[${kv%%:*}]="${kv#*:}"; done
    # tail new lines from last-run.log
    local lf="$proj/.opencode/last-run.log" sz line
    if [ -f "$lf" ]; then
      sz=$(wc -l <"$lf" 2>/dev/null || echo 0)
      if [ "$sz" -gt "$_logsz" ]; then
        while IFS= read -r line; do [ -n "$line" ] && _push "$line"; done < <(tail -n "$((sz-_logsz))" "$lf" 2>/dev/null)
        _logsz=$sz
      fi
    fi
  }

  # ── demo: a scripted cycle mirroring the loop (orchestrator → implement → verify → critics → merge) ──
  local _step=0
  local -a DEMO=(
    "cyc"  "set|orchestrator:active" "accent|✦ ORCHESTRATOR: reading OBJECTIVES.md …"
    "info|✦ next objective: implement trade-signal router"  "info|✦ decompose → 3 roadmap items · branch feat/signal-router"
    "set|orchestrator:done implementer:active" "info|▸ IMPLEMENTER: mapping dependency graph (gitnexus)…"
    "gold|⌨ USER: build a real-time websocket dashboard for trade signals"  "accent|◆ ACE: starting with the ws client + signal schema."
    "ok|▸ implementation complete · 3 files · +147 / -28"
    "set|implementer:done verifier:active" "info|▸ VERIFIER: running ./ci.sh --container …"
    "err|▸ ci.sh — TEST FAIL (test/signal-router.test.ts:142)"  "warn|▸ self-heal: gh run --log-failed → missing async mock"
    "ok|▸ re-run ./ci.sh — ALL GREEN ✓"
    "set|verifier:done reviewer:active" "ok|▸ reviewer: approved · no integration gaps"
    "set|reviewer:done ux_reviewer:active" "ok|▸ ux: loading · empty · error · reconnect — all present"
    "set|ux_reviewer:done standards:active" "ok|▸ standards: conforms to STANDARDS.md"
    "set|standards:done alignment:active" "ok|▸ alignment: on-mission · audience & values upheld"
    "set|alignment:done conflict:idle" "sep|☩ all gates pass · merging ☩"
    "feat|⛧ merge (squash) · branch deleted · pull main"
    "reset" "muted|next objective ready on roadmap" )

  _demo_step(){
    [ "$paused" = 1 ] && return
    local e act pay kv aa; e="${DEMO[$_step]}"; act="${e%%|*}"; pay="${e#*|}"   # split: same-line `local a=.. b="${a}"` doesn't see a
    case "$act" in
      cyc)   cyc=$((cyc+1)) ;;
      reset) for aa in "${!AST[@]}"; do AST[$aa]=idle; done; AST[orchestrator]=active ;;
      feat)  feat=$((feat+1)); _push "$pay" ;;
      set)   for kv in $pay; do [ -n "${AST[${kv%%:*}]+x}" ] && AST[${kv%%:*}]="${kv#*:}"; done ;;
      *)     [ "$act" != "$e" ] && _push "$pay" ;;   # any "class|text" line
    esac
    _step=$(( (_step+1) % ${#DEMO[@]} ))
  }

  # ── render one full frame into a buffer, then emit atomically ──
  local WORD1=' █████╗  ██████╗███████╗' WORD2='██╔══██╗██╔════╝██╔════╝' WORD3='███████║██║     █████╗  '
  local WORD4='██╔══██║██║     ██╔══╝  ' WORD5='██║  ██║╚██████╗███████╗' WORD6='╚═╝  ╚═╝ ╚═════╝╚══════╝'
  _at(){ printf '\033[%d;1H\033[2K%s' "$1" "$2"; }
  _chip(){ printf '%s●%s %s%s%s %s%s%s' "$2" "$RS" "$MU" "$3" "$RS" "$FGc" "$4" "$RS"; }

  _render(){
    local W=$((COLS-2)) buf="" r
    buf+="$(_at 1  "  ${AC}${WORD1}${RS}")"
    buf+="$(_at 2  "  ${AC}${WORD2}${RS}")"
    buf+="$(_at 3  "  ${AC}${WORD3}${RS}")"
    buf+="$(_at 4  "  ${AC}${WORD4}${RS}")"
    buf+="$(_at 5  "  ${AC}${WORD5}${RS}")"
    buf+="$(_at 6  "  ${AC}${WORD6}${RS}")"
    buf+="$(_at 7  "$(_dcen "$COLS" "${MU}⛧  Agentic Coding Environment  ⛧${RS}")")"
    buf+="$(_at 8  "$(_dcen "$COLS" "${DM}the forge never sleeps · the loop is ${GO}eternal${RS}")")"
    # status chips
    local cis="$GN"; case "$ci" in *fail*|*RED*|red) cis="$RD";; running) cis="$GO";; idle) cis="$MU";; esac
    local sb; sb=" $(_chip d "$AC" loop "#$cyc")    $(_chip d "$cis" ci "$ci")    $(_chip d "$GO" repo "$branch")    $(_chip d "$GN" overseer "$ovr")    $(_chip d "$AC" features "$feat/∞")    $(_chip d "$GO" fixes "$fixes")"
    buf+="$(_at 9 "$sb")"
    # agent grid: 4 per row × 2 rows, 3 lines each (top border · name · role-in-bottom-border)
    local bw=$(( (W-3)/4 )) gi=0 top=10
    local rowset
    for rowset in "0 1 2 3" "4 5 6 7"; do
      local L1=" " L2=" " L3=" " idx
      for idx in $rowset; do
        IFS='|' read -r id name role icon <<<"${AGN[$idx]}"
        local st="${AST[$id]:-idle}" col="$DM"
        case "$st" in active) col="$AC";; done) col="$GN";; fail) col="$RD";; esac
        local inner=$((bw-2)) nm="$icon $name" rl="$role"
        nm="${nm:0:$inner}"; rl="${rl:0:$((inner-3))}"
        L1+="${col}╭$(_drep ─ "$inner")╮${RS} "
        L2+="${col}│${RS}$(_dpad "$inner" " ${col}${nm}${RS}")${col}│${RS} "
        L3+="${col}╰─ ${MU}${rl}${RS} ${col}$(_drep ─ "$((inner-3-${#rl}>0?inner-3-${#rl}:0))")╯${RS} "
      done
      buf+="$(_at "$top" "$L1")"; buf+="$(_at "$((top+1))" "$L2")"; buf+="$(_at "$((top+2))" "$L3")"
      top=$((top+3))
    done
    # log pane
    local lh_row=$((top))
    buf+="$(_at "$lh_row" "  ${MU}⛧  auto-logs  ⛧$(_drep ' ' 2)${DM}$(date +%H:%M:%S)${RS}")"
    local LOG_TOP=$((lh_row+1)) LOG_BOT=$((ROWS-1)) lh n start i
    lh=$((LOG_BOT-LOG_TOP+1)); [ "$lh" -lt 1 ] && lh=1
    n=${#LOG[@]}; start=$((n-lh)); [ "$start" -lt 0 ] && start=0
    for ((i=0;i<lh;i++)); do
      local ln=""; [ $((start+i)) -lt "$n" ] && ln="${LOG[$((start+i))]}"
      buf+="$(_at "$((LOG_TOP+i))" "  $ln")"
    done
    # footer
    local pz="${CR}◆${RS}"; [ "$paused" = 1 ] && pz="${GO}❚❚${RS}"
    buf+="$(_at "$ROWS" "  $pz ${MU}$([ "$paused" = 1 ] && echo 'paused ' || echo 'running')${RS}   ${AC}cycle #$cyc${RS}   ${DM}q quit · p pause · ${CR}x KILL ACE+quit${RS}")"
    printf '\033[?2026h%b\033[?2026l' "$buf"
  }

  # ── one-frame test render (no alt screen, no loop) ──
  if [ "$test" = 1 ]; then local k
    if [ "$demo" = 1 ]; then for ((k=0;k<24;k++)); do _demo_step; done; else _refresh; fi
    _dsz; printf '\033[2J'; _render; printf '\n'; return 0; fi

  # ── interactive ──
  _drestore(){ printf '\033[r\033[?25h\033[?1049l'; stty echo 2>/dev/null || true; trap - INT TERM EXIT WINCH; }
  trap '_drestore; return 0 2>/dev/null || exit 0' INT TERM EXIT
  trap '_dsz' WINCH
  printf '\033[?1049h\033[?25l\033[2J'; stty -echo 2>/dev/null || true
  [ "$demo" = 1 ] && _push "⛧ demo mode — scripted cycle (not a live loop). q to quit." \
                  || _push "⛧ watching ${proj##*/} — start a loop with: ace autorun --yes"
  local frame=0 key
  while :; do
    _dsz
    if [ "$demo" = 1 ]; then [ $((frame % 5)) -eq 0 ] && _demo_step; else _refresh; fi
    _render
    if read -rsn1 -t 0.16 key 2>/dev/null; then
      case "$key" in
        q|Q) break ;;
        p|P) paused=$((1-paused)) ;;
        x|X) # KILL ACE — stop the loop + its opencode subtree, then quit. A bare SIGTERM to the loop does NOT
             # cascade (it's blocked in the `opencode … | tee` pipeline, so its cleanup trap is deferred), so we
             # kill the process TREES directly — opencode (.oppid) FIRST to stop spend, then the loop.
             printf '\n  %s⛔ kill the loop + opencode and quit? press y%s' "${CR}" "${RS}"; local yn lp op
             read -rsn1 yn 2>/dev/null || yn=""
             case "$yn" in y|Y)
               systemctl --user stop ace-loop.service 2>/dev/null || true   # service loop: systemd force-stops the cgroup
               op="$(cat "$proj/.opencode/.oppid" 2>/dev/null)"; lp="$(sed -n 's/^pid=//p' "$proj/.opencode/loop-state.env" 2>/dev/null | head -1)"
               _dash_killtree "$op" TERM; _dash_killtree "$lp" TERM; sleep 2
               _dash_killtree "$op" KILL; _dash_killtree "$lp" KILL
               break ;;
             esac ;;
      esac
    fi
    frame=$((frame+1))
  done
  _drestore
}
