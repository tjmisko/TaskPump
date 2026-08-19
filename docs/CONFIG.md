# Configuration

TaskPump is configured by a `taskpump.conf` at the root of the repository it
drives, overridable by environment variables. Every key has a default baked into
the tool that reads it, so **a missing config file is normal** — the file exists
to describe a project, not to make the tools work.

`taskpump.conf.example` is the annotated census: every key the tools read, with
its default, commented out. (The one deliberate omission is `TASKPUMP_NO_CONF`,
which by construction cannot be set in a file — §1.) This document explains how
they are found, which one wins, which tool reads each, and where a key's name
promises more than the code delivers.

**`tp init` writes the first one for you, and is the recommended starting
point.** Run it in the repository you want driven: it scaffolds a
`taskpump.conf` carrying only the keys a new consumer actually decides — where
the ledger lives and the id grammar, plus a commented-out build gate — and
creates the tasks directory beside it.

```bash
cd ~/code/my-project
tp init                              # tasks/ + taskpump.conf at the worktree root
tp init --tasks-dir planning/tasks   # ...or a ledger somewhere else
```

It writes at the **worktree root** even when you run it from a subdirectory,
because that is the only directory a conf governs the whole repository from
(§1). It **refuses**, naming the file it found, when a `taskpump.conf` is
already discoverable from where you are standing — a second conf would shadow an
existing ledger's configuration for part of the repository, and that refusal
changes nothing on disk. It also commits nothing and creates no tasks: `tp init`
prepares a repository, it does not start using it. From there, `tp task create`
and `tp task ready` work with no further configuration.

The full arc — `tp init`, importing an existing markdown task directory with
`tp task fsck --fix`, and a first supervised pump tick — is the README's
[Adopt in an existing repo](../README.md#adopt-in-an-existing-repo)
walkthrough.

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

### Vendored TaskPump checkouts

One conf is deliberately **skipped** by the walk: a vendored TaskPump
checkout's own tracked `taskpump.conf`. A consumer that vendors TaskPump — as
a submodule, a subtree, or a plain nested copy — gets a conf inside its own
tree that describes TaskPump's dogfood ledger, and honoring it would silently
point any invocation whose `$PWD` is inside the vendored checkout at that
ledger instead of the consumer's. So a discovered conf whose directory is a
TaskPump install (it carries `lib/config.sh` and `libexec/tp-task`) sitting
inside an enclosing repository — or checked out as a submodule of one — is
passed over, and the walk continues toward the consumer's own conf. For the
submodule shape the walk's ceiling extends to the superproject's root, and the
caller's-workspace anchor looks through to the superproject the same way: the
consumer's conf and ledger win from anywhere inside its tree.

A standalone TaskPump checkout that is nobody's vendored copy (the dogfood
repo itself, and each of its worktrees) matches neither condition and keeps
its own conf.

Two shapes remain ambiguous by construction and keep the nested behavior: a
plain nested *clone* (its own `.git`, no superproject) is indistinguishable
from the dogfood repo, and a non-install directory carrying a conf (a fixture,
a subproject) still owns its own ledger. A vendoring consumer that wants
deterministic resolution regardless sets `TASKPUMP_CONFIG` explicitly in its
shims — an explicit config never anchors to its own directory, so it is immune
to the hazard entirely.

### Relative paths in the conf

A relative path in `taskpump.conf` means **relative to the workspace the conf
describes**, never relative to wherever the caller happens to stand. After the
file loads, every relative value of the ledger-locating keys —
`TASKPUMP_TASKS_DIR`, `TASKPUMP_TASK_OUT`, `TASKPUMP_CODE_REPO`,
`TASKPUMP_LEDGER_REPO`, `TASKPUMP_PUMP_TASKS_DIR`, `TASKPUMP_PUMP_OPS_DIR`,
`TASKPUMP_WORKSPACE_ROOT`, `TASKPUMP_BRIEF_TEMPLATE`,
`TASKPUMP_PHASE_BRIEF_TEMPLATE`, `TASKPUMP_TASK_BRIEF_TEMPLATE`,
`TASKPUMP_RESUME_TEMPLATE` — is anchored to a
fixed root: a *discovered*
conf's own directory; for an explicit `TASKPUMP_CONFIG` (which may live
anywhere), the caller's worktree root. Unanchored, `tp task ready` run from a
subdirectory returned an **empty frontier with rc=0** over live work, and the
pump reported the range drained.

Three deliberate edges:

- **Environment values are not rewritten.** `TASKPUMP_TASKS_DIR=tasks tp task
  ready` keeps the shell's own convention — the caller typed the path where
  they stood.
- **State-file names are not workspace paths.** Keys like
  `TASKPUMP_PUMP_LOG` and `TASKPUMP_POOL_CAP_FILE` are relative to the *state
  dir* by contract, and `TASKPUMP_LEDGER_PROBE` is relative to a candidate
  workspace by definition; none of them anchor.
- **The unanchorable case is an error.** An explicit `TASKPUMP_CONFIG` with a
  relative path, run from outside any git worktree, refuses loudly and names
  the key — resolving it against `$PWD` would pick a different ledger per
  directory, silently.

A missing ledger is equally loud: a tasks directory that does not **exist**
fails every ledger-reading verb with a pointer to `tp task resolve`, instead
of reading as an empty frontier. Only `resolve` itself keeps answering — it is
the diagnostic the error names.

### The final resolution order

For where the ledger lives, strongest first:

1. `TASKPUMP_TASKS_DIR` from the **environment** — used as given.
2. `TASKPUMP_TASKS_DIR` from the **conf** — anchored to the conf's workspace
   as above.
3. `TASKPUMP_WORKSPACE_ROOT` — the workspace named outright, whose
   `TASKPUMP_LEDGER_PROBE` is then the ledger. The pin outranks both probes
   below because it is the caller naming the workspace rather than a
   directory answering for itself; naming a missing directory is a loud error,
   never a fall-through. Both `tp task` and `tp pump` read it, so one pinned
   shell gets one answer from both (issue #45). Standing in a worktree that
   carries a ledger of its own does **not** override it — the pin is how you
   say so, and a claim made there lands in the pinned workspace's ledger.
   Rungs 1 and 2 win over it *outright*: when a tasks dir is named, the pin
   decides nothing at all, including `TASKPUMP_CODE_REPO`, which stays on the
   caller's own worktree so the heartbeat keeps measuring where the work lands.
4. The **discovered conf's directory**, when `TASKPUMP_LEDGER_PROBE` resolves
   there (a directory carrying its own conf and ledger owns them, even inside
   a larger repo — vendored TaskPump checkouts excepted, above).
5. **`$PWD`'s worktree root**, when the probe resolves there (for a vendored
   TaskPump submodule, the superproject's root).
6. The **install root** — a fallback, not an answer: `tp task`'s mutating verbs
   refuse it unless the install root is the caller's own worktree (the vendored
   layout, where it is simply correct), and `tp pump` refuses to run at all on
   this rung, every mode included (§3.2).

`tp task resolve --all` prints the answer, the rung that produced it (`via`),
and the conf that loaded.

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
TASKPUMP_NOTIFY_CMD='logger -t taskpump'
```

The notifier here is `logger` rather than anything desktop because this example
is about the quoting and gets copied by people who are not reading it for
notifications: a configured notifier reads the message on **stdin**, which
`logger` does and an argv-style desktop notifier does not, and it has to work
where the pump actually runs — a headless host with no session bus is where a
long run lives (§3.2 has the desktop wrapper and what it needs).

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

**Three limits, and they are limits of the mechanism rather than of any one
key.**

*The two keys that govern loading are decided ahead of the bridge.*
`TASKPUMP_NO_CONF` governs whether a config file loads at all, so the bridge —
which runs as part of loading — cannot promote it in time. Its legacy spelling
`ARACHNE_NO_CONF` is therefore honored inline where the loading decision is
made, with the same outcome as everywhere else: either spelling turns discovery
off, and the canonical one wins when both are set. `TASKPUMP_CONFIG` is decided
one branch earlier still and has **no** legacy arm at all: `ARACHNE_CONFIG` does
not name a config file. It is worse than inert, because the bridge then promotes
it onto `TASKPUMP_CONFIG` *after* the file has been chosen, and an explicit
config is the signal that stops a conf's directory from anchoring relative paths
(§1). Standing in `repo/sub` with a `repo/sub/taskpump.conf` carrying
`TASKPUMP_TASKS_DIR=t`, `resolve` answered `repo/sub/t`; with
`ARACHNE_CONFIG=/does/not/exist` also set it answered `repo/t` — a different
ledger, no error, and `conf` still naming the discovered file. A missing
`TASKPUMP_CONFIG` is a loud error; a missing `ARACHNE_CONFIG` moves the anchor
silently. Write `TASKPUMP_CONFIG`.

*An `ARACHNE_*` key set inside a `taskpump.conf` never bridges.* The promotion
loop iterates a snapshot of the environment taken **before** the file is
sourced — that is what makes environment outrank file — so a conf line
`ARACHNE_TASKS_DIR=…` reaches no canonical reader at all. The rule above is
scoped to the environment on purpose. Write conf files in `TASKPUMP_*`;
`examples/arachne.conf`, the reference consumer's conf, does.

*The bridge covers `ARACHNE_*` only, never `TP_*`.* `TP_`-prefixed names are the
pump-to-runner handoff's own spelling, and the runners resolve them through
their own explicit chains. `ARACHNE_TASKS_DIR=<dir> tp task resolve --all`
answered `<dir>`; `TP_TASKS_DIR=<dir>` answered the probed default, because
nothing bridges it. Both the bridge and conf discovery live in
`lib/config.sh`, so they apply only to the tools that source it — every `tp`
subcommand, the four shipped gates that answer a question, and the two pre-tick
hooks. The runners do not (§3.3), nor does `hooks/agent-preflight`, which runs
inside a container: under a pump launch they inherit the whole loaded
environment and behave identically, but run by hand they read the shell and
nothing else.

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

Each table below gives the key, **the tool that actually reads it**, the default
that tool falls back to, and what it configures. (The container-side table in
§3.3 drops that column because the entrypoint owns every row; §3.9 adds a
writer column, because those names are written by one tool for another.) The
reader column is not decoration: several keys are read by a different tool than
their name suggests — `TASKPUMP_MONITOR_BIN` by the pump, `TASKPUMP_TASK_EXT` by
everything except `tp task` — and a key set for a tool that does not read it
produces no error, no warning and no effect. That is the whole class of bug this
document exists to make findable.

`taskpump.conf.example` carries the same keys, commented out, in the same
groups, with the same defaults; a tool's own `--help` is its third view. Two
copies of a default can drift, so where they disagree the expansion in the
source is authoritative — `rg TASKPUMP_JOBS libexec lib gates runners` answers
in one line, and every default below was read out of exactly that.

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

### 3.0 Seven keys that do not mean what their name suggests

These are the traps a reader of the key names alone falls into. Each is written
out again in its own section; they are collected here because the cost of
meeting one for the first time during an unattended run is a day.

- **`TASKPUMP_BUILD_GATE` unset is not "no build gate."** With
  `--integration-trunk` and no value set, every merge into the trunk is gated on
  `cargo check --workspace` and then `./smoke_test.sh` if the workspace has one
  (`libexec/tp-pump` `run_build_gate`). On a project that is not Rust that gate
  can only fail: the merge is `reset --hard`, the unit is appended to the
  quarantine file as `build red`, the phase's lead task is flipped to
  `needs-review`, and the operator is notified. Set the key — to your own
  command, or to `true` if you want the trunk to absorb merges ungated.
- **`TASKPUMP_PUMP_QUARANTINE_FILE` is a log, not an exclusion list.** It is
  append-only, written when a merge fails, and read exactly once — into the body
  of the graduation PR. Writing phase names into it holds nothing back; every
  one of them is dispatched on the next tick.
- **`TASKPUMP_TASKS_SUBDIR` never reaches `tp task`.** The ledger CLI defaults
  `TASKPUMP_LEDGER_PROBE` before resolution runs, so the fallback arm is dead
  there while `tp pump`, `tp monitor` and `tp dag-render` honour it. The pump's
  frontier comes from that CLI, so the two halves disagree and the pump reports
  the range drained. Write `TASKPUMP_LEDGER_PROBE`.
- **`TASKPUMP_TASK_EXT` does not change the ledger.** `tp task` hardcodes `.md`.
  The key only tells the *readers* (`tp monitor`, `tp dag-render`, the container
  entrypoint) to look for a different extension, which desynchronises them from
  the writer.
- **`TASKPUMP_EXTRA_BUSY_DIRS` has no reader; `EXTRA_BUSY_DIRS` does.** The
  prefixed spelling is the one four places in this tree have documented, and
  `tp cleanup` reads the bare one. Since the key exists to keep a reclaim sweep
  off a workspace that is mid-compile, the prefixed spelling deletes exactly the
  build output it was set to protect.

### 3.1 Ledger — `tp task` (core)

The keys a generic project actually needs.

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_TASKS_DIR` | `tp task`, `tp pump`, `tp monitor`, `tp dag-render`, entrypoint | `<workspace>/<ledger probe>` | The directory of task markdown files. The single most important key. |
| `TASKPUMP_LEDGER_PROBE` | `tp task`, `tp pump`, `tp monitor`, `tp dag-render` | `tasks` | The path, relative to a candidate workspace, whose presence means "this workspace owns a ledger". It is how a worktree's own ledger is told apart from the primary's. A *discovered* `taskpump.conf` marks its own directory as the first candidate, ahead of `$PWD`'s worktree root — a directory carrying its own conf and ledger owns them even inside a larger TaskPump-shaped repo. |
| `TASKPUMP_TASKS_SUBDIR` | `tp pump`, `tp monitor`, `tp dag-render` — **not `tp task`** | — | The fallback spelling of the key above, and a trap: see below. Write `TASKPUMP_LEDGER_PROBE`. |
| `TASKPUMP_WORKSPACE_ROOT` | `tp task`, `tp pump` | none | The workspace this CLI resolves its ledger inside when no tasks dir is named outright — the pin for a run whose `$PWD` proves nothing (a container, a CI step, a shell in `$HOME`). The same key the pump reads (§3.2), deliberately: a shell that pins the workspace and runs both tools must not get `ready --count` = 0 `via install-root` from one and the pinned frontier from the other (issue #45). `resolve --all` then reports `via workspace-pin`, and `TASKPUMP_CODE_REPO` defaults to the pinned workspace on the same condition — name a tasks dir and the pin decides neither. `tp monitor` and `tp dag-render` do not read it; in a pinned shell they still answer from `$PWD`. |
| `TASKPUMP_ID_PATTERN` | `tp task` | `^T[0-9]+(\.[0-9]+)?$` | The regex ids must match (§[LEDGER-CONTRACT.md §7](LEDGER-CONTRACT.md#7-the-id-grammar-contract)). |
| `TASKPUMP_CODE_REPO` | `tp task` | the resolved workspace root | The repository whose commits the heartbeat productivity check measures. Distinct from the ledger repo — they are frequently different. |
| `TASKPUMP_TASK_OUT` | `tp task`, entrypoint | `<parent of the tasks dir>/.next-task` | Path of the JSON "next task" surface file. |
| `TASKPUMP_TASK_PUSH` | `tp task` | `0` | `1` to `git push` after each state commit. Off by default: local-first. `TASKPUMP_PUSH` is accepted as a fallback spelling. |
| `TASKPUMP_TASK_NOCOMMIT` | `tp task` | `0` | `1` to skip committing state entirely — fixture and dry-run mode. |
| `TASKPUMP_TASK_DEBUG` | `tp task` | `0` | `1` to trace resolution to stderr. Reach for this before guessing. |
| `TASKPUMP_CLAIM_STALE_HOURS` | `tp task` | `24` | Age at which `scrub` reclaims a claim that stopped beating. |
| `TASKPUMP_FAILURE_LIMIT` | `tp task` | `3` | Consecutive unproductive iterations before `scrub` marks a task stuck. |
| `TASKPUMP_TURN_BUDGET_DEFAULT` | `tp task` | `50` | The `claim` turn budget when `--turns` is omitted. |
| `TASKPUMP_LOCK_WAIT` | `tp task` | `120` | Seconds to wait for the state lock before failing. |
| `TASKPUMP_LOCK_NAME` | `tp task` | `.taskpump-task.lock` | The state lockfile's name, created in the ledger's git root and removed when the verb that took it exits, so it is not left in the consumer's `git status`. Shared by inode across every container that bind-mounts the repo, so every concurrent agent must resolve the same name — change it only between runs. |
| `TASKPUMP_PUSH_RETRIES` | `tp task` | `6` | Retries for a contended push. |
| `TASKPUMP_COMMITTER_NAME` | `tp task` | `tp-task` | The identity ledger state commits are made under. |
| `TASKPUMP_COMMITTER_EMAIL` | `tp task` | `task@taskpump.local` | The same identity's email. |
| `TASKPUMP_PROG_NAME` | `tp task` | `tp-task` | The name this CLI calls itself in every diagnostic, error and usage line. A consumer that rebrands the install sets it; `examples/arachne.conf` pins the historical `arachne-task`. |
| `TASKPUMP_TASK` | `tp pump`, `tp monitor` | `<install>/libexec/tp-task` | Path to the task CLI those tools invoke. Set it when the tools are not co-installed. |
| `TASKPUMP_LEDGER_REPO` | `tp pump`, entrypoint — **not `tp task`** | `<workspace>/ops` | The ledger *checkout*, when it is a repository separate from the code: what the pump pulls each tick and pushes at the end (`TASKPUMP_PUMP_OPS_DIR` overrides it), and what the container resolves its ledger paths against. The ledger *directory* is `TASKPUMP_TASKS_DIR` above, and the two are deliberately separate questions. |
| `TASKPUMP_TASK_EXT` | `tp monitor`, `tp dag-render`, entrypoint — **not `tp task`** | `.md` | The extension those readers scan for. It does not change what `tp task` writes: see below. |
| `TASKPUMP_TASK_FILE_EXT` | entrypoint only | `.md` | The fallback spelling of the key above, accepted only inside the container. On the host it does nothing. |

**`TASKPUMP_TASKS_SUBDIR` is dead under `tp task`, and that split is the
hazard.** `libexec/tp-task` runs `: "${TASKPUMP_LEDGER_PROBE:=tasks}"` at load,
seventeen lines before it resolves the workspace, so by the time
`lib/config.sh`'s `${TASKPUMP_LEDGER_PROBE:-${TASKPUMP_TASKS_SUBDIR:-tasks}}`
runs the probe is always already set and the fallback arm cannot fire — from the
environment or from a conf. `tp pump`, `tp monitor` and `tp dag-render` read the
same expression with nothing defaulted ahead of it, so they *do* honour it. In a
repo carrying `planning/` (the intended ledger) and a stale `tasks/`,
`TASKPUMP_TASKS_SUBDIR=planning tp task resolve --all` answered
`tasks_dir <repo>/tasks`, and `tp pump --dry-run --phases T1` — whose frontier
comes from that same CLI — printed `DONE T1 (no open tasks)` over an open
`planning/T1.0`. In a repo with no `tasks/` at all the CLI falls through to the
install's own ledger and reports `via install-root`. Both are the confident wrong
answer. `TASKPUMP_LEDGER_PROBE=planning` gets `LAUNCH T1` from the same fixture.

**`TASKPUMP_TASK_EXT` desynchronises the readers from the writer.** The
extension is hardcoded in `libexec/tp-task` (`"$TASKPUMP_TASKS_DIR/$id.md"`,
`find … -name '*.md'`), which never reads the key. Setting it leaves `create`
writing `.md` while `tp dag-render` looks for something else and prints
`(no tasks found)`.

`TASKPUMP_TASK_ID` and `TASKPUMP_PHASE` also reach the ledger CLI, but they are
not configuration: the pump sets them to tell a launched agent what it was
assigned. They belong to the runtime handoff (§3.9).

### 3.1.1 Id grammar — `tp monitor`, `tp dag-render` (core)

`TASKPUMP_ID_PATTERN` above says which ids are *valid*; these two say how a valid
id is *split* into phase and sub-task for grouping and DAG layout. Keep all three
consistent — a sigil the pattern does not accept produces tasks nothing can group.

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_PHASE_SIGIL` | `tp task`, `tp pump`, `tp monitor`, `tp dag-render` | `T` | The letter a phase token starts with (`F` in `F45.2`). Both `tp task` and `tp pump` also strip it when they expand a phase *range*, and validate against it: under `TASKPUMP_PHASE_SIGIL=G`, `tp pump --phases T1..T2` refuses with `bad phase range 'T1..T2' (expected GN..GM)`. A single `--phases T1` is not checked against it, so a mismatched sigil is loud for a range and silent for one phase. |
| `TASKPUMP_PHASE_SEPARATOR` | `tp monitor`, `tp dag-render` | `.` | What ends the phase within an id (`.` in `F45.2`). |

### 3.2 Pump — `tp pump`

**Core scheduling:**

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_WORKSPACE_ROOT` | `tp pump`, `tp task` | the config anchor (a discovered conf's directory, else the caller's worktree root) | The workspace the pump **drives** — the default image-build context, the repository phase branches and agent worktrees are created in, the state-dir default, every `git` surface of a run. Never derived from where the tools are installed, so a vendored TaskPump's own checkout is never mistaken for the workspace (issue #32). Set it to pin a container/CI run whose `$PWD` proves nothing. Naming a missing directory is a loud error. The install's own assets (`lib/`, `libexec/`, `gates/`, `runners/`, `templates/`, `hooks/`) stay script-relative regardless. Not pump-scoped: `tp task` resolves its ledger through the same pin (§3.1), so the two tools cannot answer differently in one pinned shell. |
| `TASKPUMP_JOBS` | `tp pump` | `4` | Concurrent pool cap. This is the key the pump reads; `TASKPUMP_PUMP_JOBS` is the systemd unit's name for the same number, which it passes as `--jobs`. A standing preference: the cap file below outranks it, so an unflagged run uses whatever the last retune left there. |
| `TASKPUMP_JOBS_FALLBACK` | `lib/pump-lib.sh`, `tp disk-watchdog` — **not reachable from `tp pump`** | `6` | The cap `apl_read_cap` falls back to for a caller that passes none. The pump always passes its own `JOBS` (defaulted to 4 above), so this number cannot decide a pump run: with no cap file and no `--jobs`, `TASKPUMP_JOBS_FALLBACK=99 tp pump --dry-run` still plans `cap 4`. Its live consumer is the disk watchdog, which uses it as the cap to restore when it has no other record of one. |
| `TASKPUMP_POOL_CAP_FILE` | `tp pump`, `tp disk-watchdog` | `<state dir>/.taskpump-pool-cap` | A file holding the live cap, re-read each tick so concurrency can be retuned mid-run. An explicit `--jobs` sets it at startup — the flag is an instruction about this run, and a number a previous run left behind must not outrank it (issue #44). That write happens once the run has cleared its prerequisites, so a startup that aborts (no image, no runner, failed build) leaves the file exactly as it found it. The startup banner prints the cap in force and names which of the two set it. |
| `TASKPUMP_TICK` | `tp pump` | `30` | Seconds between supervisor ticks. |
| `TASKPUMP_STAGGER` | `tp pump` | `3` | Seconds between launches within a single tick. |
| `TASKPUMP_PUMP_TASKS_DIR` | `tp pump` | `TASKPUMP_TASKS_DIR`, else `<workspace>/<ledger probe>` | Tasks directory for the pump alone, independent of the ledger checkout — lets the pump be tested against a flat fixture. It feeds the pump's own dependency scan and the worktree handoff; the frontier itself comes from the ledger CLI, which resolves separately. |
| `TASKPUMP_PUMP_OPS_DIR` | `tp pump` | `TASKPUMP_LEDGER_REPO`, else `<workspace>/ops` | The ledger checkout the pump refreshes and pushes. When it is not a git checkout, or has no remote, there is nothing to sync: the pump says so once at startup and skips the per-tick pull and the closing push, rather than reporting a failure every tick. |
| `TASKPUMP_WORKTREES_DIR` | `tp pump` and `tp cleanup` as a **path**; `tp monitor` as a **name** | `<repo root>/.worktrees` (pump, cleanup); `.worktrees` (monitor) | Where agent workspaces live. The two contracts are incompatible: see below. `TASKPUMP_PUMP_WORKTREES_DIR` overrides it for the pump alone. |
| `TASKPUMP_BRANCH_PREFIX` | `tp pump` | `feat/` | Prefix for per-phase branches. `TASKPUMP_PUMP_BRANCH_PREFIX` overrides. |
| `TASKPUMP_BASE` | `tp pump` | `main` | Base ref new branches are cut from. `TASKPUMP_PUMP_BASE` overrides. |
| `TASKPUMP_RESUME_MAX` | `tp pump` | `3` | No-progress resumes before escalating to a human. `TASKPUMP_PUMP_RESUME_MAX` overrides. |
| `TASKPUMP_STALL_EXIT_TICKS` | `tp pump` | `3` | Consecutive deadlocked ticks before exiting 3. `TASKPUMP_PUMP_STALL_EXIT_TICKS` overrides. |

**Run state and the files a run drops:**

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_STATE_DIR` | `tp pump`, `tp disk-watchdog`, `runners/local` | the workspace root | Where the run's dotfiles live. One knob moves the pump's own files out of the repo root; each filename below is still individually overridable. It does **not** move where the observers look: see below. |
| `TASKPUMP_PUMP_STATE_FILE` | `tp pump`, `tp monitor`, `tp dag-render` | `<state dir>/<state name>` (pump); `<primary checkout>/<state name>` (monitor); `<repo root>/<state name>` (dag-render) | Supervisor state, so a restart never disturbs in-flight agents. An absolute path, overriding both the state dir and the name below. |
| `TASKPUMP_PUMP_STATE_NAME` | `tp pump`, `tp monitor`, `tp dag-render` | `.taskpump-pump.state` | That file's name *within* the state dir. Distinct from the key above, not a second spelling of it. |
| `TASKPUMP_PUMP_LOG` | `tp pump` | `<state dir>/.taskpump-pump.log` | Supervisor log path. |
| `TASKPUMP_PUMP_QUARANTINE_FILE` | `tp pump` | `<state dir>/.auto-trunk-quarantine` | The append-only record of merges the integration trunk refused — one `<unit> <sha> <reason>` line per failure. Not an exclusion list: see §3.2's integration-trunk paragraph. |
| `TASKPUMP_HOOK_MARK_FILE` | `tp pump` | `<state dir>/.taskpump-fsguard.notified` | Fingerprint of the last pre-tick hook output, kept so a persistent condition notifies once rather than every tick. `TASKPUMP_FSGUARD_MARK_FILE` is its older spelling and loses to it. |
| `TASKPUMP_AGENT_LOG_NAME` | `tp pump`, `tp monitor`, `tp cleanup`, both runners, entrypoint | `.taskpump-agent.log` | The per-worktree agent log. The monitor and the cleanup sweeper find a live agent by this filename, so renaming it makes running agents invisible to them. |
| `TASKPUMP_BRIEF_OUT_NAME` | `tp pump` | `.taskpump-phase-brief.md` | The rendered brief written into each worktree. |
| `TASKPUMP_GOAL_NOTE_NAME` | `tp pump`, entrypoint | `.taskpump-goal.md` | The goal note written into each worktree. |
| `TASKPUMP_RESUME_NOTE_NAME` | `tp pump`, entrypoint | `.taskpump-resume.md` | The resume preamble written into a resumed worktree. |
| `TASKPUMP_DISK_WATCHDOG_LOG` | `tp pump` | `<state dir>/.taskpump-disk-watchdog.log` | Where the pump redirects the disk watchdog it auto-starts. The watchdog run by hand does not read it and logs to its own stdout. |
| `TASKPUMP_PUMP_PROG_NAME` | `tp pump` | `tp-pump` | The name the pump answers to as itself: every diagnostic, the plan header, the notification title, and the transient systemd unit a `--detach` creates. |

**`TASKPUMP_STATE_DIR` moves the writer, not the readers.** The pump resolves
its state file, log, cap file, quarantine file, hook mark and watchdog log
under it, but `tp monitor` derives the state file from the *primary checkout's*
root and `tp dag-render` from its own repo root — neither reads
`TASKPUMP_STATE_DIR` at all. Move the state dir and the monitor shows no pump
until you also set `TASKPUMP_PUMP_STATE_FILE` to the absolute path, which both
sides honour.

**`TASKPUMP_WORKTREES_DIR` means two different things.** `tp pump` and
`tp cleanup` treat it as a full path (default `<repo root>/.worktrees`);
`tp monitor` treats it as a bare directory *name* relative to the repo root
(default `.worktrees`) and concatenates. An absolute value satisfies the first
two and hands the monitor `<repo root>//abs/path`; a bare name satisfies the
monitor and leaves the pump with a path relative to wherever it was started. It
is also not in the anchored-path set, so a relative value in a conf is not
rewritten. Leave it unset unless you have moved the worktrees, and when you must
set it, set `TASKPUMP_PUMP_WORKTREES_DIR` to the path and leave the general key
to the monitor.

`TASKPUMP_PUMP_PHASES` is the phase range, but the pump takes it as `--phases`;
the key exists for the systemd unit (§3.8).

**Project-shaped behavior** — the keys that make the pump fit a language and a
toolchain:

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_BUILD_GATE` | `tp pump` | **unset ⇒ `cargo check --workspace`, then `./smoke_test.sh` when the workspace has one** | The command that must pass before work is integrated. `cargo check` for Rust, `npm test` for Node, whatever your project's "is it broken" question is. `TASKPUMP_PUMP_BUILD_CMD` overrides it for the merge queue. The unset case is not "no gate": see below. |
| `TASKPUMP_VERIFY_CMDS` | `tp pump` | empty | Newline-separated commands a task must leave green, quoted into the brief. Empty by default — the templates' verify sections drop out until a consumer names its own bar. |
| `TASKPUMP_PROJECT_BRIEF` | `tp pump` | a generic "read CLAUDE.md, CONTRIBUTING.md, or equivalent" paragraph | One paragraph pointing an agent at the project's own contributor documentation. |
| `TASKPUMP_RECLAIM_CMD` | `tp pump`, `tp cleanup` | empty | How to reclaim build output from a finished workspace, so a multi-day run's disk footprint stays bounded. Empty by default: unconfigured, the per-tick reclaim pass and the `tp cleanup --targets` sweep touch nothing and log themselves unconfigured. |
| `TASKPUMP_DISK_RECLAIM` | `tp pump` | `1` | `0` switches off the pump's per-tick reclaim of finished phases' build output. Despite the name it is not disk-pressure-conditional — the pass runs every tick, before the feed gate, precisely so a paused run keeps freeing space. The watchdog's pressure-driven reclaim is `TASKPUMP_PANIC_RECLAIM` (§3.7). |
| `TASKPUMP_BRIEF_TEMPLATE` | `tp pump` | `<install>/templates/phase-drain-brief.md` | The parameterized brief a launched agent is handed at `--grain phase`. `TASKPUMP_PHASE_BRIEF_TEMPLATE` is the explicit spelling of the same thing and wins when both are set. |
| `TASKPUMP_TASK_BRIEF_TEMPLATE` | `tp pump` | `<install>/templates/task-brief.md` | The brief a `--grain task` container is handed. A separate template on purpose: the phase brief's working method *is* the in-context `next --phase` loop, which at task grain would claim the siblings the pump has already dispatched elsewhere. |
| `TASKPUMP_RESUME_TEMPLATE` | `tp pump` | `<install>/templates/resume-note.md` | The resume preamble a stalled task's agent gets ahead of that brief. |
| `TASKPUMP_TASK_CLI` | `tp pump` | `tp task` | How an agent invokes the ledger CLI from inside its worktree — the spelling the rendered briefs quote at the agent. |
| `TASKPUMP_SUBMODULE_PROBE` | `tp pump` | **none** | A path that proves the ledger submodule is populated in a fresh worktree, letting the pump skip its per-worktree `git submodule update --init --recursive`. Unset, the (idempotent, cheap) init always runs. The probe is a pure optimization — and a sharp one: a path that exists for the wrong reason skips the init some *other* submodule still needs, silently. Set it only to a path that proves everything you need populated. |
| `TASKPUMP_GATES` | `tp pump` | the default chain (§3.4) | Ordered list of gates to consult before launching (§[GATES.md](GATES.md)). A configured value replaces the chain outright. |
| `TASKPUMP_PRE_TICK_HOOKS` | `tp pump` | `<install>/hooks/gitignore-repair` and `<install>/hooks/fs-guard` | Commands run at the start of each tick — ledger refresh, repo hygiene, contamination checks. |
| `TASKPUMP_NOTIFY_CMD` | `tp pump` | unset ⇒ `notify-send <prog-name> <message>` wherever notify-send is on PATH | The command that delivers notifications, which it receives on **stdin** — see the recipes below. Unset, the pump falls back to `notify-send <prog-name> <message>` wherever notify-send is on PATH. Set it to `true` to silence them; every message is logged either way. |

`TASKPUMP_GATES` and `TASKPUMP_PRE_TICK_HOOKS` are both **newline-separated
command lines**, and each entry's first word must be an executable path. A bare
gate name, or a comma-separated list, is skipped with a warning rather than run —
which reads as "the gate passed".

**The unset `TASKPUMP_BUILD_GATE` runs `cargo`.** `run_build_gate` in
`libexec/tp-pump` uses a configured command *instead of* its default, not in
addition to it; with nothing configured the default is
`cargo check --workspace` followed by `./smoke_test.sh` if the trunk worktree
has one. That default only ever runs under `--integration-trunk`, which is
opt-in — but there it runs on every merge, and on a project with no
`Cargo.toml` `cargo check` exits non-zero before it does anything else
(`error: could not find Cargo.toml … or any parent directory`). Driven against
a fixture repo with no `Cargo.toml` and the key unset, one `--integration-trunk`
tick logged `quarantine T1: build red — not advancing auto/trunk`, left the
trunk on the same commit it started from (the merge is `reset --hard $pre`),
appended `T1 <sha> build red` to the quarantine file, flipped the lead task to
`needs-review` and notified `auto/trunk: quarantined T1 (build red)`. The same
tick with `TASKPUMP_BUILD_GATE=true` logged `integrated T1 @ …` and advanced the
trunk. A lead that is already `done` is left `done` — a broken merge is not
broken work — and gets the same quarantine line and page.

**Testing and inspection seams:**

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_PUMP_NO_LAUNCH` | `tp pump` | `0` | `1` plans and ticks without starting anything — no image build, no runner call, no trunk worktree. |
| `TASKPUMP_PUMP_DEBUG` | `tp pump` | `0` | `1` for verbose supervisor tracing. |
| `TASKPUMP_PUMP_MONITOR` | `tp pump` | `1` | `0` keeps your terminal after `--detach` instead of handing it to the monitor. |
| `TASKPUMP_PUMP_NO_GH` | `tp pump` | `0` | `1` skips every `gh` call. |
| `TASKPUMP_MONITOR_BIN` | `tp pump` | `<install>/libexec/tp-monitor` | The monitor binary `--detach` hands off to. Read by the pump, never by the monitor. |
| `TASKPUMP_NOW_S` | `lib/pump-lib.sh` | `date +%s` | Clock override. The suites' seam for token-expiry and staleness arithmetic; `ARACHNE_NOW_S` is honoured inline. |

**Integration trunk** (opt-in; off unless `--integration-trunk` is passed):

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_TRUNK` | `tp pump` | `auto/trunk` | The integration trunk's branch name. `TASKPUMP_PUMP_TRUNK` overrides. |
| `TASKPUMP_INTEGRATION` | `tp pump` | `main` | The base the trunk is cut from and the graduation PR targets. `TASKPUMP_PUMP_INTEGRATION_BASE` overrides. |
| `TASKPUMP_PUMP_TRUNK_PUSH` | `tp pump` | `0` | `1` pushes the trunk after each successful merge. |
| `TASKPUMP_PUMP_TRUNK_LOCK_FILE` | `tp pump` | `<state dir>/.auto-trunk.lock` | The flock guarding the merge queue. |
| `TASKPUMP_TRUNK_LOCK_WAIT` | `lib/pump-lib.sh` | `300` | Seconds to wait for that lock before deferring the unit to the next tick. |
| `TASKPUMP_PUMP_INTEGRATE_DRYRUN` | `tp pump` | `0` | `1` rehearses the merge queue, logging `would integrate` / `would quarantine`. No git and never the default `cargo` gate; an explicitly configured `TASKPUMP_BUILD_GATE` *is* run, which is how a test forces the red path. |

**The quarantine file is a log.** A merge that conflicts, or that fails the
build gate, is undone (`merge --abort`, or `reset --hard` to the pre-merge sha)
and one line — `<unit> <sha> <reason>` — is appended to
`TASKPUMP_PUMP_QUARANTINE_FILE`. The file is read exactly once, by
`graduate_trunk`, which pastes it into the graduation PR body under
"Quarantined (needs human reconciliation)". Nothing else opens it: it is not
consulted when the plan is computed, and a phase named in it is dispatched on
the next tick like any other. Writing `T1` and `T2` into the file by hand and
re-planning the same range printed `LAUNCH T1` and `LAUNCH T2`. What actually
holds a phase back is the ledger — the quarantined unit's lead task is flagged
`needs-review` (unless it was already `done`), and that status is what the
frontier reads. Note that a `needs-review` lead with commits ahead is also what
the stall detector resumes, so on a repeatedly-red gate the same phase will be
re-dispatched with a resume note rather than left alone.

**Hooks:**

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_FS_GUARD_ALLOWLIST` | `lib/pump-lib.sh` (`hooks/fs-guard`) | `^(\.worktrees/\|ops$\|ops/\|\.auto-trunk\.lock$\|\.auto-trunk-quarantine$)` | Extended regex of paths allowed to be dirty in the primary checkout — anything else means a container wrote where it should not have. |
| `TASKPUMP_WORKTREES_IGNORE_LINE` | `hooks/gitignore-repair`, `lib/pump-lib.sh` | `.worktrees/` | The bare ignore line the repair hook strips out of `.gitignore`, because an ignored worktrees directory makes every agent worktree invisible to `git`. |

**Notifications.** `TASKPUMP_NOTIFY_CMD` is a command line that gets the message
on **stdin**; that is the whole contract. Anything that reads stdin works, and an
argv-style notifier (`notify-send`, `terminal-notifier`) needs a wrapper that
turns the message into an argument:

```bash
TASKPUMP_NOTIFY_CMD='logger -t taskpump'                    # journal/syslog; works headless
TASKPUMP_NOTIFY_CMD='xargs -0 notify-send -u low TaskPump'  # desktop popup; needs a session
```

`-0` is load-bearing. Without it `xargs` splits the message at whitespace and
hands `notify-send` a summary, a body, and however many positionals are left
over, which it rejects (`Invalid number of options.`, reported by `xargs` as
exit 123). `xargs` also caps one argument list at ~128 KiB (`xargs
--show-limits`), so an unusually large notice — a pre-tick hook with thousands
of paths to report — fails as well. And the desktop line needs what any desktop
notification needs: a session bus with a notification daemon on it. A pump left
running under `loginctl enable-linger` (§3.8) or started over ssh has neither,
so there every notice fails — with whatever your libnotify says about the
missing bus — while the same run with the key unset would have been silent.
`logger` is the value that survives that host.

A configured command that exits non-zero is reported with its exit status and
its first line of stderr, labelled as exactly that. The pump does not infer a
cause: it has no grammar for an arbitrary notifier's output, so it quotes what
the notifier said and leaves the reading to you — the first line is often the
reason and sometimes a banner. A notifier that writes nothing is reported as
having written nothing, and one that is not on `PATH` is reported as missing
rather than as having failed. The command's arguments are never printed, because
a webhook notifier keeps its token there. The full message is in the log either
way.

**The pump refuses the install-root fallback.** Where `tp task` lets read-only
verbs answer from the install's own ledger and refuses only the mutating ones,
`tp pump` refuses outright — exit 1, with the resolved path named — when no conf
was found above `$PWD`, `$PWD` is not inside a consumer repository, and no pin
was given. A drain planned there would cut branches and worktrees inside
TaskPump itself. The check runs before argument parsing, so `--dry-run` and
`--help` refuse too. Three things get you out of it — `TASKPUMP_WORKSPACE_ROOT`,
or an explicit `TASKPUMP_TASKS_DIR` / `TASKPUMP_PUMP_TASKS_DIR` — but the
message itself names only the first, so the other two are escapes you have to
already know about (`libexec/tp-pump:115`). The vendored layout
(the install at or inside the caller's worktree) is exempt, because there the
fallback is simply correct.

### 3.3 Runner (runner-specific)

Which runner launches agents, and how. See [RUNNERS.md](RUNNERS.md).

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_RUNNER` | `tp pump` | `<install>/runners/claude-docker/runner.sh` | The runner **executable** to launch agents with — a path, not a runner name. |
| `TASKPUMP_DOCKER` | `tp pump`, `lib/pump-lib.sh` | `docker` | The container-runtime binary. |
| `TASKPUMP_IMAGE` | `tp pump` | **none** | The image to run. A real run (never `--dry-run`) aborts before any launch when it is unset — a wrong silent image is worse than a loud missing one. See [RUNNERS.md §4.0](RUNNERS.md#40-the-image-contract). |
| `TASKPUMP_IMAGE_BUILD` | `tp pump` | unset ⇒ `docker build -t <image> <workspace>` | The command that builds the image before the first launch. This is the tree's one key tested with `+set`: **unset** means "run that default build", **set to the empty string** means "skip the build entirely" — which is what a runner pulling a prebuilt image wants. Because the conf is sourced with `allexport`, a bare `TASKPUMP_IMAGE_BUILD=` line in a `taskpump.conf` is the second of those, not the first. |
| `TASKPUMP_ENTRYPOINT` | `tp pump` | `/entrypoint.sh` | In-image entrypoint path — where the image contract bakes the shipped runner's own `entrypoint.sh`. Only that entrypoint runs `TASKPUMP_PRE_FLIGHT`, so pinning another path leaves a configured hook read by nothing (issue #5). |
| `TASKPUMP_AGENT_PREFIX` | `lib/pump-lib.sh` (so `tp pump` and `tp cleanup`), `tp monitor`, `runners/claude-docker` | `tp-agent-` | Container-name prefix, **including its trailing dash**. The liveness probe of [PUMP-MECHANISMS.md §2](PUMP-MECHANISMS.md#2-liveness-from-process-state-never-task-status) matches on it, so it must be distinctive. |
| `TASKPUMP_AGENT_CONTAINER_PREFIX` | `tp monitor` only | — | A fallback spelling of the key above that only the monitor consults. Setting it alone gives you a monitor watching one prefix while the pump launches, enumerates and reclaims under `tp-agent-` — the invisible-agents failure. Write `TASKPUMP_AGENT_PREFIX`. |
| `TASKPUMP_MAX_TURNS` | `tp pump`, entrypoint (both runners forward it) | `600` | The phase-drain turn budget forwarded to each launched agent. |
| `TASKPUMP_TASK_MAX_TURNS` | `tp pump` | `120` | What a `--grain task` session gets instead, since it claims one task and exits. |
| `TASKPUMP_AGENT_MODEL` | `tp pump`, entrypoint (both runners forward it) | `opus` | The model alias forwarded to each agent. |
| `TASKPUMP_AGENT_HOME` | `tp pump` | `$HOME/.claude` | The host agent home the container copies from. |
| `TASKPUMP_AGENT_CONFIG` | `tp pump` | `$HOME/.claude.json` | The host agent config file the container copies from. |
| `TASKPUMP_CREDENTIALS` | `gates/claude-token-fresh`, `gates/claude-usage`; `tp pump` derives and exports it | `$HOME/.claude/.credentials.json`; under the pump, `<TASKPUMP_AGENT_HOME>/.credentials.json` | The host credentials file the freshness gate checks the expiry of and the usage gate pulls its OAuth token from. The pump derives it only when the operator set nothing, so a configured value is never clobbered by a derivation of itself. What the container copies is `TASKPUMP_AGENT_HOME`, not this. |
| `TASKPUMP_PRE_FLIGHT` | `runners/claude-docker` (forwarded), entrypoint | none | A consumer-supplied executable **inside the container**, run as root before the session — toolchain setup, smoke tests, anything project-shaped. A non-zero exit aborts the launch with 75. |

**The local runner** (`runners/local/runner.sh`) runs an agent as a bare
process instead of a container, and reads its own keys:

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_LOCAL_AGENT_CMD` | `runners/local` | **none; `launch` dies without it** | The shell command that runs one agent session, executed through `bash -c` in the workspace. There is deliberately no default: a plausible-but-wrong guess at your agent fails somewhere far from here. `TP_LOCAL_AGENT_CMD` is accepted. |
| `TASKPUMP_LOCAL_REGISTRY` | `runners/local` | `<state dir>/.taskpump-local-agents` when `TASKPUMP_STATE_DIR` is set, else `${XDG_STATE_HOME:-$HOME/.local/state}/taskpump/local-agents` | The `<name> <pgid> <workspace>` registry that gives a bare process the name→process mapping a container runtime provides for free. `TP_LOCAL_REGISTRY` is accepted. |
| `TASKPUMP_LOCAL_STOP_GRACE_S` | `runners/local` | `10` | Seconds between the `TERM` to the process group and the `KILL`. |
| `TASKPUMP_REPO_ROOT` | `runners/local` | none | Which workspace's fleet `list` and `stop` answer about. Registry entries record their workspace, so two projects on one host do not read each other's agents as their own (issue #40). |

**The local runner reads no `taskpump.conf`.** It never sources
`lib/config.sh`, so neither conf discovery nor the `ARACHNE_*` bridge applies to
it, and `TP_*`/`TASKPUMP_*` are read through its own explicit chains. Under a
pump launch this is invisible — the pump sourced the conf with `allexport` and
the runner inherits the whole environment — but a hand-run
`runners/local/runner.sh list` or `stop`, which is how README shows it, sees
only what the shell exports. With `TASKPUMP_LOCAL_REGISTRY` set in a
`taskpump.conf`, `list` left a dead entry in that registry unpruned; the same
value exported in the environment pruned it.

**Inside the container**, `entrypoint.sh` reads a further set that a consumer
rarely touches. Each is read canonical-first (`TASKPUMP_<NAME>`, then
`TP_<NAME>`, then the legacy name), and the shipped runner forwards them into
the container when — and only when — each is set. Two are deliberately off that
passthrough list: `TASKPUMP_INSTALL_MOUNT` and the test seam
`TASKPUMP_ENTRYPOINT_TEST_MODE`, so setting either on the host reaches no
container the shipped runner starts.

| Key | Default | What it configures |
|---|---|---|
| `TASKPUMP_CONTAINER_USER` | `dev` | The user the session runs as. |
| `TASKPUMP_CONTAINER_HOME` | `/home/<container user>` | That user's home. `hooks/agent-preflight` defaults the same key to a hardcoded `/home/dev` instead, so a consumer who changes the user and relies on that hook gets two different homes; the shipped `runners/claude-docker/preflight-example.sh` follows the entrypoint. |
| `TASKPUMP_WORKSPACE_TASK_CLI` | `tp` (on `PATH`) | The ledger CLI the container invokes: absolute, workspace-relative, or a bare command found on `PATH`. Startup fails loudly when it is absent. |
| `TASKPUMP_SAFETY_TURNS` | `3` | Turn budget for the entrypoint's safety-net claim. |
| `TASKPUMP_AGENT_WALL_TIMEOUT_S` | unset ⇒ no cap | Wall-clock cap on a session; firing exits 124. |
| `TASKPUMP_CRED_REFRESH_INTERVAL_S` | `300` | How often the container re-copies the host's access token. |
| `TASKPUMP_HOST_CRED_MOUNT` | `/tmp/claude-home` | Where the host credential dir is mounted. |
| `TASKPUMP_HOST_CONFIG_MOUNT` | `/tmp/claude-home-json/.claude.json` | Where the host agent config is mounted. |
| `TASKPUMP_RO_PROBE_FILE` | `.taskpump-rotest` | The filename used to prove the primary mount really is read-only. |
| `TASKPUMP_INSTALL_MOUNT` | `/opt/taskpump` | Where a TaskPump install is mounted in the image; its `bin/` is prepended to `PATH`. The shipped runner deliberately does not forward it, so setting it in a `taskpump.conf` is inert — it is for an image or a caller that mounts an install itself. |
| `TASKPUMP_ENTRYPOINT_TEST_MODE` | unset | The entrypoint's test seam: `plan` resolves and prints, `preflight` also runs the hook. Neither starts a session. Not forwarded either, so it is set on the entrypoint's own invocation, which is how the suites drive it. |

### 3.4 Gates (runner-specific)

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_GATES` | `tp pump` | `gates/claude-token-fresh`, `<usage bin> --gate`, `gates/disk-low` — plus `gates/net-health` at the head when `TASKPUMP_HEALTH_GATE=1` | The ordered gate list. A configured value replaces the chain outright and is used verbatim. |
| `TASKPUMP_USAGE_GATE` | `tp pump`, `gates/claude-usage` | `1` | Whether the usage gate is in the default chain and answers. `0` drops `<usage bin> --gate` from the chain and reaches the gate as `0`, so a `claude-usage` entry kept in a custom `TASKPUMP_GATES` disables itself too. `--no-usage-gate` forces `0` for one run. |
| `TASKPUMP_USAGE` | `tp pump`, `tp monitor` | `<install>/gates/claude-usage` | The binary that answers the usage question. |
| `TASKPUMP_USAGE_CEILING` | `tp pump`, `gates/claude-usage` | `95` | The utilization percent at which launching pauses. `--usage-ceiling` overrides for a run. |
| `TASKPUMP_USAGE_ENDPOINT` | `gates/claude-usage` | `https://api.anthropic.com/api/oauth/usage` | The OAuth usage endpoint. |
| `TASKPUMP_USAGE_CACHE` | `gates/claude-usage` | `/tmp/claude-plan-usage.json` | Where the probe caches the payload. |
| `TASKPUMP_USAGE_TTL` | `gates/claude-usage` | `60` | Seconds that cache stays fresh. |
| `TASKPUMP_USAGE_HTTP_TIMEOUT` | `gates/claude-usage` | `8` | `curl --max-time` for the probe. |
| `TASKPUMP_USAGE_RESET_FILE` | `gates/claude-usage`, `tp pump` | `<repo root>/.claude-usage-reset` standalone; `<state dir>/.taskpump-usage-reset` under the pump, which exports it | The reset backstop. The pump's spelling is the one that counts in a driven run. |
| `TASKPUMP_USAGE_DEBUG` | `gates/claude-usage` | `0` | `1` traces the probe to stderr. |
| `TASKPUMP_TOKEN_GATE` | `lib/pump-lib.sh` (`gates/claude-token-fresh`) | `1` | `0` makes the credential-freshness gate answer feed-ok without looking. The pump does not export this one, so it works. |
| `TASKPUMP_TOKEN_MARGIN_S` | `lib/pump-lib.sh` | `600` | Seconds of token TTL headroom the gate wants. |
| `TASKPUMP_HEALTH_GATE` | `tp pump`, `gates/net-health` | `0` under the pump; `1` when the gate is run standalone | Whether the host-health gate runs. It ships off: `1` puts it at the head of the default chain. A `net-health` entry in a custom `TASKPUMP_GATES` still needs this key to probe. |
| `TASKPUMP_HEALTH_WINDOW` | `tp pump`, `gates/net-health` | `120` | How many seconds back the gate looks. |
| `TASKPUMP_HEALTH_PROBE_CMD` | `lib/pump-lib.sh` | empty ⇒ `journalctl -k -b 0 --since '<window> sec ago'` | The command whose output is searched. |
| `TASKPUMP_HEALTH_SIGNATURES` | `lib/pump-lib.sh` | `Failed to alloc SKB\|Firmware reported general error\|Timeout on response for query command` | The failure signatures it matches. The shipped set is one machine's WiFi firmware; a consumer enabling the gate on other hardware replaces them. |
| `TASKPUMP_DISK_GATE` | `tp pump`, `lib/pump-lib.sh`, `gates/disk-low` | `1` | Whether the low-disk gate is in the default chain and answers. Its floor is `TASKPUMP_DISK_PAUSE_GB`, shared with the watchdog (§3.7). `0` also suppresses the auto-started disk watchdog, exactly as `--no-disk-gate` does — the spawn is guarded on the same switch. |
| `TASKPUMP_DISK_WATCHDOG` | `tp pump`, `gates/disk-low`, `lib/pump-lib.sh` | `<install>/libexec/tp-disk-watchdog` | The watchdog binary the gate asks for the free-space answer. |

**All four enable-flags mean the same thing under `tp pump` and standalone.**
`TASKPUMP_USAGE_GATE` and `TASKPUMP_DISK_GATE` used to be the exceptions: the
pump assigned `USAGE_GATE=1` / `DISK_GATE=1` as literals, read neither key, and
then exported `TASKPUMP_USAGE_GATE` and `TASKPUMP_DISK_GATE` into every gate's
environment *from those literals* — so `TASKPUMP_USAGE_GATE=0 tp pump --dry-run`
printed `gates: claude-token-fresh -> claude-usage -> disk-low` and the gate
itself read its own switch back as `1`. Both keys are now read where
`TASKPUMP_HEALTH_GATE` always was, so `TASKPUMP_USAGE_GATE=0` and
`--no-usage-gate` are the same instruction with different lifetimes: the key is
a standing preference, the flag is about one run, and the flag wins when both
are given. One consequence worth knowing: `TASKPUMP_DISK_GATE=0` now also
suppresses the auto-started disk watchdog, because that spawn is guarded on the
same switch ([PUMP-MECHANISMS.md §3](PUMP-MECHANISMS.md#3-budget-gated-launching-that-never-kills-in-flight-work)).

### 3.5 Monitor — `tp monitor`

The supervision TUI. Every key here is read by `tp monitor` alone unless the
table says otherwise.

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_MONITOR_REPO_ROOT` | `tp monitor` | `$PWD`'s git worktree root, else the install root | The checkout whose worktrees to report on. |
| `TASKPUMP_MONITOR_MAIN_ROOT` | `tp monitor` | derived from that repo's `--git-common-dir` | The primary checkout, used for cache keys, notes and the pump state file. |
| `TASKPUMP_MONITOR_INTERVAL` | `tp monitor` | `1` | The redraw period in seconds; fractional values are accepted. Watching is the default on a tty (`--watch` is a deprecated alias for it, `--glance` the one-frame opt-out), so this is the refresh rate of an ordinary `tp monitor`. |
| `TASKPUMP_MONITOR_TITLE` | `tp monitor` | `TaskPump` | The title-line text. |
| `TASKPUMP_MONITOR_COLS` | `tp monitor` | the real terminal width | Width override, for tests and captures. |
| `TASKPUMP_MONITOR_LINES` | `tp monitor` | the real terminal height | Height override. |
| `TASKPUMP_MONITOR_LOG` | `tp monitor` | empty ⇒ off | A redraw-instrumentation log path. |
| `TASKPUMP_MONITOR_TAIL_LINES` | `tp monitor` | `2` | Agent-log lines per session in the compact feed. |
| `TASKPUMP_AGENT_LOG_SCAN` | `tp monitor` | `200` | How many log lines per session are scanned to build that feed. |
| `TASKPUMP_AGENT_LOG_FILTER` | `tp monitor` | empty ⇒ the built-in filter | A `jq` program that pulls feed lines out of an agent log. |
| `TASKPUMP_MONITOR_TERM` | `tp monitor` | `wezterm` | The GUI terminal **binary** the `o` key spawns to open a task file. It is not a `$TERM` override. |
| `TASKPUMP_MONITOR_TERM_ARGS` | `tp monitor` | `start --always-new-process --class %CLASS% --cwd %CWD% --` | That binary's argv template; `%CLASS%` and `%CWD%` expand. |
| `TASKPUMP_MONITOR_TASK_CLASS` | `tp monitor` | `taskpump-task` | The window class of the spawned viewer, so a compositor can rule on it. |
| `TASKPUMP_MONITOR_OPEN_CMD` | `tp monitor` | empty ⇒ use the two keys above | Replaces the whole spawn; the file path is appended. |
| `TASKPUMP_MONITOR_USAGE_WINDOWS` | `tp monitor` | `5h=+%H:%M,7d=+%a %H:%M` | Comma-separated `label=datefmt` list of usage gauges. |
| `TASKPUMP_MONITOR_DISK` | `tp monitor` | `1` | `0` (or `--no-disk`) hides the disk gauge. |
| `TASKPUMP_MONITOR_DISK_PAUSE_GB` | `tp monitor` | `10` | The gauge's pause threshold — the display's own number, independent of the watchdog's `TASKPUMP_DISK_PAUSE_GB`. |
| `TASKPUMP_MONITOR_DISK_PANIC_GB` | `tp monitor` | `5` | The gauge's panic threshold, likewise independent. |
| `TASKPUMP_MONITOR_NOTES_DIR` | `tp monitor` | `<main root>/<notes dirname>` | The directory of session notes. |
| `TASKPUMP_MONITOR_NOTES_DIRNAME` | `tp monitor` | `.taskpump-monitor-notes` | That directory's name. |
| `TASKPUMP_MONITOR_NOTES_FILE` | `tp monitor` | empty ⇒ resolve from the directory | A single notes file to tail, overriding the resolved path. |
| `TASKPUMP_MONITOR_NOTES_TAIL` | `tp monitor` | `6` | Note lines shown in the panel. |
| `TASKPUMP_MONITOR_NOTES_COLW` | `tp monitor` | `60` | Maximum note width in the right column. |
| `TASKPUMP_MONITOR_CACHE_BASE` | `tp monitor` | `${TMPDIR:-/tmp}/taskpump-monitor` | The cache path prefix the three caches below derive from. Their `<key>` is a checksum of the main root, so two checkouts each running their own pump never read each other's frames. |
| `TASKPUMP_MONITOR_SESS_CACHE` | `tp monitor` | `<cache base>-sess.<key>.tsv` | The session-probe cache file. |
| `TASKPUMP_MONITOR_SESS_TTL` | `tp monitor` | `2` | Seconds that cache stays fresh. |
| `TASKPUMP_MONITOR_PUMP_CACHE` | `tp monitor` | `<cache base>-pump.<key>.tsv` | The pump-state cache file. |
| `TASKPUMP_MONITOR_PUMP_TTL` | `tp monitor` | `8` | Seconds that cache stays fresh. |
| `TASKPUMP_MONITOR_DISK_CACHE` | `tp monitor` | `<cache base>-disk.<key>.tsv` | The disk-probe cache file. |
| `TASKPUMP_MONITOR_DISK_TTL` | `tp monitor` | `60` | Seconds that cache stays fresh. |
| `TASKPUMP_MANIFEST` | `tp monitor`, `tp cleanup` | **none** | An opt-in consumer-supplied v1 parallel-run manifest — a TSV of `name<TAB>branch<TAB>brief<TAB>task` rows — consulted for a session's launch-time display name and epic anchor. The bare `MANIFEST` is its pre-extraction spelling. |
| `TASKPUMP_MANIFEST_SUBPATH` | `tp monitor`, `tp cleanup` | **none** | The same file named relative to the repo root. |

The monitor redraws often and must not re-probe the world each frame, which is
what the four cache keys are for. It also reads, from the shared groups above:
`TASKPUMP_WORKTREES_DIR` (as a *name*, §3.2), `TASKPUMP_LEDGER_PROBE` /
`TASKPUMP_TASKS_SUBDIR`, `TASKPUMP_TASKS_DIR`, `TASKPUMP_TASK_EXT`,
`TASKPUMP_PHASE_SIGIL`, `TASKPUMP_PHASE_SEPARATOR`, `TASKPUMP_AGENT_PREFIX` /
`TASKPUMP_AGENT_CONTAINER_PREFIX`, `TASKPUMP_AGENT_LOG_NAME`,
`TASKPUMP_PUMP_STATE_FILE` / `_NAME`, `TASKPUMP_TASK`, `TASKPUMP_USAGE` and
`TASKPUMP_DAG_BIN`. `TASKPUMP_MONITOR_BIN` is *not* one of them — the pump reads
that (§3.2).

Naming a manifest that does not exist is an error, on the same rule
`TASKPUMP_CONFIG` follows: an explicit request for a specific file must not
silently fall back. TaskPump does not generate that file; the ledger's live claim
is the canonical source of what each agent is working on, and both tools are
fully functional with the keys unset.

### 3.6 DAG rendering — `tp dag-render`

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_DAG_BIN` | `tp monitor`, `tp cleanup` | `<install>/libexec/tp-dag-render` | The renderer those two invoke — the monitor for the graph tab, cleanup for the container-to-task claim map. Resolved against the install, not the repo root. |
| `TASKPUMP_DAG_REPO_ROOT` | `tp dag-render` | `$PWD`'s git worktree root, else the install root | The repository the renderer resolves the ledger against. |
| `TASKPUMP_DAG_LAYOUT` | `tp dag-render` | `<install>/lib/dag-layout.awk` | The layout program. |
| `TASKPUMP_AWK` | `tp dag-render` | `gawk` | The awk binary — the layout engine is a GNU awk program and will not run under mawk. |

`tp dag-render` also reads `TASKPUMP_TASKS_DIR`, `TASKPUMP_LEDGER_PROBE` /
`TASKPUMP_TASKS_SUBDIR`, `TASKPUMP_TASK_EXT`, `TASKPUMP_PHASE_SIGIL`,
`TASKPUMP_PHASE_SEPARATOR` and `TASKPUMP_PUMP_STATE_FILE` / `_NAME`.

### 3.7 Housekeeping — `tp cleanup`, `tp disk-watchdog`, `tp agent-watchdog`

The disk watchdog is both a standalone daemon and the thing `gates/disk-low`
asks, so it owns the threshold keys the gate reports on — one floor, two
consumers.

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_CLEANUP_REPO_ROOT` | `tp cleanup` | **the install root** (the parent of the invoked script's directory) | The repository whose worktrees get swept. |
| `TASKPUMP_RECLAIM_PRIMARY` | `tp cleanup` | `0` | `1` is the same as `--include-primary`. |
| `TASKPUMP_STOP_GRACE_SEC` | `tp cleanup` | `30` | The container stop grace period, in seconds. |
| `TASKPUMP_STUCK_THRESHOLD_MIN` | `tp cleanup`, `tp agent-watchdog` | `15` | Agent-log staleness cutoff, in minutes. |
| `TASKPUMP_WATCHDOG_POLL` | `tp agent-watchdog` | `120` | Seconds between sweeps. |
| `TASKPUMP_STARTUP_GRACE_SEC` | `tp agent-watchdog`, `tp disk-watchdog` | `120` | With `--auto-exit`, how long a zero-agent state is ignored after start. |
| `TASKPUMP_EMPTY_GRACE_CHECKS` | `tp agent-watchdog`, `tp disk-watchdog` | `3` | With `--auto-exit`, how many consecutive zero-agent checks end the daemon. |
| `TASKPUMP_DISK_REPO_ROOT` | `tp disk-watchdog` | **the install root** (same derivation) | The repository the watchdog measures and reclaims within. |
| `TASKPUMP_DISK_MOUNT` | `tp disk-watchdog` | `/` | The mount to measure. |
| `TASKPUMP_DISK_PROBE` | `tp disk-watchdog` | `df --output=avail -BG '<mount>'` | The command that reports free space. |
| `TASKPUMP_DISK_POLL` | `tp disk-watchdog` | `30` | Seconds between checks. |
| `TASKPUMP_DISK_PAUSE_GB` | `tp disk-watchdog` | `10` | Free below this drops the pool cap to 0. Also the floor the `disk-low` gate answers against. |
| `TASKPUMP_DISK_PANIC_GB` | `tp disk-watchdog` | `5` | Free below this reclaims build dirs and prunes. |
| `TASKPUMP_DISK_RECOVER_GB` | `tp disk-watchdog` | `20` | Free above this restores the original cap. |
| `TASKPUMP_DISK_COOLDOWN` | `tp disk-watchdog` | `180` | Seconds to wait after a reclaim before another. |
| `TASKPUMP_PANIC_RECLAIM` | `tp disk-watchdog` | `1` | `0` prunes only and never cleans build dirs. This is the pressure-driven reclaim; `TASKPUMP_DISK_RECLAIM` (§3.2) is the pump's unconditional per-tick one. |
| `TASKPUMP_ORIGINAL_CAP` | `tp disk-watchdog` | the cap file's contents at start, else `TASKPUMP_JOBS_FALLBACK` | The cap to restore once free space recovers. Nothing in this tree writes it — it is there for a caller that starts the watchdog when the cap has already been lowered, and so has to be told what "restored" means. |

Cleanup also reads `TASKPUMP_WORKTREES_DIR` (as a path), `TASKPUMP_RECLAIM_CMD`,
`TASKPUMP_AGENT_LOG_NAME`, `TASKPUMP_AGENT_PREFIX` (through
`lib/pump-lib.sh`'s one accessor), `TASKPUMP_DAG_BIN` and the
opt-in `TASKPUMP_MANIFEST`; the disk watchdog reads `TASKPUMP_STATE_DIR` and
`TASKPUMP_POOL_CAP_FILE`. Cleanup's stuck-agent rescue maps a container to the
task it should release through the ledger's live claim; the manifest is
consulted only as a fallback, and only when it is configured.

**Both `_REPO_ROOT` defaults are script-relative, not caller-relative.** Unlike
`tp task`, `tp pump`, `tp monitor` and `tp dag-render`, which resolve from
`$PWD`, `tp cleanup` and `tp disk-watchdog` default their repository to the
parent of the script's own directory — the TaskPump install. Run from a consumer
repo with no key set, they sweep and measure the install instead of your project
and report on that, which reads as a clean sweep: from a fixture repo carrying
`.worktrees/feat/x/target`, `tp cleanup --targets --dry-run` said `no worktree
target dirs to reclaim` until `TASKPUMP_CLEANUP_REPO_ROOT` named the fixture.

The pump does not set either key for the tools it starts. It launches the disk
watchdog with a bare `nohup`, so the watchdog inherits the pump's environment
and nothing more: its repo root is the install, and — since its state dir
defaults to that same repo root — so is its `TASKPUMP_POOL_CAP_FILE`. Whenever
the install and the workspace are different directories (every layout except
dogfooding), the cap file the watchdog writes under pressure is not the one the
pump re-reads each tick. Set `TASKPUMP_STATE_DIR` or `TASKPUMP_POOL_CAP_FILE`
explicitly for a run that wants the watchdog's cap changes to land, and
`TASKPUMP_DISK_REPO_ROOT` for one that wants its reclaim to touch your project.

**`tp cleanup`'s busy-directory list is spelled without the prefix.** The tool's
own `--help`, this document and `taskpump.conf.example` have all named it
`TASKPUMP_EXTRA_BUSY_DIRS`; the code reads the bare `EXTRA_BUSY_DIRS` and there
is no assignment between the two. With `TASKPUMP_EXTRA_BUSY_DIRS=<worktree>`,
`tp cleanup --targets --dry-run` planned `rm -rf <worktree>/target`; with
`EXTRA_BUSY_DIRS=<worktree>` it printed
`skip: <worktree>/target — busy (EXTRA_BUSY_DIRS)`. The bare name is what works,
including from a `taskpump.conf` (the file is sourced with `allexport`, so a
bare `KEY=value` is exported like any other). `ARACHNE_EXTRA_BUSY_DIRS` is inert
too — the legacy bridge only rewrites `ARACHNE_*` to `TASKPUMP_*`, and neither
spelling is the one being read.

### 3.8 The systemd unit

| Key | Read by | Default | What it configures |
|---|---|---|---|
| `TASKPUMP_BIN` | `systemd/taskpump-pump.service` | none | Path to `bin/tp`. |
| `TASKPUMP_REPO` | `systemd/taskpump-pump.service` | none | The repository root the unit `cd`s into and drives. |
| `TASKPUMP_PUMP_PHASES` | `systemd/taskpump-pump.service` | none | The phase range, passed as `--phases`. |
| `TASKPUMP_PUMP_JOBS` | `systemd/taskpump-pump.service` | none | The pool cap, passed as `--jobs`. |
| `TASKPUMP_PUMP_CEILING` | `systemd/taskpump-pump.service` | none | The usage ceiling, passed as `--usage-ceiling`. |

The unit turns these five into command-line flags, so they belong in the unit's
environment rather than in `taskpump.conf` — setting `TASKPUMP_PUMP_JOBS` in the
config file does *not* change the pool cap of a pump you start by hand.
`TASKPUMP_JOBS` (§3.2) is that key.

### 3.9 The runtime handoff — set by the pump and the runners

These names carry a decision the supervisor already made into the process that
acts on it. Setting one in a `taskpump.conf` configures nothing: it is
overwritten at launch. They are listed because they are readable state inside an
agent's session, and because two of them have configurable twins that are easy
to confuse.

| Name | Written by | Read by | Meaning |
|---|---|---|---|
| `TASKPUMP_WORKSPACE_PATH` | both runners | entrypoint (default `/workspace`) | The workspace this agent was assigned. |
| `TASKPUMP_REPO_ROOT` | both runners; and `lib/pump-lib.sh` when it asks a runner for its fleet | entrypoint (default `$TASKPUMP_WORKSPACE_PATH`), `runners/local` | The primary checkout, mounted read-only. Under the local runner it doubles as configuration — the fleet scope of `list` and `stop` (§3.3). |
| `TASKPUMP_BRANCH` | both runners | nothing in this tree | The branch the agent works on. |
| `TASKPUMP_PHASE` | both runners | entrypoint | The phase it drains. |
| `TASKPUMP_TASK_ID` | both runners | entrypoint | The lead task it is assigned. |
| `TASKPUMP_BRIEF` | both runners | entrypoint (**required**) | Host path of the *rendered* brief. `TASKPUMP_BRIEF_TEMPLATE` is the configurable one. |
| `TASKPUMP_RESUME_NOTE` | both runners | entrypoint | Host path of the *rendered* resume preamble. `TASKPUMP_RESUME_TEMPLATE` is the configurable one. |
| `TASKPUMP_CONTAINER_NAME` | `runners/local` | nothing in this tree | The agent's name, exported for the agent's own use. The container runner names its container from `TP_CONTAINER_NAME` / `ARACHNE_CONTAINER_NAME` instead. |

`TASKPUMP_BRANCH` and `TASKPUMP_CONTAINER_NAME` are the two names in this table
that nothing in TaskPump reads back: they exist for the agent's own command.
Every other row is a real contract between a writer and a reader, which is why
changing one in a conf is not merely useless but invisible.

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
