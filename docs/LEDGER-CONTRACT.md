# The Ledger Contract

This is TaskPump's compatibility surface. Everything described here — the file
format, the frontmatter schema, the status vocabulary, the state machine, the
eligibility predicate, the id grammar, and the exit codes — is what a consumer is
allowed to depend on. Anything not described here is an implementation detail of
whichever tool happens to implement it today, and may change without notice.

The audience is threefold: someone writing a task file by hand, someone writing a
tool that reads the ledger, and someone re-implementing the mechanisms in another
language. The third case is why this document exists in the shape it does — see
[PUMP-MECHANISMS.md](PUMP-MECHANISMS.md) for the supervisor half of the same
promise.

---

## 1. Versioning

TaskPump versions this contract with semver, tracked in `VERSION`.

**A MAJOR bump is required to change any of:**

- the frontmatter schema — removing a field, renaming one, or changing the type
  or meaning of an existing one;
- the status vocabulary, or any transition in the state machine of §5;
- the eligibility predicate of §6;
- the id grammar contract of §7 (the shape a pattern is allowed to have, not the
  pattern itself, which is configuration);
- any exit code in §10.

**A MINOR bump covers additions** — a new verb, a new gate, a new configuration
key, a new optional frontmatter field with a defined default, a new output format
behind a flag. Existing callers keep working.

**A PATCH bump is everything else**: bug fixes, diagnostics, performance,
documentation.

The practical test: if a consumer that was correct against version *N* could
become incorrect against version *N+1* without changing a line of its own code,
that is a MAJOR change.

---

## 2. What a ledger is

A ledger is **a directory of markdown files, one file per task**, tracked in git.
There is no database, no index, and no lock file that outlives a process. The
directory is the whole state.

```
tasks/
  T1.md
  T2.1.md
  T2.2.md
```

The file's basename (minus the extension) is the task id, and the frontmatter's
`id` field repeats it. Both must agree; the tools resolve a task to a path by
name (`<tasks-dir>/<id>.md`) and read the id back out of the frontmatter, so a
file whose name and `id` disagree is reachable by one path and invisible to the
other. Only files directly in the tasks directory are considered — the walk is
one level deep, not recursive.

This shape is deliberate. It makes task state diffable, greppable, reviewable in
a pull request, and mergeable by git; it survives every tool in this repository
being deleted; and it means the history of a task is `git log -- tasks/T2.1.md`.

### 2.1 File format

Each file is YAML frontmatter delimited by `---`, followed by a markdown body.

```markdown
---
id: T2.1
phase: T2
title: Parse the config file
status: open
claimed_by: null
claimed_at: null
turn_budget_remaining: null
consecutive_failed_iterations: 0
blockers:
  - T1
completed_by_commits: []
milestone: null
files:
  - src/config.rs
last_heartbeat_head_sha: null
completed_at: null
goal: The daemon reads its settings from disk instead of hardcoded defaults.
last_heartbeat_ts: null
blocked_at: null
blocked_reason: null
resume_attempts: 0
resume_head_sha: null
---

# T2.1 — Parse the config file

## Spec

...

## Scope

...

## Acceptance

...
```

**The frontmatter is machine-owned. The body is human-owned.** That division is
the single most important rule in this document; §8 states it precisely.

The body's `## Spec` / `## Scope` / `## Acceptance` headings are what
`tp task create` scaffolds and what agents are pointed at, but they are a
convention, not a contract — no tool parses them. Verbs that record a reason
(`block`, `release`, `reopen`, `needs-review`, `complete`, `defer`, `undefer`)
**append** a timestamped section to the end of the body. They never rewrite what
is already there.

---

## 3. Frontmatter schema

Every field below is written by `tp task create`, except the **eight** marked
*(verb-added)*, which appear the first time a verb needs them. A reader must
treat an absent field as its documented default; a writer should emit the full
set.

The eight are `wiring_deferred` and `wiring_deferred_note` (Completion),
`scrub_reason` (Supervision), and all five of the Review block. `create` emits
the other twenty unconditionally, in the order §2.1 shows, and emits none of
these — so a file carrying none of the eight is a well-formed task, not an
incomplete one, and `fsck` says so (§11.1).

### Identity

| Field | Type | Semantics |
|---|---|---|
| `id` | string, required | The task's identifier. Must match the configured id pattern (§7) and equal the filename stem. Immutable — there is no rename verb; the id is how every other task refers to this one. |
| `phase` | string | The task's phase, derived from `id` at creation (§7.2) unless `--phase` overrides. The pump's unit of dispatch. |
| `title` | string, required | One line naming the work. Set at creation, editable with `tp task title --set`. |
| `goal` | string \| null | One sentence stating the intended **outcome** — what is true when this is done. Distinct from the acceptance criteria in the body: the north star, not the checklist. Surfaced at hand-off, so an agent reads it before anything else. Default `null`. |
| `milestone` | string \| null | Free-form grouping label above the phase. Not interpreted by any tool. Default `null`. |

### Scheduling

| Field | Type | Semantics |
|---|---|---|
| `status` | enum, required | One of the six values in §4. |
| `blockers` | list of task ids | Tasks that must reach `done` before this one is eligible (§6). Validated on write: each id must exist, and a task may not block itself. Default `[]`. |
| `files` | list of paths | Repo-relative paths this task is expected to touch. Default `[]`. **Two consumers read it, and an empty list means the opposite thing to each — see below.** |

`files:` has two readers, and a writer has to know which one it is writing for:

| Consumer | What it does with `files` | What an **empty** list means |
|---|---|---|
| The heartbeat productivity check (§5.3) | Attributes commits to the task to decide whether a heartbeat cycle was productive. | **Advisory, permissive** — any commit counts. |
| A supervisor scheduling at **task grain** (`tp pump --grain task`) | Two tasks may run concurrently only when their `files:` sets are disjoint; an overlap is a hold. | **Load-bearing, exclusive** — an undeclared footprint is *unknown*, and scheduling unknown as "touches nothing" would put two agents on one file while reporting a clean plan. Such a task runs alone. |

Both readings are deliberate. The productivity check is looking backwards at
work that already happened, where guessing wrong costs a false stall warning;
the scheduler is looking forwards at work about to start concurrently, where
guessing wrong costs two agents on one file. Neither reader is authoritative
over the other, and a task dispatched at task grain should declare its footprint
rather than rely on either default.

### Claim

| Field | Type | Semantics |
|---|---|---|
| `claimed_by` | string \| null | The branch holding the claim. Not an agent identity: a branch is the thing that owns work, and it survives the agent that made it. Default `null`. |
| `claimed_at` | ISO-8601 UTC \| null | When the claim was taken. Fallback input to the staleness tripwire when the task has never beaten. Default `null`. |
| `turn_budget_remaining` | integer \| null | Turns left before the budget tripwire fires. Set by `claim --turns`, decremented by `heartbeat --end`. `null` means "never claimed with a budget" and is treated as a small positive fallback by `scrub`, never as zero. Default `null`. |
| `consecutive_failed_iterations` | integer | Heartbeat cycles in a row that produced no attributable commit. Reset to 0 by a productive heartbeat, by `claim`, and by `reopen` from `needs-review`/`stuck`. Default `0`. |
| `last_heartbeat_head_sha` | sha \| null | The code repo's HEAD at `heartbeat --start`, so `--end` can diff against it. Cleared to `null` at the end of every cycle — it is a within-cycle marker, not a history. Default `null`. |
| `last_heartbeat_ts` | ISO-8601 UTC \| null | Wall-clock liveness stamp, written by both heartbeat modes. Input to the staleness tripwire. Deliberately separate from `last_heartbeat_head_sha`, which is cleared each cycle. Default `null`. |

### Completion

| Field | Type | Semantics |
|---|---|---|
| `completed_at` | ISO-8601 UTC \| null | When `complete` ran. Cleared by `reopen`. Default `null`. |
| `completed_by_commits` | list of sha strings | The commits that delivered the work, as passed to `complete --commits`. Cleared by `reopen`, which preserves the prior list in the body note. Default `[]`. |
| `wiring_deferred` *(verb-added)* | boolean | True when the task shipped a primitive whose first real (non-test) caller was deliberately left for a follow-up. Set by `defer` or `complete --defer-wiring`, cleared by `undefer` and by `reopen` from `done`. Absent means false. |
| `wiring_deferred_note` *(verb-added)* | string \| null | What wiring was deferred and why. Collected by `tp task deferred`. |

### Supervision

| Field | Type | Semantics |
|---|---|---|
| `resume_attempts` | integer | Consecutive **no-progress** auto-resumes of a stalled claim. Owned exclusively by `resume-attempt` (§5.9). Default `0`. |
| `resume_head_sha` | sha \| null | The branch head at the last resume. The progress yardstick: a different sha next time means the branch moved, which resets the counter. Default `null`. |
| `blocked_at` | ISO-8601 UTC \| null | When `block` ran. Cleared by `reopen`. Default `null`. |
| `blocked_reason` | string \| null | Why. Cleared by `reopen`. Default `null`. |
| `scrub_reason` *(verb-added)* | string \| null | Why a task was parked in `needs-review` or `stuck` — the tripwire that fired, or the reason passed to `needs-review`. Cleared by `reopen`. |

### Review *(all verb-added)*

Written by `review` and `verdict` (§5.12); `create` never emits them. A task
carrying none of them is a plain task, and every reader must treat it that
way. All five are additive — MINOR per §1.

| Field | Type | Semantics |
|---|---|---|
| `review_of` | string | On a review task: the id of the implementation task under review. `verdict` resolves the chain through it; fsck checks that it names a real task, and never the task itself. |
| `review_role` | string | `reviewer` or `adjudicator` — no other value is valid. Presence is what makes a task a review task: `next` and the eligible walks of `ready` hide it (§6), and `heartbeat --end` stops measuring commit productivity on it (§5.3). |
| `review_prompt` | string \| null | The review lens recorded at chain creation (`review --prompt`), stored repo-relative when the file lies inside the code repo. Validated to exist when recorded; read by whatever dispatches the reviewer. |
| `review_round` | integer | On the *implementation* task: the review round in progress, 1 from chain creation. Advanced by a change-request verdict. |
| `review_max_rounds` | integer | On the *implementation* task: the round bound (`review --max-rounds`, default 3). A change-request that would need a round past it parks the task `needs-review` instead (§5.12). |

### Timestamps

All timestamps are ISO-8601 UTC to second precision, `YYYY-MM-DDTHH:MM:SSZ`.
Parsers must accept exactly that. There is no local-time form.

### Extension

A consumer may add its own frontmatter fields. TaskPump's verbs preserve unknown
keys — writes go through a YAML-aware in-place edit of named paths, never a
rewrite of the document. Namespace them (`x_myteam_*`) to stay clear of fields a
future MINOR release might add.

---

## 4. Status vocabulary

Six values. No others are valid.

| Status | Meaning | Who sets it | Eligible? |
|---|---|---|---|
| `open` | Available. The only status the frontier will surface. | `create`, `release`, `reopen`, `verdict --request-changes` (the implementation, and every member of its chain), `fsck --fix` (stamping a file that has no `status` at all) | yes, if blockers are done |
| `in_progress` | Claimed by a branch and being worked. | `claim` | no |
| `done` | Complete. Satisfies other tasks' blockers. | `complete`, `verdict --approve` (the review task), `verdict --request-changes` when the round bound is spent (the gate task — its ruling was delivered) | no |
| `blocked` | Cannot proceed: an external dependency, a missing decision, a genuine upstream gap. | `block` | no |
| `needs-review` | A human must look before an agent picks it up again. | `scrub` (budget exhausted, heartbeat stale), `needs-review`, `verdict` when the round bound is spent (the implementation), the pump's escalation path | no |
| `stuck` | Repeated unproductive cycles — the work is going nowhere on its own. | `scrub` (failure streak) | no |

**`verdict` is in three of those rows, and that is the point of it.** A single
change-request ruling moves the implementation task and re-arms every member of
its review chain; the exhaustion case moves the gate to `done` and the
implementation to `needs-review` in the same commit. An implementer reading only
this table would build a state machine whose `open` is reachable from three
verbs when it is reachable from five, and would have no writer at all for the
review flow. §5.12 is the full account; this row exists so the summary does not
contradict it.

`blocked` and `needs-review` differ in *who* can clear them. `blocked` says the
world must change: an upstream merge, a credential, an answer. `needs-review`
says a human must look at *this task* — the automation tried and could not tell
whether continuing was safe.

**Only `open` enters the frontier.** This is worth stating twice, because it is
the mechanical cause of the stall described in §5.9: a task in any other status
is invisible to `next` and `ready`, and a supervisor that reads an empty frontier
as "no work left" will exit green with work outstanding.

---

## 5. The state machine

```
                    create
                      │
                      ▼
       ┌──────────► open ◄──────────────────────┐
       │              │                         │
   release          claim                    reopen
       │              │                         │
       │              ▼                         │
       └────────  in_progress                   │
                      │                         │
        ┌─────────────┼──────────────┐          │
        │             │              │          │
    complete       block          scrub         │
        │             │          (tripwire)     │
        ▼             ▼              │          │
      done         blocked           ▼          │
        │             │      needs-review ──────┤
        └─────────────┴────────  stuck ─────────┘
                            (all four reopen)
```

Transitions not drawn are rejected with a diagnostic. In particular: you cannot
`release` a task that is not `in_progress`, cannot `claim` one that is not `open`
(or `in_progress` on the same branch), and cannot reach `open` from anywhere
except `release` or `reopen`.

### 5.1 `create <id> --title ...`
`(nothing) → open`. Refuses to overwrite an existing task. Validates the id
against the pattern, derives `phase` when not given, and validates `--blockers`
(each must exist; self-blocking is rejected). The exists-check and the write
happen under one lock, so two concurrent creates of the same id cannot both
succeed.

### 5.2 `claim <id> --branch <b> [--turns N]`
`open → in_progress`, atomically. Records `claimed_by`, `claimed_at`, the turn
budget, resets `consecutive_failed_iterations` to 0, and clears
`last_heartbeat_head_sha`.

A re-claim by the **same branch** on an already-`in_progress` task is idempotent
and refreshes the budget; a claim by a *different* branch is refused. Any other
status is refused.

### 5.3 `heartbeat <id> --start | --end`
Status-preserving. A no-op (exit 0) unless the task is `in_progress`, so it is
safe to call unconditionally at the end of an agent loop.

`--start` records the code repo's HEAD and stamps `last_heartbeat_ts`.

`--end` does three things: decrements `turn_budget_remaining` (floored at 0),
stamps `last_heartbeat_ts`, and decides whether the cycle was **productive** —
did the code repo gain a commit touching this task's `files`? With no `files`
list, any commit counts. Productive resets the failure counter; unproductive
increments it.

Attribution refuses to guess. If the touched files also match the `files` list of
some *other* `in_progress` task, the cycle is credited to neither and a warning
names the conflict. A wrong attribution is worse than none: it silently clears
the tripwire on a task nobody is working.

On a **review task** (`review_role` present, §3 "Review") `--end` decrements
the budget and stamps liveness but runs no productivity check and never moves
the failure counter: an honest reviewer commits nothing, so the commit meter
measures nothing there, and a meter that measures nothing must not drive a
tripwire. A wedged reviewer is still bounded — by budget exhaustion and by
heartbeat staleness (§5.10).

### 5.4 `complete <id> [--commits ...] [--defer-wiring "..."]`
`* → done`. Records the commits and `completed_at`, releases the claim, and
appends completion notes read from stdin when stdin is not a terminal.

Refused on a **review task** (`review_role` present, §5.12): a review closes by
rendering its verdict. Both verbs write the same `done`, but every guard that
makes the verdict mean something lives in `verdict`, so completing a gate task
would hand downstream a green light with the panel still open and no ruling
recorded anywhere.

`--defer-wiring` additionally sets `wiring_deferred`. It is the sanctioned way to
say "the primitive landed and its tests pass, but nothing calls it at runtime
yet" — visible and collectable rather than silently overstated.

### 5.5 `block <id> --reason "..."`
`* → blocked`. Releases the claim, records `blocked_at`/`blocked_reason`, appends
the reason to the body.

### 5.6 `release <id> --reason "..."`
`in_progress → open`. Relinquishes a claim without judgement — the work is
available again, no tripwire tripped, budget cleared. Requires `in_progress`.

### 5.7 `reopen <id> --reason "..."`
`blocked | done | needs-review | stuck → open`. The universal door back.

- From `blocked`: the blocker turned out to be transient.
- From `done`: the task was falsely-done. Completion markers are shed
  (`completed_at`, `completed_by_commits`, the wiring-deferred flag) and the
  prior commit list is preserved in the body note.
- From `needs-review` or `stuck`: a human has looked and decided it is workable.
  `consecutive_failed_iterations` is reset, so a task reopened from `stuck` does
  not re-trip on its next heartbeat.

All four clear `scrub_reason`, `blocked_at`, `blocked_reason`, the claim fields,
and the budget.

Reopening a task that carries a **review chain** (`review_round`, §5.12) also
re-arms that chain: every member goes back to `open` with its completion and
block markers shed, and `review_round` resets to 1. The work about to be redone
has not been reviewed, so a gate left `done` across a reopen would let the next
`complete` unblock downstream with no verdict rendered.

That `needs-review` and `stuck` are reopenable is load-bearing. Without it they
are dead ends — `release` requires `in_progress`, `claim` requires `open` —
and the only way back would be hand-editing frontmatter, which §8 forbids.

### 5.8 `needs-review <id> --reason "..."` — the quarantine setter
`* → needs-review`. Exists so supervisors have a sanctioned way to park a task
for human attention instead of writing the status field themselves.

### 5.9 `resume-attempt <id> --head <sha> [--max N]` — supervisor-only
Status-preserving; owns `resume_attempts` and `resume_head_sha`. Not for manual
use.

One locked read-modify-write answering: *may this stalled claim be resumed
again?* The counter **resets to 1 when `--head` differs** from `resume_head_sha`
(the branch moved, so the last resume accomplished something) and **increments
when it matches**. Past `--max` it clamps, prints `escalate n/max`, and exits 10;
otherwise it prints `resume n/max` and exits 0. Clamping keeps repeated
escalations idempotent — a supervisor ticking every 30 seconds does not write a
commit per tick once the budget is spent.

It deliberately does not reuse `consecutive_failed_iterations`: that counter is
driven by `heartbeat --end`, which a dead agent never fires, and is zeroed by
every `claim` — so a supervisor's own resume cycle would reset the very tripwire
meant to bound it. Progress measured from the branch head needs no cooperation
from the thing being measured. See
[PUMP-MECHANISMS.md §4](PUMP-MECHANISMS.md#4-resume-with-context-bounded-by-a-no-progress-budget).

### 5.10 `scrub` — the tripwires
The supervisory sweep. Two counters escalate a claim nobody is tending:

| Condition | Becomes | `scrub_reason` |
|---|---|---|
| `turn_budget_remaining <= 0` | `needs-review` | `turn_budget exhausted` |
| `consecutive_failed_iterations >= 3` | `stuck` | `consecutive_failed_iterations=N` |
| last beat (or claim, if it never beat) older than the staleness window | `needs-review` | `heartbeat_staleness` |

Only `in_progress` tasks are considered, and the claim is cleared in each case.

Scrub is also the ledger's **integrity check**, because it is the one verb that
opens every file. Two failure modes make a task invisible to every other verb,
and nothing else will ever report them:

- `UNPARSEABLE` — the frontmatter is not valid YAML. Every read path returns
  empty for a file it cannot parse, so the task silently reads as having no id
  and no status: it matches no filter, enters no frontier, and produces no
  diagnostic anywhere. A real task sat that way for nine weeks after being
  authored with an unquoted `goal:` containing a colon.
- `NO-ID` — it parses, but carries no `id`, so no verb can name it.

Neither is repaired automatically: writes go through the same parser as reads, so
a file the CLI cannot read is one it must not write. Scrub reports the paths and
**exits 3** (§10).

### 5.11 `defer` / `undefer` / `deferred`
Status-preserving bookkeeping for the wiring flag. `undefer` requires a
`--caller` naming the non-test call site, so the ledger records evidence for the
claim rather than an assertion. `deferred` lists everything still outstanding.

### 5.12 `review` / `verdict` — review gates

Review gates put *reviewer tasks in the DAG*: ordinary tasks in the six-status
vocabulary, wired with ordinary blockers, and everything above — eligibility,
the state machine, ordering, the renderer — applies to them unchanged. Two
verbs do all the work; neither adds a status or a transition. (Not to be
confused with the pump's *feed* gates — see [GATES.md](GATES.md), which gate
launching globally and deliberately fail open. A review gate holds one edge of
the DAG shut and must never fail open.)

`review <impl-id> [--panel N] [--prompt <file>] [--max-rounds N]` synthesizes
the chain atomically under the state lock, as one ledger commit:

- N reviewer tasks (default 1) blocked by the implementation task, with ids
  allocated from the phase's own namespace (next free `.N`, §7);
- an **adjudicator** task blocked by every reviewer, when N > 1;
- the **gate task** — the adjudicator, or the lone reviewer — **added** to the
  blockers of every task that listed the implementation as a blocker. Added,
  never substituted: a later `reopen` of the implementation must hold
  downstream shut on its own.

One subject, one chain: a second `review` of the same task is refused, as is
reviewing a review task. Reviewing already-`done` work is legal (the chain is
simply eligible at once) and warns rather than refuses.

That rewiring is a snapshot, so the **authoring** blocker verbs keep it true
afterwards: `create --blockers` and `blockers --add`/`--set` carry the gate
along whenever a named blocker is an implementation under a live chain (a chain
whose gate is not yet `done`). Naming such an implementation as your blocker
means what it meant at chain-creation time — otherwise a task filed after the
chain exists would go eligible the moment the implementation completes, with
the verdict unrendered. No rider is added when the blocker is itself a review
task, when the owner is a member of that blocker's chain (a reviewer blocks its
subject by design), or when the gate is already `done`. `--remove` and
`--clear` are untouched — an operator must be able to undo a bad edge — and
`fsck` is the net: a task blocking on an implementation under live review but
not on its gate is a violation, because a review that fails open is not a
review.

`verdict <review-id> [--branch <b>] --approve [--findings -|"…"]` /
`--request-changes --findings -|"…"` records the outcome. Every verdict
requires the implementation to be `done` — `claim` checks status, not
blockers, so this guard is what refuses a ruling on unfinished or reopened
work. An adjudicator's verdict is refused while any of its reviewers has not
reported. A **claimed** review belongs to its claimant: `--branch` must be
given and must match `claimed_by`, on the same rule `claim` applies (same
branch fine, different branch never). An **unclaimed** review still rules, with
a warning — nothing records who ruled, and requiring `in_progress` would make
`verdict` stricter than `complete` and put a claim between a human and the
final call this section's round bound sends them. Then:

- **Approve** completes the review task (`* → done`, exactly as `complete`),
  findings appended to its own body. A panel reviewer's approve *is* its
  report — reviewers never move the implementation, and nothing surfaces one
  reviewer's findings to another before the adjudicator reads them all.
- **Request changes** — the gate task's call alone — appends the findings to
  the *implementation* task's body under `## Review findings (round N, …)`,
  reopens it as `reopen`-from-`done` does (completion markers shed, prior
  commits preserved in the note), re-arms the whole chain to `open`, and sets
  `review_round = N + 1`. The re-armed reviews are ineligible until the fix
  lands and `complete` runs again; the loop closes through §6 alone.
- A change-request that would need a round past `review_max_rounds` instead
  completes the gate (its verdict is delivered) and parks the implementation
  `needs-review` with `scrub_reason: review rounds exhausted (N/N)` and the
  findings intact. The bound measures futility, not duration; the door back is
  the ordinary `reopen` (§5.7), by a human — and that door **re-arms the whole
  chain** and resets `review_round` to 1, so the redone work goes back through
  the gate rather than past it. Without that, the exhaustion park would retire
  the gate permanently: it completes the gate task, so a reopen that touched
  only the implementation would leave downstream blocked on a `done` gate and
  the next `complete` would release it with no verdict rendered.

Supervisors that cannot dispatch review tasks see them only through
`ready --count` (§6): a range gated on an unrendered verdict reads as open
work with an empty frontier — a stall, reported loudly, never a drain.

---

## 6. The eligibility predicate

A task is **eligible** when:

```
status == "open"  ∧  every id in blockers has status == "done"
```

That is the whole rule. It is recomputed from the files on every query — there is
no cached frontier, no derived index that can go stale, and no separate "ready"
state to keep in sync.

A blocker that names a **nonexistent** task counts as unsatisfied. An
unresolvable blocker would otherwise remove a task from the frontier forever with
no diagnostic, which is why the mutating blocker verbs validate existence on
write.

Queries add scoping on top of the predicate, never replacing it:

- `next` returns the single lowest-ordered eligible task, and additionally skips
  tasks claimed by a *different* branch (`--branch` names yours; unclaimed or
  yours both qualify).
- `next` and the eligible walks of `ready` (`--json`, the table,
  `--count-eligible`) also skip **review tasks** (`review_role` present, §5.12)
  unless `--include-reviews` is passed: an in-context agent loop must never
  claim the review of its own work. `ready --count` deliberately does *not*
  skip them — a pending review is open work, and a range gated on one is
  stalled, not drained.
- `ready` returns the whole eligible frontier, same predicate.
- `ready --count` is deliberately **broader**: every `open` task in range,
  ignoring blockers and claims. This is the *drain test* — "is any open work
  left?" — not "what can run now?".
- `ready --count-eligible` is the narrower companion: the size of the frontier.
- `ready --json` and `list --json` both carry each task's declared `files:` as an
  array — `[]` when the task declares nothing, never `null`. A supervisor
  dispatching at task grain has to know what two eligible siblings would each
  touch before it may run them side by side, and "declares nothing" and "the
  field is missing" must not be distinguishable to a reader. `list --json` adds
  status, claimant and blockers for **every** task, not just the frontier: what a
  *running* task is touching is exactly what a candidate must not collide with.
  Its object is exactly these eight keys:

  | Key | Type | Notes |
  |---|---|---|
  | `id` | string | The task id. |
  | `file` | string | Path to the task file as the ledger reader resolved it — absolute or relative exactly as `resolve --tasks-dir` reports the directory. The one field that is *not* frontmatter: it is where this record was read from. |
  | `phase` | string | The id's phase, derived (`id` up to the first `.`). Present so a reader need not re-implement §7.2's split. |
  | `status` | string | §4. |
  | `claimed_by` | string \| null | `null`, never `""`, when unclaimed. |
  | `title` | string | The task's one-line title. |
  | `blockers` | array of strings | `[]`, never `null`. |
  | `files` | array of strings | `[]`, never `null`. See §3. |

The two counts diverge exactly when something is stalling the queue: work
remains open but nothing can start. `--count > 0` with `--count-eligible == 0` is
the signal, and a supervisor should treat it as a stall rather than progress.

### 6.1 Ordering

Tasks sort by phase, then by the numeric part within the phase, both numerically
— so `T9` precedes `T10`, and `T17.2` precedes `T17.10`. A non-numeric phase
sorts after all numeric ones. Ordering is a convenience for `next`, not a
priority system: nothing prevents working the frontier in any order.

---

## 7. The id grammar contract

Ids are configurable, but their **shape** is not. A consumer supplies a pattern
via `TASKPUMP_ID_PATTERN`; what TaskPump guarantees is how ids decompose.

### 7.1 Shape

An id is either `PHASE` or `PHASE.N`:

- `PHASE` is the grouping token — the pump's unit of dispatch, and what a phase
  range names.
- `.N` is the numeric position within the phase.

A pattern must accept both forms. Arachne's is `^F[0-9]+(\.[0-9]+)?$`; a generic
project might use `^T[0-9]+(\.[0-9]+)?$`. The tools do not care what the sigil is
— only that phase and position are separated by a `.` and that the position sorts
numerically.

Ids must not contain path separators, whitespace, or characters that are unsafe
in a filename: an id is a filename.

That rule is checked on the way **in** as well as on the way out. `create` and
`fsck` validate the id a human types, but a task file can also arrive without
passing either — written by hand, by an agent with a filesystem, or by a merged
pull request — so a consumer that reads an id back off disk and hands it to
another command re-checks it there. `tp cleanup`'s stuck-agent rescue does: an id
outside **this shape** is named on stderr and left unreleased rather than passed
on. `TASKPUMP_ID_PATTERN` is a separate question there — it is a naming
convention, not a safety property, so an id that is filename-safe but off-grammar
is reported and still released; refusing to free a wedged agent over a
convention would strand the claim, and `tp task fsck --fix` filters on the same
pattern and will not repair the file either.
Ids from `tp task`'s own read paths — `next`, `ready --json`, `list --json` —
are **not** yet re-checked; treat what they emit as ledger content, not as a
word you may splice into a command.

### 7.2 Phase derivation

The phase is the id up to the **first** `.`:

```
T17.10  →  T17
T17     →  T17
```

`create` derives `phase` this way unless `--phase` is given explicitly.

### 7.3 Ranges and lists

Wherever a phase spec is accepted (`ready --phases`, the pump's `--phases`):

| Form | Expands to |
|---|---|
| `T55` | that one phase |
| `t55`, `55`, `T55.2` | the same — case-insensitive, sigil optional, a full id is truncated to its phase |
| `T55..T63` | inclusive numeric range, ascending or descending |
| `T55,T58..T60` | comma-separated list of either form |

Non-numeric phase tokens pass through as single tokens and cannot participate in
a range.

---

## 8. The one-writer discipline

**The CLI is the sole reader and writer of frontmatter.** Not a convention — the
correctness argument for the whole system.

Every mutating verb takes an `flock` for its entire read-modify-write **and** the
git commit that follows. Concurrent agents on the same repo — including
containers that bind-mount it, where the lock is shared by inode — serialize
there. Read-only verbs (`next`, `ready`, `list`, `goal`, `deferred`, `resolve`)
take no lock. Where `flock` is unavailable the lock degrades to a no-op rather
than failing.

A hand edit bypasses the lock, the tripwire counters, and the state machine's
guards. It is how a claim ends up in two places at once, how a counter meant to
bound a loop gets reset, and how a task acquires a status no verb would have
given it. If a field you need does not exist, extend the CLI — do not write it
by hand.

The corresponding obligation on consumers: **do not parse frontmatter directly.**
Read through the CLI's JSON surfaces. A direct read is a second implementation of
the schema that no MAJOR bump will ever notify.

### 8.1 Where a ledger lives — resolution

All path resolution starts from **`$PWD`'s git worktree**, never from where the
tools are installed.

This is a scar. When resolution derived from the script's own location, running
the primary checkout's copy of the CLI while standing in a worktree wrote that
worktree's claim into the *primary's* ledger. The worktree's ledger never learned
about the claim; the primary's silently drifted 46 commits ahead of the work. It
went unnoticed because both invocations looked identical.

Whose work it is, is a property of the caller's directory. `tp task resolve`
prints which ledger a given invocation picked — use it whenever a workspace's
task state looks wrong.

---

## 9. Git as the transaction log

Every mutation is a git commit to the repository containing the tasks directory.
The commit message names the verb and the task (`claim T2.1 on feat/parser
(turns=50)`), so `git log` over the tasks directory is a complete audit trail of
who claimed what, when, and how it ended.

The commit is inside the lock, so the ledger cannot be observed mid-mutation.

**Push** is opt-in per invocation. When on, a rejected push retries with
fetch-rebase and jittered backoff — under a dozen concurrent agents pushing small
commits to the same ref, collisions are the norm, and undesynchronized retries
would thunder against it. A rebase that fails is aborted so no half-finished
rebase is left for the next invocation. Exhausting the retries is a hard failure.

**No remote is not an error.** A tasks directory that is not a git repository at
all is not an error either: the mutation still happens on disk, and the commit is
skipped. Local-first is the default; a ledger works on a laptop with no network,
no remote, and no git.

There is also a fixture mode that skips committing entirely, for tests and dry
runs.

---

## 10. The exit-code protocol — FROZEN

These codes are a wire protocol between processes. They are **frozen**: changing
one is a MAJOR change, and a consumer may key on them.

| Code | Producer | Meaning | Consumer |
|---|---|---|---|
| **3** | `tp task scrub` | ≥1 task file is invisible to the frontier (`UNPARSEABLE` or `NO-ID`). Actionable, not a crash. | The pump's per-tick preflight, which re-emits each offending path as a warning instead of logging a generic failure. |
| **3** | `tp task fsck` | ≥1 contract violation in the ledger — report mode, or what `--fix` could not repair (§11.1). Actionable, not a crash. | Import tooling and CI, which key on "violations found" (3) vs "fsck could not run" (1). |
| **3** | `tp pump` | Deadlock: nothing live, launchable, or resumable for N consecutive ticks. | `systemd`'s `Restart=on-failure`, and a human reading `systemctl --user status`. |
| **10** | any gate, `tp task resume-attempt` | Pause / escalate. From a gate: stop *launching* (§[GATES.md](GATES.md)). From `resume-attempt`: the no-progress budget is spent. | The pump's feed gate and resume path. |
| **1** | `tp task next` | Empty frontier — no eligible task. Also the generic error exit. | Agent loops, which read it as "nothing to do". |
| **1** | `tp task scrub` | Scrub itself failed — a crash, a missing dependency, a bad tasks directory. Deliberately distinct from 3. | Supervisors, which must not confuse a broken ledger with a broken scrub. |
| **75** | the reference runner's entrypoint | `EX_TEMPFAIL` — the environment was not usable and the agent exited **before claiming anything**, so no failed iteration is recorded against any task. | The launcher, which may retry without burning a tripwire. |
| **2** | any tool | Bad CLI arguments. | Humans. |
| **0** | everything | Success. For the pump specifically: **drained**, and a supervisor must *not* restart it. | `systemd`. |

Two pairs deserve attention because they encode a distinction that is easy to
lose:

- **`scrub` 3 vs 1.** "Your ledger has files nobody can see" is a different
  instruction from "the scrub could not run". Collapsing them means a supervisor
  either ignores real corruption or pages on a missing dependency.
- **`pump` 0 vs 3.** A drained pump and a deadlocked pump both stop feeding. Only
  one of them should be restarted, and only one should page a human. Before this
  distinction existed, a deadlocked pump idled for 563 ticks over seven hours
  while `systemd` reported it healthy.

### 10.1 Conformance note — where the tools diverge from the table above (v0.2.1)

> **The table in §10 is frozen and is not edited here.** This note records, for
> the release you are reading, exactly where `tp task` and `tp pump` do not
> implement it. **For a consumer writing code against TaskPump today, the tools
> are authoritative and this note is what to key on**; the frozen table states
> the intended protocol, and reconciling the two is a behaviour change, which a
> PATCH release may not make. The first two entries below are divergences and
> are filed as [#71](https://github.com/tjmisko/TaskPump/issues/71) (exit 2 is
> reserved for bad arguments and neither tool ever emits it) and
> [#72](https://github.com/tjmisko/TaskPump/issues/72) (exit 0 does not mean
> drained, and the state file cannot tell you either); the third is not a
> divergence at all but a deliberate
> widening, recorded here because the table's parenthetical would otherwise read
> as the whole rule.

**Neither `tp task` nor `tp pump` ever exits 2.** Row `2 | any tool | Bad CLI
arguments` does not hold for the two tools this contract is about. Both route
every usage error through a `die` that exits **1** — an unknown verb, an unknown
flag, a required argument omitted, an out-of-range value. Observed at this
revision: `tp task bogus`, `tp task claim` with no id, `tp pump --bogus` and
`tp pump --phases` with no value all exit 1. (`tp pump --phases` with no value
additionally fails as an unbound-variable error from bash rather than a
diagnostic, which is its own bug.)

Exit 2 is not fictional — it is simply produced elsewhere. `tp <unknown>`, the
`bin/tp` dispatcher's own unknown-command path, exits 2; so do `tp init`,
`tp cleanup`, both watchdogs, and both shipped runners' unknown-verb arms
(`RUNNERS.md §1.3` depends on that last one). So a consumer must **not** read
exit 2 as "bad arguments, generically". Read it as: the dispatcher did not
recognise the command, or a peripheral tool rejected its own arguments.

*What to key on instead:* for `tp task`, distinguish outcomes by the codes that
are real — `3` (ledger violations, from `scrub` and `fsck`), `10` (pause /
escalate, from `resume-attempt`), `1` for everything else including `next`'s
empty frontier. Do not try to separate "bad arguments" from "operation failed"
by exit code; they are the same code. Parse stderr, or do not distinguish.

**`tp pump` exit 0 does not mean drained.** Row `0 | everything | For the pump
specifically: drained, and a supervisor must not restart it` holds only for the
loop's own terminal exit. Every non-loop mode also exits 0 on success:
`--dry-run`, `--list`, `--once`, `--render-brief`, `--render-resume-note`,
`--help`, and `--detach` (which exits 0 in the *foreground* process as soon as
the supervisor is detached — the run it started has not even ticked). A `--once`
tick exits 0 whether it launched three agents, launched none because a gate
paused it, or found nothing to do.

This matters most where the table says it matters: a `systemd` unit keyed on
"exit 0 means drained, do not restart" is correct only because the unit runs the
pump in loop mode. Wire the same rule around `--once` in a cron job and every
tick reports a successful drain.

*What to key on instead:* the **state file**. The pump stamps a terminal status
into it on every exit path, including the signal handlers, precisely so that a
reader does not have to infer the outcome from a process's exit code —
`drained`, `stalled`, `paused`, `stopped`, each with a reason string. `3` still
means deadlock unambiguously; `0` means "this invocation finished", and the file
says what it finished doing.

**`tp pump` exit 3 is wider than the row's parenthetical, on purpose.** Row
`3 | tp pump` glosses the deadlock as "nothing live, launchable, or resumable
for N consecutive ticks". The pump asks the question one step later: nothing
live and **nothing started**, for N consecutive ticks. The narrower predicate
was the literal implementation once, and it answered "not deadlocked" whenever
the plan stayed full of work that never started — a pool cap of 0, launches that
fail every tick, a resume the budget has retired. The code and its meaning are
unchanged (`3` is deadlock: page a human, restart
under `Restart=on-failure`); only the set of conditions that reach it is
complete now. The reason string in the state file names which one it was.

---

## 11. Minimal conformance

An alternative implementation is conformant when it:

1. stores one markdown file per task in a flat directory, with the frontmatter
   fields and types of §3;
2. accepts and produces only the six statuses of §4, and permits exactly the
   transitions of §5;
3. computes eligibility as §6 states, recomputed per query, treating a missing
   blocker as unsatisfied;
4. decomposes ids as §7 states, and accepts the range/list syntax;
5. serializes mutations such that no two concurrent writers can both win a claim,
   and never requires a caller to edit frontmatter to reach a reachable state;
6. exits with the codes of §10.

Everything else — the language, the storage of the lock, whether git is involved,
which verbs exist beyond the state machine — is free.

### 11.1 Checking a ledger — `tp task fsck`

`tp task fsck` is the executable form of this contract: it checks every file in
the ledger and prints one line per violation, `<file>: <what>`. It is the
import path for a repository that already carries a directory of markdown task
files — run it (and `--fix`) before pointing any tool at a pre-existing DAG.

Checked per file:

- the file begins with a `---` line and the frontmatter closes with one (§2.1),
  and what lies between them parses as a YAML mapping;
- the line endings of the **frontmatter block** are LF. The delimiter
  comparison strips a trailing CR first, so a CR-terminated block is reported as
  **CRLF line endings** and not as a missing delimiter — it has one. That
  verdict is reached only after the parse and mapping checks above, because it
  asserts the block is readable: a CRLF file yq cannot parse is invisible to the
  frontier, which is what the checks above say and what `scrub` calls
  UNPARSEABLE, and fsck must not answer that file with a reassurance. What a
  readable CRLF block costs is a second reader and a stamp:
  - every yq-backed read returns the same value it would for an LF file — YAML
    normalizes CRLF, block scalars included — so `list`, `ready`, `next`,
    `scrub` and the `fm_get` calls behind them see the task normally;
  - `lib/dag-layout.awk` — the DAG renderer's parser, and the monitor's GRAPH
    tab through it — matches its delimiters as `/^---[ \t]*$/` and never strips
    a CR off a value. A CR on a **delimiter** is therefore a delimiter that
    parser never counts: it sees no block open and close, and the task is absent
    from the graph altogether. A CR on the **keys** alone leaves it drawing the
    task from values that still carry theirs — an id read that way (`T1\r`)
    matches no other task's blocker, so the node lands detached. The two are
    separate report lines because they are different damage, though the repair
    is the same;
  - `--fix` will not stamp it: `fm_set` writes LF, so stamping one key would
    convert the whole block's endings with it. Convert to LF and re-run, and
    that pass stamps it like any other import;

  Withholding the stamp is the **only** thing a CRLF file is spared. Every
  other check runs on it and every violation it carries is reported in the same
  run, so converting the endings and re-running turns up nothing the first run
  had not already named. The check is the block and its delimiters, not the
  whole file — a CRLF body is nothing `--fix` writes to, so there is nothing to
  mix and nothing to report;
- no key appears twice. A YAML mapping with `status: open` above `status: done`
  is legal to the parser and every reader takes the **last** value, so the
  human who reads the file top-down and the tools disagree about what it says —
  the shape a merge conflict leaves behind. Reported, never resolved: which
  value the author meant is not something `--fix` may guess;
- `id` equals the filename stem (§2) and matches the configured id pattern (§7);
- `status` is one of the six values of §4;
- `review_role`, where present, is `reviewer` or `adjudicator` (§3 "Review");
- `review_role`, where present, is accompanied by a `review_of`. `review_role`
  is what makes a task a review task, and every verb that acts on one resolves
  its subject through `review_of` — so a role with no subject is a task the
  frontier hides (§6) and `verdict` refuses outright: open work that nothing can
  dispatch and nothing can close, with no diagnostic until someone runs the verb
  by hand;
- `blockers` carries no empty entry. An empty string names no task: the
  dangling-blocker check skips it and so does §6, so it is a dependency in the
  file and in no reader;
- every machine key of §3 that is present has its contract type, and timestamps
  have the exact shape of §3 ("Timestamps"). A machine key absent from the file
  is reported too — a reader treats it as its default, but a writer should emit
  the full set, and stamping is what `--fix` is for. The *(verb-added)* keys
  are legal to omit, and unknown extension keys pass (§3 "Extension").

Checked whole-ledger — what no single-file tool can do:

- every blocker names an existing task file (§6 treats a missing one as
  unsatisfied forever);
- no task blocks itself;
- no blocker cycles. A cycle silently removes every one of its members from
  the frontier forever — each waits on the next, the eligibility predicate
  keeps answering "not yet", and no per-file read ever produces a diagnostic.
  The mutating blocker verbs validate each edge as it is written, but a cycle
  is made of individually valid edges — and an imported ledger arrives with
  all of its edges already drawn. fsck is the check that sees the whole graph;
- every `review_of` names an existing task file, and never the task itself
  (§5.12): a dangling one is a chain whose verdict can never land, and no
  per-file read would ever say so;
- **gate coverage**: a task that blocks on an implementation under a *live*
  review chain also blocks on that chain's gate task. This is the check that
  keeps a review gate from failing open. `review` wires the gate into every
  downstream blocker list at chain-creation time, and the authoring verbs carry
  it along afterwards, so the CLI cannot produce the uncovered shape — but an
  imported ledger can, and so can a hand edit or a deliberate
  `blockers --remove` of the gate. The result is not a task that stalls, which
  is how most ledger damage announces itself; it is a task that goes **eligible
  the moment the implementation completes, with the verdict unrendered** and
  every other reader silent about it. A review that fails open is not a review,
  so this is a violation rather than a warning.

  The check is deliberately narrow, and the exclusions are the contract as much
  as the rule is. The gate is the adjudicator, or the lone reviewer; a panel
  with no adjudicator has no gate and is not checked, because there is nothing
  to check against. A chain member blocking on its own subject is exempt — a
  reviewer blocks its implementation by design. And a chain whose gate is
  already `done` is exempt, because a rendered verdict has already gated that
  edge; reopening the subject re-arms the chain (§5.7) and the check applies
  again.

Exit codes follow scrub's convention (§10): **3** when violations were found
(actionable — one line names each), **0** on a clean ledger with no output, and
**1** when fsck itself could not run. A missing tasks directory is an error,
not a clean ledger.

`--fix` stamps **missing** machine keys with their documented defaults, and
records the whole repair as one ledger commit through the standard commit path
(§9). Most of those defaults are the ones §3 states per field — empty lists,
null claim fields, zero counters. Two are not, and it is worth naming where
they actually come from, because §3 documents no default for either:

- `status: open` — §3 marks `status` required, with no default. `open` is what
  `create` writes (§5.1), and §4 makes it the only status the frontier will
  surface; a file that reached fsck without one is a task nobody has started,
  so `open` is the transition it never got, not a guess about its state.
- `phase` — derived from `id` per §7.2, the same derivation `create` performs.
  Mechanical, not a default.

`--fix` stamps neither `id` nor `title`: §3 marks both required and neither has
a source to derive from, so it reports them and stops. It never touches the
body, never rewrites a present-but-wrong value, and never resolves a duplicate
key — a file carrying one is still stamped if it is missing keys, but which of
the two values survives is not a choice `--fix` makes. A file whose frontmatter
is CRLF it does not write to at all. All of those are reported and left as they
are, because guessing intent is how ledgers get corrupted.
