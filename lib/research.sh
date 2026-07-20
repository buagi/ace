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

# A TITLE that announces an auth wall. Title-scoped ON PURPOSE: bodies mention "sign in" everywhere (every
# nav bar has a link), so a body-scoped rule would flag half the web. A <title> of "Sign in to GitHub" is
# decisive. Measured: github.com/settings/profile returns 200 with 1249 chars and exactly this title.
# An auth/error wall's title IS the announcement ("Sign in to GitHub"); a documentation page's title is a
# TOPIC ("Error handling", "Login flow design notes", "404 pages: best practice"). So the phrase must fill
# the WHOLE first title segment, not merely start it. A prefix match flagged all three of those real pages
# and still missed "Page Not Found" -- too loose and too tight at once.
_RESEARCH_AUTHTITLE_RE='^(sign ?in|log ?in|signin|login|sign ?up|register|authenticate)( to .*)?$|^(page )?not found$|^40[0-9]([[:space:]]*[-–—:]?[[:space:]]*(forbidden|not found|unauthorized|error))?$|^(access )?(denied|forbidden|unauthorized)$|^error$'

# research_title_segment <title> — the first segment, before a site-name separator, trimmed and lowercased.
# "Sign in to GitHub · GitHub" -> "sign in to github";  "Error handling | Docs" -> "error handling".
research_title_segment() {
  printf '%s' "${1:-}" | sed -E 's/[[:space:]]*[|·—–][[:space:]]*.*$//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z'
}

# research_same_page <requested> <effective> — 0 when the effective URL is the SAME document.
# Normalises the differences that carry no meaning: scheme, a trailing slash, a leading www, case in the
# host, and the fragment. Everything else -- a changed PATH above all -- means a different document.
# Without this, example.com -> example.com/ would read as a redirect and flag every clean fetch.
research_same_page() {
  # LOWERCASE FIRST: stripping `www.` before folding case left "WWW.Example.com" intact, so a purely
  # cosmetic host difference read as a redirect — which would have flagged clean fetches as failures.
  _rn(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/^https?:\/\///; s/#.*$//; s/^www\.//; s/\/+$//'; }
  [ "$(_rn "${1:-}")" = "$(_rn "${2:-}")" ]
}

# research_url_status <url> -> prints: live | blocked | authwall | redirected | dead | unchecked
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
            -w '\n__CODE__%{http_code}__EFF__%{url_effective}' "$url" 2>/dev/null)"
  local eff="${body##*__EFF__}"
  body="${body%__EFF__*}"
  code="${body##*__CODE__}"
  body="${body%__CODE__*}"
  # Judge the STATUS, not curl's exit code: a truncated read is a successful read for our purposes.
  # 206 Partial Content is the expected reply to the range request. Classification itself lives in
  # research_classify so it can be tested offline.
  research_classify "$code" "$body" "$url" "$eff"
}

# research_classify <http-code> <body> -> live | blocked | dead
# Split out from research_url_status so the RULES can be tested without a network round-trip. A test that
# re-implements the logic it is testing proves only that the copy agrees with itself.
research_classify() {
  local code="${1:-}" body="${2:-}" want="${3:-}" got="${4:-}" title
  case "$code" in
    2*) ;;
    *)  printf 'dead'; return ;;
  esac
  # A 2xx that reads like a challenge is NOT content. Only the first 4000 chars: a denial page is short and
  # says so up front, while a long legitimate document could mention "captcha" in passing.
  if grep -qiE "$_RESEARCH_DENY_RE" <<<"${body:0:4000}"; then printf 'blocked'; return; fi
  # LAYER: the TITLE announces an auth/error wall. A login page arrives at 200 with plenty of real text and
  # no denial phrase -- measured at 1249 chars -- so neither the status code nor the body regex sees it.
  title="$(grep -oiE '<title[^>]*>[^<]{0,120}' <<<"$body" | head -1 | sed -E 's/<title[^>]*>//I')"
  if [ -n "$title" ] && grep -qE "$_RESEARCH_AUTHTITLE_RE" <<<"$(research_title_segment "$title")"; then printf 'authwall'; return; fi

  # LAYER: we did not land where we asked. A redirect to a DIFFERENT path means the content is some other
  # document -- a login page, a generic landing page, a consent wall -- however genuine it looks.
  if [ -n "$want" ] && [ -n "$got" ] && ! research_same_page "$want" "$got"; then printf 'redirected'; return; fi

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
      authwall)  echo "SPECGAP $slug SRC_LIVE cited source is an AUTH/ERROR WALL (title: sign-in or error page, served at 200): $url — the content is not the document; mark 'UNVERIFIED —' or cite a public source" ;;
      redirected) echo "SPECGAP $slug SRC_LIVE cited source REDIRECTS to a different page (you get some other document, however genuine it looks): $url" ;;
      unchecked) echo "SPECGAP $slug SRC_LIVE UNCHECKED — could not verify: $url" ;;
    esac
  # Trailing punctuation is NOT part of the URL. `(source: https://x.org/, daily bars)` captured the comma,
  # so a perfectly good citation resolved to a 404 and was reported as an invented URL -- the exact
  # false positive that makes a gate untrustworthy.
  done < <(research_spec_urls "$f")
  return 0
}

# ---------------------------------------------------------------------------------------------------
# PROVENANCE — carry the uncertainty to whoever ACTS on the claim.
#
# The checks above decide whether a cited source is reachable. That verdict was going nowhere: the
# implementer receives a SLICE (§3 Scope, the increment's ACs, C1 contract shapes, C5) and no indication
# that a contract shape might rest on a source nobody could read. And the residual class -- content that is
# plausible but wrong, a soft 404 at 200 with a normal title and no redirect -- is undetectable by any
# mechanical layer, so the ONLY protection is that the recipient is told what the claim rests on.
#
# Written ONCE at lint time (network) and read at slice time (no network), so assembling a slice stays
# offline-safe and instant.

_prov_file() { printf '%s/.opencode/cache/provenance-%s.txt' "${REPO:-$PWD}" "$1"; }

# research_write_provenance <spec> — classify every cited source and record the verdict beside the spec.
research_write_provenance() {
  local f="$1" slug pf url st n=0 bad=0
  slug="$(basename "$f" .md)"; pf="$(_prov_file "$slug")"
  mkdir -p "$(dirname "$pf")" 2>/dev/null || return 0
  {
    printf '# provenance for %s — generated by spec-lint (SPEC_LINT_NET=1)\n' "$slug"
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      case "$url" in *localhost*|*127.0.0.1*|*example.com*|*your-domain*) continue ;; esac
      n=$((n+1)); st="$(research_url_status "$url")"
      [ "$st" = live ] || bad=$((bad+1))
      printf '%s\t%s\n' "$st" "$url"
    done < <(research_spec_urls "$f")
    # UNVERIFIED lines the AUTHOR wrote are provenance too, and the most honest kind.
    grep -nE 'UNVERIFIED[[:space:]]*[—-]' "$f" 2>/dev/null | while IFS= read -r l; do
      printf 'author-unverified\t%s\n' "${l:0:160}"
    done
    printf 'SUMMARY\t%s cited source(s), %s not confirmed live\n' "$n" "$bad"
  } > "$pf" 2>/dev/null
  return 0
}

# research_provenance_block <spec> — the human/agent-facing block for a slice. Prints NOTHING when every
# source is live and the author marked nothing unverified: a clean spec should not carry noise. But when a
# spec was never checked, it says SO -- silence must never be mistakable for "verified".
research_provenance_block() {
  local f="$1" slug pf
  slug="$(basename "$f" .md)"; pf="$(_prov_file "$slug")"
  if [ ! -f "$pf" ]; then
    # A spec whose sources cite the outside world but were never verified is exactly the case the recipient
    # must hear about. A spec that cites nothing external needs no warning.
    if research_spec_urls "$f" 2>/dev/null | grep -q .; then
      printf '\n## ⚠ SOURCE PROVENANCE — NOT VERIFIED\n'
      printf 'This spec cites external sources that were NEVER checked (spec-lint ran without SPEC_LINT_NET=1).\n'
      printf 'Treat every claim about a third-party system as an ASSUMPTION, not a fact: validate it against the\n'
      printf 'real system before encoding it in a contract, and say so in your report if you could not.\n'
      research_spec_urls "$f" 2>/dev/null | sed 's/^/  unchecked: /'
    fi
    return 0
  fi
  # A literal TAB, not '\t': GNU grep -E has no \t escape, so the exclusions silently matched nothing and
  # the SUMMARY line was counted as a failed source ("2 claims" for one blocked URL).
  local TAB bad; TAB="$(printf '\t')"
  bad="$(grep -cvE "^(live${TAB}|#|SUMMARY${TAB})" "$pf" 2>/dev/null || true)"; bad="${bad:-0}"
  [ "${bad:-0}" -gt 0 ] || return 0
  printf '\n## ⚠ SOURCE PROVENANCE — %s claim(s) rest on sources that could NOT be confirmed\n' "$bad"
  printf 'A blocked, redirected, auth-walled or dead source means the content behind that citation was never\n'
  printf 'read. Worse, a fetch can succeed and still return the WRONG document (a generic page at HTTP 200),\n'
  printf 'which no check can detect — so treat these as ASSUMPTIONS and validate before encoding them.\n'
  grep -vE "^(live${TAB}|#|SUMMARY${TAB})" "$pf" 2>/dev/null | sed 's/^/  /'
}
