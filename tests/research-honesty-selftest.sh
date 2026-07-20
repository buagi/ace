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
         "500|oops|dead" \
         "000||dead"; do
  IFS='|' read -r code body want <<<"$c"
  got="$(research_classify "$code" "$body")"
  [ "$got" = "$want" ] || bad "research_classify(code=$code body='${body:0:28}') = $got, want $want"
done

# A denial phrase deep inside a LONG legitimate document must NOT flag it: only the first 4000 chars are
# examined, because a real page can discuss captchas without being one.
long="$(printf 'Legitimate documentation. %.0s' $(seq 1 300))captcha"
[ "$(research_classify 200 "$long")" = live ] || bad "a long legitimate doc mentioning 'captcha' late was misclassified as blocked"

# --- AUTH-WALL + REDIRECT layers (offline, via the real classifier) --------------------------------------
# A login wall arrives at HTTP 200 with 1249 chars of genuine text and no denial phrase, so neither the
# status code nor the body regex sees it. Two mechanical signals do: the TITLE, and landing on a different
# path than requested.
_html(){ printf '<html><head><title>%s</title></head><body>%s</body></html>' "$1" "genuine looking documentation body text"; }

# Recall: real walls must be caught.
for t in "Sign in to GitHub · GitHub" "Log in — Example" "Page Not Found" "Sign in" "Unauthorized"; do
  [ "$(research_classify 200 "$(_html "$t")" 'https://x.test/p' 'https://x.test/p')" = authwall ] \
    || bad "auth/error wall title not caught: '$t'"
done

# Precision: a docs page whose TOPIC is auth or errors must NOT be flagged. The first regex matched all
# three of these — a prefix match cannot tell an announcement from a topic.
for t in "Error handling | Firecrawl Docs" "Login flow design notes" "404 pages: best practice" "Sign-in UX patterns (blog)" "Errors and retries — API reference"; do
  got="$(research_classify 200 "$(_html "$t")" 'https://x.test/p' 'https://x.test/p')"
  [ "$got" = live ] || bad "legitimate docs page flagged as '$got' by its title: '$t'"
done

# Redirect: a changed PATH is a different document; cosmetic differences are not.
[ "$(research_classify 200 "$(_html 'Docs')" 'https://github.com/settings/profile' 'https://github.com/login?return_to=x')" = redirected ] \
  || bad "a redirect to a different PATH was not detected — this is how a login page passes as the document"
for pair in "https://example.com|https://example.com/" \
            "http://example.com/a|https://example.com/a" \
            "https://WWW.Example.com/a|https://example.com/a" \
            "https://example.com/a|https://example.com/a#frag"; do
  w="${pair%|*}"; g="${pair#*|}"
  [ "$(research_classify 200 "$(_html 'Docs')" "$w" "$g")" = live ] \
    || bad "cosmetic URL difference treated as a redirect ($w -> $g) — this would flag every clean fetch"
done

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

# --- the gate must be wired, and opt-in ------------------------------------------------------------------
grep -q 'SRC_LIVE' lib/swarm.sh      || bad "spec-lint has no SRC_LIVE check — external citations are unverified"
grep -q 'SPEC_LINT_NET' lib/swarm.sh || bad "SRC_LIVE is not gated behind SPEC_LINT_NET — a lint gate must not make network calls unasked"

# --- the agents must be TOLD (a checker alone cannot make an agent honest) --------------------------------
for a in researcher orchestrator implementer; do
  grep -q "RESEARCH HONESTY (non-negotiable)" lib/install.sh \
    || { bad "no research-honesty rule in the agent prompts"; break; }
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
