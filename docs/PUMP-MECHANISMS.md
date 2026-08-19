# Pump Mechanisms

The pump is a supervisor that keeps a pool of agents working a task DAG for days
without a human in the loop. This document specifies the five mechanisms that
make that survivable (§1–§5), and why each one is shaped the way it is. Two
sections follow that are not mechanisms and say so: §6 is the resolution rule
all five stand on, and §7 is the contract a re-implementer can rely on.

Every mechanism here was rebuilt at least once after an unattended run failed in
a way that looked like success. That history is the point: each section states
the rule, then the incident that produced it. A reimplementation that keeps the
rules and discards the reasons will rediscover the incidents.

The pump implements these against the ledger described in
[LEDGER-CONTRACT.md](LEDGER-CONTRACT.md). They are separable — a different
supervisor, in a different language, can implement all five against the same
ledger — which is exactly what this document is for. (§7's table carries six
rows: the five mechanisms and the resolution rule, because a consumer has to
honour that one too.)

---

## The shape of a tick

The pump is a loop. Each tick, in this order:

1. **Refresh the ledger** — pull the ledger checkout, so a task file another
   machine pushed is planned this tick. Skipped, once and loudly at startup, for
   a ledger that has nothing to sync.
2. **Scrub** — fire the heartbeat tripwires (mechanism 5) and check ledger
   integrity. A scrub exiting 3 names the task files invisible to the frontier
   (see the contract §10) rather than reporting a generic failure.
3. **Reclaim orphaned claims** — release what a dead agent left behind, before
   anything plans around it (mechanism 2).
4. **Pre-tick hooks** — the replaceable housekeeping seam
   ([GATES.md §5](GATES.md#5-the-third-seam--pre-tick-hooks)).
5. **Integrate** — merge every quiescent, not-yet-integrated unit branch into
   the integration trunk. A no-op unless `--integration-trunk` is on.
6. **Plan** — recompute the eligible frontier from the ledger, and classify each
   dispatch unit in range — a phase, or a task at `--grain task` — as `RUNNING`,
   `LAUNCH`, `RESUME`, `WAITING`, or `DONE` (mechanisms 1 and 4).
7. **Reclaim disk** — run the configured reclaim command over the workspaces
   the plan just filed as `DONE`.
8. **Gate** — ask each gate whether feeding is permitted (mechanism 3). A gate
   that pauses ends the tick here: nothing is launched or resumed, the state
   file is stamped `paused` with the gate's reason, and the deadlock counter
   does **not** advance, so a gated run can never page as deadlocked.
9. **Act** — launch, then resume, up to the pool cap, staggered.
10. **Settle** — persist supervisor state, and decide whether the run has
    drained, deadlocked, or should tick again.

**Steps 5 and 7 sit above the gate deliberately, and that is the placement a
reimplementation gets wrong.** A gate pauses *launching*; it does not pause the
tick. Merging a finished branch and deleting a finished workspace's build output
are local compute that spend no API budget, so a run throttled on plan usage
keeps propagating finished work while it waits. And — the case that actually
bites — **a run paused on the disk gate can free the disk that is pausing it.**
File the reclaim under "settle", below the gate, and a low-disk pause becomes a
low-disk stall: the pass that would have bought space back is the pass the
pause skips, so the condition that stopped the run is the condition the run can
no longer clear.

**And a step that is not there: there is no "observe".** Nothing asks the runner
once per tick and hands the answer down. Each pass that needs to know whether an
agent is alive asks at the moment it asks — the orphan reclaim, the plan (once
per unit), the pool count, the drain test, and every state-file write, which
carries a live count of its own — so the call count grows with the range: against a stub runner, one `--once` tick issued seven `list` invocations
for a one-phase range, eight for two phases and ten for four. Only the
*capability* probe ("does this runner answer `list` at all?") is cached, once
per process. Two obligations fall out of that, both on the runner: `list` is on
the hot path of a loop that runs for days, so it must be **cheap**; and it is
called from passes that act irreversibly on its answer, so it must be **exact**
([RUNNERS.md §1.3](RUNNERS.md#13-list)).

The plan is printable without acting on it (`--dry-run`), and a single tick is
runnable in isolation (`--once`). Both matter more than they look: a supervisor
you cannot ask "what would you do right now, and why" is a supervisor you cannot
debug at 3am on day four of a run.

---

## 1. Frontier scheduling from declared blockers

**The queue is not a queue.** It is the eligible frontier, recomputed from the
ledger every tick: `status: open` and every blocker `done`. There is no manifest,
no roster, no list of what to run maintained beside the tasks.

The consequence is that **newly-unblocked work enters automatically**. When a
task completes, everything it was blocking becomes eligible on the next tick and
gets picked up without anyone relaunching anything. "Keep acquiring" is not a
feature bolted on top of a queue; it is what you get for free when the queue is
derived rather than stored.

**A `WAITING` unit says why, and the why is derived too.** The plan used to
assert a single reason — "cross-phase blockers pending" — for every phase with
open work and an empty frontier, which sent operators hunting for an upstream
dependency that a phase gated on its own review task never had. The reason is
now read back out of the ledger: the review awaiting a verdict (nothing
dispatches a review task), the upstream task and its status, the unfinished
in-phase sibling, the branch holding a claim, a blocker with no task file — and
when none of those explains it, that none of them does. A reason gets acted on,
so an invented one costs the same afternoon a wrong answer would. The claim
clause is derived at every open count, including zero: an `in_progress` task is
not `open`, so the frontier cannot report one at all, and a phase-grain plan that
named a stranded claim only when it was the phase's last work answered "who is
holding this phase" differently depending on what else happened to be open
(issues #46/#48).

The pump dispatches at **phase grain**. Each phase with eligible work gets one
workspace, whose agent drains that phase's sub-tree serially — asking the ledger
for the next task in its own phase, doing it, asking again. Phases fan out in
parallel; cross-phase dependencies gate at the phase level. So there are two
schedulers: the pump across phases, and the in-context loop within one.

Phase grain is a deliberate compromise, and it is the **default**. Task grain
maximizes parallelism and can spend most of its time paying container startup for
a five-minute task; chain grain would minimize startup and serialize too much.
Phase is the unit that matches how work is actually authored.

**`--grain task` when the compromise stops paying.** Reach for it when a phase
holds long, genuinely independent siblings, or when the range is a single phase —
the cases where jobs headroom goes unused no matter the cap, because parallelism
only exists *across* phases. It dispatches each eligible task as its own unit: one
worktree, one branch, one agent name. Every mechanism in this document then
applies per task rather than per phase — liveness, the orphan reclaim, the resume
budget, the gates, the pool cap, the deadlock exit — because a *unit* is what the
supervisor was always really scheduling. The two things phase grain got for free
have to be paid for explicitly:

- **Mutual exclusion.** One branch per phase meant siblings touching the same
  files never collided. At task grain, two tasks may run concurrently only when
  their declared `files:` sets are **disjoint**; an overlap is a hold, exactly
  like a pending blocker, and the plan names both the task and the path. An
  **empty `files:` is exclusive**: an undeclared footprint means *unknown*, and
  scheduling unknown as "touches nothing" is the silent wrong answer this whole
  document is about, so such a task runs alone. That makes `files:` load-bearing
  rather than decorative.
- **Accumulated context.** The phase agent carried what it learned from earlier
  tasks in the phase. A task agent does not, so it gets a different brief: claim
  this one task, do it, finish it, exit — and explicitly **do not run `next`**,
  because at this grain acquisition is the pump's and `next` would hand it a
  sibling another container is already working.

Everything the tick will **start** holds its footprint, and holds it against
every candidate — the ones planned before it as much as the ones after. A tick
dispatches running, resumed and freshly-launched units together, so admitting
each class in its own full pass over the range is not a tidiness preference: an
inline admission that appended to the holder set as it went bound only the later
candidates, and a stranded task planned `RESUME` beside an eligible sibling with
the identical `files:` produced a plan reading "0 waiting" while the tick started
two agents on one file.

**What the rule does not catch.** Naming its blind spots is the point of stating
it precisely:

- **An agent that edits outside its declared set.** `files:` is a *declaration*,
  not a sandbox — nothing stops an agent from touching a path it never listed,
  and if it does, the scheduler's disjointness proof was about the wrong sets.
  The task brief says so in as many words; the enforcement is the merge, which
  is where such an edit finally surfaces as a conflict.
- **Footprints outside the range.** The holder set is built only from
  `tasks_in_range`. An agent this pump did not launch — a human in a worktree,
  another supervisor, a task in a phase outside `--phases` — has a footprint
  nobody holds, so a candidate can be scheduled straight onto it.
- **Path granularity.** Overlap is compared as literal repo-relative strings.
  Two tasks that declare a directory and a file beneath it, or the same file by
  two spellings, read as disjoint.

**Switching grain mid-flight strands the other grain's claim.** A claim is owned
by the branch that took it (`claimed_by`), and the branch a claim *would* carry
is derived from the grain: `feat/g3` at phase grain, `feat/g3.4` at task grain.
So a run restarted at the other grain does not recognize the in-flight claim as
its own — the reclaim and resume passes both refuse to touch a branch this run's
naming scheme does not own, deliberately, since that is the same test that keeps
them off a human's branch. The stranded task shows up every tick at whichever
grain is running — `WAITING G3.4 (claimed by feat/g3, no live container)` at task
grain, `WAITING G3 (… in flight: G3.4 (claimed by feat/g3))` at phase grain,
whether or not other open work sits in the phase beside it — and the run
eventually reaches the deadlock exit (3), with or without that other work. The
drain test asks about in-flight claims as well as `open` tasks precisely so the
last claim in a range cannot be drained over: an `in_progress` task is committed,
unfinished work, and calling that finished is the same false-DRAINED the resume
path exists to prevent (issue #48). Finish or `release` an in-flight claim
before changing grain.

The cost the operator accepts is N branches instead of one, and therefore N
merges. The opt-in integration trunk absorbs that: it composes with task grain,
merging each quiescent task branch under the same lock and build gate — and a
merge that fails is quarantined as a *merge* failure: a task already `done` is
never flipped back to `needs-review`, because the broken thing is the merge, not
the work.

**Why derived, not stored:** a stored queue is a second copy of the dependency
graph, and the two drift. The drift is silent and always in the same direction —
the stored copy lags, so work that has become eligible is never picked up, and
the run looks busy while starving. A derived frontier cannot lag, because there
is nothing to lag behind.

---

## 2. Liveness from process state, never task status

**Whether an agent is running is a question about processes, not about the
ledger.** The pump asks the runner (`docker ps`, or whatever the configured
runner reports) which workspaces have a live agent. It never infers liveness from
`status: in_progress`.

Two rules follow, and they are the same rule from opposite sides:

- **A unit with a live agent is never launched again.** No double-dispatch, no
  two agents racing on one branch.
- **A unit whose agent is gone is available again**, regardless of what the
  ledger says. A claim left `in_progress` by a dead process is not a live claim.

Both rules are read through the agent's **name**, which is the unit's branch with
`/` replaced by `-` ([RUNNERS.md §2](RUNNERS.md#2-naming-and-identity)). That map has to
round-trip, so a run whose units cannot be named — or two units that would be
named the *same* — is refused before anything launches. A name collision is the
worst failure this stack has: liveness would answer "running" for a unit that is
not, and the pump would launch a second agent onto the first one's branch.

What happens to that abandoned claim depends on whether it produced anything:

| Orphan state | Disposition |
|---|---|
| Branch has **no commits** ahead of base | Released to `open`. Nothing is lost; a fresh agent starts clean. |
| Branch **has commits** | **Not** released — see mechanism 4. Reopening it would tell a fresh agent to redo landed work. |

**Why not task status:** status is written by a cooperating agent. A process
killed by OOM, a container that lost its network, a machine that slept — none of
them get to write anything. Any liveness signal that depends on the dying party
reporting its own death is not a liveness signal. Process state is observed from
outside and needs no cooperation.

This also makes the pump **restart-safe**: a supervisor that restarts mid-run
re-derives what is live by looking, and never disturbs an in-flight agent.

### Where the pump looks

The mechanism above is unchanged. What is pluggable is only the **source** of
that process state:

1. **Ask the runner.** If the configured runner implements `list`
   ([RUNNERS.md §1.3](RUNNERS.md#13-list)), the pump asks it and uses its
   answer — asks it *per question*, not once per tick, as the tick section
   above spells out. What is cached, once per process, is only the capability
   probe: whether this runner has the verb.
2. **Scrape agent names.** Otherwise — a v1 runner with no `list` verb — the
   pump enumerates processes whose name carries the configured agent prefix,
   exactly as before.

Asking matters because scraping only works for a *container* runner. A runner
that starts a plain process, a VM, or a remote executor has agents no
`docker ps` will ever show, so the supervisor would read every one of them as
dead and launch over them. Delegation is what makes those runners usable at all.

Which is why the capability probe reads **exit 2, and only exit 2**, as "I do
not have that verb". Every other non-zero means the runner *has* `list` and
could not answer right now, which is transient and handled per tick. Misreading
"the runtime blipped while the pump was starting" as "v1 runner" would pin the
run to the scrape for the rest of its life — and for exactly the non-container
runners of the paragraph above, the scrape finds nothing at all. The corollary
for a runner author is easy to get wrong and stated at length in
[RUNNERS.md §1.3](RUNNERS.md#13-list): **never exit 2 for a real enumeration
failure.**

**When the source goes dark**, the pump falls back to the scrape for that tick
and logs one line — liveness failing must never wedge the supervisor. But a
fallback answer is explicitly marked as not authoritative, because for a
non-container runner it is not merely stale, it is *empty*: "every agent died at
once". So the two passes that act on **absence** — reclaiming an orphaned claim
(above) and detecting a stalled phase (mechanism 4) — are skipped entirely on
such a tick. They resume next tick.

That asymmetry is the whole discipline: a wrongly-absent agent on the *launch*
path costs at most one redundant launch decision, which the next tick corrects.
On the *reclaim* path it releases every claim in the range and resumes every
running phase at once. Fail open where the cost is bounded; refuse to act where
it is not.

---

## 3. Budget-gated launching that never kills in-flight work

Before launching, the pump consults its gates. Any gate can say **pause**; none
can say **stop**.

**Gates pause *launching* only. Running agents are never killed.** This is
absolute. A gate exists because starting *new* work right now is a bad idea —
the plan's usage window is nearly spent, the credential is about to expire, the
disk is nearly full, the network is unhealthy. None of those are reasons to
destroy work already in flight, which is the most expensive thing in the system.
When the condition clears, feeding resumes automatically. Nothing is lost; the
run simply breathes.

The shipped gates are described in [GATES.md](GATES.md). The pump does not know
what any of them measure — a gate is an executable that exits 10 to pause and
prints one line of reason, and gates run in configured order.

**Gates fail open.** A gate that errors, times out, or is missing lets the run
continue with a warning. This is the counterintuitive half, and it is not
negligence: a meter that cannot be read is not evidence of a problem. If an
unreachable usage endpoint paused the pump, then every transient network blip
would wedge a multi-day run, and the failure mode of the safety mechanism would
be worse than the failure it prevents. A gate is a *governor*, not an
interlock — the sandbox is what enforces safety.

The pool cap is enforced alongside the gates, and is **live-retunable**: the cap
is read from a file each tick, so an operator can lower concurrency mid-run
without restarting the supervisor or disturbing anything already running.

### The pump starts a disk watchdog behind your back

On a real `run` — not `--once`, not `--dry-run` — with the disk gate enabled,
the pump **spawns a background `tp disk-watchdog --auto-exit`** and logs one
line saying so. It is not a gate. It writes the same pool-cap file the operator
retunes by hand, which is the second, blunter half of disk discipline: the gate
declines to launch, the watchdog drops the cap to 0 outright, and below a
second and lower threshold it *reclaims* — build output in the worktrees **and
in the primary checkout**, then a container-runtime prune — before sleeping out
a cooldown. `--auto-exit` retires it once no agents remain.

Say it plainly, because a surprise here is expensive: **starting a pump starts
a process that can delete build output you did not ask it to delete.** Two
things bound that. The reclaim skips any workspace hosting a live agent, so a
running build is never broken; and it delegates to `tp cleanup --targets`, which
does nothing at all unless `TASKPUMP_RECLAIM_CMD` is configured — so an
unconfigured consumer gets the cap drop and the prune and no deletion. Setting
that key is what arms the rest. `TASKPUMP_PANIC_RECLAIM=0` keeps the prune and
drops the build-dir reclaim, and turning the disk gate off suppresses the
watchdog spawn along with the gate — **either way of turning it off**, the flag
`--no-disk-gate` or the key `TASKPUMP_DISK_GATE=0`, because the spawn is guarded
on the one switch both of them set. (The key used to be inert here: the pump
pinned that switch to `1` and read no key, so only the flag reached this
decision. It now does what it says, which means a conf carrying
`TASKPUMP_DISK_GATE=0` and expecting the watchdog to keep running loses the
watchdog — see [GATES.md §2.1](GATES.md#21-turning-a-default-gate-off-is-not-symmetric).)

The reclaim pass *inside* the tick (step 7) is the narrower of the two: it
touches only the workspaces the plan just filed as `DONE`, never the primary,
and never one with a live agent.

**Both passes carry the same trap, and it is worth knowing before you rely on
either.** Neither one asks your reclaim command what to reclaim. Each first
looks for a directory literally named `target/` and skips anything without one,
so the whole mechanism is Rust-shaped, and no configuration key overrides that
name. A project that builds into `build/`, `dist/` or `node_modules/` gets a
reclaim pass that runs every tick, logs nothing, and frees nothing — with
`TASKPUMP_RECLAIM_CMD` set and looking configured. The disk discipline you think
you have is the pool-cap drop and the runtime prune; the build-output half is
inert.

---

## 4. Resume-with-context, bounded by a no-progress budget

This is the mechanism that exists entirely because of one incident, so the
incident comes first.

### The 563-tick idle

A pump ran for **seven hours, 563 ticks, launching nothing**, with five open
tasks waiting and `systemd` reporting `active (running)` the entire time.

The chain:

1. An agent claimed a task, committed 25 commits of real work, and exited
   cleanly — reporting "frontier drained" — with the task still `in_progress`
   and unfinished.
2. The orphan-reclaim path saw commits on the branch and correctly refused to
   reopen it. Releasing it would have sent a fresh agent to redo 25 commits.
3. `ready` surfaces only `status: open` tasks, so the claimed task was invisible
   to the frontier.
4. Everything blocked behind it was therefore ineligible.
5. The drain test asks "are there open tasks?" — and there were. So the pump was
   not drained. It was not deadlocked either, as far as it could tell. It ticked,
   found nothing launchable, and slept. Forever.

Every individual decision was correct. The system had no state for "there is work
here, and no path to it".

Note what the agent's own exit reveals: it ran `next`, got `null` because its
task was claimed to its own branch and thus not `open`, and read that as *the
work is done*. The stall's cause and the agent's misreading are the same fact
about the ledger, seen from two sides.

### The mechanism

The pump **resumes** such a claim rather than reopening it. It keeps the claim,
relaunches the phase pointed at that specific task, and writes a **resume note**
into the workspace — a preamble the agent reads before its kickoff brief, which:

- names the task and says plainly that a previous session died mid-work;
- **tells the agent not to run `next`** — the task is claimed, `next` returns
  nothing, and reading that as "drained" is the stall reproducing itself — and
  tells it to read the task file directly instead;
- lists **what is already committed on the branch**, plus uncommitted state. A
  resumed task's entire context is its commits; a note that only reports dirty
  files tells the agent nothing about the 25 commits it must not redo;
- authorizes exactly three endings: **finish** it, **split** it (complete the
  done part, file the remainder as a new task), or **block** it. All three
  release whatever is waiting behind it. Leaving it claimed and unfinished does
  not — that is what caused the stall.

### The bound

Resuming forever is the same trap with more motion. Each resume is bounded by a
**no-progress budget**, and *no-progress* is measured from the **branch head**:

- The branch head moved since the last resume → real progress → **the counter
  resets**.
- The head is unchanged → **the counter increments**.
- The budget is spent → the task goes `needs-review` and the pump notifies **once**.

The counter lives in the ledger, so the budget survives a supervisor restart.

Two properties matter. First, a task that legitimately needs many sessions is
never escalated, because every session that commits anything resets the count —
the budget bounds *futility*, not duration. Second, the measurement needs no
cooperation from the agent: a dead agent never fires a heartbeat, so any
heartbeat-derived counter stays frozen at zero and can never bound the loop.
Reusing the heartbeat's failure counter would have been worse than useless — it
is reset by every claim, so the pump's own resume cycle would clear the tripwire
meant to stop it.

### Deadlock exit

The other half of the fix: when a tick ends with **nothing live and nothing
started**, N consecutive times, the pump **notifies and exits 3** rather than
idling green. `systemd`'s `Restart=on-failure` catches it; a drained pump exits 0
and is deliberately not restarted.

N is greater than one so a container dying mid-tick cannot trip it.

**The counter reads the outcome of the tick, not the plan**, and that distinction
is the whole mechanism. It first asked whether anything was *launchable* —
whether `PLAN_LAUNCH` and `PLAN_RESUME` were empty — which is a question about
intent rather than about progress, and it answers "not deadlocked" in exactly the
two cases where the supervisor is most stuck:

- **a pool cap of 0.** Every candidate is refused by the cap, the plan stays
  full, and the counter reset every tick. The run wrote `status: running`
  indefinitely over work it would never start.
- **a launch that fails every time.** `launch_unit` returns 1 with a warning on
  three paths — a worktree a global `core.excludesFile` still ignores, a
  worktree that conflicts with the integration trunk, and a runner that will not
  start — and none of them removes the unit from the plan. The pump warned once
  per tick, forever, and stayed green. The gitignored-worktree arm is not
  hypothetical: that exact condition is what made the 2026-08-13 canary launch
  nothing.

Both are the same failure the detector exists to catch, arriving through a door
it was not watching. Asking "did this tick start anything?" catches all three
doors with one question, because a tick that started nothing and has nothing
running made no progress by definition — while a tick that launched something,
or that has a live agent, is progress whatever the plan says.

The page has to name which one it was. `stall_exit` records the cause of the
idle ticks and quotes it: `the pool cap is 0, so 4 launchable unit(s) were never
started`, or `every launch attempt failed — 4 unit(s) planned, none started;
last: <the last refusal>`, or plain `nothing launchable, nothing resumable` when
the frontier really was empty. The three demand different repairs, and
"nothing launchable" said over a plan that was full sends the operator to look
for missing tasks that are all right there.

A range with **zero open tasks** can reach this exit too, and must: the drain
test asks about in-flight claims as well as open tasks, so a claim nobody is
driving keeps the range undrained until a human finishes or releases it. The
stall page and the state file both name the claims themselves — id and claiming
branch, the first five and a count of the rest, identically in both channels —
because `open_tasks: 0` beside `status: stalled` otherwise argues against the
page it explains, and finishing or releasing a claim is a per-claim act that a
tally cannot be performed on.

**The general lesson, which outlives this pump:** an autonomous supervisor must
be able to distinguish *drained* from *deadlocked*, and must be loud about the
second. A system that cannot tell "nothing to do" from "nothing I can do" will
always resolve the ambiguity as health, because health is the quiet answer.

---

## 5. Heartbeat tripwires

Inside a single agent's run, two counters bound how long it can go wrong before a
human is asked to look. Both are enforced by `scrub` and specified in
[LEDGER-CONTRACT.md §5.10](LEDGER-CONTRACT.md#510-scrub--the-tripwires):

- **Turn budget** — set at claim, decremented per cycle. At zero the task becomes
  `needs-review`. Bounds *cost*: an agent looping productively-but-forever still
  stops.
- **Consecutive failures** — cycles that produced no attributable commit. At the
  limit the task becomes `stuck`. Bounds *futility*: an agent thrashing without
  landing anything stops sooner than its turn budget would allow.
- **Heartbeat staleness** — a third, time-based catch: a claim whose last beat
  (or claim time, if it never beat) is older than the staleness window is
  reclaimed to `needs-review`. This is the one that reaches an *alive but hung*
  agent, which the liveness check of mechanism 2 cannot see and which will never
  fire another heartbeat.

Both counters depend on the agent **cooperating** — an agent that dies without
firing its end-of-cycle heartbeat advances neither. That is precisely why
mechanism 4's budget measures the branch head instead, and why it is a third,
independent safeguard rather than a reuse of these two. The three overlap
deliberately: cooperative-and-wrong (tripwires), dead (liveness reclaim), and
dead-with-work-committed (resume budget).

`needs-review` and `stuck` both require a human, and both are reopenable. A
tripwire that produced an unrecoverable state would just move the stall.

---

## 6. Resolution starts from the caller's workspace

Not a scheduling mechanism, but a rule every one of the above depends on, and the
subject of its own incident.

**Every path a tool resolves — the ledger, the config, the code repository — is
derived from `$PWD`'s git worktree, never from where the tool itself lives.**

The incident: each worktree carried its own copy of the CLI *and* its own ledger
checkout, but the CLI derived its root from the script's location. Running the
primary checkout's copy while standing in a worktree wrote the claim into the
**primary's** ledger. The work happened in the worktree; the record of it landed
somewhere else. The worktree's ledger never learned of the claim, and the
primary's drifted 46 commits ahead of anything it described.

It went unnoticed because both invocations are spelled the same way and both
succeed.

The root cause of the blind spot is worth more than the bug: **the
default-resolution path had zero test coverage.** Every existing test set the
ledger path explicitly, so the one code path that guesses was the one path
nothing exercised. When you configure a fixture, you stop testing resolution.

Consequences a reimplementation must preserve:

- Explicit configuration (environment, config file) always wins.
- The fallback is the caller's workspace, not the tool's.
- There is a verb (`tp task resolve`) that prints which ledger an invocation
  picked, because "which ledger am I about to touch" must be answerable without
  re-deriving the rules by hand.
- The default path is tested with the environment **unset**.

---

## 7. What a consumer may rely on

For a supervisor re-implementing these mechanisms against the same ledger:

| Mechanism | Observable contract |
|---|---|
| 1. Frontier | Eligibility is `open ∧ blockers all done`, recomputed per query. `--count` (all open in range) vs `--count-eligible` (frontier size) answer the drain test and the stall test respectively — with the drain test additionally requiring no `in_progress` task in range, since a claim is not `open` and unfinished work must never read as finished. At task grain, concurrency additionally requires disjoint declared `files:`; an empty list is exclusive. |
| 2. Liveness | Never derived from task status. An orphan with no commits is released to `open`; an orphan with commits is not. |
| 3. Gates | Exit 10 = pause launching. Exit 0 = feed. Anything else = fail open with a warning. Never kills a running agent. |
| 4. Resume | Bounded by a no-progress counter in the ledger, reset by branch-head movement, exhausting to `needs-review`. Deadlock exits 3; drained exits 0. |
| 5. Tripwires | Turn budget → `needs-review`; failure streak → `stuck`; staleness → `needs-review`. All reopenable. |
| 6. Resolution | Caller's workspace, explicit configuration wins, resolution is inspectable. |

The exit codes are frozen; see
[LEDGER-CONTRACT.md §10](LEDGER-CONTRACT.md#10-the-exit-code-protocol--frozen)
— and read §10.1 with it before keying on `tp pump`'s exit 0, which today does
**not** mean drained.
