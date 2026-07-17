# Commands

Every `ace` subcommand, grouped by what it touches. Run `ace` with no argument for the interactive menu, or `ace --help` for the terse list.

## Global flags

| Flag | Effect |
|------|--------|
| `--dry-run` | preview: log what each step would do, change nothing |
| `--watch` | live-refresh mode (`ace graph`, `ace loop dash`) |
| `--yes` / `-y` | assume-yes; auto-answer proceed-prompts with their safe default (headless) |
| `--confirm` | unlock a gated destructive op when non-interactive |
| `--version` / `-V` | print the version |
| `--help` / `-h` | print usage |

> [!IMPORTANT]
> Run `ace` from **inside the project repo** for anything repo-scoped (`autorun` · `resume` · `release` · `vps *` · `deploy` · `profile` · `publish`). That is how it resolves which repo and branch it acts on.

## Rig

| Command | Does |
|---------|------|
| `ace install` / `guided` | host tools + key + 12-agent config + GitHub login |
| `ace keys` | set/validate DeepSeek + Context7 key, pick model profile + overseer brain |
| `ace opencode` | (re)write the OpenCode config |
| `ace settings` | thematic submenus: providers/keys · which model each agent runs · model profile · appearance (theme/animation/art) · toolchain |
| `ace git` | git identity + `gh` login + credential helper |
| `ace status` / `doctor` | health check (tools · keys · `gh` · VPS · profile) ending in a **Readiness report** — a plain-language "✓ ready now / ⚠ needs setup (with the fix) / ◦ optional" summary + a single READY/NOT-READY verdict. Also printed at the end of `ace install`. |
| `ace logs` | tail the latest run/install log (`~/.config/ace/logs/`). |
| `ace arch` | print the architecture overview and what-lives-where |
| `ace demo` | paced, **zero-credit** feature walkthrough for recording (`DEMO_AUTO=1` hands-free; see [demo/RECORDING.md](demo/RECORDING.md)) |
| `ace logs` | tail the latest log |
| `ace update` | update host tooling (`opencode` · `bun` · node · `uv`) |
| `ace uninstall` | remove ACE-managed config (gated: needs `--confirm` when non-interactive) |

## Build a project

| Command | Does |
|---------|------|
| `ace scaffold` | NEW project (Node · Python · Go · Config) — full machinery |
| `ace profile` | view/edit the project profile; re-runs pre-fill from current values — see [profile.md](profile.md) |
| `ace profile --check` | validate `.opencode/profile.yaml` (required fields + enums + delivery coherence) |
| `ace publish [name]` | create + push the project's private GitHub repo so the loop can run — see note below |
| `ace upgrade` / `adopt` | EXISTING repo — add missing machinery (idempotent, safe); wires + activates the local `./ci.sh` gate |
| `ace package <name>` | add a correctly-wired TS workspace package (types resolve from source) |
| `ace stack [add <n>]` | list the scaffoldable stacks · `add` prints the template to register a new one — see [stacks.md](stacks.md) |
| `ace import` | pull existing code/data into `brownfield/` and map it |

`ace publish` is re-runnable:

- Re-pushes if `origin` is already set (recovers a failed push).
- If the name already exists, it offers **use / rename / abort**.
- Ends with a loop-readiness check.

`ace upgrade` activates the gate (`.githooks` via `core.hooksPath`) only when the repo has no custom hooks.

## Map and consistency

| Command | Does |
|---------|------|
| `ace graph [--watch]` | refresh GitNexus + Serena + `docs/architecture.md` (agent code-map) |
| `ace atlas` | refresh the human Architecture Atlas — `docs/atlas.md` (system map · data flow · module map) + the README system-map block ([how it works](architecture-atlas.md)) |
| `ace consistency [fix]` | drift/scope guard: `main`↔`origin` · GitNexus · opencode DB · podman; add `fix` to reconcile |

## Git and safety

| Command | Does |
|---------|------|
| `ace gitflow` | main + conventional commits + main-guard + PR template |
| `ace protect` | GitHub ruleset (PR + CI required; Pro-aware fallback) |
| `ace audit` | dependency vuln audit + outdated + secret scan |

## The loop

| Command | Does |
|---------|------|
| `ace autorun` / `autoloop` | the autonomous pipeline — see [autorun.md](autorun.md) |
| `ace autorun --explain` | print the resolved delivery policy (`merge_gate` · `auto_merge` · `deploy_kind` · caps) — no run |
| `ace resume` | resume after an interruption — rescues uncommitted gate-green work, then continues |
| `ace stats [global\|N\|task]` | per-subagent × worker token/cost from the opencode session DB (`global` = all projects · `N` = last-N-days · `task` = per-ROADMAP-task). `ACE_TELEMETRY=0` turns off all run logging |
| `ace quality` | quality leading-indicators: per-critic false-positive rate + retry rate + escaped-bug → `.opencode/quality-report.md` |
| `ace debate spec <file>` / `review [base]` | run a **cross-model debate** on demand — two different LLMs (defender = your overseer, challenger = `DEBATE_MODEL_B` via OpenRouter) pressure-test a spec or the branch diff; transcript → `.opencode/cache/*-debate-*.md`. Needs `OPENROUTER_API_KEY`. |

> [!NOTE]
> `ace stats` (token/cost telemetry) is distinct from `ace loop stats` (per-run timing post-mortem, listed under [Remote control](#remote-control)).

## Swarm

Parallel loops: N path-disjoint workers, each self-merging. See [swarm.md](swarm.md).

| Command | Does |
|---------|------|
| `ace swarm start\|stop` | start/stop the parallel workers |
| `ace swarm dash\|split` | live cockpit (per-worker pipeline + agents + feed + event bus); `split` = tmux columns |
| `ace swarm pause\|resume\|drain\|kill wN` | control workers — `drain` = finish current work, then stop |
| `ace swarm sandbox\|selftest\|policy\|wire` | free DRY demo · coordination tests · conflict-policy table · per-project wiring |

## Remote control

Run the loop as a detached systemd **user service** that survives terminal-close and is steerable from chat. See [remote-control.md](remote-control.md).

| Command | Does |
|---------|------|
| `ace loop start\|stop\|restart\|status\|logs\|update` | control the loop service |
| `ace loop stats` | per-run timing post-mortem — time-by-phase + slowest steps (`.opencode/run-summary.txt` + `metrics.csv`) |
| `ace dash` / `ace watch` | ONE dashboard for either flow — auto-detects a running swarm (its cockpit) vs the single-flow loop (the solo dash). Same view whichever you type (`ace loop dash` / `ace swarm dash` route here too) |
| `ace loop dash [--demo]` | live full-screen dashboard: wordmark · status bar (with the live phase tag: research · spec-gate · implementing · …) · 11 agent boxes (recolor per state) · scrolling log. Watches a running loop; `--demo` plays a scripted preview |
| `ace hermes` | wire loop milestones + command-back to Hermes (→ Telegram/Signal/phone) |
| `ace hermes mcp\|webhook` | ground the chat agent on this repo (Serena/GitNexus) · route GitHub CI/PR events → chat |
| `ace approve [tok] yes\|no` | answer a pending loop merge-approval request (paired with `MERGE_APPROVAL=hermes`) |
| `ace schedule '<when>'` | register a recurring autorun via Hermes cron (`'0 9 * * 1-5'` · `'every 6h'`) |
| `ace brain` | file ACE host-lessons + this repo's `lessons.md` into gbrain (if present) |
| `ace awake on\|off\|status [dur]` | keep the machine awake/reachable while away (`on 4h` auto-releases) |
| `ace snap [--to signal] [--out f.png]` | screenshot the real themed CLI to a PNG (freeze/ansitoimg) and send it as a Signal/Telegram attachment |

## Ship

Build and release artifacts (Go). See [go-stack.md](go-stack.md).

| Command | Does |
|---------|------|
| `ace release [--host]` | build hardened static binaries for the profile's targets — in a container; `--host` builds on the host |
| `ace release --tag vX.Y.Z` | cut a release: push a `v*` tag → fires the CI release job that builds + publishes the binaries |

## Deploy

| Command | Does |
|---------|------|
| `ace vps` | VPS menu: configure · bootstrap · harden · wire-CI · provision · deploy · health · verify · check |
| `ace vps check` | readiness doctor (read-only): system · TLS · DNS · app · DB · firewall → verdict |
| `ace vps harden` | fail2ban · auto-updates · ufw · key-only SSH — opt-in, lockout-safe |
| `ace deploy` | pull + rebuild + restart on the VPS, then health-check (http or https) |
| `ace healthcheck` | poll the live deploy (container Running + HTTP) with a timeout |
| `ace verify` | agent: probe the live VPS → triage findings into `ROADMAP.md` |

## Headless (drive from Signal/Hermes)

Every flow is non-interactive: each choice is a flag or env var, so nothing blocks on a TTY.

- `--yes` / `ACE_YES=1` auto-answers proceed-prompts with their safe default. Secrets come from env (`DEEPSEEK_API_KEY`, `CONTEXT7_API_KEY`).
- Keys headless: `DEEPSEEK_API_KEY=… ace keys --profile max --brain deepseek`.

New project — every infra choice is an explicit flag, nothing assumed:

```bash
ace scaffold --name <slug> --path <dir> --stack <node|python|go|config> \
  [--shape api|cli|cli-web|worker|library] [--audience …] \
  [--throughput low|medium|high] [--domain "…"] [--mission "…"] \
  [--no-git] [--no-ci] [--no-gitflow] [--no-container] [--no-vps] [--index] [--publish]
```

| Flag | Effect |
|------|--------|
| `--no-git` | no git at all (implies no CI/VPS/publish) |
| `--no-ci` | no Actions workflow |
| `--no-gitflow` | drop the gitflow guards |
| `--no-container` | host-only gate (no `Containerfile`; `./ci.sh --container` runs the host gate) |
| `--no-vps` | no VPS deploy |
| `--index` | index the new repo |
| `--publish` | create the GitHub remote the autorun loop needs |

Repo init is included unless `--no-git`.

> [!CAUTION]
> `deploy` · `uninstall` · `vps harden` refuse to run headlessly unless you add `--confirm`.

See [configuration.md](configuration.md#headless--signal) for the full env list.

## See also

- [getting-started.md](getting-started.md) — install and first run
- [observability.md](observability.md) — watching a run & reading the logs
- [autorun.md](autorun.md) — the autonomous loop
- [profile.md](profile.md) — the project profile the loop reads
- [configuration.md](configuration.md) — env vars and knobs
