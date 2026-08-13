# Changelog

Notable changes to TaskPump. This project versions its **ledger contract**, not
just its code: the rules for what constitutes a MAJOR, MINOR, or PATCH change are
in [docs/LEDGER-CONTRACT.md §1](docs/LEDGER-CONTRACT.md#1-versioning).

## Unreleased (0.1.0-dev)

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
  [docs/RUNNERS.md §1.3](docs/RUNNERS.md#13-what-v1-deliberately-leaves-out)).
- Branch-to-container-name slugging assumes a branch contains at most one `/`;
  a branch name that cannot round-trip the slug confuses liveness enumeration
  instead of being rejected at claim or launch time.
