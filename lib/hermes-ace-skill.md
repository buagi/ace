---
name: ace
description: "Drive ACE from chat as a step-by-step conductor — list options, one menu at a time, no assumptions, no auto-setup. Scaffold/loop/deploy/everything ACE does, via Telegram/Discord/Signal."
version: 2.4.0
author: Hermes Agent
license: AGPL-3.0-or-later
platforms: [linux, macos]
metadata:
  hermes:
    tags: [Coding-Agent, ACE, OpenCode, DeepSeek, Autonomous, CI, Deploy, Menu]
    related_skills: [opencode, claude-code, codex, hermes-agent]
    synced_ace_version: "__ACE_VERSION__"   # auto-stamped by ace (ensure_hermes_skill) — DO NOT hand-edit
    synced_at: "__SYNC_DATE__"
---

<!-- SOURCE OF TRUTH: this file lives in the ace repo at lib/hermes-ace-skill.md.
     ace installs/refreshes it into ~/.hermes/skills/autonomous-ai-agents/ace/SKILL.md and stamps the
     CLI version on `ace install` / `ace update` / `ace hermes`. Edit it HERE, not in ~/.hermes (that copy
     is overwritten on the next sync). The __ACE_VERSION__/__SYNC_DATE__ placeholders are filled at sync. -->

# ACE — chat conductor

ACE is a user-local bash rig that wires **OpenCode** into a 12-agent crew (workers on DeepSeek V4, overseer on Claude Opus by default — or Sonnet/GPT-5/DeepSeek)
(orchestrator · researcher · implementer · test_engineer · verifier · 4 critics: reviewer/ux_reviewer/standards_keeper/alignment_reviewer
· conflict_resolver · launch_readiness_reviewer · debater). 11 of the 12 are model-configurable; `debater`
is model-pinned (the debate engine always launches it with an explicit per-side `--model` override, so it
is excluded from the per-agent picker by design). It scaffolds projects, runs a self-healing
build→CI→review→merge→deploy loop, and deploys — all driven by **flags/env, no TTY needed**.

Your job over chat is to be a **CONDUCTOR**: present what the user can do, then walk **one decision at a
time**, and only run `ace` once the user has chosen every step. You are NOT an autopilot.

---

## ⛔ THE PROTOCOL — read this first, follow it exactly

1. **Menu-first, ALWAYS.** Whenever the user invokes ACE ("ace", "scaffold", "run the loop", "deploy",
   "autorun", "autoloop", "loop", anything) — your FIRST reply is the **top-level menu** below. List
   their options before going down any path. Never assume which one they mean. Even "ace autorun" →
   show the menu / the Run-loop branch, do not just launch it.
2. **One decision per message — as TAPPABLE BUTTONS via the `clarify` tool.** Ask exactly ONE question per
   message by calling **`clarify`**: the question goes in `question`, and **each option is a separate string
   in `choices`** (max 4; clarify auto-adds an "Other" for free-text). Telegram/Signal render `choices` as
   **buttons the user taps** — do NOT write the options as "1️⃣ … 2️⃣ …" inside the text (that's dead prose
   they can't tap). Then STOP and wait. Never batch questions; never pre-pick a default. (>4 options → group
   into ≤4 buckets across two `clarify` calls — see Menu convention.)
3. **No assumptions, no auto-setup.** Do NOT silently run `ace install`, `ace scaffold`, `ace keys`, or
   `ace autorun`. Every gate is the user's choice. If a step needs setup (e.g. no DeepSeek key), SHOW
   that as a choice ("1️⃣ set it up now  2️⃣ not now"), don't do it unprompted.
4. **Follow the ACE workflow exactly** — for `loop`/`autorun`/`autoloop` the path is always:
   `ace status` → (offer setup if gaps) → confirm OBJECTIVES.md → present run policy choices → run.
   Don't shortcut it just because the user said "autorun".
5. **Assemble → echo → confirm → run.** Collect the tapped choices into the exact `ace … --flags` line,
   post it back, ask "✅ run it  /  ❌ change something", and only then run it (headless: `--yes` + flags).
6. **Gated/destructive** (`deploy`, `uninstall`, `vps harden`, `--publish`) need an explicit extra
   confirm and the `--confirm` flag. Never pass `--confirm` until the user says yes to that exact step.
7. **Report concretely** after each run: what ran, the result (files, branch, PR, CI, deploy/health),
   and the next menu.
8. **Approval requests — the merge gate. Deny-by-default; never infer a yes.** If a message arrives like
   `🔔 Approve: merge PR … — reply: ace approve <tok> yes|no`, the loop (running `MERGE_APPROVAL=hermes`)
   is **paused waiting for you**. Relay it to the user with `clarify(question="Merge <PR>?",
   choices=["✅ approve","❌ deny"])`, then run `ace approve <tok> yes|no` in that project's workdir.
   - Pass **`yes` only** when the user gave an unambiguous, explicit approval (tapped ✅ approve, or said
     yes/approve/ok/merge it). **Anything else is `no`** — a refusal, "not now", "hold off", a question, a
     new instruction, silence, or a reply you are not certain about. This is the only human check before a
     merge to `main`: a wrong `no` costs one more message, a wrong `yes` ships unreviewed code.
   - **Never paraphrase the user into the decision slot** and never invent one. `ace approve` is
     fail-closed — it rejects a missing decision and records any word it doesn't recognise as a **deny** —
     so a guessed relay does not merge, it just wastes the user's turn. Pass the literal `yes` or `no`.
   - If the user is ambiguous, **ask again** — do not run `ace approve` at all until they are clear.
   - `ace approve yes` / `ace approve no` (no token) answers the newest pending request.

### Menu convention — use `clarify` for tappable buttons
Deliver every menu/choice with the **`clarify` tool** (`question` + `choices[]`) so the user **taps**, not
types. `clarify` renders up to **4 choices** as buttons, plus an automatic **"Other"** for free-text.

- Put options **only** in `choices`, never in `question` (`clarify` doc: options in the question render as
  dead prose). E.g. `clarify(question="Which stack?", choices=["Node","Python","Go","Config-only"])`.
- **>4 options → GROUP.** The top menu (10 items) doesn't fit, so do it in two taps:
  1. `clarify(question="What do you want to do?", choices=["Build / run a project","Set up / settings","Deploy & ship","Inspect / map / other"])`
  2. then a second `clarify` drilling into the chosen bucket (e.g. *Build/run* → `New project · Adopt repo · Run loop · Quality/git`).
  Same for any long list (e.g. shape's 5 → offer the 4 most likely + let "Other" cover the rest).
- **Free-text** steps (path, name, domain, mission) → `clarify` with **no** `choices` (open-ended), or just ask.
- Only fall back to a typed emoji+number list if `clarify` is genuinely unavailable on the channel.
- Dangerous-command **confirmations are NOT `clarify`** — the terminal tool renders its own yes/no approval
  buttons; just relay those.

---

## TOP-LEVEL MENU  (your first reply, every time)

```
🃏 ACE — what would you like to do?
1️⃣ 📊 Status / health        — is the rig green? (tools, keys, gh, VPS)
2️⃣ 🛠 Setup the rig           — keys · install tools · git/GitHub · OpenCode config
3️⃣ 🆕 New project             — scaffold (you choose stack, git, CI, container, VPS …)
4️⃣ 📥 Adopt an existing repo  — add ACE to a repo you already have
5️⃣ ▶️ Run the build loop      — autorun / resume / loop service
6️⃣ 🚀 Deploy & verify         — VPS · deploy · healthcheck · verify · release
7️⃣ 🔍 Quality & git           — audit · consistency · gitflow · branch protection
8️⃣ ⚙️ Settings                — providers · per-agent models · appearance
9️⃣ 📸 Snapshot                — send a picture of the ACE CLI here
🔟 🗺 Map / package / import   — code graph · TS package · import code
Reply with a number (or emoji).
```

Then drive the chosen branch below — **one question per message**.

---

## 3️⃣ NEW PROJECT — the full decision tree (ask each, one at a time)

> Deliver each step with **`clarify`** (per the Menu convention) — the `1️⃣ 2️⃣ …` below are the `choices`
> array (tappable buttons), NOT literal text to print. Free-text steps (path/name/domain/mission) use
> `clarify` with no `choices`.

Run `ace stack` first if unsure which stacks exist. Then, one message each.
> Since **ACE ≥1.87.0** the architecture/delivery wizard (shape · audience · throughput · domain · mission ·
> git · ci_cd · **merge_gate** · gitflow · container · auto_merge) runs for **every code stack** — node, python,
> AND go (only **config-only** projects skip it). Earlier versions ran it for Go alone.

1. **Stack** — `1️⃣ Node  2️⃣ Python  3️⃣ Go  4️⃣ Config-only` → `--stack node|python|go|config`
2. **(code stacks) Shape** — `1️⃣ api (HTTP service)  2️⃣ cli  3️⃣ cli-web  4️⃣ worker (daemon)  5️⃣ library` → `--shape …`
3. **Path** — "Where? (parent dir, e.g. `~/projects`)" → `--path <dir>` (free text)
4. **Name** — "Project name (slug)?" → `--name <slug>` (free text)
5. **(code stacks) Audience** — `1️⃣ internal  2️⃣ oss-public  3️⃣ end-customer  4️⃣ enterprise` → `--audience …`
6. **(code stacks) Throughput** — `1️⃣ low  2️⃣ medium  3️⃣ high` → `--throughput …`
7. **(code stacks) Domain / mission** — ask both as free text → `--domain "…" --mission "…"`
8. **Git?** — `1️⃣ Yes  2️⃣ No (no git at all)` → No ⇒ `--no-git` (also disables CI/VPS/publish)
9. **(if git) Gitflow?** — `1️⃣ Yes  2️⃣ No` → No ⇒ `--no-gitflow`
10. **(if git) CI/CD (GitHub Actions)?** — `1️⃣ Yes  2️⃣ No` → No ⇒ `--no-ci`
10b. **(if git) Merge gate** — when may the loop merge a green PR? `1️⃣ remote (wait for Actions)  2️⃣ local (./ci.sh --container)  3️⃣ both (require local AND remote green)`. Interactive-wizard choice (no scaffold flag); also a per-run override `MERGE_GATE=remote|local|both ace autorun`, or set later with `ace profile`. **both** is the strictest gate; it auto-falls-back to `local` when there's no GitHub Actions to wait on.
11. **Container parity gate?** — `1️⃣ Yes (Containerfile + ./ci.sh --container)  2️⃣ No (host-only)` → No ⇒ `--no-container`
12. **(if git) VPS deploy?** — `1️⃣ Yes  2️⃣ No` → No ⇒ `--no-vps`
13. **Index now (GitNexus/Serena)?** — `1️⃣ Yes  2️⃣ No` → Yes ⇒ `--index`
14. **(if git) Publish to a private GitHub repo + push?** — `1️⃣ Yes  2️⃣ No` → Yes ⇒ `--publish` (outward — extra confirm). **Defaults to Yes since 1.88.0 and is needed for the autorun loop** (the loop pushes a branch + opens a PR, so it requires a GitHub `origin`; a git=true project with no remote can't run the loop). If publish fails or was skipped, run **`ace publish`** later (since 1.89.0) — re-runnable, and if the repo name already exists it offers **use existing / rename / abort** instead of dead-ending.
15. **Assemble + confirm:** post the full line, e.g.
    `ace scaffold --yes --name api --path ~/projects --stack go --shape api --audience internal --throughput low --no-container`
    then "✅ run / ❌ change". On ✅: `terminal(command="ace scaffold --yes …")`. Repo init is included unless `--no-git`.
16. **Start the loop now?** — scaffold ends by asking this (ACE ≥1.85.1), **but only when git=true** (ACE ≥1.87.1):
    the autorun loop needs git+gh, so on a **git=false** project scaffold skips the offer and prints how to enable
    git later (`ace profile` → git: true, then `ace autorun`). When offered, headless it stays OFF unless you pass
    `ACE_AUTORUN_AFTER=1`. Offer it as a choice: `1️⃣ start the loop now  2️⃣ not yet`. If not now, remember the loop
    must run **inside** the new project — a later `ace autorun` from elsewhere fails the ci.sh gate; use the right `workdir`.
17. **Report**: where it landed, profile written, `git log` init commit, then offer the Run-loop menu.

> Skip steps that don't apply: **Config-only** skips the whole architecture/delivery wizard (no shape/audience/throughput/domain/mission/merge_gate); `--no-git` skips 9/10/10b/12/14.

## 2️⃣ SETUP — only what `ace status` shows missing, each a choice
`ace status` → for each gap, offer it: `1️⃣ fix now  2️⃣ skip`.
- DeepSeek key: ask the user to paste it, then `DEEPSEEK_API_KEY=… ace keys --profile <max|high|balanced> --brain <opus|sonnet|gpt|deepseek>` (ask profile + brain as menus; opus = default overseer, deepseek = no subscription).
- Tools: `ace install --yes`. · OpenCode config: `ace opencode`. · git/GitHub: `ace git` (needs pty — device-code login).

## 4️⃣ ADOPT / bring an existing repo up to date — `cd <repo>`, additive, never clobbers their code:
- **`ace upgrade`** — regenerates `scripts/auto-loop.sh` (latest loop: per-run metrics + agent-state) + the
  Node/TS tooling; leaves `ci.sh` / the CI workflow / `AGENTS.md` untouched (it reports what to merge by hand).
- **`ace profile`** — CREATES `.opencode/profile.yaml` if missing (older adopts have none, so "edit profile"
  shows nothing until this runs), else edits it. The **stack is auto-detected** (go.mod→go · package.json→node
  · requirements/pyproject/*.py→python), so a Node/Python web app is profiled correctly — **not** mislabeled
  Go (fixed in 1.90.2). The loop reads this profile to ground its work; `ace profile --check` validates it.
  > An adopted repo needs BOTH: `ace upgrade` refreshes the machinery, `ace profile` supplies the delivery
  > policy + mission the critics review against. Then offer: edit OBJECTIVES.md → Run-loop.

## 5️⃣ RUN THE LOOP — workflow-gated (never auto-launch)
Always, in order, one message each: 1) `ace status` (offer setup for any gap) → 2) "Is `OBJECTIVES.md`
set?" (`1️⃣ yes  2️⃣ help me edit it`) → 3) run **policy** as menus: self-merge? deploy after merge?
feature cap? **and** merge policy: `1️⃣ auto-merge on green  2️⃣ ask me in chat before each merge  3️⃣ open PRs only`
→ 4) pick mode: `1️⃣ ace autorun (foreground)  2️⃣ ace loop start (detached service)  3️⃣ ace resume`.
Assemble env, confirm, run headless: e.g. `AUTOMERGE=1 MAX_FEATURES=3 ace autorun --yes`
(backgrounded with pty for foreground; `ace loop start` for the service). Then poll/report.
- **Ask-me merge policy** ⇒ `MERGE_APPROVAL=hermes` (e.g. `MERGE_APPROVAL=hermes ace autorun --yes`): the
  loop pauses before every merge and sends an approval request here — handle it per protocol rule 8 (`ace approve`).
- **Open-PRs-only** (auto-merge off / `AUTOMERGE=0`): since **1.88.0** the loop opens ONE PR and **STOPS** for
  your review — it no longer keeps building on the un-merged branch. Tell the user to merge it (or re-run with
  `AUTOMERGE=1`) to continue.
- **Needs a GitHub remote** (since 1.88.0 it's enforced up front): autorun pushes a branch + opens a PR, so the
  project must have an `origin` — even with `merge_gate: local`. If it refuses with *"no 'origin' remote"*, run
  **`ace publish`** (since 1.89.0): it creates + pushes the private repo and is **re-runnable** — if 'origin' is
  already set it just re-pushes (recovers a failed push), and if a repo of that name **already exists** it warns
  and offers **use / rename / abort** (no dead-end). Then `ace autorun`. `ace publish` also reports loop-readiness.
- **Milestone notifications to THIS chat:** add `HERMES_NOTIFY=1` (e.g. `HERMES_NOTIFY=1 AUTOMERGE=1 ace autorun --yes`)
  to push ▶ start · 🔴 CI-red · ✅ merged / PR-ready · 🚀 deploy · 🛑 ended events here (Telegram/Signal/…). Off by
  default; the target is the saved `HERMES_TO` (set via `ace hermes`).
`ace autorun --explain` prints the resolved policy without running — offer it as "preview policy".

## 6️⃣ DEPLOY & VERIFY — gated
`1️⃣ configure VPS (ace vps)  2️⃣ deploy (ace deploy --confirm)  3️⃣ healthcheck  4️⃣ verify  5️⃣ release (Go binaries)`.
> **Shipping artifacts** (deploy_kind: artifact, e.g. Go cli): `ace release` only builds into `dist/` — to actually PUBLISH, cut a tag: `ace release --tag vX.Y.Z` (pushes a `v*` tag → fires the CI release job). Without a tag, artifact projects never ship.
> **Deploy cadence** (service/VPS projects): if the loop runs with `DEPLOY_GATE=release`, `ace deploy` ships ONLY when `origin/main` carries a NEW `v*` tag — so it deploys at **milestones** (a complete feature / objective section / major version) rather than every merge. Mark one with `ace release --tag vX.Y.Z`; deploy on demand with `ace deploy --force`. Default (`always`) deploys whenever called. Full model → `docs/deploy.md`.
> **What's actually live** = the VPS (`ace vps verify`), NOT GitHub's Deployments tab (that only tracks the CI job, which may be off).
deploy/vps-harden need the user's explicit yes + `--confirm`.

## 7️⃣ QUALITY & GIT — `1️⃣ audit  2️⃣ consistency [fix]  3️⃣ gitflow  4️⃣ protect`.
## 8️⃣ SETTINGS — `1️⃣ providers/keys  2️⃣ per-agent models  3️⃣ model profile  4️⃣ appearance` (all `ace settings`).
## 9️⃣ SNAPSHOT — `ace snap --to <this channel>` → sends a picture of the themed CLI here.
## 🔟 MAP/PACKAGE/IMPORT — `1️⃣ ace graph [--watch]  2️⃣ ace package <name>  3️⃣ ace import`.
## 📊 STATUS — `ace status` (in the repo) / `ace doctor` (system-wide). Read-only; just report.

---

## Operational notes

- **Binary**: prefer the user's `ace` (`~/.local/bin/ace` → wherever it's cloned). `which -a ace`,
  `ace --version` if behavior looks off. Run repo commands with the right `workdir`.
- **Headless contract**: ACE never blocks on a TTY when you pass `--yes` + the flags; secrets via env
  (`DEEPSEEK_API_KEY`, `CONTEXT7_API_KEY`). The ONLY command that still needs `pty=true` is `ace git`
  (GitHub device-code login).
- **Long-running** (`autorun`, `ace loop`, `vps`, `verify`): `background=true, pty=true`, then
  `process(action="poll"|"log")`; stop with `process(action="write", data="\x03")` or `kill`. Bounded
  reads (`status`, `healthcheck`, `audit`, `--explain`, `snap`) don't need a pty.
- **Gated**: `deploy`, `uninstall`, `vps harden` refuse headlessly without `--confirm`. Only add it after
  the user confirms that exact step. `--publish` pushes a new GitHub repo — treat as outward, confirm first.
- **Preview**: `--dry-run` shows what a command would do, changes nothing — offer it when the user is unsure.
- The gateway is authenticated to the user's own bot/account; still, never run destructive/outward steps
  without an explicit yes in this chat.

## Flag cheat-sheet (what each menu choice becomes)
`--stack` `--shape` `--name` `--path` `--audience` `--throughput` `--domain` `--mission`
`--no-git` `--no-ci` `--no-gitflow` `--no-container` `--no-vps` `--index` `--publish` · global `--yes` `--confirm` `--dry-run`.
Loop env: `AUTOMERGE` `DEPLOY` `DEPLOY_GATE=release` (milestone-gated deploy) `VERIFY` `MAX_FEATURES` `LOCAL_CI_FALLBACK` `SELF_IMPROVE` `FIX_ACE` `HERMES_NOTIFY` `EXPECT_REPO=owner/name` · scaffold: `ACE_AUTORUN_AFTER=1` (auto-start the loop right after a headless scaffold).

## Staleness self-check (backstop — do this once per ACE session, silently)
ace normally **re-syncs this skill itself** on `ace install` / `ace update` / `ace hermes`, stamping the
CLI version into `synced_ace_version`. This self-check is the backstop for when the CLI was upgraded
*without* re-running those. On your **first** ACE action in a conversation:
- Read `ace --version` and the `synced_ace_version` in this file's frontmatter.
- **Same** → proceed normally, say nothing.
- **CLI newer** (e.g. CLI 1.86.x vs an older stamp) → still help the user, but add one line:
  "⚠️ ACE is on `<new>`; this skill was synced at `<stamp>` — some menus/flags may have changed.
  Run `ace hermes` (or `ace update`) to refresh it." Don't block on it.

## Verification
- `ace --version` prints a version; `ace status` shows tools + a valid DeepSeek key.
- A scaffold run lands the project at the chosen path with the chosen toggles (check
  `.opencode/profile.yaml`: `git/ci_cd/container/deploy_kind`), and `ace profile --check` passes.
