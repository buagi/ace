# Hermes integration

Drive ACE from any chat channel when [Hermes Agent](https://hermes-agent.org/) is installed: milestone notifications, merge approvals, scheduling, code-graph grounding, a kanban mirror, and a live dashboard. ACE runs standalone; Hermes is an optional, additive layer.

> [!IMPORTANT]
> Two principles hold everywhere.
> - **Opt-in and fail-soft.** Every Hermes touch-point is gated on `command -v hermes`. No `hermes` on `PATH`, a send error, or a disabled feature degrades to a silent no-op — it never breaks or blocks the loop.
> - **Channel-agnostic, Telegram-first.** ACE's delivery target resolves in order: `HERMES_TO` env → stored `config HERMES_TO` → `telegram`.

This page is the full feature reference. For the "fire ACE from your phone while away" runbook — the detached service, staying reachable, and the security model — see [remote-control.md](remote-control.md).

## Capabilities at a glance

| Capability | Command / knob | What you get |
|---|---|---|
| Notify | `HERMES_NOTIFY=1` | milestone texts to your channel |
| Approve | `MERGE_APPROVAL=hermes` + `ace approve` | human-in-the-loop merges |
| Schedule | `ace schedule '<when>'` | recurring autoruns via Hermes cron |
| Ground | `ace hermes mcp` | chat agent navigates this repo's code graph |
| Kanban | `HERMES_KANBAN=1` | `ROADMAP.md` mirrored to a board |
| Brain | `ace brain` | ACE's lessons filed into gbrain |
| Dashboard | `ace loop dash` | live full-screen loop view |

Any channel the gateway has configured works as a `HERMES_TO` target:

| Target | Points at |
|---|---|
| `telegram` | the gateway's home channel (default) |
| `telegram:<chat_id>` | a specific Telegram chat |
| `signal:+15551234567` | a Signal number (E.164) |
| `discord:<channel_id>` | a Discord channel |
| `slack:<channel>` | a Slack channel |
| `whatsapp:<id>` | a WhatsApp chat |
| `matrix:…` | any other channel the gateway supports |

## Two config homes — ACE side vs Hermes side

ACE and Hermes own different things, and this split is where setup trips people up.

| You want to… | Owned by | Where / how |
|---|---|---|
| Bind the bot to a channel + authorize who may use it (token, channel **id**, allowed users) | Hermes | `~/.hermes/.env` via `hermes gateway`, then restart the gateway |
| Enable command-back (the bot runs `ace …` on the host) for a platform | Hermes | per-platform toolset in `~/.hermes/config.yaml` (`ace hermes` offers it); gated by `approvals: mode: manual` |
| Choose **where** ACE sends notifications | ACE | `HERMES_TO` (a single target string) — set via `ace hermes` |
| Turn notifications on for a run | ACE | `HERMES_NOTIFY=1 ace autorun --yes` |
| Ask before merge from chat | ACE | `MERGE_APPROVAL=hermes` (+ `ace approve`) |
| Schedule recurring autoruns | ACE (uses Hermes cron) | `ace schedule '<when>'` |

> [!NOTE]
> ACE only ever sets `HERMES_TO` (one destination string) plus per-run opt-in env. The channel itself — its id, token, and who is authorized — belongs to Hermes (`~/.hermes/.env`, applied by `hermes gateway` plus a restart). That is why there is no "Telegram channel id" field in the ACE console: ACE does not own the channel, only the target string that points at one Hermes already knows.

### Bind a channel — Hermes side, do this first

```bash
hermes gateway                 # interactive: bot token + home channel + allowed users/chats
# …or edit ~/.hermes/.env directly:
#   TELEGRAM_BOT_TOKEN=…             (from BotFather)
#   TELEGRAM_HOME_CHANNEL=<id>       the channel/chat id the bot calls home
#   TELEGRAM_HOME_CHANNEL_NAME=…
#   TELEGRAM_ALLOWED_USERS=<id,…>    TELEGRAM_GROUP_ALLOWED_CHATS=<id,…>
#   (Signal uses SIGNAL_* / a registered number instead)
systemctl --user restart hermes-gateway     # REQUIRED — .env is read ONLY at gateway start
```

### Point ACE at it — ACE side

```bash
ace hermes                                   # prompts "Hermes target…" → saves HERMES_TO
#   telegram             → the gateway's home channel (default)
#   telegram:<chat_id>   → a specific chat (must be one the gateway is authorized for)
HERMES_TO=signal:+15551234567 ace hermes     # non-interactive: pin a channel
ace hermes mcp                               # (optional) ground the chat agent on this repo's code graph
```

Verify each side separately:

- `ace doctor` shows the resolved ACE-side target on its `hermes/chat` line (`target=… · hermes=wired|absent`).
- `hermes gateway` or a test `hermes send` confirms the Hermes-side channel.

> [!NOTE]
> Command-back is per-platform. Enabling it adds the `terminal` toolset to that platform's bundle in `config.yaml`, so a platform without it can receive notifications and chat but cannot execute `ace`. A common split: command-back on Signal, notifications to Telegram. Either way, execution is gated by `approvals: mode: manual`.

## Command surface

| Command | What it does |
|---|---|
| `ace hermes` | The hub — wires loop milestone notifications and command-back (the bot runs `ace …` on the host, locked to your id) to your channel. |
| `ace hermes mcp` | Registers this repo's code-graph servers (Serena `--project`, GitNexus best-effort) with the Hermes agent, so chat questions are grounded. Same servers OpenCode uses. |
| `ace hermes webhook` | Subscribes a Hermes webhook route for GitHub CI/PR events → chat, and prints the route to add to the repo's GitHub webhooks. Needs a publicly-reachable gateway. |
| `ace publish [name]` | Creates and pushes the repo's private GitHub `origin` so the loop can run. Re-runnable: re-pushes if origin is set, and offers use / rename / abort if the name already exists. |
| `ace approve [tok] yes\|no` | Answers a pending merge-approval request (paired with `MERGE_APPROVAL=hermes`). No token = the newest pending request. |
| `ace schedule '<when>'` | Registers a recurring autorun for this repo via Hermes cron (`'0 9 * * 1-5'` · `'every 6h'` · `'30m'`). |
| `ace brain` | Files ACE's cross-project host-lessons and this repo's `.opencode/lessons.md` into gbrain. |
| `ace snap [--to <chan>]` | Screenshots the themed CLI to a PNG and sends it as a media attachment. |
| `ace loop dash` | A live dashboard — watch a running loop in a second pane. |

## Notifications

The autorun loop texts you curated milestones via `hermes send`:

| Milestone | Fires when |
|---|---|
| started | an autorun begins |
| merged | a PR lands on `main` |
| deployed | a merged `main` reaches the VPS |
| CI-red | CI fails and the loop starts auto-fixing |
| rathole | the loop stops after exhausted fix-retries |
| blocked | a deploy/health-check fails or a provider limit halts the run |
| stopped | the loop ends |

Opt in per run:

```bash
HERMES_NOTIFY=1 ace autorun --yes               # milestone pings to HERMES_TO
HERMES_NOTIFY=1 HERMES_SNAP=1 ace autorun --yes # also attach a CLI status snapshot to each ping
HERMES_TO=signal:+15551234567 HERMES_NOTIFY=1 ace autorun --yes
```

## Approvals from chat — human-in-the-loop merges

Launch with `MERGE_APPROVAL=hermes` and the loop pauses before every merge, messages you the PR title, URL, and a token, then blocks until you reply.

```bash
MERGE_APPROVAL=hermes ace autorun --yes        # or: MERGE_APPROVAL=hermes ace loop start
ace approve <tok> yes        # release the merge   (ace approve yes = newest pending)
ace approve <tok> no         # leave the PR open and stop
```

```mermaid
sequenceDiagram
    participant Loop as ace loop
    participant Hermes
    participant You
    Loop->>Hermes: PR title + URL + token
    Hermes->>You: Approve merge? reply "ace approve tok yes/no"
    You->>Loop: ace approve tok yes
    Loop->>Loop: merge on green
    Note over Loop,You: explicit deny / timeout / no channel: PR stays open, loop stops
```

What each outcome does today:

| Reply | Result |
|---|---|
| `ace approve <tok> yes` | merge proceeds on green |
| `ace approve <tok> no` | PR left open, loop stops |
| no reply within `APPROVAL_TIMEOUT` (default 1 h) | treated as denied, loop stops |
| no reachable channel (no `hermes` on `PATH`) | PR left open, loop stops |
| **anything else** (free text, a typo, "no thanks") | ⚠️ **recorded as an approval — the merge proceeds** |

> [!WARNING]
> **This is not yet a deny-by-default gate.** `ace approve` treats only `no` `n` `deny` `denied` `reject` `rejected` `0` `❌` as a denial; every other decision string — including one an LLM relay paraphrased — becomes a `yes`. Because the chat bot relays your words into this command, a natural-language refusal can merge the PR. **Deny with the exact word `no`.** The deny-default fix is landing; this warning will be replaced when it ships.

The decision is filesystem-backed (`.opencode/approvals/<tok>.{request,decision}`), so you can also run `ace approve` locally if the chat send fails. Without `MERGE_APPROVAL=hermes` the loop self-merges on green per `AUTOMERGE` — see [autorun.md](autorun.md).

## Grounding the chat agent — `ace hermes mcp`

Run it in the repo. It registers `serena-<slug>` (an absolute `--project` path, so it is repo-scoped) and, best-effort, `gitnexus-<slug>`. After a gateway restart the chat agent can navigate your code — symbol search, find-usages, impact — instead of guessing. For full impact and graph queries, ask the bot to run `ace` in the repo (`terminal workdir=<repo>`) and query GitNexus there.

## GitHub events → chat — `ace hermes webhook`

Subscribes a Hermes route (`gh-<slug>`, events `push,pull_request,workflow_run`) delivering to your channel, then prints the URL to add under the repo's Settings → Webhooks. You get pinged when Actions finishes instead of watching it. Requires the gateway to be publicly reachable.

## Scheduling — recurring autoruns

```bash
ace schedule '0 9 * * 1-5'     # weekday 9am: (re)start this repo's loop, deliver a one-line status
ace schedule 'every 6h'        # manage via: hermes cron list · remove ace-autorun-<slug>
```

`ace hermes` also offers a periodic digest — a Hermes cron posting `ace loop status` every N minutes, silent when idle (no spam). See [remote-control.md](remote-control.md).

## Kanban mirror — `HERMES_KANBAN=1`

One-way and ACE-authoritative: the loop mirrors `ROADMAP.md` onto a Hermes kanban board (`- [ ]` → card, `- [x]` → done) after planning and each merge, for chat-visible progress. It is best-effort and idempotent by content hash.

> [!IMPORTANT]
> ACE stays the executor — do not also run Hermes `kanban swarm` on the same repo. Set the knob on the launch command (`HERMES_KANBAN=1 ace autorun --yes`); for the detached service, `ace loop start` persists it into `.opencode/loop.env`.

## Brain bridge — `ace brain`

If you keep a gbrain knowledge base, `ace brain` files ACE's cross-project host-lessons (`~/.config/ace/host-lessons/<os>.md`) and a repo's `.opencode/lessons.md` into it, so a brain-first chat agent surfaces "how we solved X on this host/project." ACE keeps its own lessons regardless.

## Live dashboard — `ace loop dash`

A full-screen truecolor terminal dashboard: the wordmark, a status bar, agent boxes that recolor per state, and a scrolling log — read live from the loop's files (`loop-state.env` · `last-run.log` · `.agents`). Run it in a second terminal or pane beside a running loop; it watches, it does not drive. `ace loop dash --demo` plays a scripted preview. Full detail in [remote-control.md](remote-control.md).

## Driving ACE from chat — the conductor

The Hermes `ace` skill (`~/.hermes/skills/autonomous-ai-agents/ace/`) turns the bot into a step-by-step conductor. It:

- lists your options and walks one decision per message as tappable buttons (via the `clarify` tool — Telegram and Signal render the choices as an inline keyboard; long menus group into ≤4-button steps);
- assembles the exact `ace … --flags` line, confirms, then runs it headless;
- never auto-sets-up — every gate is your choice.

The companion `ace-workflow` skill is the operational playbook (headless flags, Go pre-flight, host lessons). Both are plain skill files under `~/.hermes/skills/` — edit to taste. ACE re-syncs the `ace` skill to the installed CLI version on every install, update, and `ace hermes`, so it cannot drift.

## Security model

Command-back gives the bot a host shell, so the allowlist that locks it to you is mandatory.

> [!WARNING]
> `ace hermes` sets the allowlist up and keeps `GATEWAY_ALLOW_ALL_USERS` off (the default). Scheduled and cron actions require `cron_mode: allow` in `~/.hermes/config.yaml`. Exactly three `ace` steps are `--confirm`-gated headlessly — **`ace deploy`, `ace vps harden`, and `ace uninstall`**. Everything else runs ungated from chat.

> [!CAUTION]
> **Publishing is NOT confirm-gated.** `ace publish` (and `ace scaffold --publish`) runs `gh repo create --push` with no confirmation prompt, headless or not — so a chat message that reaches it creates a GitHub repository and pushes your code to it immediately. The bot's user allowlist is the only thing standing between a message and a published repo. Keep the allowlist tight, and don't leave a chat session authorized on a host holding code you can't publish.

Full security model and the host-shell threat surface: [remote-control.md](remote-control.md).

## Standalone fallback — no Hermes

Everything above is additive. With no `hermes` on `PATH`:

- notifications, approval, kanban, and cron are no-ops;
- the loop self-merges per `AUTOMERGE`;
- `ace schedule` points you at a systemd `--user` timer;
- `ace brain` gates on `gbrain` instead.

Nothing breaks.

## Environment variables

| Var | Effect |
|---|---|
| `HERMES_NOTIFY=1` | enable milestone pings |
| `HERMES_TO=<chan>` | delivery target (default `telegram`) |
| `HERMES_SNAP=1` | attach a CLI snapshot to each ping |
| `HERMES_KANBAN=1` | mirror `ROADMAP.md` → a Hermes kanban board |
| `MERGE_APPROVAL=hermes` | pause and ask in chat before every merge |
| `APPROVAL_TIMEOUT=3600` | seconds to wait for a chat approval before treating it as denied |

> [!NOTE]
> `ace loop start` captures the launch-time env (channel, opt-ins, approval mode) into `.opencode/loop.env`, because a systemd service inherits none of your shell env. See [configuration.md](configuration.md).

## See also

- [remote-control.md](remote-control.md) — drive ACE from your phone: service, staying reachable, security model
- [autorun.md](autorun.md) — the loop, self-merge, and when it pauses
- [configuration.md](configuration.md) — `HERMES_*`, `MERGE_APPROVAL`, and related knobs
