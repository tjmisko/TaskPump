# Pump Mechanisms

The pump is a supervisor that keeps a pool of agents working a task DAG for days
without a human in the loop. This document specifies the five mechanisms that
make that survivable, and why each one is shaped the way it is.

Every mechanism here was rebuilt at least once after an unattended run failed in
a way that looked like success. That history is the point: each section states
the rule, then the incident that produced it. A reimplementation that keeps the
rules and discards the reasons will rediscover the incidents.

The pump implements these against the ledger described in
[LEDGER-CONTRACT.md](LEDGER-CONTRACT.md). They are separable — a different
supervisor, in a different language, can implement all five against the same
ledger — which is exactly what this document is for.

---

## The shape of a tick

The pump is a loop. Each tick:

1. **Preflight** — refresh the ledger checkout, `scrub` stale claims, run any
   configured pre-tick hooks. A scrub exiting 3 names task files invisible to the
   frontier (see the contract §10) rather than reporting a generic failure.
2. **Observe** — ask the runner which agents are alive (mechanism 2).
3. **Plan** — recompute the eligible frontier from the ledger, and classify each
   phase in range as `RUNNING`, `LAUNCH`, `RESUME`, `WAITING`, or `DONE`
   (mechanisms 1 and 4).
4. **Gate** — ask each gate whether feeding is permitted (mechanism 3).
5. **Act** — launch or resume up to the pool cap, staggered.
6. **Settle** — persist supervisor state, reclaim disk from finished workspaces,
   and decide whether the run has drained, deadlocked, or should tick again.

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

The pump dispatches at **phase grain**. Each phase with eligible work gets one
workspace, whose agent drains that phase's sub-tree serially — asking the ledger
for the next task in its own phase, doing it, asking again. Phases fan out in
parallel; cross-phase dependencies gate at the phase level. So there are two
schedulers: the pump across phases, and the in-context loop within one.

Phase grain is a deliberate compromise. Task grain would maximize parallelism and
spend most of its time paying container startup for a five-minute task; chain
grain would minimize startup and serialize too much. Phase is the unit that
matches how work is actually authored.

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

- **A phase with a live agent is never launched again.** No double-dispatch, no
  two agents racing on one branch.
- **A phase whose agent is gone is available again**, regardless of what the
  ledger says. A claim left `in_progress` by a dead process is not a live claim.

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
   ([RUNNERS.md §1.3](RUNNERS.md#13-list)), the pump asks it once per tick and
   uses its answer. Probed once at startup and cached for the run.
2. **Scrape agent names.** Otherwise — a v1 runner with no `list` verb — the
   pump enumerates processes whose name carries the configured agent prefix,
   exactly as before.

Asking matters because scraping only works for a *container* runner. A runner
that starts a plain process, a VM, or a remote executor has agents no
`docker ps` will ever show, so the supervisor would read every one of them as
dead and launch over them. Delegation is what makes those runners usable at all.

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

The other half of the fix: when nothing is live, launchable, *or* resumable for
N consecutive ticks, the pump **notifies and exits 3** rather than idling green.
`systemd`'s `Restart=on-failure` catches it; a drained pump exits 0 and is
deliberately not restarted.

N is greater than one so a container dying mid-tick cannot trip it.

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
| 1. Frontier | Eligibility is `open ∧ blockers all done`, recomputed per query. `--count` (all open in range) vs `--count-eligible` (frontier size) are the drain test and the stall test respectively. |
| 2. Liveness | Never derived from task status. An orphan with no commits is released to `open`; an orphan with commits is not. |
| 3. Gates | Exit 10 = pause launching. Exit 0 = feed. Anything else = fail open with a warning. Never kills a running agent. |
| 4. Resume | Bounded by a no-progress counter in the ledger, reset by branch-head movement, exhausting to `needs-review`. Deadlock exits 3; drained exits 0. |
| 5. Tripwires | Turn budget → `needs-review`; failure streak → `stuck`; staleness → `needs-review`. All reopenable. |
| 6. Resolution | Caller's workspace, explicit configuration wins, resolution is inspectable. |

The exit codes are frozen; see [LEDGER-CONTRACT.md §10](LEDGER-CONTRACT.md#10-the-exit-code-protocol--frozen).
