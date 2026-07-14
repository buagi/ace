# Crew eval corpus (Part F / F1)

Each `tasks/<id>/` holds: `task.md` (spec; first line `kind: replay|regress|mutant|trap`), a `base`
commit **or** an embedded `tree/` (self-contained), `expect.sh` (deterministic grader — exit 0 = pass;
a mutant grader prints "survived" when the seeded bug reached commit), and optional `reference.patch`
(the known-good fix, applied by `eval-run.sh --stub` so the harness is testable offline).

Run: `tests/eval-run.sh --stub` → `.opencode/eval-results.tsv` → `tests/eval-report.sh <tsv>`.
Full corpus = 12–15 tasks from ACE's own history (replays, past-bug regressions, seeded mutants, traps),
~half held out. The committed `replay-parse-guard` is the pipeline-proving starter; the rest are curated
on a live run (real crew execution needs opencode + provider keys).
