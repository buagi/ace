# Hermes integration — drive ACE from chat

ACE runs perfectly **standalone**. When [Hermes Agent](https://hermes-agent.org/) is also installed, ACE
*collaborates* with it: milestone notifications, approvals, scheduling, code-graph grounding, and a live
dashboard — all over **any** chat channel.

Two principles hold everywhere:

- **Opt-in + fail-soft.** Every Hermes touch-point is gated on `command -v hermes`. No `hermes` on PATH (or
  a send error, or a feature turned off) degrades to a **silent no-op** — it can never break or block the loop.
- **Channel-agnostic, Telegram-first.** The delivery target resolves as `HERMES_TO` env › stored
  `config HERMES_TO` › **`telegram`**. Any channel works: `telegram` · `telegram:<chat_id>` · `signal:+1555…`
  · `discord:<id>` · `slack:#chan` · `whatsapp:<id>` · `matrix:…`.

> For the "fire ACE from your phone while away" runbook (service + staying reachable + the security model),
> see **[remote-control.md](remote-control.md)**. This page is the full feature reference.

---

## Setup — ACE side vs HERMES side (two systems, set separately)

This is the part that trips people up. **Two config homes, and they own different things:**

| You want to… | Owned by | Where / how |
|---|---|---|
| **Bind the bot to a Telegram/Signal channel** + authorize who may use it (token, channel **id**, allowed users) | **Hermes** | `~/.hermes/.env` via `hermes gateway` → **then restart the gateway** |
| **Enable command-back** (the bot runs `ace …` on the host) for a platform | **Hermes** | per-platform toolset in `~/.hermes/config.yaml` (`ace hermes` offers it); gated by `approvals: mode: manual` |
| **Choose WHERE ACE sends notifications** | **ACE** | `HERMES_TO` (a single target *string*) — set via `ace hermes` |
| **Turn notifications on for a run** | **ACE** | `HERMES_NOTIFY=1 ace autorun --yes` |
| **Ask-before-merge from chat** | **ACE** | `MERGE_APPROVAL=hermes` (+ `ace approve`) |
| **Schedule recurring autoruns** | **ACE** (uses Hermes cron) | `ace schedule '<when>'` |

> **Rule of thumb:** ACE only ever sets **`HERMES_TO`** (one destination string) + per-run opt-in env. The
> **channel itself — its id, token, and who's authorized — belongs to Hermes** (`~/.hermes/.env`, applied by
> `hermes gateway` + a gateway restart). **That's why there's no "Telegram channel id" field in the ACE
> console** — ACE doesn't own the channel, only the target string that points at one Hermes already knows.

### Path A — bind a channel (HERMES side, do this first)
```bash
hermes gateway                 # interactive: bot token + home channel + allowed users/chats
# …or edit ~/.hermes/.env directly:
#   TELEGRAM_BOT_TOKEN=…             (from BotFather)
#   TELEGRAM_HOME_CHANNEL=<id>       ← the channel/chat id the bot calls home   ← "the channel id"
#   TELEGRAM_HOME_CHANNEL_NAME=…
#   TELEGRAM_ALLOWED_USERS=<id,…>    TELEGRAM_GROUP_ALLOWED_CHATS=<id,…>
#   (Signal uses SIGNAL_* / a registered number instead)
systemctl --user restart hermes-gateway     # REQUIRED — .env is read ONLY at gateway start
```

### Path B — point ACE at it (ACE side)
```bash
ace hermes                                   # prompts "Hermes target…" → saves HERMES_TO
#   telegram             → the gateway's home channel (default)
#   telegram:<chat_id>   → a specific chat (must be one the gateway is authorized for)
HERMES_TO=signal:+15551234567 ace hermes     # non-interactive: pin a channel
ace hermes mcp                               # (optional) ground the chat agent on THIS repo's code graph
```

`ace doctor` shows the resolved ACE-side target on its `hermes/chat` line (`target=… · hermes=wired|absent`);
`hermes gateway` / a test `hermes send` confirm the Hermes-side channel.

> **Command-back is per-platform.** Enabling it adds the `terminal` toolset to that platform's bundle in
> `config.yaml`, so a platform without it can receive notifications + chat but **cannot execute** `ace`.
> (E.g. a common setup: command-back on **Signal**, notifications to **Telegram** — check
> `hermes` `config.yaml platform_toolsets`.) Either way, execution is gated by `approvals: mode: manual`.

## The command surface

| Command | What it does |
|---|---|
| `ace hermes` | The hub — wires loop **milestone notifications** + **command-back** (the bot runs `ace …` on the host, locked to your id) to your channel. |
| `ace hermes mcp` | Registers this repo's **code-graph servers** (Serena `--project`, GitNexus best-effort) with the Hermes agent, so chat questions ("what calls X?", "impact of Y?") are **grounded** — the same servers OpenCode uses. |
| `ace hermes webhook` | Subscribes a Hermes **webhook route** for GitHub **CI/PR events → chat**, and prints the route to add to the repo's GitHub webhooks. Needs a publicly-reachable gateway. |
| `ace publish [name]` | Create + push the repo's private GitHub `origin` so the loop can run (it pushes a branch + opens a PR). **Re-runnable** — re-pushes if origin is set, and offers **use / rename / abort** if the name already exists. The conductor uses this for the "no 'origin' remote" / failed-push case. |
| `ace approve [tok] yes\|no` | Answers a pending **merge-approval** request (paired with `MERGE_APPROVAL=hermes`). No token = the newest pending request. |
| `ace schedule '<when>'` | Registers a **recurring autorun** for this repo via Hermes cron (`'0 9 * * 1-5'` · `'every 6h'` · `'30m'`). |
| `ace brain` | Files ACE's cross-project **host-lessons** + this repo's `.opencode/lessons.md` into **gbrain**, so the brain-first chat agent surfaces them. |
| `ace snap [--to <chan>]` | Screenshots the themed CLI to a PNG and sends it as a media attachment. |
| `ace loop dash` | A live **dashboard** (see below) — watch a running loop in a second pane. |

## Notifications (push)

The autorun loop texts you curated milestones — `started · merged · deployed · CI-red · rathole · blocked ·
stopped` — via `hermes send`. Opt in per run:

```bash
HERMES_NOTIFY=1 ace autorun --yes              # milestone pings to HERMES_TO
HERMES_NOTIFY=1 HERMES_SNAP=1 ace autorun --yes # …also attach a CLI status snapshot to each ping
HERMES_TO=signal:+15551234567 HERMES_NOTIFY=1 ace autorun --yes
```

## Approval from chat — human-in-the-loop merges

Launch with **`MERGE_APPROVAL=hermes`** and the loop pauses before **every** merge, messages you the PR
title + URL + a token, and blocks until you reply:

```bash
MERGE_APPROVAL=hermes ace autorun --yes        # or: MERGE_APPROVAL=hermes ace loop start
# chat → "🔔 Approve: merge PR … — reply: ace approve <tok> yes|no"
ace approve <tok> yes        # ✅ release the merge   (ace approve yes = newest pending)
ace approve <tok> no         # ❌ leave the PR open and stop
```

It's a true **fail-closed** gate: deny, a timeout (`APPROVAL_TIMEOUT`, default 1 h), or no reachable channel
all leave the PR open and stop. Without `MERGE_APPROVAL=hermes` the loop self-merges on green per `AUTOMERGE`
(see [autorun.md](autorun.md#confirmations--when-and-whether-it-pauses)). The decision is filesystem-backed
(`.opencode/approvals/<tok>.{request,decision}`), so you can also `ace approve` locally if the chat send fails.

## Grounding the chat agent — `ace hermes mcp`

Run it **in the repo**. It registers `serena-<slug>` (an absolute `--project` path, so it's repo-scoped) and,
best-effort, `gitnexus-<slug>`. After a gateway restart the chat agent can navigate *your* code — symbol
search, find-usages, impact — instead of guessing. For full impact/graph, ask the bot to run `ace` in the
repo (`terminal workdir=<repo>`) and query GitNexus there.

## GitHub events → chat — `ace hermes webhook`

Subscribes a Hermes route (`gh-<slug>`, events `push,pull_request,workflow_run`) delivering to your channel,
then prints the URL to add under the repo's **Settings → Webhooks**. So you get pinged when Actions finishes
instead of watching it. Requires the gateway to be publicly reachable.

## Scheduling — recurring autoruns + a status digest

```bash
ace schedule '0 9 * * 1-5'     # weekday 9am: (re)start this repo's loop, deliver a one-line status
ace schedule 'every 6h'        # manage: hermes cron list · remove ace-autorun-<slug>
```

`ace hermes` also offers a **periodic digest** — a Hermes cron posting `ace loop status` every N minutes,
**silent when idle** (no spam). See [remote-control.md §6](remote-control.md).

## Kanban mirror — `HERMES_KANBAN=1`

One-way, ACE-authoritative: the loop mirrors `ROADMAP.md` onto a Hermes kanban board (`- [ ]` → card,
`- [x]` → done) after planning and each merge, for chat-visible progress. ACE stays the executor — **don't**
also run Hermes `kanban swarm` on the same repo. Set it on the launch command
(`HERMES_KANBAN=1 ace autorun --yes`); for the detached service, `ace loop start` persists it into
`.opencode/loop.env`.

## The brain bridge — `ace brain`

If you keep a **gbrain** knowledge base, `ace brain` files ACE's cross-project host-lessons
(`~/.config/ace/host-lessons/<os>.md`) and a repo's `.opencode/lessons.md` into it, so brain-first chat
surfaces "how we solved X on this host/project." ACE keeps its own lessons regardless.

## The live dashboard — `ace loop dash`

A full-screen terminal dashboard (truecolor): the wordmark, a status bar, the agent boxes that recolor per
state, and a scrolling log — read live from the loop's files (`loop-state.env` · `last-run.log` · `.agents`).
Run it in a **second terminal/pane** beside a running loop (it watches; it doesn't drive). `ace loop dash
--demo` plays a scripted preview. See [autorun.md](autorun.md).

## Driving ACE from chat — the conductor

The Hermes **`ace` skill** (`~/.hermes/skills/autonomous-ai-agents/ace/`) turns the bot into a step-by-step
**conductor**: it lists your options, walks **one decision per message** as **tappable buttons** (via the
`clarify` tool — Telegram/Signal render the choices as an inline keyboard; long menus group into ≤4-button
steps), assembles the exact `ace … --flags` line, confirms, then runs it headless. It never auto-sets-up — every gate is your
choice. The companion **`ace-workflow`** skill is the operational playbook (headless flags, Go pre-flight,
host lessons). Both are plain skill files under `~/.hermes/skills/` — edit to taste.

## Security model

Command-back gives the bot a **host shell**, so the allowlist that locks it to **you** is mandatory —
`ace hermes` sets it up, and keeps `GATEWAY_ALLOW_ALL_USERS` off (the default). Scheduled/cron actions
require `cron_mode: allow` in `~/.hermes/config.yaml`. Destructive/outward `ace` steps (`deploy`, `vps
harden`, `--publish`, `uninstall`) still refuse headlessly without `--confirm`, even from chat.

## Standalone fallback (no Hermes)

Everything above is additive. With no `hermes` on PATH: notifications/approval/kanban/cron are no-ops, the
loop self-merges per `AUTOMERGE`, `ace schedule` points you at a systemd `--user` timer, and `ace brain`
gates on `gbrain` instead. Nothing breaks.

## Env-knob reference

| Var | Effect |
|---|---|
| `HERMES_NOTIFY=1` | enable milestone pings |
| `HERMES_TO=<chan>` | delivery target (default `telegram`) |
| `HERMES_SNAP=1` | attach a CLI snapshot to each ping |
| `HERMES_KANBAN=1` | mirror `ROADMAP.md` → a Hermes kanban board |
| `MERGE_APPROVAL=hermes` | pause + ask in chat before every merge |
| `APPROVAL_TIMEOUT=3600` | seconds to wait for a chat approval before treating it as denied |

> Detached-service note: `ace loop start` captures the **launch-time** env (channel + opt-ins + approval
> mode) into `.opencode/loop.env`, because a systemd service inherits none of your shell env — see
> [configuration.md](configuration.md).
