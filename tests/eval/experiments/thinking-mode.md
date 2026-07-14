# Experiment B — thinking mode ON vs OFF, PER ROLE  [PRE-REGISTRATION]

**Not a global flip.** A–E systematically **replaced reasoning with structure** (numbered PROCEDUREs, output
contracts, GitNexus/Serena grounding, E1 small task sizes) — which is what lets a non-thinking model perform.
**Hypothesis:** thinking is now unnecessary on the structured/mechanical roles, still needed on the
genuinely reasoning-heavy ones.

- **Test OFF on:** verifier (mechanical pass), standards_keeper, ux_reviewer, alignment_reviewer,
  conflict_resolver, janitor, rathole supervisor, LOW-risk implementer tasks.
- **Keep ON for:** implementer on HIGH-risk/logic-dense tasks; verifier/reviewer **judgment** on HIGH-risk.
- **Primary metric:** pass^k. **Cost:** tokens/task — reasoning tokens bill as **output** (priciest), and
  telemetry logs `tokens_reasoning` separately → directly measurable today.
- **Minimum actionable effect (pre-register):** pass^k within ±__ pp AND cost −__% (fill before running).

**Operational gotchas the harness MUST handle** (else you aren't testing what you think):
1. DeepSeek auto-escalates effort to **max** for OpenCode-class agents — **pin `reasoningEffort` explicitly**.
2. Thinking mode **ignores temperature/top_p**.
3. On tool-calling turns, `reasoning_content` **must be echoed back** in subsequent requests or the API 400s.

**Decision rule:** turn thinking OFF for a role only iff pass^k holds within the band AND cost drops. **A
cheaper-per-token config that causes MORE retries is a false economy** — metric 4.2 (retry rate, `ace
quality`) is the one that catches it.

**D4:** this MEASURES; it does not change model/effort config. A positive result is D4's unblock evidence.

**Verdict:** _(run `eval-ab.sh thinking-on.tsv thinking-off.tsv` per role; record the call + CIs + reasoning-token delta)_
