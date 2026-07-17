# Experiment D — research transport: webfetch vs self-hosted Firecrawl  [PRE-REGISTRATION]

**Hypothesis:** self-hosted Firecrawl (search + scrape + extract) produces better-grounded specs than
single-URL `webfetch` — more real prior-art citations, fewer `UNVERIFIED`/`model knowledge` markers — at
comparable spend. If it does NOT clearly help, Firecrawl stays optional (D-H3: webfetch parity ⇒ defer).

**Config (harness-only):**
- **A (webfetch):** Firecrawl unreachable → the H4 reachability gate auto-disables the MCP; research falls
  back to `webfetch` + model knowledge (the honest-source markers apply).
- **B (Firecrawl):** `ace firecrawl up` (loopback, no cloud key) so `FIRECRAWL_API_URL` is reachable and the
  MCP is enabled. Same task set, same SSRF rule (public docs only).

**Primary metric:** **first-pass spec-lint rate** — fraction of generated specs that pass `swarm_spec_lint`
with ZERO gaps on the first try (measured directly by the gate; no model judgement needed). **Secondary:**
count of `SOURCED`/`CITED` gaps (fewer = better grounding) and `UNVERIFIED` markers per spec.
**Cost:** tokens/task from telemetry — self-hosted fetch is free, so the only token delta is summarizing more
pages; watch that B doesn't balloon context.
**Minimum actionable effect (pre-register):** first-pass lint rate +__ pp AND cost within +__%.

**Watch:**
1. Firecrawl must be UP for arm B, or the reachability gate silently makes B == A — assert `ace firecrawl
   status` is listening before the run, else the whole experiment is a no-op.
2. Grounding quality ≠ lint pass: a spec can lint-pass with thin prior art. Read the `SOURCED` gap count AND
   spot-check that citations resolve, not just the pass/fail bit.
3. Keep the SSRF rule in force — B must never fetch localhost/internal/metadata; a violation invalidates the
   run (and is a security bug, not a data point).

**Decision rule:** recommend `ace firecrawl up` as the default research transport iff first-pass lint rate
rises meaningfully AND cost is within band AND zero SSRF violations. Otherwise it stays an opt-in tool.

**Verdict:** _(run the two arms via `tests/eval-run.sh` with Firecrawl down/up; compare with `eval-ab.sh` on
first-pass-lint TSVs; record to `.opencode/experiments/research-firecrawl.md`)_
