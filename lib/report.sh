#!/usr/bin/env bash
# report.sh — generalized "file-it-so-it-gets-fixed" channel.
#
# Extends the rathole self-fix pattern (lib/scaffold.sh ace_self_fix) so ANY part
# of ACE — the swarm, CI, security checks, the loop — can report a CATEGORIZED
# issue, and one triage pass files ONE deduped GitHub issue per (category,target)
# with an apt label. Same guarantees as the rathole flow:
#   • FILE, don't fix — a human/loop fixes the code; this only opens an issue.
#   • mechanical dedup by fingerprint (same root cause → one issue).
#   • deterministic — bash files the issue, never left to a model.
#
#   ace_report CATEGORY TARGET SUMMARY [DETAIL]   # TARGET = ace | repo | owner/name
#   ace_triage                                    # drain queue → file issues
#
# ACE_REPORT_DRY=1 prints what it WOULD file (tests, no GitHub writes).

REPORT_QUEUE="${ACE_REPORT_QUEUE:-$HOME/.config/ace/ace-report.log}"
REPORT_LEDGER="${ACE_REPORT_LEDGER:-$HOME/.config/ace/ace-report-filed.log}"
FIXME_QUEUE="${ACE_FIXME:-$HOME/.config/ace/ace-fixme.log}"   # legacy rathole queue (subsumed)

_rp_slug(){ gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null; }
_rp_branch(){ git rev-parse --abbrev-ref HEAD 2>/dev/null; }

ace_report() {
  local cat="${1:?category}" target="${2:?target}" summary="${3:?summary}" detail="${4:-}"
  mkdir -p "$(dirname "$REPORT_QUEUE")" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Is)" "$cat" "$target" "$(_rp_slug):$(_rp_branch)" \
    "$(printf '%s' "$summary" | tr '\t\n' '  ')" \
    "$(printf '%s' "$detail" | tr '\t\n' '  ')" >> "$REPORT_QUEUE" 2>/dev/null || true
}

_rp_target_slug() {
  case "$1" in
    ace)   local d="${ACE_DIR:-$(dirname "$(readlink -f "$(command -v ace 2>/dev/null)" 2>/dev/null)" 2>/dev/null)}"
           ( cd "$d" 2>/dev/null && _rp_slug ) ;;
    repo)  _rp_slug ;;
    */*)   printf '%s' "$1" ;;
    *)     _rp_slug ;;
  esac
}
_rp_label() { case "$1" in
  rathole|swarm-tooling) echo ace-self-fix ;;
  swarm-*)               echo swarm-blocked ;;
  ci-*|flake)            echo ci-flake ;;
  security|sec-*)        echo security ;;
  *)                     echo ace-report ;; esac; }

ace_triage() {
  local dry="${ACE_REPORT_DRY:-0}"
  # subsume legacy rathole notes: rewrite them into the unified queue.
  if [ -s "$FIXME_QUEUE" ]; then
    while IFS=$'\t' read -r ts rb diag; do
      [ -z "$ts" ] && continue
      printf '%s\trathole\tace\t%s\t%s\t\n' "$ts" "${rb:-?}" "$(printf '%s' "$diag" | tr '\t\n' '  ')" >> "$REPORT_QUEUE"
    done < "$FIXME_QUEUE"
    mv -f "$FIXME_QUEUE" "$FIXME_QUEUE.migrated.$(date +%s)" 2>/dev/null || : > "$FIXME_QUEUE"
  fi
  [ -s "$REPORT_QUEUE" ] || { echo "ace-triage: nothing queued."; return 0; }
  [ "$dry" = 1 ] || command -v gh >/dev/null 2>&1 || { echo "ace-triage: gh missing — queue kept at $REPORT_QUEUE."; return 1; }
  mkdir -p "$(dirname "$REPORT_LEDGER")"; touch "$REPORT_LEDGER"
  local cat target lines fp slug label title body url n=0
  while IFS=$'\t' read -r cat target; do
    [ -z "$cat" ] && continue
    # all summaries for this (category,target) group
    lines="$(awk -F'\t' -v c="$cat" -v t="$target" '$2==c && $3==t {print $1"  ["$4"]  "$5 ($6!=""?"  — "$6:"")}' "$REPORT_QUEUE")"
    [ -n "$lines" ] || continue
    fp="$(printf '%s|%s|%s' "$cat" "$target" "$(awk -F'\t' -v c="$cat" -v t="$target" '$2==c && $3==t {print $5}' "$REPORT_QUEUE" | sort -u)" | sha1sum 2>/dev/null | cut -c1-12)"
    if grep -qxF "$fp" "$REPORT_LEDGER" 2>/dev/null; then echo "  skip $cat→$target (already filed, fp=$fp)"; continue; fi
    slug="$(_rp_target_slug "$target")"; label="$(_rp_label "$cat")"
    title="[$cat] $(awk -F'\t' -v c="$cat" -v t="$target" '$2==c && $3==t {print $5}' "$REPORT_QUEUE" | tail -1 | cut -c1-72)"
    body="$(printf '## %s — reported by the ACE loop\n\n```\n%s\n```\n\n## Triage (the loop FILES; a human/loop fixes the code)\n- [ ] Root cause (function + file:line)\n- [ ] Proposed fix\n- [ ] Risk if unfixed\n\n_fingerprint: %s_\n' "$cat" "$lines" "$fp")"
    n=$((n+1))
    if [ "$dry" = 1 ]; then
      echo "  [DRY] file → repo=${slug:-<none>} label=$label  title=\"$title\""
    else
      [ -n "$slug" ] || { echo "  no repo for target=$target — kept queued"; continue; }
      gh label create "$label" >/dev/null 2>&1 || true
      url="$( ( [ "$target" = ace ] && cd "${ACE_DIR:-$(dirname "$(readlink -f "$(command -v ace)")")}" 2>/dev/null; \
              gh issue create --repo "$slug" --title "$title" --label "$label" --body "$body" 2>/dev/null \
                || gh issue create --repo "$slug" --title "$title" --body "$body" 2>/dev/null ) )"
      [ -n "$url" ] && { echo "  filed $url"; printf '%s\n' "$fp" >> "$REPORT_LEDGER"; } || echo "  gh error for $cat→$target (kept queued)"
    fi
  done < <(awk -F'\t' 'NF>=3 {print $2"\t"$3}' "$REPORT_QUEUE" | sort -u)
  [ "$dry" = 1 ] || mv -f "$REPORT_QUEUE" "$REPORT_QUEUE.done.$(date +%s)" 2>/dev/null
  echo "ace-triage: $n group(s)$([ "$dry" = 1 ] && echo ' (dry-run — nothing filed)')."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    report) shift; ace_report "$@" ;;
    triage) ace_triage ;;
    *) echo "usage: report.sh {report CATEGORY TARGET SUMMARY [DETAIL] | triage}" >&2; exit 2 ;;
  esac
fi
