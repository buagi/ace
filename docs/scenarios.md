# Scenarios — runbooks

Concrete command sequences for the jobs you'll actually run. Run `ace` from **inside the project repo**.

**① New project → autonomous, from a clean machine**
```bash
git clone <this-repo> ace && cd ace && ln -s "$PWD/ace" ~/.local/bin/ace
ace install                 # host tools · key · 9-agent config · gh login · Serena
ace scaffold                # new Node / Python / Go / Config project + full machinery
cd <project> && $EDITOR OBJECTIVES.md
ace autorun                 # hands-off
```

**② New Go service → ship a container AND hardened binaries**
```bash
ace scaffold                # → Go; the wizard captures architecture + delivery + hardening
cd <project>
./ci.sh --container         # VPS-parity build (gofmt/vet/test inside the golang image)
ace release                 # cross-compile hardened static binaries → dist/ (+ SHA256SUMS)
git tag v0.1.0 && git push --tags   # CI builds + attaches binaries to the GitHub Release
```

**③ Adopt an existing repo (keep all code + history)**
```bash
cd my-repo
ace upgrade                 # backfill machinery — additive; never touches src/, history, or your VPS
$EDITOR OBJECTIVES.md && ace autorun
```

**④ Choose the overseer brain (cost ⇄ quality)** — the 8 workers always stay on DeepSeek
```bash
ace keys                    # orchestrator brain: opus (default) | sonnet (long runs) | gpt (OpenAI) | deepseek (no sub)
ace opencode                # rewrite config, then restart opencode (loads config at launch)
```

**⑤ Unattended overnight run (cost-aware, self-driving)**
```bash
cd <project>
ace keys                    # profile → balanced (flash verifier) trims spend
AUTOMERGE=1 SELF_IMPROVE=1 MAX_FEATURES=0 ace autorun
# hits a Claude cap? it polls for reset, then falls back to DeepSeek — never dies
```

**⑥ Merge on the local gate (skip waiting on Actions)**
```bash
cd <project>                # profile merge_gate: local (or:)
MERGE_GATE=local AUTOMERGE=1 ace autorun   # merges on a green ./ci.sh --container, no Actions wait
```
> `merge_gate: local` only skips **waiting on GitHub Actions** — the loop still pushes a branch and opens a PR, so it **needs a GitHub `origin` remote** (publish the repo: `ace scaffold --publish`, or `gh repo create --source=. --remote=origin`). "Local gate" ≠ "no remote".

**⑦ Resume after a stop / crash / limit**
```bash
ace resume                  # commits gate-green work a dead run left behind, skips already-merged, continues
```

**⑧ Stand up + deploy to a fresh VPS**
```bash
ace vps                     # Configure → Bootstrap (offers Harden) → Provision git deploy
ace vps harden && ace vps check    # lockout-safe hardening, then readiness verdict
ace deploy                  # pull + rebuild + restart + health-check
```

**⑨ Pull the latest ACE without losing progress**
```bash
cd <your-ace-clone> && git pull --ff-only        # the CLI *is* the repo
ace opencode                                      # refresh global brain; restart opencode
cd <project> && ace upgrade                       # refresh project machinery
```
