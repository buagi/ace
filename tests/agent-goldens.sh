#!/usr/bin/env bash
# agent-goldens.sh — BEHAVIOURAL goldens for the read-only critics (Part F / F3, Edit 2). NIGHTLY/on-demand.
#
# prompt-contracts.sh catches STATIC clause regressions for free per-PR. This catches the behavioural ones
# that only surface at inference time and are the ones that actually hurt:
#   • a critic that GREEN-LIGHTS a seeded bug   (the worst failure — a bad change lands)
#   • a critic that CRIES WOLF on a clean diff  (sends the implementer to "fix" a non-bug, burning retries)
#   • ux_reviewer INVENTING user-surface findings on a backend-only diff
#   • a critic GUESSING instead of ABSTAINING when evidence is unavailable
# These need real model calls, so this is NIGHTLY/on-demand — NEVER per-PR (prompt-contracts.sh is the per-PR
# gate). Track its own spend with `ace stats`.
#
# ACE critics emit a MARKDOWN verdict (not JSON) and the orchestrator reads it by TOKEN — so assertions here
# are on tokens in the (scrubbed) raw output: format-agnostic, prose-independent (never assert wording).
# Follows the tests/snapshots convention (no promptfoo/npm/python). Reproduce-twice before a real fail (see
# the nightly workflow's re-run). Any subjective quality call must use a CROSS-FAMILY judge (Opus↔DeepSeek).
#
#   agent-goldens.sh --capture   run each critic (opencode) over tests/snapshots/agents/inputs/*.diff,
#                                scrub, write tests/snapshots/agents/<critic>__<case>.txt
#   agent-goldens.sh             (--check) assert every golden's verdict-token SCHEMA + its case INVARIANT.
#                                No goldens / no opencode → SKIP clean (never blocks; nightly seeds them).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 1
SNAP="tests/snapshots/agents"; INP="$SNAP/inputs"
MODE=check; [ "${1:-}" = --capture ] && MODE=capture
fail=0; bad(){ printf 'FAIL: %s\n' "$*"; fail=1; }

# scrub nondeterministic fields (timestamps, session ids, token counts) before snapshot compare
scrub(){ sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z?/<ts>/g; s/ses_[a-zA-Z0-9]+/<sid>/g; s/[0-9,]+ tokens?/<n> tokens/g'; }

# does the critic's output carry an APPROVING verdict (and NOT a rejecting one)?
approves(){ grep -qiE '\b(APPROVE|APPROVED|PASS|PASSED|\bGO\b)\b' "$1" && ! grep -qiE 'CHANGES_REQUESTED|\bFAIL(ED)?\b|NO-GO|\bblocker\b' "$1"; }

check_one(){ # <goldenfile>  (name: <critic>__<case>.txt)
  local f="$1" base case; base="$(basename "$f" .txt)"; case="${base##*__}"
  # SCHEMA: a recognizable verdict token must be present at all (else the orchestrator can't read the verdict)
  grep -qiE '\b(APPROVE|CHANGES_REQUESTED|PASS|FAIL|GO|NO-GO|UNVERIFIED|UNSURE)\b' "$f" \
    || { bad "$base: no parseable verdict token (broken output contract)"; return; }
  case "$case" in
    seeded-bug)  approves "$f" && bad "$base: GREEN-LIT a seeded bug (verdict approves a known-bad diff)" ;;
    clean)       approves "$f" || bad "$base: cried wolf on a CLEAN diff (no APPROVE/PASS verdict)"
                 grep -qiE '\bblocker\b' "$f" && bad "$base: raised a [blocker] on a clean diff (noise machine)" ;;
    backend)     if grep -qiE '\b(button|layout|colou?r|visual|accessib|copy text|user-facing|UX)\b' "$f" \
                    && ! grep -qiE 'no (user|ux|user-facing|visible)|not user-facing|backend[- ]only|out of scope|no findings|N/?A' "$f"; then
                   bad "$base: ux_reviewer invented user-surface findings on a BACKEND-only diff"; fi ;;
    no-evidence) grep -qiE '\b(UNVERIFIED|UNSURE)\b|insufficient (evidence|context)|cannot verify|no evidence' "$f" \
                   || bad "$base: GUESSED instead of abstaining (no UNVERIFIED/UNSURE on missing evidence)" ;;
    *)           : ;;   # unknown case → schema check only
  esac
}

if [ "$MODE" = capture ]; then
  command -v opencode >/dev/null 2>&1 || { echo "agent-goldens: opencode absent — nightly capture needs it + provider keys. SKIP."; exit 0; }
  mkdir -p "$SNAP"
  for pair in reviewer__seeded-bug reviewer__clean verifier__seeded-bug verifier__clean ux_reviewer__backend reviewer__no-evidence; do
    c="${pair%%__*}"; case="${pair##*__}"; d="$INP/$case.diff"; [ -f "$d" ] || { echo "skip $pair (no $d)"; continue; }
    opencode run --agent "$c" "Review this diff and emit ONLY your verdict block, verbatim.

$(cat "$d")" 2>/dev/null | scrub > "$SNAP/$pair.txt" && echo "captured $pair.txt"
  done
  echo "agent-goldens: captured. Review, then commit tests/snapshots/agents/*.txt (replaces the seeded examples with real ones)."
  exit 0
fi

# --- check ---
ls "$SNAP"/*.txt >/dev/null 2>&1 || { echo "agent-goldens: no goldens captured yet — nightly 'agent-goldens.sh --capture' seeds them (needs credits). SKIP."; exit 0; }
n=0
for f in "$SNAP"/*.txt; do check_one "$f"; n=$((n+1)); done
if [ "$fail" = 0 ]; then echo "agent-goldens: PASS ($n goldens — verdict schema + behavioural invariants hold)"; exit 0; fi
echo "agent-goldens: FAIL — a critic's behaviour regressed (see above). Re-run to confirm before acting (flake guard)."
exit 1
