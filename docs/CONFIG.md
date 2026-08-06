# Configuration

TaskPump is configured by a `taskpump.conf` at the root of the repository it
drives, overridable by environment variables. Every key has a default baked into
the tool that reads it, so **a missing config file is normal** — the file exists
to describe a project, not to make the tools work.

`taskpump.conf.example` is the annotated census of every key. This document
explains how they are found, which one wins, and what each group is for.

---

## 1. Discovery

`TASKPUMP_CONFIG` names a file explicitly and skips the search:

```bash
TASKPUMP_CONFIG=/etc/taskpump/ci.conf tp task ready
```

If it points at a file that does not exist, that is an error — an explicit
request for a specific config must not silently fall back.

Otherwise TaskPump **walks up from `$PWD`** looking for `taskpump.conf`, stopping
at the enclosing git worktree root (or `/` when you are not in a repository).
Finding nothing is not an error.

Two properties of that walk are load-bearing:

**It starts from the caller's directory, never from where the tools are
installed.** A repository with worktrees has one configuration and one ledger per
worktree; a tool that resolved from its own location would apply the primary
checkout's configuration to work happening in a worktree. This is the
wrong-ledger incident made structural — see
[PUMP-MECHANISMS.md §6](PUMP-MECHANISMS.md#6-resolution-starts-from-the-callers-workspace).

**It stops at the worktree root.** Configuration is a property of a workspace, so
it must not leak in from a parent directory — otherwise a `taskpump.conf` in your
home directory would quietly configure every repository beneath it.

Installation paths are a different question and *are* resolved from the tools'
own location, through their realpath, so a symlink on `PATH` still finds its own
installation.

### File syntax

The file is sourced by bash with `allexport`, so it is `KEY=value` per line.
Quote anything containing spaces:

```bash
TASKPUMP_TASKS_DIR=tasks
TASKPUMP_NOTIFY_CMD='notify-send -u low'
```

Because it is sourced, it is executable code. Treat it as you would any file you
run: do not source a `taskpump.conf` you have not read.

---

## 2. Precedence

```
environment  >  taskpump.conf  >  default baked into the tool
```

An exported variable always wins. This is what makes one-off overrides work:

```bash
TASKPUMP_PUMP_JOBS=1 tp pump --phases T1..T9 --dry-run
```

### Legacy name promotion

TaskPump was extracted from Arachne, where every key was spelled `ARACHNE_*`.
Both spellings are honored during the transition, bridged generically — there is
no hardcoded table of key names, so a key added on either side needs no change to
the bridge.

Promotion runs both directions:

- **`ARACHNE_X` in the environment → `TASKPUMP_X`.** An operator's existing
  exports keep working, and still outrank the config file.
- **`TASKPUMP_X`, however it was set → `ARACHNE_X`.** A config file written in
  canonical names reaches tools that still read the legacy ones.

When the environment carries **both** spellings of a key, `TASKPUMP_X` wins: both
are "environment", and between two equally strong sources the current name is
authoritative.

Write new configuration in `TASKPUMP_*`. The `ARACHNE_*` spellings are
compatibility, not an alternative.

---

## 3. Key reference

Keys are grouped by the tool that reads them. Each is listed here without its
default — defaults live in the tools, and repeating them in two places is how
they drift. Run a tool with `--help` for its own view.

Below, **core** means a generic consumer is likely to set it; **runner-specific**
means it configures the reference `claude-docker` runner or its gates and is
meaningless with a different runner.

### 3.1 Ledger — `tp task` (core)

The keys a generic project actually needs.

| Key | What it configures |
|---|---|
| `TASKPUMP_TASKS_DIR` | The directory of task markdown files. The single most important key. |
| `TASKPUMP_ID_PATTERN` | The regex ids must match (§[LEDGER-CONTRACT.md §7](LEDGER-CONTRACT.md#7-the-id-grammar-contract)). |
| `TASKPUMP_CODE_REPO` | The repository whose commits the heartbeat productivity check measures. Distinct from the ledger repo — they are frequently different. |
| `TASKPUMP_TASK_OUT` | Path of the JSON "next task" surface file. |
| `TASKPUMP_TASK_PUSH` | `1` to `git push` after each state commit. Off by default: local-first. |
| `TASKPUMP_TASK_NOCOMMIT` | `1` to skip committing state entirely — fixture and dry-run mode. |
| `TASKPUMP_TASK_DEBUG` | `1` to trace resolution to stderr. Reach for this before guessing. |
| `TASKPUMP_CLAIM_STALE_HOURS` | Age at which `scrub` reclaims a claim that stopped beating. |
| `TASKPUMP_LOCK_WAIT` | Seconds to wait for the state lock before failing. |
| `TASKPUMP_PUSH_RETRIES` | Retries for a contended push. |
| `TASKPUMP_TASK` | Path to the task CLI other tools invoke. Set it when the tools are not co-installed. |
| `TASKPUMP_TASK_ID`, `TASKPUMP_PHASE` | The task and phase a launched agent is assigned. Set by the pump, read by the runner — not something you configure by hand. |

### 3.2 Pump — `tp pump`

**Core scheduling:**

| Key | What it configures |
|---|---|
| `TASKPUMP_PUMP_PHASES` | Phase range to drain, e.g. `T1..T9`. |
| `TASKPUMP_PUMP_JOBS` | Concurrent pool cap. |
| `TASKPUMP_POOL_CAP_FILE` | A file holding the live cap, re-read each tick so concurrency can be retuned mid-run. |
| `TASKPUMP_PUMP_TASKS_DIR` | Tasks directory, independent of the ledger checkout — lets the pump be tested against a flat fixture. |
| `TASKPUMP_PUMP_LEDGER_REPO` | The ledger checkout the pump refreshes and pushes. |
| `TASKPUMP_PUMP_WORKTREES_DIR` | Base directory holding per-phase agent workspaces. |
| `TASKPUMP_PUMP_BRANCH_PREFIX` | Prefix for per-phase branches. |
| `TASKPUMP_PUMP_BASE` | Base ref new branches are cut from. |
| `TASKPUMP_PUMP_RESUME_MAX` | No-progress resumes before escalating to a human. |
| `TASKPUMP_PUMP_STALL_EXIT_TICKS` | Consecutive deadlocked ticks before exiting 3. |
| `TASKPUMP_PUMP_STATE_FILE` | Supervisor state, so a restart never disturbs in-flight agents. |
| `TASKPUMP_PUMP_LOG` | Supervisor log path. |
| `TASKPUMP_PUMP_QUARANTINE_FILE` | Phases deliberately held out of the frontier. |

**Project-shaped behavior** — the keys that make the pump fit a language and a
toolchain:

| Key | What it configures |
|---|---|
| `TASKPUMP_BUILD_GATE` | The command that must pass before work is integrated. `cargo check` for Rust, `npm test` for Node, whatever your project's "is it broken" question is. |
| `TASKPUMP_RECLAIM_CMD` | How to reclaim build output from a finished workspace, so a multi-day run's disk footprint stays bounded. |
| `TASKPUMP_BRIEF_TEMPLATE` | The parameterized brief a launched agent is handed. |
| `TASKPUMP_RESUME_TEMPLATE` | The resume preamble a stalled task's agent gets ahead of that brief. |
| `TASKPUMP_GATES` | Ordered list of gates to consult before launching (§[GATES.md](GATES.md)). |
| `TASKPUMP_PRE_TICK_HOOKS` | Commands run at the start of each tick — ledger refresh, repo hygiene, contamination checks. |
| `TASKPUMP_NOTIFY_CMD` | The command that delivers notifications. Set it to `true` to silence them. |

**Testing and inspection seams:**

`TASKPUMP_PUMP_NO_LAUNCH` (plan without starting anything), `TASKPUMP_PUMP_DEBUG`
(verbose tracing), `TASKPUMP_PUMP_MONITOR` (`0` keeps your terminal after
`--detach`), `TASKPUMP_NOW_S` (clock override for tests).

**Integration trunk** (opt-in; off by default): `TASKPUMP_PUMP_TRUNK`,
`TASKPUMP_PUMP_TRUNK_PUSH`, `TASKPUMP_PUMP_TRUNK_LOCK_FILE`,
`TASKPUMP_TRUNK_LOCK_WAIT`, `TASKPUMP_PUMP_INTEGRATION_BASE`,
`TASKPUMP_PUMP_INTEGRATE_DRYRUN`, `TASKPUMP_PUMP_NO_GH`.

### 3.3 Runner (runner-specific)

Which runner launches agents, and how. See [RUNNERS.md](RUNNERS.md).

| Key | What it configures |
|---|---|
| `TASKPUMP_RUNNER` | The runner to launch agents with. |
| `TASKPUMP_IMAGE` | Container image name. |
| `TASKPUMP_AGENT_PREFIX` | Container-name prefix. The liveness probe of [PUMP-MECHANISMS.md §2](PUMP-MECHANISMS.md#2-liveness-from-process-state-never-task-status) matches on it, so it must be distinctive. |
| `TASKPUMP_ENTRYPOINT` | In-image entrypoint path. |
| `TASKPUMP_MAX_TURNS`, `TASKPUMP_AGENT_MODEL` | Forwarded to each launched agent. |
| `TASKPUMP_PRE_FLIGHT` | A consumer-supplied hook the runner executes before handing control to the agent — toolchain setup, smoke tests, anything project-shaped. |
| `TASKPUMP_CREDENTIALS` | The credentials file the runner copies from. |

### 3.4 Gates (runner-specific)

| Key | What it configures |
|---|---|
| `TASKPUMP_GATES` | Ordered gate list. Drop a gate by leaving it out. |
| `TASKPUMP_USAGE_CEILING` | Utilization percent at which the usage gate pauses. |
| `TASKPUMP_USAGE_ENDPOINT`, `_CACHE`, `_TTL`, `_HTTP_TIMEOUT`, `_RESET_FILE`, `_DEBUG` | The usage probe's plumbing. |
| `TASKPUMP_TOKEN_GATE`, `TASKPUMP_TOKEN_MARGIN_S` | The credential-freshness gate and how much headroom it wants. |
| `TASKPUMP_DISK_GATE`, `TASKPUMP_DISK_RECLAIM`, `TASKPUMP_DISK_REPO_ROOT`, `TASKPUMP_DISK_WATCHDOG` | The low-disk gate and its reclaim behavior. |

### 3.5 Monitor — `tp monitor`

The supervision TUI. Its keys divide into three groups: **layout**
(`_COLS`, `_LINES`, `_TERM`, `_TAIL_LINES`, `_NOTES_*`), **caching**
(`_SESS_CACHE`/`_TTL`, `_PUMP_CACHE`/`_TTL`, `_DISK_CACHE`/`_TTL` — the monitor
redraws often and must not re-probe the world each frame), and **resolution**
(`_BIN`, `_REPO_ROOT`, `_MAIN_ROOT`, `_INTERVAL`, `_OPEN_CMD`, `_TASK_CLASS`,
`_DISK`, `_DISK_PAUSE_GB`, `_DISK_PANIC_GB`, `_LOG`).

All are prefixed `TASKPUMP_MONITOR_`. The one worth knowing without reading the
list is `TASKPUMP_MONITOR_INTERVAL`, the `--watch` refresh period.

### 3.6 DAG rendering — `tp dag-render`

`TASKPUMP_DAG_BIN` (path to the renderer the monitor invokes) and
`TASKPUMP_DAG_REPO_ROOT` (the repository it resolves against).

### 3.7 Housekeeping — `tp cleanup`, `tp disk-watchdog`, `tp agent-watchdog`

`TASKPUMP_CLEANUP_REPO_ROOT` and `TASKPUMP_DISK_REPO_ROOT` name the repository
each sweeps. The disk watchdog additionally reads the threshold keys listed under
gates, since it is both a gate and a standalone daemon.

---

## 4. Debugging a configuration

In order of usefulness:

```bash
tp task resolve --all           # which ledger, code repo, and out-file this
                                # invocation picked, and how it decided
tp task --help                  # a tool's own keys and defaults
TASKPUMP_TASK_DEBUG=1 tp task next    # trace resolution to stderr
tp pump --phases T1..T9 --dry-run     # the plan, with the gate decision, no side effects
```

`resolve` answers the question that costs the most time when it goes wrong. If
task state ever looks wrong in a worktree, run it before anything else.
