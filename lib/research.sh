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
#
# Two more false positives, measured, both from the same mistake -- taking a word that appears in auth walls
# to BE an auth wall:
#   * `authenticate` was in the alternation with an open `( to .*)?` tail, so "Authenticate to the API —
#     Stripe" -> segment "authenticate to the api" -> flagged. That is the standard title of the auth page of
#     an API reference; Stripe, Twilio and Shopify all ship one, and it is exactly the page a spec cites when
#     it encodes an auth contract. `authenticate` is dropped entirely: an actual wall does not say
#     "Authenticate to the API", it says "Sign in".
#   * bare `login`/`signin` (one word, no separator) is a component/endpoint/route name -- `POST /login`,
#     "Login" in a component index -- far more often than it is a wall. A rendered sign-in wall writes it as
#     human UI phrasing with the separator: "Sign in", "Log in", "Sign in to GitHub". So the separator is now
#     REQUIRED. The recall this costs is a wall whose title is exactly the one word "Login"; the precision it
#     buys is every routing/component doc named after the endpoint. `register` is dropped for the same
#     reason (a register is a thing in a dozen domains).
# The `to ...` tail is bounded rather than `.*`: "Sign in to GitHub" is an announcement, a 60-character
# sentence starting with "Sign in to" is prose about signing in.
_RESEARCH_AUTHTITLE_RE='^(sign|log)[ -]in( to .{1,40})?$|^sign[ -]up$|^(page )?not found$|^40[0-9]([[:space:]]*[-–—:]?[[:space:]]*(forbidden|not found|unauthorized|error))?$|^(access )?(denied|forbidden|unauthorized)$|^error$'

# research_title_segment <title> — the first segment, before a site-name separator, trimmed and lowercased.
# "Sign in to GitHub · GitHub" -> "sign in to github";  "Error handling | Docs" -> "error handling".
research_title_segment() {
  printf '%s' "${1:-}" | sed -E 's/[[:space:]]*[|·—–][[:space:]]*.*$//' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr 'A-Z' 'a-z'
}

# research_url_host <url> — the host, lowercased, without `www.`, port or userinfo. Empty for a non-URL.
research_url_host() {
  printf '%s' "${1:-}" | tr 'A-Z' 'a-z' \
    | sed -E 's/^https?:\/\///; s/[\/?#].*$//; s/^[^@]*@//; s/:[0-9]+$//; s/^www\.//'
}

# research_site <url> — the registrable-ish domain: the last two labels, or three when the last two are a
# known two-part public suffix (co.uk, com.au, ...). NOT a full PSL — a full PSL is a downloadable list that
# would have to be shipped and refreshed, and the only decision riding on this is "is this redirect leaving
# the site the spec cited". Over-grouping (treating a.co.uk and b.co.uk as one site) loses a warning;
# under-grouping (docs.python.org vs python.org) would produce the false positive this whole layer exists to
# stop, so the bias is deliberately towards grouping.
research_site() {
  local h; h="$(research_url_host "${1:-}")"
  [ -n "$h" ] || return 0
  # SEPARATE `local` statements: in `local a=X b=${a}` the expansions all happen before any assignment, so
  # `second` was computed from an unset `rest` (and blew up under `set -u`).
  local last="${h##*.}"
  local rest="${h%.*}"
  local second="${rest##*.}"
  case "$last" in
    ??) case "$second" in co|com|org|net|ac|gov|edu|or|ne|in) printf '%s' "${h}" | grep -oE '[^.]+\.[^.]+\.[^.]+$'; return ;; esac ;;
  esac
  printf '%s' "$h" | grep -oE '[^.]+\.[^.]+$'
}

# research_same_site <a> <b> — 0 when both URLs live on the same registrable domain.
research_same_site() {
  local a b; a="$(research_site "${1:-}")"; b="$(research_site "${2:-}")"
  [ -n "$a" ] && [ "$a" = "$b" ]
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
#   dead      the server answered and the answer was 4xx/5xx, or the name does not exist (NXDOMAIN)
#   unchecked no curl, offline, or no HTTP answer at all (timeout, refused, TLS, proxy) — the honest
#             inconclusive state, never silently "live" AND never silently "dead"
research_url_status() {
  local url="$1" body code rc=0 transport=ok
  command -v curl >/dev/null 2>&1 || { printf 'unchecked'; return; }
  case "$url" in http://*|https://*) ;; *) printf 'unchecked'; return ;; esac

  # RANGE-limited, NOT --max-filesize: curl EXITS NON-ZERO when a filesize cap trips, and this function
  # read that as "dead". Measured: docs.firecrawl.dev is 1,009,550 bytes, so a real, reachable page was
  # reported as an invented URL -- precisely on the large documentation pages a spec is most likely to
  # cite. A range request bounds the transfer without turning size into an error; servers that ignore
  # Range still finish inside --max-time.
  body="$(curl -sL --max-time "${RESEARCH_URL_TIMEOUT:-8}" -r 0-65535 \
            -A "${RESEARCH_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36}" \
            -w '\n__CODE__%{http_code}__EFF__%{url_effective}' "$url" 2>/dev/null)" || rc=$?
  local eff="${body##*__EFF__}"
  body="${body%__EFF__*}"
  code="${body##*__CODE__}"
  body="${body%__CODE__*}"
  # Judge the STATUS, not curl's exit code: a truncated read is a successful read for our purposes, and
  # 206 Partial Content is the expected reply to the range request. So whenever an HTTP status came back,
  # rc is IGNORED -- that is still the rule the >1MB regression was fixed with.
  #
  # But rc was being thrown away even when NO status came back. Then http_code is `000`, and `000` was
  # falling into the 4xx/5xx branch as `dead` -- with a message accusing the author of an invented URL.
  # A timeout, a refused connection, a blackholed IP, a TLS handshake failure and a broken proxy ALL produce
  # exactly that, and not one of them is evidence about whether the URL is right. The file's own promise at
  # the top is that it says UNCHECKED when it cannot decide; it was deciding GUILTY instead.
  #
  # The one transport failure that IS evidence is NXDOMAIN (curl 6): the resolver gave a definitive negative
  # answer -- this name does not exist -- which is precisely the invented-hostname case, and unlike a timeout
  # it does not depend on the far end being up. It is only trustworthy while OUR resolver works, though: a
  # dead resolver, a captive portal or a VPN drop returns curl 6 for every host on the internet. So it is
  # corroborated against the cached research_online probe (a full DNS + TLS round trip to a host known to
  # exist); with no working resolver to compare against, NXDOMAIN degrades to unchecked.
  if [ "$rc" != 0 ]; then
    case "$rc" in
      6) if research_online; then transport=nxdomain; else transport=unreachable; fi ;;
      *) transport=unreachable ;;
    esac
  fi
  # Classification itself lives in research_classify so it can be tested offline.
  research_classify "$code" "$body" "$url" "$eff" "$transport"
}

# research_classify <http-code> <body> [<requested-url>] [<effective-url>] [<transport>]
#   -> live | blocked | authwall | redirected | dead | unchecked
# <transport> is what the fetch itself did, since http-code cannot express it:
#   ok           an HTTP response arrived (default; the code then decides everything)
#   nxdomain     the resolver says the host does not exist, on a resolver proven to work -> dead
#   unreachable  no HTTP response and no proof of anything: timeout, refused, TLS, proxy -> unchecked
# Split out from research_url_status so the RULES can be tested without a network round-trip. A test that
# re-implements the logic it is testing proves only that the copy agrees with itself.
research_classify() {
  local code="${1:-}" body="${2:-}" want="${3:-}" got="${4:-}" transport="${5:-}" title
  case "$code" in
    2*) ;;
    ''|000)
      # No HTTP status at all. Only a definitive "this host does not exist" convicts; everything else is
      # inconclusive, and the default with no transport information is inconclusive too.
      case "$transport" in
        nxdomain) printf 'dead'; return ;;
        *)        printf 'unchecked'; return ;;
      esac ;;
    *)  printf 'dead'; return ;;
  esac
  # A 2xx that reads like a challenge is NOT content. Only the first 4000 chars: a denial page is short and
  # says so up front, while a long legitimate document could mention "captcha" in passing.
  if grep -qiE "$_RESEARCH_DENY_RE" <<<"${body:0:4000}"; then printf 'blocked'; return; fi
  # LAYER: the TITLE announces an auth/error wall. A login page arrives at 200 with plenty of real text and
  # no denial phrase -- measured at 1249 chars -- so neither the status code nor the body regex sees it.
  title="$(grep -oiE '<title[^>]*>[^<]{0,120}' <<<"$body" | head -1 | sed -E 's/<title[^>]*>//I')"
  if [ -n "$title" ] && grep -qE "$_RESEARCH_AUTHTITLE_RE" <<<"$(research_title_segment "$title")"; then printf 'authwall'; return; fi

  # LAYER: we did not land where we asked -- but a redirect ALONE is not a failure, and treating it as one
  # flagged the most-cited documentation on the web. MEASURED, every one serving exactly the requested
  # document at the redirected path:
  #   developer.mozilla.org/docs/Web/HTTP/Status -> /en-US/docs/Web/HTTP/Reference/Status   (locale + reorg)
  #   docs.github.com/rest                       -> /en/rest                               (locale)
  #   docs.python.org/library/json.html          -> /3/library/json.html                    (version pin)
  #   www.rfc-editor.org/rfc/rfc7231             -> /info/rfc7231/                          (canonical form)
  # Locale prefixes, version pins and canonicalisation are how documentation sites NORMALLY serve a stable
  # URL, so "you get some other document" was flatly false for the commonest citation in any spec.
  #
  # What a redirect is, is a WEAK signal that needs corroboration. The corroborating signals are already
  # checked above and win before we get here: an auth TITLE (a redirect to a real sign-in wall lands on a
  # page titled "Sign in to X" -> authwall) and a denial BODY (-> blocked). What is left that a redirect can
  # decide on its own is leaving the SITE entirely: docs.acme.com/api -> unrelated-parking-domain.com is a
  # different publisher, and no locale/version scheme explains it.
  #
  # Deliberately NOT a separate non-failing `note` state: a same-site path change is the normal case, so
  # recording it would put a line in the provenance block of essentially every spec that cites MDN or
  # python.org -- and a warning that fires on everything is a warning nobody reads (the exact failure this
  # fix exists to undo). A same-site redirect is simply not evidence of anything, so it says nothing.
  if [ -n "$want" ] && [ -n "$got" ] && ! research_same_page "$want" "$got" \
     && ! research_same_site "$want" "$got"; then printf 'redirected'; return; fi

  # An empty 200 is not evidence of anything either.
  [ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || { printf 'blocked'; return; }
  printf 'live'
}

# research_url_status_cached <url> — research_url_status, but at most ONE fetch per URL per process.
#
# WHY: lib/swarm.sh runs research_write_provenance and then research_spec_sources over the SAME spec in the
# same lint pass, and each classified every cited URL independently -- 20 fetches for 12 URLs, and 64s of
# wall clock for one spec with 8 unreachable hosts, every one of them paying the full --max-time twice.
#
# The cache lives HERE rather than inside research_url_status on purpose, for two reasons. It keeps
# research_url_status a pure "go and fetch it" primitive that a test can stub to COUNT fetches (a cache
# inside it would be bypassed by the stub, so the saving could never be demonstrated). And it means no change
# is needed in swarm.sh: bash `< <(...)` forks, and a fork inherits the parent's variables, so the verdicts
# the writer records in the parent shell are already in the reader's environment.
#
# Process-scoped, never written to disk: the reuse must not outlive the lint pass. A verdict cached across
# runs would report yesterday's reachability as today's, which is the same "a check that did not run looks
# like a check that passed" failure this file exists to prevent.
#
# It returns its answer in the GLOBAL `_RESEARCH_STATUS` and prints NOTHING, which looks awkward and is not
# negotiable: `st="$(research_url_status_cached "$url")"` runs the function inside a command-substitution
# SUBSHELL, so every entry it wrote to the cache died with that subshell and the cache never hit once. The
# first version of this did exactly that and measured 16 fetches where it claimed 8. Callers must therefore
# use `research_url_status_cached "$url"; st="$_RESEARCH_STATUS"` and never `$(...)`.
research_url_status_cached() {
  declare -gA _RESEARCH_STATUS_CACHE 2>/dev/null || true
  local url="${1:-}"
  local hit="${_RESEARCH_STATUS_CACHE[$url]:-}"
  if [ -n "$hit" ]; then _RESEARCH_STATUS="$hit"; return 0; fi
  _RESEARCH_STATUS="$(research_url_status "$url")"
  _RESEARCH_STATUS_CACHE[$url]="$_RESEARCH_STATUS"
  return 0
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
    research_url_status_cached "$url"; st="$_RESEARCH_STATUS"
    case "$st" in
      live)      ;;
      blocked)   echo "SPECGAP $slug SRC_LIVE cited source is BLOCKED (denial/challenge page served with a success status): $url — mark the claim 'UNVERIFIED —' or cite a reachable source" ;;
      dead)      echo "SPECGAP $slug SRC_LIVE cited source is UNREACHABLE (the server answered 4xx/5xx, or the host does not exist): $url — invented URL, or the source moved" ;;
      authwall)  echo "SPECGAP $slug SRC_LIVE cited source is an AUTH/ERROR WALL (title: sign-in or error page, served at 200): $url — the content is not the document; mark 'UNVERIFIED —' or cite a public source" ;;
      redirected) echo "SPECGAP $slug SRC_LIVE cited source REDIRECTS OFF-SITE to a different domain: $url — check you get the document you meant, not a parked or replacement site" ;;
      # NOT an accusation: no HTTP answer came back at all, which says nothing about whether the URL is
      # right. Never the word "invented" here — that message on a timeout is what made this gate distrusted.
      unchecked) echo "SPECGAP $slug SRC_LIVE UNCHECKED — no HTTP response (timeout, refused, TLS or proxy failure); this is inconclusive, NOT evidence the URL is wrong: $url" ;;
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
# Bounded by RESEARCH_MAX_URLS exactly as research_spec_sources is. It was NOT: the writer had no `n >= max`
# break at all, so the bound advertised on the gate was enforced on one of the two passes and a spec citing
# 40 sources fetched all 40 here. The URLs past the bound are still RECORDED, as `unchecked` -- dropping them
# silently would leave the recipient reading a provenance file that looks complete and is not.
research_write_provenance() {
  local f="$1" slug pf url st n=0 bad=0 checked=0 skipped=0 max="${RESEARCH_MAX_URLS:-8}" trunc=''
  slug="$(basename "$f" .md)"; pf="$(_prov_file "$slug")"
  mkdir -p "$(dirname "$pf")" 2>/dev/null || return 0
  {
    printf '# provenance for %s — generated by spec-lint (SPEC_LINT_NET=1)\n' "$slug"
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      case "$url" in *localhost*|*127.0.0.1*|*example.com*|*your-domain*) continue ;; esac
      n=$((n+1))
      if [ "$checked" -ge "$max" ]; then
        skipped=$((skipped+1)); bad=$((bad+1)); printf 'unchecked\t%s\n' "$url"; continue
      fi
      checked=$((checked+1)); research_url_status_cached "$url"; st="$_RESEARCH_STATUS"
      [ "$st" = live ] || bad=$((bad+1))
      printf '%s\t%s\n' "$st" "$url"
    done < <(research_spec_urls "$f")
    if [ "$skipped" -gt 0 ]; then trunc=" — TRUNCATED at RESEARCH_MAX_URLS=$max, $skipped left unchecked"; fi
    # UNVERIFIED lines the AUTHOR wrote are provenance too, and the most honest kind.
    grep -nE 'UNVERIFIED[[:space:]]*[—-]' "$f" 2>/dev/null | while IFS= read -r l; do
      printf 'author-unverified\t%s\n' "${l:0:160}"
    done
    printf 'SUMMARY\t%s cited source(s), %s not confirmed live%s\n' "$n" "$bad" "$trunc"
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
