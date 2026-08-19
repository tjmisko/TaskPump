## The rest of the CLI

`tp task` is the ledger ([LEDGER-CONTRACT.md](LEDGER-CONTRACT.md)) and `tp pump`
is the supervisor ([CLI-PUMP.md](CLI-PUMP.md)). Everything else is here: the
dispatcher that finds them, the scaffolder, the dashboard, the rescue tool, the
renderer, the two watchdogs and the usage probe.

---

### The `tp` dispatcher

`bin/tp` is a thin `exec` and nothing more. Every subcommand is the same program
with the same `argv` as the tool under `libexec/`, so `tp task next` and
`libexec/tp-task next` are indistinguishable.

| `tp <cmd>` | Runs |
|---|---|
| `init` | `libexec/tp-init` |
| `task` | `libexec/tp-task` |
| `pump` | `libexec/tp-pump` |
| `monitor` | `libexec/tp-monitor` |
| `dag-render` | `libexec/tp-dag-render` |
| `cleanup` | `libexec/tp-cleanup` |
| `agent-watchdog` | `libexec/tp-agent-watchdog` |
| `disk-watchdog` | `libexec/tp-disk-watchdog` |
| `stream-fmt` | `libexec/tp-stream-fmt` |
| `usage` | `gates/claude-usage` |

The install root is resolved through `readlink -f` on the script itself, so a
symlink on `PATH` (`ln -s /opt/taskpump/bin/tp ~/.local/bin/tp`) still finds its
own installation rather than the symlink's directory. Note what this does *not*
do: it never resolves the ledger or the workspace. Those are properties of the
caller's `$PWD` and each tool works them out for itself
([PUMP-MECHANISMS.md §6](PUMP-MECHANISMS.md#6-resolution-starts-from-the-callers-workspace)).

Four exits of its own:

| Invocation | Exit |
|---|---|
| `tp` with no arguments | prints the command list, **0** |
| `tp help`, `tp --help`, `tp -h` | the same list, **0** |
| `tp --version`, `-V`, `version` | prints `VERSION`, **0** — or **1** with a diagnostic if the file is missing |
| `tp <anything else>` | `tp: unknown command: <x>`, **2** |

That 2 is the only place in the tree that honours
[LEDGER-CONTRACT.md §10](LEDGER-CONTRACT.md#10-the-exit-code-protocol--frozen)'s
"bad CLI arguments" row for a *dispatch* mistake — and the tools it dispatches to
disagree with each other about it. Measured at this revision:

| Bad argument to | Exit |
|---|---|
| `tp` (unknown subcommand) | 2 |
| `tp init` | 2 |
| `tp cleanup` | 2 |
| `tp agent-watchdog` | 2 |
| `tp disk-watchdog` | 2 |
| `tp pump` | **1** |
| `tp monitor` | **1** |
| `tp dag-render` | **1** |
| `tp usage` | **1** |

So `tp bogus` exits 2 and `tp pump --bogus` exits 1. A wrapper that keys on 2 to
mean "the operator typed something wrong" will miss four tools out of nine. Key
on non-zero, or on the diagnostic.

---

### `tp init`

Scaffolds a repository into a consumer: writes `taskpump.conf` at the enclosing
worktree root, creates the tasks directory, prints the three commands that
continue the quickstart. It makes **no commit**, creates no tasks, and validates
nothing — `tp task fsck` is the tool for an existing ledger.

```
$ tp init
tp-init: scaffolded /home/you/project

  taskpump.conf  written
  tasks/         created

Nothing was committed — `git add taskpump.conf` when you are ready.

Next:
  tp task create T1 --title "First task" --goal "What done looks like."
  tp task ready
  tp pump --phases T1 --dry-run
```

| Flag | Effect |
|---|---|
| `--tasks-dir PATH` (or `=`) | Where the ledger goes. Default `tasks`. Trailing slashes are stripped. |
| `-h`, `--help` | The header block, exit 0. |

The written conf carries three keys: `TASKPUMP_TASKS_DIR` (verbatim, so a
relative value stays relative and anchors to the conf's own directory),
`TASKPUMP_ID_PATTERN` set to the `T` grammar, and a commented-out
`TASKPUMP_BUILD_GATE`.

**Two refusals, both exit 1.** Outside a git repository, because the ledger *is*
git and configuration is discovered by walking up to a worktree root, so there is
neither a root to write to nor a ledger to write about. And when a
`taskpump.conf` is already discoverable — refusing to shadow it, naming the file
it found. That check is asked twice on purpose: first through the tools' own
discovery (so what init refuses to shadow is exactly what a later `tp task ready`
from here would read, including an explicit `TASKPUMP_CONFIG`), and then as a
floor against `$REPO_ROOT/taskpump.conf` directly — because `TASKPUMP_NO_CONF=1`
turns discovery off, and "discovery is off" must never come to mean "clobber the
file that is already there".

Argument errors — an unknown flag, a `--tasks-dir` with no value, a value outside
`[A-Za-z0-9._/-]`, or one containing a `..` segment — exit **2**. The charset
restriction exists because the value is written into a file bash sources: a
consumer wanting something stranger writes the key by hand, where they can see
what they are doing.

`--tasks-dir` is deliberately **not** seeded from an ambient
`TASKPUMP_TASKS_DIR`. What lands in a file that outlives the shell is decided by
the command line, not by whatever happened to be exported.

---

### `tp monitor`

The live dashboard. It maps each running or recently-exited agent container to
its worktree, its task, its uptime and its last log lines, and puts the pump's
own state, the usage gauges, the disk gauge and a per-run notes field above them.
This is the largest tool in the tree and, until this section, the one with no
user-facing documentation at all.

**Watching is the default on a tty.** Calling the monitor interactively means
watching. A non-tty invocation *glances* — renders one frame and exits — so a
pipe never hangs on the redraw loop. In the watcher, terminal autowrap is
disabled (as `btop` and `htop` do) so long lines clip at the edge rather than
wrapping, and the frame is clipped to the terminal height so the top never
scrolls away.

#### Flags

| Flag | Value form | Effect |
|---|---|---|
| `--glance` | — | One frame, exit. The non-tty default. |
| `--interval N` | space or `=` | Watch, refreshing every N seconds. Fractional accepted (`0.5`). Implies watch mode. |
| `N` (bare positional) | — | Same as `--interval N`. The old `--watch N`. |
| `--watch` | — | Deprecated alias for "watch mode"; watching is the tty default now. |
| `--tab sessions\|graph` | space or `=` | Open on that tab. `dag` is accepted as a synonym for `graph`. |
| `--cursor <id>` | space or `=` | Start with the GRAPH cursor on that node. |
| `--moves <keys>` | space or `=` | Replay a key string before the first frame — scripted focus, e.g. `--moves jj`. |
| `--no-disk` | — | Hide the disk gauge. |
| `--demo` | — | Render synthetic sessions; no container runtime needed. |
| `--log PATH` | space or `=` | Append per-redraw timing to a log. |
| `--decode-keys N` | space or `=` | Print the token each of the next N keypresses decodes to, then exit (`q` stops early). Run this when a key does nothing in a new terminal. |
| `--show-help` | — | Print the key panel for `--tab`'s tab and exit — the headless form of the `?` overlay. |
| `-h`, `--help` | — | The header comment block, exit 0. |

Unknown flags, a `--tab` that is not `sessions`/`graph`/`dag`, an `--interval`
with no value, and a non-numeric `--decode-keys` all exit **1**.

#### The two tabs

`SESSIONS` (tab 0, the default) is the agent view: one row per agent container,
two feed lines beneath each. `GRAPH` (tab 1) is the task DAG, rendered by
`tp dag-render`, with a cursor on one node. The active tab is marked by **bold
weight and colour together**, never colour alone, so it still reads under
`--no-color`.

A session row is:

```
▸ ● feat-t1     [running] T1.4:in_progress  up 26 minutes  log 26s
    ⚙ Edit src/thing.rs
    tsc is clean. Now run the full suite to confirm no regressions.
```

The `▸` marks the selection (glyph *and* weight, never colour alone). The `●`
restates the container state that the bracketed word already gives, and wears the
same hue for that reason. `log <age>` turns coral once a **running** container's
log has been silent for more than **120 seconds** — a hardcoded number here, and
a much twitchier one than the fifteen minutes `tp cleanup --stuck` acts on, so
read it as "look at this", not as "this is dead". Rows whose task is `blocked`,
`stuck` or `needs-review` are collected under a `Needs attention:` heading at the
bottom.

Above the tabs, the pump line reads `pump[<range>]: <status>  |  N ready · M
open`. It is skeptical of its own input, and deliberately: a dead pump cannot
retract its last `running` write, so a `running` or `paused` claim is only
presented as live when the recorded `pid` verifies with `kill -0` **on the
recording host**. A dead pid, a missing pid, or a pid recorded on another machine
renders as `STALE (was running, pid N dead) — since <last_tick>` instead. Terminal
statuses (`drained`, `stalled`, `stopped`) claim no live process and pass through
unchallenged, showing their `paused_reason`.

#### Keys

Both tabs navigate a **selection** with vim motions and the viewport follows it.
The authoritative copy of this table is inside the tool — press `?` or type
`:help`, or run `tp monitor --show-help --tab <t>` to print the same panel
without launching the dashboard. What follows was transcribed from the single
table both of those read.

**GRAPH tab** (the cursor selects one task node):

| Keys | Action |
|---|---|
| `h` `l` `←` `→` | previous / next node in the layer |
| `k` `j` `↑` `↓` | nearest node one layer up/down, preferring a connected one |
| `gg` `G` | first / last layer |
| `^` `_` `0` `Home` | first node in the layer |
| `$` `End` | last node in the layer |
| `.` | recentre on the running task |
| `o` `Enter` | open the selected task's file in a new window |

**SESSIONS tab** (the cursor selects one agent session):

| Keys | Action |
|---|---|
| `k` `j` `↑` `↓` | previous / next session |
| `gg` `Home` | first session |
| `G` `End` | last session |
| `Enter` | open that session's current task file |
| `.` | back to the first session |
| `←` `→` | nothing here — `gt` / `gT` switch tab |

**Both tabs:**

| Keys | Action |
|---|---|
| `gt` `gT` | next / previous tab |
| `Tab` `Shift-Tab` | switch tab |
| `n` | add a note |
| `e` `Ctrl-G` | edit notes in `$EDITOR` |
| `?` `:help` | the key panel — any key closes it |
| `q` `:q` | quit |
| `PgUp` `PgDn` | page the viewport (`Ctrl-u` / `Ctrl-d`, `Space` / `b`) |

Three things the panel does not say. The letter keys accept either case (`Q`,
`J`, `N` and so on all work) with one exception: `b`, the `PgUp` alias, has no
uppercase arm (`libexec/tp-monitor:2280,2308`), so `B` does nothing on either
tab. `g` is a **prefix** resolved before the tab's own keymap
sees the key, and any key other than `g`, `t` or `T` cancels a pending `g` rather
than being swallowed by it — a half-typed motion never eats a command. And the
arrow keys switch tab on *neither* tab, on purpose: they are the node cursor's
axis on GRAPH, and a key that navigates on one tab and teleports you off the
other is the kind of thing you learn by losing your place.

#### Colour

Three families — STATE, CHROME and RESOURCE — and no colour outside them, with
three rules that hold the system
together: every escape re-opens with `0;` (SGR attributes are sticky, and a
leaked `2` has twice washed out an entire region); **state is never carried by
colour alone** — a glyph or a word always carries it too, which is what makes the
palette safe to retune and survivable under `--no-color`; and no basic-ANSI
colour numbers and no reverse video, because those resolve through the terminal's
theme and cannot be reasoned about.

The **state** family is the only one allowed green, amber or red. Green is the
progress axis and has exactly two steps — settled and live — with deliberately no
third green anywhere in the monitor:

| Token | Glyph | Means |
|---|---|---|
| done | `✓` | settled, behind you |
| running | `▶` | an agent is on it right now |
| parked | `⧗` | attention, not yet a problem |
| ready | `○` | eligible, not started |
| waiting | `◌` | ineligible, not started |
| blocked | `⊘` | cannot proceed |
| review | `!` | act now (`needs-review` or `stuck`) |

Status *words* are tinted from the same vocabulary: `running`/`in_progress` live,
`done` done, `open` ready, `exited` waiting, `blocked` blocked,
`needs-review`/`stuck` review. The pump's own status is treated as a state rather
than a fourth vocabulary — `running` is live, `paused` is parked, `drained` is
done, `stalled` is review, `stopped` is muted, and an unrecognised value is not
a state at all.

The remaining families carry no state: strong (titles, the selected row, the
input prompt), text (the datum you actually read), muted (labels, units, hints,
log tails — the text floor), rule (rules, gauge troughs, the inactive tab), and
faint, which is reserved for empty states and placeholders.

One note on the GRAPH tab: a task that is `in_progress` renders `▶ in progress`
when a live container is on its branch and `⧗ claimed, idle` when there is not —
either the container is gone, or the branch is draining a different task now. The
distinction is the renderer's own liveness verdict, not a restatement of the
ledger's status, because a branch with several `in_progress` claims elects
exactly one of them and the status bar has to name the one the canvas drew.

#### Notes

`n` opens a one-line prompt; `e` or `Ctrl-G` opens the whole file in
`$VISUAL`/`$EDITOR` (default `nvim`). Entries are appended as
`- HH:MM  <text>`, word-wrapped in the right-hand column rather than truncated,
with continuation lines indented past the timestamp.

The file is **scoped to the pump run**, not to the repository:

```
<main root>/.taskpump-monitor-notes/<phases slugified>-<started_at digits>.md
```

The key is the pump state file's `phases` plus `started_at`, so a new run starts
a fresh page and an old run's notes stay findable. With no pump state file at
all, the key is the literal `session`. `TASKPUMP_MONITOR_NOTES_DIRNAME` renames
the directory, `TASKPUMP_MONITOR_NOTES_DIR` relocates it, and
`TASKPUMP_MONITOR_NOTES_FILE` overrides the resolved path outright. Add the
directory to `.gitignore`.

#### It talks to `docker` by name

Every other tool in the tree reaches the container runtime through
`apl_docker`, which resolves `TASKPUMP_DOCKER`, then `DOCKER`, then `docker`.
The monitor does not: its disk gauge, its session sweep and its GRAPH-tab
liveness read all invoke a literal `docker`. On a host running `podman` — with
`TASKPUMP_DOCKER=podman` configured and honoured by the pump, the runner and
`tp cleanup` — the monitor's SESSIONS tab reports `(no tp-agent containers
running or recently exited)` for a fleet that is running perfectly well, and the
GRAPH tab draws every claimed task as `⧗ claimed, idle` rather than
`▶ in progress`.
Filed as a code bug. There is no workaround inside the monitor; a `docker` shim
on `PATH` is the only lever.

#### Where it reads, and what it caches

The workspace is the caller's git worktree
(`TASKPUMP_MONITOR_REPO_ROOT` overrides), but the **main root** — where the pump
state and the notes live — is resolved through `git rev-parse --git-common-dir`,
so a monitor started inside a worktree still watches the primary checkout's pump.

Everything expensive runs in background workers on its own TTL and is read from a
cache under `${TMPDIR:-/tmp}/taskpump-monitor-*`, keyed by a checksum of the main
root so two checkouts with two pumps cannot read each other's frames. A paint is
therefore tens of milliseconds and the first frame is instant; cold caches show
`…` placeholders that fill in within a couple of seconds. The three TTLs are the
docker session table (2s), the eligible-frontier scan (8s — it is a ~3s scan, far
too slow to run every paint) and the disk sizing (60s).

---

### `tp cleanup`

One-button rescue for a parallel run: hung agents, orphaned build output, a
container runtime full of dead layers. A mode is required, and supplying two
mutually exclusive *destructive* modes is an error — but `--status` carries no
duplicate-mode guard of its own, so `tp cleanup --all --status` is accepted and
quietly runs only the read-only pass. If you meant to reclaim and got a report,
that pairing is why.

| Mode | What it does |
|---|---|
| `--status` | Read-only summary: agent containers, the log-stale heuristic per container, worktree build-dir sizes, container storage. Implies `--dry-run`. |
| `--stuck` | For each running agent container whose agent log is older than the threshold: WIP-commit its worktree, stop the container (graceful, then kill), release its task claim. |
| `--targets` | Reclaim build output in every worktree, **skipping any worktree hosting a live agent**. |
| `--docker` | `builder prune -af` then `system prune -f`. The agent image itself is reused, not pruned. |
| `--all` | `--stuck`, then `--targets`, then `--docker`, in that order. |

Modifiers: `--dry-run` prints what each step would run instead of running it, and
`--include-primary` extends `--targets` to the primary checkout's own build
output — off by default so a human's in-progress build is never wiped without
asking. `-h`/`--help` exits 0; no mode, an unknown argument, two modes, or a
configured-but-missing `TASKPUMP_MANIFEST` all exit **2**; a sweep whose
`TASKPUMP_RECLAIM_CMD` returned non-zero in at least one workspace exits **3**
(`--all` included — the failure is not lost behind the later steps), because a
reclaim that failed bought no space and the caller driving it unattended has to
be able to tell.

The stuck heuristic is worth stating precisely, because it decides whether a
container gets killed: **a running agent container whose agent log's mtime is
older than `TASKPUMP_STUCK_THRESHOLD_MIN` (default 15) minutes is stuck.** Long
builds are slow but they do write to the log — every step emits an event in the
agent's JSON stream — so a fourteen-minute build is not flagged. A container with
no log file at all is skipped, not killed.

Which task a container is on comes from the **ledger's live claim**, resolved
through `tp dag-render --claims` so the rescue path shares the dashboards' parser
and their newest-heartbeat election and cannot disagree with them about which
claim is live. `TASKPUMP_MANIFEST` is an opt-in fallback for a consumer still
launching from a v1 TSV manifest; it has no default path, and a container that
maps to neither is reported rather than guessed at: `no live ledger claim (and no
manifest row) maps this container to a task; skipping the task release`. That
line means exactly what it says — **neither** source named this container — and
nothing else reuses it.

The id that claim carries is validated before it is used, and the two things that
can be wrong with it are reported differently:

**Unsafe refuses.** The §7.1 shape — "an id is a filename", so no path separator,
no whitespace, nothing outside `A-Za-z0-9._-`, no leading `-` (every CLI would
read it as a flag), and not empty, `.` or `..` — is what makes an id safe to pass
as a path component and as one argv word. A task file can reach
the ledger without passing `tp task create`'s check (written by hand, by an agent
with a filesystem, by a merged pull request), so an id that fails this is named on
stderr and the claim is left for a human rather than handed to another command:

```
WARN: ignoring the live ledger claim held by branch 'feat/e': task id G9.1\'\;\ touch\ /tmp/pwned\;\ echo\ \' contains \', which is not safe in a path or a command argument
      Fix the task file's frontmatter (`tp task fsck` names it) and release the claim by hand.
[…]   tp-agent-feat-e: the live ledger claim for this container names an id this tool refuses to pass on (the WARN above says what is wrong); its task claim is NOT released — fix the id, then 'tp task release <id>'
```

The id is printed with `printf %q`, so the quoting it would need is shown rather
than lost: `\'` is one apostrophe, not three characters of decoration.

The remedy line follows the source: a bad id in a `TASKPUMP_MANIFEST` row says
`Fix that row in <path>` instead, because it is not in any task file and
`tp task fsck` will not find it.

**Off-grammar only warns.** `TASKPUMP_ID_PATTERN` is the project's own naming
convention, not a safety property: an id like `F79.2` under a conf pinning
`^G[0-9]+…` is still one safe word. Refusing over it would leave a wedged agent's
claim held — and `tp task fsck --fix` filters on the same pattern, so it will not
repair the file either. The rescue says so and releases the claim anyway:

```
WARN: the live ledger claim held by branch 'feat/e': task id ZZ9 does not match TASKPUMP_ID_PATTERN ^T[0-9]+(\.[0-9]+)?$
      Proceeding anyway — the id is safe to hand on as one argument, and a wedged agent is worse than an off-grammar id. Fix the task file's frontmatter (`tp task fsck` names it) and release the claim by hand.
  (dry-run) …/tp-task release ZZ9 --reason tp-cleanup:\ stuck\ \(log\ idle\ 120min\)
```

#### What `--targets` runs, and where

**`TASKPUMP_RECLAIM_CMD` is the command.** The sweep runs only when the key is
set, and what it runs is that key's value, with each workspace as the working
directory — the same key, with the same meaning, that the pump's per-tick reclaim
pass executes:

```
$ TASKPUMP_RECLAIM_CMD='echo MY-CUSTOM-RECLAIM' tp cleanup --targets --dry-run
[…]   worktree: …/.worktrees/feat/a/target (16K)
  (dry-run) cd …/.worktrees/feat/a && echo MY-CUSTOM-RECLAIM
```

It used to be a *switch*: any value armed a hardcoded `cargo clean` /
`rm -rf <dir>/target` pair and the value itself was never read, so a consumer who
set the key to their project's real reclaim command got the Rust sweep instead.

**`TASKPUMP_RECLAIM_DIR` decides which workspaces are worth reclaiming**
(default `target`). It is a *probe*, not the thing that gets deleted: a workspace
with no such directory is skipped, and one that has it gets `TASKPUMP_RECLAIM_CMD`
run in it. Set it to whatever your build writes — `build`, `dist`,
`node_modules` — or to the empty string to drop the precondition and run the
reclaim command in every idle workspace. When nothing matches, the sweep says so
and names the key:

```
$ tp cleanup --targets --dry-run
[…] nothing to reclaim: no workspace under …/.worktrees/*/* has a target/ (set TASKPUMP_RECLAIM_DIR to the directory your build writes, or empty to run TASKPUMP_RECLAIM_CMD in every idle workspace)
```

Note what the empty value costs on the **primary** arm. `--include-primary` is
gated by that same probe, so with `TASKPUMP_RECLAIM_DIR=''` there is no
precondition left on it at all: the command runs in the primary checkout every
time `--include-primary` is passed, and the disk watchdog's PANIC sweep always
passes it. The sweep says so where it happens; list the primary root in
`TASKPUMP_EXTRA_BUSY_DIRS` if a human may be building there.

**A reclaim command that fails is not a reclaim.** The per-workspace `WARNING:
TASKPUMP_RECLAIM_CMD failed in <dir>` is counted as a failure, not a success: the
summary reads `reclaimed N worktree workspace(s); skipped M; FAILED K …` and the
sweep exits 3. An arbitrary consumer command fails routinely — `npm run clean` in
a workspace with no `package.json`, a toolchain that is not installed — where the
hardcoded `rm -rf` it replaced essentially never did.

The pump's own per-tick reclaim pass still carries the hardcoded `target/`
precondition; on a project whose build output is elsewhere it frees nothing
per-tick, and `tp cleanup --targets` (which the disk watchdog drives under PANIC)
is the pass that works.

**A workspace whose directory name this stack cannot carry is skipped, with a
warning.** Directory names under the worktrees base are chosen by whoever can
create a directory there, so a name containing anything outside
`[A-Za-z0-9._/-]` is refused rather than swept. Such a workspace's build output
is then never reclaimed by this sweep at all, so remove it by hand — the pump can
still create one (`apl_branch_slug_reject_reason` admits `'`, `$` and `(`, which
this skip does not), and that gap is open.

**The workspace is the install root, not the caller's.** `REPO_ROOT` here
defaults to the parent of the script's own directory — not to `$PWD`'s git
worktree the way the pump, the monitor, `tp task` and `tp dag-render` all resolve
theirs. In the dogfooding layout the two are the same directory and nothing shows;
in any vendored layout (TaskPump as a submodule or subtree) `tp cleanup
--targets` sweeps the *vendored TaskPump checkout's* `.worktrees/` and leaves the
consumer's alone. Set `TASKPUMP_CLEANUP_REPO_ROOT` — or
`TASKPUMP_WORKTREES_DIR`, which it also honours — to point it at the real one.
The one caller that no longer needs telling is `tp disk-watchdog`: its PANIC
sweep passes its own resolved workspace down as `TASKPUMP_CLEANUP_REPO_ROOT`.

Finally: the extra-busy-directory list is read as `TASKPUMP_EXTRA_BUSY_DIRS`,
with the unprefixed `EXTRA_BUSY_DIRS` still honoured as the legacy spelling, and
the two are **unioned** — not ranked. Ranking them would silently unprotect
everything the losing spelling named, which is the same harm as not reading the
key at all: the live `arachne-disk-guard` chain passes the bare name on its
command line while a conf (or `lib/config.sh`'s generic `ARACHNE_`→`TASKPUMP_`
promotion) supplies the prefixed one, so both are routinely set at once by
different parties. The skip line names the spelling that matched, or both:

```
  skip: …/.worktrees/feat/a — busy (TASKPUMP_EXTRA_BUSY_DIRS)
  skip: …/.worktrees/feat/b — busy (EXTRA_BUSY_DIRS)
  skip: …/.worktrees/feat/c — busy (TASKPUMP_EXTRA_BUSY_DIRS + EXTRA_BUSY_DIRS)
```

---

### `tp dag-render`

Renders the task DAG for a phase range as a layered ASCII graph — boxes for
nodes, one row of boxes per dependency layer, edges routed through horizontal
rail bands between layers. This is what the monitor's GRAPH tab draws, and it is
usable on its own.

```
$ tp dag-render
┌────────┐
│ T1.1 ✓ │
└───┬────┘
    │
┌───┴────┐
│ T2.1 ○ │
└────────┘
```

The phase range is `--phases`, else the live pump's range from the state file,
else every phase present. It reads task frontmatter directly in one `gawk` pass
rather than shelling out to a YAML parser per task, which is what makes it cheap
enough to sit behind the monitor's cache TTL.

| Flag | Effect |
|---|---|
| `--phases <spec>` | The range. Same syntax as the pump. |
| `--running <ids>` | Mark these as live (`▶`). |
| `--live-branches <list>` | Branches with a live agent, as the liveness signal — matched against each task's `claimed_by`. |
| `--cursor <id>` | Heavy border on one node. |
| `--index-file <path>` | Write the TSV node table the monitor navigates by: `id lay pos cx y status branch turns resumes blockers live goal`. |
| `--cols N` | Clip output to a viewport width. |
| `--pan N` | Horizontal pan offset. |
| `--compact` / `--full-ids` | Force short or full node labels. |
| `--no-color` | For tests and pipes. |
| `--claims` | **No picture.** One tab-separated row per branch holding an `in_progress` claim: `branch  task  turns  goal`. This is the mapping `tp cleanup` uses. |
| `-h`, `--help` | The header block, exit 0. |

All flags take their value in the next argument or after an `=`. An unknown
argument exits **1**. Two graceful non-answers exit **0** with a parenthetical
line rather than an error: `(no tasks dir: <path>)` and `(no tasks found)`.

It needs **GNU awk**, and says so rather than assuming: the edge-junction glyphs
come from `and()`/`or()` on a direction bitmask, which `mawk` and BWK awk do not
have and would silently mis-render every junction instead of failing. Both the
presence of `gawk` and its GNU-ness are probed up front, each with its own
message. `TASKPUMP_AWK` points at a differently-named binary. It also needs
bash 4+, checked at `libexec/tp-dag-render:59-62` — after the shebang, so a
bash 3 host reaches a real diagnostic rather than a syntax error.

**One parsing gap worth knowing.** The frontmatter reader collects blockers only
from a YAML **block list**:

```yaml
blockers:
  - T1.1
```

A flow list — `blockers: [T1.1]` — yields *no* blockers at all (the `[]` empty
form is handled; a non-empty one is not). `tp task` reads both, and always writes
the block form, so a ledger built with `tp task create --blockers` is fine. A
hand-authored or imported ledger using the inline form renders as a set of
disconnected roots: every edge the pump schedules on is simply absent from the
picture, silently. Demonstrated against two fixtures differing only in that
syntax.

---

### `tp stream-fmt`

A filter that turns a `claude -p` stream-json log into readable text.

```
tail -f .taskpump-agent.log | tp stream-fmt
docker logs -f tp-agent-feat-t1 | tp stream-fmt
```

It takes **no arguments at all** — there is no parser, so `tp stream-fmt --help`
reads stdin like any other invocation and blocks on a terminal. Non-JSON lines
pass through, with `Ralph iteration` markers in cyan and lines mentioning
`BLOCKED`/`ERROR`/`error` in red. JSON lines are formatted by type: assistant
text in blue; the final `result` block in green with its turn count and cost;
tool calls in yellow, with `Read`/`Edit`/`Write` showing the path, `Bash` showing
its description or the first 120 characters of the command, and `Grep`/`Glob`
showing the pattern.

Tool *results* are the exception: only `Bash` results are shown at all, and only
when they mention `error`/`failed`/`panicked` (red, last 15 lines) or `test
result`/`Finished`/`warning` (dim, last 3 lines). Everything else is dropped, so
a quiet run prints nothing between the tool calls.

---

### `tp agent-watchdog`

Runs `tp cleanup --stuck` on an interval, so log-stale agents get killed and
their tasks released for the next pass. It is the running-system counterpart to
the one-shot rescue: a container can wedge silently — waiting on a tool call that
never returns, a build lock held by a corpse, a disk-full `ENOSPC` — and without
intervention it sits there forever with its task still claimed.

| Flag | Effect |
|---|---|
| (none) | Watch and clean, forever. |
| `--dry-run` | Detect and log; forward `--dry-run` to cleanup so it acts on nothing. |
| `--once` | One sweep, exit 0. |
| `--auto-exit` | Exit cleanly once no agents remain. |
| `-h`, `--help` | The header block, exit 0. |

Unknown arguments exit **2**. `SIGINT`/`SIGTERM` log `stopping.` and exit 0.

`--auto-exit` is deliberately conservative in two ways: it ignores the
zero-agent state for `TASKPUMP_STARTUP_GRACE_SEC` (default 120) after start,
because the watchdog may have been launched before the first container was up,
and it then requires `TASKPUMP_EMPTY_GRACE_CHECKS` (default 3) *consecutive*
empty checks. Poll interval is `TASKPUMP_WATCHDOG_POLL` (default 120s) and the
stale cutoff it hands cleanup is `TASKPUMP_STUCK_THRESHOLD_MIN` (default 15).

---

### `tp disk-watchdog`

Watches free disk and reacts to pressure. Several parallel agents each maintain
gigabytes of build output on top of the container build cache, image storage and
writable layers; a box with 50 GB free can be a box with 0 GB free in half an
hour once rebuilds start, and when that happens mid-run writes begin `ENOSPC`ing
and agents wedge inside half-finished tool calls.

| Flag | Effect |
|---|---|
| (none) | Watch and throttle, forever. |
| `--dry-run` | Detect and log only. |
| `--once` | One check, exit 0. |
| `--auto-exit` | Exit cleanly once no agents remain (same grace rules as the agent watchdog). |
| `--gate` | One-shot feed-gate query: exit 0 = feed, exit 10 = pause, one line of reason on stderr. No loop, no cap-file write, no logging. |
| `-h`, `--help` | The header block, exit 0. |

Unknown arguments exit **2**.

The loop is a three-state machine over free space on `TASKPUMP_DISK_MOUNT`
(default `/`), with hysteresis so it cannot flap:

| State | Entered when | Action |
|---|---|---|
| `PANIC` | free < `TASKPUMP_DISK_PANIC_GB` (5) | write cap 0, run `tp cleanup --targets --include-primary`, run `tp cleanup --docker`, then sleep `TASKPUMP_DISK_COOLDOWN` (180s) before re-arming |
| `PAUSED` | free < `TASKPUMP_DISK_PAUSE_GB` (10) | write cap 0 |
| `HEALTHY` | free > `TASKPUMP_DISK_RECOVER_GB` (20) | restore the original cap |

Anything between the pause and recover thresholds holds the current state. The
"original cap" is `TASKPUMP_ORIGINAL_CAP`, else whatever the cap file held at
startup — **unless that is `0`**, which is somebody else's pause and not a cap to
restore to (a watchdog that adopted it would "recover" to zero and hold the wedge
it was started to clear) — else `TASKPUMP_JOBS_FALLBACK` (6). The startup line
says which: `original_cap=6 (…/.taskpump-pool-cap held 0, which is a pause and
not a cap; fell back)`. `TASKPUMP_PANIC_RECLAIM=0` keeps the prune but never
touches build directories. `--gate` answers against the *pause* threshold only
and **fails open**: a mount it cannot read is `free=unknown — failing open (feed
OK)`, exit 0.

Its PANIC sweep also checks `tp cleanup`'s exit status: a reclaim whose command
failed logs `WARNING: the reclaim sweep reported failures … assume it bought no
space` rather than letting the transcript read as though the panic was answered.

#### The cap-file path, and how it used to fail

The pump auto-starts this watchdog for every real run with the disk gate on
([CLI-PUMP.md §9](CLI-PUMP.md#9-side-effects-of-a-real-run)), described there as
belt-and-suspenders on top of the `disk-low` feed gate. The belt is attached: the
watchdog resolves the workspace the same way the pump does, and a `0` in the cap
file caps at zero.

**The cap file is the workspace's.** `REPO_ROOT` here is resolved through the
same workspace rule the pump, the monitor, `tp task` and `tp dag-render` use — a
discovered `taskpump.conf`'s directory, else the caller's git worktree, else the
install root — so both processes name the same file:

```
$ cd ~/project && FREE_GB_OVERRIDE=1 tp disk-watchdog --once
[…]   pool cap  → 0 (/home/you/project/.taskpump-pool-cap)
$ cd ~/project && tp pump --phases T1 --once
[…] Pump: … cap=0 (live via /home/you/project/.taskpump-pool-cap) …
```

`TASKPUMP_WORKSPACE_ROOT` pins it explicitly, exactly as it does for the pump,
and `TASKPUMP_POOL_CAP_FILE` / `TASKPUMP_STATE_DIR` still override the filename
outright. It used to default to the parent of its own script directory — the
*installation* — so from a consumer repo it wrote a cap file the pump never read
while logging `pool cap → 0` as though it had throttled something.

**A cap file containing `0` means launch nothing.** The shared cap reader used to
take the file's value only when it was `>= 1`, so the only number this watchdog
ever writes fell through to the caller's own `JOBS`:

```
$ echo 0 > .taskpump-pool-cap && tp pump --phases T1 --list | head -1
tp-pump plan — phases T1, grain phase, cap 0, ceiling 95%
$ echo 2 > .taskpump-pool-cap && tp pump --phases T1 --list | head -1
tp-pump plan — phases T1, grain phase, cap 2, ceiling 95%
```

A file with no digits in it at all is still garbage and still falls back to
`JOBS`. The `disk-low` feed gate remains the other half of the mechanism, so
`--no-disk-gate` still turns off both the gate and the watchdog together.

**…and a `0` is only as good as the process holding it.** The pump does not
overwrite an existing cap file unless `--jobs` was passed, so without a liveness
rule a `0` left behind by a killed watchdog caps the *next* unattended run at
zero: it launches nothing while nothing is wrong with the disk, and whether the
supervisor then idles or gives up, the cap it is obeying is wrong either way.
Three mechanisms keep that from happening, and they are worth knowing together:

1. **The pause is re-stamped while it is held.** Every poll in `PAUSED`/`PANIC`
   touches the cap file. No log line — nothing has changed — but the mtime is the
   evidence that somebody is still holding it.
2. **It is handed back on the way out.** The watch loop's `EXIT`/`INT`/`TERM`
   path restores the original cap if the file still reads `0`, saying
   `releasing the pool-cap pause on exit: a 0 left in … would pause the next run
   too`. (`--once` deliberately does not: its cap is meant to outlive it, and
   rule 3 is what ends that one. `--gate` never writes a cap at all.) While no
   watchdog runs, the `disk-low` feed gate — not this file — is what holds the
   line under pressure.
3. **An unrefreshed `0` expires.** A `0` whose file has not been touched for
   `TASKPUMP_POOL_CAP_STALE_SEC` (default 900s, 30× the default poll) is ignored
   by the cap reader, which says so once and clears the file to the cap actually
   in force:

   ```
   WARNING: pool cap file …/.taskpump-pool-cap has held 0 for 7200s with nothing refreshing it (TASKPUMP_POOL_CAP_STALE_SEC=900).
            A live tp-disk-watchdog re-stamps its pause every poll, so this 0 outlived the process that wrote it — using cap 4 and cleared it to 4.
   ```

   Set `TASKPUMP_POOL_CAP_STALE_SEC=0` to disable the expiry — for a pause
   written by hand that must outlive every watchdog. A **positive** cap never
   expires: `echo 3 > .taskpump-pool-cap` is a standing operator preference, not
   a pause, and nothing has to keep proving it. The heartbeat has to beat faster
   than the window, so a `TASKPUMP_DISK_POLL` at or above it is called out at
   startup (`WARNING: poll 1200s >= TASKPUMP_POOL_CAP_STALE_SEC 900s …`) — with
   the defaults, 30s against 900s, there is 30× of margin.

Its PANIC sweep also passes its resolved workspace to `tp cleanup` as
`TASKPUMP_CLEANUP_REPO_ROOT`, so the reclaim runs against the workspace being
guarded rather than against whatever `tp cleanup` would have resolved for itself.

---

### `tp usage`

The Claude Max-plan usage probe, and the gate the pump consults by default. It
wraps the OAuth usage endpoint — the same meter the Claude Code status toolbar
reads — into a single feed/pause decision.

| Mode | Output / exit |
|---|---|
| `--percent` | The integer binding percentage, or `unknown`. |
| `--json` | `{bind_percent, reset_epoch, reset_at, five_hour, seven_day, seven_day_opus, …, windows[], severity}`. `windows` is the two bars the monitor draws. |
| `--gate [--ceiling N]` | Exit 0 = feed, exit 10 = pause, one line of reason on stderr. |
| `--scan-logs '<glob>'` | Scan agent logs for a limit-reset signal and write the soonest future epoch to the backstop file. |
| `-h`, `--help` | Usage text, exit 0. |

No mode prints the usage text and exits **1**; an unknown mode, an unknown
argument to `--gate`, a non-integer ceiling, or `--scan-logs` with no glob all
exit **1** too.

The binding figure is the maximum across the windows that actually constrain the
run: the 5-hour session window, the 7-day window, and the 7-day *Opus* window.
The Sonnet-scoped weekly cap is deliberately excluded — it never gates an Opus
run. `reset_at` is the soonest reset among the windows currently at that binding
percentage, i.e. when headroom returns.

`--gate` asks two questions in order. The **reset backstop** wins first: if the
backstop file names a future epoch, that is a hard pause regardless of what a
possibly-stale percentage says. Otherwise the binding percentage is compared
against the ceiling (`--ceiling`, else `TASKPUMP_USAGE_CEILING`, else 95).

It **fails open**, and says which kind of open it is — the distinction matters to
an operator reading a gate line. A host with no Claude credentials at all reads
`skipped: <problem> (usage gate feeds; nothing to meter)`: this meter does not
apply here, and no amount of waiting will change that. A host whose meter is
briefly unreachable reads `feed OK (bind_percent unknown — meter unreachable;
failing open)`: try again next tick. Nothing is ever cached on the failure path,
so an unreadable meter can never later be mistaken for a reading.

No secret is ever printed. The token reaches `curl` on stdin, never on `argv` and
never in output.
