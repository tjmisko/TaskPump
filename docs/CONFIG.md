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

### Turning discovery off

`TASKPUMP_NO_CONF=1` suppresses the walk entirely: no ambient `taskpump.conf` is
loaded, and a tool sees its baked defaults plus whatever the environment sets —
nothing else. An explicit `TASKPUMP_CONFIG` still loads; the switch turns off
*ambient* discovery, not deliberate configuration. In full:

```
TASKPUMP_CONFIG (explicit file)  >  TASKPUMP_NO_CONF=1 (no walk)  >  the walk
```

This is a hermeticity seam, not a tuning knob. The test suites export it so
that the conf of whatever repository they happen to run from — TaskPump's own
included — cannot leak into fixture invocations; a suite that tests discovery
itself opts back in per-invocation with `TASKPUMP_NO_CONF=0` or an explicit
`TASKPUMP_CONFIG`. It is environment-only by construction: by the time a config
file could say anything, the decision it governs has already been made, which
is also why it appears here and not in `taskpump.conf.example`.

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
TASKPUMP_JOBS=1 tp pump --phases T1..T9 --dry-run
```

### Legacy names

TaskPump was extracted from Arachne, where every key was spelled `ARACHNE_*`.
Both spellings are honored during the transition, bridged generically — there is
no hardcoded table of key names, so a key added on either side needs no change to
the bridge.

Promotion runs both directions:

- **`ARACHNE_X` in the environment → `TASKPUMP_X`.** An operator's existing
  exports keep working, and an `ARACHNE_X` exported in the environment still
  outranks a `TASKPUMP_X` set by the config file — it is environment, and
  environment beats the file regardless of spelling.
- **`TASKPUMP_X`, however it was set → `ARACHNE_X`.** A config file written in
  canonical names reaches tools that still read the legacy ones.

When the environment carries **both** spellings of a key, `TASKPUMP_X` wins: both
are "environment", and between two equally strong sources the current name is
authoritative.

One key is reconciled ahead of the bridge rather than by it: `TASKPUMP_NO_CONF`
governs whether a config file loads at all, so the bridge — which runs as part of
loading — cannot promote it in time. Its legacy spelling `ARACHNE_NO_CONF` is
therefore honored inline where the loading decision is made, with the same
outcome as everywhere else: either spelling turns discovery off, and the
canonical one wins when both are set.

**Deprecation horizon.** The bridge is guaranteed through **every 0.x release**
and is **removed at 1.0.0**. Removal makes a consumer that was correct against
0.x incorrect without changing a line of its own code, which is exactly the
contract's test for a MAJOR change
([LEDGER-CONTRACT.md §1](LEDGER-CONTRACT.md#1-versioning)) — so it happens at a
MAJOR boundary and nowhere else. Plan migrations accordingly: write new
configuration in `TASKPUMP_*`. The `ARACHNE_*` spellings are compatibility, not
an alternative.

---

## 3. Key reference

Keys are grouped by the tool that reads them. This section says what each key is
*for*; `taskpump.conf.example` carries the same keys in the same groups with
their **defaults**, and a tool's `--help` is its own view. Defaults are written
down in one place on purpose — two copies is how they drift.

Below, **core** means a generic consumer is likely to set it; **runner-specific**
means it configures the reference `claude-docker` runner or its gates and is
meaningless with a different runner.

Some settings have two accepted spellings, and they come in two flavors. A
**fallback spelling** is a second name for one setting, kept for compatibility —
`TASKPUMP_TASKS_SUBDIR` for `TASKPUMP_LEDGER_PROBE`. An **override** is a
narrower key that wins over a general one for a single tool —
`TASKPUMP_PUMP_BASE` over `TASKPUMP_BASE`, which lets the pump cut branches from
somewhere other than the base every other tool assumes. Write the canonical name
in both cases; reach for an override only when a tool genuinely needs to differ.

### 3.1 Ledger — `tp task` (core)

The keys a generic project actually needs.

| Key | What it configures |
|---|---|
| `TASKPUMP_TASKS_DIR` | The directory of task markdown files. The single most important key. |
| `TASKPUMP_LEDGER_PROBE` | The path, relative to a candidate workspace, whose presence means "this workspace owns a ledger". It is how a worktree's own ledger is told apart from the primary's. A *discovered* `taskpump.conf` marks its own directory as the first candidate, ahead of `$PWD`'s worktree root — a directory carrying its own conf and ledger owns them even inside a larger TaskPump-shaped repo. `TASKPUMP_TASKS_SUBDIR` is accepted as a fallback spelling; write the canonical one. |
| `TASKPUMP_LEDGER_REPO` | The ledger checkout itself, when it is a repository separate from the code. |
| `TASKPUMP_ID_PATTERN` | The regex ids must match (§[LEDGER-CONTRACT.md §7](LEDGER-CONTRACT.md#7-the-id-grammar-contract)). |
| `TASKPUMP_CODE_REPO` | The repository whose commits the heartbeat productivity check measures. Distinct from the ledger repo — they are frequently different. |
| `TASKPUMP_TASK_OUT` | Path of the JSON "next task" surface file. |
| `TASKPUMP_TASK_EXT` | Task-file extension. `TASKPUMP_TASK_FILE_EXT` is accepted as a fallback spelling. |
| `TASKPUMP_TASK_PUSH` | `1` to `git push` after each state commit. Off by default: local-first. `TASKPUMP_PUSH` is accepted as a fallback spelling. |
| `TASKPUMP_TASK_NOCOMMIT` | `1` to skip committing state entirely — fixture and dry-run mode. |
| `TASKPUMP_TASK_DEBUG` | `1` to trace resolution to stderr. Reach for this before guessing. |
| `TASKPUMP_CLAIM_STALE_HOURS` | Age at which `scrub` reclaims a claim that stopped beating. |
| `TASKPUMP_FAILURE_LIMIT` | Consecutive unproductive iterations before `scrub` marks a task stuck. |
| `TASKPUMP_TURN_BUDGET_DEFAULT` | The `claim` turn budget when `--turns` is omitted. |
| `TASKPUMP_LOCK_WAIT` | Seconds to wait for the state lock before failing. |
| `TASKPUMP_LOCK_NAME` | The state lockfile's name, created in the ledger's git root. Shared by inode across every container that bind-mounts the repo, so every concurrent agent must resolve the same name — change it only between runs. |
| `TASKPUMP_PUSH_RETRIES` | Retries for a contended push. |
| `TASKPUMP_COMMITTER_NAME`, `TASKPUMP_COMMITTER_EMAIL` | The identity ledger state commits are made under. |
| `TASKPUMP_TASK` | Path to the task CLI other tools invoke. Set it when the tools are not co-installed. |

`TASKPUMP_TASK_ID` and `TASKPUMP_PHASE` also reach the ledger CLI, but they are
not configuration: the pump sets them to tell a launched agent what it was
assigned. They belong to the runtime contract at the foot of
`taskpump.conf.example`, along with the rest of the pump-to-runner handoff.

### 3.1.1 Id grammar — `tp monitor`, `tp dag-render` (core)

`TASKPUMP_ID_PATTERN` above says which ids are *valid*; these two say how a valid
id is *split* into phase and sub-task for grouping and DAG layout. Keep all three
consistent — a sigil the pattern does not accept produces tasks nothing can group.

| Key | What it configures |
|---|---|
| `TASKPUMP_PHASE_SIGIL` | The letter a phase token starts with (`F` in `F45.2`). |
| `TASKPUMP_PHASE_SEPARATOR` | What ends the phase within an id (`.` in `F45.2`). |

### 3.2 Pump — `tp pump`

**Core scheduling:**

| Key | What it configures |
|---|---|
| `TASKPUMP_JOBS` | Concurrent pool cap. This is the key the pump reads; `TASKPUMP_PUMP_JOBS` is the systemd unit's name for the same number, which it passes as `--jobs`. |
| `TASKPUMP_JOBS_FALLBACK` | The cap used when neither `--jobs` nor the cap file yields one. |
| `TASKPUMP_POOL_CAP_FILE` | A file holding the live cap, re-read each tick so concurrency can be retuned mid-run. |
| `TASKPUMP_TICK` | Seconds between supervisor ticks. |
| `TASKPUMP_STAGGER` | Seconds between launches within a single tick. |
| `TASKPUMP_PUMP_TASKS_DIR` | Tasks directory, independent of the ledger checkout — lets the pump be tested against a flat fixture. |
| `TASKPUMP_PUMP_OPS_DIR` | The ledger checkout the pump refreshes and pushes. Falls back to `TASKPUMP_LEDGER_REPO`. |
| `TASKPUMP_WORKTREES_DIR` | Where agent workspaces live. `TASKPUMP_PUMP_WORKTREES_DIR` overrides it for the pump alone. |
| `TASKPUMP_BRANCH_PREFIX` | Prefix for per-phase branches. `TASKPUMP_PUMP_BRANCH_PREFIX` overrides. |
| `TASKPUMP_BASE` | Base ref new branches are cut from. `TASKPUMP_PUMP_BASE` overrides. |
| `TASKPUMP_RESUME_MAX` | No-progress resumes before escalating to a human. `TASKPUMP_PUMP_RESUME_MAX` overrides. |
| `TASKPUMP_STALL_EXIT_TICKS` | Consecutive deadlocked ticks before exiting 3. `TASKPUMP_PUMP_STALL_EXIT_TICKS` overrides. |
| `TASKPUMP_STATE_DIR` | Where the run's dotfiles live. One knob moves them all out of the repo root; each filename below is still individually overridable. |
| `TASKPUMP_PUMP_STATE_FILE` | Supervisor state, so a restart never disturbs in-flight agents. An absolute path, overriding both the state dir and the name below. |
| `TASKPUMP_PUMP_STATE_NAME` | That file's name *within* the state dir. Distinct from the key above, not a second spelling of it. |
| `TASKPUMP_PUMP_LOG` | Supervisor log path. |
| `TASKPUMP_PUMP_QUARANTINE_FILE` | Phases deliberately held out of the frontier. |
| `TASKPUMP_AGENT_LOG_NAME` | The per-worktree agent log. The monitor and the cleanup sweeper find a live agent by this filename, so renaming it makes running agents invisible to them. |
| `TASKPUMP_BRIEF_OUT_NAME`, `TASKPUMP_GOAL_NOTE_NAME`, `TASKPUMP_RESUME_NOTE_NAME` | The other files a launch drops into a worktree. |

`TASKPUMP_PUMP_PHASES` is the phase range, but the pump takes it as `--phases`;
the key exists for the systemd unit (§3.8).

**Project-shaped behavior** — the keys that make the pump fit a language and a
toolchain:

| Key | What it configures |
|---|---|
| `TASKPUMP_BUILD_GATE` | The command that must pass before work is integrated. `cargo check` for Rust, `npm test` for Node, whatever your project's "is it broken" question is. `TASKPUMP_PUMP_BUILD_CMD` overrides it for the merge queue. |
| `TASKPUMP_VERIFY_CMDS` | Newline-separated commands a task must leave green, quoted into the brief. Empty by default — the templates' verify sections drop out until a consumer names its own bar. |
| `TASKPUMP_PROJECT_BRIEF` | One paragraph pointing an agent at the project's own contributor documentation. |
| `TASKPUMP_RECLAIM_CMD` | How to reclaim build output from a finished workspace, so a multi-day run's disk footprint stays bounded. Empty by default: unconfigured, the per-tick reclaim pass and the `tp cleanup --targets` sweep touch nothing and log themselves unconfigured. |
| `TASKPUMP_BRIEF_TEMPLATE` | The parameterized brief a launched agent is handed. |
| `TASKPUMP_RESUME_TEMPLATE` | The resume preamble a stalled task's agent gets ahead of that brief. |
| `TASKPUMP_TASK_CLI` | How an agent invokes the ledger CLI from inside its worktree. |
| `TASKPUMP_SUBMODULE_PROBE` | A path that proves the ledger submodule is populated. |
| `TASKPUMP_GATES` | Ordered list of gates to consult before launching (§[GATES.md](GATES.md)). |
| `TASKPUMP_PRE_TICK_HOOKS` | Commands run at the start of each tick — ledger refresh, repo hygiene, contamination checks. |
| `TASKPUMP_NOTIFY_CMD` | The command that delivers notifications. Set it to `true` to silence them. |

`TASKPUMP_GATES` and `TASKPUMP_PRE_TICK_HOOKS` are both **newline-separated
command lines**, and each entry's first word must be an executable path. A bare
gate name, or a comma-separated list, is skipped with a warning rather than run —
which reads as "the gate passed".

**Testing and inspection seams:**

`TASKPUMP_PUMP_NO_LAUNCH` (plan without starting anything), `TASKPUMP_PUMP_DEBUG`
(verbose tracing), `TASKPUMP_PUMP_MONITOR` (`0` keeps your terminal after
`--detach`), `TASKPUMP_PUMP_NO_GH` (skip every `gh` call).

**Integration trunk** (opt-in; off by default): `TASKPUMP_TRUNK`,
`TASKPUMP_PUMP_TRUNK_PUSH`, `TASKPUMP_PUMP_TRUNK_LOCK_FILE`,
`TASKPUMP_TRUNK_LOCK_WAIT`, `TASKPUMP_INTEGRATION`,
`TASKPUMP_PUMP_INTEGRATE_DRYRUN`. The `TASKPUMP_PUMP_`-prefixed spellings of the
trunk and integration base override the two general ones.

**Hooks:** `TASKPUMP_FS_GUARD_ALLOWLIST` (paths allowed to be dirty in the primary
checkout — anything else means a container wrote where it should not have) and
`TASKPUMP_WORKTREES_IGNORE_LINE` (the bare ignore line the repair hook strips).

### 3.3 Runner (runner-specific)

Which runner launches agents, and how. See [RUNNERS.md](RUNNERS.md).

| Key | What it configures |
|---|---|
| `TASKPUMP_RUNNER` | The runner **executable** to launch agents with — a path, not a runner name. |
| `TASKPUMP_DOCKER` | The container-runtime binary. |
| `TASKPUMP_IMAGE`, `TASKPUMP_IMAGE_BUILD` | The image to run, and the command that builds it before the first launch. The image has **no default**: a real run (never `--dry-run`) aborts before any launch when it is unset. See [RUNNERS.md §4.0](RUNNERS.md#40-the-image-contract). |
| `TASKPUMP_AGENT_PREFIX` | Container-name prefix, **including its trailing dash**. The liveness probe of [PUMP-MECHANISMS.md §2](PUMP-MECHANISMS.md#2-liveness-from-process-state-never-task-status) matches on it, so it must be distinctive. `TASKPUMP_AGENT_CONTAINER_PREFIX` is accepted as a fallback spelling. |
| `TASKPUMP_ENTRYPOINT` | In-image entrypoint path. |
| `TASKPUMP_MAX_TURNS`, `TASKPUMP_AGENT_MODEL` | Forwarded to each launched agent. |
| `TASKPUMP_AGENT_HOME`, `TASKPUMP_AGENT_CONFIG` | The host agent home and config file the container copies from. |
| `TASKPUMP_PRE_FLIGHT` | A consumer-supplied hook the runner executes before handing control to the agent — toolchain setup, smoke tests, anything project-shaped. |
| `TASKPUMP_CREDENTIALS` | The credentials file the runner copies from. |

Inside the container, `entrypoint.sh` reads a further set that a consumer rarely
touches: `TASKPUMP_CONTAINER_USER` / `_HOME`, `TASKPUMP_WORKSPACE_TASK_CLI`,
`TASKPUMP_SAFETY_TURNS`, `TASKPUMP_AGENT_WALL_TIMEOUT_S`,
`TASKPUMP_CRED_REFRESH_INTERVAL_S`, `TASKPUMP_HOST_CRED_MOUNT`,
`TASKPUMP_HOST_CONFIG_MOUNT`, and `TASKPUMP_RO_PROBE_FILE`. See
[RUNNERS.md](RUNNERS.md) and the entrypoint's own header table.

### 3.4 Gates (runner-specific)

| Key | What it configures |
|---|---|
| `TASKPUMP_GATES` | Ordered gate list. Drop a gate by leaving it out. |
| `TASKPUMP_USAGE_GATE`, `TASKPUMP_USAGE`, `TASKPUMP_USAGE_CEILING` | Whether the usage gate runs, the binary that answers it, and the utilization percent at which it pauses. |
| `TASKPUMP_USAGE_ENDPOINT`, `_CACHE`, `_TTL`, `_HTTP_TIMEOUT`, `_RESET_FILE`, `_DEBUG` | The usage probe's plumbing. |
| `TASKPUMP_TOKEN_GATE`, `TASKPUMP_TOKEN_MARGIN_S` | The credential-freshness gate and how much headroom it wants. |
| `TASKPUMP_HEALTH_GATE`, `TASKPUMP_HEALTH_WINDOW`, `TASKPUMP_HEALTH_PROBE_CMD`, `TASKPUMP_HEALTH_SIGNATURES` | The host-health gate: whether it runs (`TASKPUMP_HEALTH_GATE=1` opts it into the head of the default chain; it ships off), how far back it looks, what it looks *at*, and the failure signatures it matches. The shipped signatures are one machine's WiFi firmware; a consumer enabling it on other hardware replaces them. |
| `TASKPUMP_DISK_GATE`, `TASKPUMP_DISK_RECLAIM`, `TASKPUMP_DISK_REPO_ROOT`, `TASKPUMP_DISK_WATCHDOG` | The low-disk gate and its reclaim behavior. Its floor is `TASKPUMP_DISK_PAUSE_GB`, shared with the watchdog (§3.7). |

### 3.5 Monitor — `tp monitor`

The supervision TUI. Its keys divide into four groups: **layout** (`_COLS`,
`_LINES`, `_TITLE`, `_TAIL_LINES`, `_NOTES_*`), **caching** (`_CACHE_BASE`,
`_SESS_CACHE`/`_TTL`, `_PUMP_CACHE`/`_TTL`, `_DISK_CACHE`/`_TTL` — the monitor
redraws often and must not re-probe the world each frame), **resolution**
(`_BIN`, `_REPO_ROOT`, `_MAIN_ROOT`, `_INTERVAL`, `_LOG`, `_DISK`,
`_DISK_PAUSE_GB`, `_DISK_PANIC_GB`, `_USAGE_WINDOWS`), and **spawning an
editor** (`_TERM`, `_TERM_ARGS`, `_TASK_CLASS`, `_OPEN_CMD`).

Nearly all are prefixed `TASKPUMP_MONITOR_`; the exceptions are
`TASKPUMP_AGENT_LOG_SCAN` and `TASKPUMP_AGENT_LOG_FILTER`, which say how much of
each agent log to read and how to pull feed lines out of it. The one key worth
knowing without reading the list is `TASKPUMP_MONITOR_INTERVAL`, the `--watch`
refresh period.

`TASKPUMP_MONITOR_TERM` is the GUI terminal **binary** the `o` key spawns to open
a task file, with `TASKPUMP_MONITOR_TERM_ARGS` as its argv template (`%CLASS%`
and `%CWD%` expand). It is not a `$TERM` override.

### 3.6 DAG rendering — `tp dag-render`

`TASKPUMP_DAG_BIN` (path to the renderer the monitor invokes),
`TASKPUMP_DAG_REPO_ROOT` (the repository it resolves against),
`TASKPUMP_DAG_LAYOUT` (the layout program), and `TASKPUMP_AWK` (the gawk binary —
the layout engine is a GNU awk program and will not run under mawk).

### 3.7 Housekeeping — `tp cleanup`, `tp disk-watchdog`, `tp agent-watchdog`

`TASKPUMP_CLEANUP_REPO_ROOT` and `TASKPUMP_DISK_REPO_ROOT` name the repository
each sweeps.

**Cleanup** additionally reads `TASKPUMP_RECLAIM_PRIMARY` (`1` is the same as
`--include-primary`), `TASKPUMP_EXTRA_BUSY_DIRS` (newline-separated workspace
roots to skip — how the disk guard protects a workspace with a live compile), and
`TASKPUMP_STOP_GRACE_SEC`.

**The disk watchdog** is both a gate and a standalone daemon, so it owns the
threshold keys the gate reports on: `TASKPUMP_DISK_MOUNT`, `TASKPUMP_DISK_PROBE`,
`TASKPUMP_DISK_POLL`, `TASKPUMP_DISK_PAUSE_GB`, `TASKPUMP_DISK_PANIC_GB`,
`TASKPUMP_DISK_RECOVER_GB`, `TASKPUMP_DISK_COOLDOWN`, `TASKPUMP_PANIC_RECLAIM`,
and `TASKPUMP_DISK_WATCHDOG_LOG`.

**The agent watchdog** reads `TASKPUMP_WATCHDOG_POLL`,
`TASKPUMP_STUCK_THRESHOLD_MIN`, and — for `--auto-exit` —
`TASKPUMP_STARTUP_GRACE_SEC` and `TASKPUMP_EMPTY_GRACE_CHECKS`.

### 3.8 The systemd unit

`systemd/taskpump-pump.service` is the only reader of `TASKPUMP_BIN`,
`TASKPUMP_REPO`, `TASKPUMP_PUMP_PHASES`, `TASKPUMP_PUMP_JOBS`, and
`TASKPUMP_PUMP_CEILING`. It turns them into `--phases`, `--jobs`, and
`--usage-ceiling` on the command line, so they belong in the unit's environment
rather than in `taskpump.conf` — setting `TASKPUMP_PUMP_JOBS` in the config file
does *not* change the pool cap of a pump you start by hand. `TASKPUMP_JOBS`
(§3.2) is that key.

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
