# Getting started

Install the CLI, provision the host, create or adopt a project, then hand it to the autonomous loop. Four steps, all user-local — no root.

## 1. Install the CLI

```bash
git clone <this-repo> ace && cd ace
ln -s "$PWD/ace" ~/.local/bin/ace      # `ace` now works anywhere; clone wherever you like
```

`~/.local/bin` must be on your `PATH`.

> [!IMPORTANT]
> Open a **new terminal** after install so the managed `~/.bashrc` block is sourced.

## 2. Provision the host

```bash
ace install
```

This installs everything the rig needs, all user-local:

| Installs | What |
|----------|------|
| Host tools | `fnm`/node · `uv` · `bun` · `jq` · `opencode` · `gh` · Go toolchain |
| Keys | DeepSeek API key (validated) |
| OpenCode config | the 12-agent crew |
| GitHub | `gh` login |

`ace status` confirms the rig is green: tools · keys · `gh` · VPS · profile.

## 3. Create or adopt a project

| You have | Command | Result |
|----------|---------|--------|
| A new project | `ace scaffold` | full machinery for a Node/TypeScript · Python · Go · Config stack |
| An existing repo | `cd my-repo && ace upgrade` | adds missing machinery, idempotent and non-destructive |

The code stacks (Node, Python, Go) open an architecture-decision wizard; the Config stack skips it — see [profile.md](profile.md).

## 4. Run hands-off

```bash
cd <project>
$EDITOR OBJECTIVES.md      # set the north-star goals
ace autorun                # start the autonomous loop
```

See [autorun.md](autorun.md) for what the loop does each lap.

## Choosing the overseer brain

`ace keys` sets the **orchestrator brain** — the model that plans the work:

| Brain | Model | Use for | Subscription |
|-------|-------|---------|--------------|
| `opus` (default) | Claude Opus | deepest planning | Claude Pro/Max |
| `sonnet` | Claude Sonnet | long unattended runs; lighter on Claude quota | Claude Pro/Max |
| `gpt` | OpenAI GPT-5 | — | OpenAI |
| `deepseek` | DeepSeek V4 | running without any subscription | none |

ACE ships **12 agents** — the orchestrator plus 11 subagents. The subagents *default* to DeepSeek V4, but they are not locked there: `ace keys` is just the quick path to the overseer, and any of the 11 configurable agents can be pointed at another provider with `MODEL_<agent>=<provider>/<model>` in `ace settings` (the 12th, `debater`, is not in that list — it is model-pinned via `DEBATE_MODEL_A`/`_B`, and the cross-model debate it runs is **off by default**: `SPEC_DEBATE`/`REVIEW_DEBATE` both default to `0`). See [agents.md](agents.md).

- The default (`opus`) and the other Claude/OpenAI brains need `opencode auth login` (Anthropic or OpenAI). Use **oauth** to bill your subscription, or supply an API key — then run `ace opencode`.
- Pick `deepseek` to run without any subscription.

> [!NOTE]
> On a usage-limit the loop **waits for the reset on your chosen brain** rather than downgrading. Opt into a fallback with `ON_CLAUDE_LIMIT=deepseek` (values: `wait` default · `cancel` · `deepseek`). Details in [configuration.md](configuration.md).

## Requirements

| Requirement | Notes |
|-------------|-------|
| `bash` · `git` · `curl` | everything else is installed user-local by `ace install` |
| Container engine | podman or docker, for the `./ci.sh --container` parity gate |
| DeepSeek API key | required (Context7 key optional) |
| Claude Pro/Max | required for the default overseer (Claude Opus) and for `sonnet`. Not needed if you select `gpt` (needs OpenAI instead) or `deepseek` (needs nothing beyond the DeepSeek key) |

Tested on Fedora Silverblue/Kinoite and Arch.

## Quirks worth knowing

| Quirk | Why it matters |
|-------|----------------|
| Restart `opencode` after any config or `AGENTS.md` change | it loads config at launch, not live |
| `gh` must be authed (`ace git`) | push, PRs, CI-watch, and autorun all run through it |
| `autorun` needs a GitHub `origin` remote | it works by opening PRs — new project: `ace scaffold --publish`; existing local-only repo: `ace publish` first |
| Container engine is required | for the `--container` parity gate |
| Secrets never go in git | real values live in the VPS `.env` (gitignored); CI builds with dummies |

## Staying current

ACE has three kinds of code, and each updates a different way. Knowing which is which saves you from running an "upgrade" that does nothing — or skipping one you needed.

| Layer | What it is | How a project picks up changes |
|-------|-----------|-------------------------------|
| **`lib/*.sh` (the loop & swarm engine)** | `autoloop.sh`, `swarm.sh`, `swarm-run.sh`, `scaffold.sh`, … | **Live-sourced — automatic, free.** A scaffolded project's `scripts/auto-loop.sh` is a thin shim that sources `<ace>/lib/autoloop.sh`; the swarm coordinator runs `<ace>/lib/swarm-run.sh` directly. The next `ace loop` / `ace swarm start` runs the current code. Nothing to install. |
| **Generated per-project files** | `ci.sh`, `.githooks/*`, `scripts/atlas-refresh.sh`, scaffolds, the profile wiring | **`ace upgrade`** (a.k.a. `adopt`) — idempotent; rewrites the machinery whose *content* changed, guided by version stamps (e.g. the atlas generator's `atlas-gen-version`). Safe to re-run; commit the diff. |
| **Global agent config** | the 12-agent crew, models, MCP servers in `~/.config/opencode/opencode.json` | **`ace opencode`** — only when the crew/model/MCP definitions change. Restart `opencode` after. |

**Keep the ACE checkout itself current first** (everything above sources from it):

```sh
git -C /path/to/ace pull        # or the two-remote sync if you maintain buagi/ace
ace update                      # optional: refresh host tooling (opencode · bun · node · uv)
```

Then, **per project**:

```sh
cd my-project
ace upgrade                     # refresh generated files (atlas gen, ci.sh, hooks) — commit the diff
# ace opencode                  # ONLY if the agent crew/models/MCP changed
```

That's it — `lib/*.sh` changes (loop and swarm behaviour, the resilience fixes, new bus events) are already live on the next run; `ace upgrade` catches the generated files; `ace opencode` is rare. When in doubt: `lib` = free/live, `upgrade` = generated, `opencode` = agents.

## See also

- [commands.md](commands.md) — every `ace` subcommand
- [autorun.md](autorun.md) — the autonomous loop
- [observability.md](observability.md) — watching a run & reading the logs
- [profile.md](profile.md) — the architecture-decision wizard
- [configuration.md](configuration.md) — env vars and knobs
