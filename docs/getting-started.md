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
| OpenCode config | the 10-agent crew |
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

The 8 worker agents always run on DeepSeek V4; only the overseer is configurable.

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
| Claude Pro/Max | required unless you select the `deepseek` brain (default overseer is Claude Opus) |

Tested on Fedora Silverblue/Kinoite and Arch.

## Quirks worth knowing

| Quirk | Why it matters |
|-------|----------------|
| Restart `opencode` after any config or `AGENTS.md` change | it loads config at launch, not live |
| `gh` must be authed (`ace git`) | push, PRs, CI-watch, and autorun all run through it |
| `autorun` needs a GitHub `origin` remote | it works by opening PRs — new project: `ace scaffold --publish`; existing local-only repo: `ace publish` first |
| Container engine is required | for the `--container` parity gate |
| Secrets never go in git | real values live in the VPS `.env` (gitignored); CI builds with dummies |

## See also

- [commands.md](commands.md) — every `ace` subcommand
- [autorun.md](autorun.md) — the autonomous loop
- [profile.md](profile.md) — the architecture-decision wizard
- [configuration.md](configuration.md) — env vars and knobs
