# Engineering lessons

Durable record of the **2026-07-18 audit**: 152 verified defects, 8 PRs. Written for whoever extends ACE next — human or agent.

## Read this first: the fixes were as defective as the code

The single most important finding is not in the list of traps below. It is this:

> **Three generations of fixes each re-introduced the bug class they were fixing.**

A fix for a fail-open check shipped with its own fail-open. A fix for a swallowed return code swallowed a return code one level up. By the third generation of delegated repair, an agent was about as likely to *add* a defect as to remove one — the correct move at that point is to stop delegating and fix by hand.

Two consequences that shape everything else on this page:

1. **Every defect was found by REPRODUCTION, never by reading.** Reading a diff — human or model — did not catch these. Running the code did. A review that did not execute the failure is not evidence.
2. **The discipline items in [§B](#b-fix--review-discipline) are not ceremony.** They are the only things that actually caught the bad fixes. The mechanical traps in §A are the cheap half; §B is the half that works when the trap is novel.

Treat §A as a checklist you can automate and §B as the part you cannot.

---

## A. Mechanical traps

Each of these is a *shape* you can grep for. One-line fix, and what it actually broke.

### A1 — `local a=X b=$a`

**Fix:** split into two `local` statements.

The `$a` in the second assignment expands from the **outer** scope, not from the `a=X` on the same line — under `set -u` that is an unbound variable. This killed the cross-model debate on entry, silently, because the failure landed behind a fail-open path (§C1) that reported the debate as having run clean.

*In-tree today:* `lib/debate.sh` uses the split form throughout (`local m; m="${DEBATE_MODEL_A:-...}"`).

### A2 — `grep -c PAT f || echo 0`

**Fix:** `|| true`, then default at use with `${v:-0}`.

`grep -c` prints `0` **and** exits 1 when there are no matches, so the `||` branch appends a second `0`. The value becomes `"0\n0"`, which fails every integer comparison downstream.

*In-tree today:* `lib/swarm-dash.sh:77-78` and `:121` carry the counter-example in a comment; `lib/reanalyze.sh:18` wraps it in `_ra_c()`.

### A3 — `cmd 2>&1` captured into a value that is later parsed as data

**Fix:** keep the streams separate — redirect stderr to its own file or `/dev/null`, and capture the rc separately.

`go list` writes `go: downloading <mod>` to **stderr while exiting 0**, so folding stderr into stdout put that text *into a package list*, and the next step ran `go build go: downloading … app`. The same shape folded `gh`'s stderr into what was supposed to be a PR number.

*In-tree today:* `lib/scaffold.sh:1687` — `_golist_out=$(go list ./... 2>/tmp/ci-golist.err) || _golist_rc=$?`, with the surrounding comment spelling out that *failing* and *returning nothing* are different facts that must be judged separately.

### A4 — `printf … | grep -q` under `set -o pipefail`

**Fix:** use a here-string — `grep -q PAT <<<"$v"` — which has no second process to die.

`grep -q` exits on its first match; `printf` is still writing; past the 64 KiB pipe buffer `printf` takes SIGPIPE and `pipefail` propagates **141**. A data-loss guard read that non-zero rc as "no WIP" and deleted the branch. **Measured: the rc flipped to 141 at ~215 KB.**

*In-tree today:* `lib/swarm-run.sh:198-201` — the fix and the measurement are both in the comment.

### A5 — `git check-ignore` on a tracked path

**Fix:** add `--no-index`.

A **tracked** path is never reported as ignored without it, so an untrack sweep matched nothing and reported success having done nothing.

*In-tree today:* `lib/consistency.sh:80`.

### A6 — an apostrophe inside a single-quoted block

**Fix:** don't — restructure the quoting.

Inside a single-quoted bash string (a `jq` or `awk` program, an embedded snippet), an apostrophe **terminates the string**. What follows is reparsed as shell. This one is worth stating baldly because it is the trap most often committed *while writing up the trap*.

### A7 — a file written without a trailing newline, then read with `read`

**Fix:** always terminate the line; and preset the defaults *before* the `read` rather than relying on its exit status.

`read` returns 1 on a final line with no terminator, so a fallback keyed on that rc fires **every time**. This made every loop step record `active_s=0`/`build_s=0`, and every run summary print `~0m active-think · ~0m builds`. The numbers were being measured correctly the whole time and thrown away at the reader.

*In-tree today:* `lib/autoloop.sh:874-878` (comment: "TRAILING NEWLINE IS LOAD-BEARING"); asserted by `tests/autoloop-selftest.sh:69-85`, which demonstrates the shell semantics *and* asserts both writers and the reader.

### A8 — a REPL-ish tool on non-TTY stdin

**Fix:** pin `</dev/null`.

`opencode run` (and anything else that reads stdin) blocks forever waiting for EOF when stdin is not a terminal.

*In-tree today:* `lib/debate.sh:36`, `lib/vps.sh:447`.

### A9 — `trap … EXIT`, then sourcing a lib that installs its own

**Fix:** don't rely on a single EXIT trap surviving a `source`; re-assert it after, or clean up explicitly.

Bash has **one** EXIT trap. The sourced library's `trap … EXIT` silently replaces yours. Here it leaked a multi-MB fixture per test run.

### A10 — trusting a pidfile, then killing tree-wise

**Fix:** verify identity (read `/proc/<pid>/cmdline`) before signalling, and refuse **only on positive evidence of mismatch**.

A recycled pid takes out an innocent process *and its children*. Note the asymmetry in the fix: an unreadable cmdline is not evidence of a mismatch, so it must not silently become a refusal-to-clean-up either.

*In-tree today:* `lib/swarm-run.sh:833-838` — "Refuse ONLY on positive evidence of a mismatch".

### A11 — `cmd; ok "success"`

**Fix:** gate the success message on the rc.

The `;` claims success unconditionally from the moment `cmd` can fail. This is §C3 in miniature and it is everywhere in shell.

### A12 — resolving state inside a command substitution

**Fix:** resolve in the parent shell; a subshell cannot write back.

A "resolve once, then cache" probe placed inside `$( … )` re-ran on **every** frame forever, because the assignment died with the subshell. It never *stuck*, so it never looked broken — it was only expensive. **Measured: 83 ms/frame against a 3.1 MB `events.jsonl`.**

*In-tree today:* `lib/swarm-dash.sh:614`. (This one comes from the code's own comment rather than the audit's numbered list — see [§Provenance](#provenance).)

---

## B. Fix + review discipline

The traps above are the ones a linter can own. These are the ones that caught the *bad fixes*.

### B1 — a test that passes either way is worthless

Revert the fix in a temp copy and **prove the test goes red**. If you did not do this, say "I did not verify" — that is an acceptable answer. A false claim is not.

### B2 — a test that nothing runs is not a gate

Wire it into CI **in the same commit**. A suite existed, passed locally against a dirty tree, and was in no workflow — main was red while CI was green.

> [!WARNING]
> This is live in the repo right now. `tests/hygiene-selftest.sh`, `tests/scorecard-selftest.sh` and `tests/reanalyze-selftest.sh` are in **no workflow** (verified against `.github/workflows/*.yml`). They are suites, not gates, until someone wires them.

### B3 — verify from `git archive HEAD`, never the working tree

The tree lies about what actually merged.

### B4 — commit with explicit paths, checked against what changed

`git add -A <dirs>` silently dropped an entire file, shipping a PR whose description claimed fixes that were not in it.

### B5 — sweep downstream consumers of every changed interface

Return code, output format, file path, config key, function signature, deleted symbol. **Three fixes broke a caller one level up.** The sweep is not optional and it is not "probably fine".

### B6 — adversarial review must reproduce, not read

See the opening section. Reading found none of these.

### B7 — the four-question self-check

Per hunk of your own diff:

1. Does it **swallow an error**?
2. Does it **trust an unvalidated value**?
3. Does it **delete something recoverable**?
4. Does it **claim success it cannot vouch for**?

**Every one of the 152 defects failed exactly one of these.** That is the whole checklist; it is short on purpose.

### B8 — delegation has a depth limit

By the third generation, agents were as likely to add a defect as remove one. Switch to fixing by hand.

### B9 — a fixture must mirror what the generator really produces

A fixture with the spec title on line 2 hid a bug that failed **100% of real specs**, which put it on line 3.

*In-tree today:* `lib/swarm.sh:503` documents the real layout — a marker line, then the `# Spec: …` heading on **line 3** — and why `head -2` could never see it.

### B10 — never blanket-ignore a tool directory

`.serena/` swallowed 15 real authored documents. Ignore the transients by name, not the directory.

### B11 — do not document a guarantee that does not hold yet

Describe the broken behaviour honestly until the fix ships, then reword. The B2 warning box above is this rule applied to this page.

---

## C. Design defaults

### C1 — fail-open reporting is the dominant defect class

**34 of the 152 findings.** A check that did *not* run must never print `clean` / `ok` / `PASS`. Return an explicit **inconclusive** state and make the caller decide.

Note that fail-open is sometimes the *correct, deliberate* choice — ACE's cross-model debate is opt-in and documented as fail-open by design (`lib/debate.sh` header). The defect is not fail-open behaviour; it is fail-open behaviour that **reports as a pass**.

### C2 — asymmetry of harm decides the default

A wrong deny costs one round-trip. A wrong approve ships unreviewed code to main. Default to deny.

### C3 — report what actually happened, not the happy path

`WIP preserved` was printed while a SIGKILL discarded it.

### C4 — long silent stretches are indistinguishable from a hang

Narrate long operations with progress. This is why the loop heartbeats and the dash pulses every frame.

### C5 — generated artifacts need their ignore rule at feature-birth

Otherwise the next rescue-commit sweeps them into git, and then you need A5's `--no-index` sweep to get them back out.

---

## Where lessons are stored

Lessons are only durable if the next run reads them. Three stores, three scopes:

| Store | Scope | Written by |
|-------|-------|-----------|
| `.opencode/lessons.md` | one project | The loop appends one terse deduped line per task. `compact_lessons` caps it at `LESSONS_MAX_LINES` (default **200**) and archives the overflow. In a swarm each worker writes its own `.opencode/lessons/<branch>.md` shard and the coordinator aggregates into the canonical file. |
| `~/.config/ace/host-lessons/<os>.md` | one machine, all projects | The rathole supervisor, so a host-level trap solved in one repo is avoided in the next. |
| `${ACE_CONFIG_DIR}/lessons.md` | all projects on the machine | The **shared lessons store** — see [configuration.md](configuration.md#lessons-stores). |

`ace brain` files the host + repo lessons into gbrain when it is present.

See [configuration.md](configuration.md#lessons-stores) for the paths and precedence.

---

## Provenance

Because this page will be cited as authority, here is what rests on what.

**Verified against the code in this repo** (file:line cited inline): A1, A2, A3, A4 (incl. the ~215 KB measurement), A5, A7 (incl. the `active_s=0` symptom), A8, A10, A12 (incl. the 83 ms/frame measurement), B2's live warning, B9, and every path/default in *Where lessons are stored* except the shared store.

**From the audit record, not currently cited to a line of code:** A6, A9, A11, the "34 of 152" and "100% of specs" counts, and all of §B and §C. These are findings about work that has since been fixed, reverted, or that concerns process rather than a surviving artifact.

**Verified in the code as of this writing:** the shared lessons store is implemented — `ACE_LESSONS_SHARED` (`lib/core.sh:186`, defaulting to `${ACE_CONFIG_DIR}/lessons.md`, XDG-aware), with `lessons_shared_init` / `lessons_view` / the compaction and promotion helpers alongside it, a read-only mirror of `lessons_view` in `lib/autoloop.sh` (the loop cannot source `core.sh` without running its EXIT trap), and the store documented to agents in the generated `AGENTS.md` (`lib/install.sh`). Promotion from a project store to the shared one is deliberately NOT automatic: lessons are DATA that must never be executed, so ACE only ever queues candidates.

Also **not claimed**: there is no bash-traps lint gate wired into `.github/workflows/ci.yml` as of this writing. When one lands, §A becomes partly mechanical; until then it is a reading checklist.

---

See also: [testing.md](testing.md) · [configuration.md](configuration.md) · [autorun.md](autorun.md) · [agents.md](agents.md)
