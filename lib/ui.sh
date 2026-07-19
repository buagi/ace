#!/usr/bin/env bash
# ui.sh — colors, banner, menus, prompts. Pure bash, no external TUI deps.
# Theme: black · violet · blood-red — dark-fantasy / WH40K-Mechanicus / dark sci-fi. Pixel-art emblem
# (truecolor half-blocks) with a one-time animated reveal. Status stays semantic: green/yellow/red.
# Degrades cleanly: truecolor → 256-color → 8-color → NO_COLOR/non-TTY (plain text, no escapes, no motion).

ACE_COLOR=0; ACE_TC=0
# colour when stdout is a TTY (or ACE_FORCE_COLOR=1, for off-TTY snapshots) and NO_COLOR is unset.
if { [ -t 1 ] || [ "${ACE_FORCE_COLOR:-0}" = 1 ]; } && [ -z "${NO_COLOR:-}" ]; then
  ACE_COLOR=1; case "${COLORTERM:-}" in truecolor|24bit) ACE_TC=1 ;; esac
  [ "${ACE_FORCE_COLOR:-0}" = 1 ] && ACE_TC=1   # snapshots want full truecolor regardless of COLORTERM
fi

# headless guard — true when ACE_YES=1 or stdin isn't a TTY (no human to answer prompts). Prompts then
# resolve to their default / a provided value / fail clearly, so an agent (Hermes) never hangs ACE.
_noninteractive() { [ "${ACE_YES:-0}" = 1 ] || ! [ -t 0 ]; }

# _optin VAR "question" [Y|N] — headless: true iff env VAR=1 (explicit opt-in); interactive: ask.
# Used for the consequential extra steps (index/publish/VPS) so they never auto-run from a chat message.
_optin() { if _noninteractive; then [ "${!1:-0}" = 1 ]; else confirm "$2" "${3:-N}"; fi; }

# truecolor foreground emitter (only meaningful when ACE_TC=1)
_fg() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }

# Fixed bits + semantic status (theme-independent: green ok · yellow warn · red fail).
if [ "$ACE_COLOR" = 1 ] && [ "$ACE_TC" = 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$(_fg 57 158 67); C_YELLOW=$(_fg 205 156 31); C_GREY=$(_fg 108 108 130); C_STEEL=$(_fg 150 160 185)   # mockup: green·gold·muted
elif [ "$ACE_COLOR" = 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[38;5;42m'; C_YELLOW=$'\033[38;5;220m'; C_GREY=$'\033[38;5;102m'; C_STEEL=$'\033[38;5;110m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_GREEN=''; C_YELLOW=''; C_GREY=''; C_STEEL=''
fi

# apply_theme <warp|blood|void> — sets the ACCENT palette (everything but status). Re-callable.
#   warp  = violet (default) · blood = crimson · void = indigo/cyan (dark-sci-fi moon)
apply_theme() {
  _ACE_THEME="${1:-warp}"; case "$_ACE_THEME" in warp|blood|void) : ;; *) _ACE_THEME=warp ;; esac
  if [ "$ACE_COLOR" = 1 ] && [ "$ACE_TC" = 1 ]; then
    case "$_ACE_THEME" in
      blood) C_VIOLET=$(_fg 200 40 56); C_VIOLET2=$(_fg 120 12 22); C_ORCHID=$(_fg 255 96 96); C_RUNE=$(_fg 224 48 48); C_RED=$(_fg 255 70 70); C_BLOOD=$(_fg 110 0 0); C_EMBER=$(_fg 220 38 38) ;;
      void)  C_VIOLET=$(_fg 110 110 235); C_VIOLET2=$(_fg 44 52 120); C_ORCHID=$(_fg 150 200 255); C_RUNE=$(_fg 124 160 240); C_RED=$(_fg 255 70 90); C_BLOOD=$(_fg 70 30 110); C_EMBER=$(_fg 190 70 180) ;;
      *)     C_VIOLET=$(_fg 139 58 226); C_VIOLET2=$(_fg 64 62 84); C_ORCHID=$(_fg 166 87 237); C_RUNE=$(_fg 166 87 237); C_RED=$(_fg 204 39 46); C_BLOOD=$(_fg 110 0 0); C_EMBER=$(_fg 204 39 46) ;;   # mockup: accent·crimson·dim-border
    esac
    case "$_ACE_THEME" in blood) ACE_GRAD0="255 96 96"; ACE_GRAD1="110 0 0" ;; void) ACE_GRAD0="150 200 255"; ACE_GRAD1="190 70 180" ;; *) ACE_GRAD0="199 125 255"; ACE_GRAD1="139 0 0" ;; esac
  elif [ "$ACE_COLOR" = 1 ]; then
    case "$_ACE_THEME" in
      blood) C_VIOLET=$'\033[38;5;160m'; C_VIOLET2=$'\033[38;5;52m'; C_ORCHID=$'\033[38;5;203m'; C_RUNE=$'\033[38;5;196m'; C_RED=$'\033[38;5;196m'; C_BLOOD=$'\033[38;5;88m'; C_EMBER=$'\033[38;5;160m' ;;
      void)  C_VIOLET=$'\033[38;5;63m'; C_VIOLET2=$'\033[38;5;24m'; C_ORCHID=$'\033[38;5;117m'; C_RUNE=$'\033[38;5;69m'; C_RED=$'\033[38;5;204m'; C_BLOOD=$'\033[38;5;54m'; C_EMBER=$'\033[38;5;170m' ;;
      *)     C_VIOLET=$'\033[38;5;93m'; C_VIOLET2=$'\033[38;5;55m'; C_ORCHID=$'\033[38;5;141m'; C_RUNE=$'\033[38;5;135m'; C_RED=$'\033[38;5;196m'; C_BLOOD=$'\033[38;5;88m'; C_EMBER=$'\033[38;5;160m' ;;
    esac
  else
    C_VIOLET=''; C_VIOLET2=''; C_ORCHID=''; C_RUNE=''; C_RED=''; C_BLOOD=''; C_EMBER=''
  fi
  # back-compat aliases (existing call sites use these) → remapped onto the active theme
  C_MAGENTA="$C_VIOLET"; C_CYAN="$C_ORCHID"; C_BLUE="$C_VIOLET2"
  C_ACCENT="$C_ORCHID"; C_GOLD="$C_YELLOW"   # semantic names for the mockup header/menu
}
apply_theme "${ACE_THEME:-warp}"

# _gradient — colour stdin char-by-char across the theme gradient (truecolor only; else pass-through).
_gradient() {
  if [ "$ACE_TC" != 1 ]; then cat; return; fi
  local line r0 g0 b0 r1 g1 b1; read -r r0 g0 b0 <<<"${ACE_GRAD0:-199 125 255}"; read -r r1 g1 b1 <<<"${ACE_GRAD1:-139 0 0}"
  while IFS= read -r line; do
    local n=${#line} i d; d=$(( n>1 ? n-1 : 1 ))
    for ((i=0; i<n; i++)); do
      printf '\033[38;2;%d;%d;%dm%s' "$(( r0 + (r1-r0)*i/d ))" "$(( g0 + (g1-g0)*i/d ))" "$(( b0 + (b1-b0)*i/d ))" "${line:i:1}"
    done
    printf '\033[0m\n'
  done
}

# ---- status lines (semantic colors are intentional: green ok · yellow warn · red fail) -----------
say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${C_RUNE}◈${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}${C_BOLD}✓${C_RESET} $*"; }
warn() { printf '%s\n' "${C_YELLOW}${C_BOLD}⚠${C_RESET} $*" >&2; }
err()  { printf '%s\n' "${C_RED}${C_BOLD}✗${C_RESET} $*" >&2; }
step() { printf '\n%s %s%s%s\n' "${C_VIOLET}${C_BOLD}▰▰▶${C_RESET}" "${C_BOLD}${C_ORCHID}" "$*" "${C_RESET}"; }
hr()   { printf '%s\n' "${C_VIOLET2}⛧${C_VIOLET}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_VIOLET2}⛧${C_RESET}"; }

clear_screen() { [ -t 1 ] && printf '\033[2J\033[H' || true; }
# Alternate screen buffer (like vim/htop/less): the whole interactive menu runs on a throwaway screen, so on
# exit the terminal is RESTORED to exactly what was there before ACE — nothing left in the scroll-back. Each
# menu screen still clears via banner; this makes the *exit* clean too. ACE_ALT_SCREEN=0 opts out (keep output).
alt_screen_on()  { [ -t 1 ] && [ "${ACE_ALT_SCREEN:-1}" != 0 ] && printf '\033[?1049h\033[H' 2>/dev/null || true; }
alt_screen_off() { [ -t 1 ] && [ "${ACE_ALT_SCREEN:-1}" != 0 ] && printf '\033[?1049l' 2>/dev/null || true; }

# ---- the emblem ----------------------------------------------------------------------------------
# Ace-of-spades playing card (real ♠ silhouette in half/full blocks, violet→blood gradient) that bleeds:
# blood drips off the card's bottom edge. Gradient follows the active theme. Plain ASCII fallback.
_emblem_color() {
  local spade=(
    "           ▄▄"
    "          ████"
    "        ▄██████▄"
    "     ▄▄██████████▄▄"
    "   ▄████████████████▄"
    " ▄████████████████████▄"
    "▄██████████████████████▄"
    "████████████████████████"
    "▀█████████▀██▀█████████▀"
    "  ▀▀▀▀▀▀▀ ▄██▄ ▀▀▀▀▀▀▀"
    "         ▄████▄"
    "     ▄████████████▄"
  )
  local W=28 R="$C_RESET" B="$C_BOLD" vd="$C_VIOLET2" bd="$C_BLOOD" em="$C_EMBER" or="$C_ORCHID"
  local r0 g0 b0 r1 g1 b1; read -r r0 g0 b0 <<<"${ACE_GRAD0:-199 125 255}"; read -r r1 g1 b1 <<<"${ACE_GRAD1:-139 0 0}"
  local SW=24 n=${#spade[@]} i len lp rp r g b bar    # SW = the spade's intrinsic width; pad the BLOCK, not each row
  bar="$(printf '─%.0s' $(seq 1 "$W"))"
  printf '   %s╭%s╮%s\n' "$vd" "$bar" "$R"
  printf '   %s│%s %s%sA%s%s♠%s%*s%s│%s\n' "$vd" "$R" "$or" "$B" "$R" "$bd" "$R" $((W-3)) '' "$vd" "$R"
  for i in "${!spade[@]}"; do
    len=${#spade[$i]}; lp=$(( (W-SW)/2 )); rp=$(( W-lp-len ))
    if [ "$ACE_TC" = 1 ]; then
      r=$(( r0+(r1-r0)*i/(n-1) )); g=$(( g0+(g1-g0)*i/(n-1) )); b=$(( b0+(b1-b0)*i/(n-1) ))
      printf '   %s│%s%*s\033[38;2;%d;%d;%dm%s%s%*s%s│%s\n' "$vd" "$R" "$lp" '' "$r" "$g" "$b" "${spade[$i]}" "$R" "$rp" '' "$vd" "$R"
    else
      printf '   %s│%s%*s%s%s%s%*s%s│%s\n' "$vd" "$R" "$lp" '' "$C_VIOLET" "${spade[$i]}" "$R" "$rp" '' "$vd" "$R"
    fi
  done
  printf '   %s│%s%*s%s♠%s%s%sA%s %s│%s\n' "$vd" "$R" $((W-3)) '' "$bd" "$R" "$or" "$B" "$R" "$vd" "$R"
  printf '   %s╰─────┬───────┬──────┬───────╯%s\n' "$vd" "$R"
  # the card bleeds — blood drips off the bottom edge, irregular
  printf '%9s%s%7s%s%6s%s\n' '' "${bd}╻${R}" '' "${em}╻${R}" '' "${bd}╻${R}"
  printf '%9s%s%7s%s%6s%s\n' '' "${bd}┃${R}" '' "${em}▼${R}" '' "${bd}┃${R}"
  printf '%9s%s%7s%s%6s%s\n' '' "${em}▼${R}" '' " "          '' "${bd}▼${R}"
  printf '%9s%s▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄%s\n' '' "$bd" "$R"   # blood pool / stain (animated in the live banner)
}
_emblem_plain() {
  cat <<'ART'
   .------------------------.
   | A^                     |
   |           /\           |
   |         _/##\_         |
   |       _/######\_       |
   |     _/##########\_     |
   |    /##############\    |
   |    \##/  /##\  \##/    |
   |          \##/          |
   |         /####\         |
   |                     ^A |
   '----,-------,------,----'
        |       v      |
        v              v
ART
}

# the ACE wordmark (figlet/toilet gothic font when present, gradient-coloured) + a rotating tagline
_wordmark() {
  if [ "$ACE_COLOR" = 1 ]; then
    local A="$C_ACCENT" R="$C_RESET" B="$C_BOLD" wm=''
    # figlet/toilet only if explicitly opted in (ACE_FIGLET=on); the mockup block wordmark is the default
    if [ "${ACE_FIGLET:-auto}" = on ]; then
      command -v toilet >/dev/null 2>&1 && wm="$(toilet -f "${ACE_FIGFONT:-future}" 'ACE' 2>/dev/null)"
      [ -z "$wm" ] && command -v figlet >/dev/null 2>&1 && wm="$(figlet -f "${ACE_FIGFONT:-slant}" 'ACE' 2>/dev/null)"
    fi
    if [ -n "$wm" ]; then printf '%s\n' "$wm" | _gradient
    else
      printf '%s\n' "${B}${A}    █████╗  ██████╗███████╗${R}"
      printf '%s\n' "${B}${A}   ██╔══██╗██╔════╝██╔════╝${R}"
      printf '%s\n' "${B}${A}   ███████║██║     █████╗  ${R}"
      printf '%s\n' "${B}${A}   ██╔══██║██║     ██╔══╝  ${R}"
      printf '%s\n' "${B}${A}   ██║  ██║╚██████╗███████╗${R}"
      printf '%s\n' "${B}${A}   ╚═╝  ╚═╝ ╚═════╝╚══════╝${R}"
    fi
    printf '%s\n'   "   ${C_RED}⛧${R}  ${C_GREY}Agentic Coding Environment${R}  ${C_RED}⛧${R}"
    printf '%s\n'   "   ${C_VIOLET2}the forge never sleeps · the loop is ${C_GOLD}eternal${R}"
  else
    printf '%s\n'   "    >> A C E <<"
    printf '%s\n'   "    Agentic Coding Environment"
    printf '%s\n'   "    the forge never sleeps · the loop is eternal"
  fi
}
# Agents shown in the header. Derived from the ONE source of truth (_agent_counts in architecture.sh →
# $ACE_AGENTS + the model-pinned `debater`), never typed: this header said 9 while every other screen said
# 10, 11 or 12, which is precisely the drift a literal guarantees. ui.sh is sourced before architecture.sh,
# but this runs at RENDER time when the whole lib set is loaded; the literal covers only a test/snapshot
# that sources ui.sh on its own.
_ui_agent_total() {
  if type _agent_counts >/dev/null 2>&1; then _agent_counts | cut -d' ' -f2; else printf '12'; fi
}
# mockup status bar — a chip row (● dot · label · value) reflecting live system state.
# Renders in BOTH modes: the no-colour form is a plain one-liner (no escapes), because a piped/NO_COLOR
# run must still get the version + distro line that ui.sh's header promises.
_statusbar() {
  [ "$ACE_COLOR" = 1 ] || { printf '    v%s · %s · %s agents\n' "${ACE_VERSION:-?}" "${ACE_DISTRO_PRETTY:-?}" "$(_ui_agent_total)"; return; }
  local R="$C_RESET" g="$C_GREEN" y="$C_YELLOW" a="$C_ACCENT"
  local kc="$g" ks=ok; [ -z "${DEEPSEEK_API_KEY:-}" ] && { kc="$y"; ks="run keys"; }
  local hc="$g" hs=ok; command -v gh >/dev/null 2>&1 || { hc="$y"; hs="install"; }
  _chip(){ printf '%s●%s %s%s%s %s%s%s' "$2" "$R" "$C_GREY" "$3" "$R" "${4:-$C_STEEL}" "$5" "$R"; }
  printf '   %s    %s    %s    %s    %s\n' \
    "$(_chip d "$kc" key "$kc" "$ks")" "$(_chip d "$hc" gh "$hc" "$hs")" \
    "$(_chip d "$a" agents "$C_STEEL" "$(_ui_agent_total)")" "$(_chip d "$g" overseer "$C_STEEL" "$(orch_model_short)")" \
    "$(_chip d "$a" ver "$C_STEEL" "v${ACE_VERSION:-?}")"
}

# one-time animated reveal (truecolor + interactive only; ACE_NO_ANIM=1 disables)
_ACE_BANNER_DONE=0
banner() {
  clear_screen
  # one-time animated spade BOOT SPLASH, then the clean mockup header (ACE_SPLASH=0 skips the splash)
  if [ "$_ACE_BANNER_DONE" = 0 ] && [ "$ACE_TC" = 1 ] && [ -t 1 ] && [ "${ACE_NO_ANIM:-0}" != 1 ] && [ "${ACE_SPLASH:-1}" != 0 ]; then
    _splash_spade; sleep 0.5; clear_screen
  fi
  hr
  _wordmark
  # unconditional: _statusbar self-selects its plain vs chip-row form. Gating it on ACE_COLOR=1 made the
  # plain form dead code and silently dropped the version/distro line from every piped / NO_COLOR run —
  # exactly the runs (logs, CI capture, agent transcripts) where knowing the ACE version matters most.
  _statusbar
  hr
  _ACE_BANNER_DONE=1
}
# the ace-of-spades card bleeding in — kept as the boot splash (renders _emblem_color with drips)
# banner() only reaches this under ACE_TC=1 (⇒ ACE_COLOR=1), so the plain arm below never fires from
# there BY DESIGN: an animated splash must not spew into a pipe or a log. The arm is the degradation
# contract for anything that calls _splash_spade directly (menus/demos) — deliberately kept, not dead
# weight. The version/distro line that a no-colour run DOES need comes from _statusbar in banner().
_splash_spade() {
  [ "$ACE_COLOR" = 1 ] || { _emblem_plain; return; }
  local f; for f in '⛧· ·' '·⛧· ' ' ·⛧·' '· ·⛧'; do
    printf '\r   %s%s%s  initializing…   ' "$C_RUNE" "$f" "$C_RESET"; sleep 0.06
  done; printf '\r%*s\r' 44 ''
  local -a _emb; mapfile -t _emb < <(_emblem_color)
  local idx w dripstart=$(( ${#_emb[@]} - 4 )) poolidx=$(( ${#_emb[@]} - 1 ))
  for idx in "${!_emb[@]}"; do
    if [ "$idx" -eq "$poolidx" ]; then                    # blood pool spreads (single-line \r growth)
      for w in 3 6 9 12 16; do printf '\r%9s%s%s%s' '' "$C_BLOOD" "$(printf '▄%.0s' $(seq 1 "$w"))" "$C_RESET"; sleep 0.07; done
      printf '\r%s\n' "${_emb[$idx]}"
    elif [ "$idx" -ge "$dripstart" ]; then printf '%s\n' "${_emb[$idx]}"; sleep 0.12   # drips, one by one
    else printf '%s\n' "${_emb[$idx]}"; sleep 0.012; fi                                  # card reveal
  done
}

# ---- chrome ---------------------------------------------------------------------------------------
# box "Title" "line" ...  — ornate violet frame with rune accents
box() {
  local title="$1"; shift
  printf '%s\n' "${C_VIOLET2}╓─${C_RUNE}⛧${C_VIOLET} ${C_BOLD}${C_ORCHID}${title}${C_RESET} ${C_VIOLET2}${C_RESET}"
  local l
  for l in "$@"; do printf '%s %s\n' "${C_VIOLET2}║${C_RESET}" "$l"; done
  printf '%s\n' "${C_VIOLET2}╙─${C_RUNE}⛧${C_RESET}"
}

# menu "Header"  "label::hint"  ... ; sets MENU_CHOICE (1-based)
# Headless: honour MENU_PICK (1-based index OR a label substring), consumed once; else fail (never hang).
menu() {
  local header="$1"; shift
  local opts=("$@") i label hint
  if [ -n "${MENU_PICK:-}" ] || _noninteractive; then
    local pick="${MENU_PICK:-}"
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#opts[@]}" ]; then MENU_CHOICE="$pick"; MENU_PICK=""; return 0; fi
    if [ -n "$pick" ]; then
      for i in "${!opts[@]}"; do label="${opts[$i]%%::*}"; case "${label,,}" in *"${pick,,}"*) MENU_CHOICE=$((i+1)); MENU_PICK=""; return 0 ;; esac; done
    fi
    if _noninteractive; then err "menu '$header': set MENU_PICK to a 1-${#opts[@]} index or a label"; MENU_CHOICE=1; return 1; fi
  fi
  local _div; _div="$(printf '─%.0s' $(seq 1 44))"
  while true; do
    printf '\n   %s%s⛧ %s%s\n' "${C_BOLD}" "${C_ACCENT}" "$header" "${C_RESET}"
    printf '   %s%s%s\n\n' "${C_VIOLET2}" "$_div" "${C_RESET}"
    for i in "${!opts[@]}"; do
      label="${opts[$i]%%::*}"; hint="${opts[$i]#*::}"
      [ "$hint" = "${opts[$i]}" ] && hint=""
      printf '   %s%s%2d%s %s▸%s %s%s%s' "${C_BOLD}" "${C_ACCENT}" $((i+1)) "${C_RESET}" "${C_ACCENT}" "${C_RESET}" "${C_STEEL}" "$label" "${C_RESET}"
      [ -n "$hint" ] && printf '   %s%s%s' "${C_GREY}" "$hint" "${C_RESET}"
      printf '\n'
    done
    printf '\n   %s%s⛧%s %s%schoose%s %s[1-%d]%s %s▸%s ' "${C_BOLD}" "${C_ACCENT}" "${C_RESET}" "${C_BOLD}" "${C_FG:-}" "${C_RESET}" "${C_GREY}" "${#opts[@]}" "${C_RESET}" "${C_ACCENT}" "${C_RESET}"
    local r; read -r r
    if [[ "$r" =~ ^[0-9]+$ ]] && [ "$r" -ge 1 ] && [ "$r" -le "${#opts[@]}" ]; then
      MENU_CHOICE="$r"; return 0
    fi
    warn "Pick a number between 1 and ${#opts[@]}."
  done
}

# ask "Prompt" "default" -> ASK_REPLY   (headless: returns the default)
# ask "Prompt" "default" "hint" -> ASK_REPLY. Optional 3rd arg is a GREYED example shown in the prompt but never
# saved as the value (unlike the default) — e.g. a format template like 'openrouter/vendor/model'.
ask() {
  local prompt="$1" def="${2:-}" hint="${3:-}" r pfx
  if _noninteractive; then ASK_REPLY="$def"; return 0; fi
  pfx="$C_ORCHID$prompt$C_RESET"; [ -n "$hint" ] && pfx="$pfx $C_GREY($hint)$C_RESET"
  if [ -n "$def" ]; then printf '%s %s[%s]%s %s▸%s ' "$pfx" "$C_GREY" "$def" "$C_RESET" "$C_VIOLET" "$C_RESET"
  else printf '%s %s▸%s ' "$pfx" "$C_VIOLET" "$C_RESET"; fi
  read -r r; ASK_REPLY="${r:-$def}"
}

# ask_path "Prompt" "default" -> ASK_REPLY  (Tab-completes paths via readline; expands ~ · headless: default)
ask_path() {
  local prompt="$1" def="${2:-}" r
  if _noninteractive; then ASK_REPLY="${def/#\~/$HOME}"; return 0; fi
  if [ -n "$def" ]; then read -e -r -p "$(printf '%s%s%s %s[%s]%s %s▸%s ' "$C_ORCHID" "$prompt" "$C_RESET" "$C_GREY" "$def" "$C_RESET" "$C_VIOLET" "$C_RESET")" r
  else read -e -r -p "$(printf '%s%s%s %s▸%s ' "$C_ORCHID" "$prompt" "$C_RESET" "$C_VIOLET" "$C_RESET")" r; fi
  r="${r:-$def}"; ASK_REPLY="${r/#\~/$HOME}"
}

# ask_secret "Prompt" -> ASK_REPLY (no echo · headless: empty — caller must supply the secret via env)
ask_secret() {
  local prompt="$1" r
  if _noninteractive; then ASK_REPLY=""; return 0; fi
  printf '%s%s%s %s(hidden)%s %s▸%s ' "$C_ORCHID" "$prompt" "$C_RESET" "$C_GREY" "$C_RESET" "$C_VIOLET" "$C_RESET"
  read -rs r; printf '\n'; ASK_REPLY="$r"
}

# confirm "Question" [Y|N default] -> return 0 for yes   (headless: auto-answers the coded default)
confirm() {
  local q="$1" def="${2:-Y}" r hint="[Y/n]"
  [ "$def" = "N" ] && hint="[y/N]"
  if _noninteractive; then
    if [[ "$def" =~ ^[Yy] ]]; then printf '%s %s%s → yes (auto)%s\n' "$q" "$C_GREY" "$hint" "$C_RESET"; return 0
    else printf '%s %s%s → no (auto)%s\n' "$q" "$C_GREY" "$hint" "$C_RESET"; return 1; fi
  fi
  printf '%s%s%s %s%s%s %s▸%s ' "$C_ORCHID" "$q" "$C_RESET" "$C_GREY" "$hint" "$C_RESET" "$C_VIOLET" "$C_RESET"
  read -r r; r="${r:-$def}"
  [[ "$r" =~ ^[Yy] ]]
}

pause() { _noninteractive && return 0; printf '\n%s' "${C_GREY}press ${C_RUNE}⏎${C_GREY} to continue…${C_RESET}"; read -r _; }

# ---- progress + spinner (smooth UX, logs everything) ---------------------
ACE_STEP=0; ACE_STEPS=0
progress() {
  ACE_STEP=$((ACE_STEP+1))
  printf '\n%s %s%s%s\n' "${C_VIOLET}${C_BOLD}▰▰▶ [${ACE_STEP}/${ACE_STEPS}]${C_RESET}" "${C_BOLD}${C_ORCHID}" "$*" "${C_RESET}"
  type log >/dev/null 2>&1 && log "STEP $ACE_STEP/$ACE_STEPS: $*"
}

# spin "message" command args…  — runs cmd, shows spinner, logs output, returns cmd's exit code.
# Non-interactive (no tty) or dry-run degrade gracefully. Never use for commands needing stdin.
spin() {
  local msg="$1"; shift
  type log >/dev/null 2>&1 && log "RUN: $*"
  if [ "${ACE_DRY_RUN:-0}" = "1" ]; then printf '%s %s\n' "${C_YELLOW}[dry-run]${C_RESET}" "$*"; return 0; fi
  local sink="${ACE_LOG_FILE:-/dev/null}"
  if ! [ -t 1 ]; then "$@" >>"$sink" 2>&1; return $?; fi
  local frames='✶✸✹✺✹✷' i=0 pid rc
  ( "$@" >>"$sink" 2>&1 ) & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % ${#frames} ))
    printf '\r%s %s ' "${C_RUNE}${frames:$i:1}${C_RESET}" "${C_ORCHID}${msg}${C_RESET}"
    sleep 0.1
  done
  wait "$pid"; rc=$?
  if [ "$rc" -eq 0 ]; then printf '\r%s %s\n' "${C_GREEN}${C_BOLD}✓${C_RESET}" "$msg"
  else printf '\r%s %s %s\n' "${C_RED}${C_BOLD}✗${C_RESET}" "$msg" "${C_GREY}(see: ace logs)${C_RESET}"; fi
  type log >/dev/null 2>&1 && log "EXIT $rc: $*"
  return $rc
}
# spin_sh "message" 'shell snippet'  — for pipes/redirects
spin_sh() { spin "$1" bash -c "$2"; }
