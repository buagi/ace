#!/usr/bin/env bash
# swarm-dash.sh — the FORGE: a live, unified terminal cockpit for the ACE swarm.
#
# One screen for the whole run (ace + auto-loop + swarm):
#   • header + status bar (run · workers · roadmap · peak · pause/drain)
#   • a COORDINATOR line, then a FULL-BORDERED box per live worker showing its feature,
#     the workflow pipeline (PLAN▸BUILD▸GATE▸REVIEW▸MERGE with the current stage lit),
#     wall/budget/lease, and its live loop feed tailed inline
#   • a titled, level-coloured event BUS
# Two layouts, toggle with 'g': STACKED (tall boxes, full feeds) and PANEL (a grid of
# worker cells side-by-side — the "4 terminals" view, no tmux needed).
#
# RESILIENT: workers are sourced from status/*.stat (+ wN.log mtime for liveness), so a
# lagging/rebuilding state.json can NEVER blank the workers out. Reads only the shared
# store, so it attaches to a detached run and N viewers can watch at once.
# Keys: p pause · r resume · d drain · k kill wN · x KILL ACE+quit (whole swarm) · g grid/stacked · +/- feed size · q quit
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/swarm.sh" 2>/dev/null || true

ESC=$'\033'
c_reset="${ESC}[0m"; bold="${ESC}[1m"
c_accent="${ESC}[38;2;176;114;230m"   # purple
c_crimson="${ESC}[38;2;208;80;70m"
c_gold="${ESC}[38;2;212;160;74m"
c_green="${ESC}[38;2;63;185;106m"
c_red="${ESC}[38;2;208;69;59m"
c_fg="${ESC}[38;2;216;207;230m"
c_muted="${ESC}[38;2;122;110;142m"
c_border="${ESC}[38;2;92;80;118m"
c_dim="${ESC}[38;2;70;60;90m"
c_title="${ESC}[38;2;226;220;240m"

_lvlc(){ case "$1" in ok|done) printf '%s' "$c_green";; err|error) printf '%s' "$c_red";; warn|waiting|blocked) printf '%s' "$c_gold";;
  accent|claimed|merging) printf '%s' "$c_accent";; crimson|conflict) printf '%s' "$c_crimson";; muted) printf '%s' "$c_muted";; *) printf '%s' "$c_fg";; esac; }

# visible width of a string (ANSI stripped) — for border padding
_vw(){ local s; s="$(printf '%s' "$1" | sed "s/$ESC\\[[0-9;]*m//g")"; printf '%s' "${#s}"; }
_dashes(){ local i=0 n="${1:-0}"; while [ "$i" -lt "$n" ]; do printf '─'; i=$((i+1)); done; }
_spaces(){ local i=0 n="${1:-0}"; while [ "$i" -lt "$n" ]; do printf ' '; i=$((i+1)); done; }

# phase → active stage index (0 plan · 1 build · 2 gate · 3 review · 4 merge · 5 done)
_stage_idx(){ case "$1" in
  boot|preflight|plan|"") echo 0;; implement|write|scribe) echo 1;; verify|fix) echo 2;;
  review|re-review) echo 3;; resolve|conflict) echo 3;; merge|merging) echo 4;; done) echo 5;; *) echo 1;; esac; }
# human label for the phase, shown next to the pipeline so the stage is unmistakable
_phase_label(){ case "$1" in
  boot|preflight) echo "preflight";; plan|"") echo "planning";; implement|write) echo "implementing";;
  scribe) echo "scribing";; verify) echo "gating (ci)";; fix) echo "fixing";; review|re-review) echo "review";;
  resolve|conflict) echo "reconciling";; merge|merging) echo "merging";; done) echo "done";; *) echo "$1";; esac; }

_pipeline(){ # active_idx conflict?  → "PLAN ✓ · ▸BUILD◂ · GATE · REVIEW · MERGE"  (current stage lit)
  local a="$1" cf="${2:-}" i=0 out="" name col names=(PLAN BUILD GATE REVIEW MERGE)
  for name in "${names[@]}"; do
    [ "$i" -gt 0 ] && out+="${c_dim} · ${c_reset}"
    if   [ "$i" -lt "$a" ]; then out+="${c_green}${name} ✓${c_reset}"
    elif [ "$i" -eq "$a" ]; then col="$c_accent$bold"; [ "$name" = REVIEW ] && [ -n "$cf" ] && { name=RECONCILE; col="$c_crimson$bold"; }
                                 out+="${col}▸${name}◂${c_reset}"
    else out+="${c_dim}${name}${c_reset}"; fi
    i=$((i+1))
  done
  printf '%s' "$out"
}

# ── data helpers (all fail-soft on missing/corrupt files) ──────────────────────
_dash_roadmap(){ local rm="$REPO/ROADMAP.md" src d t
  # LIVE done count: workers merge to origin/$MAIN and keep it FETCHED FRESH in the repo's shared ref store
  # (a worktree fetch updates refs/remotes for the whole repo), so origin/$MAIN's ROADMAP reflects landed
  # ticks within seconds. The coordinator's on-disk checkout only refreshes at plan-sync — which is why the
  # done count looked frozen mid-run. Prefer origin/$MAIN; fall back to the on-disk file if it's unavailable.
  src="$(git -C "$REPO" show "origin/${MAIN:-main}:ROADMAP.md" 2>/dev/null)"
  if [ -n "$src" ]; then
    d=$(printf '%s\n' "$src" | grep -cE '^[[:space:]]*- \[[xX]\] ')
    t=$(printf '%s\n' "$src" | grep -cE '^[[:space:]]*- \[[ xX]\] ')
  else
    d=$(grep -cE '^[[:space:]]*- \[[xX]\] ' "$rm" 2>/dev/null || echo 0)
    t=$(grep -cE '^[[:space:]]*- \[[ xX]\] ' "$rm" 2>/dev/null || echo 0)
  fi
  echo "${d:-0} ${t:-0}"; }
_last_event_for(){ [ -s "$SWARM_DIR/events.jsonl" ] || return 0
  grep -F "\"worker\":\"$1\"" "$SWARM_DIR/events.jsonl" 2>/dev/null | tail -1 | jq -r '.msg // ""' 2>/dev/null | cut -c1-70; }
# 3-state bar: done (█, solid) · IN-FLIGHT (▓, the items workers are on right now) · remaining (░).
# The in-flight segment moves as items are claimed/merged, so the bar reflects live activity — not
# just the rare full-merge jumps that made it look static.
_bar(){ local d="$1" t="${2:-1}" inf="${3:-0}" w=14 fd fi i=0; [ "$t" -lt 1 ] && t=1
  fd=$(( d*w/t )); [ "$fd" -gt "$w" ] && fd="$w"
  fi=$(( (d+inf)*w/t )); [ "$fi" -gt "$w" ] && fi="$w"; [ "$fi" -lt "$fd" ] && fi="$fd"
  [ "$inf" -gt 0 ] && [ "$fi" -le "$fd" ] && [ "$fd" -lt "$w" ] && fi=$(( fd + 1 ))   # show ≥1 block while any item is in-flight
  printf '%s' "$c_accent"; while [ "$i" -lt "$fd" ]; do printf '█'; i=$((i+1)); done
  printf '%s' "$c_gold"; while [ "$i" -lt "$fi" ]; do printf '▓'; i=$((i+1)); done
  printf '%s' "$c_dim"; while [ "$i" -lt "$w" ]; do printf '░'; i=$((i+1)); done; printf '%s' "$c_reset"; }

# a braille heartbeat that advances every frame (DASH_TICK) so the pre-dispatch view is visibly ALIVE.
_heartbeat(){ local f=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); printf '%s' "${f[$(( ${DASH_TICK:-0} % 10 ))]}"; }
# a small pulsing bar (moves left↔right) — a second "it's alive" cue that needs no data.
_pulse(){ local w=12 span p i=0; span=$(( w*2 - 2 )); p=$(( ${DASH_TICK:-0} % span )); [ "$p" -ge "$w" ] && p=$(( span - p ))
  printf '%s' "$c_dim"; while [ "$i" -lt "$w" ]; do [ "$i" = "$p" ] && printf '%s◆%s' "$c_accent$bold" "$c_dim" || printf '·'; i=$((i+1)); done; printf '%s' "$c_reset"; }

# ── live-progress helpers (merge cadence · ETA · attention) ─────────────────────────────────────
# _spark "n n n …" → a unicode sparkline scaled to the series max. Array-indexed (no multibyte substring).
_spark(){ local -a ch=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █); local max=1 v out=""
  for v in $1; do [ "${v:-0}" -gt "$max" ] 2>/dev/null && max="$v"; done
  for v in $1; do out+="${ch[$(( ${v:-0}*7/max ))]}"; done; printf '%s' "$out"; }
# _fmt_ago SECONDS → "45s" / "12m" / "1h05m"
_fmt_ago(){ local a="${1:-0}"; if [ "$a" -lt 60 ]; then printf '%ds' "$a"; elif [ "$a" -lt 3600 ]; then printf '%dm' "$((a/60))"; else printf '%dh%02dm' "$((a/3600))" "$(((a%3600)/60))"; fi; }
# merge-ish bus timestamps (sorted) — a tick landed on main: phase 'merging', or a "main advanced"/"merged" msg.
_merge_ts(){ jq -r 'select((.phase=="merging") or (.msg|test("main advanced|merged|merging on its authority";"i")))|.ts' "$SWARM_DIR/events.jsonl" 2>/dev/null | sort -n; }
# _pulse_merges "sorted_ts" now → "▁▂▅▇ last 3m" (gold when the last merge is old — a stalling cue).
_pulse_merges(){ local ts="$1" now="$2" win="${PULSE_WIN:-1800}" nb=14 last ago series agocol
  [ -z "$ts" ] && { printf '%s···· no merges yet%s' "$c_dim" "$c_reset"; return; }
  last="$(printf '%s\n' "$ts" | tail -1)"; ago=$(( now - last ))
  agocol="$c_dim"; [ "$ago" -gt 600 ] && agocol="$c_gold"
  series="$(printf '%s\n' "$ts" | awk -v now="$now" -v win="$win" -v nb="$nb" '{d=now-$1; if(d>=0&&d<win){b=int((win-d)*nb/win); if(b>=nb)b=nb-1; c[b]++}} END{for(i=0;i<nb;i++)printf "%d ",c[i]+0}')"
  printf '%s%s%s %slast %s%s' "$c_accent" "$(_spark "$series")" "$c_reset" "$agocol" "$(_fmt_ago "$ago")" "$c_reset"; }
# _eta "sorted_ts" now remaining → "~1h05m" from the recent merge rate, "—" if no recent merges, "done" if 0 left.
_eta(){ local ts="$1" now="$2" rem="${3:-0}" win="${PULSE_WIN:-1800}" n eta
  [ "$rem" -le 0 ] && { printf '%sdone%s' "$c_green" "$c_reset"; return; }
  n="$(printf '%s\n' "$ts" | awk -v now="$now" -v win="$win" 'now-$1>=0&&now-$1<win{c++} END{print c+0}')"
  [ "${n:-0}" -lt 1 ] && { printf '%s—%s' "$c_dim" "$c_reset"; return; }
  eta=$(( rem * win / n )); printf '~%s' "$(_fmt_ago "$eta")"; }
# collisions the coordinator recorded in the batch plan (cheap — no re-lint per frame).
_dash_collisions(){ grep -c '^COLLIDE' "$SWARM_DIR/batch-plan.txt" 2>/dev/null || echo 0; }

# infer the coordinator's PRE-worker phase from its log so the dash NAMES what it's doing (never blank).
# emits: "human label<TAB>step-idx"  (step: 0 preflight · 1 planning · 2 dispatching)
_coord_phase(){
  local l; l="$(grep -avE 'jq:|parse error|Cannot index' "$SWARM_DIR/coordinator.log" 2>/dev/null | grep -vE '^[[:space:]]*$' | tail -n 30 | sed "s/$ESC\\[[0-9;]*m//g" | tr 'A-Z' 'a-z')"
  case "$l" in
    *"usage limit"*|*"waiting for reset"*|*"limit — waiting"*|*"limit hasn't reset"*) printf '%s\t%s' "paused — overseer hit a usage limit; resumes automatically on reset" 1 ;;
    *"syncing objectives"*|*"→ roadmap"*|*"read objectives"*|*"read roadmap"*|*"planning"*|*"chore/plan"*) printf '%s\t%s' "planning — the orchestrator is turning OBJECTIVES into ROADMAP tasks" 1 ;;
    *"container gate"*|*"ci.sh --container"*|*"verifying ./ci.sh"*|*"resuming"*|*"rescue"*) printf '%s\t%s' "verifying the gate on prior work before dispatch" 0 ;;
    *"preflight"*|*"consistency"*|*"reconcil"*) printf '%s\t%s' "preflight — reconciling repo state (git · gitnexus · opencode)" 0 ;;
    *"conflict-policy"*|*"self-heal"*|*"🐝 swarm"*) printf '%s\t%s' "starting up — wiring the swarm + conflict policy" 0 ;;
    *) printf '%s\t%s' "spinning up workers — they will claim tasks any moment" 2 ;;
  esac
}
# mini step tracker:  preflight ✓ → ▸plan◂ → dispatch
_coord_steps(){ local a="$1" i=0 out="" s names=(preflight plan dispatch)
  for s in "${names[@]}"; do
    [ "$i" -gt 0 ] && out+="${c_dim} → ${c_reset}"
    if   [ "$i" -lt "$a" ]; then out+="${c_green}${s} ✓${c_reset}"
    elif [ "$i" -eq "$a" ]; then out+="${c_accent}${bold}▸${s}◂${c_reset}"
    else out+="${c_dim}${s}${c_reset}"; fi; i=$((i+1))
  done; printf '%s' "$out"; }

# THE resilient worker source: status/*.stat is authoritative for RENDERING (feat/phase/
# wall/budget/act), liveness comes from max(stat.ts, wN.log mtime) so a busy worker mid-
# implement (stat ts stale, but log streaming) never disappears. Paths augmented from
# state.json when it's readable. Emits: worker<TAB>feat<TAB>phase<TAB>wall<TAB>budget<TAB>act<TAB>paths
_live_workers(){
  local now stale pj; now="$(date +%s)"; stale="${DASH_STALE:-300}"
  pj="$(jq -rc '.claims[]|select(.status=="active")|[.worker,.paths]|@tsv' "$STATE" 2>/dev/null)"
  local f
  for f in "$SWARM_DIR"/status/*.stat; do
    [ -f "$f" ] || continue
    local worker feat phase wall budget act ts lm live paths
    worker="$(sed -n 's/^worker=//p' "$f")"; [ -n "$worker" ] || worker="$(basename "$f" .stat)"
    phase="$(sed -n 's/^phase=//p' "$f")"; feat="$(sed -n 's/^feat=//p' "$f")"
    wall="$(sed -n 's/^wall=//p' "$f")"; budget="$(sed -n 's/^budget=//p' "$f")"
    act="$(sed -n 's/^act=//p' "$f")"; ts="$(sed -n 's/^ts=//p' "$f")"; [ -n "$ts" ] || ts=0
    case "$phase" in done|idle|"") continue ;; esac        # finished / between items → not a live box
    lm="$(stat -c %Y "$SWARM_DIR/$worker.log" 2>/dev/null || echo 0)"
    live=$(( lm > ts ? lm : ts )); [ $((now - live)) -gt "$stale" ] && continue   # silent too long → drop
    paths="$(printf '%s\n' "$pj" | awk -F'\t' -v w="$worker" '$1==w{print $2; exit}')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$worker" "$feat" "$phase" "$wall" "$budget" "$act" "$paths"
  done | sort -u
}

# section rule — a bold, unmistakable divider title:  ━━━ ⚙ WORKERS ━━━━━━━━━━━━━
_rule(){ local glyph="$1" title="$2" col="${3:-$c_accent}" w tv
  w="$(tput cols 2>/dev/null || echo 100)"; tv=$(( ${#title} + 6 ))
  printf ' %s━━━ %s%s%s %s%s%s\n' "$col" "$col$bold" "$glyph $title" "$c_reset$col" "$(_dashes $(( w - tv - 6 )))" "$c_reset" ""; }

dash_header(){ printf ' %s⛧ A C E%s %s· the forge%s  %s—  the loop is %seternal%s   %s[%s]%s\n' \
    "$c_accent$bold" "$c_reset" "$c_muted" "$c_reset" "$c_dim" "$c_gold" "$c_reset" "$c_dim" "${DASH_MODE:-stacked}" "$c_reset"; }

dash_statusbar(){
  local d t; read -r d t < <(_dash_roadmap)
  local active peak paused draining pct now mts pulse eta ncoll collchip inflabel
  active="$(_live_workers | grep -c . )"
  # +1 on claim, -1 on ANY terminal event (done/conflict/error/idle) — else an error-released worker's
  # +1 is never decremented and peak over-reports.
  peak=$(jq -rc 'select(.phase=="claimed" or .phase=="done" or .phase=="conflict" or .phase=="error" or .phase=="idle")|[.ts,(if .phase=="claimed" then 1 else -1 end)]|@tsv' "$SWARM_DIR/events.jsonl" 2>/dev/null | sort -n | awk '{c+=$2; if(c>m)m=c} END{print m+0}')
  [ -f "$SWARM_DIR/control.pause" ] && paused=" ${c_gold}${bold}⏸ PAUSED${c_reset}"
  [ -f "$SWARM_DIR/control.drain" ] && draining=" ${c_gold}${bold}⌁ FINISHING → STOP${c_reset}"
  pct=0; [ "$t" -gt 0 ] && pct=$(( d * 100 / t ))
  now="$(date +%s)"; mts="$(_merge_ts)"
  pulse="$(_pulse_merges "$mts" "$now")"; eta="$(_eta "$mts" "$now" "$(( t - d ))")"
  ncoll="$(_dash_collisions)"; collchip=""; [ "${ncoll:-0}" -gt 50 ] && collchip="   ${c_gold}⚠ ${ncoll} serializing${c_reset}"
  inflabel=""; [ "$active" -gt 0 ] && inflabel=" ${c_gold}+${active} in-flight${c_reset}"
  # line 1 — the RUN: identity + live worker count + peak concurrency + pause/drain state
  printf ' %s●%s run %s%s%s      %s●%s workers %s%s%s      %s●%s peak %s%s%s%s%s\n' \
    "$c_accent" "$c_muted" "$c_fg" "${RUNID:-—}" "$c_reset" \
    "$c_green" "$c_muted" "$c_green$bold" "$active" "$c_reset" \
    "$c_accent" "$c_muted" "$c_fg" "${peak:-0}" "$c_reset" "${paused:-}" "${draining:-}"
  # line 2 — PROGRESS: live roadmap done/total (%) + 3-state bar + merge pulse + ETA (+ collisions if serializing)
  printf ' %s●%s roadmap %s%s/%s%s %s%s%%%s %s%s      %s⇡%s %s      %seta%s %s%s\n' \
    "$c_gold" "$c_muted" "$c_fg$bold" "$d" "$t" "$c_reset" "$c_dim" "$pct" "$c_reset" "$(_bar "$d" "$t" "$active")" "$inflabel" \
    "$c_accent" "$c_reset" "$pulse" "$c_muted" "$c_reset" "$eta" "$collchip"
  printf ' %s%s%s\n' "$c_border" "$(_dashes "$(( $(tput cols 2>/dev/null||echo 100) - 2 ))")" "$c_reset"
}

# coordinator line + (if no live workers) a clear reason WHY, never a silent blank
_coord_up(){ [ -f "$SWARM_DIR/coordinator.pid" ] && kill -0 "$(cat "$SWARM_DIR/coordinator.pid" 2>/dev/null)" 2>/dev/null; }
dash_coord(){
  local slug hb="" wtr; slug="$(basename "$REPO")"; wtr="$SWARM_DIR/worktrees"
  _coord_up && hb="${c_green}$(_heartbeat)${c_reset} "     # live pulse so you can SEE it's not dead — during dispatch too
  printf '  %s%s⚙ coordinator%s %s· %s%s%s · reconcile · merge-queue · ROADMAP tick%s\n' \
    "$hb" "$c_accent$bold" "$c_reset" "$c_muted" "$c_fg$bold" "$slug" "$c_reset$c_muted" "$c_reset"
  # WHERE ace is working: the project root (the repo the loop drives) + where each worker's isolated worktree lives.
  printf '    %s📁 repo %s%s%s    %s⎇ worktrees %s%s%s\n' \
    "$c_muted" "$c_fg" "$REPO" "$c_reset" "$c_muted" "$c_dim" "$wtr" "$c_reset"
}
# The reassuring PRE-DISPATCH panel: shown while the coordinator is up but no worker has claimed yet
# (preflight / gate / planning can take minutes). Names the phase, tracks the step, and BEATS so nobody
# thinks it hung. ~5 lines — enough to reassure, small enough to leave room for the workers.
dash_no_workers(){
  if [ -f "$SWARM_DIR/control.drain" ]; then
    printf '   %s⌁ finishing current tasks — swarm will STOP once workers are done (no new work claimed)%s\n' "$c_gold" "$c_reset"; return
  fi
  if ! _coord_up; then
    printf '   %sno swarm running — start it: %sace autorun%s (pick 2-5) %sor%s ace swarm start%s\n' "$c_dim" "$c_fg" "$c_dim" "$c_muted" "$c_dim" "$c_reset"; return
  fi
  local ph si; IFS=$'\t' read -r ph si < <(_coord_phase)
  local wcol; wcol="$(( $(tput cols 2>/dev/null || echo 100) - 10 ))"
  local cline; cline="$(grep -avE 'jq:|parse error|Cannot index' "$SWARM_DIR/coordinator.log" 2>/dev/null | grep -vE '^[[:space:]]*$' | tail -n1 | sed "s/$ESC\\[[0-9;]*m//g" | cut -c1-"$wcol")"
  printf '   %s%s%s %sworking — no workers dispatched yet, and that is normal%s   %s\n' "$c_gold$bold" "$(_heartbeat)" "$c_reset" "$c_fg$bold" "$c_reset" "$(_pulse)"
  printf '   %s◆%s %s%s%s\n' "$c_accent" "$c_reset" "$c_fg" "$ph" "$c_reset"
  printf '   %s\n' "$(_coord_steps "$si")"
  printf '   %s↳ %s%s\n' "$c_dim" "${cline:-…}" "$c_reset"
  printf '   %sworker boxes appear here the instant one claims its first task%s\n' "$c_dim" "$c_reset"
}

# The 9 subagents, grouped under the 5 pipeline stages:  id : short-label : stage-idx.
# conflict_resolver is stage 9 so it only lights up when a conflict actually occurs (not by stage order).
_AGENTS="orchestrator:plan:0 implementer:impl:1 test_engineer:test:1 verifier:gate:2 reviewer:rev:3 ux_reviewer:ux:3 standards_keeper:std:3 alignment_reviewer:algn:3 conflict_resolver:rslv:9"

# _stage_from_log WORKER → "idx<TAB>agent" from the MOST RECENT marker in the live log. The .stat phase
# stays "implement" the whole time (the entire implement→gate→review→merge runs inside ONE opencode
# orchestrator call), so we read the log to make the pipeline actually advance + name the active agent.
_stage_from_log(){
  local log="$SWARM_DIR/$1.log"; [ -s "$log" ] || return 0
  tail -n 240 "$log" 2>/dev/null | sed "s/$ESC\\[[0-9;]*m//g" | tac 2>/dev/null | awk '
    { l=tolower($0)
      if (l ~ /loop ended|nothing to merge|pr #[0-9]+ merged|gh pr merge|✔ merged/) {print "4\tmerge"; exit}
      if (l ~ /conflicting|conflict.resolver/)      {print "3\tconflict_resolver"; exit}
      if (l ~ /alignment.?review/)                  {print "3\talignment_reviewer"; exit}
      if (l ~ /standards.?keep/)                    {print "3\tstandards_keeper"; exit}
      if (l ~ /ux.?review/)                         {print "3\tux_reviewer"; exit}
      if (l ~ /reviewer|approve|changes_requested/) {print "3\treviewer"; exit}
      if (l ~ /container gate|ci\.sh|verifier/)     {print "2\tverifier"; exit}
      if (l ~ /test.?engineer/)                     {print "1\ttest_engineer"; exit}
      if (l ~ /implementer|implement:/)             {print "1\timplementer"; exit}
      if (l ~ /planning|writing spec|opencode\/specs|plan:/) {print "0\torchestrator"; exit}
    }'
}

# _agents_line WORKER ACTIVE CURIDX → the ALL-AGENTS strip: every subagent shown, ✓ once it has run
# (its stage passed, or it appears in the log), ▸active◂ when running now, dim while pending.
_agents_line(){
  local log="$SWARM_DIR/$1.log" active="$2" cur="${3:-0}" seen e id lbl st out=""
  seen="$(tail -n 240 "$log" 2>/dev/null | sed "s/$ESC\\[[0-9;]*m//g" | tr 'A-Z' 'a-z')"
  for e in $_AGENTS; do
    id="${e%%:*}"; lbl="$(printf '%s' "$e" | cut -d: -f2)"; st="${e##*:}"
    if [ "$id" = "$active" ]; then out+="${c_accent}${bold}▸${lbl}◂${c_reset} "
    elif [ "$st" -lt "$cur" ] || printf '%s' "$seen" | grep -qE "(^|[^a-z_])${id//_/[_ ]}"; then out+="${c_green}${lbl}✓${c_reset} "   # word-boundary: 'reviewer' must NOT match ux_reviewer/alignment_reviewer
    else out+="${c_dim}${lbl}${c_reset} "; fi
  done
  printf '%s' "$out"
}

# ── STACKED layout: one full-bordered box per worker with its live feed inline ──
dash_workers(){
  local cols_t rows_t; cols_t="$(tput cols 2>/dev/null || echo 100)"; rows_t="$(tput lines 2>/dev/null || echo 42)"
  local BW CW; BW=$(( cols_t - 4 )); [ "$BW" -lt 44 ] && BW=44; CW=$(( BW - 4 ))   # scales to the FULL terminal width (no 116 cap → wide terminals get wide boxes, less truncation)
  dash_coord
  local rows; rows="$(_live_workers)"
  [ -z "$rows" ] && { dash_no_workers; return; }
  local n; n="$(printf '%s\n' "$rows" | grep -c .)"
  # size each worker's feed so the WHOLE frame fits the terminal height (never overflow → scroll).
  # fixed chrome = header1 + status3 (run+progress+rule) + workers-rule1 + coord2 + busrule1 + footer2 = 12,
  # plus the bus lines; each worker box is 7 chrome rows + its feed. (The PROGRESS line added +1 here.)
  local buslines="${DASH_BL:-${DASH_BUSLINES:-5}}" feed maxbox shown="$n" hidden=0
  # never overflow a small window: cap boxes to what fits (7 chrome + ≥2 feed = 9 rows each); the rest
  # get a "+N more — press g for grid" note. This is what keeps ACE inside the terminal.
  maxbox=$(( (rows_t - 12 - buslines) / 9 )); [ "$maxbox" -lt 1 ] && maxbox=1   # -12 fixed chrome; box = 7 chrome + ≥2 feed = 9
  [ "$n" -gt "$maxbox" ] && { shown="$maxbox"; hidden=$(( n - maxbox )); }
  feed=$(( (rows_t - 12 - buslines) / (shown>0?shown:1) - 7 )); [ "$feed" -lt 2 ] && feed=2   # box = 7 chrome rows (border·pipeline·agents·meta·paths·separator·border)
  [ -n "${DASH_FEED_OVR:-}" ] && feed="$DASH_FEED_OVR"; [ "$feed" -gt 24 ] && feed=24
  local w feat phase wall budget act paths shown_i=0
  while IFS=$'\t' read -r w feat phase wall budget act paths; do
    [ -z "$w" ] && continue
    [ "$shown_i" -ge "$shown" ] && continue; shown_i=$(( shown_i + 1 ))   # box budget spent → skip the rest (noted below)
    local wc idx cf="" agent=""; wc="$(_wcol "$w")"; idx="$(_stage_idx "$phase")"; case "$phase" in resolve|conflict) cf=1;; esac
    local _inf; _inf="$(_stage_from_log "$w")"; [ -n "$_inf" ] && { idx="${_inf%%$'\t'*}"; agent="${_inf#*$'\t'}"; }
    [ "$agent" = conflict_resolver ] && cf=1
    [ -n "$feat" ] || feat="(item)"
    # attention: how long since this worker last wrote anything? past HANG_WARN it's a stall cue (gold tag).
    local _lm _att=""; _lm="$(stat -c %Y "$SWARM_DIR/$w.log" 2>/dev/null || echo 0)"
    [ "$_lm" -gt 0 ] && { local _age=$(( $(date +%s) - _lm )); [ "$_age" -ge "${HANG_WARN:-300}" ] && _att="   ${c_gold}${bold}⚠ silent $(_fmt_ago "$_age")${c_reset}"; }
    # ── full box ──────────────────────────────────────────────────────────────
    local ttl="⛧ swarm worker ${w#w} · ${feat}"; ttl="$(printf '%s' "$ttl" | cut -c1-$((CW-6)))"
    printf '  %s┌─ %s%s%s %s%s┐%s\n' "$wc" "$wc$bold" "$ttl" "$c_reset$wc" "$(_dashes $(( CW - $(_vw "$ttl") - 1 )))" "$wc" "$c_reset"
    _bx_row "$wc" "$CW" "$(_pipeline "$idx" "$cf")   ${c_muted}${bold}$([ -n "$agent" ] && printf '⚙ %s' "$agent" || _phase_label "$phase")${c_reset}${_att}"
    _bx_row "$wc" "$CW" "$(_agents_line "$w" "$agent" "$idx")"
    # WHERE this worker is working: its isolated worktree + branch, the wall/budget, then the file leases it holds
    local _wt _br; _wt="$(ls -d "$SWARM_DIR/worktrees/$w"-* 2>/dev/null | head -1)"; _br="$(git -C "$_wt" symbolic-ref --short HEAD 2>/dev/null)"
    _bx_row "$wc" "$CW" "${c_muted}wall ${c_fg}${wall:-?}m${c_muted}/${budget:-?}m    ${c_muted}⎇ ${c_fg}${_br:-—}    ${c_muted}📁 ${c_dim}${_wt##*/}${c_reset}"
    _bx_row "$wc" "$CW" "${c_dim}⟨ $(printf '%s' "${paths:-…}" | cut -c1-$((CW-6))) ⟩${c_reset}"
    _bx_row "$wc" "$CW" "${c_border}$(_dashes $(( CW - 1 )))${c_reset}"   # separator: meta ┄ live feed (cleaner line separation)
    # live feed, ANSI-stripped + WRAPPED to the box width (fold at spaces — no more mid-line truncation)
    if [ "${DASH_FEEDS:-1}" != 0 ] && [ -s "$SWARM_DIR/$w.log" ]; then
      tail -n "$feed" "$SWARM_DIR/$w.log" 2>/dev/null | sed "s/$ESC\\[[0-9;]*m//g" | fold -s -w "$(( CW - 2 ))" | tail -n "$feed" | while IFS= read -r ln; do
        local lc="$c_fg"
        case "$ln" in *GREEN*|*✓*|*APPROVE*|*merged*|*PASS*|*done*) lc="$c_green";; *RED*|*✗*|*FAIL*|*error*|*⛔*|*CONFLICT*) lc="$c_red";;
          *⚠*|*WARN*|*CHANGES*|*HANG*|*waiting*) lc="$c_gold";; *'→ opencode'*|*Agent*|*'• '*) lc="$c_accent";; *'…'*|*thinking*|*'now:'*) lc="$c_muted";; esac
        _bx_row "$wc" "$CW" "${lc}${ln}${c_reset}"
      done
    else _bx_row "$wc" "$CW" "${c_dim}↳ ${act:-waiting for output…}${c_reset}"; fi
    printf '  %s└%s┘%s\n' "$wc" "$(_dashes $(( CW + 2 )))" "$c_reset"
  done <<< "$rows"
  [ "$hidden" -gt 0 ] && printf '  %s… +%d more worker%s not shown (window too short) — press %sg%s for the grid view%s\n' \
    "$c_gold" "$hidden" "$([ "$hidden" -gt 1 ] && echo s)" "$c_accent$bold" "$c_gold" "$c_reset"
}

# a single bordered content row, padded to CW so the right border lines up. Collapse TABS to a single
# space first: a tab counts as ONE char in _vw but the terminal renders it as up to 8 columns, so a
# tab-bearing feed line (git/gh output is tab-separated) would push the right │ out of alignment.
_bx_row(){ local wc="$1" cw="$2" content="$3" pad; content="${content//$'\t'/ }"
  pad=$(( cw - $(_vw "$content") )); [ "$pad" -lt 0 ] && pad=0
  printf '  %s│%s %s%s %s│%s\n' "$wc" "$c_reset" "$content" "$(_spaces "$pad")" "$wc" "$c_reset"; }

# ── PANEL layout: worker cells in a side-by-side grid (the "4 terminals" view) ──
dash_grid(){
  local cols_t rows_t; cols_t="$(tput cols 2>/dev/null || echo 100)"; rows_t="$(tput lines 2>/dev/null || echo 42)"
  dash_coord
  local rows; rows="$(_live_workers)"
  [ -z "$rows" ] && { dash_no_workers; return; }
  local n; n="$(printf '%s\n' "$rows" | grep -c .)"
  local ncols; ncols=$(( cols_t / 46 )); [ "$ncols" -lt 1 ] && ncols=1; [ "$ncols" -gt "$n" ] && ncols="$n"; [ "$ncols" -gt 4 ] && ncols=4
  local cw; cw=$(( cols_t / ncols - 2 )); [ "$cw" -gt 100 ] && cw=100   # cells scale with the terminal (was capped at 58)
  local nrows; nrows=$(( (n + ncols - 1) / ncols ))
  local ch; ch=$(( (rows_t - 12) / (nrows>0?nrows:1) )); [ "$ch" -lt 6 ] && ch=6; [ "$ch" -gt 16 ] && ch=16   # -12: +1 for the PROGRESS status line
  local feedh=$(( ch - 4 ))
  # collect worker records into arrays (compute the log-inferred stage/agent ONCE per worker here,
  # never per cell-line, or we'd spawn ch×n tail|awk pipelines every frame).
  local -a WW=() FT=() PH=() WL=() BD=() AC=() IDX=() AGT=()
  local w feat phase wall budget act paths
  while IFS=$'\t' read -r w feat phase wall budget act paths; do
    [ -z "$w" ] && continue; WW+=("$w"); FT+=("$feat"); PH+=("$phase"); WL+=("$wall"); BD+=("$budget"); AC+=("$act")
    local _ix _ag _inf; _ix="$(_stage_idx "$phase")"; _ag=""
    _inf="$(_stage_from_log "$w")"; [ -n "$_inf" ] && { _ix="${_inf%%$'\t'*}"; _ag="${_inf#*$'\t'}"; }
    IDX+=("$_ix"); AGT+=("$_ag")
  done <<< "$rows"
  local total="${#WW[@]}" gr i
  for (( gr=0; gr<total; gr+=ncols )); do          # each grid ROW of up to ncols cells
    local line
    for (( line=0; line<ch; line++ )); do          # each visual line within the row of cells
      local col
      for (( col=0; col<ncols; col++ )); do
        i=$(( gr + col )); [ "$i" -ge "$total" ] && { printf '%s' "$(_spaces $(( cw + 2 )))"; continue; }
        _grid_cell_line "$i" "$line" "$ch" "$feedh" "$cw"
      done
      printf '\n'
    done
  done
  # store arrays for the cell renderer via globals
}

# render ONE line of ONE grid cell (no trailing newline). Uses the WW/FT/... arrays.
_grid_cell_line(){
  local i="$1" line="$2" ch="$3" feedh="$4" cw="$5"
  local w="${WW[$i]}" wc idx="${IDX[$i]}" agent="${AGT[$i]}" cf=""; wc="$(_wcol "$w")"
  case "${PH[$i]}" in resolve|conflict) cf=1;; esac; [ "$agent" = conflict_resolver ] && cf=1
  local inner=$(( cw - 2 ))
  if [ "$line" -eq 0 ]; then
    local ttl; ttl="$(printf '⛧ w%s · %s' "${w#w}" "${FT[$i]}" | cut -c1-$((inner-2)))"
    printf '  %s┌─ %s%s%s %s%s┐%s' "$wc" "$wc$bold" "$ttl" "$c_reset$wc" "$(_dashes $(( inner - $(_vw "$ttl") - 3 )))" "$wc" "$c_reset"
  elif [ "$line" -eq 1 ]; then
    _cell_pad "$wc" "$inner" "$(_pipeline_compact "$idx" "$cf")"
  elif [ "$line" -eq 2 ]; then
    _cell_pad "$wc" "$inner" "${c_accent}${bold}$([ -n "$agent" ] && printf '⚙ %s' "$agent" || _phase_label "${PH[$i]}")${c_reset} ${c_dim}${WL[$i]}m/${BD[$i]}m${c_reset}"
  elif [ "$line" -eq $(( ch - 1 )) ]; then
    printf '  %s└%s┘%s' "$wc" "$(_dashes "$inner")" "$c_reset"
  else
    local fl=$(( line - 3 )) txt
    txt="$(tail -n "$feedh" "$SWARM_DIR/$w.log" 2>/dev/null | sed "s/$ESC\\[[0-9;]*m//g" | sed -n "$((fl+1))p" | cut -c1-$((inner-1)))"
    [ -n "$txt" ] || txt=""
    local lc="$c_fg"; case "$txt" in *✓*|*PASS*|*done*|*merged*) lc="$c_green";; *✗*|*FAIL*|*error*|*⛔*) lc="$c_red";; *⚠*|*WARN*|*waiting*) lc="$c_gold";; *…*|*thinking*) lc="$c_muted";; esac
    _cell_pad "$wc" "$inner" "${lc}${txt}${c_reset}"
  fi
}
_pipeline_compact(){ local a="$1" cf="${2:-}" i=0 out="" m names=(P B G R M)
  for m in "${names[@]}"; do
    if [ "$i" -lt "$a" ]; then out+="${c_green}${m}${c_reset}"
    elif [ "$i" -eq "$a" ]; then out+="${c_accent}${bold}[${m}]${c_reset}"
    else out+="${c_dim}${m}${c_reset}"; fi; [ "$i" -lt 4 ] && out+="${c_dim}·${c_reset}"; i=$((i+1))
  done; printf '%s' "$out"; }
_cell_pad(){ local wc="$1" inner="$2" content="$3" pad; content="${content//$'\t'/ }"   # tabs → space (see _bx_row)
  pad=$(( inner - $(_vw "$content") )); [ "$pad" -lt 0 ] && pad=0
  printf '  %s│%s%s%s%s│%s' "$wc" "$c_reset" "$content" "$(_spaces "$pad")" "$wc" "$c_reset"; }

# ── titled, level-coloured event bus ──────────────────────────────────────────
dash_bus(){
  [ -s "$SWARM_DIR/events.jsonl" ] || return 0
  _rule "⛧" "BUS" "$c_gold"
  tail -n "${DASH_BL:-${DASH_BUSLINES:-5}}" "$SWARM_DIR/events.jsonl" 2>/dev/null | while IFS= read -r line; do
    local ts w lvl msg wc
    ts="$(printf '%s' "$line" | jq -r '(.ts|strftime("%H:%M:%S"))? // ""' 2>/dev/null)"
    w="$(printf '%s' "$line" | jq -r '.worker // "?"' 2>/dev/null)"; wc="$(_wcol "$w")"; w="$(_wname "$w")"
    lvl="$(printf '%s' "$line" | jq -r '.level // .phase // "info"' 2>/dev/null)"
    msg="$(printf '%s' "$line" | jq -r '.msg // ""' 2>/dev/null | cut -c1-100)"
    printf ' %s%s%s  %s%-9s%s %s%s%s\n' "$c_dim" "$ts" "$c_reset" "$wc$bold" "$w" "$c_reset" "$(_lvlc "$lvl")" "$msg" "$c_reset"
  done
}

dash_footer(){
  local cols_t; cols_t="$(tput cols 2>/dev/null || echo 100)"
  printf ' %s%s%s\n' "$c_border" "$(_dashes $(( cols_t - 2 )))" "$c_reset"
  printf ' %s●%s %sthe forge never sleeps%s   %sp%s pause · %sr%s resume · %sd%s finish+stop · %sk%s kill wN · %sx%s KILL ACE+quit · %sg%s %s · %s±%s feed · %sq%s quit dash\n' \
    "$c_crimson" "$c_reset" "$c_dim" "$c_reset" \
    "$c_accent$bold" "$c_muted" "$c_accent$bold" "$c_muted" "$c_accent$bold" "$c_muted" "$c_accent$bold" "$c_muted" \
    "$c_crimson$bold" "$c_muted" \
    "$c_accent$bold" "$c_muted" "$([ "${DASH_MODE:-stacked}" = grid ] && echo stacked || echo panel)" "$c_accent$bold" "$c_muted" "$c_accent$bold" "$c_muted"
}

dash_frame(){
  REPO="${REPO:-${SWARM_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  local _rt; _rt="$(tput lines 2>/dev/null || echo 42)"
  DASH_BL="${DASH_BUSLINES:-5}"; [ "$_rt" -lt 30 ] && DASH_BL=3   # tight window → smaller bus so workers + status still fit
  dash_header; dash_statusbar
  _rule "⚙" "WORKERS" "$c_accent"
  if [ "${DASH_MODE:-stacked}" = grid ]; then dash_grid; else dash_workers; fi
  echo; dash_bus; dash_footer
}

swarm_dash(){
  swarm_init
  REPO="${SWARM_REPO:-${REPO:-}}"; REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  # worker events carry the real run id; coordinator posts write run:"" — take the last NON-empty one.
  RUNID="${RUNID:-$(jq -r 'select(.run!=null and .run!="")|.run' "$SWARM_DIR/events.jsonl" 2>/dev/null | tail -1)}"
  command -v jq >/dev/null || { echo "swarm-dash needs jq"; return 1; }
  DASH_MODE="${DASH_MODE:-stacked}"
  # ALTERNATE SCREEN: a dedicated, non-scrolling viewport (like htop/vim). No scrollback
  # pollution while watching, and the terminal is restored exactly on quit — no scroll-up.
  printf '%s' "${ESC}[?1049h${ESC}[?25l"
  trap 'printf "%s" "${ESC}[?25h${ESC}[?1049l${ESC}[0m"' EXIT INT TERM
  # Read keys from the controlling terminal. In the normal interactive launch stdin IS the tty; but if
  # the ace CLI ever wraps the dash's stdin, fall back to /dev/tty so p/r/d/k/g/± still respond.
  local key kw _tty=; { [ -t 0 ] || ! [ -r /dev/tty ]; } || _tty=/dev/tty
  DASH_TICK=0
  while :; do
    DASH_TICK=$(( DASH_TICK + 1 ))     # advances the heartbeat/pulse every frame
    printf '%s%s%s' "${ESC}[H" "${ESC}[2J" "$(dash_frame)"
    if [ -n "$_tty" ]; then read -rsn1 -t "${DASH_REFRESH:-2}" key <"$_tty" || key=""
    else read -rsn1 -t "${DASH_REFRESH:-2}" key || key=""; fi
    case "$key" in
      q|Q) break ;;
      p|P) : > "$SWARM_DIR/control.pause" ;;
      r|R) rm -f "$SWARM_DIR/control.pause" "$SWARM_DIR/control.drain" ;;
      d|D) : > "$SWARM_DIR/control.drain" ;;
      g|G) if [ "${DASH_MODE:-stacked}" = grid ]; then DASH_MODE=stacked; else DASH_MODE=grid; fi ;;
      +|=) DASH_FEED_OVR=$(( ${DASH_FEED_OVR:-8} + 2 )) ;;
      -|_) DASH_FEED_OVR=$(( ${DASH_FEED_OVR:-8} - 2 )); [ "${DASH_FEED_OVR}" -lt 3 ] && DASH_FEED_OVR=3 ;;
      k|K) printf '%s kill which worker (e.g. w1): %s' "$c_gold" "$c_reset"
           if [ -n "$_tty" ]; then read -r kw <"$_tty"; else read -r kw; fi; [ -n "$kw" ] && : > "$SWARM_DIR/control.kill-$kw" ;;
      x|X) # KILL ACE — stop the WHOLE swarm (coordinator + workers + their opencode) and quit the dash
           printf '%s⛔ KILL the whole swarm — all workers + opencode — and quit? [y/N]: %s' "$c_crimson" "$c_reset"
           if [ -n "$_tty" ]; then read -r kw <"$_tty"; else read -r kw; fi
           case "$kw" in
             y|Y) printf '%s stopping — SIGTERM the swarm process group; in-flight work is committed as WIP on the worker branches…%s\n' "$c_gold" "$c_reset"
                  : > "$SWARM_DIR/control.drain" 2>/dev/null   # stop claiming new work at once
                  local cp; cp="$(cat "$SWARM_DIR/coordinator.pid" 2>/dev/null)"
                  if [ -n "$cp" ] && kill -0 "$cp" 2>/dev/null; then
                    # -"$cp" targets the coordinator's process GROUP (setsid leader): reaper + workers + opencode.
                    # Each worker's autoloop cleanup trap fires on TERM → preserves WIP + kills its opencode subtree.
                    kill -TERM -"$cp" 2>/dev/null || kill -TERM "$cp" 2>/dev/null
                    sleep 4
                    kill -KILL -"$cp" 2>/dev/null || kill -KILL "$cp" 2>/dev/null
                  fi
                  rm -f "$SWARM_DIR/coordinator.pid" 2>/dev/null
                  break ;;
           esac ;;
    esac
  done
}
[ "${BASH_SOURCE[0]}" = "${0}" ] && { case "${1:-}" in dash|"") swarm_dash;; frame) swarm_init; dash_frame;; esac; }
