#!/usr/bin/env bash
# research.sh — verify that a spec's EXTERNAL citations point at something real and readable.
#
# WHY THIS EXISTS
# spec-lint already proves in-repo claims: CITED demands `(cites path:L..)` and CITE_REAL proves the path
# exists. External claims had no equivalent, so a fabricated API contract passed every gate in the project.
#
# Then the failure mode got worse. Firecrawl CLOUD returns HTTP 200 with `"success": true` for a page whose
# body is "Access denied" -- measured against stooq.com, which blocks by IP reputation below the JS layer.
# The self-hosted engine at least errored loudly; the cloud one hands back a denial page as if it were
# content. An agent cannot tell the difference, and neither could anything downstream.
#
# WHAT ACE CAN AND CANNOT SEE (measured, not assumed): tool-call failures are NOT captured in any ACE log --
# not last-run.log, not a session DB. The error is printed to the TUI and lost. So there is no way to audit
# research after the fact from the run. The only durable artifact is the SPEC, so that is what gets checked.
#
# Deliberately NOT a scraper: one bounded GET per cited URL. If it cannot decide, it says UNCHECKED -- never
# "fine" (C1: a check that did not run must not look like a check that passed).

# Denial/challenge bodies that arrive with a 2xx status. This list is the whole point of the file: status
# code alone is worthless when the block is served as a successful page.
_RESEARCH_DENY_RE='access denied|requires javascript|enable javascript|just a moment|checking your browser|verify you are human|are you a robot|captcha|cf-browser-verification|attention required|request blocked|rate limit exceeded|too many requests|403 forbidden|unusual traffic'

# research_url_status <url> -> prints: live | blocked | dead | unchecked
#   live      2xx and the body does not look like a denial/challenge page
#   blocked   reachable but served a denial/challenge (INCLUDING a 200 that says "Access denied")
#   dead      4xx/5xx, DNS failure, connection refused
#   unchecked no curl, or offline — the honest inconclusive state, never silently "live"
research_url_status() {
  local url="$1" body code
  command -v curl >/dev/null 2>&1 || { printf 'unchecked'; return; }
  case "$url" in http://*|https://*) ;; *) printf 'unchecked'; return ;; esac

  # RANGE-limited, NOT --max-filesize: curl EXITS NON-ZERO when a filesize cap trips, and this function
  # read that as "dead". Measured: docs.firecrawl.dev is 1,009,550 bytes, so a real, reachable page was
  # reported as an invented URL -- precisely on the large documentation pages a spec is most likely to
  # cite. A range request bounds the transfer without turning size into an error; servers that ignore
  # Range still finish inside --max-time.
  body="$(curl -sL --max-time "${RESEARCH_URL_TIMEOUT:-8}" -r 0-65535 \
            -A "${RESEARCH_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36}" \
            -w '\n__CODE__%{http_code}' "$url" 2>/dev/null)"
  code="${body##*__CODE__}"
  body="${body%__CODE__*}"
  # Judge the STATUS, not curl's exit code: a truncated read is a successful read for our purposes.
  # 206 Partial Content is the expected reply to the range request. Classification itself lives in
  # research_classify so it can be tested offline.
  research_classify "$code" "$body"
}

# research_classify <http-code> <body> -> live | blocked | dead
# Split out from research_url_status so the RULES can be tested without a network round-trip. A test that
# re-implements the logic it is testing proves only that the copy agrees with itself.
research_classify() {
  local code="${1:-}" body="${2:-}"
  case "$code" in
    2*) ;;
    *)  printf 'dead'; return ;;
  esac
  # A 2xx that reads like a challenge is NOT content. Only the first 4000 chars: a denial page is short and
  # says so up front, while a long legitimate document could mention "captcha" in passing.
  if grep -qiE "$_RESEARCH_DENY_RE" <<<"${body:0:4000}"; then printf 'blocked'; return; fi
  # An empty 200 is not evidence of anything either.
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || { printf 'blocked'; return; }
  printf 'live'
}

# research_online — one cheap probe so a whole offline run does not report every source as dead.
# Cached per process: an offline laptop must not pay a timeout per cited URL.
research_online() {
  case "${_RESEARCH_ONLINE:-}" in 0) return 1 ;; 1) return 0 ;; esac
  if curl -sL --max-time 5 -o /dev/null "https://example.com" 2>/dev/null; then _RESEARCH_ONLINE=1; return 0; fi
  _RESEARCH_ONLINE=0; return 1
}

# research_spec_urls <spec> -> the URLs a spec presents as EVIDENCE, one per line, cleaned.
# Its own function so the test exercises THIS code rather than a copy of it: the first version of the test
# re-implemented the grep/sed inline, so deleting the punctuation strip here left the test green.
research_spec_urls() {
  # Trailing punctuation is NOT part of the URL. `(source: https://x.org/, daily bars)` captured the comma,
  # so a perfectly good citation resolved to a 404 and was reported as an invented URL -- the exact kind of
  # false positive that makes a gate untrustworthy enough to be switched off.
  grep -oE '\((source|cites):[^)]*https?://[^ )]+' "$1" 2>/dev/null \
    | grep -oE 'https?://[^ )]+' | sed -E 's/[[:punct:]]+$//' | sort -u
}

# research_spec_sources <spec> -> emits `SPECGAP <slug> SRC_LIVE <detail>` lines, spec-lint's own format.
# Bounded by RESEARCH_MAX_URLS (default 8) per spec: this runs inside a gate, not a crawl.
research_spec_sources() {
  local f="$1" slug url st n=0 max="${RESEARCH_MAX_URLS:-8}"
  slug="$(basename "$f" .md)"
  [ -f "$f" ] || return 0
  if ! research_online; then
    echo "SPECGAP $slug SRC_LIVE UNCHECKED — offline, external citations not verified (inconclusive, not clean)"
    return 0
  fi
  # Only URLs presented as EVIDENCE — inside `(source: …)` or `(cites …)`. A URL that is merely a config
  # value or an example (`https://localhost:5000`) is not a claim about the world and must not be fetched.
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in *localhost*|*127.0.0.1*|*example.com*|*your-domain*) continue ;; esac
    [ "$n" -ge "$max" ] && { echo "SPECGAP $slug SRC_LIVE UNCHECKED — more than $max cited sources; verified the first $max only"; break; }
    n=$((n+1))
    st="$(research_url_status "$url")"
    case "$st" in
      live)      ;;
      blocked)   echo "SPECGAP $slug SRC_LIVE cited source is BLOCKED (denial/challenge page served with a success status): $url — mark the claim 'UNVERIFIED —' or cite a reachable source" ;;
      dead)      echo "SPECGAP $slug SRC_LIVE cited source is UNREACHABLE (4xx/5xx/DNS): $url — invented URL, or the source moved" ;;
      unchecked) echo "SPECGAP $slug SRC_LIVE UNCHECKED — could not verify: $url" ;;
    esac
  # Trailing punctuation is NOT part of the URL. `(source: https://x.org/, daily bars)` captured the comma,
  # so a perfectly good citation resolved to a 404 and was reported as an invented URL -- the exact
  # false positive that makes a gate untrustworthy.
  done < <(research_spec_urls "$f")
  return 0
}
