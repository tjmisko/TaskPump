## `tp pump` — the supervisor

`tp pump` points a pool of sandboxed agents at a range of phases and drains it,
tick after tick, for days. What it *does* each tick, and why each mechanism is
shaped that way, is [PUMP-MECHANISMS.md](PUMP-MECHANISMS.md); what every key it
reads means is [CONFIG.md](CONFIG.md). This section is the surface: the flags,
the exit codes, the state file, the files it drops, and everything it hands a
runner. Where the surface contradicts a doc, the surface as described here is
what the code at this revision actually does.

One rule before the table, because it explains half of it: **the pump takes no
positional arguments**. `tp pump T55` is `unexpected argument: T55`, exit 1. The
range goes in `--phases`.

---

### 1. Flags

The parser is one `case` over `argv` and nothing else in the pump reads
arguments at all. Every flag below is listed with the value form that `case`
actually accepts — which is not uniform, and the irregularity has teeth (§1.1).

| Flag | Value form | Effect |
|---|---|---|
| `--phases <spec>` | space or `=` | **Required.** The range to drain. Range and comma-list syntax (`T55..T63`, `T55,T57`). Absent ⇒ `--phases is required`, exit 1. |
| `--phase <spec>` | space or `=` | Exact alias of `--phases` — the same `case` arm. Note it accepts a full range, unlike `tp task ready --phase`, where the singular means one phase. |
| `--jobs N`, `-j N` | space only | Pool cap for this run. Validated `^[0-9]+$`. |
| `--usage-ceiling N` | space or `=` | Utilization percentage the usage gate pauses at. The bare form validates `^[0-9]+$`; **the `=` form does not** (§1.1). |
| `--grain phase\|task` | space or `=` | Dispatch unit. `phase` is the default. |
| `--tick SECONDS` | space only | Seconds between ticks; overrides `TASKPUMP_TICK`. Validated `^[0-9]+$`. |
| `--branch-prefix PREFIX` | space only | Prefix every unit branch is built from. Validated at tick zero against the agent-name round-trip (§6). |
| `--base REF` | space only | Branch new worktrees are cut from. Also sets an internal `BASE_GIVEN` flag, which is the *only* thing that suppresses the integration trunk's base override (§5). |
| `--integration-trunk` | no value | Turns the integration trunk on. **There is no environment or conf key for this** — the `TASKPUMP_*` trunk keys configure a feature that only this flag enables. |
| `--integration-base REF` | space or `=` | The branch the trunk is cut from, and the base of the graduation PR. Default `main`. |
| `--resume-max N` | space or `=` | No-progress resume attempts before a stalled task is escalated. The bare form validates `^[1-9][0-9]*$`; **the `=` form does not** (§1.1). |
| `--no-resume-stalled` | no value | Disables stalled-orphan detection entirely. |
| `--no-health-gate` | no value | Drops `net-health` from the default chain and exports `TASKPUMP_HEALTH_GATE=0`. |
| `--no-usage-gate` | no value | Drops `claude-usage --gate` from the default chain and exports `TASKPUMP_USAGE_GATE=0`. `TASKPUMP_USAGE_GATE=0` in the environment or a conf does the same thing standingly; the flag wins when both are given. |
| `--no-disk-gate` | no value | Drops `disk-low` from the default chain **and** suppresses the auto-started disk watchdog (§9). `TASKPUMP_DISK_GATE=0` does the same thing standingly, watchdog included — it is the same switch. |
| `--dry-run` | no value | Print the gate chain and the plan; launch nothing; exit 0 — or exit 1 on any of the misconfigurations §6 lists, the gate and hook chains included, because the mode you confirm a chain in has to be able to say no. |
| `--list` | no value | Print the plan only; exit 0. |
| `--once` | no value | Run one real tick, stamp `stopped`, exit 0. |
| `--render-brief <unit>` | space or `=` | Debug: render the brief for one unit to stdout, exit 0. |
| `--render-resume-note <unit>` | space or `=` | Debug: render the resume preamble a stalled unit would get, exit 0. |
| `--detach` | no value | Re-exec the run detached (§8). Silently ignored unless the mode is a full run. |
| `--no-monitor` | no value | After `--detach`, keep your shell instead of handing the terminal to the monitor. |
| `-h`, `--help` | no value | Print the header block, exit 0. |

Anything else beginning with `--` is `unknown flag <x> (try --help)`, exit 1;
anything else at all is `unexpected argument: <x>`, exit 1.

**Two flags exist only in the source header, below the `# HELP-END` marker, and
therefore never appear in `--help`:** `--resume-max` and `--no-resume-stalled`.
`apl_help` stops printing at that marker, and the stalled-claim block sits below
it. Verified: `tp pump --help | grep resume-max` matches nothing.

#### 1.1 The `=` forms are irregular, and two of them skip validation

`--flag=value` works for `--phases`, `--phase`, `--grain`, `--usage-ceiling`,
`--integration-base`, `--resume-max`, `--render-brief` and
`--render-resume-note`. It does **not** work for `--jobs`, `--tick`, `--base` or
`--branch-prefix`: those die with `unknown flag --jobs=2`, exit 1, which at least
fails loudly.

The dangerous half is quieter. The bare `--usage-ceiling` and `--resume-max` arms
validate their argument; the `=` arms assign it verbatim. So:

```
$ tp pump --phases T1 --usage-ceiling=abc --list
tp-pump: gate '…/gates/claude-usage' failed (rc=1); feeding anyway —
  claude-usage: --ceiling must be an integer (got 'abc')
tp-pump plan — phases T1, grain phase, cap 4, ceiling abc%
GATE: feed-ok
```

The run starts. The usage gate then errors on every tick for the life of the
drain, and because a broken gate **fails open** (that is the rule, and it is the
right rule — [GATES.md §1.1](GATES.md#11-two-rules-that-are-not-negotiable)), the
pump feeds anyway. A single typed `=` silently disables the usage ceiling for a
multi-day unattended run, and the only evidence is one warning per tick in a log
nobody is reading at 3am. `--resume-max=abc` is accepted in the same way and
never complains at all.

Prefer the space form for both.

#### 1.2 `--jobs 0` is legal, and it stalls out rather than pausing

The validation is `^[0-9]+$`, so zero passes. The launch loop breaks when
`live >= cap`, and `0 >= 0` on the first candidate, so nothing is ever started.
The *plan* is unaffected — the cap is applied in the tick, not in `compute_plan`
— so `--jobs 0 --list` still prints `LAUNCH` lines under a `cap 0` header.

A cap of 0 is therefore not a pause: it is a run that cannot make progress, and
the deadlock detector treats it as one. Three consecutive ticks that end with
nothing live and nothing started reach `stall_exit` — exit 3, `status: stalled`,
and a page whose reason names the cause: `the pool cap is 0, so N launchable
unit(s) were never started`. Use it to make a run stop loudly, not to hold one
open; to hold a pool open at minimum feed, set the cap file to `1`, which is
also the knob that retunes a live run.

It did not always do that, and the old shape is worth remembering because it is
the one failure this detector exists to prevent. The counter used to read the
*plan* rather than the outcome — `have == 0 && PLAN_LAUNCH empty && PLAN_RESUME
empty` — and at cap 0 the plan is *full* of launchable work the cap refuses to
start, so the counter reset every tick, `STALL_EXIT_TICKS` was never reached, and
the run wrote `status: running` for as long as it was left alone. That was the
563-tick idle of
[PUMP-MECHANISMS.md §4](PUMP-MECHANISMS.md#the-563-tick-idle) in a different
costume: a supervisor reporting health while making no progress. (A `0` written
to the cap file — by you or by the disk watchdog — *is* honoured now and does
hold the launch loop at zero, but it is a *held* pause: the watchdog re-stamps
it every poll and hands it back when it exits, and one that nothing has
refreshed for `TASKPUMP_POOL_CAP_STALE_SEC` is expired and cleared. So a
hand-written `0` is not a pause that lasts either — `1` is still the number to
write by hand.
[CLI-TOOLS.md](CLI-TOOLS.md#the-cap-file-path-and-how-it-used-to-fail).)

#### 1.3 Mode precedence is last-wins

`--dry-run`, `--list`, `--once`, `--render-brief`, `--render-resume-note` and
`--help` all set one `MODE` variable, so the last one on the command line wins.
Verified: `--dry-run --once` runs a real tick; `--once --dry-run` prints the plan
and exits.

`--render-brief` and `--render-resume-note` take their unit **in the flag's own
argument slot, and write it over `PHASES`**. `tp pump --phases T2 --render-brief
T1` renders T1's brief; the `--phases T2` is discarded. At `--grain task` the
argument must be a task id in range — handed a phase token, the pump refuses
rather than fabricating a brief for a task that does not exist:

```
$ tp pump --grain task --render-brief T1
tp-pump: --render-brief takes a TASK ID at --grain task; 'T1' is not a task in range.
```

Exit 1. `--render-resume-note` has its own refusal for the same reason: it runs
the stalled-orphan detection for real and dies with `no stalled orphan detected
for phase <x> (nothing to resume)` rather than printing a preamble for a stall
that does not exist. Also exit 1.

---

### 2. Exit codes

The frozen protocol is [LEDGER-CONTRACT.md §10](LEDGER-CONTRACT.md#10-the-exit-code-protocol--frozen).
The pump does not match it in two places, and both matter to anything that keys
on the status.

| Code | When the pump produces it |
|---|---|
| **0** | A drained range — *and* five other things (§2.1). |
| **1** | Every fatal error, including every bad argument (§2.2). |
| **3** | Deadlock: `STALL_EXIT_TICKS` consecutive ticks ended with nothing live and nothing started. An empty frontier is only one of the causes — a cap of 0, a gate that refuses every launch, and a launch that fails every tick all reach it with work still on the plan. §1.2 and §12 enumerate them. |
| **2** | Never (§2.2). |

#### 2.1 Exit 0 does not mean drained

§10 reads, for the pump specifically: *drained, and a supervisor must not restart
it.* That is true of exactly one of the eight invocations that reach `exit 0`:

| Invocation | What 0 means |
|---|---|
| a full run that ends | **Drained.** The loop broke on `is_drained`, then `graduate_trunk`, `ops_push`, `write_state drained` and the drain notification ran. Do not restart. |
| `--detach` | **Nothing has drained, and nothing has even been attempted yet.** The 0 reports that the run was successfully handed to a transient `systemd --user` unit (or to `setsid`+`nohup`); the run itself begins after this process is gone and may still be going hours later. This is the sharpest edge of the seven non-drain zeros, because it is the one an operator is most likely to script: the exit status arrives immediately, looks exactly like a completed drain, and the range it was pointed at has not been touched. |
| `--once` | One tick ran. The range is in whatever state that tick left it. State file says `stopped`. |
| `--dry-run` | A plan was printed: no image build, no launches, no ledger mutation, no state file. The gate chain *is* consulted, so a gate with a cache of its own may still have written one. |
| `--list` | A plan was printed. |
| `--render-brief` | A brief was printed. |
| `--render-resume-note` | A resume preamble was printed. |
| `--help` | Help was printed. |

Verified against a three-task fixture: `tp pump --phases T1..T2 --once` returned
0 and wrote `"status": "stopped", "open_tasks": 3`. A `systemd` unit or a CI job
that treats the frozen table as complete will read a single non-draining tick as
a completed drain.

The distinguishing signal is not the exit code, it is the state file: only a real
drain writes `status: drained` (§3). A supervisor that must tell the two apart
should read that field, not `$?`.

#### 2.2 Exit 2 is not produced by the pump; `bin/tp` does produce it

§10 assigns 2 to *bad CLI arguments, any tool*. `tp-pump` has no `exit 2`
anywhere. Its only argument-error path is `die() { warn "$*"; exit 1; }`.
Verified, all exit 1: `--nonsense`, `--jobs=2`, `--grain chain`, a missing
`--phases`, `--resume-max 0`, and a bare positional argument.

Two exit-2 candidates from the audit turned out not to reach the pump either.
`lib/config.sh` exits 2 only when it is *executed* rather than sourced. A
`TASKPUMP_CONFIG` naming a missing file makes `tp_load_config` return 1, which
under `set -e` ends the pump at **1**, not 2:

```
$ TASKPUMP_CONFIG=/nonexistent/taskpump.conf tp pump --phases T1 --list
config.sh: TASKPUMP_CONFIG points at a missing file: /nonexistent/taskpump.conf
$ echo $?
1
```

Meanwhile `bin/tp` *does* exit 2, for an unknown subcommand
([CLI-TOOLS.md](CLI-TOOLS.md#the-tp-dispatcher)). So `tp bogus` exits 2 and
`tp pump --bogus` exits 1: the two halves of one CLI disagree about the same
category of mistake. Do not key a wrapper on 2 for argument errors.

#### 2.3 Exit codes the pump *consumes*

The pump is also a consumer of the protocol, and these are the ones it reads:

| From | Code | The pump's response |
|---|---|---|
| any gate | `10` | Pause launching. The gate's combined output becomes the pause reason (first `10` short-circuits the chain). |
| any gate | `0` with output | **Fed, but collected as a note.** Surfaced only by `print_plan`, indented under the `GATE:` line — never in the tick log, because a persistent condition would print every tick for days. |
| any gate | anything else | Fail open: warn, feed anyway. |
| a gate that is no longer executable | — | Skipped with a warning, **mid-drain only** — an entry that was already unrunnable at startup refused the run (§6), so this is a gate deleted or un-`chmod`'d while the drain was in flight. The warning on stderr is the whole disclosure: a real run prints no `GATE:` line to hang a note under. |
| `tp task resume-attempt` | `10` | The no-progress budget is spent: escalate to `needs-review` and notify once. |
| `tp task scrub` | `3` | Re-emit each `UNPARSEABLE`/`NO-ID` line as `ledger integrity: …`. Any other non-zero scrub status is a flat `scrub failed (continuing)`. |
| the liveness source | `75` | Degraded enumeration. One warning per tick, and the two **absence-driven** passes (orphan reclaim, stall detection) are skipped for that tick. |
| the runner's `launch` | non-zero | Warn, skip that unit. Never fatal to the run. |

---

### 3. The state file

Every terminal path and every tick writes `.taskpump-pump.state` (name and
location configurable; see `TASKPUMP_PUMP_STATE_FILE` / `TASKPUMP_STATE_DIR`).
This is the file `tp monitor` renders and the file a restarting supervisor reads.
It has twelve fields and no schema was written down before this section:

```json
{
  "phases": "T1..T2",
  "jobs": 4,
  "ceiling": 95,
  "grain": "phase",
  "started_at": "2026-08-19T06:33:50Z",
  "last_tick": "2026-08-19T06:33:55Z",
  "live_agents": 0,
  "open_tasks": 3,
  "status": "stopped",
  "paused_reason": "single tick complete (--once)",
  "pid": 2839518,
  "host": "goosebook"
}
```

| Field | What it is |
|---|---|
| `phases` | The range as typed. Also the **restart-detection key**: a leftover file whose `.phases` matches logs `resuming pump for …`; one that differs warns `a pump state file exists for a different range (…); overwriting`. |
| `jobs` | The cap **in force**, not the flag — `effective_cap()`, which reads the cap file once the flag has been stamped into it. A run whose cap file says 4 must not present the operator's `--jobs 1` here (issue #44). |
| `ceiling` | The usage ceiling in percent. Written verbatim, so an unvalidated `--usage-ceiling=abc` lands here as a string. |
| `grain` | `phase` or `task`. |
| `started_at` | UTC, set once at process start. A `--detach` re-exec is a new process and resets it. |
| `last_tick` | UTC, rewritten on every `write_state`. Under a `running` claim this is the operator's cross-check against a recycled pid. |
| `live_agents` | Live agent count at write time. Fail-open, so a **degraded** liveness tick records 0 rather than refusing to answer. |
| `open_tasks` | `tp task ready --phases … --count`. Claims are not open, so this can read 0 beside `status: stalled`. |
| `status` | One of exactly five values (below). |
| `paused_reason` | Overloaded on purpose: it carries the gate pause reason, the stall reason, the `--once` completion note, and the signal name. Not just pauses. |
| `pid` | The writer's pid. `status` alone is a claim a dead pump cannot retract, so a reader verifies with `kill -0` instead of trusting the label. |
| `host` | `$HOSTNAME`, else `hostname`, else `unknown`. Another host's pid table is unreadable from here, which is why the field exists. |

**The five statuses**, which nothing else writes down:

| `status` | Written by |
|---|---|
| `running` | The end of a normal tick. |
| `paused` | A tick where a gate returned 10. `paused_reason` carries the gate's line. |
| `drained` | The drain path, after `graduate_trunk` and the final ledger push. |
| `stalled` | `stall_exit`, immediately before exit 3. `paused_reason` names the in-flight claims. |
| `stopped` | `--once` completing, a signal handler, or the `EXIT` trap on any other exit. |

#### 3.1 Exit honesty

The `EXIT`, `INT`, `TERM` and `HUP` traps all stamp a terminal status, and three
details are worth knowing:

- The traps are installed **only after the startup prerequisites pass**. A run
  that aborts at startup — no image, no `~/.claude`, unwritable anything —
  leaves a previous run's state file alone rather than clobbering it with its own
  failure.
- `INT`/`TERM`/`HUP` get their own handlers because a fatal signal does not run
  the `EXIT` trap in a non-interactive shell. Each stamps `stopped` with
  `received SIG<x>`, reaps the backgrounded tick sleep so an orphaned `sleep`
  cannot outlive the pump, then re-raises so the exit status still reports the
  signal.
- `SIGKILL` cannot be trapped. That path is exactly what the `pid` field is for.

---

### 4. `--grain phase` vs `--grain task`

The grain decides what a **unit** is: a phase, or a single task. Every mechanism
in the pump is written in units, so both grains share one set of code paths. The
*why* is [PUMP-MECHANISMS.md §1](PUMP-MECHANISMS.md#1-frontier-scheduling-from-declared-blockers);
what changes on the surface is this:

| | `--grain phase` (default) | `--grain task` |
|---|---|---|
| a unit is | a phase token, `T3` | a task id, `T3.4` |
| its branch | `<prefix>t3` | `<prefix>t3.4` |
| turn budget | `TASKPUMP_MAX_TURNS` (600) | `TASKPUMP_TASK_MAX_TURNS` (120) — a session that claims one task does not need a sub-tree's budget |
| the brief | drain-the-phase, agent runs `tp task next` in a loop | do-this-one-task, and **explicitly do not run `next`** |
| mutual exclusion | free — one branch per phase | paid for explicitly: two tasks run concurrently only when their declared `files:` are disjoint, and an empty `files:` is exclusive |
| plan column width | 6 | 9 |
| `DONE` gloss | `(no open tasks)` | `(complete)` |
| name-collision check | the branch-prefix probe at tick zero | plus `validate_unit_names` over every unit in range |

`--grain chain` is parsed and refused: `grain 'chain' is not implemented yet;
only --grain phase and --grain task are supported (SPEC_GAP: D4 chain grain
deferred)`, exit 1. Any other value is `unknown grain '<x>' (phase|task|chain)`,
exit 1.

**Switching grain mid-flight strands the other grain's claim.** A claim is owned
by the branch that took it, the branch is derived from the grain, and neither the
reclaim pass nor the resume pass will touch a branch this run's naming scheme
does not own — deliberately, since that is the same test that keeps them off a
human's branch. Finish or `release` an in-flight claim before changing grain.

---

### 5. The integration trunk

`--integration-trunk` is off by default and is **the only switch that turns it
on**. `TASKPUMP_PUMP_TRUNK`, `TASKPUMP_TRUNK`, `TASKPUMP_PUMP_INTEGRATION_BASE`,
`TASKPUMP_INTEGRATION`, `TASKPUMP_PUMP_TRUNK_LOCK_FILE` and
`TASKPUMP_PUMP_QUARANTINE_FILE` all *configure* the feature; none of them enables
it. Setting them in `taskpump.conf` and expecting integration gets you nothing.

With the flag on, six things change:

1. **The base moves.** `BASE_REF` becomes the trunk (default `auto/trunk`) unless
   `--base` was given explicitly — worktrees are cut from continuously-integrated
   code rather than from a base that goes stale over a multi-day drain.
2. **`ensure_trunk` runs at startup** (real runs only; skipped under
   `TASKPUMP_PUMP_NO_LAUNCH`). It creates the trunk branch from
   `--integration-base` if absent and materialises a dedicated **host** worktree
   for it at `<worktrees dir>/<trunk with / → ->`. The host owns that worktree,
   not a container: the merge and the build run on the host's fresh auth, never
   inside a dying agent.
3. **Every launch merges the trunk into the unit's worktree first.** A worktree
   cut before a dependency integrated would not contain it. A conflict here
   aborts the merge, skips the launch and quarantines the unit.
4. **`reconcile_trunk` runs every tick**, after the scrub and pre-tick hooks and
   **before the feed gate** — deliberately, because integration is local compute
   that spends no API tokens, so finished work keeps propagating while *launching*
   is usage-paused. For each unit in range it skips the live ones (never merge a
   tree an agent is mid-edit on), skips the ones with no branch, skips the ones
   already an ancestor of the trunk, then under a `flock` on the trunk lock file:
   `merge --no-ff` into the trunk worktree → run the build gate → on success log
   and optionally `push` (only when `TASKPUMP_PUMP_TRUNK_PUSH=1`); on conflict
   `merge --abort` and quarantine; on a red build `reset --hard` back and
   quarantine.
   **The build gate has a hardcoded Rust default, and leaving
   `TASKPUMP_BUILD_GATE` unset does not mean "no gate".** With no command
   configured, `run_build_gate` runs `cargo check --workspace` in the trunk
   worktree, and then `./smoke_test.sh` if one is executable there. On a project
   that is not Rust, `cargo check` fails — 101 where cargo exists, 127 where it
   does not — so with `--integration-trunk` on, **every** merge is `reset --hard`
   and quarantined as a red build, the lead task is flipped to `needs-review`,
   and the operator is notified that their build is broken. Nothing is lost (the
   branch still holds the work), but the stated cause is wrong and the trunk
   never advances. Set `TASKPUMP_BUILD_GATE` to your own command, or to `true` to
   accept every merge, before turning the trunk on outside a Rust project.
5. **Quarantine is a merge verdict, not a work verdict.** The unit's lead task is
   flipped to `needs-review` — *unless it is already `done`*, in which case it
   stays `done`, because the broken thing is the merge. Both wordings notify. A
   line is appended to the quarantine file either way.
6. **`graduate_trunk` runs at the drain**, before the final ledger push. It needs
   `gh`; without it, one warning and the run still exits 0. If a PR from the trunk
   to the integration base is already open it is left alone. Otherwise the trunk
   worktree is pushed `-u origin`, and one PR titled `auto: integrate <phases>` is
   opened against the integration base, with the quarantine file's contents pasted
   into the body. Note that `TASKPUMP_PUMP_NO_GH=1` does **not** suppress this —
   that key is consulted in exactly one other function.

#### 5.1 The launch gate, and a phase-grain trap

With the trunk on, an otherwise-eligible unit is also held until every
cross-unit blocker's **code** is physically on the trunk. The plan says so:

- phase grain: `WAITING  T2  (deps done but not yet integrated into auto/trunk)`
- task grain: `WAITING  T2.1  (blockers done but not yet integrated into auto/trunk)`

The two grains answer the question differently, and only one of them is safe.

At task grain, a blocker with **no branch in the repository** counts as
integrated, with the reason spelled out in the code: the blocker set reaches back
to work that landed long before this run and never had a pump branch, and holding
a unit forever behind a branch that will never exist is a stall, not a safeguard.

At phase grain there is no such escape. `phase_deps_integrated` resolves each
cross-phase blocker to `<prefix><phase>` and asks whether that branch is an
ancestor of the trunk — and that question is *quietly false* when the branch does
not exist. So a blocker phase whose work landed months ago is reported as "deps
done but not yet integrated" forever. The reason is not true; the repository
contradicts it; and there is no tick that can change the answer.

Demonstrated on a two-task fixture (`T1.1 done`, `T2.1 open blockers: [T1.1]`, no
`feat/t1` branch anywhere):

```
$ tp pump --phases T1..T2 --integration-trunk --list
  WAITING  T2     (deps done but not yet integrated into auto/trunk)
  DONE     T1     (no open tasks)

$ tp pump --phases T1..T2 --integration-trunk --grain task --list
  LAUNCH   T2.1      -> feat/t2.1
  DONE     T1.1      (complete)

$ tp pump --phases T1..T2 --integration-trunk        # TASKPUMP_PUMP_STALL_EXIT_TICKS=1
[…] T1..T2 STALLED after 1 idle ticks — 1 open task(s) … : nothing launchable, nothing resumable […]
$ echo $?
3
```

**The precondition this implies, until the code changes:** at `--grain phase`
with `--integration-trunk`, every cross-phase blocker of every phase in the range
must have been driven by *this* pump's branch naming — i.e. `<prefix><phase>`
must exist as a local branch. A range whose upstream phases predate the pump, or
were merged and had their branches deleted, walks straight to exit 3 while being
told a reason the repository does not support. Either drop `--integration-trunk`
for that range, run it at `--grain task`, or recreate the blocker phase's branch
so the ancestry question has something to answer. Filed as
[#74](https://github.com/tjmisko/TaskPump/issues/74) for the diagnostic — the
wait names a branch that never existed and never says so — and
[#75](https://github.com/tjmisko/TaskPump/issues/75) for the missing escape
hatch that task grain already has.

---

### 6. What the pump refuses before it starts

All of these are exit 1, and all of them fire before any launch:

| Refusal | Why |
|---|---|
| `TASKPUMP_WORKSPACE_ROOT names a missing directory` | The pin has to name something. |
| `refusing to run against the TaskPump installation itself` | Resolution fell back to the install root with no conf, no pin and a `$PWD` outside any consumer repo. A drain planned there would build, branch and cut worktrees inside the vendored TaskPump and then report the range DONE at rc=0 against the wrong ledger. |
| `--phases is required` | No default range exists, and a wrong one is expensive. |
| `tasks directory does not exist: <dir>` | A missing ledger and a drained range must not look alike: `open_count` masks a refusal into "0 open", which would render every phase DONE at rc=0. |
| `bad phase range '<x>'` | The spec is expanded and validated **in the main shell**, up front. Every later consumer reads the expander through a process substitution, where `die` would kill only the subshell — a malformed range would be reported and then ignored, leaving the pump to idle green against an empty phase list. |
| a branch-prefix whose slug cannot round-trip | The agent name is the branch with `/` → `-`, and liveness is read back out of those names. Checked once at tick zero, because the prefix is a property of the configuration, not of any one launch. |
| a unit-name collision at `--grain task` | `validate_unit_names` runs before **every** mode, `--dry-run` included: a plan showing two tasks launching onto one agent name is a wrong plan, and finding that out at launch time is too late. |
| `gate entry is not an executable file: <x>` | Every entry of the gate chain in force is checked before any mode, `--dry-run` included: each line's first word must be a regular file with the execute bit (a directory passes `-x` and is refused too). An entry that cannot run used to be skipped with one warning and then reported as `GATE: feed-ok` for the rest of the run — a gate the operator configured, believes in, and does not have ([GATES.md §1.0](GATES.md#10-how-taskpump_gates-is-spelled-and-how-it-fails)). The refusal names the key that produced the entry, which is not always the chain: the default chain's usage entry comes from `TASKPUMP_USAGE`. |
| `pre-tick hook entry is not an executable file: <x>` | The same check on `TASKPUMP_PRE_TICK_HOOKS`, where the same typo silently disables `fs-guard`. |
| `TASKPUMP_<X>_GATE must be 0 or 1 (got '<v>')` | The three gate enable switches are numeric keys — every gate in the tree tests them arithmetically — so `false`, `no` and `off` are refused by name rather than read. Checked against the environment, so passing the matching `--no-*-gate` flag does not hide an unreadable key. |
| no `~/.claude`, no `TASKPUMP_IMAGE`, no executable runner | Launch prerequisites. Skipped entirely under `TASKPUMP_PUMP_NO_LAUNCH=1` and never checked by `--dry-run`/`--list`, so a read-only plan works on a host with none of them. |
| a missing brief template | Checked for the render modes and for real runs. |

---

### 7. Gates and pre-tick hooks, as the pump invokes them

**The default gate chain** is assembled from the three `--no-*-gate` flags:

> `[net-health] → claude-token-fresh → [claude-usage --gate] → [disk-low]`

`net-health` is in the chain only when `TASKPUMP_HEALTH_GATE=1`; the other three
are in unless their flag drops them. A configured `TASKPUMP_GATES` **replaces the
whole chain** and is used verbatim — including, note, that a `net-health` entry in
a custom chain still needs `TASKPUMP_HEALTH_GATE=1` to actually probe.
`--dry-run` prints the chain as basenames in consultation order, and a real run
logs the identical line at startup from the same function — the mode you confirm
a chain in and the mode that spends money must not describe the chain
differently:

```
gates: claude-token-fresh -> claude-usage -> disk-low
```

Basenames only — a custom entry's arguments do not show, so `claude-usage --gate`
and `claude-usage --gate --ceiling 50` print identically. Every entry on that
line resolved to an executable *file*, because a chain containing one that did
not would have refused the run before printing anything (§6). One name per
**line** of the chain, though, and only each line's first word is checked — two
gates written on one line are one entry, and the line shows the first of them
([GATES.md §1.0](GATES.md#10-how-taskpump_gates-is-spelled-and-how-it-fails)).

**What every gate sees.** The pump exports a fixed set before running the chain,
not "its configuration" wholesale: `TASKPUMP_HEALTH_GATE`, `TASKPUMP_USAGE_GATE`,
`TASKPUMP_DISK_GATE`, `TASKPUMP_HEALTH_WINDOW`, `TASKPUMP_USAGE_CEILING`,
`TASKPUMP_USAGE_RESET_FILE`, `TASKPUMP_CREDENTIALS` and
`TASKPUMP_DISK_WATCHDOG`, plus the legacy `HEALTH_GATE`, `HEALTH_WINDOW` and
`ARACHNE_USAGE_RESET_FILE`. The three `*_GATE` switches carry the value in force
for this run — the operator's key with the matching `--no-*-gate` flag applied —
so a gate kept in a custom chain reads back what was actually asked for.
`TASKPUMP_CREDENTIALS` is derived from the agent home **only when unset** — an
operator's explicit value is never clobbered by a derivation of itself.
Everything else a gate wants, it discovers for itself the way any tool does.

**Pre-tick hooks** have no document of their own; this is their contract. The
default chain is `hooks/gitignore-repair` then `hooks/fs-guard`;
`TASKPUMP_PRE_TICK_HOOKS` replaces it. Each entry is a command line. For each:

- an entry whose first word is not an executable file **refuses the run** at
  startup, before any mode (§6) — the same rule the gate chain is held to, and
  for the same reason: a hook that is skipped is indistinguishable from a hook
  that ran and found nothing. A hook that stops being executable *mid*-drain is
  skipped with one warning per tick instead, as a gate is;
- the workspace root is **appended** to whatever words the entry itself carries,
  and `TP_REPO_ROOT` is exported alongside. A bare `hooks/fs-guard` therefore
  reads the root as `$1`; an entry written `myhook --strict` reads it as `$2`;
- stdout and stderr are captured together and logged;
- a **non-zero exit is a warning and nothing more** — a hook never skips or fails
  a tick;
- the concatenated output of the whole chain is compared against a fingerprint in
  the mark file (`.taskpump-fsguard.notified` by default). Changed output
  notifies once; unchanged output stays quiet however many ticks it persists for;
  output going empty deletes the mark file, which re-arms the notification.

The dedup is the point. A persistent condition — a dirty primary checkout, say —
would otherwise fire a desktop notification every `TICK` seconds for days, and
the mark file survives a supervisor restart so a restart cannot re-page.

---

### 8. `--detach`

`--detach` re-execs the same command minus `--detach`, fully detached, so a
multi-day run survives a closed terminal or a dropped SSH session. **It is
honoured only for a full run:** the check is `DETACH == 1 && MODE == run`, so
`--once --detach` runs in the foreground and `--dry-run --detach` never reaches
the check at all. Neither warns.

Preferred path: a transient systemd user unit.

```
systemd-run --user --collect --unit=<prog>-<phases sanitized>
  --description='<prog> usage-governed pump (<phases>)'
  -p WorkingDirectory=$PWD
  [--setenv=NAME=VALUE …]
  <this script> <original argv minus --detach>
```

The unit name is the program name (`TASKPUMP_PUMP_PROG_NAME`, default `tp-pump`)
plus the phase spec with every non-alphanumeric character turned into `-`.
`Restart` is deliberately not set for a transient unit; the shipped
`systemd/taskpump-pump.service` is the template for restart-on-failure.

The environment forward is the part worth understanding, because the transient
unit starts from the user manager with `$HOME` as its cwd and a near-empty
environment. Two rules:

- **Only exported names cross.** Every exported `TASKPUMP_*` and `ARACHNE_*`
  variable is forwarded, plus ten documented unprefixed names —
  `GITHUB_TOKEN`, `MAX_TURNS`, `AGENT_MODEL`, `JOBS`, `POOL_TICK`,
  `POOL_STAGGER`, `HEALTH_WINDOW`, `DOCKER`, `AGENT_MEMORY_MAX`,
  `AGENT_MEMORY_SWAP` — and only when the caller exported them. The pump's own
  computed state never crosses.
- **`WorkingDirectory=$PWD` is forwarded because conf discovery walks up from
  `$PWD`.** Without it the detached run would discover a different
  `taskpump.conf`, or none.

Fallback when `systemd-run` is missing or the user manager is unreachable:
`setsid nohup … >>$PUMP_LOG 2>&1 </dev/null &`, which inherits the environment
and cwd natively — the forward above exists to make the preferred path equivalent
to it. This is the **only** thing that ever writes `.taskpump-pump.log`; a
foreground run logs to stdout and a systemd run logs to the journal.

Either way the launching terminal is then handed to `tp monitor`, since watching
is almost always what you want next. Quitting the monitor with `q` leaves the
pump running — it is a viewer, not the run. `--no-monitor` or
`TASKPUMP_PUMP_MONITOR=0` keeps your shell; a non-tty or a missing monitor binary
skips it automatically with a line saying so.

---

### 9. Side effects of a real run

Two of them are worth knowing before you start an unattended run:

- **The pump exports the operator's GitHub token into every agent.** When
  `GITHUB_TOKEN` is unset and `gh` is on `PATH`, the pump runs `gh auth token` at
  startup and exports the result. Every launched agent then receives it in its
  environment (§10). If you do not want that inside a sandbox, set `GITHUB_TOKEN`
  to something else — including the empty string — before starting the run.
- **The pump starts a second daemon.** For `MODE=run` with the disk gate on and
  `TASKPUMP_PUMP_NO_LAUNCH` unset, it launches
  `nohup tp-disk-watchdog --auto-exit` in the background, logging to
  `TASKPUMP_DISK_WATCHDOG_LOG`, and says so: `disk watchdog started (cap-file
  path; log: …)`. Turning the disk gate off suppresses it along with the gate —
  `--no-disk-gate` or `TASKPUMP_DISK_GATE=0`, the same switch either way. The
  watchdog retires itself once no agents remain. It resolves the workspace the
  way the pump does, so the cap file it writes is the one this run re-reads
  ([CLI-TOOLS.md](CLI-TOOLS.md#tp-disk-watchdog)).

Files a run touches, all in `TASKPUMP_STATE_DIR` (default: the workspace root)
unless individually overridden:

| File | Written when |
|---|---|
| `.taskpump-pump.state` | every tick and every terminal exit |
| `.taskpump-pool-cap` | at startup when `--jobs` was typed, **or whenever the file does not exist** — so a first run seeds it from `TASKPUMP_JOBS` with no flag at all. Read every tick, which is what makes the cap live-retunable. |
| `.taskpump-fsguard.notified` | the pre-tick hook fingerprint |
| `.taskpump-disk-watchdog.log` | the auto-started watchdog's output |
| `.taskpump-pump.log` | the `setsid` detach fallback only |
| `.auto-trunk.lock` | the first `--integration-trunk` run |
| `.auto-trunk-quarantine` | appended on each failed trunk merge; read once, at graduation, to fill in the PR body |
| `<worktree>/.taskpump-phase-brief.md` | each launch |
| `<worktree>/.taskpump-resume.md` | each **resume** — and actively deleted on a normal launch, so a fresh drain of a reused worktree cannot inherit a previous resume's instructions |

The two `.auto-trunk*` files are in the fs-guard's allowlist alongside
`.worktrees/` and `ops`, because they are untracked files the supervisor itself
creates in the repo root — without that entry the contamination guard would fire
on every tick for the rest of the drain. The last two rows are the exception to
the heading above: they are written inside the unit's own worktree, not in
`TASKPUMP_STATE_DIR`.

The cap-file write is placed below every startup abort and above the banner on
purpose: a pump that never ticked must not clobber a number a previous run, an
operator or the disk watchdog set. An unwritable cap file is not fatal — the run
holds at the flag's value and says `could not write … — this run holds at --jobs
N; retuning through that file is off`.

---

### 10. What the pump hands a runner

At launch the pump builds the child environment explicitly with `env`, so the
runner receives these **in addition to** everything the pump itself exports.
Twenty-one canonical `TP_*` names, `GITHUB_TOKEN`, and thirteen legacy twins:

| `TP_*` | Legacy twin | Value |
|---|---|---|
| `TP_WORKSPACE` | `WORKSPACE_PATH` | the unit's worktree path |
| `TP_BRANCH` | — | the unit's branch |
| `TP_CONTAINER_NAME` | — | agent name: the branch with `/` → `-`, prefixed |
| `TP_IMAGE` | — | `TASKPUMP_IMAGE` |
| `TP_ENTRYPOINT` | — | `TASKPUMP_ENTRYPOINT` |
| `TP_TASK_ID` | `ARACHNE_TASK_ID` | the lead task — the resumed task id on a resume, else the phase's lowest eligible task (the unit itself at task grain) |
| `TP_PHASE` | `ARACHNE_PHASE` | the unit's phase |
| `TP_MODEL` | `AGENT_MODEL` | `TASKPUMP_AGENT_MODEL` |
| `TP_MAX_TURNS` | `MAX_TURNS` | `TASKPUMP_MAX_TURNS`, or `TASKPUMP_TASK_MAX_TURNS` at task grain |
| `TP_REPO_ROOT` | `REPO_ROOT` | the workspace root |
| `TP_BRIEF` | `ARACHNE_BRIEF` | the rendered kickoff brief, as a string |
| `TP_RESUME_NOTE` | `ARACHNE_RESUME_NOTE` | path to the written resume note, empty on a normal launch |
| `TP_LEDGER_REPO` | — | the ledger checkout |
| `TP_CLAUDE_DIR` | `CLAUDE_DIR` | the agent home on the host |
| `TP_CLAUDE_JSON` | `CLAUDE_JSON` | the agent config on the host |
| `TP_AGENT_LOG_NAME` | — | log filename inside the worktree |
| `TP_GOAL_NOTE_NAME` | — | goal-note filename (written *inside* the container) |
| `TP_TASKS_DIR` | — | the ledger directory |
| `TP_MEMORY_MAX` | `AGENT_MEMORY_MAX` | `${AGENT_MEMORY_MAX:-3g}` |
| `TP_MEMORY_SWAP` | `AGENT_MEMORY_SWAP` | `${AGENT_MEMORY_SWAP:-5g}` |
| `TP_DOCKER` | `DOCKER` | the container runtime binary |
| `GITHUB_TOKEN` | — | §9 |

Two things this table says that
[RUNNERS.md §1.1](RUNNERS.md#11-launch) currently does not. First, **eight of the
twenty-one have no twin at all**: `TP_BRANCH`, `TP_CONTAINER_NAME`, `TP_IMAGE`,
`TP_ENTRYPOINT`, `TP_LEDGER_REPO`, `TP_AGENT_LOG_NAME`, `TP_GOAL_NOTE_NAME`,
`TP_TASKS_DIR`. Second, **most twins are not `ARACHNE_*`** — they are the
un-prefixed pre-extraction names (`WORKSPACE_PATH`, `AGENT_MODEL`, `MAX_TURNS`,
`REPO_ROOT`, `CLAUDE_DIR`, `CLAUDE_JSON`, `DOCKER`, `AGENT_MEMORY_MAX`,
`AGENT_MEMORY_SWAP`), and only four are (`ARACHNE_TASK_ID`, `ARACHNE_PHASE`,
`ARACHNE_BRIEF`, `ARACHNE_RESUME_NOTE`). A third-party runner written to read
`ARACHNE_MODEL` or `ARACHNE_MAX_TURNS` would launch with neither.

`AGENT_MEMORY_MAX` and `AGENT_MEMORY_SWAP` are read by the **pump** from its own
host environment, and there is deliberately no `TASKPUMP_*` spelling of either.
Setting them in `taskpump.conf` therefore does nothing at all: the conf sets
`TASKPUMP_*` keys, and the legacy bridge only maps `TASKPUMP_X ↔ ARACHNE_X`.
Export them in the shell that starts the pump, or in the systemd unit.

---

### 11. Reading a plan

`--dry-run` and `--list` print the same plan; `--dry-run` adds two lines above
it.

```
[dry-run] no image build, no launches, no ops mutation
gates: claude-token-fresh -> claude-usage -> disk-low
tp-pump plan — phases T1..T2, grain phase, cap 4, ceiling 95%
GATE: feed-ok
  LAUNCH   T1     -> feat/t1
  WAITING  T2     (1 open, none eligible — cross-phase blockers pending: T1.1 (open))
frontier: 1 launchable, 0 running, 0 resumable, 1 waiting | open tasks in range: 3
```

The header names the range, the grain, the **cap in force** and the ceiling. The
`GATE:` line is either `feed-ok` or `PAUSED — <reason>`; any feeding gate that
had something to say is printed indented beneath it, and this is the only place
those notes ever surface.

Five verbs, in this order:

| Verb | Meaning |
|---|---|
| `LAUNCH` | eligible, nothing holding it — this tick would start it |
| `RUNNING` | a live agent is on this unit's branch; never double-launched |
| `RESUME` | an orphaned claim with committed work on this unit's branch, container dead |
| `WAITING` | not finished and not startable, **with the reason** |
| `DONE` | `(no open tasks)` at phase grain, `(complete)` at task grain |

Every `WAITING` line carries a derived reason, never an assumed one. At phase
grain the tail is assembled from seven clauses, `;`-joined, in this order:

```
awaiting review: <ids> (the pump never dispatches a review task; record the verdict)
cross-phase blockers pending: <id> (<status>), …
in-phase blockers pending: <id> (<status>), …
claimed: <id> by <branch>, …
in flight: <id> (claimed by <branch>), …
blockers with no task file: <ids>
open and unblocked but outside the frontier: <ids>
```

With open work in the phase the whole thing is prefixed `<N> open, none eligible
— `. If the count says there is open work and the walk finds none, the reason is
`the ledger lists no open task in this phase — the count and the listing
disagree`, which names the two answers that conflict rather than inventing a
dependency. Task grain has its own shorter set: `blockers pending: <ids>`,
`claimed by <branch>, no live container`, `status: <x> — needs a human`,
`blockers done but not yet integrated into <trunk>` (§5.1), and one of three
mutual-exclusion holds — `files: empty — exclusive; <holder> holds the tree`,
`<holder> declares no files: — exclusive; it holds the tree`, or
`files overlap with <holder>: <path>`. A stranded unit that is also held reads
`stalled on <id> (<status>) but held: <that reason>`. The catch-all,
`no reason recorded — that is a pump bug, please report it`, reads like a bug on
purpose: reaching it means a `WAITING` unit was filed with no reason at all.

---

### 12. The tick, in the order the code runs it

[PUMP-MECHANISMS.md](PUMP-MECHANISMS.md#the-shape-of-a-tick) gives the shape and
the reasoning. This is the literal order, because two steps are not where the
prose puts them:

1. `ops_pull` — refresh the ledger checkout, if there is a separate one to
   refresh (classified once at startup, and said once there, rather than warned
   about every tick forever).
2. `tp task scrub` — exit 3 re-emits the offending paths.
3. `reclaim_orphaned_claims` — release clean orphans, park committed ones.
4. `run_pre_tick_hooks` (§7).
5. **`reconcile_trunk`** — before the gate, because integration spends no tokens.
6. `compute_plan`.
7. **`reclaim_done_targets`** — also before the gate, so a disk-pressure pause can
   self-heal as finished phases free their build output. Note this pass only
   considers a `DONE` unit whose worktree contains a literal `target/` directory,
   which is a hardcoded Cargo assumption: on a non-Rust project a configured
   `TASKPUMP_RECLAIM_CMD` never runs, and the "unconfigured" startup line does not
   print either, because the key *is* configured. A silent no-op.
8. `feed_gate` — a pause writes `paused` and **returns**, which means a gated tick
   neither increments nor resets the deadlock counter.
9. Launch `PLAN_LAUNCH` up to the cap, staggered; then `PLAN_RESUME` up to the
   same cap, under the same gate — genuinely-eligible work is always preferred
   over resuming a partially-done task, and a resume never fires while the pump
   is throttled.
10. Update the deadlock counter, write `running`.

The counter in step 10 reads the **outcome** of steps 9, not the plan from step
6: a tick that ends with no live agent and nothing started is an idle tick,
whatever the cause — an empty frontier, a pool cap of 0, N launches that all
failed, or N units refused before any launch was attempted. It records which,
and `stall_exit` quotes that back:

- `nothing launchable, nothing resumable`
- `the pool cap is 0, so N launchable unit(s) were never started`
- `every launch attempt failed — N unit(s) planned, none started; last: <the
  last refusal>` — at least one launch was attempted, and all of them failed
- `N unit(s) planned, none started; last: <the last refusal>` — nothing started
  and no launch was attempted, which is what a resume the budget retired looks
  like: it escalates to `needs-review` and pages without reaching the launcher

"Nothing launchable" said over a plan that was full is a page pointing at the
wrong thing, and so is "every launch attempt failed" over a tick that attempted
none. Anything that starts, and any live agent, resets the counter to zero.

Then, outside the tick: `is_drained` (three questions — no open task, no
in-flight claim, no live agent) breaks the loop; otherwise `STALL_TICKS >=
STALL_EXIT_TICKS` calls `stall_exit`; otherwise sleep. The sleep is backgrounded
and `wait`ed rather than run in the foreground, so a `systemctl stop` does not
have to wait out the rest of the tick before the `TERM` trap can stamp the file.

---

### 13. Notifications

Six messages go through `pump_notify`, which logs the message first and then
delivers it. Nothing else notifies.

| Message | When |
|---|---|
| the pre-tick hooks' combined output | when that output *changes* (§7) |
| `<unit> STALLED on <id> — <verdict>, no progress across N auto-resumes. Marked needs-review; …` | the resume budget is spent |
| `auto/trunk: quarantined <unit> (<reason>); <lead> left done — reconcile the merge by hand` | a failed trunk merge whose lead task is already `done` |
| `auto/trunk: quarantined <unit> (<reason>); <lead> flagged needs-review` | a failed trunk merge whose lead task is not |
| `<phases> STALLED after N idle ticks — … : <why the ticks were idle>. In flight: <claims>. M task(s) need human review …` | immediately before exit 3 |
| `<phases> drained: 0 open should remain (N open), M task(s) need human review …` | immediately before exit 0 |

`TASKPUMP_NOTIFY_CMD` receives the message **on stdin**, not as an argument.
Unset, the pump falls back to `notify-send "<prog name>" "<message>"` on argv when
that binary exists, and to the log line alone otherwise. The asymmetry is
deliberate and it is the mistake the code's own warnings exist to catch: a
plausible pin like `notify-send -u low` wants a summary argument, never reads
stdin, and fails on every notice.

A configured command that fails is reported — with its exit status, the fact that
nothing was delivered, and its first *speaking* line of stderr, labelled as
exactly that rather than offered as the cause. Four distinct warnings, because
four distinct things can be true: the program is not on `PATH` (asked *before*
the run, so the shell's own `command not found` is never quoted back as though
the notifier had said it); it failed and said something; it failed and wrote
only blank or control bytes, so there is nothing quotable — reported as that,
never as silence; and it failed and said nothing at all (only then does the pump
mention the stdin contract, and it mentions it as something to check rather than
as the diagnosis). The `notify-send`
fallback stays quiet: nobody configured it, a headless host has no session bus,
and the log line is still the record.

---

### 14. Test seams

These change real scheduling and integration decisions, and four of them are
un-prefixed names that any environment could collide with. They are listed here
so that a run behaving strangely has somewhere to look:

| Name | Effect |
|---|---|
| `TASKPUMP_PUMP_NO_LAUNCH=1` | Ticks through gates, plan and state without materialising worktrees or containers. Also skips the image build, the `~/.claude`/image/runner prerequisites, the liveness probe line, `ensure_trunk` and the disk watchdog. |
| `TASKPUMP_PUMP_INTEGRATE_DRYRUN=1` | Integration rehearsal: logs `would integrate` / `would quarantine` and touches no git. Its build gate assumes green when no `TASKPUMP_BUILD_GATE` is configured, while the real path runs the default gate — so a rehearsal can print `would integrate` for a merge the real run quarantines. |
| `STUB_INTEGRATED` | Space-separated list of units to treat as integrated; overrides the real ancestry check in the launch gate at **both** grains. |
| `STUB_INTEGRATE_NOBRANCH`, `STUB_INTEGRATE_ANCESTOR`, `STUB_INTEGRATE_CONFLICT` | Drive the dry-run integrator's branch-absent / already-integrated / conflict paths. |
| `TASKPUMP_PUMP_DEBUG=1` | Turns on the per-tick skip traces (`skip integrate …`), which are otherwise silent so reconcile does not spam the log every `TICK` seconds. |
