# Pre-registered experiments (Part F / F4, Part 2)

Two pending A/Bs, run through F1's harness. **Ground rules (F0, non-negotiable):** pre-register the primary
metric + minimum actionable effect BELOW *before* running; paired on the identical task set; k=5; report
**quality AND cost**; at n≈12 only large effects are real — say **"indistinguishable"** when it is.

**F4 MEASURES; it does not flip config. The D4 (model routing) deferral stands** — a positive result here is
what *unblocks* D4 with evidence instead of a guess.

Run (nightly / on-demand, needs credits):
```
tests/eval-run.sh --k 5 --out A.tsv          # config A (base)
tests/eval-run.sh --k 5 --out B.tsv          # config B (the variant) — applied ONLY in the harness
tests/eval-ab.sh A.tsv B.tsv                 # paired McNemar + bootstrap → adopt / don't / indistinguishable
```
Write the verdict + this pre-registration to `.opencode/experiments/<name>.md`.
