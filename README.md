# TaskPump

TaskPump is a task DAG and an agent supervisor for long-running autonomous work.

Tasks are plain markdown files with YAML frontmatter — one file per task, holding
its status, its blockers, its goal, and its claim. A single CLI is the only
reader and writer of that state, so claims are atomic, every mutation is a git
commit, and nothing is ever hand-edited into a shape the state machine would not
allow. Because the ledger is just files in a directory, it diffs, it reviews in a
pull request, it merges, and it survives every tool in this repository being
deleted.

On top of that ledger sits a **pump**: a supervisor that recomputes the eligible
frontier every tick, launches sandboxed agents against it, and keeps going for
days. It never stores a queue — the frontier is derived from declared blockers,
so newly-unblocked work enters on its own with nothing to requeue. It decides
liveness by looking at processes rather than believing task status, because a
process killed mid-run never gets to write anything. It governs itself against
your plan's usage meter and pauses *feeding* rather than exhausting your quota,
never killing work already in flight. It resumes a task stranded behind an
abandoned claim, with a note telling the new agent what the dead one already
committed. And it exits loudly on a genuine deadlock instead of idling green.

Every one of those behaviours is in the second paragraph because an unattended
run failed without it. The full accounting is in
[docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md); the short version is that a
supervisor which cannot distinguish "nothing to do" from "nothing I *can* do"
will always resolve the ambiguity as health.

---

## Quickstart

Requirements: `bash` 4+, `git`, [`yq`](https://github.com/mikefarah/yq) (mikefarah's
Go implementation, v4 — **not** the Python `yq`), `jq`, and `awk` (GNU awk for the
DAG renderer). Running agents additionally needs a container runtime.

```bash
git clone https://github.com/tjmisko/TaskPump
ln -s "$PWD/TaskPump/bin/tp" ~/.local/bin/tp
```

### 1. Configure your project

Write a `taskpump.conf` at the root of the repository you want driven. Two keys
is a working configuration:

```bash
TASKPUMP_TASKS_DIR=tasks
TASKPUMP_ID_PATTERN='^T[0-9]+(\.[0-9]+)?$'
```

Add these when you start running agents:

```bash
TASKPUMP_BUILD_GATE='npm test'          # what "is the tree broken?" means here
TASKPUMP_IMAGE=my-project-agent         # the image agents launch from — no default;
                                        #   a real run aborts loudly without one
TASKPUMP_PUMP_JOBS=1                    # start at one; raise after you watch a drain
```

`examples/minimal.conf` is that file with commentary;
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
tp monitor --watch
```

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
