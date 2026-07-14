# Agent goldens (Part F / F3, Edit 2)

Behavioural regression goldens for the read-only critics. Checked by `tests/agent-goldens.sh` **nightly**
(never per-PR — `tests/prompt-contracts.sh` is the per-PR gate).

- `inputs/*.diff` — the four fixture diffs fed to the critics (`--capture`).
- `<critic>__<case>.txt` — the critic's scrubbed verdict output. The committed files are **seed examples**
  that prove the `--check` invariant logic; the nightly `agent-goldens.sh --capture` (with provider keys)
  **replaces** them with real scrubbed transcripts.

Cases + invariant (asserted on verdict TOKENS, never prose): `seeded-bug`→must NOT approve · `clean`→must
approve, no [blocker] · `backend`→ux_reviewer must not invent user-surface findings · `no-evidence`→must
emit UNVERIFIED/UNSURE. A real fail must reproduce twice (nightly re-run) before it blocks.
