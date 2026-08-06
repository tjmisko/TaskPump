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

### Removed

- The `run-parallel.sh` half of the read-only-mount test guard. That launcher
  stays in Arachne and is slated for deletion there; the pump's `--phases` and
  `--jobs` cover what it did.
- The test assertion against Arachne's own agent-settings JSON. The runner's
  settings-merge semantics are asserted against a fixture instead.

### Still Arachne-shaped

Tracked for the generalization work that follows this entry, so nobody mistakes
these for finished:

- The `net-health` gate matches `brcmfmac` WiFi firmware signatures specific to
  one class of host. Generic consumers should drop it from `TASKPUMP_GATES`; its
  recovery half deliberately stays consumer-side (see
  [docs/GATES.md](docs/GATES.md)).
- Liveness enumeration matches on a container-name prefix rather than asking the
  runner, so a runner must name its agents `<prefix><branch-slug>`. A
  `runner.sh list` verb is the v2 fix (see
  [docs/RUNNERS.md §1.3](docs/RUNNERS.md#13-what-v1-deliberately-leaves-out)).
- Branch-to-container-name slugging assumes a branch contains at most one `/`.
