# Changelog

## Unreleased (0.1.0-dev)

### Extracted from Arachne — 2026-08-06

TaskPump began as the `scripts/` directory of
[Arachne](https://github.com/tjmisko/Arachne). It was cut out with
`git-filter-repo`, so **the full commit history of every extracted file is
preserved** — `git log --follow` on any tool reaches back through its entire
development in the original repo, across the renames below.

The extraction is being done in stages. This entry covers the first: a purely
mechanical move into a canonical layout, plus the two pieces every later stage
builds on — the `tp` dispatcher and the configuration core. No behavior was
generalized and no default was changed; with no `taskpump.conf` present the
tools do exactly what they did inside Arachne.

**Layout.** Tools moved to `libexec/tp-*`, sourced code to `lib/`, the usage
governor to `gates/claude-usage`, the container agent runner to
`runners/claude-docker/`, the systemd unit to `systemd/`, design notes to
`docs/design/`, and the suites to `tests/`.

**Added.**

- `bin/tp` — one entry point dispatching to every tool, resolving its
  installation through its own realpath so a symlink on `PATH` works.
- `lib/config.sh` — exports the install layout (`TP_ROOT` and friends) and
  discovers a `taskpump.conf` by walking up from `$PWD` to the enclosing git
  worktree root. Environment beats config beats tool default. Legacy `ARACHNE_*`
  and canonical `TASKPUMP_*` names are bridged generically in both directions,
  with no hardcoded key table.
- `taskpump.conf.example` — the full 85-key configuration surface, each key
  named alongside its `ARACHNE_*` twin.
- `tests/run-all.sh` — runs every suite and prints a per-suite summary.

**Changed.**

- Sibling lookups are install-relative (`TP_LIBEXEC_DIR`, `TP_LIB_DIR`,
  `TP_GATES_DIR`) rather than relative to the repo being driven, since TaskPump
  is meant to live inside a consumer repo as a submodule.

**Removed.**

- The `run-parallel.sh` half of the read-only-mount test guard. That launcher
  stays in Arachne and is slated for deletion there; the pump's `--phases` and
  `--jobs` cover what it did.
- The test assertion against Arachne's own `claude-settings-auto.json`. The
  runner's settings-merge semantics are now asserted against a fixture instead.
