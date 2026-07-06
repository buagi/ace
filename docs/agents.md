# The crew — 9 agents

The OpenCode config (`~/.config/opencode/opencode.json`, written by `ace install` / `ace opencode`)
defines a 9-agent crew. The **orchestrator** runs on your chosen overseer brain (**Claude Opus by
default** · Sonnet · OpenAI GPT-5 · or DeepSeek for no subscription); the rest run on DeepSeek V4.

| Agent | Role |
|-------|------|
| **orchestrator** | Plans into small tasks, delegates, drives the loop. Writes no code. Reads the [profile](profile.md) and routes work to serve the mission. |
| **implementer** | Senior implementation specialist — executes one scoped task to production quality (tests included); self-reviews before returning. |
| **test_engineer** | Adversarial test author (**risk-gated**). On high-risk / logic-dense tasks, designs the test strategy and writes **independent** tests that try to *break* the code; writes test files + shared helpers only, never production code. |
| **verifier** | Read-only. Runs `./ci.sh`, re-reads the diff, confirms cited symbols exist, runs a security scan → PASS/FAIL. |
| **reviewer** | Principal-engineer code critic: correctness, integration, placement, security hard-gate. |
| **ux_reviewer** | Product/UX & scope critic — judges as a demanding end user; DX/API ergonomics. |
| **standards_keeper** | Best-practices critic. Curates `.opencode/STANDARDS.md` for the stack; flags version drift / past-EOL deps. |
| **alignment_reviewer** | **Mission/values/audience critic** — judges whether a change serves the [profile](profile.md). |
| **conflict_resolver** | Resolves a PR's merge conflicts by preserving **both** sides' intent; escalates UNRESOLVABLE. |

## Risk-gated review

The orchestrator scales ceremony to the change:

- **Low-risk** (docs/config/copy, test-only, a single non-security package) → fast lane: the
  **verifier** gate + the **engineering reviewer**'s APPROVE.
- **High-risk** (auth · money/orders/webhooks · DB migrations · secrets · public APIs · multi-package
  — when unsure, treat as high) → an independent **`test_engineer`** authoring pass after the
  implementer, then the **full panel**: `reviewer` + `ux_reviewer` + `standards_keeper` +
  `alignment_reviewer`, all four must APPROVE, plus the security hard-gate.

A commit lands only on **verifier PASS** AND the risk-gated critics' **APPROVE**. The loop never
self-merges unsafely — push → PR, and merge only when the [delivery gate](profile.md#delivery-policy--loop-behavior)
is green.

## The alignment critic

`alignment_reviewer` is the newest critic. Its source of truth is the project
[profile](profile.md) (`.opencode/profile.yaml` + `ARCHITECTURE.md`) — exactly as `standards_keeper`'s
is `STANDARDS.md`. It runs in two ways:

1. **Always (planner-level):** the orchestrator reads the profile first and routes every task to
   serve the stated mission/audience, flagging off-mission work.
2. **Gated (dedicated critic):** on high-impact / user-facing changes it gives a focused verdict —
   does this advance the mission, fit the audience, uphold the values/philosophy, and suit the
   throughput target? — `APPROVE` / `CHANGES_REQUESTED` tied to specific profile fields. If no
   profile exists, it says so and approves on scope-fit only (never blocks on a missing profile).

## The test engineer

The implementer already writes tests as part of its Definition of Done — but it tests its *own* code,
so those tests can encode the same blind spots. On **high-risk or logic-dense** tasks (the same gate
that triggers the full critic panel) the orchestrator adds an independent **`test_engineer`** pass: a
specialist that authors tests *against* the implementer's mental model — trying to break the code, not
confirm it. It writes test files + shared helpers only (never production code); if a test exposes a
bug, it reports it for the implementer to fix rather than papering over it. Low-risk tasks skip it and
rely on the implementer's own tests, so the extra cost only lands where it pays off.

It picks the **test type per scenario** from the decision table in `.opencode/STANDARDS.md` (curated by
`standards_keeper`) and mirrored in every project's `AGENTS.md`:

| Code under test | Test type |
|---|---|
| Branchy logic, boundaries | Table-driven (happy + error + edge) |
| Parser / serializer / encoder / math | Property + fuzz (roundtrip & invariants) |
| Generated output | Golden / snapshot |
| HTTP / RPC handler | In-process server + contract check |
| DB / external wiring | Integration against an ephemeral dependency |
| Money / orders / webhooks | Replay/idempotency + audit-record assertion |
| Auth / ownership | Authz-DENY matrix (role × resource) |
| Concurrency | Race detector + contention cases |
| Critical user flow | One end-to-end test, sparingly |

Scaffolded projects ship a **shared test-support module** to reuse (Go `internal/testutil` with a
FakeClock + golden helper · Node `tests/` factories + helpers · Python `tests/conftest.py` fixtures),
and `./ci.sh` reports **coverage of the changed code** as a signal (no blanket-% gate — that just
invites gaming). High-stakes packages can be **mutation-tested** (`scripts/mutation.sh`) for a stronger
signal than coverage. Tests always ship in the **same PR** as the code they cover.

After editing the agent config in `lib/install.sh`, run `ace opencode` to regenerate the live
config, then restart opencode (it loads config at launch).
