# Changelog

Notable changes to TaskPump. This project versions its **ledger contract**, not
just its code: the rules for what constitutes a MAJOR, MINOR, or PATCH change are
in [docs/LEDGER-CONTRACT.md §1](docs/LEDGER-CONTRACT.md#1-versioning).

## 0.2.0 — 2026-08-14

The release that makes TaskPump usable by a repository that is not Arachne. Every
silent-resolution defect found in v0.1.0 is closed, the supervisor stops lying
about its own state, and a new consumer starts with two commands instead of a
config census.

The theme is one rule applied everywhere: **a wrong answer must not be able to
look like a right one.** Most of what is fixed here exited 0 while reporting
something false — an empty frontier, a drained range, a live pump that was not
running, a ledger that was not the caller's — and every fix turns that shape
into a refusal that names the key, the path, and the diagnostic.

### Fixed

- **Conf-relative paths resolve against the configuration's own workspace, not
  `$PWD`.** A committed `taskpump.conf` can only carry relative paths — every
  worktree is a different absolute path — so `TASKPUMP_TASKS_DIR=planning/tasks`
  was correct from the repository root and silently wrong from anywhere else:
  the ledger was probed relative to the caller's directory, found nothing, and
  the frontier came back **empty at exit 0**. Reproduced live against a real
  consumer during the F80 verification: ten open tasks, header row only, rc=0.

  Resolution now anchors a conf-supplied relative path to the workspace the conf
  itself belongs to (a discovered conf anchors to its own directory; an explicit
  `TASKPUMP_CONFIG` anchors to the caller's worktree, because an explicit conf is
  routinely a cross-worktree template). An **environment**-supplied value keeps
  the shell's own convention and stays `$PWD`-relative — the caller typed it
  where they stood. A relative path that cannot be anchored at all is an error
  naming the key, never a guess. (#1)

- **`tp pump` derives its ledger from the same rule as `tp task`.** The pump's
  tasks-dir default was hardcoded to Arachne's `ops/task-loop/tasks`, so the
  brief it handed a launched agent named a directory that does not exist in a
  repository set up exactly as the README describes. It now derives from
  `TASKPUMP_LEDGER_PROBE` against the shared workspace anchor: the supervisor and
  the CLI can no longer disagree about whose ledger an invocation touches. (#2)

- **`TASKPUMP_SUBMODULE_PROBE` has no default.** The old one was Arachne's
  `ops/planning/STATUS.md` — for anyone else it either never exists (the
  idempotent init runs every tick, wasteful but safe) or exists for an unrelated
  reason and **silently skips** the submodule init some other submodule still
  needed. Unset, the init always runs; configured, it is an opt-in optimization
  whose skip-trap is documented. (#3)

- **A vendored TaskPump's own conf can no longer hijack its consumer's ledger.**
  A repository that vendors TaskPump as a subtree, a copy, or a git submodule
  carries TaskPump's dogfood `taskpump.conf` inside it; discovery walking up from
  a subdirectory found that file first and answered with TaskPump's ledger. The
  walk now steps over a vendored installation's own conf — and from inside a
  submodule it continues into the superproject — while a standalone or dogfood
  checkout keeps its conf exactly as before. (#6)

- **The pump refuses a missing ledger instead of reporting the range drained.**
  `open_count` and `frontier_phases` mask a failed `tp task ready` into "0 open
  tasks" with their `2>/dev/null` fallbacks, so a typo'd tasks dir rendered every
  phase `DONE` at rc=0 — a false drain, the exact shape of the 563-tick idle
  incident, arriving through a new door. A nonexistent tasks directory now aborts
  the run before planning, naming the directory and the `resolve` diagnostic.

- **The pump anchors its workspace to the configuration, not to its own install
  directory.** `REPO_ROOT` was derived from the script's location, so for a
  vendored or submodule consumer *every* workspace surface pointed at the
  vendored `taskpump/` instead of the project: the default image build context,
  the ops/worktrees/state directories, and every `git -C` call — branch
  verification, worktree creation, the integration trunk. A real run built,
  branched, and cut agent worktrees inside the vendored copy.

  Caught by a consumer's first shim-borne canary launch, and invisible to every
  dry-run before it: a dry run touches none of those surfaces. All 25 workspace
  uses were audited and re-anchored; TaskPump's own assets (`lib/`, `libexec/`,
  `gates/`, `runners/`, `templates/`, `hooks/`) already resolved through the
  install root and are untouched. `TASKPUMP_WORKSPACE_ROOT` pins the workspace
  explicitly for layouts that need it.

  And because the fallback rung is not an answer for a supervisor: when nothing
  anchors the workspace — no discovered conf, no repository at `$PWD`, no pin —
  the pump now refuses outright rather than planning against its own
  installation. The vendored layout, where the install root sits inside the
  caller's worktree, keeps the fallback exactly as `tp task` allows it. (#32)

- **`tp pump --detach` carries the caller's world across the systemd boundary.**
  The `systemd-run` path re-exec'd forwarding only `GITHUB_TOKEN`, dropping
  `TASKPUMP_CONFIG` (so a consumer's shim was bypassed), the working directory
  (the unit ran from `$HOME`, where conf discovery finds nothing), and every
  override. It ran conf-less and died on the missing-image check. The re-exec now
  pins `WorkingDirectory` and forwards the exported `TASKPUMP_*`/`ARACHNE_*`
  namespace plus the documented unprefixed passthroughs, so the two detach paths
  see equivalent environments. (#31)

- **No `tp pump` exit path leaves the state file claiming `running`.** After a
  completed drain the state file still read `status: running, live_agents: 1`
  with no supervisor, no container, and an inflated open count — and a reader
  trusting that label burned a rescue session. Two paths never reached a terminal
  write: `--once` exited straight after its tick, and a killed loop died wherever
  it stood.

  `--once` now stamps a terminal state carrying any gate-pause reason; the loop
  installs EXIT and INT/TERM/HUP handlers that stamp `stopped` with the signal
  and re-raise, preserving the exit status, and never overwrite a deliberate
  `drained` or `stalled`. The tick sleep became interruptible so `systemctl stop`
  is not deferred a full tick, and the handler reaps it.

  SIGKILL cannot be trapped, so the reader is skeptical too: the state file now
  records the writer's pid and host, and `tp monitor` verifies liveness before
  believing a `running` claim — a dead pid, a pidless pre-fix file, or another
  host's claim renders **STALE** with the last tick, never as a live pump. An
  alive-but-unsignalable pid (a system-unit pump watched from a user shell) is
  correctly live, and a foreign-host claim says *unverifiable*, not *dead* —
  it never asserts a death it could not check. (#22)

- **`tp cleanup`'s stuck-agent rescue maps containers to tasks through the
  ledger.** It read Arachne's `parallel-manifest.tsv` — a file TaskPump does not
  ship — so for every other consumer the rescue stopped the container and
  silently skipped the task release. The mapping is now the ledger's live
  in_progress claim, which works for any consumer, needs no manifest, and follows
  an agent as it moves through a phase instead of freezing the launch-time
  assignment. A manifest remains an opt-in fallback with no default, and a
  configured-but-missing one is a loud error naming the key that was set.

  The claim lookup deliberately ignores the pump state's phase range: a stuck
  agent is typically the one the range has already moved past, and a narrowed
  lookup skipped exactly the rescue the tool exists for. A renderer that cannot
  be reached is now reported by name rather than being swallowed into a false
  "no live ledger claim". (#7)

- **The example configurations tell the truth.** `examples/arachne.conf` is what
  a new consumer copies, and thirteen load-bearing pins were annotated
  `# (default)` after a filename flip made them real overrides — an annotation
  that, copied, silently changes behavior. Every annotation is now re-derived
  from source with a `file:line` citation, in a grammar a test suite re-checks on
  every run. The conf also set a pre-flight hook the shipped entrypoint cannot
  run, quietly raised the job cap above the historical value, and pinned a notify
  command that swallowed every notification it was given. (#4, #5, #8, #9)

- **A ledger-mutating command now refuses the install-root fallback** instead of
  silently writing into TaskPump's own ledger. When no explicit tasks dir, no
  discovered `taskpump.conf` and no cwd git toplevel answers the ledger probe,
  resolution falls back to the installation's root — correct for the vendored
  layout (the install root *is* the workspace), and a silent wrong answer
  everywhere else.

  It produced one: `tp task create` in a fresh repository with no `tasks/`
  directory wrote the task into the TaskPump checkout's ledger, with a commit,
  and was caught only because that ledger happened to be under watch
  (2026-08-12). Both sides look fine afterwards, which is what makes it the worst
  shape a wrong answer can take.

  `create`, `claim`, `complete`, `block`, `scrub` and the rest now exit non-zero
  naming what was probed, where resolution landed, and both fixes (`mkdir tasks`
  or `TASKPUMP_TASKS_DIR=…`). Read-only commands keep working on purpose —
  `resolve --tasks-dir` is the diagnostic the error points at. The vendored
  layout is unaffected: when the install root is the caller's worktree, or sits
  inside it, the fallback is correct and stays silent.

### Added

- **`tp init` scaffolds a new consumer.** The first command a repository runs: a
  starter `taskpump.conf` and a tasks directory, after which `tp task create` and
  `tp task ready` work with no further configuration. It refuses to clobber
  existing state and is a stated no-op on a second run. MINOR: additive.

- **`tp task fsck` validates — and can repair — an existing ledger.** The import
  path for a repository that already keeps markdown task files: frontmatter
  delimiters, id-versus-filename identity, the status vocabulary, contract-legal
  types for every machine key, dangling blockers, self-blocking, and **blocker
  cycles** — the one check no single-file tool can perform, and the one whose
  absence silently removes a cycle's members from the frontier forever. Report
  mode prints one line per violation and exits 3; `--fix` stamps only *missing*
  machine keys with documented defaults, in one auditable commit, never touching
  bodies and never rewriting a value that is present but wrong. MINOR: additive,
  and documented as the contract's conformance check.

- **`tp` is on the agent's PATH inside the container.** The reference runner
  bind-mounts the TaskPump installation read-only at `/opt/taskpump`, so a
  workspace no longer has to vendor a task CLI for its agents to record their own
  work. Resolution order is an explicit `TASKPUMP_WORKSPACE_TASK_CLI`, then `tp`
  on PATH, then the loud error — now unreachable with the shipped runner, kept
  for custom ones.

- **`tp pump --grain task` dispatches independent siblings concurrently.** The
  unit of dispatch had always been the phase, so two tasks that touch nothing in
  common still queued behind one agent. Task grain gives each eligible task its
  own worktree, branch, and agent name, and every supervisor mechanism moves down
  with it: liveness corroboration, ownership-aware reclaim, resume-with-context
  under the same no-progress budget, the jobs cap, and the loud deadlock exit.
  Phase grain remains the default and is byte-identical — the shipped behavior of
  an existing consumer does not move.

  Two things phase grain got for free are now explicit. Concurrency is admitted
  only between tasks whose `files:` sets are disjoint, which makes that field
  load-bearing rather than decorative — a task declaring no files is scheduled
  exclusively, because a task that names nothing may touch anything. And the
  task-scoped brief forbids `next`: the phase brief tells an agent to keep
  acquiring work, which at this grain would have it claim the very siblings the
  pump just dispatched elsewhere. MINOR: additive, opt-in behind the flag.

- **An adoption walkthrough that takes a repository from nothing to a
  supervised drain**, in the README: `tp init`, then authoring tasks or
  importing an existing markdown ledger with `fsck`, inspecting the frontier,
  `--dry-run`, one supervised `--once`, and finally `--jobs 1` with the monitor
  open. The runner choice is presented honestly — the sandboxed container runner
  needs an image, the local runner needs no docker and gives no sandbox — and
  every command in it was executed against a throwaway repository rather than
  written from the source. Nothing in it refers to the project TaskPump was
  extracted from.

- **Runner contract v2: `runner.sh list`.** A runner can now be *asked* which of
  its agents are alive, instead of the supervisor inferring it by scraping
  container names. `list` is a fleet verb — one call, one snapshot, no
  per-agent input — so answering it costs one process per tick rather than one
  per agent. An empty fleet is exit 0 with no output; a runtime that cannot be
  reached is a non-zero exit with one line on stderr, because *"nothing is
  running"* and *"I could not look"* demand opposite actions and the runner does
  not get to guess which. The reference `claude-docker` runner implements it over
  the pump's own enumeration (`lib/pump-lib.sh`), not a second copy of the
  filter, so the names it prints are by construction the names the prefix scrape
  would find. MINOR: additive to the contract, and the prefix scrape remains the
  documented fallback, so an existing v1 runner keeps working unchanged. See
  [docs/RUNNERS.md §1.3](docs/RUNNERS.md#13-list).

  The pump does not call `list` yet — it still scrapes — so this lands
  verifiable on its own.

- **The two Claude gates skip cleanly on a host with no Claude credentials.**
  Both ship in the default chain, so a consumer driving a different agent was
  running them against a file that will never exist. They now feed with one
  explanatory line — `claude-token-fresh: skipped: no claude credentials at
  <path>` — instead of failing open silently, and `claude-usage` distinguishes
  "there is no meter here" (permanent) from "the meter is unreachable"
  (transient). Missing, unreadable, malformed and expiry-less credentials are all
  absent input; a credentials file that can be read is measured exactly as
  before, and nothing is ever cached from a failed read.

  A silent feed is indistinguishable from a gate that looked and approved, and
  those are opposite facts about how protected a run is. `tp pump --dry-run` now
  prints what a *feeding* gate had to say under the `GATE:` line; the tick loop
  stays quiet, since a persistent condition would otherwise print every 30s for
  days. See [docs/GATES.md §2](docs/GATES.md#2-the-shipped-gates).

- **A branch that cannot carry an agent name is now refused**, at the claim
  (`tp task claim --branch feat/a/b`) and at pump startup (a
  `TASKPUMP_BRANCH_PREFIX` whose branches would be unmappable aborts the run
  before tick zero, naming the key).

  The agent name is the branch with `/` → `-`, so `feat/a/b` and `feat/a-b`
  produce the same name. This was documented as advisory and **silently broken
  in practice**: the branch launched, liveness could not map the name back, the
  pump read the phase as dead, and it launched a second agent on the same branch
  — the one thing the supervisor must never do. Also refused: a leading or
  trailing `/`, and whitespace. The slug encoding is unchanged (existing
  container names keep matching); one rule in `lib/pump-lib.sh` serves both
  tools. See [docs/RUNNERS.md §2](docs/RUNNERS.md#2-naming-and-identity).

- `apl_live_agent_names_strict` in `lib/pump-lib.sh`: the existing enumeration
  with the runtime's failure propagated instead of flattened into an empty list.
  Both forms now share one `docker ps --filter` expression.

- **The pump's liveness now delegates to `runner.sh list`** when the configured
  runner has it, and scrapes agent names when it does not — so a runner that
  starts something other than a container becomes visible to the supervisor
  instead of reading as permanently dead. The capability is probed once at
  startup (exit 2 = "no such verb" = v1 runner; any other failure means the
  runner *has* the verb and its runtime is merely unreachable, so a blip at
  startup does not disable delegation for the whole run).

  Mid-run, a liveness source that cannot answer falls back to the scrape and logs
  one line per tick — but the two passes that act on *absence*, reclaiming
  orphaned claims and detecting stalled phases, are skipped for that tick.
  A blind tick reads as "every agent died at once", and acting on it would
  release every claim in the range. See
  [docs/PUMP-MECHANISMS.md §2](docs/PUMP-MECHANISMS.md#2-liveness-from-process-state-never-task-status).

  The monitor, cleanup and both watchdogs are read-only observers and keep
  scraping for now; delegation is opted into per caller, not per config key.

- **`runners/local` — a shipped process runner.** Drives agents as plain host
  processes: no image, no daemon, nothing to install. Two knobs
  (`TASKPUMP_RUNNER`, `TASKPUMP_LOCAL_AGENT_CMD`) and a consumer with no
  container runtime can run a drain. Implements all three verbs; `launch`
  refuses to start a second agent under a live name.

  **It sandboxes nothing** — the agent runs with your full host permissions.
  Every guarantee in [RUNNERS.md §4](docs/RUNNERS.md#4-the-claude-docker-reference-runner)
  belongs to the container runner and none of them apply. See
  [RUNNERS.md §3](docs/RUNNERS.md#3-runnerslocal--the-process-runner).

  Liveness is tracked through a registry of `<name> <pgid>` pairs, keyed on the
  process *group* so an agent's children die with it, and read from process
  *state* so a zombie is not mistaken for a live agent — `kill -0` succeeds on
  one, and an orphaned agent under a container's non-reaping PID 1 stays a
  zombie forever.

- **Review gates: a reviewer is a task in the DAG.** `tp task review <id>
  [--panel N]` synthesizes an ordinary reviewer chain — N reviewer tasks blocked
  by the implementation, an adjudicator blocked by the panel when N > 1 — and
  adds the gate to the blockers of everything downstream, in one ledger commit
  under one lock. No new status, no new transition, no change to the eligibility
  predicate: gating is the blocker rule doing what it already did, which is why
  `tp monitor` and the DAG renderer draw the chain without being taught about it.
  The gate is *added* to a downstream task's blockers, never substituted for the
  implementation edge, so reopening the work still holds downstream shut on its
  own.

  `tp task verdict <review-id> --approve | --request-changes --findings -`
  renders the ruling through the existing doors. A change request appends the
  findings to the *implementation's* body where the next agent will read them,
  reopens it, re-arms the chain, and advances the round; past
  `review_max_rounds` (default 3) the implementation parks `needs-review` with
  the findings intact rather than looping forever. The guards close the quiet
  bypasses: no verdict on work that is not `done`, no adjudicator ruling before
  its panel reported, no panel member rendering the change request, no verdict
  over another branch's live claim, no second verdict on a rendered one.

  Two policy consequences ship with the mechanism. `next` and the eligible walks
  of `ready` skip review tasks unless `--include-reviews`, so an agent loop
  cannot claim the review of its own work — while `ready --count` still counts
  them, because a pending review is open work and a range gated on one is
  stalled, not drained. And `heartbeat` on a review task spends budget without
  moving the failure streak: the commit meter measures nothing for a task whose
  deliverable is a ledger verdict, and three honest readings of a diff must not
  scrub a reviewer as stuck.

  v1 is the hand-drivable mechanism; pump dispatch of review units, brief
  templates and monitor badges are sequenced behind it. MINOR: five optional
  verb-added frontmatter fields, two verbs, one query flag; no field, status,
  transition or exit code changed, and `fsck` accepts a review-free ledger
  exactly as before. Rationale and rejected alternatives in
  [docs/design/review-gates.md](docs/design/review-gates.md). (#12)

### Changed

- **The suites are hermetic against a pump-launched session's environment.** The
  pump necessarily exports `TASKPUMP_TASKS_DIR` and `TP_TASKS_DIR` — pointing at
  the real ledger — into every agent session; that is how an agent's `tp` finds
  its ledger. But the canonical spelling outranks its legacy twin, so a fixture
  configuring itself as `ARACHNE_TASKS_DIR=<tmpdir>` was silently outranked, and
  the test read the real ledger while believing it read its fixture. A dogfooding
  agent saw 64 spurious failures this way and burned session time proving they
  were not its own — the false-red mirror of the false-green problem
  `TASKPUMP_NO_CONF` already solved for leaked conf files.

  Every suite now sources a shared prologue that unsets the entire inherited
  `TASKPUMP_*`/`TP_*`/`ARACHNE_*` namespace **by enumeration** rather than from a
  hand-kept list, and a coverage assertion fails loudly the moment a new suite
  forgets it.

## 0.1.0 — 2026-08-13

The extraction of TaskPump from Arachne, and its generalization into a tool any
repository can use.

### Provenance

TaskPump began as the `scripts/` directory of
[Arachne](https://github.com/tjmisko/Arachne). It was cut out on **2026-08-06**
with `git-filter-repo`, so **the full commit history of every extracted file is
preserved** — `git log --follow` on any tool reaches back through its entire
development in the original repository, across every rename below.

That history is the reason these tools are worth extracting rather than
rewriting. They drove multi-day unattended agent drains, and most of what looks
like an unusual design decision is a scar from a run that failed: the resume
mechanism exists because a pump idled 563 ticks over seven hours reporting itself
healthy, workspace-first path resolution exists because a claim landed in the
wrong repository's ledger and went unnoticed for 46 commits, and the fail-open
discipline in the gates exists because a safety mechanism that wedges an
unattended run is worse than the condition it guards against. Each is now
documented alongside its incident in
[docs/PUMP-MECHANISMS.md](docs/PUMP-MECHANISMS.md).

Arachne remains the reference consumer. Its real configuration ships as
`examples/arachne.conf`.

### Conformance baseline

The extraction is gated on behavioral equivalence, measured by the suites that
came with the tools. Every suite was captured green **before** the move and must
stay green after it:

| Suite | Assertions |
|---|---:|
| `test-tp-task` | 177 |
| `test-tp-monitor` | 184 |
| `test-tp-pump` | 122 |
| `test-tp-dag-render` | 51 |
| `test-claude-usage` | 28 |
| `test-tp-cleanup` | 25 |
| `test-pump-lib` | 23 |
| `test-entrypoint` | 16 |
| **Total** | **626** |

Two of those counts moved during the extraction, and both moves are dispositions
of a cross-boundary dependency rather than a change in behavior:

- **`test-tp-pump` 127 → 122.** Five assertions grepped a launcher that stays in
  Arachne (and is slated for deletion there) for its container mount set. The
  pump's own `--phases`/`--jobs` cover what that launcher did.
- **`test-entrypoint` 9 → 16.** The suite asserted the runner reads Arachne's own
  agent-settings JSON. Re-pointed at a fixture, and expanded while it was open.

### Added

**The `tp` dispatcher.** One entry point — `tp task`, `tp pump`, `tp monitor`,
`tp cleanup`, `tp usage`, … — resolving its installation through its own
realpath, so a symlink on `PATH` still finds its own tools.

**The configuration core** (`lib/config.sh`). Discovers a `taskpump.conf` by
walking up from `$PWD` to the enclosing git worktree root — never from where the
tools are installed, which is the wrong-ledger lesson made structural.
Environment beats config beats each tool's baked-in default. Legacy `ARACHNE_*`
and canonical `TASKPUMP_*` names are bridged generically in both directions, with
no hardcoded key table, so a key added on either side needs no change here.
The bridge is guaranteed through every 0.x release and removed at 1.0.0 — a
MAJOR change under the contract's own versioning rules; see the "Legacy names"
section of [docs/CONFIG.md](docs/CONFIG.md#legacy-names).

**Documentation** — the contracts a consumer is allowed to depend on:

- `docs/LEDGER-CONTRACT.md` — the versioned compatibility surface: task file
  format, frontmatter schema, status vocabulary, state machine, eligibility
  predicate, id grammar, one-writer discipline, and the frozen exit-code
  protocol.
- `docs/PUMP-MECHANISMS.md` — the five supervisor mechanisms as contract, each
  with the incident that produced it, so a future consumer (including a
  re-implementation in another language) has a stable reference.
- `docs/CONFIG.md`, `docs/GATES.md`, `docs/RUNNERS.md` — configuration
  resolution, and the two plugin seams.
- A `README.md` written for a project that is not Arachne.

**Examples and fixtures.** `examples/minimal.conf` (the smallest working
configuration), `examples/arachne.conf` (a real consumer, annotated with why each
hardening default exists), and `tests/fixtures/generic-project/` — a standing
demo project with a `T`-prefixed id grammar that the README's examples and CI
both run against, so the quickstart cannot go stale.

**CI** (`.github/workflows/ci.yml`). A shellcheck job pinned to `-S error`, where
the tree is clean today so any new error is unambiguously a regression; and a
test job that installs gawk and a pinned mikefarah `yq` v4, runs every suite, and
drives the generic-consumer fixture. Severity is meant to ratchet upward —
`-S warning` currently has 38 pre-existing findings.

**`tests/run-all.sh`** — runs every suite, keeps going after a failure so one
broken suite does not hide the rest, and prints a summary table.

### Changed

**State, log, and note filename defaults are now `.taskpump-*`.** Every file a
run drops — pump state and log, agent log, phase brief, goal and resume notes,
pool cap, usage reset, disk-watchdog log, fs-guard mark, read-only probe,
monitor notes dir, and the monitor cache base (`$TMPDIR/taskpump-monitor`) —
defaults to a `.taskpump-*` spelling. Key names are unchanged; the historical
`.arachne-*` names remain available purely through configuration, and
`examples/arachne.conf` pins all of them for the reference consumer. The ledger
lockfile, previously hardcoded, gained its own key in the same move:
`TASKPUMP_LOCK_NAME` (default `.taskpump-task.lock`).

**Do not upgrade under a live drain.** The agent-log name is how the monitor and
the cleanup sweeper find a running agent, and the ledger lock only excludes
agents that resolve the same filename — so flipping these defaults under running
agents makes them invisible to their supervisors and splits the fleet across two
locks. Finish or stop the drain first, or pin the historical names in
`taskpump.conf` (as `examples/arachne.conf` does) before upgrading.

**Layout.** Tools to `libexec/tp-*`, sourced code to `lib/`, the usage governor
to `gates/claude-usage`, the container agent runner to `runners/claude-docker/`,
the systemd unit to `systemd/`, design notes to `docs/design/`, suites to
`tests/`.

**Sibling lookups are install-relative** (`TP_LIBEXEC_DIR`, `TP_LIB_DIR`,
`TP_GATES_DIR`) rather than relative to the repository being driven, since
TaskPump is meant to live inside a consumer repo as a submodule or beside it on
`PATH`. Ledger and workspace resolution stay caller-relative — the two questions
have opposite answers, and conflating them is what caused the wrong-ledger
incident.

**Runner defaults are TaskPump's own (G1.5).** Three flips, each pinned to its
historical value in `examples/arachne.conf`:

- `TASKPUMP_AGENT_PREFIX` defaults to `tp-agent-` (was `arachne-agent-`). This
  is the name liveness enumeration matches on. **Do not upgrade under a live
  drain:** a supervisor restarted with the new default cannot see containers
  named under the old one — finish or stop the drain first, or pin the old
  prefix.
- `TASKPUMP_IMAGE` has **no default** (was `arachne`). A real run with no image
  configured aborts before any launch, naming the key; `--dry-run` still plans
  imageless. A wrong silent default is strictly worse than a loud missing one.
- `TASKPUMP_ENTRYPOINT` defaults to `/entrypoint.sh` (was Arachne's
  `/entrypoint-parallel.sh`) — where the image contract bakes the shipped
  runner's own `entrypoint.sh`. See
  [docs/RUNNERS.md §4.0](docs/RUNNERS.md#40-the-image-contract).

**Tool identity defaults are TaskPump's own (G1.4).** Everything a run signs —
ledger commits, diagnostics, the pump's plan header and transient unit, the
sweeper's snapshot commits, the monitor's task window class — spells TaskPump
by default, each pinned to its historical spelling in `examples/arachne.conf`:

- `TASKPUMP_PROG_NAME` defaults to `tp-task` (was `arachne-task`), and ledger
  commits are authored `tp-task <task@taskpump.local>` via
  `TASKPUMP_COMMITTER_NAME` / `TASKPUMP_COMMITTER_EMAIL` (was
  `arachne-task <task@arachne.local>`).
- The pump's warn prefix, plan header, notify title, and transient systemd unit
  name derive from one new key, `TASKPUMP_PUMP_PROG_NAME`, default `tp-pump`
  (previously hardcoded `arachne-pump`).
- The stuck-agent sweep's pre-stop wip snapshot is committed as
  `tp-cleanup <cleanup@taskpump.local>` (was the `arachne-cleanup` identity).
- `TASKPUMP_MONITOR_TASK_CLASS` defaults to `taskpump-task` (was
  `arachne-task`).

**The ledger's default shape is `tasks/` and `T` ids (G1.6).** A repository
that keeps its ledger in `tasks/` with `T`-shaped ids now needs no ledger
configuration at all; Arachne's shape survives as `examples/arachne.conf` pins:

- `TASKPUMP_LEDGER_PROBE` defaults to `tasks` (was `ops/task-loop/tasks`), in
  `tp-task`'s resolution and the `tp-dag-render`/`tp-monitor` fallbacks alike;
  the container entrypoint's tasks-dir fallback follows.
- `TASKPUMP_ID_PATTERN` defaults to `^T[0-9]+(\.[0-9]+)?$` and
  `TASKPUMP_PHASE_SIGIL` to `T` (were `^F[0-9]+(\.[0-9]+)?$` and `F`).
- Default ledger resolution now lets a *discovered* `taskpump.conf` anchor: its
  directory outranks `$PWD`'s worktree root, so a directory carrying its own
  conf and `tasks/` — a fixture, a vendored subproject — owns its own ledger
  even inside a larger TaskPump-shaped repository. An explicit
  `TASKPUMP_CONFIG` never moves resolution.
- The task CLI the pump quotes into briefs is `tp task`, and the one the
  container entrypoint execs is `tp` (`TASKPUMP_TASK_CLI` /
  `TASKPUMP_WORKSPACE_TASK_CLI`; both were `scripts/arachne-task`). An image
  that cannot resolve `tp` fails at startup, before any heartbeat, naming both
  remedies.

**Supervisor policy defaults are project-neutral (G1.7).** No shipped default
can know a consumer's toolchain or hardware, so the Rust- and host-shaped
policies retire to `examples/arachne.conf` pins:

- `TASKPUMP_VERIFY_CMDS` defaults to empty (was `cargo fmt --all` +
  `cargo clippy --workspace -- -D warnings`). Brief templates gained
  conditional sections, so an empty default drops the verify prose entirely
  instead of rendering a dangling sentence.
- The per-tick reclaim pass runs only when `TASKPUMP_RECLAIM_CMD` is
  configured; the built-in `cargo clean` / `rm -rf` fallback is retired.
  Unconfigured, the pass is a logged no-op, and `tp-cleanup`'s `--targets`
  sweep is likewise armed only by a configured command.
- The `net-health` gate ships **off** (`TASKPUMP_HEALTH_GATE` flips `1` → `0`).
  Its probes match `brcmfmac` WiFi firmware signatures specific to one class of
  host — host policy, not project policy — so it joins the chain (first) only
  when a consumer opts in; its recovery half deliberately stays consumer-side
  (see [docs/GATES.md](docs/GATES.md)). The default chain is
  `claude-token-fresh -> claude-usage -> disk-low`, and `tp pump --dry-run` now
  prints the active chain as a `gates:` line.

### Removed

- The `run-parallel.sh` half of the read-only-mount test guard. That launcher
  stays in Arachne and is slated for deletion there; the pump's `--phases` and
  `--jobs` cover what it did.
- The test assertion against Arachne's own agent-settings JSON. The runner's
  settings-merge semantics are asserted against a fixture instead.

### Still Arachne-shaped

Tracked for the generalization work that follows this entry, so nobody mistakes
these for finished:

- Liveness enumeration matches on a container-name prefix rather than asking the
  runner, so a runner must name its agents `<prefix><branch-slug>`. A
  `runner.sh list` verb is the v2 fix (see
  [docs/RUNNERS.md §1.3](docs/RUNNERS.md#13-list); shipped in Unreleased, with
  the prefix scrape kept as the fallback).
- Branch-to-container-name slugging assumes a branch contains at most one `/`;
  a branch name that cannot round-trip the slug confuses liveness enumeration
  instead of being rejected at claim or launch time.
