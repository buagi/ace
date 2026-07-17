# Debate sandbox — the ground truth for measuring the cross-model debate

This is a **runnable, labeled** ACE project. Its `specs/*.md` are authored HIGH-risk specs, some **seeded-flawed**
(the debate SHOULD flag) and some **clean** (SHOULD pass), with the answers in **`labels.tsv`**
(`slug · FLAGGED|SOUND · expected-issue`). That ground truth is what makes the debate's effectiveness
*measurable* — precision/recall/F1, not just activity.

## Measure (no live run needed to re-score)
```
ace debate score --capture   # run the LIVE debate over each spec (needs OPENROUTER_API_KEY + DEBATE_MODEL_B)
ace debate score             # score the recorded outputs → precision/recall/F1 + append a trend point (offline)
ace debate trend             # effectiveness over time + a conclusion (improving / flat / regressing)
ace debate review            # what still fails (false positives/negatives) + tuning hints
```

## Run it live (watch the debate fire in a real loop)
```
ace debate testproject /tmp/ds     # materialize a throwaway copy (specs → .opencode/specs, profile, ci.sh, git init)
cd /tmp/ds
SPEC_DEBATE=1 DEBATE_ONLY=authz-missing,webhook-nosig,vague-acs ace autorun --yes
```

## Add a fixture
Author `specs/<slug>.md` (HIGH-risk), add a `labels.tsv` row, `--capture` + review, commit. Grow the corpus over
time — a bigger labeled set makes the effectiveness score (and the auto-tune A/B) trustworthy.
