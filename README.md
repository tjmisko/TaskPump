# TaskPump

TaskPump is a task DAG and an agent supervisor for long-running autonomous work.

Record tasks as markdown files with YAML frontmatter. Each task file records
its status, its blockers, its goal, its definition of done, its claim, and
relevant context for a coding agent. The `tp` CLI is the only reader and writer
of task state, so claims are atomic, every mutation is a git commit, and
nothing is ever hand-edited into a shape the state machine would not allow.
Because the ledger is just files in a directory, it diffs, it reviews in a pull
request, it merges, and it survives every tool in this repository being
deleted.

On top of that ledger sits a **pump**, a supervisor that can keep a planned
taskloop going for days by (1) recomputing the eligible frontier every tick and
(2) launching sandboxed agents against eligible tasks. The open task frontier
is derived from declared blockers. When work becomes unblocked, it becomes
available on the frontier.

**Robustness to Agent and Machine Failure**: The pump is designed assuming
that unplanned interruptions will occur and that agents will not reliably
finish their work. The supervisor derives liveness by looking at processes to
corroborate the task status recorded by agents in their sessions for robustness
against interruptions by the OOM killer, power failures, etc. This prevents
dangling tasks and bad state from clogging the pump. The supervisor can also be
configured to pause task ingestion when the plan's usage reaches a threshold.
It resumes a task stranded behind an abandoned claim, with a note telling the
new agent what the dead one already committed. And it exits loudly on a genuine
deadlock instead of idling green.

The full accounting of failures which led to the requirements that produced
this design is in [docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md).

---

## Quickstart

Requirements: `bash` 4+, `git`, [`yq`](https://github.com/mikefarah/yq) (mikefarah's
Go implementation, v4 — **not** the Python `yq`), `jq`, and `awk` (GNU awk for the
DAG renderer). Running agents additionally needs a container runtime.

```bash
git clone https://github.com/tjmisko/TaskPump
ln -s "$PWD/TaskPump/bin/tp" ~/.local/bin/tp
```

### 1. Point it at your project

TaskPump works bare. A repository that keeps its ledger in `tasks/` with
`T`-shaped ids (`T1`, `T2.1`) needs **no** configuration at all — from the root
of the repository you want driven:

```bash
mkdir tasks
```

That directory's presence is what marks a repository as carrying its own
ledger; `tp task resolve` prints which ledger any invocation would touch.

A `taskpump.conf` at the same root is how you diverge from the defaults — a
ledger somewhere else, a different id grammar:

```bash
TASKPUMP_TASKS_DIR=planning/tasks             # ledger lives elsewhere
TASKPUMP_ID_PATTERN='^J[0-9]+(\.[0-9]+)?$'    # different sigil — set TASKPUMP_PHASE_SIGIL=J too
```

Add these when you start running agents:

```bash
TASKPUMP_BUILD_GATE='npm test'          # what "is the tree broken?" means here
TASKPUMP_IMAGE=my-project-agent         # the image agents launch from — no default;
                                        #   a real run aborts loudly without one
TASKPUMP_PUMP_JOBS=1                    # start at one; raise after you watch a drain
```

`examples/minimal.conf` is a commented conf to start from;
`examples/arachne.conf` is a fully-configured real consumer, annotated with why
each hardening default exists. [docs/CONFIG.md](docs/CONFIG.md) covers discovery
and precedence, and `taskpump.conf.example` is the complete key census.

### 2. Create some tasks

```bash
tp task create T1 --title "Define the settings struct" \
    --goal "There is one typed home for every setting the daemon reads."

tp task create T2.1 --title "Parse the config file" \
    --goal "The daemon reads its settings from disk instead of compiled-in defaults." \
    --blockers T1 --files src/config.rs
```

Ids are `PHASE` or `PHASE.N`. The phase is the pump's unit of dispatch and what a
range names; the sigil is yours. Blockers are validated on creation — an id that
does not exist would silently remove the task from the frontier forever.

The goal is one sentence describing the **outcome**, distinct from the acceptance
criteria in the body. It is what an agent reads first, so it is worth writing
properly. `tp task goal --missing` lists tasks that lack one.

### 3. Inspect the frontier

```bash
tp task ready                    # every eligible task: open, blockers all done
tp task ready --count            # all open work in range  — "is anything left?"
tp task ready --count-eligible   # frontier size           — "what can start now?"
tp task next --branch feat/t2    # the single next task, as JSON
```

Those two counts answer different questions, and the difference is the whole
diagnostic. Work remaining with nothing eligible means something is stalling the
queue — see [docs/LEDGER-CONTRACT.md §6](docs/LEDGER-CONTRACT.md#6-the-eligibility-predicate).

### 4. Work a task

By hand or by agent, the loop is the same:

```bash
tp task claim T2.1 --branch feat/t2 --turns 50
tp task heartbeat T2.1 --start
#   ... do the work, commit it ...
tp task heartbeat T2.1 --end
tp task complete T2.1 --commits "$(git rev-parse HEAD)"
```

If it cannot proceed, say so rather than leaving it claimed:
`tp task block T2.1 --reason "..."` for an external dependency,
`tp task release T2.1 --reason "..."` to simply hand it back. Both free whatever
was waiting behind it.

### 5. Run the pump

Always plan before you launch:

```bash
tp pump --phases T1..T9 --dry-run     # the plan and the gate decision, no side effects
tp pump --phases T1..T9 --once        # exactly one real tick, then exit
tp pump --phases T1..T9 --jobs 2      # drain, staying under two concurrent agents
```

`--dry-run` prints each phase as `LAUNCH`, `RUNNING`, `RESUME`, `WAITING`, or
`DONE`, plus why feeding is or is not permitted. Read it before every real run;
it is the cheapest way to find out that a phase you expected to start is gated on
something you forgot.

The dispatch unit is the **phase** by default: one workspace per phase, whose
agent drains that phase serially while phases fan out in parallel. When a phase
holds long independent siblings — or when your range is a single phase — that
serializes work the jobs cap had room for, and `--grain task` dispatches each
eligible task on its own branch instead:

```bash
tp pump --phases T3 --grain task --jobs 3 --dry-run
```

The same plan, one line per task (`LAUNCH T3.4 -> feat/t3.4`). Two tasks run
concurrently only when their declared `files:` sets are disjoint — an overlap
waits and the plan names the path, and a task that declares no files at all runs
alone, because an unknown footprint must not be scheduled as an empty one. So fill
in `files:` before reaching for this grain. Everything else is unchanged: the same
gates, the same jobs cap, the same resume and deadlock behaviour, one agent per
branch. See [docs/PUMP-MECHANISMS.md §1](docs/PUMP-MECHANISMS.md).

Pick the grain before you start, not during: a claim belongs to the branch that
took it, and the two grains derive different branches (`feat/t3` vs `feat/t3.4`).
Restarting a range at the other grain leaves any in-flight claim stranded, since
neither the reclaim nor the resume pass will touch a branch this run's naming
scheme does not own. The plan says so every tick — `WAITING T3.4 (claimed by
feat/t3, no live container)` — and the run reaches its deadlock exit (3), whether
or not other open work remains beside it: a range is never reported **drained**
while a claim is still in flight. Finish or `tp task release` an in-flight claim
before changing grain.

### 6. Watch

```bash
tp monitor
```

Watching is the default on a tty; piped output renders one frame and exits
(`--glance` forces that, `--interval 5` sets the cadence).

A live TUI with two tabs: `SESSIONS` for what agents are doing, `GRAPH` for the
task DAG laid out by dependency, with the selected task's goal, budget, and
blockers in the header.

---

## Try it without a project

There is a standing fixture — a small project that has nothing to do with the one
TaskPump came from:

```bash
cd tests/fixtures/generic-project
tp task list
tp task ready --count            # 3 — open work remains
tp task ready --count-eligible   # 1 — one task can start now
tp task next --branch feat/t2
```

`tests/fixtures/generic-project/README.md` walks through what each task in it
demonstrates, including a three-command demonstration of the frontier mechanism:
complete a task, and the one that was waiting on it becomes eligible with nothing
rescheduled.

---

## Adopt in an existing repo

The quickstart works bottom-up from an empty directory. This is the same arc
for a repository that already exists — yours — from scaffold to a first
supervised tick, with something to read at every step. Nothing here asks you to
trust an agent yet: the first launch is a stub you watch.

### 1. Scaffold

From anywhere inside the repository you want driven:

```bash
tp init
```

It writes a starter `taskpump.conf` at the worktree root — only the keys a new
consumer actually decides, id grammar spelled out — and creates `tasks/` beside
it (`--tasks-dir planning/tasks` puts the ledger elsewhere). It refuses, naming
the file, if a conf is already discoverable from where you stand: a second conf
would shadow the first for part of the repository. It commits nothing.

Two lines of repository hygiene before anything writes state. The conf belongs
in history; the runtime droppings do not — ignore them the way TaskPump's own
repository does. (Do **not** ignore `.worktrees/`: the pump refuses to launch
into a gitignored worktree.)

```bash
cat >> .gitignore <<'EOF'
.taskpump-task.lock
.taskpump-pump.state
.taskpump-pump.log
.taskpump-pool-cap
.taskpump-usage-reset
.taskpump-fsguard.notified
.taskpump-disk-watchdog.log
.taskpump-monitor-notes/
EOF
git add taskpump.conf .gitignore && git commit -m "chore: adopt TaskPump"
```

That last line is the one people leave out, and it is the one that bites: the
monitor's scratchpad (`n` in the TUI) writes a note file into a directory at the
repository root, which is neither ignored by default nor in the contamination
guard's allowlist. Take one note during a drain and the guard reports

```
FS-GUARD: primary checkout dirty outside allowlist:
?? .taskpump-monitor-notes/
```

on every tick for the rest of the run, and pushes a desktop notification the
first time. Note the line break: the header and the offending paths are separate
lines (`lib/pump-lib.sh:590`), so grep for `dirty outside allowlist` rather than
for a whole sentence naming the path.

Then run `tp task resolve --all`. It prints which ledger every invocation from
here will touch and how it decided — it is the diagnostic every error message
points at, and thirty seconds now beats reading it for the first time
mid-incident.

### 2. Author tasks — or import the ones you already have

Authoring from scratch is quickstart §2, unchanged: `tp task create`, blockers
validated on creation, a one-sentence goal that is worth writing properly.

If the repository already keeps a directory of markdown task files, point
`TASKPUMP_TASKS_DIR` (and `TASKPUMP_ID_PATTERN` plus `TASKPUMP_PHASE_SIGIL`, if
your ids are not `T`-shaped) at what you have — the scaffold leaves an existing
tasks directory untouched — and let `fsck` run the import:

```bash
tp task fsck          # every contract violation, one line each; exit 3
tp task fsck --fix    # stamp the MISSING machine keys with their defaults
tp task fsck          # clean; exit 0
```

`--fix` stamps only what is absent — `status: open`, empty blockers, the null
claim fields — and never rewrites a value that is present but wrong: guessing
intent is how ledgers get corrupted. What it cannot invent (a missing `id` or
`title`, frontmatter that does not parse, ids outside the grammar, a blocker
cycle) stays on the report for you to resolve by hand. The fix pass is itself a
ledger commit, so the import diffs and reviews like any other change. A stamped
goal is `null`; `tp task goal --missing` lists the tasks still owing one, and
that debt is worth paying before an agent reads them.

### 3. Inspect the frontier

Quickstart §3, plus the DAG:

```bash
tp task ready                    # every eligible task
tp task ready --count            # all open work in range
tp task ready --count-eligible   # what can start right now
tp dag-render --phases T1..T2    # the graph, statuses inline
```

Work remaining with nothing eligible means something is stalling the queue —
that difference is the whole diagnostic, and
[docs/LEDGER-CONTRACT.md §6](docs/LEDGER-CONTRACT.md#6-the-eligibility-predicate)
is how to read it.

### 4. Choose a runner

**`runners/claude-docker`** is the hardened reference: agents run in a
container, behind an egress allowlist, with the primary checkout mounted
read-only and credentials installed access-token-only, so a container can
authenticate but never rotate the host's tokens. The price of those guarantees
is an image: TaskPump ships the runner, not the image, and a real run aborts
loudly until `TASKPUMP_IMAGE` names one satisfying the contract in
[docs/RUNNERS.md §4.0](docs/RUNNERS.md#40-the-image-contract). This is the
runner for unattended work.

**`runners/local`** has nothing underneath it — no image to build, no daemon to
talk to. It starts the agent as a plain host process, and **it does not sandbox
anything**: the agent runs as you, with your permissions, your filesystem, your
network and your credentials, and nothing between it and your machine but its
own restraint. That is fine for a supervised experiment and wrong for an
unattended drain of an untrusted workload — [docs/RUNNERS.md §3](docs/RUNNERS.md#3-runnerslocal--the-process-runner)
says this at greater length, and it bears repeating. It is also the runner that
lets you rehearse the whole loop with a stub before any real agent exists,
which is exactly what the next two steps do.

### 5. Where the tools live

Nothing so far cared where TaskPump itself is installed, and neither does the
pump. The workspace it drives — the phase branches it cuts, the agent worktrees
it materialises, the state file it writes — is a property of the **caller**,
resolved exactly as the ledger is: the discovered `taskpump.conf`'s directory,
else the worktree you are standing in. One checkout on `PATH` drives any number
of repositories, and its own directory stays out of their runs.

Vendoring a copy inside the repository is therefore a choice, with its own good
reasons — a tool version pinned alongside the project, and collaborators or CI
who need nothing on `PATH` — rather than a workaround:

```bash
mkdir taskpump
git -C ~/code/TaskPump archive HEAD | tar -x -C taskpump
git add taskpump && git commit -m "chore: vendor TaskPump"
```

Either layout launches into your repository. What decides that is where you run
from, so when neither a conf nor `$PWD` can answer — a container, a CI job, a
unit started somewhere neutral — the pump refuses instead of guessing:

```
$ cd /tmp/scratch && tp pump --phases T1..T2 --dry-run
tp-pump: refusing to run against the TaskPump installation itself.
  No taskpump.conf above $PWD, $PWD is not inside a consumer repository, and no pin was given — so resolution fell back to the install root:
    /home/you/code/TaskPump
  A drain planned there would target the install, not your project.
  fix: run from your project root, or set TASKPUMP_WORKSPACE_ROOT=/path/to/project
```

`TASKPUMP_WORKSPACE_ROOT=/path/to/project` is that pin, for the layouts where
`$PWD` proves nothing; a pin naming a missing directory is a loud error, never a
fallback. Ledger verbs read the same pin, so `tp task ready --count` in that
shell counts the pinned project's frontier instead of answering `0` from the
install's own ledger — one pin, one workspace, `tp pump` and `tp task` alike.
It outranks `$PWD`, so in a pinned shell a claim made from inside a worktree
lands in the pinned workspace's ledger; that is the trade a pin buys. Naming
`TASKPUMP_TASKS_DIR` outright still wins over it, in both.

### 6. One supervised tick

Add the runner block to `taskpump.conf`:

```bash
# The local process runner, with a stub agent while the plumbing is on trial.
# TASKPUMP_RUNNER names an executable and nothing searches for it: a path to
# the install's runner, or one relative to where you run pump verbs (vendored,
# that is taskpump/runners/local/runner.sh from the repository root).
TASKPUMP_RUNNER=~/code/TaskPump/runners/local/runner.sh
TASKPUMP_LOCAL_AGENT_CMD='cat .taskpump-phase-brief.md; sleep 600'

# The launch prerequisites are container-shaped and a process runner does not
# escape them yet (docs/RUNNERS.md §3.3): the image key must be non-empty, and
# an EMPTY build command means "skip the image build".
TASKPUMP_IMAGE=unused-by-a-process-runner
TASKPUMP_IMAGE_BUILD=

# Agent names are this prefix plus the branch, and the local runner's registry
# is shared across the host — make the prefix this project's own, or two
# repositories launching the same branch name will mistake each other's agents
# for theirs.
TASKPUMP_AGENT_PREFIX=myproject-agent-
```

Commit that edit before the tick. The pump runs a pre-tick guard that reports
anything dirty in the primary checkout outside `.worktrees/` and the ledger, and
an uncommitted `taskpump.conf` is exactly that — a first tick that opens with
`FS-GUARD: primary checkout dirty` is usually just this.

The stub prints its brief into the agent log and stays alive ten minutes — long
enough to watch liveness work. Plan first, then run exactly one tick:

```bash
tp pump --phases T1..T2 --dry-run   # LAUNCH T1, and why feeding is permitted
tp pump --phases T1..T2 --once
```

The run opens with one startup line worth decoding — `ledger: no separate ledger
repo to sync (... is not a git checkout); skipping the per-tick pull and the
closing push` is the pump noticing you keep the ledger in this repository rather
than in a separate checkout, so it has nothing to refresh; it says that once and
then stays quiet — and then prints the launch: agent name, lead task, and the log
path under `.worktrees/feat/t1/`. Now look at what exists:

```bash
tp pump --phases T1..T2 --dry-run                  # T1 is RUNNING now, not LAUNCH
~/code/TaskPump/runners/local/runner.sh list       # the agent, by name
head -4 .worktrees/feat/t1/.taskpump-agent.log     # the brief it was handed
git branch --list                                  # feat/t1, cut in YOUR repository
```

That second dry-run is the point of the exercise: the pump sees the live agent
and will not launch it twice, which is the one property everything else rests
on.

### 7. The loop, watched

```bash
tp pump --phases T1..T2 --jobs 1
```

runs the real loop — recomputing the frontier each tick, launching nothing while
the pool is full — with `tp monitor` open in a second terminal. The monitor reads
the state file the pump writes at your repository root, so its header tracks the
run (`pump[T1..T2]: running  |  1 ready · 2 open`) and the `GRAPH` tab scopes
itself to the range. Two honest caveats with the local runner and a stub: the
`SESSIONS` table enumerates containers, so a process agent never appears there —
the agent's own log and the pump log are your view into it — and a stub does not
claim its task, so the ledger keeps T1 `○ ready` while the pump counts the phase
RUNNING. A real agent claims as its first act.

One knob is worth knowing: `--jobs` *writes* `.taskpump-pool-cap` at startup and
every tick then reads it, which is what lets `echo 1 >| .taskpump-pool-cap`
retune a live pump mid-drain. The file outlives the run that wrote it, so an
explicit `--jobs` overwrites whatever an earlier run left there — the flag is an
instruction about this run, and a run that aborts at startup, before it ticks
once, leaves the file alone. Without the flag the file wins, deliberately, and
the startup banner prints the cap actually in force plus where it came from:

```
[09:23:16] Pump: phases=T1..T2 grain=phase cap=1 (--jobs, then live via /repo/.taskpump-pool-cap) ceiling=95% tick=30s
```

Ctrl-C stops feeding and leaves running agents alive — and stamps the state file
on the way out, so the next reader is not misled:

```
$ tp pump --phases T1..T2 --jobs 1
[09:23:16] SIGINT — stopping the supervisor (running agents are left alive; state stamped stopped)
$ jq -r '.status, .paused_reason' .taskpump-pump.state
stopped
received SIGINT
```

A pump that dies without that courtesy — `SIGKILL`, a lost machine — leaves
`running` in the file forever, so no reader takes it at face value: the monitor
verifies the recorded pid before presenting a pump as live, and renders
`pump[T1..T2]: STALE (was running, pid 896404 dead) — since 2026-08-14T16:23:34Z`
when it cannot. The stub stops through the runner:

```bash
TP_CONTAINER_NAME=myproject-agent-feat-t1 ~/code/TaskPump/runners/local/runner.sh stop
```

When the plumbing has earned it, graduation is one key at a time: point
`TASKPUMP_LOCAL_AGENT_CMD` at a real agent reading
`.taskpump-phase-brief.md`, or configure the sandboxed runner and its image
([docs/RUNNERS.md §4](docs/RUNNERS.md#4-the-claude-docker-reference-runner)),
set `TASKPUMP_BUILD_GATE` to the check you would not merge without, and read
[docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md) before leaving a drain
unattended.

### 8. The rest of the toolkit

`tp task` and `tp pump` are the two halves of the idea. Everything else under
`tp` exists because a multi-day unattended run produces situations a supervisor
should not try to resolve by itself, and each of those tools is one of those
situations, packaged. You will not need any of them on day one. Knowing which
one exists is what saves the afternoon on day four.

**Looking at a run.** `tp monitor` is the live view (quickstart §6);
`tp dag-render` prints the same dependency graph as a layered ASCII diagram, for
a terminal, a paste, or a machine with no TUI. `tp usage` reads the plan-usage
meter directly — it is the gate's own probe, so it answers "why did feeding
stop" without starting a pump. `tp stream-fmt` is a filter, not a command: pipe
an agent's JSON log through it and read what the agent actually did.

**Getting a wedged box moving again.** An agent container can hang silently on a
tool call that never returns — a build lock held by a corpse, a disk that filled
up — and a hung agent is worse than a dead one, because its task stays claimed
and nothing else may pick it up. `tp cleanup` is the packaged recovery for that:
it identifies agents whose log has gone quiet past a threshold, commits their
work-in-progress so nothing is lost, stops them, and releases the claims. It
also reclaims build output and prunes the container runtime, which is the other
way a long run wedges a machine. Start with its read-only mode; it will tell you
what it would do without doing any of it.

**Doing that on a schedule.** `tp agent-watchdog` runs the stuck sweep on an
interval, and `tp disk-watchdog` watches free space and drops the pool cap
before the disk fills. You are probably already running the second one without
knowing it — the pump starts one for you
([docs/PUMP-MECHANISMS.md §3](docs/PUMP-MECHANISMS.md#3-budget-gated-launching-that-never-kills-in-flight-work)
explains what that means for your build directories, and is worth reading before
an unattended drain).

Every flag, mode and exit code for all of them is in
[docs/CLI-TOOLS.md](docs/CLI-TOOLS.md) — including the ones whose behaviour is
narrower than their name suggests, which is most of the reason that document
exists. Each of them also answers `--help` with its own header, which is the
copy that ships with the binary and therefore the copy that cannot go stale —
each of them except `tp stream-fmt`, which parses no arguments at all. Being a
filter is the whole of it: `tp stream-fmt --help` echoes `--help` back as
another line of input, and typed at a terminal with nothing piped in it just
waits.

---

## Layout

| Path | What lives there |
|------|------------------|
| `bin/tp` | the single entry point — `tp task`, `tp pump`, `tp monitor`, … |
| `libexec/` | the tools themselves (`tp-task`, `tp-pump`, `tp-monitor`, …) |
| `lib/` | sourced shared code: the config core, pump helpers, the DAG layout engine |
| `gates/` | feed gates the pump consults before launching |
| `hooks/` | the pre-tick housekeeping seam, plus TaskPump's own container pre-flight |
| `runners/` | agent launchers; `claude-docker/` is the sandboxed container runner |
| `templates/` | the briefs an agent is handed — phase drain, task, resume note |
| `systemd/` | unit templates for running a pump across days |
| `examples/` | annotated configurations: minimal, and a real consumer |
| `tests/` | the shell suites; `tests/run-all.sh` runs every one |
| `docs/` | the contracts below, plus `docs/design/` notes |

---

## Documentation

| Document | What it answers |
|---|---|
| [docs/LEDGER-CONTRACT.md](docs/LEDGER-CONTRACT.md) | The versioned compatibility surface: file format, frontmatter schema, status vocabulary, state machine, eligibility, id grammar, exit codes. Read this before writing anything that reads a ledger. |
| [docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md) | The six supervisor mechanisms and the incident behind each. Read this before re-implementing or trusting one. |
| [docs/CLI-TASK.md](docs/CLI-TASK.md) | Every verb, flag and exit code of `tp task` — the ledger CLI, including the traps where a verb does less than its name suggests. |
| [docs/CLI-PUMP.md](docs/CLI-PUMP.md) | The `tp pump` surface: flags, exit codes, the state file, and everything it hands a runner. |
| [docs/CLI-TOOLS.md](docs/CLI-TOOLS.md) | The rest of the CLI — the `tp` dispatcher, `init`, `monitor`, `cleanup`, `dag-render`, both watchdogs, `stream-fmt` and `usage`. |
| [docs/CONFIG.md](docs/CONFIG.md) | How configuration is discovered, which source wins, and what every key group is for. |
| [docs/GATES.md](docs/GATES.md) | The gate plugin contract, the shipped gates, the pre-tick hook seam, and how to write one of each. |
| [docs/RUNNERS.md](docs/RUNNERS.md) | The runner contract, and what the hardened reference runner guarantees. |

The two contracts and the reference answer different questions. Ask
LEDGER-CONTRACT or PUMP-MECHANISMS *why* something behaves as it does and what
you may depend on; ask the three CLI references what to type.

---

## Extending it

TaskPump has three plugin seams, all of which are just executables named by a
configuration key, and all of which replace a default chain rather than add to
one.

A **gate** decides whether starting new work right now is a bad idea. It exits 10
to pause launching and prints one line saying why; 0 feeds; anything else fails
open with a warning. A gate never kills a running agent, and never fails a task.
See [docs/GATES.md](docs/GATES.md).

A **runner** starts an agent. `runner.sh launch` reads its inputs from the
environment, prints a handle, and detaches; `runner.sh stop` stops one;
`runner.sh list` answers which of its agents are alive, which is where the
supervisor's never-double-launch property comes from; `runner.sh contract`
reports the contract version. Adapting TaskPump to a different agent, or to no
container at all, means writing about twenty lines. See
[docs/RUNNERS.md](docs/RUNNERS.md).

A **pre-tick hook** is housekeeping the supervisor runs before it plans
anything — it takes the repo root, says anything worth saying on stdout, and can
never abort a tick. The two shipped hooks keep the worktrees visible to git and
report contamination in the primary checkout. See
[docs/GATES.md §5](docs/GATES.md#5-the-third-seam--pre-tick-hooks).

Beside those sits the **pre-flight hook**, which belongs to the runner rather
than to the pump: it runs inside the container, and it is where everything
project-shaped goes — toolchain setup, dependency bootstrapping, smoke tests,
the egress allowlist. That hook is the reason the runner can stay generic.

---

## Testing

```bash
./tests/run-all.sh              # every suite, with a summary table
./tests/run-all.sh task         # only suites whose name matches
```

The suites are hermetic: no container runtime, no network, no real agent, and no
checkout of any particular project. They build their fixtures in temporary
directories and stub anything external.

Hermeticity runs in both directions, and two guards hold it. `tests/suite-prologue.sh`
closes the ways the caller's world can reconfigure a fixture — ambient
`taskpump.conf` discovery off, the inherited `TASKPUMP_*` / `TP_*` / `ARACHNE_*`
environment scrubbed, notifications stubbed — and the one way a fixture can
reconfigure the caller's world: the pump's hook mark file is redirected out of
any repository, because a suite that runs a real tick without pinning a
workspace resolves the state dir to the checkout the suites are running *from*.
Every suite sources it, and `run-all.sh` sources it too.

`run-all.sh` then checks that claim rather than trusting it. It snapshots the
tree twice around the run: `git status --porcelain`, for tracked and untracked
litter, and a content manifest of the run-state files — `.taskpump-*`,
`.arachne-*`, `.auto-trunk*`, and `.git/info/exclude`. The manifest exists
because the status probe is blind to exactly the files that got hurt: every one
of those names is in `.gitignore` (TaskPump is itself a repo a pump can be
pointed at), so a suite deleting and rewriting the operator's live
`.taskpump-fsguard.notified` left `git status` empty and the run green. Either
delta now fails the run and names the files that moved.

---

## Provenance

TaskPump was extracted from [Arachne](https://github.com/tjmisko/Arachne) on
2026-08-06 with `git-filter-repo`, so **the full commit history of every tool is
preserved** — `git log --follow` on any file reaches back through its entire
development in the original repository, across the renames.

That history is why the documentation reads the way it does. These tools drove
multi-day unattended drains, and most of what looks like an odd design decision
is a scar: the resume mechanism exists because a pump idled for seven hours
reporting itself healthy, the workspace-first path resolution exists because a
claim landed in the wrong repository's ledger, and the fail-open discipline in
the gates exists because a safety mechanism that wedges a run is worse than the
condition it guards against. Each is documented with its incident rather than as
a rule, so the next person can tell which parts are load-bearing.

Arachne remains the reference consumer — its real configuration is
`examples/arachne.conf` — and the generalization is ongoing. See
[CHANGELOG.md](CHANGELOG.md) for what has moved and what is still Arachne-shaped.
