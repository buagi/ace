# Getting started

## 1. Put it on the grid
```bash
git clone <this-repo> ace && cd ace
ln -s "$PWD/ace" ~/.local/bin/ace      # now `ace` works anywhere (clone wherever you like)
```
`~/.local/bin` must be on your `PATH`. Open a **new terminal** after install (for the `~/.bashrc` block).

## 2. Wire the rig
```bash
ace install        # host tools (fnm/node · uv · bun · jq · opencode · gh · Go toolchain) + key
                   # + 10-agent OpenCode config + GitHub login — all user-local, no root
```
`ace status` confirms the rig is green (tools · keys · gh · VPS · profile).

## 3. Build
```bash
# NEW project →                         # EXISTING repo →
ace scaffold                            cd my-repo && ace upgrade
#   Node / TypeScript · Python · Go · Config
```
The **Go** stack opens an architecture-decision wizard ([profile.md](profile.md)).

## 4. Go hands-off
```bash
cd <project>
$EDITOR OBJECTIVES.md      # set the north-star goals
ace autorun                # the machine takes the wheel — see autorun.md
```

## Choosing the overseer brain
`ace keys` → *orchestrator brain*: `opus` (**default** — deepest planning; on your Claude plan) · `sonnet`
(best for long unattended runs, lighter on Claude quota) · `gpt` (OpenAI GPT-5) · `deepseek` (no
subscription). The 8 worker agents always run on DeepSeek V4. The default (Opus) and the other Claude/OpenAI
options need `opencode auth login` (Anthropic or OpenAI — **oauth** to bill your subscription, or an API
key), then `ace opencode`; pick `deepseek` if you'd rather run without any subscription. On a usage-limit the
loop **waits for reset on your chosen model** rather than downgrading (opt into a fallback with
`ON_CLAUDE_LIMIT=deepseek`). Details in [configuration.md](configuration.md).

## Requirements
`bash` · `git` · `curl` — everything else is installed **user-local** by `ace install`. A **container
engine** (podman/docker) for the parity gate. A **DeepSeek** API key (Context7 optional); the **default
overseer is Claude Opus**, so a **Claude Pro/Max** subscription (`opencode auth login`) is needed unless you
select the `deepseek` brain. Tested on **Fedora Silverblue/Kinoite** and **Arch**.

## Quirks worth knowing
- 🧠 **Restart opencode** after any config / `AGENTS.md` change — it loads at launch, not live.
- 🤖 **`gh` must be authed** (`ace git`) — push, PRs, CI-watch, and autorun all run through it.
- 🔗 **autorun needs a GitHub `origin` remote** — it works by opening PRs. New project: `ace scaffold --publish`. Existing local-only repo: `ace publish` first.
- 🐳 **Container engine** is required for the `--container` parity gate.
- 🔐 **Secrets never go in git** — real values live in the VPS `.env` (gitignored); CI builds with dummies.
