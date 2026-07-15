# ACE — Documentation

The full guide, split by topic. New here? Start with the [root README](../README.md) for the
overview + quickstart, then dive into a page below.

## Legend

| Page | What's in it |
|------|--------------|
| [getting-started.md](getting-started.md) | Install, first project, choosing the overseer brain. |
| [commands.md](commands.md) | The full `ace` command deck (every subcommand). |
| [stacks.md](stacks.md) | The scaffoldable stacks (Node · Python · Go · Config) **and how to add a new one**. |
| [go-stack.md](go-stack.md) | The Go route: architecture profile wizard, gopls MCP, hardened release binaries. |
| [profile.md](profile.md) | The editable project profile (`.opencode/profile.yaml`) + delivery policy (merge gate / auto-accept). |
| [agents.md](agents.md) | The 10-agent crew, risk-gated review, and the alignment critic. |
| [autorun.md](autorun.md) | The autonomous loop, its lifecycle, per-run metrics, and the read-only ACE self-triage. |
| [swarm.md](swarm.md) | **Parallel loops** — N workers in path-disjoint worktrees, the live cockpit (`ace swarm dash`), finish+stop, per-run archives, every `SWARM_*` knob. |
| [conflict-policy.md](conflict-policy.md) | How the swarm handles *predictable* merge conflicts up front (version · changelog · lockfiles · manifests) — union / structured-merge / regenerate. |
| [hermes.md](hermes.md) | **Drive ACE from chat** — notify · approve · schedule · ground · kanban · brain · dashboard, on any channel (the full Hermes reference). |
| [remote-control.md](remote-control.md) | The "fire ACE from your phone while away" runbook — detached service, staying reachable, the security model. |
| [configuration.md](configuration.md) | Every env knob + where config lives (the settings reference). |
| [scenarios.md](scenarios.md) | Runbooks for the jobs you'll actually run. |
| [the-gate.md](the-gate.md) | The tiered `ci.sh` gate — what blocks a commit. |
| [deploy.md](deploy.md) | Shipping to the VPS — cadence, the `DEPLOY_GATE` milestone gate, manual deploy, where to check what's live. |
| [deferred-decisions.md](deferred-decisions.md) | *(maintainer)* Known trade-offs intentionally not built yet — the serialized-merge re-gate, `allocate`, and their triggers. |

## Quick map

- **Set up the rig** → [getting-started.md](getting-started.md)
- **Build something** → [stacks.md](stacks.md) · [go-stack.md](go-stack.md)
- **Drive it hands-off** → [autorun.md](autorun.md) · [configuration.md](configuration.md)
- **Run it in parallel** → [swarm.md](swarm.md) · [conflict-policy.md](conflict-policy.md)
- **Drive it from chat / your phone** → [hermes.md](hermes.md) · [remote-control.md](remote-control.md)
- **Understand the crew** → [agents.md](agents.md)
- **Ship binaries / deploy** → [go-stack.md](go-stack.md) (release) · [commands.md](commands.md) (`ace deploy`)
