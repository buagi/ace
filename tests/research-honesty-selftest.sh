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

if [ "$fail" = 0 ]; then
  echo "research-honesty-selftest: PASS — denial pages classified as blocked (even at 200/success), precision pins hold, gate wired opt-in, agents instructed$([ "$skipped" = 1 ] && printf ' (network tests SKIPPED — offline)')"
else
  echo "research-honesty-selftest: FAIL"
fi
exit "$fail"
