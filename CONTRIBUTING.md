# Contributing to TaskPump

TaskPump starts coding agents against a repository and supervises them for days
with nobody watching. The cost of a change that merely *looks* right is not a red
build — it is an unattended run that spends the night telling an operator
something untrue. Every rule below was bought with an incident of that shape, and
each one is stated with the incident rather than as a bare policy, so you can tell
which parts are load-bearing.

This file is the rules for **changing** TaskPump.
[docs/LEDGER-CONTRACT.md](docs/LEDGER-CONTRACT.md) is the rules for **depending**
on it, and [docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md) is why the
supervisor is shaped the way it is. Read whichever of those covers the surface
you are touching before you touch it.

---

## 1. The standard of truth

This is the section to read if you read only one.

The last two releases have one theme, and both `CHANGELOG.md` entries state it in
their own words. v0.2.0: *a wrong answer must not be able to look like a right
one* — most of what it fixed exited 0 while reporting something false, an empty
frontier or a drained range or a live pump that was not running. v0.2.1 narrowed
that: **every one of its fixes was a tool stating a reason, and in each case the
stated reason was wrong rather than missing.** A pull failure that quoted git's
progress banner — the step that *succeeded* — instead of git's `fatal:`; a
`WAITING` phase blamed on a cross-phase blocker it does not have; a startup
banner naming a pool cap the ticks do not read; a range reported `DRAINED` with
committed work still claimed on a branch; a CRLF task file told its `---`
delimiters were missing when they were right there. Every one of them exited
cleanly. None of them crashed. All of them sent an operator to fix the wrong
thing.

Two of that release's fixes were **rejected on first attempt for committing the
same offence inside the repair**. One replaced a wrong cause with a wrong cause
plus a false reassurance: it told the operator `yq parses it and every verb reads
it` about files that `tp task scrub` calls `NO-ID`, and it returned the CRLF
verdict *instead of* every other check, so following its own advice produced a
completely different diagnosis on the second run (`CHANGELOG.md`, the `#34`
entry). The other asserted a single cause for every possible failure — it
appended "`TASKPUMP_NOTIFY_CMD` takes the message on stdin, not as an argument"
to every notifier failure, which is the wrong cause on a headless host, where a
wrapper that honours the stdin contract exactly still fails for want of a session
bus (the `#35` entry).

So the review question for a change here is not only "does it work". It is:

> **After this lands, is every sentence it emits true?**

Every sentence: diagnostics, warnings, plan lines, `--help` text, log lines, code
comments, the docs it touches, and the `CHANGELOG.md` entry it writes for itself
(§4.2). In practice that decomposes into four habits.

**A diagnostic asserts only what its evidence establishes.** If a probe failed,
say the probe failed; do not name the most likely cause as *the* cause. The
shipped notifier warning is the worked example: it quotes the first line the
notifier itself wrote to stderr, and names the stdin contract as something to
check *only when the notifier wrote nothing at all*.

**A message that names a cause names a reachable one.** A reason string the
repository cannot act on is worse than no reason string. `tp pump --grain phase`
with `--integration-trunk` holds a phase `WAITING` on *"deps done but not yet
integrated into $INTEGRATION_TRUNK"* (`libexec/tp-pump:2033`) when the blocker's
branch never existed — a condition no tick can satisfy — and then, after
`STALL_EXIT_TICKS` idle ticks, exits 3 with a *different* account: "no live
agents, nothing launchable, nothing resumable" (`stall_exit`,
`libexec/tp-pump:2534-2551`), which never mentions the missing branch. Two
reasons, neither actionable, and they disagree with each other. #74 is the
message; #75 is the behaviour behind it.

**A comment is a claim.** `libexec/tp-pump:1398` says "The shipped templates call
this `{{BUILD_GATE}}`"; `rg -n 'BUILD_GATE' templates/` hits only
`templates/README.md`, which states the opposite in as many words — "No shipped
template uses `{{BUILD_GATE}}`" (#57). A comment that is wrong sends the next
reader to delete a live alias.

**Documentation claims are checked, not remembered.** Six sites in this tree said
a defect "is filed as a bug" while the tracker had zero open issues; that is #52,
and it is exactly the failure mode this project exists to be embarrassed by. If
you write "filed", "fixed", "planned" or "scheduled", have the issue number, and
have opened the issue. Prefer a `file:line` or a command whose output you pasted
over a summary you are confident about.

---

## 2. The invariants

### 2.1 shellcheck: zero findings, and the severity never widens

`shellcheck -S warning -x` over `bin/ libexec/ lib/ gates/ runners/ hooks/`
reports **zero** findings. The severity is pinned at `warning` and never widens
back to `error`. Loosening the pin to make a change pass is the one thing it must
not be used for. The gate is `.github/workflows/ci.yml:33-51`.

The ratchet exists because the original pin was `-S error` while the tree carried
a backlog of warning-level findings out of the extraction from Arachne — a
severity chosen to keep CI green rather than to keep the code correct. Task
`tasks/G2.4.md` ("Zero shellcheck warnings, then ratchet CI to `-S warning`",
`status: done`) cleared the backlog so the pin could move, and the point of
moving it is that **any warning the job now reports is one somebody just
introduced**.

Fix the finding rather than silencing it. Where a warning is genuinely wrong
about intent, a `# shellcheck disable=SCxxxx` carries its reason on the same
line — `lib/config.sh:180` (`# path is discovered at runtime by design`),
`libexec/tp-pump:182` (`# read by apl_live_agents (lib/pump-lib.sh)`).
`rg -n 'shellcheck disable' bin/ libexec/ lib/ gates/ runners/ hooks/` returns
twelve lines, seven of them annotated that way; the five bare ones sit above a
deliberate word split (`set -- $spec`, `set -- ${TASKPUMP_NOTIFY_CMD}`) or repeat
a disable whose reason is stated one line earlier (`libexec/tp-monitor:1256`
under `:1254`).

### 2.2 Test hermeticity, in two halves

A suite must be unable to read the world it runs in, and must leave no trace in
the repository it runs from. Both halves are incidents.

**Half one — the suite cannot inherit its world.** `tests/suite-prologue.sh`
closes the two doors:

- *Ambient conf.* The tools discover `taskpump.conf` by walking up from `$PWD`,
  so the conf of whatever repository the suites happen to run from leaks into
  every fixture invocation. TaskPump's own dogfood conf sets
  `TASKPUMP_BUILD_GATE='./tests/run-all.sh'` — that leak once re-entered the whole
  suite unboundedly. The prologue exports `TASKPUMP_NO_CONF=1`; a suite that
  tests discovery itself opts back in per-invocation.
- *Inherited environment (issue #18).* The pump and the container entrypoint
  export `TASKPUMP_TASKS_DIR` / `TP_TASKS_DIR` — pointing at the **real** ledger —
  into every agent session, which is necessarily how an agent's `tp` finds its
  ledger. But `lib/config.sh` gives a canonical spelling the win over its legacy
  twin, so an inherited `TASKPUMP_X` silently outranks the `ARACHNE_X` a fixture
  sets. The 2026-08-13 G3 drain agent saw **64 spurious failures across three
  suites**, each reading the real ledger while believing it read its fixture. The
  prologue unsets every exported `TASKPUMP_*`, `TP_*` and `ARACHNE_*` name by
  enumeration (`compgen -e`), then re-establishes the hermetic baseline:
  `TASKPUMP_NO_CONF=1` and notifications stubbed to `true` in both spellings.

Both `tests/run-all.sh` and every individual `tests/test-*.sh` source it — the
central guard and the standalone guard. A new suite inherits both by opening
with:

```bash
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/suite-prologue.sh"
```

This is enforced, not merely conventional: `tests/test-env-hermeticity.sh:155-167`
greps every `tests/test-*.sh` and `run-all.sh` for a **source line** naming the
prologue (a mention in a comment does not count) and fails if one is missing. Set
anything your fixture needs *after* sourcing it; nothing may be inherited.

**Half two — the suite leaves no trace.** `tests/run-all.sh:37` snapshots
`git status --porcelain` of the repository before the suites run and `:79`
snapshots it again afterwards; any delta is itself a failure. That gate exists
because a git stub's fallthrough answer to `--git-common-dir` once manufactured
`<sha>/info/exclude` trees in the repository root on every run (issue #20).

**The gate is currently blind to gitignored litter, and that matters to you
today.** Neither snapshot passes `--ignored`, so a write to any `.taskpump-*`
run file is invisible to it. Three suites — `test-tp-pump.sh`,
`test-config-resolution.sh` and `test-pump-task-grain.sh` — resolve their
workspace onto the checkout they are running from and clobber or delete its
`.taskpump-fsguard.notified`, the pump's file-system-guard notification mark
(`libexec/tp-pump:2339` writes it, `:2342` deletes it when the hooks fall quiet).
A full run that re-armed or forged a live pump's notification state still prints
`All 25 suite(s) passed.` That is **#111**, milestoned `v0.2.2` — the release
whose stated theme is the safety nets that silently do nothing, and this is the
item that has to land first, because until the gate can see this class of write
no fix for the others can be proven to stay fixed.

Until it lands, the containment is **not** an environment pin. Exporting
`TASKPUMP_HOOK_MARK_FILE` does not survive the prologue's scrub, by design:

```
$ TASKPUMP_HOOK_MARK_FILE=/tmp/pin-probe bash -c \
    '. tests/suite-prologue.sh; echo "after prologue: [${TASKPUMP_HOOK_MARK_FILE:-<unset>}]"'
after prologue: [<unset>]
```

The containment is **the working directory you run from**, and only that. The
three leaking suites never `cd`, so the workspace comes off the cwd rung of
`tp_resolve_workspace` (`lib/config.sh:231-233`) — which reads `$PWD`'s git
worktree, not where the tooling lives. Copying the checkout and invoking the
copy's scripts is therefore **not enough**: from the primary, the copy's own CLI
still resolves onto the primary.

```
$ copy=$(mktemp -d) && cp -a ~/Projects/TaskPump/. "$copy/"

$ cd ~/Projects/TaskPump && "$copy/bin/tp" task resolve --tasks-dir
/home/tjmisko/Projects/TaskPump/tasks            # the copy's CLI, the primary's ledger

$ cd "$copy" && "$copy/bin/tp" task resolve --tasks-dir
<copy>/tasks                                   # only the cd moved it
```

So: `cd` into the copy first, then run the suite there. Never run the full suite
in a checkout a pump is driving.

```bash
copy=$(mktemp -d)
cp -a ~/Projects/TaskPump/. "$copy/"
cd "$copy"            # ← the load-bearing line; without it, nothing is contained
./tests/run-all.sh
```

Measured that way with one of the three leaking suites — `./tests/run-all.sh
pump-task-grain` from inside the copy — the suite passed (`Tests: 107  Passed:
107  Failed: 0`, `All 1 suite(s) passed.`) and the file it rewrote was
`$copy/.taskpump-fsguard.notified`, carrying the suite's own `FS-GUARD: primary
checkout dirty outside allowlist:` text. Run `tp task resolve --tasks-dir` from
where you are standing before you trust any of this: it prints, without writing
anything, which ledger the next invocation will pick.

### 2.3 A fix lands with the assertion that would have caught it

Not "with tests" — with **the** assertion: the one that would have failed before
the fix and passes after it. The v0.2.1 entry for #36 is the shape to copy: no
production code changed at all, and the deliverable was three assertions holding
open a deliberate hole in the runner's environment passthrough, because the only
thing protecting it was a prose comment and "add it for symmetry" was a plausible
edit that would have turned the comment into a lie.

**An assertion is never weakened or deleted to make a change pass.** If a change
genuinely moves an observable surface, the golden files move deliberately and the
diff is part of the review, not a side effect of it.
`tests/test-golden-plan.sh` freezes the pump's three rendered surfaces — the tick
plan, the kickoff brief, and the stalled-claim resume note — byte for byte
against `tests/golden/`, precisely so that a refactor changing one byte of what
an operator or an agent reads fails. Re-record only for an intentional change,
and read the diff before you commit it:

```bash
UPDATE_GOLDEN=1 ./tests/test-golden-plan.sh
```

### 2.4 The ledger has one writer

`tp task` is the only thing that writes task frontmatter. Every mutating verb
takes an `flock` for its entire read-modify-write **and** the git commit that
follows, so concurrent agents — including containers that bind-mount the
repository, where the lock is shared by inode — serialize there. This is not a
convention; it is the correctness argument for the whole system
([docs/LEDGER-CONTRACT.md §8](docs/LEDGER-CONTRACT.md#8-the-one-writer-discipline)).

Two obligations follow for a contributor. **Do not add a second writer**: if a
field you need does not exist, extend `tp task`. **Do not add a second reader
either** — a new tool reads the ledger through the CLI's JSON surfaces, not by
parsing frontmatter, because a direct read is a second implementation of the
schema that no MAJOR bump will ever notify.

Say plainly which half is missing: **nothing enforces this today.** The ledger is
mounted read-write in every runner (`runners/claude-docker/runner.sh:261`,
`:267` — no `:ro`), and `libexec/tp-task:356` stages the *whole* tasks directory
(`git add -A -- "$TASKPUMP_TASKS_DIR"`), so a hand edit is swept into the next
ordinary verb's commit under the CLI's own committer identity. `tp task fsck`
does not catch it: it is a schema check, not a provenance check (#85). Measured
on a copy of this repository's own ledger — flip one task's `status: done` back
to `open` with `sed`, and `tp task fsck` still exits 0 and prints nothing. Treat
one-writer as a review obligation you enforce by reading the diff, not as a
property the tool guarantees.

Resolution is from `$PWD`, never from where the tools are installed
([§8.1](docs/LEDGER-CONTRACT.md#81-where-a-ledger-lives--resolution)) — a scar
from a claim that landed in the primary's ledger while the work happened in a
worktree, leaving the primary silently 46 commits ahead of reality. So a `tp
task` verb run inside a worktree writes **that worktree's** ledger and commits to
**that branch** — unless a `TASKPUMP_WORKSPACE_ROOT` pin is in force, which
outranks `$PWD` deliberately and is the trade a pin buys. Run ledger verbs from
the checkout whose branch should carry the commit, and use `tp task resolve`
whenever a workspace's task state looks wrong.

### 2.5 §10 of the ledger contract is FROZEN

[docs/LEDGER-CONTRACT.md §10](docs/LEDGER-CONTRACT.md#10-the-exit-code-protocol--frozen)
is a wire protocol between processes. Consumers are invited to key on it, so
changing any code in that table is a MAJOR change.

For a change that would diverge from it, the rule is: **the table does not
move.** Either the code comes to match the table, or the divergence is recorded
in §10.1 — the conformance note, which states for the release you are reading
exactly where the tools do not implement the frozen table, and which is
authoritative for a consumer writing code today. Editing §10 to describe what the
code happens to do is the offence in §1 with a contract attached to it.

The divergences on 2026-08-19, both open and both milestoned `v0.3.0`:

- **#71** — `tp task` and `tp pump` never exit 2. §10 reserves 2 for "bad CLI
  arguments, any tool"; both tools route every usage error through a `die()` that
  exits 1, which is also `tp task next`'s "empty frontier" and also every
  operational failure. Exit 2 is not fictional — `bin/tp`, `tp init`,
  `tp cleanup`, both watchdogs and both runners emit it — which makes it worse
  than a uniform miss.
- **#72** — `tp pump` exit 0 does not mean drained. Eight distinct invocations
  reach exit 0 and only the loop's terminal exit is a drain; `--detach` exits 0 in
  the foreground before the run it started has ticked once. §10.1's fallback
  ("read the state file") does not rescue the consumer either, because six of
  those eight paths never write the file — that half is **#69**, milestoned
  `v0.2.2`.

Both are `v0.3.0` rather than `v1.0.0` deliberately: making the code emit 2, or
making exit 0 mean one thing, changes observed behaviour without editing the
frozen table. A change that needed the *table* to read differently is a `v1.0.0`
item and needs a migration note.

---

## 3. Running the checks

### 3.1 What must be installed

README's Quickstart lists `bash` 4+, `git`, mikefarah `yq` v4, `jq`, and GNU
`awk`. That list is right, and it is not exhaustive. What each one is for, and
what its absence actually looks like. Rows that say **Measured** were checked by
running against a two-task fixture ledger with exactly one tool removed from a
purpose-built `PATH`; the rest cite the guard in the source:

| Tool | Used for | Missing it looks like |
|---|---|---|
| `bash` 4+ | namerefs and associative arrays throughout | `tp monitor` and `tp dag-render` check `BASH_VERSINFO` up front and exit 1 naming your version (`libexec/tp-monitor:111`, `libexec/tp-dag-render:59`). Those are the only two `BASH_VERSINFO` sites in `bin/ libexec/ lib/ gates/ runners/ hooks/`; nothing else checks |
| `git` | ledger commits, phase branches, agent worktrees | **not an error, and not mentioned.** `libexec/tp-task:352-356` skips the commit when the tasks directory has no git root — including when `git` is absent entirely. Measured with `git` off `PATH`: `tp task claim T1.1 --branch feat/probe` printed `claimed T1.1 for feat/probe (turn_budget=50)` and mutated the frontmatter, with no commit and no warning (contract §9) |
| `yq` (mikefarah, v4 — **not** the Python `yq`) | every frontmatter read and write, via `--front-matter=extract\|process` | **an empty or blank ledger, reported as an ordinary one.** Measured with `yq` off `PATH`: `tp task ready` prints the header and no rows at rc 0; `tp task list` prints rows of blanks at rc 0; `tp task next` prints `null` at rc 1 — which is also what a genuinely empty frontier does; `tp task fsck` reports every file as `frontmatter is not valid YAML between the --- delimiters`, blaming the ledger for the tool's own missing parser. There is no `command -v yq` anywhere in the tree (#104). CI pins `YQ_VERSION: v4.44.3` (`.github/workflows/ci.yml:18`); v4 is the API the tools are written against |
| `jq` | `tp task next`'s JSON hand-off, the pump's eligibility read, both Claude gates | **nothing guards it, and the pump calls a launchable phase `WAITING`.** Measured: `tp pump --phases T1 --list` with `jq` present printed `LAUNCH T1 -> feat/t1`; with `jq` off `PATH` it printed `WAITING T1 (1 open, none eligible — the ledger lists no open task in this phase — the count and the listing disagree)` and `frontier: 0 launchable`, at rc 0. `tp task next` dies with bash's own `…/libexec/tp-task: line 623: jq: command not found` at rc 127, a code the frozen §10 table does not define. The only two `command -v jq` sites are `lib/pump-lib.sh:506`, inside `apl_host_credentials_problem()` — documented at `:484-485` as "Always exits 0: this classifies, it does not decide" — and `gates/claude-usage:102`, which returns into a cache fallback. Neither guards the frontier |
| `gawk` | the DAG layout engine (`lib/dag-layout.awk` uses `and()`/`or()`, gawk extensions) | probed twice, and named both times: `libexec/tp-dag-render:136-137` exits 1 if the binary is missing, `:138-139` exits 1 if it is not GNU awk. Measured: `TASKPUMP_AWK=mawk tp dag-render` → `ERROR: mawk not found — tp dag-render needs GNU awk (gawk); set TASKPUMP_AWK to override`. This is the row to copy when you add a dependency |
| `flock` | the ledger's cross-agent state lock | degrades to a no-op rather than failing — `libexec/tp-task:452` is `command -v flock … \|\| { dbg "flock unavailable; no state lock"; return 0; }` (contract §8). Correct for a single writer, and silently wrong for concurrent ones |
| GNU coreutils (`df`, `stat`, `date`, `du`) | the disk watchdog, the usage meter, worktree sizing | **undeclared, and destructive when absent.** The probe is `df --output=avail -BG` with its stderr discarded (`libexec/tp-disk-watchdog:110-114`), so a non-GNU `df` yields an empty reading that the state machine treats as 0 GB free: `set_cap 0` pauses every future launch and `docker_panic` (`:184` → `libexec/tp-cleanup:365-366`) runs `docker builder prune -af` and `docker system prune -f` on a host that may have terabytes free (#102) |
| `setsid` (util-linux) | `tp pump --detach`'s fallback, and `runners/local` | `--detach` backgrounds itself at `libexec/tp-pump:2783`, never checks that the child survived, prints a pid and a `stop: kill <pid>` line (`:2786-2787`) and exits 0 with **nothing running**; the local runner (`runners/local/runner.sh:413`) fails its five-second poll instead, with `the agent did not start within 5s` (`:428`), pointing you at your agent command (#104) |
| `curl` | only the Claude usage gate's refresh | not a hard requirement: `gates/claude-usage:102` falls back to a stale-but-valid cache, and with no usable cache `build_decision` reports `severity: unknown` and the gate feeds (`:186-188`). Measured with `curl` off `PATH`: `tp pump --list` printed `GATE: feed-ok` and planned normally |

Running agents additionally needs a container runtime, unless you are on
`runners/local`.

### 3.2 The suites

```bash
./tests/run-all.sh                    # every suite, then a summary table
./tests/run-all.sh task               # only suites whose path matches
./tests/test-tp-task-lock.sh          # one suite, standalone
UPDATE_GOLDEN=1 ./tests/test-golden-plan.sh   # re-record the frozen surfaces
```

`ls tests/test-*.sh | wc -l` answers 25 as of 2026-08-19. The filter is a plain
substring match against each suite's **full path**, so `task` selects six
(`test-pump-task-grain`, `test-tp-task`,
`test-tp-task-fsck`, `test-tp-task-generic`, `test-tp-task-lock`,
`test-tp-task-review`) and a filter that happens to match the directory selects
everything. `run-all.sh` keeps going after a failure so one broken suite does not
hide the state of the rest, and exits 1 if any suite failed or if the repository's
git status moved.

Read §2.2 before running the full suite in a checkout a pump is driving.

A suite is a plain script: it prints `PASS: …` / `FAIL: …` lines, ends with

```
Tests: N  Passed: N  Failed: N
```

which `run-all.sh` greps for the summary table (falling back to counting `^PASS`
and `^FAIL` lines), and it exits non-zero on any failure. Observed, standalone:

```
$ ./tests/test-env-hermeticity.sh
...
--- coverage: every suite and run-all source the shared prologue ---
PASS: every tests/test-*.sh sources the shared prologue
PASS: run-all.sh sources the shared prologue (the central guard)

--- end to end: run-all launches a legacy-spelled suite clean under poison ---
PASS: run-all under pump-poisoned env exits 0 for a legacy-spelled suite
PASS: the nested run reports the suite green

==============================================
Tests: 11  Passed: 11  Failed: 0
==============================================
```

The suites want no container runtime, no network, no real agent, and no checkout
of any particular project: build fixtures in `mktemp -d`, `trap` their removal,
and stub anything external.

### 3.3 shellcheck locally, the way CI runs it

Same file discovery, same flags:

```bash
files=$(find bin libexec lib gates runners hooks \
          -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null | sort)
shellcheck -S warning -x $files
```

`$files` is deliberately unquoted — the word split is the argument list, which is
why CI carries `# shellcheck disable=SC2086` above the line. `-x` follows
`source`d files, so `lib/`'s shared code is analysed in the context of each tool
that sources it. Clean means silent:

```
$ shellcheck -S warning -x $files
$ echo $?
0
```

CI installs shellcheck from `apt-get` unpinned, so the version you run locally and
the version the job runs are not guaranteed to agree; a newer shellcheck can
report a finding CI has not seen yet. Fix it anyway — it will be CI's finding at
the next runner-image bump.

---

## 4. Branches, commits, and releases

### 4.1 Branches, and how to propose a change

**The first action: branch, then open a draft PR against `main`.** Do not commit
to `main`; cut a feature branch or a worktree, push it, and
`gh pr create -d --base main`. Every pull request this repository has ever had —
nineteen, as of 2026-08-19 — targets `main`
(`gh pr list --state all --json baseRefName`). An *agent* driven by the pump is
the exception and is told so by its brief: under `--integration-trunk` it opens
against the trunk it was cut from, which `AGENTS.md` covers. A human contributor
targets `main`.

Branch shapes in use, from `git branch -a`:

- `fix/issue-<n>-<slug>` when you are fixing a filed issue. This is the common
  case and the shape to reach for: all eleven fixes in the v0.2.1 sweep used it
  (`fix/issue-33-task-lock-litter` … `fix/issue-48-stranded-claim-false-drain`).
- `fix/<slug>` when there is no issue number yet.
- `feat/<slug>`, or `feat/<task-id>-<slug>` when the work is a ledger task, as in
  `feat/g4.5-suite-env`.
- `docs/<topic>`, `chore/<topic>` for an integration branch that collects
  several, and `release/vX.Y.Z`.

Single changes land through their own PR (`Merge pull request #51 from
tjmisko/release/v0.2.0`). A sweep does not: several branches merge into one
`chore/` integration branch and that lands as a unit (`Merge branch
'docs/truth-repairs' into chore/followup-integration`) — which is why the eleven
`fix/issue-*` branches above have no PRs of their own.

**If you cannot set labels or milestones** — an outside contributor cannot —
write the release class you believe applies, and the reason, in the PR
description: *"PATCH: makes the code match its own documented behaviour"*, using
the tests in §4.3. A maintainer applies the `release:` label and the milestone.
Label and milestone agreed on every open issue when §4.3 was measured, so a
silent guess is worse than saying which class you meant and why.

### 4.2 Commits

Conventional commits, with an optional scope. Over the last 100 commits on `main`
as of 2026-08-19: `fix` 32, `docs` 16, `feat` 6, `test` 5, `chore` 3,
`refactor` 1, plus 34 merges and three ledger commits (`complete G4.4`) that
`tp task` writes for itself and that are not conventional. Recount with:

```bash
git log -100 --format='%s' main \
  | sed -E 's/^(Merge).*/merge/; s/^([a-z]+)(\([^)]*\))?:.*/\1/' | sort | uniq -c | sort -rn
```

Scopes name the tool or surface — `fix(pump):`, `fix(fsck):`, `docs(config):`,
`fix(runner-local):`, `chore(release):`.

One commit, one logical change. The subject states **what is now true**, not what
was edited:

```
fix(pump): report the notifier's first line as a line, not as the reason
fix(pump): quote git's error for a failed ops pull, not git's progress banner
fix(fsck): decide CRLF last, and from the whole frontmatter block
```

The body is where the reasoning goes: what an operator saw, why the obvious
repair was wrong, and what was measured. No emoji.

**Your change writes its own `CHANGELOG.md` entry, under an `## Unreleased`
heading.** That is the practice, and it is the reason §4.4's release commit
touches only two files: it dates the `Unreleased` heading with the version and
folds the sweep's entries in beside it, rather than authoring them. `5715c6e`'s
own body says so — "the CHANGELOG's `Unreleased` heading gets its date and the
entries written across this sweep are folded in beside it" — and the ledger tasks
say the same from the other side (`tasks/G2.3.md:33`, `tasks/G3.1.md:62`). Note
that `CHANGELOG.md` carries no `## Unreleased` heading right now
(`rg -n '^## ' CHANGELOG.md` shows `0.2.1`, `0.2.0`, `0.1.0`), because v0.2.1 has
just been cut — the first change after a release creates it. Write the entry in
the house style described in §4.4 step 3.

### 4.3 Which release a change belongs to

The rule lives in
[docs/LEDGER-CONTRACT.md §1](docs/LEDGER-CONTRACT.md#1-versioning). The tracker
encodes how it is applied, in three labels that map one-to-one onto three
milestones. On 2026-08-19 there were 73 open issues (#52–#124), and every one
carried a `release:` label matching its milestone — no exceptions. The counts
below are of that date; recount them with:

```bash
gh issue list --state open --limit 200 --json number,milestone,labels \
  | jq -r 'group_by(.milestone.title // "none") | map({ms: .[0].milestone.title, n: length})'
```

| Label | Milestone (open, 2026-08-19) | The label's own description |
|---|---|---|
| `release:v0.2.2` | `v0.2.2` (36) | PATCH-safe: ships in v0.2.2 |
| `release:v0.3.0` | `v0.3.0` (37) | Behaviour change: needs a MINOR |
| `release:v1.0.0` | `v1.0.0` (0) | Frozen-contract change: needs a MAJOR or a migration note |

In practice:

- **PATCH** — making the code match its own documented behaviour, plus
  diagnostics and documentation. #52 (six docs claiming defects are "filed" when
  nothing was filed) is PATCH. So is #104: guarding a missing `yq` changes an
  answer that was never correct.
- **MINOR** — changing a default, or making a documented configuration key
  actually do something. #117 (the trunk build gate defaults to `cargo check
  --workspace`, so any non-Rust repository quarantines every phase) and #119
  (`TASKPUMP_USAGE_GATE` / `TASKPUMP_DISK_GATE` hardcoded to 1 and exported over
  the operator's value) are both MINOR. So are #71 and #72: an exit code that
  moves *toward* the frozen table still changes what a caller observes.
- **MAJOR** — changing a reserved exit code or anything else in the frozen wire
  protocol, the frontmatter schema, the status vocabulary, the state machine, the
  eligibility predicate, or the id-grammar contract. The practical test from §1
  of the contract: if a consumer that was correct against version *N* could become
  incorrect against *N+1* without changing a line of its own code, it is MAJOR.

One live tension, which you should raise rather than resolve on your own: the
`v0.1.0` release commit (`0fbf96f`) states that the flipped defaults are frozen
and "any further default change is a MAJOR bump", while the `v0.3.0` milestone
plans exactly that as MINOR ("defaults that assume a Rust workspace"). The
tracker is what is being applied today. If your change turns on that distinction,
ask before you pick a milestone.

### 4.4 Cutting a release

Three releases have been cut — `v0.1.0`, `v0.2.0`, `v0.2.1`. (`git tag -l` prints
a fourth tag, `archive/f15-canvas-interaction-2026-04-15`, which is not a version
tag.) What those three actually did:

1. On the integration or `release/` branch, one commit `chore(release): vX.Y.Z`
   that touches `VERSION` and `CHANGELOG.md` and nothing else. `5715c6e` is the
   template: `2 files changed, 161 insertions(+), 10 deletions(-)`. The
   `CHANGELOG.md` half dates the existing `## Unreleased` heading and folds the
   sweep's entries in beside it; it does not author entries the changes should
   already have written (§4.2). `0fbf96f` says the same of v0.1.0: "the
   CHANGELOG's Unreleased heading gets the date".
2. That commit's body names the semver class **and justifies it against the
   contract**, field by field — v0.2.1's says: "No frontmatter field, status
   vocabulary entry, state transition, eligibility predicate, id grammar rule or
   exit code changed, and every 0.2.0 ledger is read unchanged."
3. The `CHANGELOG.md` entry opens with the theme of the release, then one entry
   per fix in the house style: what an operator saw, the wrong reason they were
   given, what it says now, and — where a first attempt was rejected — why. Where
   a divergence was found and deliberately *not* closed, the entry says so and
   says why (v0.2.1: "documented rather than fixed, since closing them is a
   behaviour change").
4. Merge to `main` and tag. `v0.2.1` and `v0.2.0` tag the merge commit; `v0.1.0`
   tags the release commit itself.
5. Before tagging, re-check the truth claims the release makes about itself —
   nothing should say "filed" or "fixed" that is not (§1, #52).

A GitHub Release object is not part of the routine: only `v0.2.0` has one. The
tag is the marker.

---

## 5. TaskPump drains its own ledger

`tasks/` is TaskPump's own task DAG, driven by TaskPump, under the `G` grammar
this repository configures for itself (`TASKPUMP_ID_PATTERN='^G[0-9]+(\.[0-9]+)?$'`,
`taskpump.conf:41`). On 2026-08-19 it held 34 task files, all of them
`status: done`, and `tp task ready --count` answered `0`; the backlog that day
was the 73 open issues on the tracker (#52–#124), not the ledger. Check both
before you assume: `ls tasks/*.md | wc -l` and `tp task ready --count`.

The same conf sets `TASKPUMP_BUILD_GATE='./tests/run-all.sh'`: the suite *is* the
dogfood pump's answer to "is the tree broken?". That is also why the hermeticity
prologue exists in the shape it does — see §2.2.

A contribution can therefore arrive as ledger tasks rather than as a patch, and a
maintainer planning a drain will encode a phase that way:

```bash
tp task create G6.1 --title "..." \
    --goal  "one sentence naming the outcome, not the activity" \
    --files lib/pump-lib.sh --blockers G5.2
```

If you are authoring or completing tasks, read
[docs/LEDGER-CONTRACT.md](docs/LEDGER-CONTRACT.md) first — §3 for the schema, §5
for which transitions exist, §6 for why a task is or is not on the frontier. Fill
in `files:`: `--grain task` schedules two tasks concurrently only when their
declared footprints are disjoint, and a task declaring no files runs alone. That
check is an exact string match today, so a task declaring `lib/` and one
declaring `lib/a.sh` are treated as disjoint and co-scheduled (#91) — declare
paths, not directory prefixes, until that closes. Never hand-edit frontmatter
(§2.4).

---

## 6. Reporting a vulnerability

Do not open a public issue for a security finding in the sandbox, the credential
handling, or the agent trust boundary. [SECURITY.md](SECURITY.md) is the
reporting channel.

TaskPump ships under the Apache License 2.0 ([LICENSE](LICENSE)); contributions
are made under it.
