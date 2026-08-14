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
EOF
git add taskpump.conf .gitignore && git commit -m "chore: adopt TaskPump"
```

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

### 5. Put the tools where the pump can launch from

One mechanical fact decides the layout: the pump materialises each agent's
workspace as a git worktree of the repository the tools are installed in,
resolved from its own location — not from where you run it. Everything above
worked from a checkout on `PATH` because ledger resolution is caller-relative;
launches are not. With a standalone TaskPump checkout, a real tick would cut
the agent's worktree from *that checkout* instead of your repository.

So before launching, vendor the tools inside the repository they should drive —
a plain copy, not a clone (a nested `.git` would anchor the pump to the copy
itself):

```bash
mkdir taskpump
git -C ~/code/TaskPump archive HEAD | tar -x -C taskpump
git add taskpump && git commit -m "chore: vendor TaskPump"
```

From here on, pump verbs go through `./taskpump/bin/tp`, run from the
repository root. Ledger verbs do not care which copy answers them.

### 6. One supervised tick

Add the runner block to `taskpump.conf`:

```bash
# The local process runner, with a stub agent while the plumbing is on trial.
# Run pump verbs from the repository root: this runner path is read as written.
TASKPUMP_RUNNER=taskpump/runners/local/runner.sh
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

# The contamination guard expects worktrees at the repo root; vendored, they
# live under taskpump/.worktrees/.
TASKPUMP_FS_GUARD_ALLOWLIST='^(taskpump/\.worktrees/|\.worktrees/|ops$|ops/)'
```

The stub prints its brief into the agent log and stays alive ten minutes — long
enough to watch liveness work. Plan first, then run exactly one tick:

```bash
./taskpump/bin/tp pump --phases T1..T2 --dry-run   # LAUNCH T1, and why feeding is permitted
./taskpump/bin/tp pump --phases T1..T2 --once
```

The tick prints the launch — agent name, lead task, and the log path under
`taskpump/.worktrees/feat/t1/` — and one warning worth decoding: `ops pull
--ff-only failed (continuing)` is the pump trying to refresh a separate ledger
checkout you have not configured, and is noise here. Now look at what exists:

```bash
./taskpump/bin/tp pump --phases T1..T2 --dry-run   # T1 is RUNNING now, not LAUNCH
taskpump/runners/local/runner.sh list              # the agent, by name
head -4 taskpump/.worktrees/feat/t1/.taskpump-agent.log   # the brief it was handed
```

That second dry-run is the point of the exercise: the pump sees the live agent
and will not launch it twice, which is the one property everything else rests
on.

### 7. The loop, watched

```bash
./taskpump/bin/tp pump --phases T1..T2 --jobs 1
```

runs the real loop — recomputing the frontier each tick, launching nothing
while the pool is full — with `./taskpump/bin/tp monitor` open in a second
terminal. Two honest caveats about what you will see with the local runner: the
monitor's `SESSIONS` table enumerates containers, so a process agent does not
appear in it — the agent's own log and the pump log are your view into the
run — and the `GRAPH` tab scopes itself to a pump it can see, so `tp dag-render
--phases T1..T2` is the reliable spelling of the graph. Ctrl-C stops feeding
and leaves running agents; the stub stops through the runner:

```bash
TP_CONTAINER_NAME=myproject-agent-feat-t1 taskpump/runners/local/runner.sh stop
```

When the plumbing has earned it, graduation is one key at a time: point
`TASKPUMP_LOCAL_AGENT_CMD` at a real agent reading
`.taskpump-phase-brief.md`, or configure the sandboxed runner and its image
([docs/RUNNERS.md §4](docs/RUNNERS.md#4-the-claude-docker-reference-runner)),
set `TASKPUMP_BUILD_GATE` to the check you would not merge without, and read
[docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md) before leaving a drain
unattended.

---

## Layout

| Path | What lives there |
|------|------------------|
| `bin/tp` | the single entry point — `tp task`, `tp pump`, `tp monitor`, … |
| `libexec/` | the tools themselves (`tp-task`, `tp-pump`, `tp-monitor`, …) |
| `lib/` | sourced shared code: the config core, pump helpers, the DAG layout engine |
| `gates/` | feed gates the pump consults before launching |
| `runners/` | agent launchers; `claude-docker/` is the sandboxed container runner |
| `systemd/` | unit templates for running a pump across days |
| `examples/` | annotated configurations: minimal, and a real consumer |
| `tests/` | the shell suites; `tests/run-all.sh` runs every one |
| `docs/` | the contracts below, plus `docs/design/` notes |

---

## Documentation

| Document | What it answers |
|---|---|
| [docs/LEDGER-CONTRACT.md](docs/LEDGER-CONTRACT.md) | The versioned compatibility surface: file format, frontmatter schema, status vocabulary, state machine, eligibility, id grammar, exit codes. Read this before writing anything that reads a ledger. |
| [docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md) | The five supervisor mechanisms and the incident behind each. Read this before re-implementing or trusting one. |
| [docs/CONFIG.md](docs/CONFIG.md) | How configuration is discovered, which source wins, and what every key group is for. |
| [docs/GATES.md](docs/GATES.md) | The gate plugin contract, the shipped gates, and how to write one. |
| [docs/RUNNERS.md](docs/RUNNERS.md) | The runner contract, and what the hardened reference runner guarantees. |

---

## Extending it

TaskPump has two plugin seams, both of which are just executables.

A **gate** decides whether starting new work right now is a bad idea. It exits 10
to pause launching and prints one line saying why; 0 feeds; anything else fails
open with a warning. A gate never kills a running agent, and never fails a task.
See [docs/GATES.md](docs/GATES.md).

A **runner** starts an agent. `runner.sh launch` reads its inputs from the
environment, prints a handle, and detaches; `runner.sh stop` stops one. Adapting
TaskPump to a different agent, or to no container at all, means writing about
fifteen lines. See [docs/RUNNERS.md](docs/RUNNERS.md).

Between them sits the **pre-flight hook**, where everything project-shaped goes:
toolchain setup, dependency bootstrapping, smoke tests. That hook is the reason
the runner can stay generic.

---

## Testing

```bash
./tests/run-all.sh              # every suite, with a summary table
./tests/run-all.sh task         # only suites whose name matches
```

The suites are hermetic: no container runtime, no network, no real agent, and no
checkout of any particular project. They build their fixtures in temporary
directories and stub anything external.

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
