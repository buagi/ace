# OBJECTIVES — debate sandbox (a minimal orders API, for trialling the cross-model debate)

A throwaway project whose HIGH-risk features are AUTHORED + LABELED (see labels.tsv) so the debate's
catch-rate is measurable. Some specs carry a seeded flaw the debate SHOULD flag; others are clean.

- [ ] View order by id — per-object authorization (BOLA/IDOR safe)
- [ ] Stripe payment webhook — signature-verified, deduped, reconciled
- [ ] Public rate limiter — token bucket before auth, fail-open
- [ ] Dashboard performance — measurable acceptance criteria

The specs already live in .opencode/specs/ (materialized from the template). Run the debate over them and
score it: `ace debate score --capture` then `ace debate score` (offline) and `ace debate trend`.
