#!/usr/bin/env bash
# research-honesty-selftest — pins the external-claim checks.
#
# THE DEFECT, MEASURED: Firecrawl CLOUD returns HTTP 200 with "success": true for a body that reads
# "Access denied" (stooq.com, which blocks by IP reputation below the JS layer). The self-hosted engine at
# least errored; the cloud one hands a denial page back as content. Neither the agent that cites it nor
# anything downstream could tell -- spec-lint proved in-repo paths (CITE_REAL) and nothing at all about
# claims concerning the outside world.
#
# ALSO PINS THE PRECISION, because two false positives were found while writing this and either would have
# made the gate untrustworthy enough to be switched off:
#   * --max-filesize makes curl EXIT NON-ZERO, so a 1,009,550-byte real docs page read as "dead"
#   * `(source: https://x.org/, note)` captured the trailing comma, so a valid citation 404'd
#
# Network tests are SKIPPED (not failed, and not silently passed) when offline.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
# shellcheck disable=SC1091
. lib/research.sh 2>/dev/null || { echo "research-honesty-selftest: cannot source lib/research.sh"; exit 1; }

fail=0; skipped=0
bad(){ echo "FAIL: $*"; fail=1; }

# --- offline-safe: classification logic, no network ------------------------------------------------------
# Exercised through a stubbed curl so the denial-detection rule is pinned even in a sandbox with no egress.
# Rules are tested through research_classify — the real function, no re-implementation.
for c in "200|Access denied|blocked" \
         "200|<html>This site requires JavaScript to verify your browser|blocked" \
         "200|Just a moment... checking your browser|blocked" \
         "200|Please complete the captcha to continue|blocked" \
         "200|Attention Required! Cloudflare|blocked" \
         "200||blocked" \
         "206|Date,Open,High,Low,Close,Volume|live" \
         "200|Date,Open,High,Low,Close,Volume|live" \
         "404|Not Found|dead" \
         "403|nope|dead" \
         "500|oops|dead"; do
  IFS='|' read -r code body want <<<"$c"
  got="$(research_classify "$code" "$body")"
  [ "$got" = "$want" ] || bad "research_classify(code=$code body='${body:0:28}') = $got, want $want"
done

# --- D2: a fetch that produced NO HTTP STATUS must be UNCHECKED, never dead --------------------------------
# THE DEFECT, MEASURED: research_url_status threw away curl's exit code, so a timeout, a refused connection,
# a blackholed IP, a TLS handshake failure, a broken proxy and a DNS failure ALL arrived here as http_code
# `000` -- and `000` fell into the 4xx/5xx branch as `dead`, whose message accuses the author of an invented
# URL. The header of lib/research.sh promises "If it cannot decide, it says UNCHECKED -- never 'fine'". It
# was deciding GUILTY when it could not decide, which is the same lie in the other direction.
# The ONE transport failure that is evidence is NXDOMAIN on a working resolver: a definitive "this name does
# not exist" IS the invented-hostname case. Everything else is inconclusive, including an absent verdict.
for c in "000||unreachable|unchecked" \
         "000||ok|unchecked" \
         "000|||unchecked" \
         "000||nxdomain|dead" \
         "404|Not Found|ok|dead" \
         "404|Not Found|unreachable|dead" \
         "200|real docs|unreachable|live"; do
  IFS='|' read -r code body tr want <<<"$c"
  got="$(research_classify "$code" "$body" '' '' "$tr")"
  [ "$got" = "$want" ] || bad "research_classify(code=$code transport='$tr') = $got, want $want"
done
# The message the author reads must not accuse them. `unchecked` on a timeout saying "invented URL" is what
# made this gate distrusted; assert against the REAL emitter, not a copy of its strings.
_ud="$(mktemp -d)"; printf '# Spec: u\n- a (source: https://timeout.example.net/a, x)\n' > "$_ud/u.md"
und="$( set --; . lib/research.sh >/dev/null 2>&1
        research_online(){ return 0; }
        research_url_status(){ printf unchecked; }
        research_spec_sources "$_ud/u.md" 2>/dev/null )"
rm -rf "$_ud"
grep -q 'UNCHECKED' <<<"$und" || bad "an unchecked source produced no UNCHECKED line: [$und]"
grep -qi 'invented' <<<"$und" && bad "the SRC_LIVE message for an UNCHECKED source still says 'invented URL' — a timeout is not evidence the author made the URL up"

# A denial phrase deep inside a LONG legitimate document must NOT flag it: only the first 4000 chars are
# examined, because a real page can discuss captchas without being one.
long="$(printf 'Legitimate documentation. %.0s' $(seq 1 300))captcha"
[ "$(research_classify 200 "$long")" = live ] || bad "a long legitimate doc mentioning 'captcha' late was misclassified as blocked"

# --- AUTH-WALL + REDIRECT layers (offline, via the real classifier) --------------------------------------
# A login wall arrives at HTTP 200 with 1249 chars of genuine text and no denial phrase, so neither the
# status code nor the body regex sees it. Two mechanical signals do: the TITLE, and landing on a different
# path than requested.
_html(){ printf '<html><head><title>%s</title></head><body>%s</body></html>' "$1" "genuine looking documentation body text"; }

# D3 — THE FULL PRECISION/RECALL TABLE for the title rule. Every row is a real title shape. The rule has
# been wrong in both directions twice, so both directions are pinned here in one place.
#
# RECALL: real walls must be caught.
for t in "Sign in to GitHub · GitHub" "Log in — Example" "Page Not Found" "Sign in" "Unauthorized" \
         "Sign in to GitLab" "Log in" "404 Not Found" "Forbidden" "Error" "Not Found"; do
  # ("Access Denied" belongs to the BODY rule, not this one — it is classified `blocked` a few blocks up.)
  [ "$(research_classify 200 "$(_html "$t")" 'https://x.test/p' 'https://x.test/p')" = authwall ] \
    || bad "auth/error wall title not caught: '$t'"
done

# PRECISION: a docs page whose TOPIC is auth or errors must NOT be flagged. A prefix match cannot tell an
# announcement from a topic, and the words in an auth wall are also the words in the docs ABOUT auth.
#   "Authenticate to the API — Stripe" was flagged: `authenticate` sat in the alternation with an open
#   `( to .*)?` tail. That is the standard title of the auth page of an API reference (Stripe, Twilio and
#   Shopify all ship one) — i.e. precisely the page a spec cites when it encodes an auth contract, so the
#   check was at its least reliable exactly where it mattered most.
#   Bare "Login" was flagged: one word with no separator is an endpoint/route/component name (`POST /login`)
#   far more often than it is a wall, which writes it as human UI phrasing ("Sign in", "Log in").
for t in "Error handling | Firecrawl Docs" "Login flow design notes" "404 pages: best practice" \
         "Sign-in UX patterns (blog)" "Errors and retries — API reference" \
         "Authenticate to the API — Stripe" "Authenticate to the API" "Authentication" "Login" "Signin" \
         "Register a webhook" "Sign up flow — design system" "Not found errors explained" \
         "Error codes | Twilio Docs" "Login (component)"; do
  got="$(research_classify 200 "$(_html "$t")" 'https://x.test/p' 'https://x.test/p')"
  [ "$got" = live ] || bad "legitimate docs page flagged as '$got' by its title: '$t'"
done

# --- D1: a REDIRECT ALONE IS NOT A FAILURE ----------------------------------------------------------------
# THE DEFECT, MEASURED LIVE: `redirected` fired whenever the effective path differed, and told the author
# "you get some other document, however genuine it looks". All four of these serve exactly the requested
# document, and they are among the most-cited URLs on the web:
#   developer.mozilla.org/docs/Web/HTTP/Status -> /en-US/docs/Web/HTTP/Reference/Status
#   docs.github.com/rest -> /en/rest · docs.python.org/library/json.html -> /3/library/json.html
#   www.rfc-editor.org/rfc/rfc7231 -> /info/rfc7231/
# Locale prefixes, version pins and canonicalisation are how docs sites NORMALLY serve a stable URL.
# Pinned offline as URL pairs so the rule holds without egress; the live end-to-end check is further down.
for pair in "https://developer.mozilla.org/docs/Web/HTTP/Status|https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status" \
            "https://docs.github.com/rest|https://docs.github.com/en/rest" \
            "https://docs.python.org/library/json.html|https://docs.python.org/3/library/json.html" \
            "https://www.rfc-editor.org/rfc/rfc7231|https://www.rfc-editor.org/info/rfc7231/" \
            "https://docs.acme.io/api|https://docs.acme.io/v2/en/api" \
            "https://acme.io/docs|https://docs.acme.io/docs" \
            "https://example.com|https://example.com/" \
            "http://example.com/a|https://example.com/a" \
            "https://WWW.Example.com/a|https://example.com/a" \
            "https://example.com/a|https://example.com/a#frag"; do
  w="${pair%|*}"; g="${pair#*|}"
  [ "$(research_classify 200 "$(_html 'Docs')" "$w" "$g")" = live ] \
    || bad "a same-site redirect was reported as a failure ($w -> $g) — this flags the most-cited docs on the web"
done

# ...but leaving the SITE is still reported: no locale or version scheme explains a different publisher.
for pair in "https://docs.acme.com/api|https://parked-domain.example.net/" \
            "https://good-docs.org/spec|https://ad-network.io/lp?ref=1"; do
  w="${pair%|*}"; g="${pair#*|}"
  [ "$(research_classify 200 "$(_html 'Docs')" "$w" "$g")" = redirected ] \
    || bad "a CROSS-HOST redirect to an unrelated domain was not reported ($w -> $g)"
done

# And a redirect to a GENUINE auth wall is still caught — by the corroborating signal (the title), which is
# what makes it a real verdict rather than a guess. github.com/settings/profile -> /login, measured: 200,
# 1249 chars, title "Sign in to GitHub".
[ "$(research_classify 200 "$(_html 'Sign in to GitHub · GitHub')" 'https://github.com/settings/profile' 'https://github.com/login?return_to=x')" = authwall ] \
  || bad "a redirect to a real sign-in wall is no longer caught — dropping the bare-redirect rule must not cost this"
# Corroboration by BODY works the same way.
[ "$(research_classify 200 '<html><title>Docs</title>Access denied</html>' 'https://a.test/doc' 'https://a.test/other')" = blocked ] \
  || bad "a redirect that lands on a denial body is no longer caught"

# --- citation extraction: precision, no network ----------------------------------------------------------
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
cat > "$d/s.md" <<'MD'
# Spec: s (slug: s · risk: LOW · tier: FAST)
## 2. Prior art
- feed (source: https://real.example.net/docs, daily bars)
- local dev uses https://localhost:5000/v1/api as the gateway
- config value `GUIDE_URL = "https://github.com/Voyz/ibeam"`
MD
# Calls the REAL extractor. The first version inlined the grep/sed, so deleting the punctuation strip in
# lib/research.sh left this green — a test that re-implements its subject proves only self-consistency.
urls="$(research_spec_urls "$d/s.md")"
grep -q '^https://real.example.net/docs$' <<<"$urls" || bad "cited URL not extracted cleanly (trailing punctuation?): [$urls]"
grep -q 'localhost' <<<"$urls" && bad "a localhost EXAMPLE was treated as a cited source — it is a config value, not a claim"
grep -q 'ibeam'     <<<"$urls" && bad "a bare URL used as a config VALUE was treated as a cited source — only (source:|cites:) count"

# --- network-dependent: the real classification end to end -----------------------------------------------
if research_online; then
  [ "$(research_url_status 'https://example.com')" = live ] \
    || bad "example.com did not classify as live — the checker is broken or the network is lying"
  # Regression pin for the --max-filesize bug: a >1MB real page must be live, not dead.
  st="$(research_url_status 'https://docs.firecrawl.dev/contributing/self-host')"
  [ "$st" = live ] || bad "a large (>1MB) REAL docs page classified as '$st' — the filesize/exit-code regression is back"
  [ "$(research_url_status 'https://example.com/definitely-not-real-xyz123')" = dead ] \
    || bad "a 404 did not classify as dead"
  # D1 END TO END: the four measured false positives. These are LIVE URLs whose redirect is a locale prefix,
  # a version pin or a canonicalisation, and every one of them was reported to the author as "you get some
  # other document". Offline pairs above pin the rule; this pins it against the real web.
  for u in 'https://developer.mozilla.org/docs/Web/HTTP/Status' \
           'https://docs.github.com/rest' \
           'https://docs.python.org/library/json.html' \
           'https://www.rfc-editor.org/rfc/rfc7231'; do
    st="$(research_url_status "$u")"
    [ "$st" = live ] || bad "a canonical, universally-cited docs URL classified as '$st': $u — the redirect rule is over-firing again"
  done
  # D2 END TO END: a blackholed address answers nothing at all. That is INCONCLUSIVE, not proof the author
  # invented the URL. Short timeout so the suite does not pay for it.
  st="$(RESEARCH_URL_TIMEOUT=3 research_url_status 'https://10.255.255.1/x')"
  [ "$st" = unchecked ] || bad "an unroutable host classified as '$st' — a timeout must be UNCHECKED; 'dead' here accuses the author of inventing a URL on the strength of a network hiccup"
else
  skipped=1
  echo "  SKIP: offline — network classification not exercised (inconclusive, not clean)"
fi

# --- the >1MB regression, pinned by MECHANISM ------------------------------------------------------------
# Asserting only "a big page classifies live" was not enough: the refactor that removed the curl-exit-code
# branch made the old sabotage un-reproducible, so the assertion passed against reintroduced --max-filesize.
# Pin what actually went wrong instead: a size cap that turns into an EXIT CODE, and branching on that code.
# CODE ONLY, not comments: the fix is DOCUMENTED in lib/research.sh, so an unscoped grep matched the very
# comment explaining why --max-filesize is wrong and failed against correct code. Third time today that a
# grep assertion matched prose — scope every one of them.
_code(){ grep -vE '^[[:space:]]*#' lib/research.sh; }
_code | grep -q -- '--max-filesize' \
  && bad "--max-filesize is back: curl EXITS NON-ZERO when it trips, which is how a 1,009,550-byte REAL docs page was reported as an invented URL"
_code | grep -qE 'curl [^|]*\)"[[:space:]]*\|\|[[:space:]]*\{[[:space:]]*printf .dead' \
  && bad "research_url_status branches on curl's EXIT CODE again — a truncated read is still a successful read; judge the HTTP status"



# --- PROVENANCE must reach the RECIPIENT ------------------------------------------------------------------
# The residual class -- content that is plausible but WRONG (a generic page at 200, normal title, no
# redirect) -- is undetectable by every mechanical layer. The only protection is that whoever ACTS on the
# claim is told what it rests on. So the signal must survive into the slice the implementer reads.
pd="$(mktemp -d)"; mkdir -p "$pd/.opencode/cache"
cat > "$pd/p.md" <<'MD'
# Spec: p   (slug: p · risk: LOW · tier: FAST)
## 2. Prior art
- feed (source: https://blocked.invalid/x, bars)
- UNVERIFIED — column order assumed from memory (source unreachable: x, anti-bot)
## 3. Scope
In: parse
## 4. Acceptance criteria
- AC-1 WHEN parsed THE SYSTEM SHALL return rows
## C1. Contract
GET returns CSV
MD
slice="$(REPO="$pd" bash lib/swarm.sh spec-slice "$pd/p.md" AC-1 2>/dev/null)"
grep -q 'SOURCE PROVENANCE' <<<"$slice"   || bad "the slice carries NO provenance — the implementer encodes a contract shape with no idea it rests on an unread source"
grep -q 'UNVERIFIED CLAIM' <<<"$slice"   || bad "an author-written UNVERIFIED line never reaches the implementer (§2 is not in the slice, so nothing else carries it)"
grep -qi 'ASSUMPTION' <<<"$slice"   || bad "the provenance block does not tell the recipient what to DO about it"

# A clean spec must stay clean: a warning on every slice trains people to ignore warnings.
cat > "$pd/c.md" <<'MD'
# Spec: c   (slug: c · risk: LOW · tier: FAST)
## 3. Scope
In: internal only
## 4. Acceptance criteria
- AC-1 WHEN x THE SYSTEM SHALL y
MD
grep -q 'SOURCE PROVENANCE' <<<"$(REPO="$pd" bash lib/swarm.sh spec-slice "$pd/c.md" AC-1 2>/dev/null)"   && bad "a spec citing NO external source still got a provenance warning — noise on every slice trains recipients to ignore it"
rm -rf "$pd"

grep -qF "PROVENANCE ARRIVES WITH YOUR SLICE" lib/install.sh   || bad "the implementer is not told how to act on a provenance warning"
grep -qF "make the assumption VISIBLE in the code" lib/install.sh   || bad "the implementer is not told to surface the assumption rather than silently encode it"

# --- the provenance READER (this branch was never executed by any test) ------------------------------------
# Every earlier assertion hit only the `[ ! -f "$pf" ]` fallback, so mutating the reader to `return 0`, or
# reintroducing the grep `\t` bug, left the suite GREEN. Build a real provenance file and assert what the
# recipient actually sees.
rd="$(mktemp -d)"; mkdir -p "$rd/.opencode/cache"
printf '# provenance for r\n' > "$rd/.opencode/cache/provenance-r.txt"
printf 'live\thttps://ok.example.net/a\n'                >> "$rd/.opencode/cache/provenance-r.txt"
printf 'blocked\thttps://denied.example.net/b\n'         >> "$rd/.opencode/cache/provenance-r.txt"
printf 'author-unverified\t6:- UNVERIFIED — assumed\n'   >> "$rd/.opencode/cache/provenance-r.txt"
printf 'SUMMARY\t2 cited source(s), 1 not confirmed live\n' >> "$rd/.opencode/cache/provenance-r.txt"
printf '# Spec: r (slug: r)\n' > "$rd/r.md"
blk="$( set --; . lib/research.sh >/dev/null 2>&1; REPO="$rd" research_provenance_block "$rd/r.md" 2>/dev/null )"
grep -q 'SOURCE PROVENANCE' <<<"$blk" || bad "provenance reader produced no block from a real provenance file"$'\n'"$blk"
grep -q '2 claim(s)'        <<<"$blk" || bad "provenance count wrong: expected 2 (one blocked + one author-unverified), got:"$'\n'"$blk"
grep -q 'denied.example.net' <<<"$blk" || bad "the blocked URL is not named in the block the recipient reads"
grep -q 'SUMMARY'           <<<"$blk" && bad "the SUMMARY bookkeeping line leaked into the user-facing block (the grep -E \\t bug)"
grep -q 'ok.example.net'    <<<"$blk" && bad "a LIVE source was listed as a problem — only unconfirmed ones belong here"
# The WRITER must be exercised too: the block above builds its input by hand, so `research_write_provenance`
# returning early still passed. Stub the classifier (no network) and assert the file it produces.
wd="$(mktemp -d)"; mkdir -p "$wd/.opencode/cache"
cat > "$wd/w.md" <<'MD'
# Spec: w (slug: w)
## 2. Prior art
- a (source: https://good.example.net/a, ok)
- b (source: https://bad.example.net/b, ok)
- UNVERIFIED — assumed shape (source unreachable: bad.example.net, anti-bot)
MD
( set --; . lib/research.sh >/dev/null 2>&1
  research_url_status(){ case "$1" in *good*) printf live ;; *) printf blocked ;; esac; }
  REPO="$wd" research_write_provenance "$wd/w.md" ) >/dev/null 2>&1
pf="$wd/.opencode/cache/provenance-w.txt"
[ -f "$pf" ] || bad "research_write_provenance produced NO file — the writer is unexercised and can return early unnoticed"
if [ -f "$pf" ]; then
  grep -q "^live${TABC:-$(printf '\t')}https://good.example.net/a$"    "$pf" || bad "writer did not record the live source: $(cat "$pf")"
  grep -q "^blocked${TABC:-$(printf '\t')}https://bad.example.net/b$"  "$pf" || bad "writer did not record the blocked source: $(cat "$pf")"
  grep -q '^author-unverified' "$pf" || bad "writer dropped the author's UNVERIFIED line — the most honest provenance there is"
  grep -q '^SUMMARY.*2 cited source(s), 1 not confirmed live' "$pf" || bad "writer SUMMARY wrong: $(grep '^SUMMARY' "$pf")"
fi
rm -rf "$wd"

# --- D4: the writer must honour RESEARCH_MAX_URLS, and a URL must be fetched ONCE per pass -----------------
# THE DEFECT, MEASURED: research_write_provenance had no `n >= max` break (unlike research_spec_sources), and
# lib/swarm.sh runs the writer and then the scanner over the same spec in the same lint pass — 20 fetches for
# 12 URLs at max=8, and 64s of wall clock for one spec with 8 unreachable hosts, each paying --max-time twice.
# research_url_status is stubbed as a COUNTER, which is why the cache had to live in a separate wrapper: a
# cache inside research_url_status would be bypassed by this stub and the saving could never be demonstrated.
bd="$(mktemp -d)"; mkdir -p "$bd/.opencode/cache"
{ printf '# Spec: b (slug: b)\n## 2. Prior art\n'
  for i in $(seq 1 12); do printf -- '- s%s (source: https://site%s.test/doc, note)\n' "$i" "$i"; done
} > "$bd/b.md"
( set --; . lib/research.sh >/dev/null 2>&1
  research_url_status(){ printf '%s\n' "$1" >> "$bd/fetches.log"; printf live; }
  research_online(){ return 0; }
  export bd
  REPO="$bd" RESEARCH_MAX_URLS=8 research_write_provenance "$bd/b.md" >/dev/null 2>&1
  REPO="$bd" RESEARCH_MAX_URLS=8 research_spec_sources "$bd/b.md" >/dev/null 2>&1 )
fetches="$(wc -l < "$bd/fetches.log" 2>/dev/null || echo 0)"; fetches="${fetches// /}"
pbf="$bd/.opencode/cache/provenance-b.txt"
# (a) the writer is bounded.
[ "${fetches:-99}" -le 8 ] \
  || bad "the writer ignored RESEARCH_MAX_URLS and/or refetched for the scanner: $fetches fetches for 12 URLs at max=8 (want <= 8)"
# (b) ...and it SAYS it truncated, rather than handing over a provenance file that looks complete.
grep -q 'TRUNCATED' "$pbf" 2>/dev/null \
  || bad "the writer truncated at RESEARCH_MAX_URLS without recording it — the recipient reads a partial provenance file as a complete one: $(cat "$pbf" 2>/dev/null)"
grep -q '^unchecked'"$(printf '\t')"'https://site9.test/doc$' "$pbf" 2>/dev/null \
  || bad "a URL past the bound was dropped silently instead of being recorded as unchecked"
# (c) each URL classified exactly once across BOTH passes — no duplicates in the fetch log.
dupes="$(sort "$bd/fetches.log" 2>/dev/null | uniq -d | wc -l)"; dupes="${dupes// /}"
[ "${dupes:-1}" = 0 ] \
  || bad "a URL was classified more than once in one lint pass ($dupes duplicated) — the writer and the scanner each fetch it"
rm -rf "$bd"

rm -rf "$rd"

# --- the gate must be wired, and opt-in ------------------------------------------------------------------
grep -q 'SRC_LIVE' lib/swarm.sh      || bad "spec-lint has no SRC_LIVE check — external citations are unverified"
grep -q 'SPEC_LINT_NET' lib/swarm.sh || bad "SRC_LIVE is not gated behind SPEC_LINT_NET — a lint gate must not make network calls unasked"

# --- the agents must be TOLD (a checker alone cannot make an agent honest) --------------------------------
# Scoped PER AGENT. The previous loop never used $a -- it ran one file-wide grep three times, so stripping
# the rule from two of the three prompts left the suite green and #156's entire subject unverified.
_agent_prompt(){ # <agent> -> that agent's prompt string only
  python3 - "$1" <<'PYEOF' 2>/dev/null
import json,re,sys
src=open('lib/install.sh').read()
i=src.find('"%s"'%sys.argv[1])
if i<0: sys.exit(1)
j=src.find('"prompt": "',i)
if j<0: sys.exit(1)
j+=len('"prompt": "')
k=src.find('"',j)
while k>0 and src[k-1]=='\\': k=src.find('"',k+1)
print(src[j:k])
PYEOF
}
for a in researcher orchestrator implementer; do
  body="$(_agent_prompt "$a")"
  [ -n "$body" ] || { bad "could not extract the $a prompt — the extraction anchor moved"; continue; }
  grep -qF "RESEARCH HONESTY (non-negotiable)" <<<"$body" \
    || bad "the $a prompt has no research-honesty rule (a file-wide grep hid this: the rule may exist on a DIFFERENT agent)"
done
grep -q "success=true with a 200 for bodies that say 'Access denied'" lib/install.sh \
  || bad "the prompt does not warn that a SUCCESS flag can accompany a denial page — the exact trap measured"
grep -qF "UNVERIFIED -- <claim> (source unreachable" lib/install.sh \
  || bad "the prompt does not mandate the UNVERIFIED form for an unreachable source"
# MEASURED failure shapes that arrive as success=true. The denial-phrase rule alone does NOT cover these:
#   404      -> success=true, statusCode 404, ~300 chars of plausible prose (only the status betrays it)
#   login    -> success=true, 200, 1249 chars of a sign-in page with no denial phrase at all
grep -qF "CHECK metadata.statusCode ON EVERY FETCH" lib/install.sh \
  || bad "agents are not told to check metadata.statusCode — a 404 returns success=true WITH plausible content"
grep -qF "sign-in/login page" lib/install.sh \
  || bad "agents are not told a login/consent/paywall page is a failed fetch — it arrives at 200 with real text"
grep -qF "COMPARE metadata.sourceURL" lib/install.sh \
  || bad "agents are not told to compare sourceURL with url — a redirect to a login page is otherwise invisible to them"

if [ "$fail" = 0 ]; then
  echo "research-honesty-selftest: PASS — denial pages classified as blocked (even at 200/success), precision pins hold, gate wired opt-in, agents instructed$([ "$skipped" = 1 ] && printf ' (network tests SKIPPED — offline)')"
else
  echo "research-honesty-selftest: FAIL"
fi
exit "$fail"
