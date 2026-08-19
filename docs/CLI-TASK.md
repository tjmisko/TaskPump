## `tp task` — the ledger CLI

`tp task` is the ledger's only sanctioned reader and writer. Twenty-three verbs
dispatch out of one file (`libexec/tp-task`), and between them they are the whole
surface a consumer needs: the frontier queries a supervisor polls, the state
machine an agent drives, the authoring verbs that file work, the review gates,
and the two integrity checks. Everything it writes lands in YAML frontmatter
described by [LEDGER-CONTRACT.md](LEDGER-CONTRACT.md) §3, and every mutation is a
git commit.

This section documents what the code does at this revision, including the places
where that is not what you would want it to do. Those are marked **Trap**, and
they are collected again at the end.

Nothing here parses a task file for you. If you find yourself reaching for `yq`
against `tasks/*.md`, reach for `list --json` or `ready --json` instead — a
direct read is a second implementation of a schema that no version bump will
notify you about.

---

### Resolution: which ledger you are about to touch

Every invocation first answers "whose ledger is this?", before it looks at a
single argument. The rungs, in order:

1. `TASKPUMP_TASKS_DIR` names the ledger outright. Reported as `via env`, or
   `via conf-value` when the value came from a `taskpump.conf`.
2. `TASKPUMP_WORKSPACE_ROOT` pins the workspace. Reported as `via workspace-pin`.
3. A *discovered* `taskpump.conf` above `$PWD`, when `TASKPUMP_LEDGER_PROBE`
   resolves inside its directory. Reported as `via conf`.
4. `$PWD`'s git worktree, when the probe resolves there. Reported as `via cwd`.
5. Otherwise the TaskPump installation's own root. Reported as `via install-root`
   — and this is a fallback, not an answer.

`tp task resolve --all` prints the outcome and which rung produced it. Run it
first whenever a workspace's task state looks wrong; it is the diagnostic every
resolution error points at, which is why it is one of the few verbs that keeps
working when the others refuse.

**The install-root fallback is refused for eighteen verbs.** When resolution
reached rung 5 *and* the installation is outside the caller's worktree,
`create`, `claim`, `heartbeat`, `complete`, `block`, `needs-review`, `release`,
`reopen`, `review`, `verdict`, `defer`, `undefer`, `resume-attempt`, `scrub`,
`goal`, `title`, `blockers` and `fsck` die with a multi-line diagnostic naming
both probed directories. `next`, `ready`, `list`, `deferred` and `resolve` keep
answering. The refusal exists because a `tp task create` run in a fresh
repository with no `tasks/` directory once wrote the task into TaskPump's own
ledger, with a commit, and the repository the operator was standing in never
learned about it. Note that `goal`, `title`, `blockers` and `fsck` are refused
even in their read-only forms: a verdict about the wrong ledger is as wrong as a
write to it.

**A missing tasks directory is an error, not an empty frontier.** Twenty-one
verbs (every one that reads or writes the ledger except `fsck`, which has its own
check, and `resolve`) call `tp_require_tasks_dir` and die if
`$TASKPUMP_TASKS_DIR` does not exist. An empty listing with rc 0 from a
misresolved path is how a pump once reported a live range drained.

**A `TASKPUMP_WORKSPACE_ROOT` naming a missing directory is fatal before argv is
parsed** — even `tp task --help` and `tp task resolve` exit 1 with
`TASKPUMP_WORKSPACE_ROOT names a missing directory: <value>`. That message names
the key and the value, so it is its own diagnostic and has nothing to gain from
`resolve`.

---

### The state lock and the commit — split by form, not by verb

Mutation serializes on an `flock` held for the whole read-modify-write plus the
commit that follows. The lockfile is `<ledger git root>/$TASKPUMP_LOCK_NAME`, is
held on FD 9 for the process lifetime, and is removed on exit by a trap — but
only while the flock is still held and only when the path still names the inode
this process locked, because a lockfile unlinked carelessly stops being a lock.

Which invocations take it is a property of the **form**, not the verb, and that
distinction is easy to lose: `goal` appears on the contract's read-only-verb list
(§8), and `goal --set` locks and commits like any other mutator. Read the table
by invocation, not by name:

| Locks | Invocations |
|---|---|
| Always, taken by the dispatcher before the verb runs | `claim`, `heartbeat`, `complete`, `block`, `needs-review`, `release`, `reopen`, `review`, `verdict`, `defer`, `undefer`, `resume-attempt`, `scrub` |
| Always, taken inside the verb | `create` |
| Only on the mutating form | `goal --set`, `title --set`, `blockers --set/--add/--remove/--clear`, `fsck --fix` |
| Never | `next`, `ready`, `list`, `deferred`, `resolve`, `goal <id>`, `goal --missing`, `title <id>`, `blockers <id>`, `fsck` (report mode), `help` |

Verified by counting `acquired state lock` traces under `TASKPUMP_TASK_DEBUG=1`
for every verb in the table.

Two consequences worth stating outright:

- **`next` writes a file without the lock.** It has no ledger mutation, but it
  truncates `$TASKPUMP_TASK_OUT` on every call. Two agents sharing one
  `TASKPUMP_TASK_OUT` race there, and the loser reads a task it never asked for.
  Give each agent its own path.
- **`TASKPUMP_TASK_NOCOMMIT=1` disables the lock as well as the commit.**
  `acquire_state_lock` returns immediately, so fixture mode also turns off
  cross-agent exclusion. That is correct for a single-process test and wrong for
  anything concurrent.

Where `flock` is unavailable the lock degrades to a no-op with a debug trace.
Where the tasks directory is not inside a git repository, the lockfile falls back
to `/tmp/$TASKPUMP_LOCK_NAME` — so two unrelated non-git ledgers on one host
exclude each other, and the commit is skipped entirely (silently, unless
`TASKPUMP_TASK_DEBUG=1`).

Commit messages name the verb and the task (`claim T2.1 on feat/parser
(turns=50)`), so `git log -- tasks/` is the audit trail. `TASKPUMP_TASK_PUSH=1`
pushes after each commit; a ledger with no remote warns once and succeeds rather
than failing a verb whose write already landed.

---

### Exit codes

| Code | When |
|---|---|
| `0` | Success. |
| `1` | Every refusal, every guard, every unknown verb, every unknown flag, every missing required argument — and `next` on an empty frontier, and `scrub`/`fsck` failing to run at all. |
| `3` | `scrub` found task files invisible to the frontier; `fsck` found contract violations (in `--fix` mode, violations that remain after stamping). |
| `10` | `resume-attempt` ruled `escalate`: the no-progress budget is spent. |

**Trap: `tp task` never exits 2.** [LEDGER-CONTRACT.md](LEDGER-CONTRACT.md) §10
is frozen and assigns 2 to "any tool" for bad CLI arguments, but there is no
`exit 2` anywhere in `libexec/tp-task`: every argument error goes through `die`,
which exits 1. Verified — `tp task no-such-verb` and `tp task ready --nope` both
return 1. The dispatcher in `bin/tp` *does* honour the code, so `tp taskk`
returns 2 while `tp task nosuchverb` returns 1. A consumer branching on 2-vs-1
reads every `tp task` usage error as a generic failure; branch on stderr, or
treat 1 as "refused or misused" and reserve 3 and 10 for the meanings above.

`tp task` with no verb prints the full usage **to stdout** and exits 1;
`tp task --help` prints the same thing and exits 0. (`tp` with no arguments exits
0, so the asymmetry is `tp task`'s alone.)

---

### Argument grammar

- Value-taking flags accept both spellings: `--branch feat/a` and
  `--branch=feat/a`. Every value-taking flag in the file has a paired `--flag=*`
  arm; no help text shows the `=` form.
- Comma-separated list flags (`--blockers`, `--files`, `--commits`,
  `blockers --set`) split on `,`. `--files` and `--blockers` strip *all*
  whitespace from each element; `--commits` strips exactly one leading and one
  trailing space per element (`jq`'s `ltrimstr`/`rtrimstr`), so
  `--commits "  abc "` records `" abc"`. Verified.
- Ids are positional and there is exactly one per verb. A second positional is
  `too many positional args`, except for `resolve`, which silently ignores
  everything after the first argument: `resolve --tasks-dir --code-repo` answers
  for `--tasks-dir` alone, rc 0.
- `--phase`/`--phases` tolerate a sigil, no sigil, wrong case, or a full task id:
  `T51`, `t51`, `51` and `T51.2` all mean phase `T51`.
- Unknown flags are fatal for every verb **except `scrub`**, which has no
  argument parser at all (see Traps).

---

### The frontier: `next`, `ready`, `list`

All three read the ledger without mutating it, take no lock, and never commit.
`next` is the one that still writes something: `$TASKPUMP_TASK_OUT`, outside the
ledger.

#### `next [--branch <b>] [--phase <TN>] [--include-reviews]`

Emits the single highest-priority eligible task as JSON, on stdout **and** into
`$TASKPUMP_TASK_OUT`. Eligibility is `status: open` ∧ every blocker `done` ∧
(unclaimed, or claimed by `--branch`). Omitting `--branch` therefore narrows the
result to unclaimed tasks only — the empty string matches no claimant. Ordering
is numeric by phase then by within-phase number, not lexical. Verified with a
five-task fixture, `ready --json` returned `T9, T10, T17, T17.2, T17.10` in that
order, and `next` picked `T9`. A phase whose token is not numeric after the sigil
is stripped sorts after every numeric one — with a widened
`TASKPUMP_ID_PATTERN`, `TMERGE` came last.

`--phase` scopes to one phase, compared against the id's own prefix. Review tasks
are hidden unless `--include-reviews`: an in-context agent loop calling `next`
after completing its own work would otherwise claim the review of that work in
the same session, which looks like independent scrutiny and is not.

Output on success, five keys exactly:

```json
{"id":"T1","file":"/abs/path/tasks/T1.md","branch":"feat/a","goal":"...","ready":true}
```

`branch` echoes `--branch` verbatim and is `""` when the flag was omitted; `goal`
is `""` when the task has none, and in that case a warning naming
`goal <id> --set` goes to stderr.

**On an empty frontier `next` prints the literal `null`, writes `null` into
`$TASKPUMP_TASK_OUT`, and returns 1.** Both halves matter: an agent loop reads
the exit code as "nothing to do", and a stale `$TASKPUMP_TASK_OUT` from the
previous call would otherwise be indistinguishable from a fresh assignment.

#### `ready [--branch <b>] [--phases <spec>] [--json|--count|--count-eligible] [--include-reviews]`

The whole frontier rather than its head. `--phase` is an undocumented singular
alias for `--phases`, accepted in both `--phase T1` and `--phase=T1` spellings.

Four answers, and they are deliberately different questions:

- **default** — a human table with columns `ID PHASE STATUS BLOCKERS`; `STATUS`
  is always the literal `open`, because only open tasks reach it.
- **`--json`** — an array of `{id, file, phase, goal, blockers, files}`. `phase`
  is the id's prefix; `blockers` and `files` are always arrays, `[]` rather than
  `null`, so a reader never has to distinguish absent from empty. `[]` for an
  empty frontier.
- **`--count`** — the count of `status: open` tasks in range, **ignoring blocker
  and claim state**. This is the pump's drain test, "is any open work left?", and
  it counts review tasks even without `--include-reviews`: a pending review is
  open work, and a supervisor that stopped counting it would exit "drained" over
  an unrendered verdict.
- **`--count-eligible`** — the size of the `--json` frontier, "how many can launch
  now?". `--count-eligible` 0 while `--count` > 0 is the signature of a stall.

`--count` wins when both counting flags are given (it returns before the frontier
walk). All of `--json`, the default table and `--count-eligible` hide review tasks
unless `--include-reviews`.

`--phases` accepts a single phase, an inclusive numeric range in either direction
(`T3..T1` expands the same set as `T1..T3`), and comma lists of either
(`T1,T3..T5`). Non-numeric phase tokens pass through uppercased and cannot
participate in a range.

**Trap: a malformed range is not fatal.** `expand_phases` dies inside a process
substitution, so the `die` kills only the subshell. The phase set ends up empty
while the filter is still considered active, every task is skipped, and you get a
confident answer for a range you did not ask for:

```
$ tp task ready --phases 'TX..TY' --count
0                                        # rc 0; the error is on stderr only
$ tp task ready --phases 'T1,TX..TY' --count
1                                        # rc 0; an answer for T1 alone
```

Since `--count` is the documented drain test, a typo in a hand-typed range reads
as "drained", and the exit status will not tell you otherwise. Capture stderr and
treat `bad phase range` as fatal yourself.

#### `list [--status <s>] [--json]`

Every task, no eligibility filter, no phase filter. The human table is
`ID STATUS CLAIMED_BY BLOCKERS TITLE`, and appends a `no goal` flag to the title
of any `open` or `in_progress` task lacking one.

`--json` emits an array of eight keys exactly:
`{id, file, phase, status, claimed_by, title, blockers, files}`. `claimed_by` is
`null`, never `""`, when unclaimed. This is the shape a task-grain supervisor
reads: it needs status, claimant, blockers *and* declared footprint for every
task, because what a running task is touching is exactly what a candidate must
not collide with.

**Trap: `--status` is an exact string match with no vocabulary check.**
`list --status typo` prints the header row and nothing else, rc 0. The vocabulary
is `open|in_progress|done|blocked|needs-review|stuck`.

---

### Authoring: `create`, `title`, `goal`, `blockers`

#### `create <id> --title "..." [--phase TN] [--goal "..."] [--files a,b] [--blockers X,Y] [--milestone m]`

Writes `<tasks-dir>/<id>.md` with the full twenty-key machine frontmatter block —
`id, phase, title, status, claimed_by, claimed_at, turn_budget_remaining,
consecutive_failed_iterations, blockers, completed_by_commits, milestone, files,
last_heartbeat_head_sha, completed_at, goal, last_heartbeat_ts, blocked_at,
blocked_reason, resume_attempts, resume_head_sha` — plus a body of
`# <id> — <title>` and `## Spec` / `## Scope` / `## Acceptance` stubs. Commits
`create <id>`.

`--title` is required. The id must match `TASKPUMP_ID_PATTERN`. `phase` defaults
to everything before the first `.` in the id. The lock is taken *before* the
exists-check, because the check and the write are one read-modify-write: two
agents filing the same id concurrently would both pass an unlocked check and the
second `>` would truncate the first's task.

`--blockers` validates that every id resolves and rejects self-blocking, and
carries any live review gate along (below). `--milestone` is a free-form label no
tool interprets.

**Trap: `--phase` is not checked against the id, and nothing reads the field it
writes.** `create T52 --title C --phase TZZ` succeeds and stores `phase: TZZ`,
but every phase filter — `next --phase`, `ready --phases`, and the pump's
grouping through them — derives the phase from the id's own prefix instead.
Verified: that task is counted by `ready --phases T52 --count` (1) and invisible
to `ready --phases TZZ --count` (0), while its frontmatter says `TZZ`. The
override buys you a mislabelled record, not a regrouping.

#### `title <id> [--set "text"]`

Read form prints the title on one line, rc 0, no lock. `--set` refuses empty
text, takes the lock, writes `.title`, commits `title: set <id>`.

#### `goal <id> [--set "text"]` and `goal --missing`

Read form prints the goal on one line — an empty line when unset, rc 0. `--set`
refuses empty text, takes the lock, writes `.goal`, commits `goal: set <id>`.

`--missing` lists the ids of `open` and `in_progress` tasks with no goal, one per
line, rc 0 always. It is read-only and ignores any id argument.

**Note the split**: `goal` is on the contract's read-only-verbs list, but
`goal --set` locks and commits like any other mutator. The read forms are
genuinely lock-free; the verb is not.

#### `blockers <id> [--set A,B | --add X | --remove X | --clear]`

Read form prints one blocker id per line, rc 0, no lock. Empty output means no
blockers.

Mutating forms take the lock **before** reading the current list — `--add` and
`--remove` are read-modify-write, and reading outside the lock lets two agents
compute from the same stale snapshot so the second write drops the first's edge.
Each form then normalises the whole surviving list: trim, drop empties, reject
self-blocking, require every id to resolve to a real task file, de-duplicate.
The list is written in YAML **block** style, never flow style, because the DAG
renderer's line-oriented parser reads `blockers:` followed by `  - id` lines and
would see a flow list as no blockers at all.

`blockers <id> --set ""` is refused with `use --clear to empty`; `--add ""` and
`--remove ""` with `blockers --<mode> requires an id`. `--clear` writes
`blockers: []` — it has no candidates, so there is nothing for the validation to
reject, which is why it keeps working when the existing list is already broken.

`--set` and `--add` carry live review gates along; `--remove` and `--clear` do
not, because a subtractive form is an operator explicitly rewiring, and re-adding
what they just removed would make a bad edge unfixable.

**Trap: an unresolvable blocker is refused in silence.** `blockers T2 --add T99`
and `create T9 --blockers T99` both exit 1 with nothing on stdout and nothing on
stderr. `normalize_blockers` calls `task_file_required` as a plain command; the
inner `task_file` returns 1, and under `set -euo pipefail` errexit kills the
shell before the `die` on the next line can print. The refusal is real — nothing
is written — but you get no diagnostic. Self-blocking, checked one line earlier,
*does* print (`a task cannot block on itself: T1`).

**Trap: a pre-existing dangling blocker makes `--remove` fail.** Because the
whole surviving list is re-normalised, removing `T1` from `blockers: [T1, T2,
T99]` where `T99` names nothing exits 1 silently and changes nothing. `--clear`
still works. Verified. `fsck` is what names the dangling edge.

---

### The claim lifecycle

#### `claim <id> --branch <b> [--turns N]`

Sets `status: in_progress`, `claimed_by`, `claimed_at`, `turn_budget_remaining`,
zeroes `consecutive_failed_iterations`, and nulls `last_heartbeat_head_sha`.
Commits `claim <id> on <b> (turns=N)`. Prints `claimed <id> for <b>
(turn_budget=N)` and, when the task has one, `goal: ...`.

`--branch` is required. Re-claiming with the same branch on an `in_progress` task
is idempotent and refreshes the budget; any other status, or a different
claimant, is refused. `--turns` defaults to `TASKPUMP_TURN_BUDGET_DEFAULT` (50).

**The branch name is validated at claim time**, and this is the one place that
rule is enforced: a branch may carry at most one `/`, because the agent name is
the branch with `/` mapped to `-` and that mapping has to be reversible.
`claim T2 --branch feat/a/b` is refused with a two-paragraph explanation, rc 1.
Letting it through costs nothing here and everything later — the pump reads the
phase as dead and launches a second agent on the same branch.

**Trap: `--turns` is not validated.** The value is interpolated straight into a
`yq` expression, so `--turns abc` leaks `Error: 5:30: lexer: invalid input text`
with rc 1 and no tool prefix. Nothing is written. Contrast `resume-attempt
--max`, which is validated.

#### `heartbeat <id> [--start|--end]`

**With no flag, the mode is `--start`** — the parser's initialiser, not a
documented default. Verified: `heartbeat T1` prints `heartbeat start T1` and
writes the start stamp.

A heartbeat on a task that is not `in_progress` is a silent no-op, rc 0.

`--start` records the code repo's current HEAD in `last_heartbeat_head_sha` and
stamps `last_heartbeat_ts`. `--end` decrements `turn_budget_remaining` (floored
at 0), nulls `last_heartbeat_head_sha`, re-stamps `last_heartbeat_ts`, and
decides productivity: HEAD moved since `--start`, and — when the task declares
`files:` — at least one touched path is in that set. Productive resets
`consecutive_failed_iterations` to 0; unproductive increments it.

Two carve-outs:

- **Ambiguous attribution is refused rather than credited.** If the touched files
  also match some *other* `in_progress` task's `files:` list, a `WARNING` naming
  the conflicting ids goes to stderr and neither task is credited. The incident:
  one task was credited productive because another's commit overlapped its
  `files:` list while that other task was the one actually being worked.
- **On a review task `--end` decrements the budget only.** The failure counter is
  left untouched — not incremented, not reset — because an honest reviewer
  commits no code and three cycles of carefully reading a diff would otherwise
  scrub it `stuck`. A wedged reviewer is still bounded by the budget and by
  heartbeat staleness.

#### `complete <id> [--commits sha,sha] [--defer-wiring "note"]`

Sets `status: done`, `completed_at`, `completed_by_commits` (a JSON array parsed
from the `--commits` comma list, one space stripped from each end of each
element), and clears `claimed_by`, `turn_budget_remaining`,
`consecutive_failed_iterations` and `last_heartbeat_head_sha`. Commits
`complete <id>`.

`--defer-wiring` additionally sets `wiring_deferred: true` and
`wiring_deferred_note`, and appends a `## Wiring deferred` section to the body.

**Stdin becomes a `## Completion notes` section** whenever stdin is not a tty.
That is `! [ -t 0 ]`, so a pipe from a script or a redirect from a file both
count; `< /dev/null` reads empty and appends nothing.

**Refused on a review task**, with a pointer to `verdict`. Both write the same
`done`, but every guard that makes a verdict mean something lives in `verdict`,
so a `complete` on a gate task would hand downstream a green light with the panel
still open and no ruling recorded anywhere.

#### `block <id> --reason "..."`

`status: blocked`, clears `claimed_by`, sets `blocked_at` and `blocked_reason`,
appends a `## Blocked` section. `--reason` required.

#### `needs-review <id> --reason "..."`

`status: needs-review`, clears `claimed_by`, sets `scrub_reason` to the reason,
appends a `## Needs review` section. `--reason` required. This is the sanctioned
setter the pump uses to quarantine a phase whose merge conflicted or went
build-red, so it never hand-edits frontmatter.

#### `release <id> --reason "..."`

Relinquishes a live claim: `status: open`, clears `claimed_by`, `claimed_at`,
`turn_budget_remaining` and `last_heartbeat_head_sha`, appends a `## Released`
section. **Refuses any status but `in_progress`.**

#### `reopen <id> --reason "..."`

The door back to `open` from `blocked`, `done`, `needs-review` or `stuck`; any
other status is refused. Always clears `blocked_at`, `blocked_reason`,
`claimed_by`, `claimed_at`, `turn_budget_remaining`, `last_heartbeat_head_sha`
and `scrub_reason`, and appends a `## Reopened (ts, from <status>)` section.

From `done` it also sheds `completed_at`, `completed_by_commits`,
`wiring_deferred` and `wiring_deferred_note`, preserving the prior commits in the
body note. From `needs-review` or `stuck` it also zeroes
`consecutive_failed_iterations`, so a task revived from `stuck` does not re-trip
its tripwire on the next unproductive turn.

Without this verb, `needs-review` and `stuck` are dead ends: `release` requires
`in_progress`, `claim` requires `open`, and nothing else writes `open`.

**Reopening a task that carries a review chain re-arms the chain.** When the
reopened task has a `review_round`, every chain member that is not already `open`
is reset to `open` (completion, claim, block and scrub markers all shed) and
gains a `## Re-armed by reopen` note; `review_round` goes back to 1. The output
gains a second line naming what moved:

```
$ tp task reopen T1 --reason "human says go"
reopened T1 (was needs-review)
review chain re-armed (round 1): T1.1
```

Without this, the rounds-exhausted park would be a trapdoor: that path completes
the gate, so a bare reopen would leave the gate `done` and the next `complete`
would make downstream eligible with no review rendered and nothing warning.
`verdict` cannot patch it either — it refuses a second ruling on a `done` review,
and `review` refuses a second chain — so `reopen` is the only sanctioned way
back.

---

### Review gates: `review` and `verdict`

This is the newest surface, and the one with the most guards. The design is that
a review is an **ordinary task** the CLI synthesizes, so the eligibility
predicate does the gating with no new predicate logic and the DAG renderer draws
the chain because it is nodes with edges. See
[design/review-gates.md](design/review-gates.md) for the rejected alternatives.

#### The shape of a chain

`review T1 --panel N` creates:

- **N reviewer tasks**, each blocked by `T1`, with `review_of: T1` and
  `review_role: reviewer`.
- **an adjudicator** when `N > 1`, blocked by all N reviewers, with
  `review_role: adjudicator`.
- **the gate**: the adjudicator if there is one, else the lone reviewer. The gate
  id is *added* to the blockers of every task that already named `T1` as a
  blocker — added, never substituted, so a later reopen of `T1` still holds
  downstream shut on its own.

Ids come from the implementation's own phase namespace, allocated as the next
free `.N` (the bare-phase file counts as 0). With `T1` and `T1.2` present,
`review T1` produces `T1.3`. Each generated id is checked against
`TASKPUMP_ID_PATTERN` before anything is written.

Round bookkeeping lives on the **implementation** task, not on the reviews:
`review_round` (starts at 1) and `review_max_rounds`. One home for the counter
and its bound, whichever chain member renders the ruling.

Worked example, verified end to end:

```
$ tp task review T1 --panel 2
review chain for T1: reviewer(s) T1.1 T1.2, adjudicator T1.3 (gate: T1.3)
downstream rewired onto the gate: T2
```

With no downstream the second line reads `no downstream tasks listed T1 as a
blocker; the gate blocks nothing yet` — which is a real state, not a failure.

#### `review <impl-id> [--panel N] [--prompt <file>] [--max-rounds N]`

Locks, writes the chain, rewires downstream and commits — all in one ledger
commit, so the chain is never observable half-built.

| Flag | Default | Behaviour |
|---|---|---|
| `--panel N` | 1 | Number of reviewer tasks. Must be a positive integer; `--panel 0` dies rc 1. `N > 1` also synthesizes the adjudicator. |
| `--prompt <file>` | none | A review lens, recorded in `review_prompt` for whatever dispatches the reviewer. **Validated at creation time** — a typo'd path fails here, not weeks later. Stored repo-relative when the file lies inside `TASKPUMP_CODE_REPO` (so the recorded path survives the ledger being read from another checkout), absolute otherwise. Verified both ways. Set only on reviewer tasks; the adjudicator gets `review_prompt: null`. |
| `--max-rounds N` | 3 | Bound on the change-request loop, written to `review_max_rounds` on the **implementation**. Must be a positive integer; `--max-rounds 0` dies rc 1. |

Refusals:

- **One subject, one chain.** A second `review T1` dies naming the existing
  members: `a review chain for T1 already exists (T1.1); one subject, one chain —
  reopen its tasks to re-review`.
- **A review task cannot be reviewed.** `review T1.1` dies — the adjudicator is
  the review of the reviews.

Reviewing already-done work **warns and proceeds**: `reviewing already-done work:
T1 is done, so the chain is eligible immediately`. Reviewing landed work is
legitimate.

#### Review tasks and the frontier

Review tasks carry `review_role`, and that is what hides them:
`next` and `ready` (in its `--json`, default and `--count-eligible` forms) skip
any task with a `review_role` unless `--include-reviews` is passed. `ready
--count` counts them regardless. This is **query scoping only** — the eligibility
predicate is untouched, and `claim` works on a review task directly.

#### `verdict <review-id> [--branch <b>] --approve|--request-changes [--findings -|"..."]`

The one way a review closes. `--findings -` reads stdin.

**Guards, in the order they fire:**

1. Exactly one of `--approve` / `--request-changes`, or die.
2. The id must name a task with a `review_role`.
3. That task must not already be `done` — `a verdict is already recorded ...;
   reopen it to re-review`.
4. **Ownership.** A *claimed* review requires `--branch`, and the branch must
   equal `claimed_by`; ruling over another branch's live claim would overwrite a
   reviewer mid-read. An *unclaimed* review **warns on stderr and proceeds, rc
   0** — requiring `in_progress` would make `verdict` stricter than `complete`,
   and the documented human door out of a rounds-exhausted park has no
   dispatcher around to claim for it. In a scripted drain that warning is the
   only record of who ruled, and it does not affect the exit code.
5. `review_of` must resolve to a task in this ledger.
6. **The implementation must be `done` — for BOTH verdicts.** `cannot render a
   verdict on T1 while it is open; the review is of completed work (wait for
   complete)`. `claim` checks status, not blockers, so nothing upstream of this
   line stops a verdict on work that was never finished or was reopened while the
   reviewer read it, and a verdict on a moving target reviews nothing. (The
   tool's `--help` used to attach this requirement to `--request-changes` alone;
   that text has been corrected. Verified: `verdict T1.1 --approve --findings ok`
   on an `open` implementation dies rc 1.)
7. `--request-changes` requires `--findings`, non-empty — the implementer needs
   something to act on. `--approve` does not.
8. **An adjudicator may not rule before its panel reported**: `adjudicator
   verdict before the panel reported — still pending: T1.1 T1.2`.
9. **Only the gate task renders `--request-changes`**: a panel reviewer gets
   `only the gate task (T1.3) renders the change-request verdict; record your
   findings with --approve — independence is the point of the panel`. A panel
   where any member can reopen the work is a panel whose verdict nobody rendered.

**`--approve`** completes the review task (`status: done`, `completed_at`,
claim and budget cleared) and appends `## Verdict: approve (round N, ts)` with
the findings, if any, to that task's body. The output line differs by role:

```
verdict T1.3: approve (round 1) — the gate is done; downstream unblocks as its remaining blockers do
verdict T1.1: approve (round 1) — report recorded; the gate verdict belongs to T1.3
```

**`--request-changes` within the round budget** is the change loop, and it moves
four things at once:

- the findings are appended to the **implementation's** body as `## Review
  findings (round N, ts)` — the implementer is who must act on them;
- the implementation reopens exactly as reopen-from-done would (completion
  markers shed, prior commits preserved in the note) and `review_round` advances;
- the ruling gate's body gains `## Verdict: request-changes (round N, ts)`;
- **the whole chain re-arms to `open`**, the ruling gate included — it keeps its
  verdict note but ends the call `open`, not `done` — each non-ruling member
  gaining a `## Re-armed for round N` note. Their blockers are intact, so every
  member stays ineligible until the fix lands and `complete` runs again. The loop
  closes through the eligibility predicate and nothing else.

```
verdict T1.1: request-changes (round 1) — T1 reopened for round 2; chain re-armed
```

**`--request-changes` past `review_max_rounds`** does something different: the
gate's verdict is delivered (its task completes, the report stands) and the
implementation is **parked** rather than reopened —

```
verdict T1.1: request-changes (round 2) — review rounds exhausted (2/2); T1 parked needs-review with the findings
```

— `status: needs-review`, `scrub_reason: review rounds exhausted (2/2)`,
completion markers shed. The round bound measures futility, not duration; past it
a human renders the final call, and the door back is `reopen`, which re-arms the
chain and resets `review_round` to 1.

#### Gate riders on the authoring verbs

`review` snapshots downstream once, at chain-creation time, and never revisits.
In a long-horizon drain, work is authored as it is discovered, so a task filed
*after* the chain exists would block on the implementation alone and go eligible
the moment it completed — the gate looking applied and not being, which is the
feature's central promise leaking out the back.

So `create --blockers` and `blockers --add/--set` carry the gate along. Naming an
implementation under live review as your blocker means what it meant at
chain-creation time:

```
$ tp task create T4 --title Late --blockers T1
created T4 at .../tasks/T4.md
review gate(s) carried along (the named blocker is under live review): T1.3
```

Three cases deliberately get no rider: a blocker that is itself a review task
(the chain's own wiring), an owner that is a member of that blocker's chain (a
reviewer blocks its subject by design, and a rider would build a cycle), and a
chain whose gate is already `done` (the edge would be inert). Subtractive forms
never ride.

Note the asymmetry this produces: `blockers T5 --add T1` writes `T1 T1.3`, and
`blockers T5 --remove T1` then leaves `T1.3` behind. The gate edge was added by a
rider and is removed only by naming it.

`fsck` is the net under everything the riders cannot reach — see below.

---

### Deferred wiring: `defer`, `undefer`, `deferred`

The sanctioned opt-out from "wire it to production before calling it done": the
foundation shipped and its unit tests pass, but the first real non-test caller
was left for a follow-up.

#### `defer <id> --reason "what wiring was deferred"`

Sets `wiring_deferred: true` and `wiring_deferred_note`, appends a `## Wiring
deferred` section. **Status is untouched** — the task can still go `done`.
`--reason` required. `complete --defer-wiring "note"` is the inline form at
completion time.

#### `undefer <id> --caller "<file:line> — what wired it"`

Sets `wiring_deferred: false`, nulls the note, appends a `## Wiring landed`
section. `--caller` is required and should name the non-test call site, so the
ledger records the *evidence* for the claim rather than an unbacked assertion.
Refuses when `wiring_deferred` is not set. If the wiring did not actually land,
use `reopen` instead.

#### `deferred [--json]`

Lists every task with `wiring_deferred: true`. The table is
`ID STATUS DEFERRED-WIRING NOTE`; `--json` emits an array of
`{id, status, note}`. Read-only, no lock, rc 0. This is the collection step:
shipped-but-unwired foundations to fold back into the queue as follow-up tasks.

---

### Supervisor verbs: `scrub`, `resume-attempt`

#### `scrub`

Takes the lock. Walks every task file and does two jobs.

**Job one — report the invisible.** A file whose frontmatter does not parse, or
that parses with no `id`, is invisible to every other verb: `fm_get` swallows
`yq`'s error and returns empty, so the task matches no status filter, never
enters the frontier, and produces no diagnostic anywhere. One such file sat in a
ledger for nine weeks after being authored with an unquoted `goal:` containing a
colon. Neither case is repaired here — `fm_set` also goes through `yq`, so the
CLI cannot write to a file it cannot read.

```
scrub: UNPARSEABLE /…/tasks/T8.md (invisible to next/ready — repair the frontmatter by hand)
scrub: NO-ID /…/tasks/T9.md (invisible to next/ready — add an 'id:' or move the file out of the tasks dir)
tp-task: 2 task file(s) invisible to the frontier (see UNPARSEABLE/NO-ID above)
```

Per-file lines go to **stdout**; the summary line is the only thing on **stderr**,
so `scrub 2>&1 | tee` does not double-report each path. Exit 3. Exit 1 means
scrub itself failed, which a supervisor must not confuse with a broken ledger.

**Job two — relabel stale claims.** For each `in_progress` task, three tripwires,
and they are an **if/elif chain, not a set**:

| Order | Condition | Result |
|---|---|---|
| 1 | `turn_budget_remaining <= 0` (a null budget reads as 3) | `needs-review`, `scrub_reason: turn_budget exhausted` |
| 2 | `consecutive_failed_iterations >= TASKPUMP_FAILURE_LIMIT` | `stuck`, `scrub_reason: consecutive_failed_iterations=N` |
| 3 | last heartbeat (or `claimed_at`, if it never beat) older than `TASKPUMP_CLAIM_STALE_HOURS` | `needs-review`, `scrub_reason: heartbeat_staleness` |

Each also clears `claimed_by`. A claim that is simultaneously budget-exhausted
*and* heartbeat-stale reports only the budget reason. A non-integer
`TASKPUMP_CLAIM_STALE_HOURS` silently falls back to 24. A null budget defaults to
3 rather than 0, so a legitimate in-flight claim from tooling that skipped
`--turns` is not scrubbed on the very next pass.

**Trap: `scrub` has no argument parser.** `main` passes `"$@"` through and
`cmd_scrub` goes straight into the file loop, so every flag is silently ignored —
including one that reads like a safety flag. Verified: `tp task scrub --dry-run
--whatever` ignored both and relabeled a task, rc 0. There is no dry-run mode.

#### `resume-attempt <id> --head <sha> [--max N]`

The supervisor's verb — nothing enforces that, but nothing else has a reason to
call it. It records that a stalled task is about to be auto-resumed and rules on
whether it still may; the ruling comes back on stdout *and* in the exit code, so
the caller never has to read frontmatter itself.

Progress is "did the branch move since the last resume", measured by comparing
`--head` against the stored `resume_head_sha`. That deliberately does not depend
on the container cooperating: a dead agent never fires `heartbeat --end`, so
`consecutive_failed_iterations` stays 0 and cannot serve as the budget; and
`claim` zeroes that counter anyway, so the pump's own resume cycle would reset the
tripwire meant to stop it.

```
head moved, or first ever resume  ->  resume_attempts = 1,  "resume 1/3",   rc 0
no progress                       ->  resume_attempts += 1, "resume 2/3",   rc 0
would exceed --max                ->  clamped at max,       "escalate 3/3", rc 10
```

Clamping keeps repeated escalate calls idempotent: once exhausted the verb writes
nothing, so a pump ticking every 30 seconds does not churn a commit per tick.
Verified: three calls with an unchanged sha give `resume 1/2`, `resume 2/2`,
`escalate 2/2` (rc 10), and a fourth with a new sha resets to `resume 1/2`.

`--head` is required and must be 7-40 hex characters — validated rather than
escaped, because it is interpolated into a `yq` expression and a hex-only shape is
cheaper than getting the quoting right. `--max` defaults to 3 and must be at
least 1; `--max 0` dies rc 1.

---

### `fsck [--fix]` — whole-ledger conformance

The import path for a repository that already carries a directory of markdown
task files, and the audit `scrub` is too cheap to be. One line per violation
(`<file>: <what>`), exit 3 when any exist, 0 when clean, 1 when fsck could not run
(a missing tasks directory is `die`, exit 1 — a verdict about a ledger that does
not exist is not a clean bill of health).

**Per file:**

- the frontmatter opens with `---`, closes with `---`, parses as YAML, and is a
  mapping — the delimiter checks are load-bearing, because `yq`'s front-matter
  mode happily "parses" a file with none at all;
- **CRLF endings**, reported in two flavours: on the delimiters, or on the keys
  alone with bare delimiters. Both are named because the second reader —
  `lib/dag-layout.awk`, the DAG renderer and the monitor's GRAPH tab through it —
  matches a bare `---` and never strips a CR off a value. A CR on a delimiter
  drops the task from the DAG entirely; a CR on the keys alone draws it from
  values that still carry theirs, so its id matches no blocker and the node lands
  detached. Neither stops the rest of the audit;
- every key in the twenty-eight-key schema table has a contract-legal type, and
  the three classes differ: `id`/`title` are required (no default exists to
  invent), eighteen are stampable, and eight are verb-added and legal to omit;
- `status` is in `open|in_progress|done|blocked|needs-review|stuck`;
- `review_role` is in `reviewer|adjudicator`;
- **`review_role` present with no `review_of`** — a review task with no subject is
  hidden from the frontier and `verdict` dies on it: open work nothing can
  dispatch and nothing can close;
- no duplicate key. `yq`'s tree keeps both entries and every reader takes the
  last, so a `status: open` above a `status: done` (the merge-conflict artifact)
  is a file whose human reader and whose tools disagree;
- `id` is a string, equals the filename stem, and matches
  `TASKPUMP_ID_PATTERN` — a file whose name and id disagree is reachable by one
  path and invisible to the other;
- `blockers` contains no empty entry.

**Whole-ledger** — the checks no single-file tool can do:

- **dangling blockers** — `blocker 'T99' names no task in this ledger (unsatisfied
  forever — the task can never enter the frontier)`;
- **self-blocks** — `task blocks itself ('T2' is in its own blockers)`;
- **blocker cycles**, by depth-first walk over the blocker edges, reported as the
  full path. Verified with `T1 -> T3 -> T2 -> T1` wired by hand: exactly one
  violation, rc 3. A cycle removes every one of its members from the frontier
  forever, and no per-file read will ever say so — the eligibility predicate just
  keeps answering "not yet";
- **`review_of` resolution**, and never to the task itself;
- **gate coverage**: a task that blocks on an implementation under **live** review
  must also block on that chain's gate. The CLI cannot produce this shape — the
  rewiring and the riders see to that — but an imported ledger, a hand edit, or a
  deliberate `blockers --remove` of the gate can, and the result is the feature
  failing *open*. A review that fails open is not a review, so it is a violation,
  not a warning. Verified: removing one gate edge from a live chain yields
  exactly one violation and rc 3. A chain whose gate is already `done` is skipped;
  so is a panel with no adjudicator, which has no gate to check against.

**`--fix`** takes the lock and stamps **missing** stampable keys with their
documented defaults, as one ledger commit, then runs the report pass — so what
prints and what the exit code answers for is what *remains* wrong. It is
deliberately narrow:

- only files whose identity is sound are written (parseable mapping, `id` a
  string equal to the stem and matching the pattern) — writing to a file whose
  identity is in question would launder a broken file into a half-plausible one;
- a **present-but-wrong** value is never rewritten, and a **duplicate** key is
  never resolved: which value the author meant is exactly the guess it refuses to
  make;
- a **CRLF** file is not stamped at all, because `fm_set` writes LF and stamping
  one key would convert the whole block's endings with it. Convert the endings and
  re-run; the second pass stamps it like any other import, and turns up nothing
  the first pass had not already named.

---

### `resolve` and `help`

#### `resolve [--tasks-dir|--code-repo|--all]`

Prints where this invocation would read and write. Defaults to `--all`. Exempt
from both the install-root refusal and the missing-directory refusal, because it
is the diagnostic those errors point at — an error that disables the tool you need
to diagnose it is a worse error.

```
$ tp task resolve --all
tasks_dir  /home/me/proj/tasks
task_out   /home/me/proj/.next-task
code_repo  /home/me/proj
script     /opt/taskpump
cwd_root   /home/me/proj
via        cwd
conf       <none>
```

`script` is the installation root; `cwd_root` is `$PWD`'s git toplevel or
`<none>`; `conf` is the loaded config file or `<none>`. `via` is one of
`conf | cwd | install-root | workspace-pin | env | conf-value`, and it is the
field every resolution error tells you to read.

`resolve` reads only its first argument, silently. An unrecognised first argument
dies with the usage line, rc 1.

#### `help` / `-h` / `--help`

Prints the full usage to stdout, exit 0. `tp task` with no verb prints the same
text to stdout and exits **1**.

---

### JSON output shapes, in full

Four verbs emit JSON. These are the complete key sets; nothing is optional and
nothing else appears.

| Producer | Shape |
|---|---|
| `next` (stdout and `$TASKPUMP_TASK_OUT`) | `{"id":string,"file":string,"branch":string,"goal":string,"ready":true}` — or the bare literal `null` on an empty frontier, with rc 1 |
| `ready --json` | `[{"id":string,"file":string,"phase":string,"goal":string,"blockers":[string],"files":[string]}]` — `[]` when empty |
| `list --json` | `[{"id":string,"file":string,"phase":string,"status":string,"claimed_by":string\|null,"title":string,"blockers":[string],"files":[string]}]` — `[]` when empty |
| `deferred --json` | `[{"id":string,"status":string,"note":string}]` — `[]` when empty |

`file` is always an absolute path. `blockers` and `files` are always arrays, never
`null`. `branch` and `goal` are `""` rather than `null` when unset. `claimed_by`
is the one field that is `null` rather than `""`.

`next`, `ready --json` and `list --json` are pretty-printed; `deferred --json`
emits one compact object per line with the closing `]` on a line of its own. Feed
all four to a parser, not to a line reader.

---

### Environment keys

Twenty keys are read directly by `tp task`. Names below are canonical; the legacy
`ARACHNE_*` spelling of each is promoted to it by `lib/config.sh` (verified:
`ARACHNE_TASKS_DIR` sets `tasks_dir` and reports `via env`).

**Locations**

| Key | Default | Effect |
|---|---|---|
| `TASKPUMP_LEDGER_PROBE` | `tasks` | The ledger's path relative to a candidate workspace root. Answers "does this worktree carry a ledger of its own?", and when no tasks dir is named outright it *is* the ledger's location. |
| `TASKPUMP_WORKSPACE_ROOT` | unset | Pins the workspace, outranking the conf and cwd probes. A value naming a missing directory is fatal before argv is parsed. Loses to an explicit tasks dir, and loses *outright*: it then moves neither the tasks dir nor `TASKPUMP_CODE_REPO`. |
| `TASKPUMP_TASKS_DIR` | `<workspace>/<probe>` | The ledger directory. The most specific key there is. |
| `TASKPUMP_TASK_OUT` | `<parent of tasks dir>/.next-task` | Where `next` writes its JSON. Give concurrent agents separate paths. |
| `TASKPUMP_CODE_REPO` | `<workspace>` | The repository whose commits `heartbeat --end` measures, and the root `review --prompt` paths are made relative to. Frequently not the ledger repo. |

**Git**

| Key | Default | Effect |
|---|---|---|
| `TASKPUMP_TASK_PUSH` | `0` | `1` pushes after each state commit. `TASKPUMP_PUSH` is the fallback spelling; `TASKPUMP_TASK_PUSH` wins. A rejected push retries with fetch-rebase and jittered backoff; a ledger with no remote warns once and succeeds. |
| `TASKPUMP_PUSH_RETRIES` | `6` | Attempts before `push failed after N retries` (rc 1, after the commit already landed). |
| `TASKPUMP_COMMITTER_NAME` | `tp-task` | Identity on ledger commits, deliberately distinct from the operator's, so a ledger's history separates bookkeeping from authored work. |
| `TASKPUMP_COMMITTER_EMAIL` | `task@taskpump.local` | As above. |

**Id grammar**

| Key | Default | Effect |
|---|---|---|
| `TASKPUMP_ID_PATTERN` | `^T[0-9]+(\.[0-9]+)?$` | Validates a new id in `create`, validates every id `review` generates, and is one of `fsck`'s per-file checks. |
| `TASKPUMP_PHASE_SIGIL` | `T` | The alphabetic prefix phase ranges strip and re-apply. What is *not* configurable is the shape: an id is `PHASE` or `PHASE.N`, and the phase is everything before the first `.`. |

**Tripwires and concurrency**

| Key | Default | Effect |
|---|---|---|
| `TASKPUMP_TURN_BUDGET_DEFAULT` | `50` | `claim`'s budget when `--turns` is omitted. |
| `TASKPUMP_FAILURE_LIMIT` | `3` | Consecutive unproductive iterations before `scrub` marks a task `stuck`. Read only by `scrub`. |
| `TASKPUMP_CLAIM_STALE_HOURS` | `24` | Heartbeat-staleness threshold. A non-integer value silently falls back to 24. |
| `TASKPUMP_LOCK_WAIT` | `120` | Seconds to wait for the state lock. **One budget for the whole acquisition**, re-queues included — under a real drain each departing agent's unlink wakes the next waiter onto an inode that has left the tree, and a fixed retry count failed seven waiters in ten. A non-integer pin is passed to `flock` verbatim and earns no retry budget. |
| `TASKPUMP_LOCK_NAME` | `.taskpump-task.lock` | The lockfile's name, created in the ledger's git root (or `/tmp` when the tasks dir is not in a repo). Every concurrent agent must resolve the same name or they stop excluding each other — change it only between runs, never under a live drain. |

**Behaviour**

| Key | Default | Effect |
|---|---|---|
| `TASKPUMP_TASK_NOCOMMIT` | `0` | `1` skips commits **and the state lock**. Fixture mode; not safe for concurrency. |
| `TASKPUMP_TASK_DEBUG` | `0` | `1` traces resolution, skipped candidates, lock acquisition and commit decisions to stderr. Reach for this before guessing. |
| `TASKPUMP_PROG_NAME` | `tp-task` | The name this tool uses in its own diagnostics and in the command lines it suggests. |

Two more reach `tp task` through `lib/config.sh` and change which ledger every
verb touches, though `tp task --help` never names them:
`TASKPUMP_CONFIG` (load this conf file explicitly, skipping the discovery walk)
and `TASKPUMP_NO_CONF=1` (suppress the discovery walk entirely — an explicit
`TASKPUMP_CONFIG` still loads).

**Keys that do *not* reach `tp task`, despite appearing ledger-shaped:**

- **`TASKPUMP_TASK_EXT` / `TASKPUMP_TASK_FILE_EXT`.** `tp task` reads neither.
  The extension is hardcoded `.md` in every path — the file resolver, the
  directory walk, the review-task writer, `fsck`'s stem derivation. `tp monitor`
  and `tp dag-render` *do* honour the key, so setting it gives the monitor one
  ledger and the ledger CLI another, with no diagnostic from either. Verified:
  with `TASKPUMP_TASK_EXT=.task`, `tp task list` still lists the `.md` ledger and
  ignores the `.task` file. Leave it unset.
- **`TASKPUMP_TASKS_SUBDIR`.** Documented as a fallback spelling for
  `TASKPUMP_LEDGER_PROBE`, and the fallback does exist in `lib/config.sh` — but
  `tp-task` defaults `TASKPUMP_LEDGER_PROBE` to `tasks` *before* workspace
  resolution runs, so the probe is never empty and the fallback can never fire
  here. Verified: in a fixture whose ledger is at `planning/tasks`,
  `TASKPUMP_TASKS_SUBDIR=planning/tasks tp task resolve --tasks-dir` printed the
  TaskPump *installation's* tasks dir, while `TASKPUMP_LEDGER_PROBE=planning/tasks`
  printed the fixture's. Write the canonical name.
- **`TASKPUMP_LEDGER_REPO`.** No occurrence in `libexec/tp-task`. Its readers are
  `tp-pump` and the reference runner's entrypoint. Setting it to point `tp task`
  at a separate ledger checkout does nothing.
- **`TP_LIB_DIR`.** Written as an override (`${TP_LIB_DIR:-...}`) but inert:
  `lib/config.sh` assigns it unconditionally and is sourced first, so an exported
  value is always overwritten before the line that reads it.

---

### Traps, collected

Every one of these was reproduced against a scratch fixture at this revision. All
are places the tool is silent, or says less than it knows.

1. **No exit code 2.** Every argument error is rc 1. `bin/tp` returns 2 for an
   unknown *top-level* command, so 2 never distinguishes a `tp task` misuse.
2. **A malformed `--phases` range answers 0, rc 0.** The error reaches stderr
   only, and with a partial list you get a real count for a narrower range than
   you named. `--count` is the drain test, so this reads as "drained".
3. **An unresolvable blocker is refused in total silence** — `create --blockers`
   and `blockers --add/--set`, rc 1, nothing on either stream. Self-blocking, by
   contrast, prints.
4. **`blockers --remove` fails, silently, when any *other* blocker is dangling**,
   because the whole surviving list is re-validated. `--clear` still works.
5. **`scrub` ignores every argument.** No parser, no dry-run, and a flag is not a
   no-op — the sweep runs and relabels.
6. **`claim --turns` is unvalidated** and leaks a raw `yq` lexer error on a
   non-numeric value.
7. **`create --phase` is not checked against the id**, and no filter reads the
   `phase` field anyway — both `next --phase` and `ready --phases` group by the
   id's prefix.
8. **`list --status` does no vocabulary check**; a typo prints an empty table,
   rc 0.
9. **`resolve` ignores every argument after the first**, rc 0.
10. **`heartbeat <id>` with no flag stamps a start.** Neither the help nor the
    contract names a default, so an unflagged call reads as a no-op and is not.
11. **`verdict` on an unclaimed review warns and still exits 0.** In a scripted
    drain that warning is the only record of who ruled.
12. **`TASKPUMP_TASK_EXT` splits the ledger between tools** — see above.
13. **`TASKPUMP_TASK_NOCOMMIT=1` disables cross-agent exclusion**, not just the
    commit.
14. **The state lockfile falls back to `/tmp`** when the tasks dir is not inside a
    git repository, where two unrelated ledgers on one host will collide.
