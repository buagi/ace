# The command deck

Every `ace` subcommand. Flags: `--dry-run` · `--watch` · `--version` · `--help`.

| Sector | Command | Does |
|--------|---------|------|
| **rig** | `ace install` / `guided` | host tools + key + 10-agent config + git login |
| | `ace keys` | set/validate DeepSeek + Context7 key, pick model profile + overseer brain |
| | `ace opencode` | (re)write the OpenCode config |
| | `ace settings` | thematic settings: providers/keys · **which model each agent runs** · model profile · appearance (theme/animation/art) · toolchain |
| | `ace git` | git identity + `gh` login + credential helper |
| | `ace status` / `doctor` | health: tools · keys · gh · VPS · profile |
| | `ace arch` | print the architecture overview + what-lives-where |
| | `ace logs` · `ace update` · `ace uninstall` | tail log · update host tooling · clean ACE bits |
| **build** | `ace scaffold` | NEW project (Node · Python · Go · Config) — full machinery |
| | `ace profile` | view/edit the project profile (re-runs pre-fill from the current values) — see [profile.md](profile.md) |
| | `ace profile --check` | validate `.opencode/profile.yaml` (required fields + enums + delivery coherence) |
| | `ace publish [name]` | create + push the project's private GitHub repo so the loop can run. **Re-runnable**: re-pushes if `origin` is set (recovers a failed push); if the name already exists it offers **use / rename / abort**; ends with a loop-readiness check |
| | `ace upgrade` / `adopt` | EXISTING repo — add missing machinery (idempotent, safe); wires + **activates the local `./ci.sh` gate** (`.githooks` via `core.hooksPath`) when the repo has no custom hooks |
| | `ace package <name>` | correctly-wired TS workspace package (types resolve) |
| | `ace stack [add <n>]` | list the scaffoldable stacks · `add` prints the template to register a new one — see [stacks.md](stacks.md) |
| | `ace import` | pull existing code/data into `brownfield/` + map it |
| **map** | `ace graph [--watch]` | refresh GitNexus + Serena + `docs/architecture.md` |
| | `ace consistency [fix]` | drift/scope guard: `main`↔`origin` · GitNexus · opencode DB · podman |
| **git** | `ace gitflow` | main + conventional commits + main-guard + PR template |
| | `ace protect` | GitHub ruleset (PR + CI required; Pro-aware) |
| | `ace audit` | dep vuln audit + outdated + secret scan |
| **loop** | `ace autorun` / `autoloop` | the autonomous pipeline — see [autorun.md](autorun.md) |
| | `ace autorun --explain` | print the resolved delivery policy (merge_gate · auto_merge · deploy_kind · caps) — no run |
| | `ace resume` | resume after an interruption — rescues uncommitted gate-green work, then continues |
| **swarm** | `ace swarm start\|stop` | **parallel loop**: N path-disjoint workers, each self-merging — see [swarm.md](swarm.md) |
| | `ace swarm dash\|split` | the live cockpit (per-worker pipeline + agents + feed + event bus); `split` = tmux columns |
| | `ace swarm pause\|resume\|drain\|kill wN` | control workers — `drain` = finish current work, then stop |
| | `ace swarm sandbox\|selftest\|policy\|wire` | free DRY demo · coordination tests · conflict-policy table · per-project wiring |
| **remote** | `ace loop start\|stop\|restart\|status\|logs\|update` | run the loop as a detached systemd **user service** (survives terminal-close), steerable from chat — see [remote-control.md](remote-control.md) |
| | `ace loop stats` | per-run timing **post-mortem** — time-by-phase + slowest steps (`.opencode/run-summary.txt` + `metrics.csv`) |
| | `ace loop dash [--demo]` | live full-screen **dashboard** — wordmark · status bar · 10 agent boxes (recolor per state) · scrolling log. Watches a running loop's files; `--demo` plays a scripted preview |
| | `ace hermes` | wire loop milestones + command-back to Hermes (→ Telegram/Signal/phone) |
| | `ace hermes mcp\|webhook` | ground the chat agent on this repo (Serena/GitNexus) · route GitHub CI/PR events → chat |
| | `ace approve [tok] yes\|no` | answer a pending loop merge-approval request (paired with `MERGE_APPROVAL=hermes`) |
| | `ace schedule '<when>'` | register a recurring autorun for this repo via Hermes cron (`'0 9 * * 1-5'` · `'every 6h'`) |
| | `ace brain` | file ACE host-lessons + this repo's `lessons.md` into gbrain (if present) |
| | `ace awake on\|off\|status [dur]` | keep the machine awake/reachable while you're away (`on 4h` auto-releases) |
| | `ace snap [--to signal] [--out f.png]` | screenshot the real themed CLI to a PNG (freeze/ansitoimg) and send it as a Signal/Telegram media attachment |
| **ship** | `ace release [--host]` | build hardened static binaries (Go) for the profile's targets — in a container; `--host` on the host. See [go-stack.md](go-stack.md) |
| | `ace release --tag vX.Y.Z` | cut a release: push a `v*` tag → fires the CI release job that builds + publishes the binaries (how artifact projects ship) |
| **deploy** | `ace vps` | configure · bootstrap · harden · wire-CI · provision · deploy · health · verify · check |
| | `ace vps check` | readiness doctor (read-only): system · TLS · DNS · app · DB · firewall → verdict |
| | `ace vps harden` | fail2ban · auto-updates · ufw · key-only SSH — opt-in, lockout-safe |
| | `ace deploy` | pull + rebuild + restart on the VPS, then health-check (http *or* https) |
| | `ace healthcheck` | poll the live deploy (container Running + HTTP) with a timeout |
| | `ace verify` | agent: probe the live VPS → triage findings into `ROADMAP.md` |

> **Golden rule:** run `ace` from **inside the project repo** (`autorun` · `resume` · `release` ·
> `vps *` · `deploy`) — that's how it resolves which repo / branch it's acting on.

## Headless (drive from Signal/Hermes)
Every flow is non-interactive — each choice is a flag/env, so nothing blocks on a TTY:
- `--yes` / `ACE_YES=1` auto-answers proceed-prompts with their safe default; secrets come from env
  (`DEEPSEEK_API_KEY`, `CONTEXT7_API_KEY`).
- New project — **every infra choice is an explicit flag** (nothing assumed):
  `ace scaffold --name <slug> --path <dir> --stack <node|python|go|config>`
  `  [--shape api|cli|worker|library] [--audience …] [--throughput low|medium|high] [--domain "…"] [--mission "…"]`
  `  [--no-git] [--no-ci] [--no-gitflow] [--no-container] [--no-vps] [--index] [--publish]`.
  · `--no-git` ⇒ no git at all (implies no CI/VPS/publish) · `--no-ci` ⇒ no Actions workflow ·
  `--no-container` ⇒ host-only gate (no `Containerfile`; `./ci.sh --container` runs the host gate) ·
  `--no-vps` ⇒ no VPS deploy. Repo init is included unless `--no-git`.
- Keys: `DEEPSEEK_API_KEY=… ace keys --profile max --brain deepseek`.
- **Gated**: `deploy` · `uninstall` · `vps harden` refuse headlessly unless you add `--confirm`.
See [configuration.md](configuration.md#headless--signal) for the full env list.
