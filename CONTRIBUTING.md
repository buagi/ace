# Contributing to ACE

Thanks for taking the time — ACE is early (`0.0.1-alpha`), so issues, ideas, and PRs are all genuinely welcome.

> ⚠️ ACE is an **autonomous agent** that runs commands, pushes, deploys, and spends money. Please read the
> [Disclaimer](README.md#-disclaimer--use-at-your-own-risk) — develop and test in a **sandbox / disposable
> environment**, never against production systems or data you can't afford to lose.

## Ways to help

- **Report a bug** — open an issue with the template. Include your OS, the `ace` command, and what happened vs. what you expected.
- **Request a feature** — open an issue describing the problem you're trying to solve (not just the solution).
- **Improve docs** — typos, unclear steps, missing gotchas. Docs PRs are the easiest first contribution.
- **Send code** — see below.

## Quick start for hacking on ACE

```bash
git clone https://github.com/buagi/ace ace && cd ace
ln -s "$PWD/ace" ~/.local/bin/ace       # put `ace` on your PATH
bash -n ace lib/*.sh                     # syntax-check
bash tests/profile-reader.sh             # run a test directly
```

ACE is **bash** — no build step. The libraries live in `lib/*.sh`, the CLI dispatches from `ace`, and
`tests/` holds the checks CI runs.

## Before you open a PR

The same gate CI runs, locally:

```bash
for f in ace lib/*.sh tests/*.sh; do bash -n "$f"; done   # syntax
shellcheck -S error -e SC1090,SC1091 ace lib/*.sh tests/*.sh   # lint (errors only)
bash tests/profile-reader.sh
bash tests/snapshot-generators.sh          # if you touched a generator, run with --update, then review the diff
```

- **Commit messages are Conventional Commits** — `type(scope): summary` (e.g. `fix(vps): …`, `feat(swarm): …`). A commit-msg hook enforces this.
- Keep changes focused; match the surrounding style (terse, no needless deps).
- `main` is protected: PRs must pass **`lint`** and **`tests`**, and are merged by **squash** or **rebase** (linear history). A maintainer merges — you can't merge to `main` directly, that's expected.

## PR flow

1. Fork, branch (`fix/…` or `feat/…`).
2. Make the change, run the gate above.
3. Open a PR against `main` describing **what** and **why**. Link any related issue.
4. CI runs on the PR (first-time contributors' runs need a one-click maintainer approval — normal).
5. A maintainer reviews and merges.

## Code of conduct

Be respectful and constructive. This is a small early project; assume good faith, keep discussion technical.

Questions? Open an issue — no question is too small this early.
